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
getroffen=""
for _ in $(seq 1 90); do
    if log_enthaelt ziel 'GET /takt'; then getroffen=ja; break; fi
    sleep 1
done
# Beide Jobs feuern in derselben Minute; dem zweiten einen Moment geben.
sleep 3
pruefe "crond ruft die URL nach Zeitplan auf" test -n "$getroffen"
pruefe "der Aufruf steht als OK in den Container-Logs" \
    log_enthaelt webcron 'OK  *HTTP 200 .* http://ziel/takt'
pruefe "auch der Kopfzeilen-Job kommt durch die Crontab (HTTP 200 auf /kopf)" \
    log_enthaelt webcron 'OK  *HTTP 200 .* http://ziel/kopf'

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
