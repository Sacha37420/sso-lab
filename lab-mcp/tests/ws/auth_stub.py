"""Essai du §8 UNIQUEMENT : tient lieu de /mcp/api/ws-auth avant que le moteur
n'existe. Admet si le cookie « essai » vaut l'uid visé (X-Lab-Ws-Uid)."""
from http.server import BaseHTTPRequestHandler, HTTPServer


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_GET(self):
        uid = self.headers.get("X-Lab-Ws-Uid", "")
        ok = f"essai={uid}" in self.headers.get("Cookie", "") and uid
        print(f"ws-auth uid={uid} uri={self.headers.get('X-Forwarded-Uri')} méthode={self.headers.get('X-Forwarded-Method')} → {'200' if ok else '401'}", flush=True)
        self.send_response(200 if ok else 401)
        self.send_header("Content-Length", "0")
        self.end_headers()


HTTPServer(("0.0.0.0", 8000), H).serve_forever()
