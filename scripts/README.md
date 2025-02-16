# Aggregation Script

Irgendwann war der Raspberry PI heillos damit überfordert alle Daten live zusammenzustellen und die monatlichen und vorallem jährlichen Dashboards liefen nur noch in Timeouts. Daher war eine Aggregierung notwendig. Diese erledigt das Bash Shell Script `evcc-influx-aggregate.sh`.

# Installation

1. Script [`evcc-influx-aggregate.sh`](./evcc-influx-aggregate.sh) und Konfigurationsdatei [`evcc-influx-aggregate.conf`](./evcc-influx-aggregate.conf) herunterladen und auf ein Linux System kopieren. Idealerweise ist dies das System (oder die VM) auf der die InfluxDB läuft. Falls dies nicht möglicht ist (z.B. HAOS), kann das script auch remote von einem anderen Linux System ausgeführt werden.

2. Getrennte Datenbank für die aggregierten Daten anlegen. Falls keine getrennte Datenbank gewünscht wird können auch die Zugangsdaten der EVCC Influx Datenbank genommen werden. Es wird allerdings empfohlen eine getrennte Datenbank für die Aggegrationen anzulegen.
   1. Auf dem Influx server das `influx` CLI starten
   2. Datenbank anlegen (hier nennen wir die DB 'evcc_aggr'): 
      
      `create database evcc_aggr`
   3. Datenbank benutzen: 
      
      `use evcc_aggr`
   4. Einen User 'grafana' anlegen. Falls gewünscht mit Password: 
      
      `create user grafana with password '' with all privileges`

3. Nur bei Remote Ausführung des Scriptes auf einem anderen System als dem auf dem die Influx DB läuft:
   1. Influx Client installieren. Je nach Linuxderivat z.B. `apt-get install influxdb-client`
   2. Mit `influx -version` überprüfen, dass es der Client mit der richtigen Version ist (muss 1.8.x sein)
     ```
     $ influx -version
     InfluxDB shell version: 1.8.10
     ```
   3. Überprüfen ob man sich zur Influx verbinden kann: `influx -host [Influx DB host name] -port 8086 -database [Database name]`

4. Konfigurationsdatei [`evcc-influx-aggregate.conf`](./evcc-influx-aggregate.conf) mit den entsprechenden Werten anpassen. Die Werte sind mit erklärenden Kommentaren versehen. Bitte alle Werte überprüfen und gegebenenfalls anpassen.

5. Die Recht für das Script anpassen, damit es ausführbar wird: `chmod +x evcc-influx-aggregate.sh`

6. Für jedes Jahr, für das die Influx DB bereits mit EVCC Daten gefüllt ist, eine Aggregierung des gesamten Jahres starten:
   ```bash
   ./evcc-influx-aggregate.sh --year 2024
   ```
   Das wird nun etwas dauern.

7. Mit Hilfe von `crontab -e` folgende regelmäßige Aufrufe konfigurieren:
   ```
   5 0 * * * <PATH_TO_SCRIPT>/evcc-influx-aggregate.sh --yesterday >> /var/log/evcc-grafana-dashboards.log 2>&1
   0 * * * * <PATH_TO_SCRIPT>/evcc-influx-aggregate.sh --today >> /var/log/evcc-grafana-dashboards.log 2>&1
   ```
   Hierbei `<PATH_TO_SCRIPT>` durch den Pfad ersetzen, wo das Script gespeichert wurde.

   Damit wird dann jede Nacht der gestrige Tage aggregiert, sowie jede volle Stunde einmal der aktuelle Tag. Die Ausgaben werden in der Datei `/var/log/evcc-grafana-dashboards.log` geloggt.

8. Anlegen und Setzen der permissions des Log Files:
   ```bash
   sudo touch /var/log/evcc-grafana-dashboards.log
   sudo chown <USERNAME> /var/log/evcc-grafana-dashboards.log
   ```
   Dabei ist `<USERNAME>` durch den Loginnamen des Benutzers zu ersetzen unter dem in Schritt 8 der Befehl `crontab -e` ausgeführt wurde.


