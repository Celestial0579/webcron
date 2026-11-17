# webcron

Ruft Cronjob-URLs nach Zeitplan auf — für Webanwendungen, deren Hoster
keine Cronjobs anbietet.

**Schnellstart in 5 Minuten: [ANLEITUNG.md](ANLEITUNG.md)**

## Wozu das gut ist

Viele Webanwendungen brauchen einen regelmäßigen Anstoß von außen:
WordPress sein `wp-cron.php`, Nextcloud sein `cron.php`, Shops ihre
Export- und Aufräum-URLs. Billige Webhoster bieten dafür oft keinen
Cronjob an — oder nur einen, in grobem Raster, über ein Webinterface.

webcron schließt diese Lücke: Ein kleiner Container (Alpine, supercronic,
curl), der auf beliebiger eigener Hardware läuft — Heimserver, NAS,
VPS — und die konfigurierten URLs nach echtem Cron-Zeitplan aufruft.

```
eigener Host (Docker) ──HTTP(S)──> https://example.com/wp-cron.php
                      ──HTTP(S)──> https://cloud.example.com/cron.php
```

**Abgrenzung:** Es gibt Mini-Images mit ähnlichem Zweck (etwa
[docker-curl-cron](https://github.com/r1co/docker-curl-cron) oder
[docker-webcron](https://github.com/cw1/docker-webcron)) — die können
jeweils genau *eine* URL je Container und sind teils seit Jahren
unangetastet. Volle Scheduler wie
[Cronicle](https://github.com/soulteary/docker-cronicle) können weit
mehr, wollen dafür aber Nutzerverwaltung, Datenhaltung und offene Ports.
webcron liegt dazwischen: beliebig viele URLs mit echter Cron-Syntax in
einer einzigen Textdatei, Logs und Status-Übersicht, sonst nichts.

## Schnellstart

`jobs.cron` anlegen (Vorlage: [jobs.example.cron](jobs.example.cron)):

```
# <Minute> <Stunde> <Monatstag> <Monat> <Wochentag> <URL>
*/5 * * * *  https://example.com/wp-cron.php?doing_wp_cron
30 3 * * *   https://example.com/export/nightly?token=GEHEIM
```

Die Datei enthält Secrets. Sie sollte nur root gehören und lesen können,
sonst liest sie auch der Prozess der Status-UI (`nobody`) — und jeder
lokale Nutzer des Docker-Hosts:

```bash
sudo chown root:root jobs.cron && sudo chmod 600 jobs.cron
```

(Mit rootless Docker genügt `chmod 600 jobs.cron`.) Als Einzeldatei
mounten wie unten, nicht das ganze Verzeichnis: Das Verzeichnis `/config`
im Abbild ist `0700`. root im Container braucht Leserecht als Besitzer —
unter `cap_drop: ALL` fehlt ihm `CAP_DAC_OVERRIDE`. Fehlt es, bricht der
Start mit einer klaren Meldung ab; ist die Datei für alle lesbar, warnt
webcron beim Start und bei `--pruefen`.

Dann starten:

```bash
docker run -d --name webcron --restart unless-stopped \
  -e TZ=Europe/Berlin \
  -p 127.0.0.1:8080:8080 \
  -v "$PWD/jobs.cron:/config/jobs.cron:ro" \
  --read-only --tmpfs /run --tmpfs /tmp \
  --cap-drop ALL --cap-add SETUID --cap-add SETGID \
  --security-opt no-new-privileges:true \
  ghcr.io/celestial0579/webcron:latest
```

Die Status-Übersicht ist danach auf dem Docker-Host unter
`http://127.0.0.1:8080/` erreichbar (bewusst nur lokal gebunden, sie hat
keine Anmeldung). Von einem anderen Rechner aus: SSH-Tunnel
`ssh -L 8080:127.0.0.1:8080 <host>`, oder bewusst an eine LAN-Adresse
binden (`-p <LAN-IP>:8080:8080`, nur hinter der Host-Firewall).

Oder mit Compose: [docker-compose.yml](docker-compose.yml) anpassen und
`docker compose up -d`.

Vor dem ersten Start lohnt ein Probelauf — er ruft jede URL sofort genau
einmal auf und schlägt fehl, wenn eine nicht erreichbar ist:

```bash
docker run --rm -v "$PWD/jobs.cron:/config/jobs.cron:ro" \
  ghcr.io/celestial0579/webcron:latest --einmal
```

Nur die Konfiguration prüfen, ohne irgendetwas aufzurufen: `--pruefen`.

## Konfiguration

Eine Zeile je Aufruf: fünf Cron-Felder, die URL, danach optional
HTTP-Kopfzeilen als `Name:Wert`. Kommentare (`#`) und Leerzeilen sind
erlaubt. Kaputte Zeilen lehnt der Container beim Start komplett ab —
ein halber Zeitplan wäre schlimmer als keiner.

```
# Endpunkt, der sein Secret als Header erwartet (z. B. das
# Hengstverzeichnis-Framework unter /cron/run):
*/5 * * * *  https://hengste.example.com/cron/run  X-Cron-Secret:GEHEIM
```

Die Cron-Felder prüft webcron auf ihren Wertebereich: Minute 0–59,
Stunde 0–23, Monatstag 1–31, Monat 1–12, Wochentag 0–6 (Sonntag ist 0,
eine 7 gibt es nicht). Erlaubt sind Zahlen, `*`, Listen (`1,15`),
Bereiche (`1-5`) und Schritte nach `*` oder einem Bereich (`*/5`,
`8-18/2`), keine Namen wie `mon` und kein Schritt hinter einer einzelnen
Zahl (`0/15`). Die Datei darf UTF-8 mit BOM sein und Windows-Zeilenenden
haben.

Kopfzeilen sind der richtige Platz für Secrets: Anders als der
Query-String tauchen sie nicht in Access- und Proxy-Logs auf. Grenzen
der Syntax: Weder URL noch Kopfzeilen dürfen Leerzeichen oder
Hochkommas enthalten — `Authorization: Bearer <token>` (mit Leerzeichen
im Wert) geht deshalb nicht; Endpunkte mit eigenem Header wie
`X-Cron-Secret` sind der vorgesehene Weg. Header-Werte behandelt webcron
durchgehend als Secrets: Status-UI, Startprotokoll und `--pruefen`
nennen nur die Namen, nie die Werte; Fehlermeldungen der Konfigurations-
prüfung nennen nur Zeile und Art des Fehlers, nie Teile der Zeile. Die
URL gilt wörtlich: `[` `]` `{` `}` (z. B. `filter[status]=offen`) wertet
curl nicht als Muster aus. Weder Kopfzeilen noch URL stehen
auf einer Kommandozeile (Zeitplaner-Log, `ps`, `/proc`): Die Crontab nennt
je Job nur eine Nummer, URL und Kopfzeilen liegen in einer Datei, die
nur der Zeitplaner-Benutzer lesen kann, und curl bekommt sie über stdin.

**Weiterleitungen:** Jobs *mit* Kopfzeilen folgen keiner Weiterleitung —
sonst gingen die Secrets auch an fremde Hosts oder über http. Eine
3xx-Antwort zählt als `FEHLER` und nennt das Ziel (maskiert); die URL in
`jobs.cron` muss das endgültige Ziel sein. Jobs ohne Kopfzeilen folgen
Weiterleitungen, aber nie von https auf http.

Nach einer Änderung an `jobs.cron` den Container neu starten
(`docker restart webcron`); die Datei wird beim Start gelesen.

| Variable | Standard | Bedeutung |
|---|---|---|
| `TZ` | `UTC` | Zeitzone, in der die Zeitpläne gelten |
| `WEBCRON_TIMEOUT` | `60` | Sekunden, bis ein Aufruf abgebrochen wird |
| `WEBCRON_VERSUCHE` | `2` | curl-Wiederholungen bei Netz-/Serverfehlern |
| `WEBCRON_USER_AGENT` | `webcron (+…)` | User-Agent der Aufrufe |
| `WEBCRON_UI_PORT` | `8080` | Port der Status-UI, `0` schaltet sie ab |
| `WEBCRON_JOBS` | `/config/jobs.cron` | Pfad der Konfigurationsdatei |
| `WEBCRON_LOGLEVEL` | `8` | Gesprächigkeit von supercronic: 8 = normal, kleiner = Fehlersuche (`-debug`), größer = nur Fehler (`-quiet`); die Job-Kommandozeile enthält nur die Jobnummer |

## Logs und Status-UI

Jeder Aufruf landet mit Zeit, HTTP-Code, Dauer und Jobnummer in den Container-Logs. Die Nummer
ist die Reihenfolge der Jobs in `jobs.cron`; von der URL stehen nur Schema und Host da:

```
$ docker logs webcron
2026-08-09 14:35:00  OK      HTTP 200  1s  Job 1  https://example.com/***
2026-08-09 14:40:02  FEHLER  HTTP 503  2s  Job 1  https://example.com/***
```

Als `OK` zählt jede 2xx-Antwort (bei Jobs ohne Kopfzeilen auch 3xx), alles andere als `FEHLER`
(`HTTP 000` = Server gar nicht erreichbar).

Zusätzlich liefert eine schreibgeschützte **Status-UI** eine Übersicht
aller Jobs mit letztem Aufruf, Ergebnis und Fehlerzähler:
`http://127.0.0.1:8080/` auf dem Docker-Host (Port per `-p`/`ports:` nur
an 127.0.0.1 gebunden, siehe Schnellstart; für andere Rechner SSH-Tunnel
oder bewusst eine LAN-Adresse). Sie hat bewusst keine Anmeldung — den
Port also nie ins Internet weiterreichen. Wer sie gar nicht will: `WEBCRON_UI_PORT=0` und die
Port-Freigabe weglassen.

Bearbeiten lässt sich dort nichts: Die Konfiguration ist die Datei,
nicht der Container.

## Sicherheit

- Logs und Status-UI nennen von einer URL nur Schema und Host
  (`https://example.com/***`). Pfad, Query-String und Zugangsdaten
  (`user:pw@`) werden maskiert, denn auch der Pfad kann ein Secret tragen
  (Drupal `/cron/<key>`, Webhook-IDs, Ping-UUIDs). Die URL steht auf keiner
  Kommandozeile, und auch Fehlermeldungen von curl und der
  Konfigurationsprüfung geben sie nicht preis. Trotzdem Geheimnisse bevorzugt als Kopfzeile übergeben.
  Wo möglich, der Anwendung ein eigenes Cron-Token geben, das nichts
  anderes kann.
- Der einzige Port ist die Status-UI (ohne Anmeldung) — im LAN in
  Ordnung, aber nicht ins Internet weiterreichen. Ohne UI
  (`WEBCRON_UI_PORT=0`) braucht der Container gar keinen Port.
- Die Status-UI läuft als `nobody` und sieht nur die maskierte Jobliste
  und den Status, nie die Jobdateien mit URL-Secrets und Kopfzeilen —
  und, wenn `jobs.cron` wie oben nur root gehört, auch nicht diese
  Quelle (`/config` im Abbild ist `0700`, die Datei kommt als Einzeldatei
  hinein).
- **Kein Dauerprozess läuft als root.** Der Container startet als root,
  damit er die nur für root lesbare Konfiguration einlesen kann. Dann gibt
  `webcron` die Rechte ab: Die Status-UI (httpd) läuft als `nobody`, der
  Zeitplaner (supercronic, PID 1) und die Abrufe als `webcron` (UID 10001),
  und kein Prozess behält root. Die Jobdateien mit den Secrets lesen nur
  `webcron` und root; weder `nobody` (Status-UI) noch `webcron` lesen
  `/config`. Mit der Compose-Datei bleibt nach dem Start auch keine
  Capability übrig, und `no-new-privileges` verhindert, dass ein Prozess
  neue Rechte erlangt.
- Keine besonderen Rechte und kein beschreibbares Dateisystem außer
  `/run` und `/tmp`: Die Beispiele (Compose, `docker run`) erzwingen das mit
  `read_only`, `tmpfs`, `cap_drop: ALL` (nur SETUID und SETGID bleiben, für
  den Rechtewechsel beim Start) und `no-new-privileges`. Auch ohne diese
  Optionen (`docker run` ohne die Einschränkungen) laufen Zeitplaner, curl
  und Status-UI nicht als root; empfohlen bleiben die Optionen trotzdem.
- Die Syntax der Cron-Zeilen prüft webcron selbst (Wertebereiche, siehe
  `--pruefen`); supercronic führt die geprüften Zeilen aus. Wie bisher gilt
  bei gesetztem Monatstag *und* Wochentag: einer der beiden genügt.

## Tests

```bash
tests/integrationstest.sh
```

baut das Abbild und prüft Konfigurationsprüfung, Einmal-Modus,
einen echten Zeitplan-Takt (supercronic), dass kein Prozess als root läuft und die Status-UI gegen einen
Wegwerf-Webserver — es wird keine echte fremde URL aufgerufen.
Dasselbe läuft als GitHub-CI. Auf `main` veröffentlicht sie das Abbild als
`ghcr.io/celestial0579/webcron`; Pull Requests bauen es nur.

## Lizenz

MIT, siehe [LICENSE](LICENSE).
