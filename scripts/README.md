# Aggregation Script

At some point, the Raspberry PI was completely overwhelmed with compiling all data live, and the monthly and especially yearly dashboards only ran into timeouts. Therefore, aggregation was necessary. This is done by the Bash shell script `evcc-vm-aggregate.sh`.

This requires a proper [installation of Victoria Metrics](../vm-installation.md).

## Installation

1. Download the script [`evcc-vm-aggregate.sh`](./evcc-vm-aggregate.sh) and the configuration file [`evcc-vm-aggregate.conf`](./evcc-vm-aggregate.conf) and copy them to a Linux system. Ideally, this is the system on which Victoria Metrics is running. If this is not possible (e.g., HAOS), the script can also be executed remotely from another Linux system.

2. Install the UNIX CLI tools `curl` and  `jq`. On Debian-based Linux systems, e.g., with `apt install curl jq`.

3. Adjust the configuration file [`evcc-vm-aggregate.conf`](./evcc-vm-aggregate.conf) with the appropriate values. The values are annotated with explanatory comments. Please review and adjust all values as needed.

4. Adjust the permissions for the script so that it becomes executable: `chmod +x evcc-vm-aggregate.sh`

5. Create in initial aggregation of your existing data in VM starting from the first date of data available. E.g. if the data starts of March 21, 2023, run this command.
   ```bash
   ./evcc-vm-aggregate.sh --from 2023 3 21
   ```
   This will take some time.

6. Configure the following scheduled executions using `crontab -e`:
   ```
   5 0 * * * <PATH_TO_SCRIPT>/evcc-vm-aggregate.sh --yesterday >> /var/log/evcc-grafana-dashboards.log 2>&1
   0 * * * * <PATH_TO_SCRIPT>/evcc-vm-aggregate.sh --today >> /var/log/evcc-grafana-dashboards.log 2>&1
   ```
   Replace `<PATH_TO_SCRIPT>` with the path where the script was saved.

   This will aggregate yesterday's data every night and the current day's data every full hour. The output is logged to the file `/var/log/evcc-grafana-dashboards.log`.

7. Create and set the permissions of the log file:
   ```bash
   sudo touch /var/log/evcc-grafana-dashboards.log
   sudo chown <USERNAME> /var/log/evcc-grafana-dashboards.log
   ```
   Replace `<USERNAME>` with the login name of the user under which the command `crontab -e` was executed in the previous step.


## Usage

| Parameter                    | Description                                                                              |
| ---------------------------- | ---------------------------------------------------------------------------------------- |
| `--day <year> <month> <day>` | Aggregate the data for the specified day and month                                       |
| `--month <year> <month>`     | Aggregate all data for all days of the specified month.                                   |
| `--year <year>`              | Aggregate all data for all days and months of the specified year                          |
| `--from <year> <month> <day> [--to <year> <month> <day>]` | Aggregate all data from a specific start date to an end date. If no end date is specified with `--to`, the end date is the current day. |
| `--today`                    | Aggregate today's complete sample intervals.                                            |
| `--yesterday`                | Aggregate yesterday's local calendar day.                                               |
| `--dry-run`                  | Calculate and print Prometheus samples without deleting or importing data. Combine with a date selector. |
| `--delete-aggregations`      | Delete all aggregated metrics after explicit confirmation. Cannot be combined with `--dry-run`. |
| `--debug`                    | Enable debug output for troubleshooting.                                                 |


### Examples

Aggregate the data of today:
```bash
evcc-vm-aggregate.sh --today
```

Aggregate the data of all days in November 2025:
```bash
evcc-vm-aggregate.sh --month 2025 11
```

Aggregate the data of all days of the year 2024:
```bash
evcc-vm-aggregate.sh --year 2024
```

Aggregate the data of July 16, 2024:
```bash
evcc-vm-aggregate.sh --day 2024 7 16
```

Aggregate the data starting from March 6, 2023 until the current day:
```bash
evcc-vm-aggregate.sh --from 2023 3 6
```

Aggregate the data starting from March 6, 2023 to February 15, 2025:
```bash
evcc-vm-aggregate.sh --from 2023 3 6 --to 2025 2 15
```

Delete all aggregated data from the Victoria Metrics database:
```bash
evcc-vm-aggregate.sh --delete-aggregations
```
## Additional daily statistics

The script also produces the following daily aggregates. Like the other daily metrics, they carry `year`, `month` and `day` labels. Monthly and yearly statistics are calculated from daily values rather than stored separately.

| Metric | Meaning | Additional label |
| --- | --- | --- |
| `pvEnergyForecastDaily` | Daily forecast solar energy in Wh, integrated from `tariffSolar_value` (W) | — |
| `vehicleOdometerMaxDaily` | Maximum daily vehicle odometer reading | `vehicle` |
| `vehicleEnergyDaily` | Daily vehicle charging energy in Wh | `vehicle` |
| `potentialHomeDailyPrice` | Hypothetical home energy cost at the grid tariff | — |
| `potentialLoadpointDailyPrice` | Hypothetical charging cost at the grid tariff | `loadpoint` |
| `energyDischargeDailyPrice` | Battery discharge valued at the grid tariff | — |
| `energyChargeDailyPrice` | Signed battery charging valuation at the feed-in tariff | — |
| `vehicleChargeDailyPrice` | Vehicle charging cost using the charging tariff | `vehicle` |
| `potentialVehicleChargeDailyPrice` | Hypothetical vehicle charging cost at the grid tariff | `vehicle` |

Costs are in the currency used by the tariffs. Battery charging valuation retains the legacy Influx sign: negative charging power at a positive feed-in tariff produces a negative value. Vehicle charging prices retain the legacy average across loadpoints; simultaneous charging at different tariffs is therefore only approximated.

Every metric written by `aggregateDay()` must also be included in `AGGREGATED_METRICS`, which is used by `--delete-aggregations`.

The solar forecast uses the same trapezoidal integration and positive power limits
as measured PV energy, but treats `tariffSolar_value` as a sparse held gauge.
At each sample boundary, the latest raw value strictly before the boundary is
carried forward for up to 24 hours, including across midnight. Zero is a valid
forecast. Negative values and values at or above `PEAK_POWER_LIMIT` are rejected
after selecting the latest update, so an invalid update cannot revive an older
valid value. Missing, invalid or expired intervals cause the daily forecast to
be omitted with a warning; any previous aggregate is retained. They are never
filled with synthetic zero power. This differs from measured meter data.
It integrates the forecast power recorded throughout the day, rather than a fixed forecast issued at a particular time. For today, it
covers only elapsed complete sample intervals, not the remaining day's forecast.
If no usable forecast samples exist, no forecast aggregate is written. After
upgrading from the zero-filled forecast implementation, recalculate previously
aggregated dates (for example October and November) to replace understated values.

## Daily boundaries and calculation

All date selectors iterate local calendar dates in `TIMEZONE`, including year,
month and date-range selections. Each day runs from local midnight to the next
local midnight. Daylight-saving transitions therefore produce 23- or 25-hour
days; the next day is never obtained by adding 86400 seconds. One result is stored
at that day's midnight with matching `year`, `month` and `day` labels.

Power queries calculate the arithmetic mean of valid **raw samples** in each
`ENERGY_SAMPLE_INTERVAL`, including zero readings. Missing intervals within an
existing series are filled with zero. Energy is the trapezoidal integral between
successive interval means, following the legacy Influx calculation rather than
integrating resampled instantaneous power. No area is extrapolated before the
first or after the last interval mean. This deliberately retains the legacy
endpoint convention; for a constant power over a full day, the integrated span
is one sample interval shorter than the calendar day.

Positive energy filters use `0 <= power < PEAK_POWER_LIMIT`; negative energy
filters use `-PEAK_POWER_LIMIT < power <= 0` and reverse the sign for exported
energy and battery charging energy. Signed cost calculations retain the power
sign. The negative peak guard is stricter than the old Influx upper-only filter.

Costs use the same interval means and trapezoids, partitioned at tariff interval
boundaries. Grid/feed-in tariffs use the last raw tariff in each interval with
the preceding tariff carried forward. Charging tariffs use raw interval means,
retaining the legacy global approximation across simultaneous loadpoints.
An initial tariff is looked up in up to 100 years of retained history; a missing
price is only required for nonzero energy segments. If such a segment has no
price, the entire daily cost for that device (or scalar) is omitted with a
warning; other devices, costs and energy metrics continue. Previous daily costs
for omitted series are removed when publishing the day, rather than retained
as apparently recalculated values. Zero energy requires no tariff and costs zero. Tariff statistics use raw daily samples.

`ENERGY_SAMPLE_INTERVAL` must divide an hour and be at most one hour.
`TARIFF_PRICE_INTERVAL` must be a multiple of the sample interval. Supported
duration syntax is a positive integer followed by `s`, `m`, `h` or `d`.
Today's calculations stop at the last complete sample interval and never fill
the remaining future day with synthetic zero power. Future dates are skipped.

Battery SoC extrema use raw samples of `batterySoc_value{id=""}`, without a
resampling subquery. Values outside 0–100% are discarded before taking extrema;
the minimum additionally excludes zero, matching the legacy read-error guard.
This raw-data read requires access to VictoriaMetrics `/api/v1/export`.
`HOME_BATTERY=false` skips battery outputs; `DYNAMIC_TARIFF=false` skips tariff
history statistics (costs still require the configured tariffs).

## Validation and publication

Use a read-only calculation before replacing existing aggregates:

```bash
./evcc-vm-aggregate.sh --day 2025 10 26 --dry-run > /tmp/evcc-2025-10-26.prom
```

Normal progress output is one line per day, followed on success by a completion
message reporting elapsed hours, minutes and seconds, also without debug enabled. Per-metric
progress and missing-source notices are shown only with `--debug` (or
`DEBUG="true"` in the configuration). Errors remain visible in normal mode.
Logs go to stderr; stdout contains only the generated samples. The script keeps
the existing Bash, GNU date, curl and jq dependencies. Configured `VM_USER` and
`VM_PASSWORD` are used for HTTP basic authentication.

All results for a day are calculated and checked before that day is published.
Unexpected multiple scalar results, duplicate/missing device labels, non-finite
values, API errors and failed HTTP requests stop the run with a nonzero exit.
Metrics without source data are logged and left unchanged rather than replaced
with invented zero totals. Publication replaces all device series for each
successfully calculated metric/date, then imports the staged daily samples.
Deletion and import are separate HTTP requests, not a database transaction:
an import failure after deletion requires rerunning that day. Runs modifying
the same dates must not overlap.

The new algorithm does not repair existing aggregates until explicitly run for
those dates. Back up affected data before recalculation. A full historical run
makes more HTTP requests than the previous monthly query implementation.

Regression tests (no database access) can be run from the repository root with
Python 3, Bash >=4, GNU date and jq on PATH:

```bash
python3 internal/tests/test_vm_aggregate.py
```

### Python port

`evcc-vm-aggregate.py` ports the current Bash calculations to Python 3.9+ using
only the standard library and an installed IANA timezone database. The Bash
script remains the numerical reference. Date calculations publish by default,
just like Bash. Use `--dry-run` to print calculated samples without changing
VictoriaMetrics. Dry runs and device discovery use a read-only HTTP client.
Merely installing or viewing help does not run a calculation or change cron
jobs. The existing `.conf` is shared with Bash.

```bash
python3 scripts/evcc-vm-aggregate.py --dry-run --day 2025 3 30
python3 scripts/evcc-vm-aggregate.py --dry-run --month 2026 1 --debug
python3 scripts/evcc-vm-aggregate.py --dry-run --from 2025 1 1 --to 2025 12 31
```

The default configuration is the adjacent `evcc-vm-aggregate.conf`; use
`--config /path/to/evcc-vm-aggregate.conf` to select another file. It accepts the
simple assignments in the shipped configuration, including the existing
`TIMEZONE="\`cat /etc/timezone\`"` idiom. It does not execute arbitrary shell
configuration expressions. Explicit timezone names such as `Europe/Berlin`
work on systems without `/etc/timezone`. The date selectors `--today`,
`--yesterday`, `--day`, `--month`, `--year`, and `--from`/`--to` are supported.
Choose one date selector or one maintenance action. `--detect` is always
read-only. `--delete-aggregations` requires an interactive `YES` confirmation
and cannot be combined with `--dry-run`. A date selector without `--dry-run`
calculates and publishes the selected dates.

The port preserves raw-sample interval queries, filtering, trapezoidal
integration without edge extrapolation, tariff carry-forward and missing-price
omissions, sparse forecast completeness checks, raw SoC extrema, device labels,
and local day boundaries. Daily responses and prepared interval energies are
reused within each day; power matrices and raw SoC samples are additionally
reused within bounded calendar chunks. HTTP connections are reused. Output
numeric formatting can differ from Bash,
so comparisons parse numbers rather than compare text. Logs go to stderr and
Prometheus samples to stdout; a day's output is staged until its calculations
finish. Missing source series remain absent. `--debug`, or `DEBUG="true"` in
the configuration, prints per-metric progress, missing-source notices and final
HTTP request counts/timings to stderr.

Both scripts always report elapsed time in hours, minutes and whole seconds,
for example `Aggregation finished in 02h 03m 04s.`, to stderr after a successful
aggregation, including dry runs. Hours do not wrap after 24. Failed runs do not
print this success message. JSON profiles retain numeric seconds and their
existing precision.

Run the offline checks with:

```bash
python3 internal/tests/test_vm_python.py
```

The original Bash/Python parity check used
`internal/tests/compare_vm_python.py`, which records and replays Bash query
responses. That legacy harness applies to the pre-optimization port: the current
port deliberately uses different query ranges and defers historical tariff
queries, so it no longer has the same request set. Use the stored-value
comparator below for current validation.

Validation on 22 November 2026 on the `home` aarch64 host (Python 3.13.5):
all 228 numeric samples across eight completed days matched Bash exactly,
with identical series identities and timestamps. Dates: 2023-03-26,
2025-01-15, 2025-03-30, 2025-06-01, 2025-10-26, 2025-10-27, 2026-01-01,
and 2026-11-20. Missing historical forecast data and a missing vehicle tariff
were omitted by both versions. The 18 offline checks also passed.
Cached-response processing took 30.04 seconds for Bash and 3.93 seconds for
Python in total (7.65x); request counts fell from 32 to 27 per day. This is a
sample-based parity check and processing benchmark, not a full-history audit
or an end-to-end production benchmark. VM values were not changed.

For routine validation, compare Python dry runs directly with already stored
VictoriaMetrics daily samples, without executing Bash:

```bash
python3 internal/tests/compare_vm_stored.py \
  --python-script scripts/evcc-vm-aggregate.py \
  --config scripts/evcc-vm-aggregate.conf \
  --output /tmp/evcc-python-stored-comparison \
  --month 2026 1 2025-03-30 2025-10-26
```

The stored-value comparator reads raw aggregate samples through `/api/v1/export`
and compares full metric/label identities, timestamps and numeric values.
Missing stored `pvEnergyForecastDaily` samples are reported separately because
forecast aggregation is incomplete; existing forecast samples are still checked
against the same 1% tolerance. Missing non-forecast references, stored series
absent from the dry run, conflicting stored samples and numeric failures remain
visible and produce a nonzero exit status. A stored value of zero passes only
if the new value is also zero. Use completed days to avoid comparing a partial
stored total with a later cutoff. `--reuse-python` can repeat the reference read
using the dry-run output already saved in the output directory; the script hash
and timezone must match. The recorded files and detailed `summary.json` allow
inspection without further database requests. No aggregate values are modified.

Stored-reference validation on 22 November 2026 covered January 2026 and seven
additional days (38 days total). All 1,237 comparable samples passed the 1%
threshold; maximum relative difference was 9.96e-13 (rounding scale). There were
35 missing forecast references, handled separately as expected. A further 113
stored series were absent from the dry run; all stored values in these series
were zero. A read-only source audit found no raw source samples for 112 of these
series; the remaining series was a legacy `extEnergyDaily` sample without a
`title` label, whereas the Python port emits titled device series. Seven stored
zero series on 26 October 2025 also had two distinct sample timestamps within
the 25-hour day. These coverage/timestamp findings remain in the detailed report
and cause the comparator to exit nonzero despite the passing numeric checks.
They were not silently treated as matches, and no VM values were modified.


### Python performance controls

Multi-day CLI runs now group power queries and raw SoC exports into seven-day
calendar chunks by default. Calculations still split at each local midnight;
23/25-hour days are preserved, and integration never bridges adjacent days.
Devices without samples on an individual day remain absent. Today's partial
period runs separately, and a power query falls back to the daily range when
a timezone transition makes its sample grid incompatible with the chunk grid.
Tariff intervals and daily statistics continue to be queried per day.

`--batch-days 1` disables range batching; `--batch-days N` accepts 1–31 days.
Larger chunks can use more memory and are not assumed to be faster. Prepared
trapezoidal interval energies are reused for energy and cost calculations,
without changing summation order. Historical tariff defaults are loaded only
when the day's tariff bins actually require them; missing defaults remain
missing, and negative/zero prices retain their meaning. No concurrency or
additional third-party dependencies were introduced.

`--profile /path/to/profile.json` records each successful HTTP request's query
parameters, response size and separate HTTP/read and JSON decode timings, plus
aggregate elapsed time and cache-hit counts. Authentication headers are never
included. Without this option, only timing counters are retained; query details
do not accumulate over long historical runs.

```bash
python3 scripts/evcc-vm-aggregate.py --dry-run --month 2026 1 \
  --profile /tmp/evcc-python-profile.json
python3 scripts/evcc-vm-aggregate.py --dry-run --month 2026 1 --batch-days 1
```

The stored-value comparator accepts the same `--batch-days` and `--profile`
options. Its profile excludes the requests used to retrieve stored reference
aggregates. `internal/tests/benchmark_vm_python.py` can compare a saved,
instrumented pre-optimization Python version with daily and weekly optimized
runs in alternating order. Every run must produce exactly identical parsed
samples; it never invokes the Bash script. Use completed historical periods.

Optimization validation on 22 November 2026 (same aarch64 host, Python 3.13.5):
36 offline checks passed locally and on the target host. All 1,525 comparable
stored values across 49 completed days passed the 1% tolerance, with maximum
relative difference 9.96e-13. The output files for the 38 previously checked days
were byte-identical to the saved pre-optimization dry runs. The broader sample
still reports reference coverage issues separately: 46 missing forecast
references, 165 stored series absent from the dry run, and seven stored timestamp
conflicts. These are not counted as numeric matches or silently repaired.

A direct read-only benchmark for 1–7 January 2026 ran each variant twice in
alternating order. All 246 results were exactly equal in every run:

| Python variant | Median elapsed time | HTTP requests |
| --- | ---: | ---: |
| Before optimization | 23.12 s | 189 |
| Optimized, daily queries | 4.08 s | 178 |
| Optimized, seven-day chunks | 4.02 s | 82 |

This sample was 5.75x faster overall. Avoiding unnecessary historical tariff
lookups delivered most of the time saving; weekly batching primarily reduced
request count (57%) and had only a small additional time benefit here. Timings
include real VM requests and output generation, not replayed responses. They
are sample measurements, not a promised full-history speedup. VM data, installed
production files and cron were left unchanged.


### Python publication and maintenance

Preview with `--dry-run`; omit it to publish selected dates:

```bash
python3 scripts/evcc-vm-aggregate.py --dry-run --day 2026 1 1
python3 scripts/evcc-vm-aggregate.py --day 2026 1 1
python3 scripts/evcc-vm-aggregate.py --yesterday
```

Every day's calculations and validation must complete before any mutation.
Publication deletes the existing series for each successfully calculated
metric/date (matching `year`, `month`, `day`, across all device labels), then
imports the staged Prometheus samples. Missing source data and incomplete
forecasts retain prior aggregates. Missing tariffs for nonzero energy omit the
affected daily cost series; publication removes prior costs for that entire
metric/day and imports only the valid device results. Thus omitted costs are
not left behind as apparently recalculated values. All future days and days
with fewer than two complete sample intervals are skipped without publication.

A single shared registry contains every daily output metric and limits the
full-delete operation. The raw source metrics are not part of this registry.
The client permits POST only to the documented delete-series and Prometheus
import endpoints, and never retries a failed mutation automatically. Deletion
and import are **not a transaction**: a failure after deletion can leave missing
values; the run stops, reports the affected date, and requires a deliberate
rerun after fixing the cause. Back up affected aggregates before a production
recalculation. Avoid overlapping write runs, including the existing Bash cron.

```bash
python3 scripts/evcc-vm-aggregate.py --detect
python3 scripts/evcc-vm-aggregate.py --delete-aggregations
```

`--detect` returns JSON arrays of vehicles, loadpoints, EXT/AUX device titles
and consumer titles. It reads retained source-series metadata from the Unix
epoch until now, removes empty/duplicate names, and sorts the results. It
includes historical devices and does not modify configuration. Bash advertised
`--detect` but did not implement its action; Python implements actual discovery.

`--delete-aggregations` deletes all registered daily aggregate series for all
retained dates. It accepts only an exact `YES` on stdin, then waits three seconds
before deleting; EOF or any other reply cancels without mutation. It cannot be
combined with date selection, `--detect`, or `--dry-run`. This also removes
aggregates for dates whose raw source data may no longer be retained.

The additional publication tests use a simulated client, never a live database:

```bash
python3 internal/tests/test_vm_publication.py
```

API wire formats were checked against the
[VictoriaMetrics API examples](https://docs.victoriametrics.com/victoriametrics/url-examples/).
The implementation has not replaced the installed Bash script or its cron jobs.
Live verification remains limited to read-only discovery and dry runs; write and
delete behavior is covered by offline tests, not a live production write test.

Completion checks on 22 November 2026: 59 offline tests passed locally and on
the Pi, including date replacement scope, device labels/UTF-8, missing-tariff
cleanup, dry-run write rejection, exact deletion confirmation, failure handling,
future-day skipping, and leading-zero dates. Live read-only discovery was checked
against historical metadata as well as currently active devices. A seven-day
dry run produced the same 246 samples as the previously validated port. No live
publication or deletion was performed; those paths were tested with simulated
clients only. Installation and cron are unchanged.
