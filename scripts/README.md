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
| `--today`                    | Aggregate the data of today and the current month                                        |
| `--yesterday`                | Aggregate the data of yesterday and yesterday's month                                    |
| `--delete-aggregations`      | Delete the measurements of the aggregated data from the Victoria Metrics database. Deleting a single measurement can take several minutes. |s of the loadpoints and vehicles are correct. If older values are found, they can be hidden in the dashboards via the blocklist variable. |
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