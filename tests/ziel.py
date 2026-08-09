"""Wegwerf-Webserver fuer den Integrationstest.

/takt und /einmal antworten 200, /kopf verlangt die Kopfzeile
X-Cron-Secret mit dem Wert 'geheim' (wie es z. B. der Cron-Endpunkt des
Hengstverzeichnis-Frameworks tut), alles andere ist 404. Jede Anfrage
landet im Log (stderr) — darauf wartet der Test.
"""
from http.server import BaseHTTPRequestHandler, HTTPServer


class Ziel(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/kopf":
            if self.headers.get("X-Cron-Secret") == "geheim":
                self.send_response(200)
            else:
                self.send_response(403)
        elif self.path in ("/takt", "/einmal"):
            self.send_response(200)
        else:
            self.send_response(404)
        self.end_headers()
        self.wfile.write(b"ok\n")


HTTPServer(("", 80), Ziel).serve_forever()
