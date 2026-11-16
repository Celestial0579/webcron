# Anleitung: In 5 Minuten zum laufenden webcron

Ausführliche Doku im [README](README.md) — hier nur der kürzeste Weg.

## 1. Job-Datei anlegen

Datei `jobs.cron` erstellen, eine Zeile je Aufruf:

```
# <Minute> <Stunde> <Monatstag> <Monat> <Wochentag> <URL> [Header ...]

# WordPress alle 5 Minuten:
*/5 * * * *  https://example.com/wp-cron.php?doing_wp_cron

# Endpunkt mit Secret-Header (z. B. Hengstverzeichnis /cron/run):
*/5 * * * *  https://hengste.example.com/cron/run  X-Cron-Secret:GEHEIM
```

Secrets gehören in einen Header (`Name:Wert`, ohne Leerzeichen), nicht in
die URL — Query-Strings landen in Access-Logs.

Die Datei enthält Secrets und gehört nur root: Sonst kann sie auch der
Prozess der Status-UI (`nobody`) lesen.

```bash
sudo chown root:root jobs.cron && sudo chmod 600 jobs.cron
```

(Mit rootless Docker genügt `chmod 600 jobs.cron`. Später bearbeiten mit
`sudoedit jobs.cron`.) Ohne Leserecht für root bricht webcron mit einer
klaren Meldung ab; ist die Datei für alle lesbar, warnt es beim Start.

## 2. Probelauf

Ruft jede URL sofort genau einmal auf; schlägt fehl, wenn eine nicht
erreichbar ist:

```bash
docker run --rm -v "$PWD/jobs.cron:/config/jobs.cron:ro" \
  ghcr.io/celestial0579/webcron:latest --einmal
```

## 3. Starten

```bash
docker run -d --name webcron --restart unless-stopped \
  -e TZ=Europe/Berlin \
  -p 127.0.0.1:8080:8080 \
  --read-only --tmpfs /run --tmpfs /tmp \
  --cap-drop ALL --cap-add SETUID --cap-add SETGID \
  --security-opt no-new-privileges:true \
  -v "$PWD/jobs.cron:/config/jobs.cron:ro" \
  ghcr.io/celestial0579/webcron:latest
```

(Oder [docker-compose.yml](docker-compose.yml) anpassen und
`docker compose up -d`.)

## 4. Kontrollieren

- Status-Übersicht im Browser: `http://127.0.0.1:8080/` (auf dem Docker-Host; von anderen Rechnern per SSH-Tunnel `ssh -L 8080:127.0.0.1:8080 <host>`)
- Logs: `docker logs webcron` — jede Zeile mit Zeit, HTTP-Code, Dauer

## 5. Jobs ändern

`jobs.cron` bearbeiten, dann:

```bash
docker restart webcron
```

Häufigster Stolperstein: Der Container startet nicht? Dann lehnt er eine
kaputte Zeile ab — `docker logs webcron` nennt Zeile und Grund.
