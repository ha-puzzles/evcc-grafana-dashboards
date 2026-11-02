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

Normal progress output is one line per day. Per-metric progress, missing-source
notices and the final completion message are shown only with `--debug` (or
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
