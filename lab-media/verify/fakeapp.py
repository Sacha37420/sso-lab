"""App fictive de verify.sh : le hook de lecture d'une app (forme du contrat peripheriques I2).

POST /hook?key=<clé>   corps MediaMTX → 200 ssi action == "read" et token == GOOD_TOKEN, sinon 401
                       (mode « 500 » : répond 500 ; mode « hang » : ne répond pas avant 60 s)
GET  /_log             tout ce que le hook a reçu : [{"key_ok": bool, "body": {...}, "status": int}]
POST /_mode?m=ok|500|hang      POST /_clear
"""
import json
import os
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

KEY, GOOD = os.environ['HOOK_KEY'], os.environ['GOOD_TOKEN']
state = {'mode': 'ok', 'log': []}
lock = threading.Lock()


class H(BaseHTTPRequestHandler):
    def reply(self, code, data=None):
        raw = json.dumps(data).encode() if data is not None else b''
        self.send_response(code)
        self.send_header('Content-Length', str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def do_GET(self):
        if self.path == '/_log':
            with lock:
                return self.reply(200, state['log'])
        self.reply(404)

    def do_POST(self):
        url = urlsplit(self.path)
        raw = self.rfile.read(int(self.headers.get('Content-Length', 0)))
        query = parse_qs(url.query)
        if url.path == '/_mode':
            state['mode'] = query['m'][0]
            return self.reply(200, {'mode': state['mode']})
        if url.path == '/_clear':
            with lock:
                state['log'].clear()
            return self.reply(200, {})
        if url.path != '/hook':
            return self.reply(404)
        key_ok = query.get('key', [''])[0] == KEY
        try:
            body = json.loads(raw)
        except ValueError:
            body = None
        mode = state['mode']
        if mode == 'hang':
            status = 0
        elif mode == '500':
            status = 500
        else:
            ok = key_ok and isinstance(body, dict) and body.get('action') == 'read' and body.get('token') == GOOD
            status = 200 if ok else 401
        with lock:
            state['log'].append({'key_ok': key_ok, 'body': body, 'raw': raw.decode('utf-8', 'replace'),
                                 'status': status, 'mode': mode})
        if mode == 'hang':
            time.sleep(60)
            status = 401
        self.reply(status)

    def log_message(self, *args):
        pass


ThreadingHTTPServer(('0.0.0.0', 8000), H).serve_forever()
