# Grafana Dashboard für EVCC

Vorab: Ohne in Grafana einsteigen zu können, geht es nicht. Die Dashboards sind an meinen Bedürfnisse angepasst, so filtere ich in vielen Dashboards Ausreißer aus. Diese Werte müsst ihr ggf. anpassen. Zum Beispiel filtere ich bei meiner 9.84 kWp anlage alle Werte über 20 kW raus. Denkt bitte nicht, dass ihr meine Dashboards einfach in Grafana hochladen könnt und es wird bei Euch funktionieren. Seht das bitte eher als Startpunkt für eigene Dashboards.

Ich habe versucht alle notwendigen Anpassungen unter ['dashboards'](dashboards/README.md) aufzulisten. Dabei ist mir aber sicher was durch die Lappen gegangen.

![PV Today Screenshot](dashboards/img/today.png)


## Installation

### Grundvoraussetzungen

Folgende Grundvoraussetzungen müssen erfüllt sein:

- EVCC: https://evcc.io/
- Influx DB: https://www.influxdata.com/
- Grafana: https://grafana.com/
- Grundlegende Linux Kenntnisse oder die Bereitschaft sich diese anzueignen.
- Die Möglichkeit ein Bash Shell Script regelmäßig per Crontab ausführen zu können.
- Bereitschaft sich etwas in Grafana einzuarbeiten.


### Software

Hier nur die groben Schritte, da sie je nach Plattform stark variieren:

1. Influx DB installieren. Ich nutze die InfluxDB noch in der Version 1.8.
2. Influx DB so konfigurieren, dass sie InfluxQL benutzt.
3. EVCC konfigurieren, dass Daten in die Influx geschrieben werden: https://docs.evcc.io/docs/reference/configuration/influx/
4. Grafana installieren

### Installation der Dashboards in Grafana

1. Data Source für Influx DB anlegen:
![Data Source anlegen](./img/create-datasource.png)

2. Dashboard [JSON Dateien](./dashboards) von diesem GitHub herunterladen.

3. JSON Dateien mittels 'Import' in Grafana importieren.
![Import](./img/import.png)

4. Dashboards wie [unter 'dashboards' beschrieben](./dashboards/README.md) anpassen.

5. Daten Aggregation Script wie [unter 'scripts beschrieben](./scripts/README.md) anpassen und installieren (ohne dieses werden die Dashboards für Monat, Jahr und Finanz nicht laufen).

## Danke

Herzlichen Dank an alle, die im Thread ["InfluxDB und Grafana"](https://github.com/evcc-io/evcc/discussions/4213) im EVCC Repository aktiv mitgeholfen haben. Ohne Eure Hilfe wäre das hier entweder nichts geworden oder hätte deutlich länger gedauert.
