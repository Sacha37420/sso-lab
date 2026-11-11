#!/usr/bin/env python3
"""Faux GitHub des essais du moteur : API REST minimale sur 127.0.0.1 (port libre).

  faux-github.py <dossier>    écrit <dossier>/port, puis sert jusqu'à être tué.
  FAUX_GH_TOKEN   jeton attendu (Bearer) — un autre jeton reçoit 401
  FAUX_GH_SCOPES  valeur de l'en-tête X-OAuth-Scopes rendu par GET /user (fichier <dossier>/scopes s'il existe)
Chaque POST /repos/<o>/<r>/pulls est ajouté à <dossier>/pulls.jsonl (sans l'en-tête
d'autorisation, mais avec « auth_ok »).
"""
import http.server
import json
import os
import sys

D = sys.argv[1]
TOKEN = os.environ.get("FAUX_GH_TOKEN", "")


class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _auth(self):
        return self.headers.get("Authorization", "") == f"Bearer {TOKEN}"

    def _send(self, code, obj, headers=None):
        b = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def do_GET(self):
        if not self._auth():
            return self._send(401, {"message": "Bad credentials"})
        if self.path == "/user":
            p = os.path.join(D, "scopes")
            scopes = open(p).read().strip() if os.path.exists(p) else os.environ.get("FAUX_GH_SCOPES", "")
            return self._send(200, {"login": "essai"}, {"X-OAuth-Scopes": scopes} if scopes else {})
        if self.path.startswith("/repos/"):
            return self._send(200, {"full_name": self.path[7:]})
        self._send(404, {"message": "Not Found"})

    def do_POST(self):
        n = int(self.headers.get("Content-Length", "0"))
        body = json.loads(self.rfile.read(n) or b"{}")
        if self.path.endswith("/pulls"):
            rec = {"path": self.path, "auth_ok": self._auth(), **body}
            with open(os.path.join(D, "pulls.jsonl"), "a") as f:
                f.write(json.dumps(rec, ensure_ascii=False) + "\n")
            if not self._auth():
                return self._send(401, {"message": "Bad credentials"})
            repo = self.path.split("/")[3]
            return self._send(201, {"html_url": f"https://github.example/{repo}/pull/{len(open(os.path.join(D, 'pulls.jsonl')).readlines())}"})
        self._send(404, {"message": "Not Found"})


s = http.server.HTTPServer(("127.0.0.1", 0), H)
with open(os.path.join(D, "port"), "w") as f:
    f.write(str(s.server_address[1]))
s.serve_forever()
