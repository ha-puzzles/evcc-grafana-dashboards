# Installation von Victoria Metrics

Es gibt hier mehrere Wege: 

- Docker Image: Empfohlen
- Debian Package: Hier bekomme ich leider das Web UI nicht zum laufen. Wer dieses nicht braucht, mag damit am besten zurecht kommen.
- Manuelle Installation.


## Installation über Docker mit Docker Compose

1. Installation von `docker-compose`:
   ```bash
   sudo apt update && sudo apt install docker-compose
   ```
1. Ein Verzeichnis erstellen, wo der Victoria Metrics Docker Container seine Daten ablegt. Zum Beispiel im Home Verzeichnis unter `docker/victoria-metrics`:
   ```bash
   mkdir -p ~/docker/victoria-metrics
   cd ~/docker/victoria-metrics
   ```
1. Dort eine Datei `docker-compose.yml` mit folgendem Inhalt erstellen:
   ```yaml
   services:
      # VictoriaMetrics instance, a single process responsible for
      # storing metrics and serve read requests.
      victoriametrics:
         image: victoriametrics/victoria-metrics:latest
         ports:
            - 8428:8428
            - 8089:8089
            - 8089:8089/udp
            - 2003:2003
            - 2003:2003/udp
            - 4242:4242
         volumes:
            - ./vmdata:/storage
         command:
            - "--storageDataPath=/storage"
            - "--graphiteListenAddr=:2003"
            - "--opentsdbListenAddr=:4242"
            - "--httpListenAddr=:8428"
            - "--influxListenAddr=:8089"
            - "--vmalert.proxyURL=http://vmalert:8880"
            - "--retentionPeriod=100y"
         restart: always
   ```
1. Den Docker containter herunterladen und starten:
   ```bash
   sudo docker-compose pull && sudo docker-compose up -d
   ```
1. In einem Browser die URL `http://<server>:8428` öffnen. `<server>` dabei durch den Host namen Eures Linux servers, auf dem Victoria Metrics läuft, ersetzen. Ihr solltet diese Seite zu Gesicht bekommen:
   ![Victoria Metrics Seite](./img/victoria-metrics-ui.png)
   Ein Click auf den Link 'vmui' sollte nun das Victoria Metrics Web UI öffnen.
1. Das CLI `vmutil` als Docker image ausführen:
   ```
   sudo docker run -it --rm victoriametrics/vmctl:latest --version
   ```
   Diese sollte eine Ausgabe ähnlich dieser erzeugen:
   ```
   Unable to find image 'victoriametrics/vmctl:latest' locally
   latest: Pulling from victoriametrics/vmctl
   d8ad8cd72600: Already exists 
   466c3c6cfeee: Already exists 
   fd4bd266edb3: Pull complete 
   Digest: sha256:a0bb731558882068bc6677c787b6376004beb359906b1bb93bdd88cadb577962
   Status: Downloaded newer image for victoriametrics/vmctl:latest
   2026/03/01 21:12:05 INFO: metrics: disable exposing PSI metrics because of failed init: open /sys/fs/cgroup/cpu.pressure: no such file or directory
   vmctl version vmctl-20260213-201617-tags-v1.136.0-0-g7386a35942
   2026/03/01 21:12:05 Total time: 675.49µs
   ```

Fertig.

Wenn nun eine neuere Victoria Metrics Version erscheint ist der Upgrade dank Docker sehr einfach:
```bash
cd ~/docker/victoria-metrics
sudo docker-compose pull && sudo docker-compose up -d
```


## Installation über Debian Package

1. Victoria Metrics mittels `apt` installatiren:
   ```bash
   sudo apt update && sudo apt install victoria-metrics
   ```
1. Data Retention Period erhöhen.
   1. Die Datei `/etc/default/victoria-metrics` editieren, zum Beispiel mit VI: 
      ```bash
      sudo vi /etc/default/victoria-metrics
      ```
   1. Zur Variable `ARGS` am Ende folgendes hinzufügen:
      ```
      -retentionPeriod=100y
      ```
      100 Jahre sollten erstmal reichen. Mehr geht in Victoria Metrics leider nicht.
1. Victoria Metric starten.
   ```
   sudo systemctl start victoria-metrics
   ```
1. In einem Browser die URL `http://<server>:8428` öffnen. `<server>` dabei durch den Host namen Eures Linux servers, auf dem Victoria Metrics läuft, ersetzen. Ihr solltet diese Seite zu Gesicht bekommen:
   ![Victoria Metrics Seite](./img/victoria-metrics-ui.png)
   Ein Click auf den Link 'vmui' wird vermutlich zu einem 404 Fehler führen. Dies ist genau das Fehlen des Victoria Metrics Web UI, welches ich oben erwähnt habe. Leider konnte ich nicht herausfinden, wie man dieses Problem löst. 
1. Sicherstellen, dass `vmctl` richtig installiert wurde:
   ```bash
   vmctl --version
   ```

## Manuelle Installation

1. Download der Binaries der Victoria Metrics Datenbank und der Utilities von der Victoria Metrics [Releases Seite](https://github.com/VictoriaMetrics/VictoriaMetrics/releases). Wir benötigen folgende Dateien eines Releases, der KEIN Enterprise Release ist:
   - victoria-metrics-linux-<arch>>-<version>.tar.gz
   - vmutils-darwin-<arch>-<version>.tar.gz
   
   Hier sind `<arch>` durch die Systemarchitektur und `<version>` durch die Victoria Metrics Version zu ersetzen. Wenn wir zum Beispiel für einen Raspberry PI die Version v1.136.0 installieren wollen, dann laden wir uns von dem [v1.136.0 Release](https://github.com/VictoriaMetrics/VictoriaMetrics/releases/tag/v1.136.0) die Dateien 
   - victoria-metrics-linux-arm64-v1.136.0.tar.gz
   - vmutils-darwin-arm64-v1.136.0.tar.gz

   herunter.
1. Übertragt die heruntergeladenen Archive auf den Server, zum Beispiel mittels `scp`.
1. Erstellt einen temporären Ordner `vm` an beliebiger Stelle in dem ihr die Archive ablegt.
1. Erstellt in diesem `vm` Ordner einen Unterordner `bin` und wechselt in diesen `vm/bin` Ordner.
1. Entpackt die Binaries aus den Archivedateien, die im übergelegenen `vm` Ordner liegen in den `vm/bin` Ordner:
   ```bash
   tar zxvf ../victoria-metrics-linux-*.tar.gz
   tar zxvf ../vmutils-*.tar.gz
   ```
1. Alle Binaries haben nun ein `-prod` Anhang im Namen. Diesen entfernen wir mit
   ```bash
   ls -1 *-prod | while read file; do mv -v $file `echo $file | sed 's/-prod$//'`; done
   ```
1. Mit einem `ls` überprüfen wir nun kurz, dass der vorherige Befehle erfolgreich war.
1. Wir setzen den Besitzer der Dateien auf root.
   ```bash
   sudo chown root:root *
   ```
1. Jetzt verschieben wir die Binaries nach `/usr/local/bin`.
   ```bash
   sudo mv * /usr/local/bin
   ```
1. Victoria Metrics braucht nun noch einen Benutzer unter dem der Dienst läuft, welcher sich aber nicht interaktiv einloggen darf.
   ```bash
   sudo useradd -s /usr/sbin/nologin victoriametrics
   ```
1. Für die Datenbankdateien brauchen wir noch ein Verzeichnis mit den richtigen Berechtigungen.
   ```bash
   sudo mkdir -p /var/lib/victoria-metrics 
   sudo chown -R victoriametrics:victoriametrics /var/lib/victoria-metrics
   ```
1. Jetzt müssen wir noch einen Service für die Datenbank erstellen, welcher auch gleich die richtige Data Retention Period setzt.
   ```bash
   sudo bash -c 'cat <<END >/etc/systemd/system/victoriametrics.service
   [Unit]
   Description=VictoriaMetrics service
   After=network.target

   [Service]
   Type=simple
   User=victoriametrics
   Group=victoriametrics
   ExecStart=/usr/local/bin/victoria-metrics -storageDataPath=/var/lib/victoria-metrics -retentionPeriod=100y -selfScrapeInterval=10s
   SyslogIdentifier=victoriametrics
   Restart=always

   PrivateTmp=yes
   ProtectHome=yes
   NoNewPrivileges=yes

   ProtectSystem=full

   [Install]
   WantedBy=multi-user.target
   END'
   ```
1. Dieser Dienst muss nun noch aktiviert und gestartet werden.
   ```bash
   sudo systemctl daemon-reload
   sudo systemctl enable --now victoriametrics.service
   ```
1. Mit dem folgenden Befehl überprüfen wir, dass der Dienst korrekt läuft.
   ```bash
   sudo systemctl status victoriametrics.service
   ```
1. In einem Browser die URL `http://<server>:8428` öffnen. `<server>` dabei durch den Host namen Eures Linux servers, auf dem Victoria Metrics läuft, ersetzen. Ihr solltet diese Seite zu Gesicht bekommen:
   ![Victoria Metrics Seite](./img/victoria-metrics-ui.png)
   Ein Click auf den Link 'vmui' sollte nun das Victoria Metrics Web UI öffnen.
1. Sicherstellen, dass `vmctl` richtig installiert wurde:
   ```bash
   vmctl --version
   ```

## Weitere Installations Methoden

Victoria Metrics ist noch über einige weitere Methoden wie Docker, Helm Charts oder Kubernetes verfügbar. Siehe auch der [Quick Start](https://docs.victoriametrics.com/victoriametrics/quick-start/) Guide von Victoria Metrics.

Egal wie ihr Victoria Metrics installiert, stellt sicher, dass ihr den Parameter `-retentionPeriod=100y` bei der Ausführung der Datenbank setzt.