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
  -p 8080:8080 \
  -v "$PWD/jobs.cron:/config/jobs.cron:ro" \
  ghcr.io/celestial0579/webcron:latest
```

(Oder [docker-compose.yml](docker-compose.yml) anpassen und
`docker compose up -d`.)

## 4. Kontrollieren

- Status-Übersicht im Browser: `http://<host>:8080/`
- Logs: `docker logs webcron` — jede Zeile mit Zeit, HTTP-Code, Dauer

## 5. Jobs ändern

`jobs.cron` bearbeiten, dann:

```bash
docker restart webcron
```

Häufigster Stolperstein: Der Container startet nicht? Dann lehnt er eine
kaputte Zeile ab — `docker logs webcron` nennt Zeile und Grund.
