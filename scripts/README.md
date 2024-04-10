# Aggregation Script

Irgendwann war der Raspberry PI heillos damit überfordert alle Daten live zusammenzustellen und die monatlichen und vorallem jährlichen Dashboards liefen nur noch in Timeouts. Daher war eine Aggregierung notwendig. Diese erledigt das Bash Shell Script `evcc-influx-aggregate.sh`.

# Installation

1. Script [`evcc-influx-aggregate.sh`](./evcc-influx-aggregate.sh) herunterladen und auf ein Linux System kopieren.
2. Script mit Zugangsdaten für Influx oben anpassen:
   ```bash
   #consts
   INFLUXDB="evcc" # Name of the Influx DB, where you write the EVCC data into
   INFLUX_USER="" # Your user name. Empty, if no user is required.
   INFLUX_PASSWORD="none" # can be anything except an empty string in case no password is set
    ```
3. Falls kein Heimspeicher vorhanden ist, kann dessen Aggregtion deaktiviert werden:
   ```bash
   HOME_BATTERY="true" # set to false in case your home does not use a battery
   ```
4. Loadpoints müssen mit den Titeln, wie sie in der evcc.yaml definiert worden sind angegeben werden. Ein zweiter Loadpoint kann ggf. deaktiviert werden.
   ```bash
   LOADPOINT_1_TITLE="Garage" # title of loadpoint 1 as defined in evcc.yaml
   LOADPOINT_2_ENABLED=true # set to false in case you have just one loadpoint
   LOADPOINT_2_TITLE="Stellplatz" # title of loadpoint 2 as defined in evcc.yaml
   ```
5. `chmod +x evcc-influx-aggregate.sh`
6. Für jedes Jahr, für das die Influx DB bereits mit EVCC Daten gefüllt ist, eine Aggregierung des gesamten Jahres starten:
   ```bash
   ./evcc-influx-aggregate.sh --year 2024
   ```
   Das wird nun etwas dauern.
7. Mit Hilfe von `crontab -e` folgende regelmäßige Aufrufe konfigurieren:
   ```
   5 0 * * * /home/cschlipf/bin/evcc-influx-aggregate.sh --yesterday
   0 * * * * /home/cschlipf/bin/evcc-influx-aggregate.sh --today
   ```
   Damit wird dann jede Nacht der gestrige Tage aggregiert, sowie jede volle Stunde einmal der aktuelle Tag.


