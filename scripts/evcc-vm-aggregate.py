#!/usr/bin/env python3
"""EVCC daily aggregation; Python >=3.9, standard library only.

Date calculations publish by default; use --dry-run to preview samples without writes.
"""
import argparse
import base64
import calendar
import datetime as dt
import http.client
import json
import math
from pathlib import Path
import re
import sys
import time
from urllib.parse import urlencode
from zoneinfo import ZoneInfo


AGGREGATED_METRICS = (
    'pvEnergyDaily', 'pvEnergyForecastDaily', 'homeEnergyDaily',
    'gridEnergyImportDaily', 'gridEnergyExportDaily',
    'batteryEnergyDischargedDaily', 'batteryEnergyChargedDaily',
    'loadpointEnergyDaily', 'auxEnergyDaily', 'extEnergyDaily', 'consumerEnergyDaily',
    'energyPriceBoughtDaily', 'energyPriceSoldDaily', 'energyPriceMaxDaily',
    'energyPriceMinDaily', 'energyPriceAvgDaily', 'greenShareHomeDaily',
    'batterySocMaxDaily', 'batterySocMinDaily', 'vehicleOdometerMaxDaily',
    'vehicleEnergyDaily', 'potentialHomeDailyPrice', 'potentialLoadpointDailyPrice',
    'energyDischargeDailyPrice', 'energyChargeDailyPrice',
    'vehicleChargeDailyPrice', 'potentialVehicleChargeDailyPrice',
)


def duration(value):
    m = re.fullmatch(r'([1-9][0-9]*)([smhd])', value)
    if not m:
        raise ValueError('Invalid duration: ' + value)
    return int(m[1]) * dict(s=1, m=60, h=3600, d=86400)[m[2]]


def read_config(path):
    """Read assignments without executing shell code; support the shipped TZ idiom."""
    result = {}
    for line in Path(path).read_text().splitlines():
        line = line.strip()
        if not line or line.startswith('#'):
            continue
        m = re.fullmatch(r'([A-Z_]+)\s*=\s*(.*?)\s*', line)
        if not m:
            raise ValueError('Unsupported configuration line')
        key, value = m.groups()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
            value = value[1:-1]
        if key == 'TIMEZONE' and value in ('`cat /etc/timezone`', '$(cat /etc/timezone)'):
            value = Path('/etc/timezone').read_text().strip()
        elif '`' in value or '$(' in value:
            raise ValueError('Shell evaluation unsupported for ' + key)
        result[key] = value
    return result


def numeric(value):
    value = float(value)
    if not math.isfinite(value):
        raise ValueError('Non-finite sample/result')
    return value


class Client:
    def __init__(self, cfg, profile=False, allow_write=False):
        self.connection = http.client.HTTPConnection(cfg['VM_HOST'], int(cfg['VM_PORT']), timeout=180)
        self.headers = {}
        if cfg.get('VM_USER'):
            token = base64.b64encode((cfg['VM_USER'] + ':' + cfg.get('VM_PASSWORD', '')).encode()).decode()
            self.headers['Authorization'] = 'Basic ' + token
        self.cache = {}
        self.requests = 0
        self.timings = []
        self.cache_hits = 0
        self.profile_enabled = profile
        self.http_seconds = self.decode_seconds = 0.0
        self.allow_write = allow_write

    def get(self, endpoint, **params):
        if endpoint not in ('/api/v1/query', '/api/v1/query_range', '/api/v1/export', '/api/v1/series'):
            raise ValueError('Read-only endpoint required')
        key = endpoint + '?' + urlencode(params)
        if key not in self.cache:
            started = time.perf_counter()
            self.connection.request('GET', key, headers=self.headers)
            response = self.connection.getresponse()
            body = response.read().decode()
            received = time.perf_counter()
            self.requests += 1
            if response.status != 200:
                raise RuntimeError('VM HTTP status ' + str(response.status))
            if endpoint.endswith('/export'):
                result = [json.loads(line) for line in body.splitlines() if line.strip()]
            else:
                result = json.loads(body)
                if not isinstance(result, dict) or result.get('status') != 'success':
                    raise ValueError('Invalid VM response')
                data = result.get('data')
                if not endpoint.endswith('/series'):
                    data = data.get('result') if isinstance(data, dict) else None
                if not isinstance(data, list):
                    raise ValueError('Invalid VM response')
                result = data
            self.cache[key] = result
            http_seconds = received - started
            decode_seconds = time.perf_counter() - received
            self.http_seconds += http_seconds
            self.decode_seconds += decode_seconds
            if self.profile_enabled:
                self.timings.append(dict(endpoint=endpoint, params=params, bytes=len(body.encode()),
                                         http_seconds=http_seconds, decode_seconds=decode_seconds))
        else:
            self.cache_hits += 1
        return self.cache[key]

    def post(self, endpoint, body=None, **params):
        if not self.allow_write:
            raise ValueError('Writes are disabled for this client')
        if endpoint not in ('/api/v1/admin/tsdb/delete_series', '/api/v1/import/prometheus'):
            raise ValueError('Unsupported write endpoint')
        if endpoint.endswith('/delete_series'):
            if set(params) != {'match[]'} or body is not None:
                raise ValueError('Deletion requires a series selector')
            body = urlencode(params).encode()
            content_type = 'application/x-www-form-urlencoded'
        else:
            if params or not isinstance(body, bytes) or not body:
                raise ValueError('Import requires a nonempty byte payload')
            content_type = 'text/plain; charset=utf-8'
        started = time.perf_counter()
        self.connection.request('POST', endpoint, body=body,
                                headers=dict(self.headers, **{'Content-Type': content_type}))
        response = self.connection.getresponse()
        response.read()
        elapsed = time.perf_counter() - started
        self.requests += 1
        self.http_seconds += elapsed
        if self.profile_enabled:
            self.timings.append(dict(method='POST', endpoint=endpoint, params=params, bytes=len(body),
                                     http_seconds=elapsed, decode_seconds=0))
        if not 200 <= response.status < 300:
            raise RuntimeError(f'VM HTTP status {response.status} during {endpoint}; stopping without retry')
        self.cache.clear()

    def profile(self):
        return dict(requests=self.requests, cache_hits=self.cache_hits,
                    http_seconds=self.http_seconds, decode_seconds=self.decode_seconds,
                    queries=self.timings)


class Aggregator:
    def __init__(self, cfg, client):
        self.cfg, self.client = cfg, client
        self.zone = ZoneInfo(cfg['TIMEZONE'])
        self.step = duration(cfg['ENERGY_SAMPLE_INTERVAL'])
        self.tariff = duration(cfg['TARIFF_PRICE_INTERVAL'])
        if self.step > 3600 or 3600 % self.step or self.tariff % self.step:
            raise ValueError('Sample interval must divide one hour and tariff interval')
        if not re.fullmatch('[1-9][0-9]*', cfg['PEAK_POWER_LIMIT']):
            raise ValueError('PEAK_POWER_LIMIT must be a positive integer')
        self.peak = cfg['PEAK_POWER_LIMIT']
        self.interval_energies = {}
        self.batch_start = self.batch_end = None
        self.batch_matrices = {}
        self.batch_soc = None
        self.day_metrics = set()
        self.day_ready = False
        self.debug = cfg.get('DEBUG', 'false') == 'true'

    def log_debug(self, message):
        if self.debug:
            print('[DEBUG] ' + message, file=sys.stderr)

    def publish(self):
        """Replace only the metrics staged by a completed, validated day."""
        if not self.client.allow_write:
            raise ValueError('Writes are disabled')
        if not self.day_ready:
            raise ValueError('Day calculations have not completed successfully')
        unknown = self.day_metrics.difference(AGGREGATED_METRICS)
        if unknown:
            raise ValueError('Unregistered output metrics: ' + ', '.join(sorted(unknown)))
        # All output must encode successfully before the first deletion.
        payload = ('\n'.join(self.output) + '\n').encode() if self.output else b''
        try:
            for metric in AGGREGATED_METRICS:
                if metric in self.day_metrics:
                    selector = (f'{metric}{{year="{self.day.year}",month="{self.day:%Y-%m}",'
                                f'day="{self.day}"}}')
                    self.client.post('/api/v1/admin/tsdb/delete_series', **{'match[]': selector})
            if payload:
                self.client.post('/api/v1/import/prometheus', body=payload)
        except (OSError, RuntimeError, ValueError, http.client.HTTPException) as exc:
            raise RuntimeError(f'{self.day}: publication failed ({exc}); some previous aggregates may already be '
                               'deleted. Fix the error and rerun this day; no automatic retry.') from exc
        self.log_debug(f'{self.day}: published {len(self.output)} samples')

    def power_expression(self, selector, mode, tag):
        if mode == 'forecast':
            return f'avg((last_over_time({selector}[24h] offset 1ms) >= 0) < {self.peak})'
        x, p = f'{selector}[{self.step}s] offset 1ms', self.peak
        def f(name, bound):
            return f'{name}_over_time({x},{bound})'
        if mode == 'positive':
            numerator = f('sum_gt', 0) + ' - ' + f('sum_gt', p) + ' - ' + f('sum_eq', p)
            denominator = f('count_gt', 0) + ' + ' + f('count_eq', 0) + ' - ' + f('count_gt', p) + ' - ' + f('count_eq', p)
        elif mode == 'negative':
            numerator = f('sum_le', 0) + ' - ' + f('sum_le', '-' + p)
            denominator = f('count_le', 0) + ' - ' + f('count_le', '-' + p)
        elif mode == 'signed':
            numerator = f('sum_le', p) + ' - ' + f('sum_eq', p) + ' - ' + f('sum_le', '-' + p)
            denominator = f('count_le', p) + ' - ' + f('count_eq', p) + ' - ' + f('count_le', '-' + p)
        else:
            raise ValueError('Unknown filter')
        group = f'by ({tag})' if tag else ''
        return f'(sum {group}({numerator})) / clamp_min(sum {group}({denominator}),1)'

    def matrix(self, selector, mode, tag):
        query = self.power_expression(selector, mode, tag)
        if (self.batch_start is not None and self.batch_start <= self.start < self.cutoff <= self.batch_end
                and (self.start - self.batch_start) % self.step == 0):
            if query not in self.batch_matrices:
                self.batch_matrices[query] = self.client.get(
                    '/api/v1/query_range', query=query, start=self.batch_start + self.step,
                    end=self.batch_end, step=self.step)
            # A device present elsewhere in the week must not invent a zero
            # result on a day on which the original daily query has no series.
            result = []
            for row in self.batch_matrices[query]:
                values = [v for v in row['values'] if self.start < v[0] <= self.end]
                if values:
                    result.append(dict(metric=row['metric'], values=values))
            return result
        return self.client.get('/api/v1/query_range', query=query,
                               start=self.start + self.step, end=self.end, step=self.step)

    def prepare_batch(self, first, last):
        """Cache power matrices and raw SoC for at most one calendar chunk."""
        self.batch_matrices.clear()
        self.batch_soc = None
        self.batch_start = self.batch_end = None
        if first < last:
            self.batch_start = int(dt.datetime.combine(first, dt.time(), self.zone).timestamp())
            self.batch_end = int(dt.datetime.combine(last + dt.timedelta(days=1), dt.time(), self.zone).timestamp())

    def aggregate_range(self, first, last, batch_days=7, now=None):
        if not 1 <= batch_days <= 31:
            raise ValueError('Batch days must be between 1 and 31')
        if first > last:
            raise ValueError('Start date is after end date')
        now = int(time.time()) if now is None else now
        today = dt.datetime.fromtimestamp(now, self.zone).date()
        try:
            while first <= last:
                # Today's moving cutoff and future days always run separately.
                stop = min(last, first + dt.timedelta(days=batch_days - 1))
                stop = min(stop, today - dt.timedelta(days=1)) if first < today else first
                self.prepare_batch(first, stop)
                while first <= stop:
                    yield first, self.aggregate(first, now=now)
                    first += dt.timedelta(days=1)
        finally:
            self.batch_matrices.clear()
            self.batch_soc = None
            self.batch_start = self.batch_end = None

    def prices(self, metric, mode):
        # A historical default is only used where keep_last_value has no value.
        # Avoid scanning up to 100 years when every required bin already exists.
        def seed():
            rows = self.client.get('/api/v1/query',
                                   query=f'avg(last_over_time({metric}[100y] offset 1ms))', time=self.start)
            return numeric(rows[0]['value'][1]) if rows else None

        def expression(window):
            if mode == 'mean':
                return f'sum(sum_over_time({metric}[{window}s] offset 1ms)) / sum(count_over_time({metric}[{window}s] offset 1ms))'
            return f'avg(last_over_time({metric}[{window}s] offset 1ms))'

        complete, remainder = divmod(self.end - self.start, self.tariff)
        prices = {}
        fallback = None
        if complete:
            rows = self.client.get('/api/v1/query_range', query=f'keep_last_value({expression(self.tariff)})',
                                   start=self.start + self.tariff,
                                   end=self.start + complete * self.tariff, step=self.tariff)
            values = rows[0]['values'] if rows else []
            prices = {math.floor((t - self.start) / self.tariff + 0.5) - 1: numeric(v) for t, v in values}
            missing = [i for i in range(complete) if i not in prices]
            if missing:
                fallback = seed()
                if fallback is not None:
                    prices.update((i, fallback) for i in missing)
        if remainder:
            rows = self.client.get('/api/v1/query', query=expression(remainder), time=self.end)
            last = numeric(rows[0]['value'][1]) if rows else prices.get(complete - 1)
            if last is None:
                last = fallback if complete else seed()
            if last is not None:
                prices[complete] = last
        return prices

    def stage(self, metric, tag, rows):
        if not rows:
            self.log_debug(f'{self.day}: no data for {metric}; existing values retained')
            return
        if not tag and len(rows) > 1:
            raise ValueError('Multiple scalar series: ' + metric)
        labels = [r['metric'].get(tag, '') for r in rows] if tag else []
        if tag and (any(not label for label in labels) or len(set(labels)) != len(labels)):
            raise ValueError('Missing/duplicate device labels: ' + metric)
        for row in rows:
            value = numeric(row['value'][1])
            fields = {'year': str(self.day.year), 'month': self.day.strftime('%Y-%m'), 'day': str(self.day)}
            if tag:
                fields[tag] = row['metric'][tag]
            text = ','.join(k + '=' + json.dumps(v, ensure_ascii=False) for k, v in fields.items())
            self.output.append(f'{metric}{{{text}}} {value:.17g} {self.start * 1000}')
        self.day_metrics.add(metric)

    def segments(self, selector, mode, tag):
        key = selector, mode, tag
        if key in self.interval_energies:
            return self.interval_energies[key]
        rows = self.matrix(selector, mode, tag)
        count = (self.end - self.start) // self.step
        if mode == 'forecast' and (len(rows) != 1 or [v[0] for v in rows[0]['values']] != list(range(self.start + self.step, self.end + 1, self.step))):
            self.interval_energies[key] = None
            return None
        prepared = []
        for row in rows:
            values = [0.0] * count
            for timestamp, value in row['values']:
                index = math.floor((timestamp - self.start) / self.step + 0.5) - 1
                value = numeric(value)
                if 0 <= index < count:
                    values[index] = value
            energies = [(values[i - 1] + values[i]) * self.step / 2 for i in range(1, count)]
            prepared.append((row['metric'], energies))
        self.interval_energies[key] = prepared
        return prepared

    def energy(self, metric, selector, mode, tag='', sign=1, prices=None):
        self.log_debug('Calculating ' + metric)
        prepared = self.segments(selector, mode, tag)
        if prepared is None:
            print(f'[WARNING] {self.day}: {metric} omitted: incomplete forecast', file=sys.stderr)
            return
        results = []
        for labels, energies in prepared:
            area, missing = 0.0, False
            for i, energy in enumerate(energies):
                if prices is None:
                    area += energy
                elif energy != 0:
                    price = prices.get(i * self.step // self.tariff)
                    if price is None:
                        missing = True
                    else:
                        area += energy * price
            if missing:
                print(f'[WARNING] {self.day}: {metric} omitted for {labels}: energy without tariff; '
                      'previous costs for this metric/day are removed on publication', file=sys.stderr)
                self.day_metrics.add(metric)
            else:
                results.append({'metric': labels, 'value': [self.start, area * sign / (3600 if prices is None else 3600000)]})
        self.stage(metric, tag, results)

    def statistic(self, metric, expression, tag=''):
        self.log_debug('Calculating ' + metric)
        self.stage(metric, tag, self.client.get('/api/v1/query', query=expression, time=self.cutoff))

    def soc(self):
        if self.batch_start is not None and self.batch_start <= self.start < self.cutoff <= self.batch_end:
            if self.batch_soc is None:
                self.batch_soc = self.client.get('/api/v1/export', **{
                    'match[]': 'batterySoc_value{id=""}', 'start': self.batch_start, 'end': f'{self.batch_end - 1}.999'})
            rows = self.batch_soc
        else:
            rows = self.client.get('/api/v1/export', **{'match[]': 'batterySoc_value{id=""}', 'start': self.start, 'end': f'{self.cutoff - 1}.999'})
        values = []
        for row in rows:
            if not isinstance(row.get('metric'), dict) or not isinstance(row.get('values'), list) or not isinstance(row.get('timestamps'), list) or len(row['values']) != len(row['timestamps']):
                raise ValueError('Invalid raw export')
            values.extend(v for t, v in zip(row['timestamps'], row['values']) if self.start * 1000 <= t < self.cutoff * 1000 and type(v) in (int, float) and 0 <= v <= 100)
        for metric, candidates, operation in [('batterySocMaxDaily', values, max), ('batterySocMinDaily', [v for v in values if v > 0], min)]:
            self.stage(metric, '', [{'metric': {}, 'value': [0, operation(candidates)]}] if candidates else [])

    def aggregate(self, day, now=None):
        self.client.cache.clear()
        self.interval_energies.clear()
        self.day, self.output = day, []
        self.day_metrics.clear()
        self.day_ready = False
        self.start = int(dt.datetime.combine(day, dt.time(), self.zone).timestamp())
        next_start = int(dt.datetime.combine(day + dt.timedelta(days=1), dt.time(), self.zone).timestamp())
        now = int(time.time()) if now is None else now
        self.cutoff = min(next_start, now)
        self.end = self.start + (self.cutoff - self.start) // self.step * self.step
        if self.end - self.start < self.step * 2:
            return []
        window = f'{self.cutoff - self.start}s'
        print(f'[INFO] Aggregating {day}', file=sys.stderr)
        self.run_metrics(window)
        self.day_ready = True
        return self.output

    def run_metrics(self, window):
        self.energy('pvEnergyDaily', 'pvPower_value{id=""}', 'positive', '', 1)
        self.energy('pvEnergyForecastDaily', 'tariffSolar_value', 'forecast', '', 1)
        self.energy('homeEnergyDaily', 'homePower_value', 'positive', '', 1)
        self.energy('gridEnergyImportDaily', 'gridPower_value', 'positive', '', 1)
        self.energy('gridEnergyExportDaily', 'gridPower_value', 'negative', '', -1)
        self.energy('loadpointEnergyDaily', 'chargePower_value{loadpoint!=""}', 'positive', 'loadpoint', 1)
        self.energy('vehicleEnergyDaily', 'chargePower_value{vehicle!=""}', 'positive', 'vehicle', 1)
        self.energy('auxEnergyDaily', 'auxPower_value{title!=""}', 'positive', 'title', 1)
        self.energy('extEnergyDaily', 'extPower_value{title!=""}', 'positive', 'title', 1)
        self.energy('consumerEnergyDaily', 'consumersPower_value{title!=""}', 'positive', 'title', 1)
        self.statistic('vehicleOdometerMaxDaily', f'max by(vehicle)(max_over_time(vehicleOdometer_value{{vehicle!=""}}[{window}] offset 1ms))', 'vehicle')
        self.statistic('greenShareHomeDaily', f'avg(avg_over_time(greenShareHome_value[{window}] offset 1ms))')
        grid_prices = self.prices('tariffGrid_value', 'last')
        feed_prices = self.prices('tariffFeedIn_value', 'last')
        charge_prices = self.prices('tariffPriceLoadpoints_value', 'mean')
        self.energy('energyPriceBoughtDaily', 'gridPower_value', 'positive', '', 1, grid_prices)
        self.energy('energyPriceSoldDaily', 'gridPower_value', 'negative', '', -1, feed_prices)
        self.energy('potentialHomeDailyPrice', 'homePower_value', 'signed', '', 1, grid_prices)
        self.energy('potentialLoadpointDailyPrice', 'chargePower_value{loadpoint!=""}', 'signed', 'loadpoint', 1, grid_prices)
        self.energy('vehicleChargeDailyPrice', 'chargePower_value{vehicle!=""}', 'signed', 'vehicle', 1, charge_prices)
        self.energy('potentialVehicleChargeDailyPrice', 'chargePower_value{vehicle!=""}', 'signed', 'vehicle', 1, grid_prices)
        if self.cfg['HOME_BATTERY'] == 'true':
            self.energy('batteryEnergyDischargedDaily', 'batteryPower_value{id=""}', 'positive', '', 1)
            self.energy('batteryEnergyChargedDaily', 'batteryPower_value{id=""}', 'negative', '', -1)
            self.energy('energyDischargeDailyPrice', 'batteryPower_value{id=""}', 'positive', '', 1, grid_prices)
            self.energy('energyChargeDailyPrice', 'batteryPower_value{id=""}', 'negative', '', 1, feed_prices)
            self.soc()
        if self.cfg['DYNAMIC_TARIFF'] == 'true':
            self.statistic('energyPriceMaxDaily', f'max(max_over_time(tariffGrid_value[{window}] offset 1ms))')
            self.statistic('energyPriceMinDaily', f'min(min_over_time(tariffGrid_value[{window}] offset 1ms))')
            self.statistic('energyPriceAvgDaily', f'sum(sum_over_time(tariffGrid_value[{window}] offset 1ms))/sum(count_over_time(tariffGrid_value[{window}] offset 1ms))')


def date_parts(parts):
    if not 1970 <= int(parts[0]) <= 2100:
        raise ValueError('Year must be between 1970 and 2100')
    return dt.date(*map(int, parts))


def detect_devices(client):
    """Discover nonempty device labels across retained source series."""
    result = {}
    now = int(time.time())
    for name, metric, label in (
        ('vehicles', 'chargePower_value', 'vehicle'),
        ('loadpoints', 'chargePower_value', 'loadpoint'),
        ('ext_devices', 'extPower_value', 'title'),
        ('aux_devices', 'auxPower_value', 'title'),
        ('consumers', 'consumersPower_value', 'title'),
    ):
        # VM treats zero as an unspecified start (today), not the Unix epoch.
        # One second is rounded to the first UTC day by the metadata API.
        rows = client.get('/api/v1/series', **{'match[]': f'{metric}{{{label}!=""}}', 'start': 1, 'end': now})
        if any(not isinstance(row, dict) or any(not isinstance(v, str) for v in row.values()) for row in rows):
            raise ValueError('Invalid device discovery response')
        result[name] = sorted({row[label] for row in rows if row.get(label)})
    return result


def delete_aggregations(client):
    if not client.allow_write:
        raise ValueError('Writes are disabled')
    print('[WARNING] Delete ALL daily aggregates, including values whose raw data may no longer exist.\n'
          "Type 'YES' to continue:", file=sys.stderr, flush=True)
    try:
        confirmation = input()
    except EOFError:
        confirmation = ''
    if confirmation != 'YES':
        print('[INFO] Deletion aborted', file=sys.stderr)
        return
    for seconds in (3, 2, 1):
        print(f'[INFO] Deleting all aggregates in {seconds} seconds', file=sys.stderr)
        time.sleep(1)
    for metric in AGGREGATED_METRICS:
        try:
            client.post('/api/v1/admin/tsdb/delete_series', **{'match[]': metric})
        except (OSError, RuntimeError, ValueError, http.client.HTTPException) as exc:
            raise RuntimeError(f'Deletion stopped at {metric} ({exc}); earlier metrics may already be deleted') from exc
    print('[INFO] All daily aggregates deleted', file=sys.stderr)


def main(argv=None):
    parser = argparse.ArgumentParser(
        description='Calculate and optionally publish daily EVCC aggregates in VictoriaMetrics.',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog='''Choose one date selector, --detect, or --delete-aggregations.
Date calculations publish by default. Use --dry-run to calculate without writes.
Dates use TIMEZONE from the configuration.
Date ranges include both endpoints. Years must be between 1970 and 2100.
Today uses the cutoff at run start and integrates complete sample intervals;
future days are skipped. Dry runs print Prometheus samples to stdout;
logs go to stderr. Default publication replaces existing aggregates only after a day's
calculations succeed. Deletion and import are separate, non-atomic requests.
Do not overlap publishing runs for the same dates, including Bash cron jobs.

Examples:
  %(prog)s --dry-run --day 2025 3 30
  %(prog)s --dry-run --month 2026 1
  %(prog)s --dry-run --year 2025
  %(prog)s --dry-run --from 2026 1 1 --to 2026 1 7
  %(prog)s --dry-run --yesterday --debug
  %(prog)s --dry-run --today --config /path/to/evcc-vm-aggregate.conf
  %(prog)s --dry-run --month 2026 1 --batch-days 1 --profile timings.json
  %(prog)s --yesterday
  %(prog)s --detect
  %(prog)s --delete-aggregations
''')
    parser.add_argument('--config', type=Path, metavar='FILE', default=Path(__file__).with_suffix('.conf'),
                        help='Configuration file (default: evcc-vm-aggregate.conf beside this script)')
    parser.add_argument('--dry-run', action='store_true',
                        help='Print daily samples without modifying VictoriaMetrics (default: publish)')
    parser.add_argument('--debug', action='store_true',
                        help='Print per-metric progress, missing-source notices and final timings (also via DEBUG=true)')
    parser.add_argument('--profile', type=Path, metavar='FILE',
                        help='Write request parameters, response sizes, HTTP/JSON timings and elapsed time to a JSON file')
    parser.add_argument('--batch-days', type=int, default=7, choices=range(1, 32), metavar='1..31',
                        help='Calendar days per power/SoC query (default: 7; 1 disables batching)')
    selection = parser.add_argument_group('date selection or action').add_mutually_exclusive_group(required=True)
    selection.add_argument('--day', nargs=3, metavar=('YEAR', 'MONTH', 'DAY'),
                           help='Calculate one calendar day')
    selection.add_argument('--month', nargs=2, metavar=('YEAR', 'MONTH'),
                           help='Calculate daily aggregates for every day of a calendar month')
    selection.add_argument('--year', metavar='YEAR',
                           help='Calculate daily aggregates for every day of a calendar year')
    selection.add_argument('--from', dest='first', nargs=3, metavar=('YEAR', 'MONTH', 'DAY'),
                           help='First day of an inclusive range; ends today unless --to is given')
    selection.add_argument('--today', action='store_true',
                           help='Calculate the current, incomplete calendar day')
    selection.add_argument('--yesterday', action='store_true',
                           help='Calculate the previous calendar day')
    selection.add_argument('--detect', action='store_true',
                           help='Print vehicles, loadpoints and device titles as JSON; reads retained series only')
    selection.add_argument('--delete-aggregations', action='store_true',
                           help="Delete all registered daily aggregates after typing YES; incompatible with --dry-run")
    parser.add_argument('--to', dest='last', nargs=3, metavar=('YEAR', 'MONTH', 'DAY'),
                        help='Last day of an inclusive range; requires --from')
    args = parser.parse_args(argv)
    if args.last and not args.first:
        parser.error('--to requires --from')
    if args.delete_aggregations and args.dry_run:
        parser.error('--delete-aggregations cannot use --dry-run')
    cfg = read_config(args.config)
    debug = args.debug or cfg.get('DEBUG', 'false') == 'true'
    client = Client(cfg, profile=bool(args.profile), allow_write=not (args.dry_run or args.detect))
    started = time.perf_counter()
    try:
        if args.detect:
            print(json.dumps(detect_devices(client), indent=2, ensure_ascii=False))
        elif args.delete_aggregations:
            delete_aggregations(client)
        else:
            worker = Aggregator(cfg, client)
            worker.debug = debug
            today = dt.datetime.now(worker.zone).date()
            if args.year:
                first = date_parts([args.year, 1, 1])
                last = dt.date(first.year, 12, 31)
            elif args.month:
                first = date_parts([*args.month, 1])
                last = first.replace(day=calendar.monthrange(first.year, first.month)[1])
            elif args.day:
                first = last = date_parts(args.day)
            elif args.first:
                first = date_parts(args.first)
                last = date_parts(args.last) if args.last else today
            else:
                first = last = today - dt.timedelta(days=int(args.yesterday))
            for day, lines in worker.aggregate_range(first, last, batch_days=args.batch_days):
                if not args.dry_run:
                    if worker.day_ready:
                        worker.publish()
                else:
                    for line in lines:
                        print(line)
    finally:
        client.connection.close()
        if args.profile:
            profile = client.profile()
            profile['elapsed_seconds'] = time.perf_counter() - started
            args.profile.write_text(json.dumps(profile, indent=2))
    if not (args.detect or args.delete_aggregations):
        hours, remainder = divmod(int(time.perf_counter() - started), 3600)
        minutes, seconds = divmod(remainder, 60)
        print(f'[INFO] Aggregation finished in {hours:02d}h {minutes:02d}m {seconds:02d}s.', file=sys.stderr)
    if debug:
        print(f'[DEBUG] {client.requests} HTTP requests, {time.perf_counter() - started:.3f}s', file=sys.stderr)


if __name__ == '__main__':
    try:
        main()
    except (ValueError, KeyError, OSError, RuntimeError, http.client.HTTPException) as exc:
        print(f'[ERROR] {exc}', file=sys.stderr)
        sys.exit(1)
