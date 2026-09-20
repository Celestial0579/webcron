# Traeger fuer die Testdaten. Wird nur von docker-compose.test.yml benutzt
# und liefert den Inhalt von tests/ in ein Volume, aus dem sich sowohl der
# webcron-Container als auch der Wegwerf-Webserver bedienen.
#
# Warum nicht einfach ./tests einhaengen? Ein Bind-Mount wird vom
# Docker-Daemon aufgeloest, nicht von dem, der den Befehl absetzt. Laeuft der
# Test in einem Container, der nur den Socket des Wirts benutzt (CI,
# Docker-im-Docker), sucht der Wirt den Pfad in SEINEM Dateisystem -- dort
# gibt es ihn nicht, und er legt stillschweigend ein leeres Verzeichnis an.
# Der Container findet dann keine einzige Testdatei.
#
# Ein Bauauftrag schickt seinen Kontext als Datenstrom durch den Socket und
# kennt dieses Problem nicht -- innen wie aussen, hier wie auf GitHub.
#
# Die Testdaten gehoeren ausdruecklich NICHT ins Anwendungsabbild: das baut
# unveraendert aus dem Dockerfile im Wurzelverzeichnis.
FROM alpine:3.22
COPY . /vorlage/
