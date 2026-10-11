"""lab-media-auth — deux serveurs HTTP dans un seul processus (bibliothèque standard seule).

  * HOOK (réseau interne de lab-media, port 9000) : cible de `authHTTPAddress` de MediaMTX.
    Décide lui-même publish / api / playback / metrics / pprof ; relaie `read` au hook de
    l'app propriétaire du préfixe, corps transmis tel quel, en échec fermé.
  * CONTRÔLE (dev-net, port 9100) : l'API I3 des apps — voir lab-media/API.md.

Les identifiants internes de MediaMTX (API, relecture) sont tirés au hasard à chaque
démarrage et ne quittent jamais la mémoire de ce processus : ils ne sont dans aucun fichier
et aucune app ne peut les recevoir.

Journal : une ligne JSON par décision. Jamais de mot de passe, de jeton, de clé de hook, de
nom d'utilisateur ni de query (elle peut porter un jeton).
"""
from __future__ import annotations

import base64
import hmac
import http.client
import json
import os
import re
import secrets
import socket
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor, TimeoutError as FutureTimeout
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, quote, urlencode, urlsplit

from . import registry as reg_mod

MAX_BODY = 128 * 1024
CHUNK = 64 * 1024
INTERNAL_ACTIONS = {'api', 'playback', 'metrics', 'pprof'}
SESSION_ENDPOINTS = {'webrtc': 'webrtcsessions', 'hls': 'hlssessions', 'rtsp': 'rtspsessions'}
SESSION_FIELDS = ('id', 'path', 'state', 'created', 'remoteAddr')
RELAY_PER_APP = 8
ID_CHARS = set('0123456789abcdefABCDEF-')
RFC3339 = re.compile(r'^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(\.\d{1,9})?(Z|[+-]\d\d:\d\d)$')
DURATION = re.compile(r'^\d{1,6}(\.\d{1,6})?$')

_log_lock = threading.Lock()


def log(event: str, **fields) -> None:
    line = json.dumps({'t': time.strftime('%Y-%m-%dT%H:%M:%S%z'), 'event': event, **fields},
                      ensure_ascii=False, separators=(',', ':'))
    with _log_lock:
        sys.stdout.write(line + '\n')
        sys.stdout.flush()


def eq(given, expected: str) -> bool:
    """Comparaison en temps constant ; un attendu vide ne valide jamais rien."""
    if not expected or not isinstance(given, str):
        return False
    return hmac.compare_digest(given.encode(), expected.encode())


def creds_ok(body: dict, creds) -> bool:
    ok_user = eq(body.get('user'), creds.user)
    ok_pass = eq(body.get('password'), creds.password)
    return ok_user and ok_pass


def _count(item: dict, *keys: str) -> int:
    for key in keys:
        value = item.get(key)
        if isinstance(value, int):
            return value
    return 0


class State:
    """Tout ce que les deux serveurs partagent."""

    def __init__(self, env: dict):
        self.hook_key = reg_mod._secret(env, 'LAB_MEDIA_HOOK_KEY')
        with open(env.get('LAB_MEDIA_AUTH_REGISTRY_FILE', '/etc/lab-media/registry.json'), encoding='utf-8') as fh:
            self.registry = reg_mod.load(fh.read(), env)
        self.api = urlsplit(env.get('LAB_MEDIA_AUTH_MTX_API', 'http://lab-media-ctl:9997'))
        self.playback = urlsplit(env.get('LAB_MEDIA_AUTH_MTX_PLAYBACK', 'http://lab-media-ctl:9996'))
        self.read_timeout = float(env.get('LAB_MEDIA_READ_HOOK_TIMEOUT_S', '3'))
        if not 0.2 <= self.read_timeout <= 8:
            # MediaMTX abandonne son propre appel au bout de readTimeout (10 s) : rester dessous.
            raise reg_mod.RegistryError('LAB_MEDIA_READ_HOOK_TIMEOUT_S doit être entre 0.2 et 8')
        self.internal = reg_mod.Creds('lab-media-auth', secrets.token_urlsafe(32))
        # Relais des lectures : au plus RELAY_PER_APP appels simultanés vers le hook d'UNE app.
        # Au-delà, refus immédiat : une app dont le hook pend ne peut pas, sous une rafale de
        # demandes de lecture (WHEP et HLS sont joignables depuis Internet), épuiser les
        # relais des autres apps.
        apps = self.registry.apps
        self.relay_slots = {name: threading.BoundedSemaphore(RELAY_PER_APP) for name in apps}
        self.pool = ThreadPoolExecutor(max_workers=max(1, len(apps)) * RELAY_PER_APP,
                                       thread_name_prefix='read-relay')

    # ── appels à MediaMTX (identifiants internes) ────────────────────────────
    def _mtx(self, base, method: str, path: str, timeout: float = 5):
        conn = http.client.HTTPConnection(base.hostname, base.port, timeout=timeout)
        token = base64.b64encode(f'{self.internal.user}:{self.internal.password}'.encode()).decode()
        conn.request(method, path, headers={'Authorization': f'Basic {token}'})
        return conn, conn.getresponse()

    def mtx_json(self, method: str, path: str):
        """(code HTTP, JSON ou None). Lève OSError si MediaMTX est injoignable."""
        conn, resp = self._mtx(self.api, method, path)
        try:
            raw = resp.read()
        finally:
            conn.close()
        try:
            return resp.status, (json.loads(raw) if raw else None)
        except ValueError:
            return resp.status, None

    def mtx_list(self, endpoint: str) -> list[dict]:
        items, page = [], 0
        while True:
            code, data = self.mtx_json('GET', f'/v3/{endpoint}/list?itemsPerPage=1000&page={page}')
            if code != 200 or not isinstance(data, dict):
                raise OSError(f'{endpoint}/list → HTTP {code}')
            items.extend(data.get('items') or [])
            page += 1
            if page >= int(data.get('pageCount') or 1):
                return items


# ═════════════════════════════════════════════════════════════════════════════
# HOOK — appelé par MediaMTX seul
# ═════════════════════════════════════════════════════════════════════════════

def decide(state: State, raw: bytes) -> tuple[bool, dict]:
    """(autorisé ?, champs de journal). Toute erreur, tout cas imprévu ⇒ refus."""
    try:
        body = json.loads(raw or b'{}')
    except (ValueError, UnicodeDecodeError):
        return False, {'reason': 'corps illisible'}
    if not isinstance(body, dict):
        return False, {'reason': 'corps illisible'}
    action, path, protocol = body.get('action'), body.get('path'), body.get('protocol')
    info = {'action': action, 'path': path, 'protocol': protocol, 'id': body.get('id'), 'ip': body.get('ip')}
    registry = state.registry

    if action in INTERNAL_ACTIONS:
        ok = creds_ok(body, state.internal)
        return ok, {**info, 'reason': 'identifiants internes' if ok else 'identifiants internes refusés'}

    if action == 'publish':
        app = registry.owner(path)
        if app is None or path not in registry.paths:
            return False, {**info, 'reason': 'chemin sans propriétaire'}
        info['app'] = app.name
        if registry.paths[path].pull_url:
            return False, {**info, 'reason': 'chemin tiré : personne n\'y publie'}
        who = None
        # Pas de court-circuit : chaque candidat est toujours comparé.
        if app.publish is not None and creds_ok(body, app.publish):
            who = f'app {app.name}'
        for source in registry.sources.values():
            if creds_ok(body, source.publish) and path in source.paths:
                who = who or f'source {source.name}'
        # RTSP seulement : la publication WebRTC (WHIP, joignable par Caddy donc depuis
        # Internet) n'a pas été prouvée sûre — fermée, même avec de bons identifiants.
        if who and protocol != 'rtsp':
            return False, {**info, 'reason': f'{who} : publication {protocol} fermée (RTSP seul)'}
        if who:
            return True, {**info, 'reason': who}
        anonymous = not body.get('user') and not body.get('password')
        return False, {**info, 'reason': 'sans identifiants' if anonymous else 'identifiants de publication refusés'}

    if action == 'read':
        app = registry.owner(path)
        if app is None or path not in registry.paths:
            return False, {**info, 'reason': 'chemin sans propriétaire'}
        info['app'] = app.name
        ok, why = relay_read(state, app, raw)
        return ok, {**info, 'reason': why}

    return False, {**info, 'reason': 'action inconnue'}


def _post_hook(app, raw: bytes, timeout: float, slot) -> int:
    try:
        url = urlsplit(app.hook_url)
        cls = http.client.HTTPSConnection if url.scheme == 'https' else http.client.HTTPConnection
        conn = cls(url.hostname, url.port, timeout=timeout)
        try:
            conn.request('POST', f'{url.path or "/"}?{urlencode({"key": app.hook_key})}', body=raw,
                         headers={'Content-Type': 'application/json'})
            return conn.getresponse().status
        finally:
            conn.close()
    finally:
        slot.release()   # rendu quand l'appel est réellement fini, pas quand on cesse de l'attendre


def relay_read(state: State, app, raw: bytes) -> tuple[bool, str]:
    """Relaie le corps de MediaMTX tel quel au hook de l'app. Échec fermé : injoignable,
    lent au-delà du délai (délai TOTAL, pas par opération de socket) ou réponse ≠ 200."""
    slot = state.relay_slots[app.name]
    if not slot.acquire(blocking=False):
        return False, f'hook de {app.name} : saturé ({RELAY_PER_APP} appels en cours)'
    try:
        future = state.pool.submit(_post_hook, app, raw, state.read_timeout, slot)
    except RuntimeError:
        slot.release()
        return False, f'hook de {app.name} : relais arrêté'
    try:
        status = future.result(timeout=state.read_timeout)
    except FutureTimeout:
        future.cancel()
        return False, f'hook de {app.name} : délai dépassé'
    except (OSError, http.client.HTTPException) as exc:
        kind = 'délai dépassé' if isinstance(exc, (socket.timeout, TimeoutError)) else 'injoignable'
        return False, f'hook de {app.name} : {kind} ({type(exc).__name__})'
    except Exception as exc:  # noqa: BLE001 — rien ne doit autoriser par accident
        return False, f'hook de {app.name} : erreur ({type(exc).__name__})'
    if status == 200:
        return True, f'hook de {app.name} : 200'
    return False, f'hook de {app.name} : {status}'


class _Base(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    server_version = 'lab-media-auth'
    sys_version = ''
    timeout = 30

    def log_message(self, *args):  # journal d'accès par défaut : coupé (il porterait la query)
        pass

    def send_empty(self, code: int, headers: dict | None = None) -> None:
        self.send_response(code)
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.send_header('Content-Length', '0')
        self.end_headers()

    def send_json(self, code: int, data) -> None:
        raw = json.dumps(data, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Cache-Control', 'no-store')
        self.send_header('Content-Length', str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def read_body(self) -> bytes | None:
        try:
            length = int(self.headers.get('Content-Length', '0'))
        except ValueError:
            return None
        if not 0 <= length <= MAX_BODY:
            return None
        return self.rfile.read(length)


class HookHandler(_Base):
    state: State

    def do_POST(self):
        t0 = time.perf_counter()
        url = urlsplit(self.path)
        raw = self.read_body()
        if raw is None:
            self.close_connection = True
            return self.send_empty(401)
        if url.path != '/hook' or not eq((parse_qs(url.query).get('key') or [''])[0], self.state.hook_key):
            log('hook', allowed=False, reason='clé du hook absente ou fausse')
            return self.send_empty(401)
        allowed, info = decide(self.state, raw)
        log('hook', allowed=allowed, ms=round((time.perf_counter() - t0) * 1000, 2), **info)
        self.send_empty(200 if allowed else 401)

    def do_GET(self):
        self.send_empty(401)


# ═════════════════════════════════════════════════════════════════════════════
# CONTRÔLE — API I3 des apps
# ═════════════════════════════════════════════════════════════════════════════

class ControlHandler(_Base):
    state: State

    # ── plomberie ────────────────────────────────────────────────────────────
    def error(self, code: int, error: str, detail: str) -> None:
        self.send_json(code, {'error': error, 'detail': detail})

    def authenticate(self):
        header = self.headers.get('Authorization', '')
        user = password = None
        if header.startswith('Basic '):
            try:
                user, _, password = base64.b64decode(header[6:], validate=True).decode().partition(':')
            except (ValueError, UnicodeDecodeError):
                user = password = None
        app = self.state.registry.app_by_control_user(user) if user else None
        # Toujours une comparaison, même pour un utilisateur inconnu.
        ok = eq(password, app.control.password if app else self.state.internal.password) and app is not None
        if not ok:
            time.sleep(0.5)
            log('control', allowed=False, reason='identifiants de contrôle refusés',
                method=self.command, route=urlsplit(self.path).path)
            self.send_json_401()
            return None
        return app

    def send_json_401(self) -> None:
        raw = b'{"error":"unauthorized","detail":"Identifiants de contr\\u00f4le requis."}'
        self.send_response(401)
        self.send_header('WWW-Authenticate', 'Basic realm="lab-media"')
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def route(self, method: str) -> None:
        url = urlsplit(self.path)
        if url.path == '/healthz' and method == 'GET':
            return self.send_json(200, {'status': 'ok'})
        app = self.authenticate()
        if app is None:
            return
        query = {k: v[0] for k, v in parse_qs(url.query).items()}
        parts = [p for p in url.path.split('/') if p]
        try:
            handled = self.dispatch(app, method, parts, query)
        except (OSError, http.client.HTTPException) as exc:
            log('control', app=app.name, method=method, route=url.path, status=502,
                reason=f'MediaMTX injoignable ({type(exc).__name__})')
            return self.error(502, 'media_unavailable', 'Serveur média injoignable.')
        if handled is None:
            log('control', app=app.name, method=method, route=url.path, status=404)
            self.error(404, 'not_found', 'Route inconnue.')

    def do_GET(self):
        self.route('GET')

    def do_POST(self):
        if self.read_body() is None:
            self.close_connection = True
            return self.send_empty(400)
        self.route('POST')

    def done(self, app, status: int, **fields) -> bool:
        log('control', app=app.name, method=self.command, status=status, **fields)
        return True

    # ── routes ───────────────────────────────────────────────────────────────
    def dispatch(self, app, method, parts, query):
        if parts[:1] != ['v1']:
            return None
        rest = parts[1:]
        if method == 'GET' and rest == ['paths']:
            return self.paths_list(app)
        if method == 'GET' and rest[:1] == ['paths'] and len(rest) > 1:
            return self.path_get(app, '/'.join(rest[1:]))
        if method == 'GET' and rest == ['sessions']:
            return self.sessions_list(app, query)
        if method == 'POST' and len(rest) == 4 and rest[0] == 'sessions' and rest[3] == 'kick':
            return self.session_kick(app, rest[1], rest[2])
        if method == 'GET' and rest == ['recordings']:
            return self.recordings_list(app, query)
        if method == 'GET' and rest == ['recordings', 'get']:
            return self.recordings_get(app, query)
        return None

    def _path_item(self, name: str, live: dict | None) -> dict:
        conf = self.state.registry.paths[name]
        live = live or {}
        return {
            'path': name,
            'ready': bool(live.get('ready', live.get('online'))),
            'readyTime': live.get('readyTime') or live.get('onlineTime'),
            'tracks': list(live.get('tracks') or []),
            'readers': len(live.get('readers') or []),
            'inboundBytes': _count(live, 'inboundBytes', 'bytesReceived'),
            'source': 'pull' if conf.pull_url else 'publisher',
            'recorded': conf.record,
        }

    def paths_list(self, app):
        live = {item.get('name'): item for item in self.state.mtx_list('paths')}
        items = [self._path_item(name, live.get(name)) for name in self.state.registry.app_paths(app)]
        self.send_json(200, {'items': items})
        return self.done(app, 200, route='paths')

    def _not_yours(self, app, route: str, path) -> bool:
        """Même réponse pour « n'existe pas » et « appartient à une autre app »."""
        self.error(404, 'unknown_path', 'Chemin inconnu pour cette app.')
        return self.done(app, 404, route=route, path=path if isinstance(path, str) else None,
                         reason='chemin hors de ses préfixes ou non déclaré')

    def _own_path(self, app, path) -> bool:
        return self.state.registry.owns(app, path) and path in self.state.registry.paths

    def path_get(self, app, path):
        if not self._own_path(app, path):
            return self._not_yours(app, 'paths/get', path)
        code, data = self.state.mtx_json('GET', '/v3/paths/get/' + quote(path))
        self.send_json(200, self._path_item(path, data if code == 200 and isinstance(data, dict) else None))
        return self.done(app, 200, route='paths/get', path=path)

    def _sessions(self, app, protocol: str) -> list[dict]:
        out = []
        for item in self.state.mtx_list(SESSION_ENDPOINTS[protocol]):
            if not self.state.registry.owns(app, item.get('path')):
                continue
            row = {'protocol': protocol}
            row.update({k: item.get(k) for k in SESSION_FIELDS})
            row['inboundBytes'] = _count(item, 'inboundBytes', 'bytesReceived')
            row['outboundBytes'] = _count(item, 'outboundBytes', 'bytesSent')
            if protocol == 'hls':
                row['state'] = 'read'     # un lecteur HLS ne publie jamais
            out.append(row)
        return out

    def sessions_list(self, app, query):
        protocol, path = query.get('protocol'), query.get('path')
        if protocol is not None and protocol not in SESSION_ENDPOINTS:
            self.error(400, 'bad_protocol', f'protocol ∈ {sorted(SESSION_ENDPOINTS)}')
            return self.done(app, 400, route='sessions')
        if path is not None and not self._own_path(app, path):
            return self._not_yours(app, 'sessions', path)
        items = []
        for proto in ([protocol] if protocol else sorted(SESSION_ENDPOINTS)):
            items.extend(self._sessions(app, proto))
        if path is not None:
            items = [i for i in items if i['path'] == path]
        self.send_json(200, {'items': items})
        return self.done(app, 200, route='sessions', count=len(items))

    def session_kick(self, app, protocol, session_id):
        if protocol not in SESSION_ENDPOINTS:
            self.error(400, 'bad_protocol', f'protocol ∈ {sorted(SESSION_ENDPOINTS)}')
            return self.done(app, 400, route='sessions/kick')
        mine = None
        if 0 < len(session_id) <= 64 and set(session_id) <= ID_CHARS:
            mine = next((s for s in self._sessions(app, protocol) if s['id'] == session_id), None)
        if mine is None:
            # Inconnue, déjà terminée, ou session d'une autre app : indiscernables.
            self.error(404, 'unknown_session', 'Session inconnue pour cette app.')
            return self.done(app, 404, route='sessions/kick', protocol=protocol, id=session_id[:64],
                             reason='session inconnue ou hors de ses préfixes')
        if mine.get('state') == 'publish':
            self.error(409, 'not_a_reader', 'Seule une session de lecture peut être expulsée.')
            return self.done(app, 409, route='sessions/kick', protocol=protocol, id=session_id)
        code, _ = self.state.mtx_json('POST', f'/v3/{SESSION_ENDPOINTS[protocol]}/kick/{session_id}')
        if code == 404:
            self.error(404, 'unknown_session', 'Session inconnue pour cette app.')
            return self.done(app, 404, route='sessions/kick', protocol=protocol, id=session_id,
                             reason='terminée entre la liste et l\'expulsion')
        if code != 200:
            raise OSError(f'kick → HTTP {code}')
        self.send_empty(204)
        return self.done(app, 204, route='sessions/kick', protocol=protocol, id=session_id, path=mine['path'])

    def recordings_list(self, app, query):
        path = query.get('path')
        if not self._own_path(app, path):
            return self._not_yours(app, 'recordings', path)
        params = {'path': path}
        for key in ('start', 'end'):
            if key in query:
                if not RFC3339.match(query[key]):
                    self.error(400, 'bad_request', f'{key} : horodatage RFC 3339 avec fuseau attendu.')
                    return self.done(app, 400, route='recordings', path=path)
                params[key] = query[key]
        conn, resp = self.state._mtx(self.state.playback, 'GET', '/list?' + urlencode(params))
        try:
            raw = resp.read()
        finally:
            conn.close()
        if resp.status == 200:
            items = [{'start': i.get('start'), 'duration': i.get('duration')} for i in json.loads(raw or b'[]')]
        elif resp.status == 404 or (resp.status == 400 and b'no such file or directory' in raw):
            # MediaMTX 1.21.1 : 404 « aucun segment » ; 400 « lstat … no such file » quand rien n'a
            # encore été enregistré sous ce chemin (ou qu'il n'est pas enregistré). Les deux = vide.
            items = []
        else:
            raise OSError(f'playback /list → HTTP {resp.status}')
        self.send_json(200, items)
        return self.done(app, 200, route='recordings', path=path, count=len(items))

    def recordings_get(self, app, query):
        path = query.get('path')
        if not self._own_path(app, path):
            return self._not_yours(app, 'recordings/get', path)
        if not RFC3339.match(query.get('start', '')) or not DURATION.match(query.get('duration', '')):
            self.error(400, 'bad_request', 'Requis : start (RFC 3339 avec fuseau) et duration (secondes).')
            return self.done(app, 400, route='recordings/get', path=path)
        fmt = query.get('format', 'fmp4')
        if fmt not in ('fmp4', 'mp4'):
            self.error(400, 'bad_request', 'format ∈ fmp4, mp4.')
            return self.done(app, 400, route='recordings/get', path=path)
        params = {'path': path, 'start': query['start'], 'duration': query['duration'], 'format': fmt}
        conn, resp = self.state._mtx(self.state.playback, 'GET', '/get?' + urlencode(params), timeout=60)
        try:
            if resp.status != 200:
                raw = resp.read()
                if resp.status == 404 or (resp.status == 400 and b'no such file or directory' in raw):
                    self.error(404, 'no_recording', 'Aucun enregistrement sur cette plage.')
                    return self.done(app, 404, route='recordings/get', path=path)
                raise OSError(f'playback /get → HTTP {resp.status}')
            # Longueur inconnue d'avance : flux jusqu'à la fermeture de la connexion.
            self.close_connection = True
            self.send_response(200)
            self.send_header('Content-Type', resp.getheader('Content-Type') or 'video/mp4')
            self.send_header('Cache-Control', 'no-store')
            self.send_header('Connection', 'close')
            self.end_headers()
            sent = 0
            try:
                while True:
                    chunk = resp.read(CHUNK)
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                    sent += len(chunk)
            except OSError:
                pass  # l'app a fermé : on coupe l'amont (finally)
            return self.done(app, 200, route='recordings/get', path=path, bytes=sent)
        finally:
            conn.close()


# ═════════════════════════════════════════════════════════════════════════════

def write_config(state: State, env: dict) -> None:
    """Écrit le mediamtx.yml dérivé du registre dans le volume partagé avec MediaMTX, qui le
    recharge à chaud. Écriture atomique, et seulement si le contenu change."""
    target = env.get('LAB_MEDIA_AUTH_CONFIG_OUT', '/config/mediamtx.yml')
    with open(env.get('LAB_MEDIA_AUTH_BASE_FILE', '/opt/lab-media/mediamtx.base.yml'), encoding='utf-8') as fh:
        content = reg_mod.render_mediamtx(fh.read(), state.registry)
    try:
        with open(target, encoding='utf-8') as fh:
            if fh.read() == content:
                log('config', written=False, paths=len(state.registry.paths))
                return
    except FileNotFoundError:
        pass
    tmp = f'{target}.tmp'
    with open(tmp, 'w', encoding='utf-8') as fh:
        fh.write(content)
    os.chmod(tmp, 0o640)   # il peut porter l'URL (avec identifiants) d'une source tirée
    os.replace(tmp, target)
    log('config', written=True, paths=len(state.registry.paths))


def _serve(handler_cls, host: str, port: int, state: State, name: str) -> ThreadingHTTPServer:
    handler = type(handler_cls.__name__, (handler_cls,), {'state': state})
    server = ThreadingHTTPServer((host, port), handler)
    server.daemon_threads = True
    threading.Thread(target=server.serve_forever, name=name, daemon=True).start()
    return server


def main() -> int:
    env = dict(os.environ)
    try:
        state = State(env)
        write_config(state, env)
        # Le hook n'écoute QUE sur l'adresse du réseau interne de lab-media : l'alias
        # « lab-media-hook » n'existe que là. Les apps (dev-net) ne peuvent pas l'atteindre.
        hook_host = socket.gethostbyname(env.get('LAB_MEDIA_AUTH_HOOK_BIND', 'lab-media-hook'))
    except (reg_mod.RegistryError, OSError) as exc:
        log('fatal', reason=str(exc))
        return 1
    _serve(HookHandler, hook_host, 9000, state, 'hook')
    _serve(ControlHandler, env.get('LAB_MEDIA_AUTH_CONTROL_BIND', '0.0.0.0'), 9100, state, 'control')
    log('started', hook=f'{hook_host}:9000', control=':9100',
        apps={a.name: list(a.prefixes) for a in state.registry.apps.values()},
        sources=sorted(state.registry.sources), paths=sorted(state.registry.paths),
        read_timeout_s=state.read_timeout)
    stop = threading.Event()
    import signal
    signal.signal(signal.SIGTERM, lambda *_: stop.set())
    signal.signal(signal.SIGINT, lambda *_: stop.set())
    stop.wait()
    log('stopped')
    return 0


if __name__ == '__main__':
    sys.exit(main())
