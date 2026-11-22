"""Offline regression checks for the read-only Python prototype."""
import contextlib
import datetime as dt
import importlib.util
import io
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock, patch

SCRIPT = Path(__file__).resolve().parents[2] / 'scripts/evcc-vm-aggregate.py'
spec = importlib.util.spec_from_file_location('vm_python', SCRIPT)
vm = importlib.util.module_from_spec(spec)
spec.loader.exec_module(vm)
CFG = dict(TIMEZONE='Europe/Berlin', ENERGY_SAMPLE_INTERVAL='60s', TARIFF_PRICE_INTERVAL='15m', PEAK_POWER_LIMIT='40000', HOME_BATTERY='true', DYNAMIC_TARIFF='true')


class PortTests(unittest.TestCase):
    def worker(self, values=None):
        client = Mock(cache={})
        worker = vm.Aggregator(CFG, client)
        worker.day = dt.date(2025, 1, 1)
        worker.start, worker.end, worker.cutoff = 0, 180, 180
        worker.output = []
        worker.matrix = Mock(return_value=[{'metric': {}, 'values': values or [[60, '100'], [120, '100'], [180, '100']]}])
        return worker

    def test_trapezoids_and_no_edge_extrapolation(self):
        w = self.worker()
        w.energy('energy', 'raw', 'positive')
        self.assertAlmostEqual(float(w.output[0].split()[-2]), 100 * 120 / 3600)

    def test_missing_power_bin_is_zero(self):
        w = self.worker([[60, '100'], [180, '100']])
        w.energy('energy', 'raw', 'positive')
        self.assertAlmostEqual(float(w.output[0].split()[-2]), 100 * 60 / 3600)

    def test_missing_tariff_omits_nonzero_energy(self):
        w = self.worker()
        with contextlib.redirect_stderr(io.StringIO()):
            w.energy('cost', 'raw', 'signed', prices={})
        self.assertEqual(w.output, [])

    def test_zero_energy_needs_no_tariff(self):
        w = self.worker([[60, '0'], [120, '0'], [180, '0']])
        w.energy('cost', 'raw', 'signed', prices={})
        self.assertEqual(float(w.output[0].split()[-2]), 0)

    def test_zero_negative_prices_and_segment_boundary(self):
        w = self.worker()
        w.tariff = 60
        w.energy('cost', 'raw', 'signed', prices={0: 0, 1: -0.2})
        self.assertAlmostEqual(float(w.output[0].split()[-2]), -1200 / 3600000)

    def test_forecast_incomplete_is_omitted(self):
        w = self.worker([[60, '100'], [180, '100']])
        with contextlib.redirect_stderr(io.StringIO()):
            w.energy('forecast', 'raw', 'forecast')
        self.assertEqual(w.output, [])

    def test_duplicate_and_empty_device_labels_rejected(self):
        for rows in ([{'metric': {}, 'value': [0, 1]}], [{'metric': {'title': 'a'}, 'value': [0, 1]}] * 2):
            with self.assertRaises(ValueError):
                self.worker().stage('test', 'title', rows)

    def test_multiple_scalar_and_nonfinite_rejected(self):
        with self.assertRaises(ValueError):
            self.worker().stage('test', '', [{'metric': {}, 'value': [0, 1]}] * 2)
        for value in ('NaN', 'Inf', '-Inf'):
            with self.assertRaises(ValueError):
                self.worker([[60, value], [120, '1']]).energy('test', 'raw', 'positive')

    def test_label_escaping(self):
        w = self.worker()
        w.stage('test', 'title', [{'metric': {'title': 'A"\\\nü'}, 'value': [0, 1]}])
        self.assertIn('title="A\\"\\\\\\nü"', w.output[0])

    def test_dst_and_leap_calendar_boundaries(self):
        for day, seconds in [('2025-03-30', 82800), ('2025-10-26', 90000), ('2024-02-29', 86400), ('2025-12-31', 86400)]:
            w = self.worker()
            w.run_metrics = Mock()
            with contextlib.redirect_stderr(io.StringIO()):
                w.aggregate(dt.date.fromisoformat(day), now=2000000000)
            self.assertEqual(w.cutoff - w.start, seconds)

    def test_partial_and_future_days(self):
        w = self.worker()
        w.run_metrics = Mock()
        day = dt.date(2025, 1, 1)
        start = int(dt.datetime(2025, 1, 1, tzinfo=w.zone).timestamp())
        with contextlib.redirect_stderr(io.StringIO()):
            w.aggregate(day, now=start + 197)
        self.assertEqual(w.end - start, 180)
        self.assertEqual(w.cutoff - start, 197)
        w.run_metrics.reset_mock()
        self.assertEqual(w.aggregate(day, now=start - 1), [])
        w.run_metrics.assert_not_called()

    def test_partial_tariff_fallback_and_negative_seed(self):
        w = self.worker()
        w.client.get.side_effect = [[], [{'value': [0, '-0.2']}]]
        self.assertEqual(w.prices('tariff', 'last'), {0: -0.2})
        self.assertIn('[180s]', w.client.get.call_args_list[0].kwargs['query'])
        self.assertIn('[100y]', w.client.get.call_args_list[1].kwargs['query'])

    def test_complete_tariffs_skip_historical_seed(self):
        w = self.worker()
        w.end = 1800
        w.client.get.return_value = [{'values': [[900, '-0.2'], [1800, '0']]}]
        self.assertEqual(w.prices('tariff', 'last'), {0: -0.2, 1: 0})
        self.assertEqual(w.client.get.call_count, 1)

    def test_tariff_seed_only_fills_missing_bins(self):
        w = self.worker()
        w.end = 1860
        w.client.get.side_effect = [
            [{'values': [[1800, '0.5']]}], [{'value': [0, '-0.2']}], []]
        self.assertEqual(w.prices('tariff', 'last'), {0: -0.2, 1: 0.5, 2: 0.5})

    def test_missing_historical_tariff_is_not_zero(self):
        w = self.worker()
        w.end = 1800
        w.client.get.side_effect = [[], []]
        self.assertEqual(w.prices('tariff', 'last'), {})

    def test_energy_segments_are_reused_for_costs(self):
        w = self.worker()
        w.energy('energy', 'raw', 'positive')
        with patch.object(vm, 'numeric', wraps=vm.numeric) as convert:
            w.energy('cost', 'raw', 'positive', prices={0: 0.2})
        self.assertEqual(w.matrix.call_count, 1)
        # Only the finished cost is converted by stage(), not the raw samples.
        self.assertEqual(convert.call_count, 1)
        self.assertAlmostEqual(float(w.output[-1].split()[-2]), 12000 * 0.2 / 3600000)

    def test_segment_cache_cleared_between_days(self):
        w = self.worker()
        w.run_metrics = lambda window: w.energy('energy', 'raw', 'positive')
        with contextlib.redirect_stderr(io.StringIO()):
            w.aggregate(dt.date(2025, 1, 1), now=2000000000)
            w.aggregate(dt.date(2025, 1, 2), now=2000000000)
        self.assertEqual(w.matrix.call_count, 2)

    def test_batched_dst_days_match_daily_queries_without_inventing_devices(self):
        for first in (dt.date(2025, 3, 29), dt.date(2025, 10, 25)):
            cfg = dict(CFG, ENERGY_SAMPLE_INTERVAL='1h', TARIFF_PRICE_INTERVAL='1h')
            def make_worker():
                client = Mock(cache={})
                w = vm.Aggregator(cfg, client)
                def query(endpoint, **params):
                    values = []
                    for timestamp in range(params['start'], params['end'] + 1, params['step']):
                        # Assign the interval ending at midnight to the previous
                        # day; the middle day has no series at all.
                        day = dt.datetime.fromtimestamp(timestamp - 1, w.zone).date()
                        if day != first + dt.timedelta(days=1):
                            values.append([timestamp, str(timestamp % 730 + 1)])
                    return [{'metric': {'title': 'device'}, 'values': values}] if values else []
                client.get.side_effect = query
                w.run_metrics = lambda window: w.energy('energy', 'raw', 'positive', 'title')
                return w
            daily, batch = make_worker(), make_worker()
            last = first + dt.timedelta(days=2)
            with contextlib.redirect_stderr(io.StringIO()):
                a = list(daily.aggregate_range(first, last, batch_days=1, now=2000000000))
                b = list(batch.aggregate_range(first, last, batch_days=7, now=2000000000))
            self.assertEqual(a, b)
            self.assertEqual(b[1][1], [])
            self.assertEqual(daily.client.get.call_count, 3)
            self.assertEqual(batch.client.get.call_count, 1)
            self.assertEqual(batch.batch_matrices, {})

    def test_batched_soc_preserves_daily_raw_extrema(self):
        client = Mock(cache={})
        w = vm.Aggregator(CFG, client)
        first, last = dt.date(2025, 10, 25), dt.date(2025, 10, 26)
        boundary = int(dt.datetime.combine(last, dt.time(), w.zone).timestamp()) * 1000
        client.get.return_value = [{'metric': {}, 'timestamps': [boundary - 1, boundary], 'values': [80, 2]}]
        w.run_metrics = lambda window: w.soc()
        with contextlib.redirect_stderr(io.StringIO()):
            days = list(w.aggregate_range(first, last, now=2000000000))
        self.assertEqual([float(line.split()[-2]) for line in days[0][1]], [80, 80])
        self.assertEqual([float(line.split()[-2]) for line in days[1][1]], [2, 2])
        self.assertEqual(client.get.call_count, 1)

    def test_today_is_not_batched_with_history(self):
        w = vm.Aggregator(CFG, Mock(cache={}))
        first = dt.date(2025, 1, 1)
        now = int(dt.datetime(2025, 1, 4, 12, tzinfo=w.zone).timestamp())
        batches = []
        w.run_metrics = lambda window: batches.append((w.day, w.batch_start, w.batch_end))
        with contextlib.redirect_stderr(io.StringIO()):
            list(w.aggregate_range(first, dt.date(2025, 1, 4), now=now))
        self.assertIsNotNone(batches[0][1])
        self.assertIsNone(batches[-1][1])

    def test_request_profile_separates_http_decode_and_hits(self):
        c = vm.Client(dict(VM_HOST='localhost', VM_PORT='8428'), profile=True)
        c.connection = Mock()
        c.connection.getresponse.return_value.status = 200
        c.connection.getresponse.return_value.read.return_value = b'{"status":"success","data":{"result":[]}}'
        c.get('/api/v1/query', query='test')
        c.get('/api/v1/query', query='test')
        p = c.profile()
        self.assertEqual((p['requests'], p['cache_hits']), (1, 1))
        self.assertGreaterEqual(p['http_seconds'], 0)
        self.assertGreaterEqual(p['decode_seconds'], 0)
        self.assertNotIn('headers', p['queries'][0])

    def test_unaligned_half_hour_dst_uses_daily_power_query(self):
        w = vm.Aggregator(dict(CFG, TIMEZONE='Australia/Lord_Howe',
                               ENERGY_SAMPLE_INTERVAL='1h', TARIFF_PRICE_INTERVAL='1h'), Mock(cache={}))
        w.prepare_batch(dt.date(2025, 10, 4), dt.date(2025, 10, 7))
        w.day = dt.date(2025, 10, 6)
        w.start = int(dt.datetime.combine(w.day, dt.time(), w.zone).timestamp())
        w.cutoff = w.start + 86400
        w.end = w.cutoff
        w.client.get.return_value = []
        w.matrix('raw', 'positive', '')
        self.assertEqual(w.client.get.call_args.kwargs['start'], w.start + w.step)
        self.assertEqual(w.client.get.call_args.kwargs['end'], w.end)

    def test_batch_cache_released_on_failure(self):
        w = vm.Aggregator(CFG, Mock(cache={}))
        def fail(window):
            w.batch_matrices['test'] = [1]
            w.batch_soc = [2]
            raise ValueError('test failure')
        w.run_metrics = fail
        with self.assertRaises(ValueError), contextlib.redirect_stderr(io.StringIO()):
            list(w.aggregate_range(dt.date(2025, 1, 1), dt.date(2025, 1, 7), now=2000000000))
        self.assertEqual(w.batch_matrices, {})
        self.assertIsNone(w.batch_soc)
        self.assertIsNone(w.batch_start)

    def test_query_details_are_not_accumulated_without_profile(self):
        c = vm.Client(dict(VM_HOST='localhost', VM_PORT='8428'))
        c.connection = Mock()
        c.connection.getresponse.return_value.status = 200
        c.connection.getresponse.return_value.read.return_value = b'{"status":"success","data":{"result":[]}}'
        c.get('/api/v1/query', query='test')
        self.assertEqual(c.profile()['queries'], [])
        self.assertEqual(c.profile()['requests'], 1)

    def test_soc_filters_raw_extrema(self):
        w = self.worker()
        w.client.get.return_value = [{'metric': {}, 'timestamps': [0, 1, 2, 3, 4, 180000], 'values': [0, -1, 101, 80, 2, 99]}]
        w.soc()
        self.assertEqual([float(s.split()[-2]) for s in w.output], [80, 2])

    def test_config_never_executes_shell(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'test.conf'
            path.write_text('VM_HOST="$(touch /tmp/should-never-exist)"')
            with self.assertRaises(ValueError):
                vm.read_config(path)

    def test_mutation_endpoints_blocked_and_cache(self):
        c = vm.Client(dict(VM_HOST='localhost', VM_PORT='8428'))
        with self.assertRaises(ValueError):
            c.get('/api/v1/import/prometheus')
        c.connection = Mock()
        c.connection.getresponse.return_value.status = 200
        c.connection.getresponse.return_value.read.return_value = b'{"status":"success","data":{"result":[]}}'
        c.get('/api/v1/query', query='x')
        c.get('/api/v1/query', query='x')
        self.assertEqual(c.connection.request.call_count, 1)
        self.assertEqual(c.connection.request.call_args.args[0], 'GET')

    def test_cli_requires_action_before_any_connection(self):
        with patch.object(vm, 'Client') as client, contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit):
                vm.main([])
            client.assert_not_called()

    def test_missing_tariff_does_not_discard_zero_energy_device(self):
        w = self.worker()
        w.matrix.return_value = [
            {'metric': {'title': 'active'}, 'values': [[60, '100'], [120, '100']]},
            {'metric': {'title': 'idle'}, 'values': [[60, '0'], [120, '0']]}]
        with contextlib.redirect_stderr(io.StringIO()):
            w.energy('cost', 'raw', 'signed', 'title', prices={})
        self.assertEqual(len(w.output), 1)
        self.assertIn('title="idle"', w.output[0])

    def test_duration_and_date_validation(self):
        for value in ('0s', '1.5m', '1h30m', '-60s'):
            with self.assertRaises(ValueError):
                vm.duration(value)
        for parts in ([2025, 2, 29], [1969, 1, 1]):
            with self.assertRaises(ValueError):
                vm.date_parts(parts)
        with self.assertRaises(ValueError):
            vm.Aggregator(dict(CFG, ENERGY_SAMPLE_INTERVAL='7s'), Mock())


if __name__ == '__main__':
    unittest.main()
