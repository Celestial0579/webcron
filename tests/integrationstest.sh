#!/usr/bin/env bash
# Integrationstest: baut das Abbild und prueft es gegen einen
# Wegwerf-Webserver — keine einzige echte Fremd-URL wird angefasst.
#
#   tests/integrationstest.sh              aufraeumen am Ende
#   tests/integrationstest.sh --behalten   Aufbau stehen lassen
set -euo pipefail

cd "$(dirname "$0")/.."

BEHALTEN=0
[[ "${1:-}" == "--behalten" ]] && BEHALTEN=1

# Auf dem Entwicklungsrechner koennen mehrere Instanzen parallel testen —
# deshalb der Namensraum aus dem Branch. Ausserhalb genuegt ein fester Name.
if command -v arbeit >/dev/null 2>&1; then
    PROJEKT="$(arbeit ns)-webcron-test"
else
    PROJEKT="webcron-test"
fi

COMPOSE=(docker compose -f docker-compose.test.yml -p "$PROJEKT")

# Zwischendateien pro Lauf, damit parallele Laeufe sich nicht stoeren.
ARBEIT=$(mktemp -d)

aufraeumen() {
    if [[ $BEHALTEN -eq 1 ]]; then
        echo
        echo "Aufbau bleibt stehen. Abbauen mit:"
        echo "  ${COMPOSE[*]} down -v"
        return
    fi
    echo
    echo "--- Abbau ---"
    rm -rf "$ARBEIT"
    "${COMPOSE[@]}" down -v --remove-orphans >/dev/null 2>&1 || true
}
trap aufraeumen EXIT

fehler=0
pruefe() {  # pruefe "<Beschreibung>" <Befehl...>
    local beschreibung="$1"; shift
    if "$@" >"$ARBEIT/pruefung.log" 2>&1; then
        echo "  OK    $beschreibung"
    else
        echo "  FEHL  $beschreibung"
        sed 's/^/          /' "$ARBEIT/pruefung.log" | head -20
        fehler=$((fehler + 1))
    fi
}
pruefe_scheitert() {  # wie pruefe, aber der Befehl MUSS fehlschlagen
    local beschreibung="$1"; shift
    if "$@" >"$ARBEIT/pruefung.log" 2>&1; then
        echo "  FEHL  $beschreibung (Befehl war unerwartet erfolgreich)"
        sed 's/^/          /' "$ARBEIT/pruefung.log" | head -20
        fehler=$((fehler + 1))
    else
        echo "  OK    $beschreibung"
    fi
}

log_enthaelt() {  # log_enthaelt <dienst> <muster>
    "${COMPOSE[@]}" logs "$1" 2>/dev/null | grep -q "$2"
}

# Wartet, bis ein Muster im Log eines Dienstes auftaucht. Ein starres
# `sleep` reicht nicht: Auf langsamen CI-Runnern hinkt der Docker-Logstrom
# dem Ereignis um Sekunden hinterher — genau daran ist ein Lauf schon
# gescheitert, obwohl der Aufruf selbst laengst durch war.
warte_auf_log() {  # warte_auf_log <dienst> <muster> <sekunden>
    local rest="$3"
    while (( rest > 0 )); do
        log_enthaelt "$1" "$2" && return 0
        sleep 1
        rest=$((rest - 1))
    done
    log_enthaelt "$1" "$2"
}

ui_prozess_nobody() {
    "${COMPOSE[@]}" exec -T webcron ps -o user,args | grep '[h]ttpd' | grep -q '^nobody'
}

status_ui() {
    "${COMPOSE[@]}" exec -T webcron curl -sf http://127.0.0.1:8080/cgi-bin/status
}

echo "--- Aufbau (Projekt: $PROJEKT) ---"
"${COMPOSE[@]}" up -d --build

echo
echo "--- Konfigurationspruefung ---"
pruefe "gueltige Konfiguration wird angenommen" \
    "${COMPOSE[@]}" run --rm --no-deps webcron --pruefen
pruefe_scheitert "kaputte Konfiguration wird abgelehnt" \
    "${COMPOSE[@]}" run --rm --no-deps -e WEBCRON_JOBS=/tests/kaputt.cron webcron --pruefen
pruefe_scheitert "fehlende Konfiguration fuehrt zum Abbruch" \
    "${COMPOSE[@]}" run --rm --no-deps -e WEBCRON_JOBS=/gibts/nicht webcron --pruefen
pruefe_scheitert "kaputte Kopfzeile wird abgelehnt" \
    "${COMPOSE[@]}" run --rm --no-deps -e WEBCRON_JOBS=/tests/kaputt-kopf.cron webcron --pruefen

# Header-Werte sind Secrets. Sie duerfen in keiner Ausgabe auftauchen —
# genau das ist schon passiert: Die Startausgabe druckte die rohe Crontab
# samt X-Cron-Secret-Wert in die Container-Logs.
"${COMPOSE[@]}" run --rm --no-deps -e WEBCRON_JOBS=/tests/kopf.cron webcron --pruefen \
    > "$ARBEIT/pruefen-ausgabe.txt" 2>&1 || true
pruefe "--pruefen nennt den Header-Namen (maskiert)" \
    grep -q 'X-Cron-Secret:\*\*\*' "$ARBEIT/pruefen-ausgabe.txt"
pruefe_scheitert "--pruefen verraet den Header-Wert nicht" \
    grep -q 'geheim' "$ARBEIT/pruefen-ausgabe.txt"

# Konfigurationsdatei mit Windows-Zeilenenden (CRLF) ist gueltig, eine mit
# Steuerzeichen nicht -- beides wird im Container erzeugt, nicht im Repo
# (git koennte Zeilenenden umschreiben).
pruefe "Konfiguration mit CRLF-Zeilenenden wird angenommen" \
    "${COMPOSE[@]}" run --rm --no-deps --entrypoint sh webcron -c \
    "printf '* * * * *  http://ziel/takt  X-K:v\\r\\n' > /tmp/j.cron && WEBCRON_JOBS=/tmp/j.cron webcron --pruefen"
pruefe_scheitert "Konfiguration mit Steuerzeichen wird abgelehnt" \
    "${COMPOSE[@]}" run --rm --no-deps --entrypoint sh webcron -c \
    "printf '* * * * *  http://ziel/ta\\033kt\\n' > /tmp/j.cron && WEBCRON_JOBS=/tmp/j.cron webcron --pruefen"

# Rechte der Konfigurationsdatei: Die Testdaten sind nur fuer root lesbar
# (siehe docker-compose.test.yml) -- wie im Betrieb. Eine fuer alle lesbare
# Datei muss eine Warnung ausloesen, eine unlesbare einen klaren Abbruch.
"${COMPOSE[@]}" run --rm --no-deps webcron --pruefen > "$ARBEIT/rechte-root.txt" 2>&1 || true
pruefe "nur root lesbare Konfiguration wird angenommen" \
    grep -q 'Konfiguration in Ordnung' "$ARBEIT/rechte-root.txt"
pruefe_scheitert "nur root lesbare Konfiguration: keine Warnung" \
    grep -q WARNUNG "$ARBEIT/rechte-root.txt"
"${COMPOSE[@]}" run --rm --no-deps --entrypoint sh webcron -c \
    'cp /tests/takt.cron /tmp/offen.cron && chmod 644 /tmp/offen.cron && WEBCRON_JOBS=/tmp/offen.cron webcron --pruefen' \
    > "$ARBEIT/rechte-offen.txt" 2>&1 || true
pruefe "fuer alle lesbare Konfiguration: --pruefen warnt" \
    grep -q WARNUNG "$ARBEIT/rechte-offen.txt"
rc=0
"${COMPOSE[@]}" run --rm --no-deps --entrypoint sh webcron -c \
    'cp /tests/takt.cron /tmp/zu.cron && chmod 000 /tmp/zu.cron && WEBCRON_JOBS=/tmp/zu.cron webcron --pruefen' \
    > "$ARBEIT/rechte-zu.txt" 2>&1 || rc=$?
pruefe "Konfiguration ohne Leserecht: Abbruch mit Exit != 0" test "$rc" -ne 0
pruefe "Konfiguration ohne Leserecht: Meldung nennt das Problem" \
    grep -q 'nicht lesbar' "$ARBEIT/rechte-zu.txt"

# Meldungen zu kaputten Zeilen duerfen keine Teile der Zeile nennen: sie
# landen in den Container-Logs. Je Fall: --pruefen muss scheitern und darf
# keinen der Werte 'geheimN' ausgeben.
lehne_ab_ohne_wert() {  # lehne_ab_ohne_wert "<Beschreibung>" "<Zeile>"
    local beschreibung="$1" zeile="$2"
    if "${COMPOSE[@]}" run --rm --no-deps --entrypoint sh webcron -c \
        "printf '%s\\n' '$zeile' > /tmp/j.cron && WEBCRON_JOBS=/tmp/j.cron webcron --pruefen" \
        > "$ARBEIT/ablehnung.txt" 2>&1; then
        echo "  FEHL  $beschreibung (wurde angenommen)"
        fehler=$((fehler + 1))
    elif grep -q 'geheim' "$ARBEIT/ablehnung.txt"; then
        echo "  FEHL  $beschreibung (Meldung nennt einen Wert)"
        sed 's/^/          /' "$ARBEIT/ablehnung.txt" | head -20
        fehler=$((fehler + 1))
    else
        echo "  OK    $beschreibung"
    fi
}
lehne_ab_ohne_wert "Meldung nennt bei fehlendem Cron-Feld die Zeile nicht" \
    '0 0 1 http://ziel/x?token=geheim5 X-K:geheim6'
lehne_ab_ohne_wert "Meldung nennt bei verschobenen Feldern die URL nicht" \
    '0 0 1 http://ziel/x?token=geheim5 X-K:geheim6 X-L:geheim6'
lehne_ab_ohne_wert "Meldung nennt bei falschem Schema die URL nicht" \
    '0 0 1 1 * htps://nutzer:geheim5@ziel/x?t=geheim5'
lehne_ab_ohne_wert "Meldung nennt bei ungueltigem Header-Namen den Wert nicht" \
    '0 0 1 1 * http://ziel/x X_Api_Key:geheim6'
lehne_ab_ohne_wert "Meldung nennt bei 'Authorization:Bearer <token>' das Token nicht" \
    '0 0 1 1 * http://ziel/x Authorization:Bearer geheim7'

# Scheitert mktemp, bricht webcron-abruf ab, ohne irgendetwas zu loeschen
# (frueher stand dort ein Ausweichpfad /dev/null, den die Trap entfernte).
# mktemp scheitert hier an einem Verzeichnis ohne Schreibrecht (root hat im
# Testaufbau kein CAP_DAC_OVERRIDE); eine Attrappe in /tmp ginge nicht, denn
# Dockers tmpfs ist noexec.
# Das Skript in Hochkommas soll erst im Container expandiert werden:
# shellcheck disable=SC2016
pruefe "ohne Zwischendatei: Abbruch mit Meldung, /dev/null bleibt Geraet" \
    "${COMPOSE[@]}" run --rm --no-deps --entrypoint sh webcron -c '
        mkdir -p /tmp/l/jobs
        echo http://ziel/takt > /tmp/l/jobs/1
        chmod 555 /tmp/l
        WEBCRON_LAUFDIR=/tmp/l webcron-abruf --job 1 2>/tmp/fehler; rc=$?
        [ "$rc" = 2 ] && grep -q Zwischendatei /tmp/fehler && [ -c /dev/null ]'

echo
echo "--- Einmal-Modus ---"
pruefe "erreichbare URL wird als OK gewertet" \
    "${COMPOSE[@]}" run --rm -e WEBCRON_JOBS=/tests/einmal.cron webcron --einmal
pruefe_scheitert "HTTP 404 wird als Fehler gewertet" \
    "${COMPOSE[@]}" run --rm -e WEBCRON_JOBS=/tests/fehl.cron webcron --einmal
pruefe "Kopfzeile wird mitgesendet (Ziel verlangt X-Cron-Secret)" \
    "${COMPOSE[@]}" run --rm -e WEBCRON_JOBS=/tests/kopf.cron webcron --einmal
pruefe_scheitert "Gegenprobe: ohne Kopfzeile lehnt das Ziel mit 403 ab" \
    "${COMPOSE[@]}" run --rm -e WEBCRON_JOBS=/tests/kopf-ohne.cron webcron --einmal

"${COMPOSE[@]}" run --rm -e WEBCRON_JOBS=/tests/verbindung-fehlt.cron webcron --einmal \
    > "$ARBEIT/verbindung.txt" 2>&1 || true
pruefe "Aufruf ohne Verbindung wird als Fehler gemeldet" \
    grep -q 'FEHLER' "$ARBEIT/verbindung.txt"
pruefe_scheitert "die Ausgabe zu einer gescheiterten Verbindung nennt keinen URL-Teil" \
    grep -q 'geheim4' "$ARBEIT/verbindung.txt"

pruefe_scheitert "Kopfzeilen-Job folgt keiner Weiterleitung (3xx ist Fehler)" \
    "${COMPOSE[@]}" run --rm -e WEBCRON_JOBS=/tests/weiter.cron webcron --einmal
pruefe_scheitert "das Weiterleitungsziel wurde nie angefragt" \
    log_enthaelt ziel 'GET /sekundaer'

echo
echo "--- crond-Betrieb (warte auf den ersten Takt, bis zu 90 s) ---"
pruefe "crond ruft die URL nach Zeitplan auf" \
    warte_auf_log ziel 'GET /takt' 90
pruefe "der Aufruf steht als OK in den Container-Logs" \
    warte_auf_log webcron 'OK  *HTTP 200 .* http://ziel/takt' 30
pruefe "auch der Kopfzeilen-Job kommt durch die Crontab (HTTP 200 auf /kopf)" \
    warte_auf_log webcron 'OK  *HTTP 200 .* http://ziel/kopf' 30
pruefe_scheitert "das Startprotokoll verraet den Header-Wert nicht" \
    log_enthaelt webcron 'geheim'
pruefe "URL mit %-Kodierung kommt samt Kopfzeile an (Ziel antwortet 200)" \
    warte_auf_log webcron 'OK  *HTTP 200 .* http://ziel/kopf?\*\*\*' 30
pruefe "der Aufruf mit Query-String kam beim Ziel an" \
    warte_auf_log ziel 'GET /takt?token=geheim2' 30
pruefe_scheitert "der Query-String steht in keinem Log von webcron (crond-Joblog eingeschlossen)" \
    log_enthaelt webcron 'geheim2'
pruefe "eckige Klammern in der URL kommen wortwoertlich beim Ziel an (kein curl-Globbing)" \
    warte_auf_log ziel 'GET /takt?a\[0\]=1&token=geheim3' 30
pruefe_scheitert "kein Log von webcron nennt den Query-String mit Klammern (curl-Fehlermeldung)" \
    log_enthaelt webcron 'geheim3'
pruefe_scheitert "kein Log von webcron meldet ein ungueltiges curl-Muster" \
    log_enthaelt webcron 'bad range'

echo
echo "--- Status-UI ---"
status_ui > "$ARBEIT/statusseite.html" || : > "$ARBEIT/statusseite.html"
pruefe "Status-UI (httpd) laeuft als nobody" \
    ui_prozess_nobody
pruefe_scheitert "nobody kann die Jobdateien (Secrets) nicht lesen" \
    "${COMPOSE[@]}" exec -T --user nobody webcron cat /run/webcron/jobs/2
# $WEBCRON_JOBS soll erst im Container expandiert werden:
# shellcheck disable=SC2016
pruefe_scheitert "nobody kann auch die Konfigurationsdatei selbst nicht lesen" \
    "${COMPOSE[@]}" exec -T --user nobody webcron sh -c 'cat "$WEBCRON_JOBS"'
# shellcheck disable=SC2016
pruefe "Gegenprobe: root liest die Konfigurationsdatei" \
    "${COMPOSE[@]}" exec -T webcron sh -c 'cat "$WEBCRON_JOBS"'
pruefe_scheitert "Dateisystem ist schreibgeschuetzt" \
    "${COMPOSE[@]}" exec -T webcron touch /usr/schreibtest
pruefe "Statusseite antwortet" test -s "$ARBEIT/statusseite.html"
pruefe "Statusseite zeigt den Job" grep -q "http://ziel/takt" "$ARBEIT/statusseite.html"
pruefe "Statusseite zeigt das Ergebnis OK" grep -q "OK (HTTP 200)" "$ARBEIT/statusseite.html"

echo
if [[ $fehler -gt 0 ]]; then
    echo "ERGEBNIS: $fehler Pruefung(en) fehlgeschlagen"
    exit 1
fi
echo "ERGEBNIS: alle Pruefungen bestanden"
