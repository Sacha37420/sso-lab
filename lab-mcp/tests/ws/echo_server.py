"""Substitut d'espace de travail pour les essais réseau : HTTP + WebSocket (écho),
bibliothèque standard seulement. Écoute sur 8080 comme l'image d'I7."""
import base64, hashlib, json, os, socketserver, struct
from http.server import BaseHTTPRequestHandler

GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def do_GET(self):
        if self.headers.get("Upgrade", "").lower() == "websocket":
            key = self.headers["Sec-WebSocket-Key"]
            acc = base64.b64encode(hashlib.sha1((key + GUID).encode()).digest()).decode()
            self.send_response(101)
            self.send_header("Upgrade", "websocket")
            self.send_header("Connection", "Upgrade")
            self.send_header("Sec-WebSocket-Accept", acc)
            self.end_headers()
            # une trame texte masquée (< 126 octets) reçue → renvoyée préfixée
            hdr = self.rfile.read(2)
            n = hdr[1] & 0x7F
            mask = self.rfile.read(4)
            data = bytes(b ^ mask[i % 4] for i, b in enumerate(self.rfile.read(n)))
            out = f"écho de {os.environ.get('WHO', '?')} : ".encode() + data
            self.wfile.write(bytes([0x81, len(out)]) + out)
            self.close_connection = True
            return
        body = json.dumps({"qui": os.environ.get("WHO", "?"), "chemin": self.path,
                           "cookie_reçu": bool(self.headers.get("Cookie"))}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


class S(socketserver.ThreadingTCPServer):
    allow_reuse_address = True


S(("0.0.0.0", 8080), H).serve_forever()
