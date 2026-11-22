"""Offline publication, deletion and discovery tests. No real VM connection."""
import contextlib
import datetime as dt
import importlib.util
import io
import json
from pathlib import Path
import unittest
from unittest.mock import Mock, patch
from urllib.parse import parse_qs

spec = importlib.util.spec_from_file_location('vm', Path(__file__).resolve().parents[2] / 'scripts/evcc-vm-aggregate.py')
vm = importlib.util.module_from_spec(spec)
spec.loader.exec_module(vm)
CFG = dict(VM_HOST='localhost', VM_PORT='8428', TIMEZONE='Europe/Berlin',
           ENERGY_SAMPLE_INTERVAL='60s', TARIFF_PRICE_INTERVAL='15m',
           PEAK_POWER_LIMIT='40000', HOME_BATTERY='true', DYNAMIC_TARIFF='true')
DELETE = '/api/v1/admin/tsdb/delete_series'
IMPORT = '/api/v1/import/prometheus'


class PublicationTests(unittest.TestCase):
    def worker(self):
        client = Mock(cache={}, allow_write=True)
        w = vm.Aggregator(CFG, client)
        w.day = dt.date(2025, 10, 26)
        w.start, w.end, w.cutoff = 0, 180, 180
        w.output = []
        w.day_ready = True
        return w

    def row(self, value=1, **labels):
        return {'metric': labels, 'value': [0, value]}

    def test_publish_staged_metrics_only_and_preserve_all_device_labels(self):
        w = self.worker()
        w.stage('pvEnergyDaily', '', [self.row()])
        w.stage('extEnergyDaily', 'title', [self.row(2, title='A"\\\nü'), self.row(3, title='B')])
        w.stage('auxEnergyDaily', 'title', [])
        w.publish()
        calls = w.client.post.call_args_list
        self.assertEqual([c.args[0] for c in calls], [DELETE, DELETE, IMPORT])
        selectors = [c.kwargs['match[]'] for c in calls[:-1]]
        self.assertEqual(selectors, [
            'pvEnergyDaily{year="2025",month="2025-10",day="2025-10-26"}',
            'extEnergyDaily{year="2025",month="2025-10",day="2025-10-26"}'])
        # Metric/day deletion must include all devices, even ones omitted now.
        self.assertTrue(all('title=' not in s for s in selectors))
        self.assertEqual(calls[-1].kwargs['body'].decode(), '\n'.join(w.output) + '\n')

    def test_completely_missing_tariff_deletes_old_costs_without_import(self):
        w = self.worker()
        w.matrix = Mock(return_value=[{'metric': {}, 'values': [[60, '100'], [120, '100']]}])
        with contextlib.redirect_stderr(io.StringIO()):
            w.energy('energyPriceBoughtDaily', 'raw', 'positive', prices={})
        self.assertEqual(w.output, [])
        w.publish()
        self.assertEqual(w.client.post.call_count, 1)
        self.assertIn('energyPriceBoughtDaily{', w.client.post.call_args.kwargs['match[]'])

    def test_missing_price_for_one_device_replaces_whole_cost_metric(self):
        w = self.worker()
        w.matrix = Mock(return_value=[
            {'metric': {'vehicle': 'active'}, 'values': [[60, '100'], [120, '100']]},
            {'metric': {'vehicle': 'idle'}, 'values': [[60, '0'], [120, '0']]}])
        with contextlib.redirect_stderr(io.StringIO()):
            w.energy('vehicleChargeDailyPrice', 'raw', 'signed', 'vehicle', prices={})
        w.publish()
        self.assertEqual(w.client.post.call_count, 2)
        self.assertNotIn('vehicle=', w.client.post.call_args_list[0].kwargs['match[]'])
        self.assertIn(b'vehicle="idle"', w.client.post.call_args_list[1].kwargs['body'])
        self.assertNotIn(b'vehicle="active"', w.client.post.call_args_list[1].kwargs['body'])

    def test_missing_power_and_incomplete_forecast_retain_old_values(self):
        w = self.worker()
        w.matrix = Mock(return_value=[])
        w.energy('homeEnergyDaily', 'raw', 'positive')
        with contextlib.redirect_stderr(io.StringIO()):
            w.energy('pvEnergyForecastDaily', 'forecast', 'forecast')
        w.publish()
        w.client.post.assert_not_called()

    def test_failed_day_cannot_publish_partially_staged_output(self):
        w = self.worker()
        def fail(window):
            w.stage('pvEnergyDaily', '', [self.row()])
            w.stage('homeEnergyDaily', '', [self.row('NaN')])
        w.run_metrics = fail
        with self.assertRaises(ValueError), contextlib.redirect_stderr(io.StringIO()):
            w.aggregate(dt.date(2025, 1, 1), now=2000000000)
        with self.assertRaises(ValueError):
            w.publish()
        w.client.post.assert_not_called()

    def test_delete_failure_stops_before_import_and_next_day(self):
        w = self.worker()
        w.stage('pvEnergyDaily', '', [self.row()])
        w.stage('homeEnergyDaily', '', [self.row()])
        w.client.post.side_effect = [None, RuntimeError('HTTP 500')]
        with self.assertRaisesRegex(RuntimeError, 'HTTP 500.*already be deleted'):
            w.publish()
        self.assertEqual(w.client.post.call_count, 2)
        self.assertTrue(all(c.args[0] == DELETE for c in w.client.post.call_args_list))

    def test_import_failure_is_reported_without_retry(self):
        w = self.worker()
        w.stage('pvEnergyDaily', '', [self.row()])
        w.client.post.side_effect = [None, OSError('connection lost')]
        with self.assertRaisesRegex(RuntimeError, 'rerun this day'):
            w.publish()
        self.assertEqual(w.client.post.call_count, 2)

    def test_unregistered_metric_and_disabled_client_cannot_publish(self):
        w = self.worker()
        w.stage('unknownDaily', '', [self.row()])
        with self.assertRaisesRegex(ValueError, 'Unregistered'):
            w.publish()
        w.client.post.assert_not_called()
        w.client.allow_write = False
        with self.assertRaisesRegex(ValueError, 'disabled'):
            w.publish()

    def test_client_default_cannot_write_even_via_get(self):
        c = vm.Client(CFG)
        c.connection = Mock()
        for endpoint in (DELETE, IMPORT):
            with self.assertRaises(ValueError):
                c.get(endpoint)
            with self.assertRaises(ValueError):
                c.post(endpoint, body=b'x')
        c.connection.request.assert_not_called()

    def test_post_encodes_form_utf8_auth_and_accepts_204(self):
        c = vm.Client(dict(CFG, VM_USER='test', VM_PASSWORD='secret'), profile=True, allow_write=True)
        c.connection = Mock()
        c.connection.getresponse.return_value.status = 204
        c.post(DELETE, **{'match[]': 'extEnergyDaily{title="ü"}'})
        call = c.connection.request.call_args
        self.assertEqual(call.args, ('POST', DELETE))
        self.assertEqual(parse_qs(call.kwargs['body'].decode())['match[]'], ['extEnergyDaily{title="ü"}'])
        self.assertTrue(call.kwargs['headers']['Authorization'].startswith('Basic '))
        c.post(IMPORT, body='extEnergyDaily{title="ü"} 2 0\n'.encode())
        self.assertEqual(c.connection.request.call_args.kwargs['body'].decode(), 'extEnergyDaily{title="ü"} 2 0\n')
        self.assertEqual(c.requests, 2)
        self.assertNotIn('secret', json.dumps(c.profile()))

    def test_post_failure_and_unsupported_payloads(self):
        c = vm.Client(CFG, allow_write=True)
        c.connection = Mock()
        c.connection.getresponse.return_value.status = 500
        with self.assertRaises(RuntimeError):
            c.post(DELETE, **{'match[]': 'pvEnergyDaily'})
        c.connection.request.reset_mock()
        for endpoint, kwargs in [(IMPORT, {'body': b''}), (DELETE, {}), ('/other', {})]:
            with self.assertRaises(ValueError):
                c.post(endpoint, **kwargs)
        c.connection.request.assert_not_called()

    def test_delete_all_requires_exact_confirmation(self):
        for answer in ('yes', 'YES ', '', EOFError()):
            c = Mock(allow_write=True)
            kwargs = {'side_effect': answer} if isinstance(answer, Exception) else {'return_value': answer}
            with patch('builtins.input', **kwargs), patch.object(vm.time, 'sleep') as sleep, contextlib.redirect_stderr(io.StringIO()):
                vm.delete_aggregations(c)
            c.post.assert_not_called()
            sleep.assert_not_called()

    def test_confirmed_delete_uses_only_registry_and_aborts_on_failure(self):
        c = Mock(allow_write=True)
        with patch('builtins.input', return_value='YES'), patch.object(vm.time, 'sleep'), contextlib.redirect_stderr(io.StringIO()):
            vm.delete_aggregations(c)
        self.assertEqual([call.kwargs['match[]'] for call in c.post.call_args_list], list(vm.AGGREGATED_METRICS))
        c = Mock(allow_write=True)
        c.post.side_effect = [None, RuntimeError('HTTP 500')]
        with self.assertRaises(RuntimeError), patch('builtins.input', return_value='YES'), patch.object(vm.time, 'sleep'), contextlib.redirect_stderr(io.StringIO()):
            vm.delete_aggregations(c)
        self.assertEqual(c.post.call_count, 2)

    def test_detection_is_read_only_sorted_unique_and_uses_history(self):
        c = Mock()
        c.get.side_effect = [[{'vehicle': 'B'}, {'vehicle': 'A'}, {'vehicle': 'A'}, {'vehicle': ''}],
                             [{'loadpoint': 'Garage'}], [{'title': 'ü'}], [], []]
        result = vm.detect_devices(c)
        self.assertEqual(result, dict(vehicles=['A', 'B'], loadpoints=['Garage'], ext_devices=['ü'], aux_devices=[], consumers=[]))
        c.post.assert_not_called()
        # Zero has special "use default" semantics in VM; require an explicit
        # nonzero start so historical devices are included.
        self.assertTrue(all(call.kwargs['start'] == 1 for call in c.get.call_args_list))

    def test_series_response_parsing_and_malformed_detection(self):
        c = vm.Client(CFG)
        c.connection = Mock()
        c.connection.getresponse.return_value.status = 200
        c.connection.getresponse.return_value.read.return_value = b'{"status":"success","data":[{"title":"x"}]}'
        self.assertEqual(c.get('/api/v1/series', **{'match[]': 'extPower_value'}), [{'title': 'x'}])
        fake = Mock()
        fake.get.return_value = [{'vehicle': 2}]
        with self.assertRaises(ValueError):
            vm.detect_devices(fake)

    def test_invalid_cli_combinations_fail_before_config_or_connection(self):
        for flags in [[], ['--write', '--today'],
                      ['--dry-run', '--delete-aggregations'],
                      ['--dry-run', '--today', '--to', '2025', '1', '1']]:
            with patch.object(vm, 'Client') as client, patch.object(vm, 'read_config') as cfg, contextlib.redirect_stderr(io.StringIO()):
                with self.assertRaises(SystemExit):
                    vm.main(flags)
                client.assert_not_called()
                cfg.assert_not_called()

    def test_main_dry_run_never_posts_and_leading_zero_dates(self):
        c = Mock(cache={}, allow_write=False)
        w = Mock()
        w.zone = vm.ZoneInfo('Europe/Berlin')
        w.aggregate_range.return_value = [(dt.date(2025, 8, 3), ['sample'])]
        with patch.object(vm, 'read_config', return_value=CFG), patch.object(vm, 'Client', return_value=c) as make, patch.object(vm, 'Aggregator', return_value=w), contextlib.redirect_stdout(io.StringIO()) as output:
            vm.main(['--dry-run', '--day', '2025', '08', '03'])
        self.assertFalse(make.call_args.kwargs['allow_write'])
        self.assertEqual(output.getvalue(), 'sample\n')
        self.assertEqual(w.aggregate_range.call_args.args, (dt.date(2025, 8, 3), dt.date(2025, 8, 3)))
        w.publish.assert_not_called()
        c.post.assert_not_called()

    def test_main_publishes_successful_days_by_default(self):
        c = Mock(cache={}, allow_write=True)
        w = Mock(day_ready=True)
        w.zone = vm.ZoneInfo('Europe/Berlin')
        w.aggregate_range.return_value = [(dt.date(2025, 1, 1), ['sample']), (dt.date(2025, 1, 2), ['sample'])]
        with patch.object(vm, 'read_config', return_value=CFG), patch.object(vm, 'Client', return_value=c) as make, patch.object(vm, 'Aggregator', return_value=w), contextlib.redirect_stdout(io.StringIO()) as output:
            vm.main(['--from', '2025', '1', '1', '--to', '2025', '1', '2'])
        self.assertTrue(make.call_args.kwargs['allow_write'])
        self.assertEqual(w.publish.call_count, 2)
        self.assertEqual(output.getvalue(), '')

    def test_main_default_publishes_and_stops_at_failed_publication(self):
        c = Mock(cache={}, allow_write=True)
        w = Mock(day_ready=True)
        w.zone = vm.ZoneInfo('Europe/Berlin')
        w.aggregate_range.return_value = [(dt.date(2025, 1, 1), []), (dt.date(2025, 1, 2), [])]
        w.publish.side_effect = RuntimeError('publish failed')
        with patch.object(vm, 'read_config', return_value=CFG), patch.object(vm, 'Client', return_value=c) as make, patch.object(vm, 'Aggregator', return_value=w), self.assertRaises(RuntimeError):
            vm.main(['--from', '2025', '1', '1', '--to', '2025', '1', '2'])
        self.assertTrue(make.call_args.kwargs['allow_write'])
        self.assertEqual(w.publish.call_count, 1)
        c.connection.close.assert_called_once()

    def test_main_failed_calculation_never_publishes(self):
        w = Mock()
        w.zone = vm.ZoneInfo('Europe/Berlin')
        w.aggregate_range.side_effect = ValueError('calculation failed')
        with patch.object(vm, 'read_config', return_value=CFG), patch.object(vm, 'Client'), patch.object(vm, 'Aggregator', return_value=w), self.assertRaises(ValueError):
            vm.main(['--today'])
        w.publish.assert_not_called()

    def test_main_skipped_future_day_does_not_publish(self):
        w = Mock(day_ready=False)
        w.zone = vm.ZoneInfo('Europe/Berlin')
        w.aggregate_range.return_value = [(dt.date(2100, 1, 1), [])]
        with patch.object(vm, 'read_config', return_value=CFG), patch.object(vm, 'Client'), patch.object(vm, 'Aggregator', return_value=w):
            vm.main(['--day', '2100', '01', '01'])
        w.publish.assert_not_called()

    def test_main_routes_maintenance_actions_without_calculation(self):
        for flags, action in [(['--detect'], 'detect_devices'),
                              (['--delete-aggregations'], 'delete_aggregations')]:
            c = Mock()
            with patch.object(vm, 'read_config', return_value=CFG), patch.object(vm, 'Client', return_value=c) as make, patch.object(vm, 'Aggregator') as worker, patch.object(vm, action, return_value={}) as handler, contextlib.redirect_stdout(io.StringIO()):
                vm.main(flags)
            self.assertEqual(make.call_args.kwargs['allow_write'], action == 'delete_aggregations')
            handler.assert_called_once_with(c)
            worker.assert_not_called()
            c.connection.close.assert_called_once()

    def test_zero_padded_month_is_still_supported(self):
        w = Mock()
        w.zone = vm.ZoneInfo('Europe/Berlin')
        w.aggregate_range.return_value = []
        with patch.object(vm, 'read_config', return_value=CFG), patch.object(vm, 'Client'), patch.object(vm, 'Aggregator', return_value=w):
            vm.main(['--dry-run', '--month', '2025', '08'])
        self.assertEqual(w.aggregate_range.call_args.args, (dt.date(2025, 8, 1), dt.date(2025, 8, 31)))

    def test_debug_config_enables_missing_source_notices(self):
        w = vm.Aggregator(dict(CFG, DEBUG='true'), Mock())
        w.day = dt.date(2025, 1, 1)
        with contextlib.redirect_stderr(io.StringIO()) as log:
            w.stage('pvEnergyDaily', '', [])
        self.assertIn('existing values retained', log.getvalue())

    def test_completion_time_without_debug_and_no_success_message_on_failure(self):
        cases = [(0.9, '00h 00m 00s'), (59.9, '00h 00m 59s'),
                 (60, '00h 01m 00s'), (3599.9, '00h 59m 59s'),
                 (3600, '01h 00m 00s'), (3661, '01h 01m 01s'),
                 (90061, '25h 01m 01s')]
        for elapsed, expected in cases:
            for flags in (['--day', '2025', '1', '1'], ['--dry-run', '--day', '2025', '1', '1']):
                for failed in (False, True):
                    w = Mock(day_ready=True)
                    w.zone = vm.ZoneInfo('Europe/Berlin')
                    if failed:
                        w.aggregate_range.side_effect = ValueError('calculation failed')
                    else:
                        w.aggregate_range.return_value = [(dt.date(2025, 1, 1), ['sample'])]
                    with patch.object(vm, 'read_config', return_value=CFG), patch.object(vm, 'Client'), patch.object(vm, 'Aggregator', return_value=w), patch.object(vm.time, 'perf_counter', side_effect=[100.0, 100.0 + elapsed]), contextlib.redirect_stderr(io.StringIO()) as log, contextlib.redirect_stdout(io.StringIO()) as output:
                        if failed:
                            with self.assertRaises(ValueError):
                                vm.main(flags)
                        else:
                            vm.main(flags)
                    if failed:
                        self.assertNotIn('Aggregation finished', log.getvalue())
                    else:
                        self.assertIn(f'[INFO] Aggregation finished in {expected}.', log.getvalue())
                        self.assertEqual(output.getvalue(), 'sample\n' if '--dry-run' in flags else '')


if __name__ == '__main__':
    unittest.main()
