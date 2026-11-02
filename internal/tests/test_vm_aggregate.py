"""Regression tests: calendar boundaries, integration and safe publication.

Run with Python 3. Bash >=4, jq and GNU date must be on PATH.
No network access or database writes are used.
"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "evcc-vm-aggregate.sh"
if not SCRIPT.exists():
    SCRIPT = Path(__file__).resolve().parents[2] / "scripts" / "evcc-vm-aggregate.sh"
BASH = shutil.which("bash")


def run(code, *, check=True):
    result = subprocess.run([BASH, "-c", 'source "$1"; ' + code, "test", str(SCRIPT)],
                            text=True, capture_output=True)
    if check and result.returncode:
        raise AssertionError(result.stderr + result.stdout)
    return result


def matrix(values, labels=None):
    return {"status": "success", "data": {"resultType": "matrix", "result": [
        {"metric": labels or {}, "values": values}]}}


class AggregationTests(unittest.TestCase):
    def test_local_calendar_days(self):
        result = run('''
            TIMEZONE=Europe/Berlin; SAMPLE_SECONDS=60; TARIFF_SECONDS=900; DRY_RUN=true
            aggregateEnergy(){ :; }; aggregateCost(){ :; }; aggregateStatistic(){ :; }
            aggregateSoc(){ :; }; tariffMatrix(){ echo null; }
            HOME_BATTERY=true; DYNAMIC_TARIFF=true
            for d in 2025-03-29 2025-03-30 2025-03-31 2025-10-25 2025-10-26 2025-10-27; do
                aggregateDay "$d" || exit 1
                echo "$DAY_DATE $((DAY_CUTOFF-DAY_START)) $(TZ="$TIMEZONE" date -d @$DAY_START +%T)"
            done
        ''')
        self.assertEqual(result.stdout.splitlines(), [
            "2025-03-29 86400 00:00:00", "2025-03-30 82800 00:00:00",
            "2025-03-31 86400 00:00:00", "2025-10-25 86400 00:00:00",
            "2025-10-26 90000 00:00:00", "2025-10-27 86400 00:00:00"])

    def test_calendar_iteration_across_year_and_leap_day(self):
        result = run('aggregateDay(){ echo "$1"; }; aggregateRange 2024-02-28 2024-03-01; aggregateRange 2024-12-31 2025-01-01')
        self.assertEqual(result.stdout.splitlines(), ["2024-02-28", "2024-02-29", "2024-03-01", "2024-12-31", "2025-01-01"])
        self.assertNotEqual(run('aggregateRange 2025-02-02 2025-02-01', check=False).returncode, 0)

    def reduce(self, power, prices=None, sign=1, stop=240):
        # JSON is passed via quoted temporary files, never shell interpolation.
        with tempfile.TemporaryDirectory() as temp:
            p, t = Path(temp)/"power.json", Path(temp)/"prices.json"
            p.write_text(json.dumps(power)); t.write_text(json.dumps(prices))
            result = run(f'DAY_START=0; SAMPLE_END={stop}; SAMPLE_SECONDS=60; TARIFF_SECONDS=120; '
                         f'reducePower "$(cat {p})" "$(cat {t})" {sign}')
        return json.loads(result.stdout)["data"]["result"]

    def test_trapezoid_and_no_extrapolation(self):
        values = self.reduce(matrix([[60,"600"],[120,"600"],[180,"600"],[240,"600"]]))
        self.assertAlmostEqual(float(values[0]["value"][1]), 30)

    def test_missing_bins_are_zero_not_bridged(self):
        values = self.reduce(matrix([[60,"600"],[180,"600"]]), stop=180)
        self.assertAlmostEqual(float(values[0]["value"][1]), 10)

    def test_large_device_responses_do_not_use_command_arguments(self):
        power = {"status":"success", "data":{"resultType":"matrix", "result":[
            {"metric":{"title":f"Device {device}"},
             "values":[[60*(i+1),"600"] for i in range(1440)]}
            for device in range(12)]}}
        self.assertGreater(len(json.dumps(power)), 131072)
        values = self.reduce(power, stop=86400)
        self.assertEqual(len(values),12)
        for result in values:
            self.assertAlmostEqual(float(result['value'][1]),14390)

        # Exercise the same transport for a large tariff response as well.
        prices = matrix([[120*(i+1),"0.1"] for i in range(14400)])
        self.assertGreater(len(json.dumps(prices)),131072)
        values = self.reduce(power, prices, stop=86400)
        for result in values:
            self.assertAlmostEqual(float(result['value'][1]),1.439)

    def test_price_boundary_and_export_sign(self):
        power = matrix([[60,"-600"],[120,"-600"],[180,"-600"],[240,"-600"]])
        prices = matrix([[120,"0.1"],[240,"0.3"]])
        values = self.reduce(power, prices, sign=-1)
        self.assertAlmostEqual(float(values[0]["value"][1]), 0.005)

    def test_no_missing_tariff_silently_becomes_zero(self):
        self.assertEqual(self.reduce(matrix([[60,"600"],[120,"600"]]), matrix([]), stop=120), [])

    def test_zero_energy_needs_no_tariff(self):
        values = self.reduce(matrix([[60,"0"],[120,"0"]]), matrix([]), stop=120)
        self.assertEqual(float(values[0]["value"][1]), 0)

    def test_partial_price_omits_whole_device_but_keeps_valid_device(self):
        power = matrix([[60,"600"],[120,"600"],[180,"600"],[240,"600"]], {"vehicle":"missing"})
        power["data"]["result"] += matrix([[60,"600"],[120,"0"],[180,"0"],[240,"0"]], {"vehicle":"valid"})["data"]["result"]
        values = self.reduce(power, matrix([[120,"0.1"]]))
        self.assertEqual([v["metric"]["vehicle"] for v in values], ["valid"])
        self.assertAlmostEqual(float(values[0]["value"][1]), 0.0005)

    def test_zero_and_negative_tariffs_remain_valid(self):
        for price, expected in [("0",0),("-0.1",-0.001)]:
            values = self.reduce(matrix([[60,"600"],[120,"600"]]), matrix([[120,price]]), stop=120)
            self.assertAlmostEqual(float(values[0]["value"][1]), expected)

    def test_missing_cost_is_registered_for_removal(self):
        with tempfile.TemporaryDirectory() as temp:
            f, out = Path(temp)/"power", Path(temp)/"out"
            f.write_text(json.dumps(matrix([[60,"600"],[120,"600"]])))
            result = run(f'''DAY_START=0; SAMPLE_END=120; SAMPLE_SECONDS=60; TARIFF_SECONDS=120
                DAY_DATE=2023-03-26; DAY_OUTPUT={out}; DAY_METRICS=()
                powerMatrix(){{ cat {f}; }}
                aggregateCost test raw signed "" 1 '{{"data":{{"result":[]}}}}' || exit 1
                printf '%s\\n' "${{DAY_METRICS[@]}}"
            ''')
            self.assertEqual(result.stdout.strip(), "test")
            self.assertFalse(out.exists())
            self.assertIn("energy without tariff", result.stderr)

    def test_scalar_and_device_cardinality_validation(self):
        for tag, rows in [("", [{"metric":{},"value":[0,"1"]}]*2),
                          ("vehicle", [{"metric":{},"value":[0,"1"]}]),
                          ("vehicle", [{"metric":{"vehicle":"A"},"value":[0,"1"]}]*2),
                          ("", [{"metric":{},"value":[0,"NaN"]}])]:
            with tempfile.NamedTemporaryFile(mode="w") as f:
                json.dump({"data":{"result":rows}}, f); f.flush()
                result = run(f'DAY_DATE=2025-01-01; DAY_START=0; DAY_OUTPUT=/dev/null; '
                             f'stageResult test "{tag}" "$(cat {f.name})"', check=False)
            self.assertNotEqual(result.returncode, 0)

    def test_prometheus_label_escaping_and_midnight_timestamp(self):
        with tempfile.TemporaryDirectory() as temp:
            f, out = Path(temp)/"in.json", Path(temp)/"out.txt"
            f.write_text(json.dumps({"data":{"result":[{"metric":{"vehicle":'A "quoted" \\ name'},"value":[123,"4.2"]}]}}))
            run(f'DAY_DATE=2025-10-26; DAY_START=1761429600; DAY_OUTPUT={out}; '
                f'stageResult test vehicle "$(cat {f})"')
            line = out.read_text()
            self.assertIn('vehicle="A \\"quoted\\" \\\\ name"', line)
            self.assertTrue(line.endswith(' 1761429600000\n'))

    def test_day_error_before_publish_performs_no_writes(self):
        result = run('''
            TIMEZONE=Europe/Berlin; SAMPLE_SECONDS=60; TARIFF_SECONDS=900; DRY_RUN=false
            aggregateEnergy(){ return 1; }
            vmRequest(){ echo UNEXPECTED_WRITE; return 99; }
            aggregateDay 2025-06-01
            status=$?; rm -f "$DAY_OUTPUT"; exit "$status"
        ''', check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("UNEXPECTED_WRITE", result.stdout)

    def test_http_and_api_failures_are_errors(self):
        for body in ["{\"status\":\"error\",\"error\":\"test\"}", "invalid JSON"]:
            with tempfile.NamedTemporaryFile(mode="w") as f:
                f.write(body); f.flush()
                result = run(f'vmRequest(){{ cat {f.name}; }}; queryVM /api/v1/query', check=False)
            self.assertNotEqual(result.returncode, 0)
        self.assertNotEqual(run('vmRequest(){ return 22; }; queryVM /api/v1/query', check=False).returncode, 0)

    def test_cli_ranges_and_leading_zeroes(self):
        for flags, expected in [('--year 2024', '2024-01-01 2024-12-31'),
                                ('--month 2025 03', '2025-03-01 2025-03-31'),
                                ('--day 2025 08 09', '2025-08-09 2025-08-09'),
                                ('--from 2025 10 26 --to 2025 10 27', '2025-10-26 2025-10-27')]:
            result = run('cat(){ command cat "$@" 2>/dev/null || echo Europe/Berlin; }; aggregateRange(){ echo "$1 $2"; }; main '+flags+' --dry-run')
            self.assertEqual(result.stdout.strip(), expected)
        self.assertNotEqual(run('validateDate 2025 02 29', check=False).returncode, 0)

    def test_soc_raw_filters_keep_short_extrema(self):
        raw = {"metric":{"__name__":"batterySoc_value","id":""},
               "timestamps":[0, 100, 101, 102, 103, 104, 105, 106, 1000],
               "values":[99, 15, 100, 65535, 0, -1, 101, 14, 1]}
        with tempfile.TemporaryDirectory() as temp:
            f, out = Path(temp)/'raw.json', Path(temp)/'out'
            f.write_text(json.dumps(raw))
            run(f'DAY_START=0; DAY_CUTOFF=1; DAY_DATE=2025-01-01; DAY_OUTPUT={out}; '
                f'vmRequest(){{ cat {f}; }}; aggregateSoc')
            lines = out.read_text().splitlines()
            self.assertEqual(len(lines),2)
            self.assertTrue(lines[0].endswith(' 100 0'))
            self.assertTrue(lines[1].endswith(' 14 0'))

    def test_failed_delete_never_imports(self):
        result = run('''
            TIMEZONE=Europe/Berlin; SAMPLE_SECONDS=60; TARIFF_SECONDS=900; DRY_RUN=false
            aggregateEnergy(){ DAY_METRICS+=("$1"); echo test >> "$DAY_OUTPUT"; }
            aggregateCost(){ :; }; aggregateStatistic(){ :; }; aggregateSoc(){ :; }
            tariffMatrix(){ echo null; }
            HOME_BATTERY=true; DYNAMIC_TARIFF=true
            vmRequest(){ echo "$1" >&2; return 22; }
            aggregateDay 2025-06-01
            status=$?; rm -f "$DAY_OUTPUT"; exit "$status"
        ''', check=False)
        self.assertNotEqual(result.returncode,0)
        self.assertIn('/api/v1/admin/tsdb/delete_series',result.stderr)
        self.assertNotIn('/api/v1/import/prometheus',result.stderr)

    def test_partial_tariff_interval_no_lookahead(self):
        result = run('''
            DAY_START=0; SAMPLE_END=180; TARIFF_SECONDS=120
            queryVM(){
                case "$*" in
                    *100y*) echo '{"data":{"result":[{"value":[0,"0.1"]}]}}';;
                    *query_range*) echo '{"status":"success","data":{"result":[{"metric":{},"values":[[120,"0.2"]]}]}}';;
                    *)
                        [[ "$*" == *"[60s] offset 1ms"* && "$*" == *"time=180"* ]] || return 1
                        echo '{"data":{"result":[{"value":[180,"0.3"]}]}}';;
                esac
            }
            tariffMatrix tariff last
        ''')
        self.assertEqual(json.loads(result.stdout)['data']['result'][0]['values'], [[120,'0.2'],[240,'0.3']])


if __name__ == "__main__":
    unittest.main()
