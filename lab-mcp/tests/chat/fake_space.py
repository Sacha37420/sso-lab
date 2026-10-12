"""FAUX espace de travail pour l'essai de la passerelle (chantier espace-chat) — bibliothèque
standard seulement. Tient lieu de l'image `lab-workspace` : un « éditeur » sur :8080 et le service
de conversation d'I1 sur :8090 (HTTP + WebSocket, `/healthz`, `/activity`). Chaque réponse dit QUI
a répondu, quel chemin il a vu et quel hôte lui a été transmis : c'est ce que l'essai vérifie.

Variables : WHO (uid), CHAT=off (rien n'écoute sur 8090 : image sans le service), CHAT=later
(le service ne démarre qu'à la commande `chat_in` : démarrage lent).

Commandes de l'essai, sur :8080 et en direct seulement (jamais par la passerelle) :
  /__set?activity=live|old|error|garbage|future|missing   ce que rend /activity
  /__set?beat=live|0                                       battement de l'éditeur (/healthz → lastHeartbeat)
  /__set?chat_in=<secondes>                                (CHAT=later) le service écoutera dans N secondes
  /__conns                                                 connexions ouvertes, par service
"""
import base64, hashlib, json, os, socketserver, threading, time
from http.server import BaseHTTPRequestHandler
from urllib.parse import parse_qs, urlsplit

GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
WHO = os.environ.get("WHO", "?")
STATE = {"activity": "live", "beat": "live", "frozen_ms": 0}
CONNS = {"editor": 0, "chat": 0}
LOCK = threading.Lock()


class Base(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    service = "?"

    def log_message(self, *a):
        pass

    def setup(self):
        super().setup()
        with LOCK:
            CONNS[self.service] += 1

    def finish(self):
        with LOCK:
            CONNS[self.service] -= 1
        super().finish()

    def send_json(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def seen(self, **more):
        return {"qui": WHO, "service": self.service, "methode": self.command, "chemin": self.path,
                "host": self.headers.get("Host"), "x_forwarded_host": self.headers.get("X-Forwarded-Host"),
                "cookie_recu": bool(self.headers.get("Cookie")), **more}

    def public_host(self):
        return self.headers.get("X-Forwarded-Host") or self.headers.get("Host") or ""

    def websocket(self):
        """Poignée de main refusée (403) si l'Origin ne désigne pas l'hôte public — règle d'I1, qui
        est aussi celle de code-server. Puis une trame texte reçue → renvoyée, signée."""
        origin = self.headers.get("Origin", "")
        if urlsplit(origin).netloc != self.public_host():
            self.send_json(403, {"refus": "origin", "origin": origin, "attendu": self.public_host()})
            return
        key = self.headers["Sec-WebSocket-Key"]
        self.send_response(101)
        self.send_header("Upgrade", "websocket")
        self.send_header("Connection", "Upgrade")
        self.send_header("Sec-WebSocket-Accept", base64.b64encode(hashlib.sha1((key + GUID).encode()).digest()).decode())
        self.end_headers()
        self.close_connection = True
        hdr = self.rfile.read(2)
        if len(hdr) < 2:
            return
        n = hdr[1] & 0x7F
        mask = self.rfile.read(4)
        data = bytes(b ^ mask[i % 4] for i, b in enumerate(self.rfile.read(n)))
        out = f"{self.service}@{WHO} {self.path} : ".encode() + data
        self.wfile.write(bytes([0x81, len(out)]) + out)

    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        self.send_json(200, self.seen(corps=self.rfile.read(n).decode("utf-8", "replace")))


class Editor(Base):
    service = "editor"

    def do_GET(self):
        url = urlsplit(self.path)
        if self.headers.get("Upgrade", "").lower() == "websocket":
            return self.websocket()
        if url.path == "/__set":
            for k, v in parse_qs(url.query).items():
                STATE[k] = v[0]
                if k == "activity":
                    STATE["frozen_ms"] = int(time.time() * 1000)
                if k == "chat_in":
                    threading.Timer(float(v[0]), GO.set).start()
            return self.send_json(200, STATE)
        if url.path == "/__conns":
            return self.send_json(200, dict(CONNS))
        if url.path == "/healthz":
            beat = int(time.time() * 1000) if STATE["beat"] == "live" else 0
            return self.send_json(200, {"status": "alive" if beat else "expired", "lastHeartbeat": beat})
        self.send_json(200, self.seen())


class Chat(Base):
    service = "chat"

    def do_GET(self):
        url = urlsplit(self.path)
        if self.headers.get("Upgrade", "").lower() == "websocket":
            return self.websocket()
        if url.path == "/healthz":
            return self.send_json(200, {"ok": True})
        if url.path == "/activity":
            mode, now = STATE["activity"], int(time.time() * 1000)
            if mode == "live":          # un tour d'assistant en cours : activité continue
                return self.send_json(200, {"last_activity_ms": now})
            if mode == "old":           # plus rien depuis le moment où l'essai l'a figé
                return self.send_json(200, {"last_activity_ms": STATE["frozen_ms"]})
            if mode == "error":         # en erreur, avec une valeur qui garderait l'espace si elle était lue
                return self.send_json(500, {"last_activity_ms": now})
            if mode == "future":
                return self.send_json(200, {"last_activity_ms": now + 86_400_000})
            if mode == "garbage":
                body = b"<html>pas du JSON</html>"
                self.send_response(200)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
                return
            return self.send_json(404, {"detail": "not found"})
        self.send_json(200, self.seen(agent=parse_qs(url.query).get("agent", [None])[0]))


class S(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


GO = threading.Event()
if os.environ.get("CHAT", "on") == "on":
    GO.set()


def chat():
    GO.wait()
    S(("0.0.0.0", 8090), Chat).serve_forever()


if os.environ.get("CHAT", "on") != "off":
    threading.Thread(target=chat, daemon=True).start()
S(("0.0.0.0", 8080), Editor).serve_forever()
