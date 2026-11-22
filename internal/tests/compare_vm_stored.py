#!/usr/bin/env python3
"""Compare Python dry runs with stored VM daily aggregates; never execute Bash.

Missing pvEnergyForecastDaily reference values are recorded separately. Existing
forecast values receive the same 1% check as every other metric.
"""
import argparse
import ast
import calendar
import contextlib
import datetime as dt
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import re
import sys
import time


def load(path):
    spec = importlib.util.spec_from_file_location('vm_python', path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def identity(metric, labels):
    return (metric, tuple(sorted(labels.items())))


def parse_samples(lines):
    result = {}
    for line in lines:
        series, value, timestamp = line.rsplit(' ', 2)
        metric, labels = series.split('{', 1)
        pairs = re.findall(r'(\w+)=("(?:[^"\\]|\\.)*")', labels[:-1])
        key = identity(metric, {k: json.loads(v) for k, v in pairs})
        if key in result:
            raise ValueError('Duplicate Python sample')
        result[key] = (float(value), int(timestamp))
    return result


def stored_samples(rows, start, stop, numeric):
    result, issues = {}, []
    for row in rows:
        labels = dict(row['metric'])
        metric = labels.pop('__name__')
        key = identity(metric, labels)
        if len(row['values']) != len(row['timestamps']):
            raise ValueError('Invalid stored export')
        for timestamp, value in zip(row['timestamps'], row['values']):
            if not start <= timestamp < stop:
                continue
            sample = (numeric(value), timestamp)
            if key in result and result[key] != sample:
                issues.append({'series': repr(key), 'reason': 'conflicting stored samples', 'previous': result[key], 'sample': sample})
            result[key] = sample
    return result, issues


def compare(expected, actual):
    forecast = 'pvEnergyForecastDaily'
    reference_missing = [repr(k) for k in sorted(actual.keys() - expected.keys()) if k[0] != forecast]
    forecast_missing = [repr(k) for k in sorted(actual.keys() - expected.keys()) if k[0] == forecast]
    python_missing = [repr(k) for k in sorted(expected.keys() - actual.keys())]
    failures, differences, exact, maximum = [], [], 0, 0.0
    for key in sorted(expected.keys() & actual.keys()):
        (a, ta), (b, tb) = expected[key], actual[key]
        relative = abs(b - a) / abs(a) if a else (0 if b == 0 else None)
        if relative is not None:
            maximum = max(maximum, relative)
        entry = {'series': repr(key), 'stored': a, 'python': b, 'stored_timestamp': ta,
                 'python_timestamp': tb, 'relative_error': relative, 'absolute_error': abs(b-a)}
        if a == b and ta == tb:
            exact += 1
        else:
            differences.append(entry)
        if ta != tb or relative is None or relative > 0.01:
            failures.append(entry)
    return dict(compared=len(expected.keys() & actual.keys()), exact=exact,
                maximum_relative_error=maximum, failures=failures, differences=differences,
                missing_stored=reference_missing, missing_python=python_missing,
                missing_forecast_reference=forecast_missing)



def metric_names(path):
    return sorted({node.value for node in ast.walk(ast.parse(path.read_text()))
                   if isinstance(node, ast.Constant) and isinstance(node.value, str)
                   and re.fullmatch(r'[A-Za-z]\w*Daily(?:Price)?', node.value)})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--python-script', type=Path, required=True)
    parser.add_argument('--config', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--batch-days', type=int, default=7, choices=range(1, 32), metavar='1..31')
    parser.add_argument('--profile', type=Path, help='Save timings for aggregation requests only')
    parser.add_argument('--reuse-python', action='store_true', help='Reuse dry-run samples already saved in --output')
    parser.add_argument('--month', nargs=2, type=int, metavar=('YEAR', 'MONTH'))
    parser.add_argument('days', nargs='*')
    args = parser.parse_args()
    days = set(dt.date.fromisoformat(day) for day in args.days)
    if args.month:
        year, month = args.month
        days.update(dt.date(year, month, day) for day in range(1, calendar.monthrange(year, month)[1] + 1))
    if not days:
        parser.error('Select dates or --month')
    module = load(args.python_script)
    cfg = module.read_config(args.config)
    client = module.Client(cfg, profile=bool(args.profile))
    reference_client = module.Client(cfg)
    worker = module.Aggregator(cfg, client)
    today = dt.datetime.now(worker.zone).date()
    if any(day >= today for day in days):
        parser.error('Use completed historical days for stored comparisons')
    metrics = metric_names(args.python_script)
    args.output.mkdir(parents=True, exist_ok=True)
    report = dict(reference='stored VictoriaMetrics daily aggregates',
                  python_sha256=hashlib.sha256(args.python_script.read_bytes()).hexdigest(),
                  timezone=cfg['TIMEZONE'], metrics=metrics, tolerance=0.01,
                  batch_days=args.batch_days, days=[])
    previous = {}
    if args.reuse_python:
        previous_report = json.loads((args.output / 'summary.json').read_text())
        if previous_report['python_sha256'] != report['python_sha256'] or previous_report['timezone'] != report['timezone']:
            raise ValueError('Saved dry-run version/timezone mismatch')
        previous = {entry['day']: entry for entry in previous_report['days']}
    try:
        ordered = sorted(days)
        batch_stop = None
        for index, day in enumerate(ordered):
            if args.reuse_python:
                seconds = previous[str(day)]['python_seconds']
                lines = (args.output / f'{day}.python.prom').read_text().splitlines()
                worker.start = int(dt.datetime.combine(day, dt.time(), worker.zone).timestamp())
                worker.cutoff = int(dt.datetime.combine(day + dt.timedelta(days=1), dt.time(), worker.zone).timestamp())
            else:
                if batch_stop is None or day > batch_stop:
                    end_index = index
                    while (end_index + 1 < len(ordered) and end_index - index + 1 < args.batch_days
                           and ordered[end_index + 1] == ordered[end_index] + dt.timedelta(days=1)):
                        end_index += 1
                    batch_stop = ordered[end_index]
                    worker.prepare_batch(day, batch_stop)
                log = io.StringIO()
                began = time.perf_counter()
                with contextlib.redirect_stderr(log):
                    lines = worker.aggregate(day)
                seconds = time.perf_counter() - began
                (args.output / f'{day}.python.prom').write_text('\n'.join(lines) + '\n')
                (args.output / f'{day}.python.log').write_text(log.getvalue())
            selector = '{__name__=~"' + '|'.join(metrics) + '",day="' + str(day) + '"}'
            rows = reference_client.get('/api/v1/export', **{'match[]': selector, 'start': worker.start, 'end': f'{worker.cutoff - 1}.999'})
            reference_client.cache.clear()
            (args.output / f'{day}.stored.json').write_text(json.dumps(rows))
            expected, issues = stored_samples(rows, worker.start * 1000, worker.cutoff * 1000, module.numeric)
            actual = parse_samples(lines)
            entry = dict(day=str(day), python_seconds=seconds, stored_samples=len(expected), python_samples=len(actual),
                         stored_issues=issues, **compare(expected, actual))
            report['days'].append(entry)
            (args.output / 'summary.json').write_text(json.dumps(report, indent=2, allow_nan=False))
            print(json.dumps({k: len(v) if isinstance(v, list) else v for k,v in entry.items() if k != 'differences'}), flush=True)
    finally:
        client.connection.close()
        reference_client.connection.close()
        if args.profile:
            profile = client.profile()
            profile['elapsed_seconds'] = sum(d['python_seconds'] for d in report['days'])
            args.profile.write_text(json.dumps(profile, indent=2))
    return int(any(d['failures'] or d['missing_stored'] or d['missing_python'] or d['stored_issues'] for d in report['days']))


if __name__ == '__main__':
    sys.exit(main())
