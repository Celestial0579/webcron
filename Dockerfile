FROM alpine:3.22

# curl macht die eigentlichen Aufrufe. tzdata sorgt dafuer, dass
# TZ=Europe/Berlin wirklich Berliner Zeit bedeutet. busybox-extras bringt
# den httpd fuer die Status-UI, tini raeumt die von crond und httpd
# gestarteten Kindprozesse ab.
RUN apk add --no-cache curl tzdata tini busybox-extras

COPY bin/webcron bin/webcron-abruf /usr/local/bin/
COPY www /www

# crond braucht root, um /etc/crontabs/root zu lesen und Jobs zu starten;
# der Container bleibt deshalb bei root. Er veroeffentlicht von sich aus
# keinen Port und fuehrt nur die konfigurierten Aufrufe aus.
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD sh -c 'pidof crond >/dev/null && { [ "${WEBCRON_UI_PORT:-8080}" = "0" ] || curl -sf "http://127.0.0.1:${WEBCRON_UI_PORT:-8080}/cgi-bin/status" >/dev/null; }'

ENTRYPOINT ["/sbin/tini", "--", "webcron"]
