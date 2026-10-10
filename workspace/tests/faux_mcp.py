#!/usr/bin/env python3
"""Faux serveur MCP (Streamable HTTP, réponses JSON) pour verify.sh — bibliothèque standard seule.

Ne sert qu'à PROUVER que Claude Code et Mistral Vibe lisent bien leur déclaration et envoient
l'en-tête `Authorization: Bearer <valeur de LAB_MCP_TOKEN>` tirée de l'environnement.
Refuse (401) toute requête sans le bon jeton. Chaque requête est journalisée — sans le jeton —
dans le fichier donné en argument : `<méthode JSON-RPC> auth=OK|KO|ABSENT agent=<User-Agent>`.

Usage : faux_mcp.py <port> <fichier journal>      (jeton attendu : variable FAUX_MCP_JETON)
"""
import json
import os
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT, JOURNAL = int(sys.argv[1]), sys.argv[2]
ATTENDU = "Bearer " + os.environ["FAUX_MCP_JETON"]


class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):  # silence
        pass

    def _rep(self, code, corps=None):
        data = b"" if corps is None else json.dumps(corps).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        self._rep(405, {"error": "pas de flux SSE"})

    def do_DELETE(self):
        self._rep(200, {})

    def do_POST(self):
        brut = self.rfile.read(int(self.headers.get("Content-Length", 0) or 0))
        try:
            msg = json.loads(brut or b"{}")
        except ValueError:
            msg = {}
        recu = self.headers.get("Authorization")
        etat = "ABSENT" if recu is None else ("OK" if recu == ATTENDU else "KO")
        with open(JOURNAL, "a", encoding="utf-8") as f:
            f.write(f"{msg.get('method')} auth={etat} agent={self.headers.get('User-Agent', '')}\n")
        if etat != "OK":
            return self._rep(401, {"error": "jeton refusé"})
        methode, ident = msg.get("method"), msg.get("id")
        if ident is None:  # notification
            return self._rep(202)
        if methode == "initialize":
            res = {
                "protocolVersion": msg.get("params", {}).get("protocolVersion", "2025-03-26"),
                "capabilities": {"tools": {}},
                "serverInfo": {"name": "faux-lab-mcp", "version": "0"},
            }
        elif methode == "tools/list":
            res = {"tools": [{
                "name": "whoami",
                "description": "outil factice de verify.sh",
                "inputSchema": {"type": "object", "properties": {}},
            }]}
        elif methode == "ping":
            res = {}
        else:
            return self._rep(200, {"jsonrpc": "2.0", "id": ident,
                                   "error": {"code": -32601, "message": "méthode inconnue"}})
        self._rep(200, {"jsonrpc": "2.0", "id": ident, "result": res})


ThreadingHTTPServer(("127.0.0.1", PORT), H).serve_forever()
