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

aufraeumen() {
    if [[ $BEHALTEN -eq 1 ]]; then
        echo
        echo "Aufbau bleibt stehen. Abbauen mit:"
        echo "  ${COMPOSE[*]} down -v"
        return
    fi
    echo
    echo "--- Abbau ---"
    "${COMPOSE[@]}" down -v --remove-orphans >/dev/null 2>&1 || true
}
trap aufraeumen EXIT

fehler=0
pruefe() {  # pruefe "<Beschreibung>" <Befehl...>
    local beschreibung="$1"; shift
    if "$@" >/tmp/pruefung.log 2>&1; then
        echo "  OK    $beschreibung"
    else
        echo "  FEHL  $beschreibung"
        sed 's/^/          /' /tmp/pruefung.log | head -20
        fehler=$((fehler + 1))
    fi
}
pruefe_scheitert() {  # wie pruefe, aber der Befehl MUSS fehlschlagen
    local beschreibung="$1"; shift
    if "$@" >/tmp/pruefung.log 2>&1; then
        echo "  FEHL  $beschreibung (Befehl war unerwartet erfolgreich)"
        sed 's/^/          /' /tmp/pruefung.log | head -20
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
    > /tmp/pruefen-ausgabe.txt 2>&1 || true
pruefe "--pruefen nennt den Header-Namen (maskiert)" \
    grep -q 'X-Cron-Secret:\*\*\*' /tmp/pruefen-ausgabe.txt
pruefe_scheitert "--pruefen verraet den Header-Wert nicht" \
    grep -q 'geheim' /tmp/pruefen-ausgabe.txt

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

echo
echo "--- Status-UI ---"
status_ui > /tmp/statusseite.html || : > /tmp/statusseite.html
pruefe "Statusseite antwortet" test -s /tmp/statusseite.html
pruefe "Statusseite zeigt den Job" grep -q "http://ziel/takt" /tmp/statusseite.html
pruefe "Statusseite zeigt das Ergebnis OK" grep -q "OK (HTTP 200)" /tmp/statusseite.html

echo
if [[ $fehler -gt 0 ]]; then
    echo "ERGEBNIS: $fehler Pruefung(en) fehlgeschlagen"
    exit 1
fi
echo "ERGEBNIS: alle Pruefungen bestanden"
