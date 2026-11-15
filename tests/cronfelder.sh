#!/bin/sh
# Prueft, dass `webcron --pruefen` Cron-Felder nach Wertebereich beurteilt.
# Laeuft im Container (siehe tests/integrationstest.sh), braucht nur sh und
# webcron im PATH.
DATEI=$(mktemp)
trap 'rm -f "$DATEI"' EXIT
fehler=0

# erwarte ok|fehl '<5 Cron-Felder>'
erwarte() {
    printf '%s http://ziel/x\n' "$2" > "$DATEI"
    if WEBCRON_JOBS="$DATEI" webcron --pruefen >/dev/null 2>&1; then ist=ok; else ist=fehl; fi
    if [ "$ist" = "$1" ]; then
        echo "  OK    $1: $2"
    else
        echo "  FEHL  '$2' sollte $1 sein, ist aber $ist"
        fehler=$((fehler + 1))
    fi
}

# gueltig
erwarte ok '* * * * *'
erwarte ok '0 3 * * 0'
erwarte ok '59 23 31 12 6'
erwarte ok '0 0 1 1 0'
erwarte ok '*/15 0-23 1-31 1-12 0-6'
erwarte ok '0,30 8-18/2 1,15 * 1-5'
erwarte ok '07 08 09 * *'
erwarte ok '*/60 * * * *'
erwarte ok '1-5 * * * *'
# ausserhalb des Bereichs: busybox-crond fuehrte sie trotzdem aus
erwarte fehl '0 3 * * 7'
erwarte fehl '75 3 * * *'
erwarte fehl '60 * * * *'
erwarte fehl '* 24 * * *'
erwarte fehl '* * 0 * *'
erwarte fehl '* * 32 * *'
erwarte fehl '* * * 0 *'
erwarte fehl '* * * 13 *'
erwarte fehl '1-70 * * * *'
erwarte fehl '0-60 * * * *'
erwarte fehl '5,75 * * * *'
# unsinnige Form
erwarte fehl '5-3 * * * *'
erwarte fehl '*/0 * * * *'
erwarte fehl '*/61 * * * *'
erwarte fehl '0/15 * * * *'
erwarte fehl '1,,2 * * * *'
erwarte fehl '1, * * * *'
erwarte fehl ',1 * * * *'
erwarte fehl '1-2-3 * * * *'
erwarte fehl '*-5 * * * *'
erwarte fehl '** * * * *'
erwarte fehl '/5 * * * *'
erwarte fehl '99999999999999999999 * * * *'

# UTF-8-BOM am Dateianfang (PowerShell 5.1: Set-Content -Encoding UTF8)
printf '\357\273\277* * * * * http://ziel/x\n' > "$DATEI"
if WEBCRON_JOBS="$DATEI" webcron --pruefen >/dev/null 2>&1; then
    echo "  OK    Datei mit UTF-8-BOM wird angenommen"
else
    echo "  FEHL  Datei mit UTF-8-BOM wurde abgelehnt"
    fehler=$((fehler + 1))
fi
printf '\357\273\277# Kommentar\n* * * * * http://ziel/x\n' > "$DATEI"
if WEBCRON_JOBS="$DATEI" webcron --pruefen >/dev/null 2>&1; then
    echo "  OK    UTF-8-BOM vor einem Kommentar wird angenommen"
else
    echo "  FEHL  UTF-8-BOM vor einem Kommentar wurde abgelehnt"
    fehler=$((fehler + 1))
fi

[ "$fehler" -eq 0 ] || { echo "$fehler Pruefung(en) fehlgeschlagen"; exit 1; }
echo "alle Pruefungen bestanden"
