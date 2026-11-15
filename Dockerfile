FROM alpine:3.24@sha256:f59abe656b692d901e184be3445e084786602108599d2a51d229c0f5a48c71bf

# curl macht die eigentlichen Aufrufe. tzdata sorgt dafuer, dass
# TZ=Europe/Berlin wirklich Berliner Zeit bedeutet. busybox-extras bringt
# den httpd fuer die Status-UI, tini raeumt die von crond und httpd
# gestarteten Kindprozesse ab.
RUN apk add --no-cache curl tzdata tini busybox-extras

# /config nur fuer root: Wird die Konfiguration als Einzeldatei nach
# /config/jobs.cron gemountet, kommt der Status-UI-Prozess (nobody) nicht
# bis zur Datei, egal welche Rechte sie auf dem Host hat.
RUN mkdir -m 0700 /config

COPY bin/webcron bin/webcron-abruf /usr/local/bin/
COPY www /www
RUN chmod -R a+rX /www && chmod 755 /www/cgi-bin/status

# crond braucht root, um /etc/crontabs/root zu lesen und Jobs zu starten;
# der Container bleibt deshalb bei root. Er veroeffentlicht von sich aus
# keinen Port und fuehrt nur die konfigurierten Aufrufe aus.
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD sh -c 'pidof crond >/dev/null && { [ "${WEBCRON_UI_PORT:-8080}" = "0" ] || curl -sf "http://127.0.0.1:${WEBCRON_UI_PORT:-8080}/cgi-bin/status" >/dev/null; }'

ENTRYPOINT ["/sbin/tini", "--", "webcron"]
