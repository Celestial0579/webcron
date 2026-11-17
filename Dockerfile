FROM alpine:3.24@sha256:f59abe656b692d901e184be3445e084786602108599d2a51d229c0f5a48c71bf

# curl macht die eigentlichen Aufrufe. tzdata sorgt dafuer, dass
# TZ=Europe/Berlin wirklich Berliner Zeit bedeutet. busybox-extras bringt
# den httpd fuer die Status-UI.
#
# supercronic ersetzt den busybox-crond (#25): Der braucht root, um je Job die
# Identitaet zu wechseln; supercronic laeuft als gewoehnlicher Benutzer und
# fuehrt die Jobs unter derselben Identitaet aus. su-exec gibt beim Start die
# root-Rechte ab, bevor der Zeitplaner laeuft.
RUN apk add --no-cache curl tzdata busybox-extras supercronic su-exec \
    && addgroup -S -g 10001 webcron \
    && adduser -S -D -H -u 10001 -G webcron -s /sbin/nologin webcron

# /run muss fuer den Dienst-Benutzer beschreibbar sein: Er legt dort das
# Laufverzeichnis /run/webcron an. Ein tmpfs auf /run (read_only-Betrieb)
# uebernimmt die Rechte dieses Verzeichnisses.
RUN chmod 1777 /run

# /config nur fuer root: Wird die Konfiguration als Einzeldatei nach
# /config/jobs.cron gemountet, kommt der Status-UI-Prozess (nobody) nicht
# bis zur Datei, egal welche Rechte sie auf dem Host hat.
RUN mkdir -m 0700 /config

COPY bin/webcron bin/webcron-abruf /usr/local/bin/
COPY www /www
RUN chmod -R a+rX /www && chmod 755 /www/cgi-bin/status

# Kein Dauerprozess laeuft als root (#25). Der Container startet als root,
# weil nur root die nur fuer root lesbare Konfiguration einlesen und die
# Status-UI (httpd, Benutzer nobody) und den Zeitplaner (supercronic,
# Benutzer webcron) unter getrennten Benutzern starten kann. `webcron` gibt
# die Rechte ab und ersetzt sich per exec durch supercronic; danach gehoert
# keinem Prozess mehr root, und supercronic ist PID 1. Der Container
# veroeffentlicht von sich aus keinen Port und fuehrt nur die konfigurierten
# Aufrufe aus.
#
# Der Healthcheck laeuft mit dem Benutzer des Containers, also als root. Den
# Abruf der Status-UI macht er deshalb per su-exec als nobody (#28): Deren
# Antwort wertet kein root-Prozess aus. Laeuft der Container ohne root, ruft
# er curl direkt auf, wie bin/webcron beim Start.
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD sh -c 'pidof supercronic >/dev/null && { [ "${WEBCRON_UI_PORT:-8080}" = "0" ] || { if [ "$(id -u)" = 0 ]; then set -- su-exec nobody; fi; "$@" curl -sf "http://127.0.0.1:${WEBCRON_UI_PORT:-8080}/cgi-bin/status" >/dev/null; }; }'

ENTRYPOINT ["webcron"]
