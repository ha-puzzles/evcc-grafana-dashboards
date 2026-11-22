"""Offline tests for stored-aggregate comparison classifications."""
import importlib.util
from pathlib import Path
import unittest
import re

spec = importlib.util.spec_from_file_location('stored', Path(__file__).with_name('compare_vm_stored.py'))
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


class StoredTests(unittest.TestCase):
    def test_all_registered_metric_names_are_queried(self):
        scripts = Path(__file__).resolve().parents[2] / 'scripts'
        bash = (scripts / 'evcc-vm-aggregate.sh').read_text()
        registry = bash.split('AGGREGATED_METRICS=(', 1)[1].split(')', 1)[0]
        expected = sorted(re.findall(r'"(\w+)"', registry))
        self.assertEqual(m.metric_names(scripts / 'evcc-vm-aggregate.py'), expected)

    def key(self, name='homeEnergyDaily'):
        return m.identity(name, {'day': '2025-01-01'})

    def test_missing_forecast_is_optional_but_existing_forecast_is_checked(self):
        k = self.key('pvEnergyForecastDaily')
        result = m.compare({}, {k: (1, 0)})
        self.assertEqual(len(result['missing_forecast_reference']), 1)
        self.assertEqual(result['missing_stored'], [])
        self.assertEqual(len(m.compare({k: (1, 0)}, {k: (2, 0)})['failures']), 1)

    def test_zero_reference_and_timestamp_mismatch(self):
        k = self.key()
        self.assertEqual(m.compare({k: (0, 0)}, {k: (0, 0)})['exact'], 1)
        self.assertEqual(len(m.compare({k: (0, 0)}, {k: (0.001, 0)})['failures']), 1)
        self.assertEqual(len(m.compare({k: (1, 0)}, {k: (1, 1)})['failures']), 1)

    def test_negative_reference_relative_tolerance(self):
        k = self.key()
        self.assertEqual(m.compare({k: (-10, 0)}, {k: (-10.05, 0)})['failures'], [])
        self.assertEqual(len(m.compare({k: (-10, 0)}, {k: (-10.2, 0)})['failures']), 1)

    def test_conflicting_stored_values_are_not_silently_accepted(self):
        rows = [{'metric': {'__name__': 'homeEnergyDaily'}, 'values': [1, 2], 'timestamps': [0, 0]}]
        _, issues = m.stored_samples(rows, 0, 1, float)
        self.assertEqual(len(issues), 1)

    def test_label_escaping_and_order(self):
        sample = m.parse_samples(['extEnergyDaily{day="2025-01-01",title="A\\\"\\nü"} 2 0'])
        self.assertIn(m.identity('extEnergyDaily', {'title': 'A"\nü', 'day': '2025-01-01'}), sample)


if __name__ == '__main__':
    unittest.main()
