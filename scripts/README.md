# Aggregation Script

Irgendwann war der Raspberry PI heillos damit überfordert alle Daten live zusammenzustellen und die monatlichen und vorallem jährlichen Dashboards liefen nur noch in Timeouts. Daher war eine Aggregierung notwendig. Diese erledigt das Bash Shell Script `evcc-influx-aggregate.sh`.

# Installation

1. Script [`evcc-influx-aggregate.sh`](./evcc-influx-aggregate.sh) herunterladen und auf ein Linux System kopieren. Idealerweise ist dies das system (oder die VM) auf der die InfluxDB läuft. Falls dies nicht möglicht ist (z.B. HAOS), kann das script auch remote von einem anderen Linux System ausgeführt werden.
2. Script mit Zugangsdaten für Influx oben anpassen:
   ```bash
   #consts
   INFLUXDB="evcc" # Name of the Influx DB, where you write the EVCC data into
   INFLUX_USER="" # Your user name. Empty, if no user is required.
   INFLUX_PASSWORD="none" # can be anything except an empty string in case no password is set
    ```
3. Wird das Script auf demselben System installiert auf dem auch die Influx DB läuft, kann dieser Schritt übersprungen werden. Falls das Script nicht lokal auf dem System läuft, wo die InfluxDB läuft:
   1. Influx Client installieren. Je nach Linuxderivat z.B. `apt-get install influxdb-client`
   2. Mit `influx -version` überprüfen, dass es der Client mit der richtigen Version ist (muss 1.8.x sein)
     ```
     $ influx -version
     InfluxDB shell version: 1.8.10
     ```
   3. Überprüfen ob man sich zur Influx verbinden kann: `influx -host [Influx DB host name] -port 8086 -database [Database name]`
   4. Hostname und Port des remote Influxsystems anpassen:
     ```bash
     INFLUX_HOST="localhost" # If the script is run remotely, enter the host name of the remote host. Default: "localhost"
     INFLUX_PORT=8086 # The port to connect to influx. Default: 8086
     ```
4. Falls kein Heimspeicher vorhanden ist, kann dessen Aggregation deaktiviert werden:
   ```bash
   HOME_BATTERY="true" # set to false in case your home does not use a battery
   ```
5. Loadpoints müssen mit den Titeln, wie sie in der evcc.yaml definiert worden sind angegeben werden. Ein zweiter Loadpoint kann ggf. deaktiviert werden.
   ```bash
   LOADPOINT_1_TITLE="Garage" # title of loadpoint 1 as defined in evcc.yaml
   LOADPOINT_2_ENABLED=true # set to false in case you have just one loadpoint
   LOADPOINT_2_TITLE="Stellplatz" # title of loadpoint 2 as defined in evcc.yaml
   ```
6. `chmod +x evcc-influx-aggregate.sh`
7. Für jedes Jahr, für das die Influx DB bereits mit EVCC Daten gefüllt ist, eine Aggregierung des gesamten Jahres starten:
   ```bash
   ./evcc-influx-aggregate.sh --year 2024
   ```
   Das wird nun etwas dauern.
8. Mit Hilfe von `crontab -e` folgende regelmäßige Aufrufe konfigurieren:
   ```
   5 0 * * * <PATH_TO_SCRIPT>/evcc-influx-aggregate.sh --yesterday >> /var/log/evcc-grafana-dashboards.log 2>&1
   0 * * * * <PATH_TO_SCRIPT>/evcc-influx-aggregate.sh --today >> /var/log/evcc-grafana-dashboards.log 2>&1
   ```
   Hierbei `<PATH_TO_SCRIPT>` durch den Pfad ersetzen, wo das Script gespeichert wurde.

   Damit wird dann jede Nacht der gestrige Tage aggregiert, sowie jede volle Stunde einmal der aktuelle Tag. Die Ausgaben werden in der Datei `/var/log/evcc-grafana-dashboards.log` geloggt.


