"""Doubles LOCAUX AUX TESTS d'oauth-hub et de l'API GitHub.

Ne servent qu'à éprouver le FORMAT des échanges et les REFUS (compte non relié,
client non autorisé, portée manquante, suppression de dépôt refusée) tant
qu'oauth-hub ne fait pas confiance à `lab-mcp`. Rien ici n'est copié dans
l'image (voir .dockerignore) ni utilisé par le serveur en service.

Comportement piloté par des fichiers, pour changer de cas sans redémarrer :
  /tmp/hub-mode    ok (défaut) | untrusted | noscope
  /tmp/gh-delete   ok (défaut) | forbidden
Le compte `devtestb` n'est jamais relié (409).
"""
import base64
import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

FAKE_GH_TOKEN = "gho_FAUX_JETON_DE_TEST_0123456789"
HUB_PORT, GH_PORT = 9101, 9102
created_repos: set[str] = set()


def _mode(path: str, default: str) -> str:
    try:
        return open(path).read().strip() or default
    except OSError:
        return default


def _claims(handler) -> dict:
    auth = handler.headers.get("Authorization", "")
    try:
        payload = auth.split(" ", 1)[1].split(".")[1]
        return json.loads(base64.urlsafe_b64decode(payload + "=" * (-len(payload) % 4)))
    except Exception:
        return {}


class _Base(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _send(self, code: int, body=None):
        data = b"" if body is None else json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _body(self) -> dict:
        n = int(self.headers.get("Content-Length") or 0)
        return json.loads(self.rfile.read(n) or b"{}")


class Hub(_Base):
    """Mêmes chemins, codes et champs que oauth-hub (README, « Contrat d'interface »)."""

    def do_GET(self):
        claims = _claims(self)
        uid = claims.get("preferred_username", "")
        mode = _mode("/tmp/hub-mode", "ok")
        connect = "https://lab.example/oauth-hub/providers?connect=github"
        if mode == "untrusted":
            return self._send(403, {"detail": f"Ce token a été émis par un client non autorisé : '{claims.get('azp')}'. "
                                              "Un développeur doit ajouter ce client_id dans la page « Apps autorisées »"})
        linked = uid != "devtestb"
        scope = "read:user" if mode == "noscope" else "read:user,repo"
        if self.path.startswith("/api/providers/github/status/"):
            return self._send(200, {"provider": "github", "display_name": "GitHub", "configured": True,
                                    "connected": linked, "scope": scope if linked else "",
                                    "account_label": "devtest-gh" if linked else "", "connect_url": connect})
        if self.path.startswith("/api/providers/github/token/"):
            if not linked:
                return self._send(409, {"detail": "Vous n'avez pas encore relié votre compte GitHub.",
                                        "provider": "github", "connect_url": connect})
            return self._send(200, {"access_token": FAKE_GH_TOKEN, "token_type": "bearer",
                                    "scope": scope, "expires_at": None})
        self._send(404, {"detail": "not found"})


class Gh(_Base):
    def _log(self):
        ok = self.headers.get("Authorization", "") == f"Bearer {FAKE_GH_TOKEN}"
        with open("/tmp/gh-requests.log", "a") as fh:
            fh.write(f"{self.command} {self.path} jeton_attendu={'oui' if ok else 'NON'}\n")
        return ok

    def do_GET(self):
        if not self._log():
            return self._send(401, {"message": "Bad credentials"})
        if self.path == "/user":
            return self._send(200, {"login": "devtest-gh", "id": 4242, "name": "Dev Test"})
        if self.path.startswith("/repos/") and "/commits" in self.path:
            return self._send(200, [
                {"sha": open("/tmp/gh-head").read().strip() if __import__("os").path.exists("/tmp/gh-head") else "a" * 40,
                 "commit": {"message": "feat: dernier commit\n\ncorps", "author": {"name": "Dev Test", "date": "2026-10-10T12:00:00Z"}}},
                {"sha": "b" * 40, "commit": {"message": "feat: initial scaffold", "author": {"name": "Dev Test", "date": "2026-10-09T12:00:00Z"}}}])
        if self.path.startswith("/repos/"):
            full = self.path[len("/repos/"):]
            if full.count("/") == 1 and (full in created_repos or full.startswith("Sacha37420/") or _mode("/tmp/gh-repos", "") == "all"):
                return self._send(200, {"full_name": full, "default_branch": "main"})
            if full in created_repos or full.endswith("/deja-pris"):
                return self._send(200, {"full_name": full})
            return self._send(404, {"message": "Not Found"})
        self._send(404, {"message": "Not Found"})

    def do_POST(self):
        if not self._log():
            return self._send(401, {"message": "Bad credentials"})
        body = self._body()
        if self.path == "/user/repos":
            created_repos.add(f"devtest-gh/{body['name']}")
            with open("/tmp/gh-requests.log", "a") as fh:
                fh.write(f"   corps création : {json.dumps(body, ensure_ascii=False)}\n")
            return self._send(201, {"full_name": f"devtest-gh/{body['name']}", "private": body.get("private")})
        if self.path.startswith("/repos/") and (self.path.endswith("/keys") or self.path.endswith("/hooks")):
            if self.path.endswith("/keys") and _mode("/tmp/gh-keys", "ok") == "forbidden":
                return self._send(403, {"message": "Resource not accessible by integration"})
            with open("/tmp/gh-requests.log", "a") as fh:
                shown = dict(body)
                if "config" in shown:
                    shown["config"] = {**shown["config"], "secret": "<%d car.>" % len(shown["config"].get("secret", ""))}
                fh.write(f"   corps : {json.dumps(shown, ensure_ascii=False)[:300]}\n")
            return self._send(201, {"id": 4321})
        if self.path.startswith("/repos/") and self.path.endswith("/issues"):
            repo = self.path[len("/repos/"):-len("/issues")]
            with open("/tmp/gh-requests.log", "a") as fh:
                fh.write(f"   corps ticket : {json.dumps(body, ensure_ascii=False)}\n")
            return self._send(201, {"number": 7, "html_url": f"https://github.com/{repo}/issues/7"})
        self._send(404, {"message": "Not Found"})

    def do_DELETE(self):
        if not self._log():
            return self._send(401, {"message": "Bad credentials"})
        if _mode("/tmp/gh-delete", "ok") == "forbidden":
            return self._send(403, {"message": "Must have admin rights to Repository."})
        created_repos.discard(self.path[len("/repos/"):])
        self._send(204)


def start() -> None:
    for port, handler in ((HUB_PORT, Hub), (GH_PORT, Gh)):
        srv = ThreadingHTTPServer(("127.0.0.1", port), handler)
        threading.Thread(target=srv.serve_forever, daemon=True).start()
