# Aggregation Script

At some point, the Raspberry PI was completely overwhelmed with compiling all data live, and the monthly and especially yearly dashboards only ran into timeouts. Therefore, aggregation was necessary. This is done by the Python script `evcc-vm-aggregate.py`.

This requires a proper [installation of Victoria Metrics](../vm-installation.md).

## Installation

1. Download the script [`evcc-vm-aggregate.py`](./evcc-vm-aggregate.py) and the configuration file [`evcc-vm-aggregate.conf`](./evcc-vm-aggregate.conf) and copy them to a system with Python 3.9 or newer. Ideally, this is the system on which Victoria Metrics is running. If this is not possible (e.g., HAOS), the script can also be executed remotely from another Linux system.

2. Install Python 3.9 or newer and an IANA timezone database. The script uses only the Python standard library; curl, jq, GNU date and Bash are not required. On Debian-based systems, install them with `apt install python3 tzdata`. On Windows, install the timezone database with `python -m pip install tzdata` if it is unavailable.

3. Adjust the configuration file [`evcc-vm-aggregate.conf`](./evcc-vm-aggregate.conf) with the appropriate values. The values are annotated with explanatory comments. Please review and adjust all values as needed.

4. Make the script executable with `chmod +x evcc-vm-aggregate.py`, then check the installation with `./evcc-vm-aggregate.py --help`. Set `TIMEZONE` in the configuration to an explicit IANA name such as `Europe/Berlin` for portability.

5. Create in initial aggregation of your existing data in VM starting from the first date of data available. E.g. if the data starts of March 21, 2023, run this command.
   ```bash
   ./evcc-vm-aggregate.py --from 2023 3 21
   ```
   This will take some time.

6. Configure the following scheduled executions using `crontab -e`:
   ```
   5 0 * * * /usr/bin/python3 <PATH_TO_SCRIPT>/evcc-vm-aggregate.py --yesterday >> /var/log/evcc-grafana-dashboards.log 2>&1
*/15 * * * * /usr/bin/python3 <PATH_TO_SCRIPT>/evcc-vm-aggregate.py --today >> /var/log/evcc-grafana-dashboards.log 2>&1
   ```
   Replace `<PATH_TO_SCRIPT>` with the path where the script was saved.

   This will aggregate yesterday's data every night and the current day's data every 15 minutes. The output is logged to the file `/var/log/evcc-grafana-dashboards.log`.

7. Create and set the permissions of the log file:
   ```bash
   sudo touch /var/log/evcc-grafana-dashboards.log
   sudo chown <USERNAME> /var/log/evcc-grafana-dashboards.log
   ```
   Replace `<USERNAME>` with the login name of the user under which the command `crontab -e` was executed in the previous step.


## Usage

The executable script uses its `#!/usr/bin/env python3` shebang, so invoke it
directly as `./evcc-vm-aggregate.py`; no `python3` prefix is needed.

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
./evcc-vm-aggregate.py --today
```

Aggregate the data of all days in November 2025:
```bash
./evcc-vm-aggregate.py --month 2025 11
```

Aggregate the data of all days of the year 2024:
```bash
./evcc-vm-aggregate.py --year 2024
```

Aggregate the data of July 16, 2024:
```bash
./evcc-vm-aggregate.py --day 2024 7 16
```

Aggregate the data starting from March 6, 2023 until the current day:
```bash
./evcc-vm-aggregate.py --from 2023 3 6
```

Aggregate the data starting from March 6, 2023 to February 15, 2025:
```bash
./evcc-vm-aggregate.py --from 2023 3 6 --to 2025 2 15
```

Delete all aggregated data from the Victoria Metrics database:
```bash
./evcc-vm-aggregate.py --delete-aggregations
```

## Aggregated metrics

This is a reference of all aggregated metrics that are created by this script.

The aggregation script writes daily values with `year`, `month` and `day` labels,
using calendar days in the configured timezone. Energy values are in Wh; costs
and revenues use the tariff currency, and tariff statistics use currency/kWh.
Monthly and yearly totals are calculated from these daily values. Today's
energy and cost values cover only elapsed complete sample intervals.

| Aggregated Metric Name | Aggregated from Metrics | Description |
| --- | --- | --- |
| `pvEnergyDaily` | `pvPower_value{id=""}` | Total PV energy generated during the day. |
| `pvEnergyForecastDaily` | `tariffSolar_value` | Forecast solar energy integrated from recorded forecast power in W. Omitted if forecast sample intervals are incomplete. |
| `homeEnergyDaily` | `homePower_value` | Daily home energy consumption. |
| `gridEnergyImportDaily` | `gridPower_value` | Daily energy imported from the grid, using positive power readings. |
| `gridEnergyExportDaily` | `gridPower_value` | Daily energy exported to the grid, reported as a positive energy value. |
| `batteryEnergyDischargedDaily` | `batteryPower_value{id=""}` | Daily energy discharged from the home battery. |
| `batteryEnergyChargedDaily` | `batteryPower_value{id=""}` | Daily energy charged into the home battery, reported as a positive energy value. |
| `loadpointEnergyDaily` | `chargePower_value{loadpoint!=""}` | Daily charging energy per `loadpoint`. |
| `auxEnergyDaily` | `auxPower_value{title!=""}` | Daily auxiliary device energy consumption per `title`. |
| `extEnergyDaily` | `extPower_value{title!=""}` | Daily external device energy consumption per `title`. |
| `consumerEnergyDaily` | `consumersPower_value{title!=""}` | Daily consumer energy consumption per `title`. |
| `energyPriceBoughtDaily` | `gridPower_value`, `tariffGrid_value` | Daily cost of imported grid energy, calculated with the applicable grid tariffs. |
| `energyPriceSoldDaily` | `gridPower_value`, `tariffFeedIn_value` | Daily revenue from exported grid energy, calculated with the applicable feed-in tariffs. |
| `energyPriceMaxDaily` | `tariffGrid_value` | Maximum grid tariff recorded during the day. |
| `energyPriceMinDaily` | `tariffGrid_value` | Minimum grid tariff recorded during the day. |
| `energyPriceAvgDaily` | `tariffGrid_value` | Arithmetic mean of the day's raw grid tariff samples; not weighted by energy consumption. |
| `greenShareHomeDaily` | `greenShareHome_value` | Daily mean green energy share for home consumption, retaining the source metric's unit. Means are calculated per source series, then averaged across series. |
| `batterySocMaxDaily` | `batterySoc_value{id=""}` | Maximum daily home battery state of charge in percent; readings outside 0–100% are excluded. |
| `batterySocMinDaily` | `batterySoc_value{id=""}` | Minimum daily home battery state of charge in percent; zero and readings outside 0–100% are excluded. |
| `vehicleOdometerMaxDaily` | `vehicleOdometer_value{vehicle!=""}` | Maximum daily odometer reading per `vehicle`, retaining the source metric's unit. |
| `vehicleEnergyDaily` | `chargePower_value{vehicle!=""}` | Daily charging energy per `vehicle`. |
| `potentialHomeDailyPrice` | `homePower_value`, `tariffGrid_value` | Hypothetical daily cost of home consumption valued at the grid tariff. |
| `potentialLoadpointDailyPrice` | `chargePower_value{loadpoint!=""}`, `tariffGrid_value` | Hypothetical daily charging cost per `loadpoint` valued at the grid tariff. |
| `energyDischargeDailyPrice` | `batteryPower_value{id=""}`, `tariffGrid_value` | Daily battery discharge valued at the grid tariff. |
| `energyChargeDailyPrice` | `batteryPower_value{id=""}`, `tariffFeedIn_value` | Signed daily battery charging valuation at the feed-in tariff; negative charging power produces a negative value at a positive tariff. |
| `vehicleChargeDailyPrice` | `chargePower_value{vehicle!=""}`, `tariffPriceLoadpoints_value` | Daily charging cost per `vehicle`, using the mean charging tariff across loadpoints; simultaneous charging at different tariffs is approximated. |
| `potentialVehicleChargeDailyPrice` | `chargePower_value{vehicle!=""}`, `tariffGrid_value` | Hypothetical daily charging cost per `vehicle` valued at the grid tariff. |

Battery aggregates require `HOME_BATTERY="true"`. Grid tariff minimum, maximum
and average require `DYNAMIC_TARIFF="true"`. Aggregates with no source data are
omitted; costs with missing tariffs for nonzero energy are also omitted.
