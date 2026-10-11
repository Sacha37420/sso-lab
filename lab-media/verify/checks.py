"""Contrôles de verify.sh, lancés DANS le conteneur lmt-client (réseaux lmt-dev et lmt-sso) :
il joue à la fois le backend des apps fictives (API de contrôle) et leurs navigateurs (HLS).

usage : checks.py <phase>      — une ligne « PASS|FAIL  <id>  <ce qui est prouvé> — <observé> » par contrôle.
"""
import base64
import http.cookiejar
import json
import os
import re
import socket
import sys
import time
import urllib.error
import urllib.request

E = os.environ
AUTH, CADDY, MEDIA = E['AUTH_URL'], E['CADDY_URL'], E['MEDIA_HOST']
A = (E['A_USER'], E['A_PASS'])
B = (E['B_USER'], E['B_PASS'])
A_PUB = (E['A_PUB_USER'], E['A_PUB_PASS'])
TA, TB = E['TOKEN_A'], E['TOKEN_B']
APPA, APPB = 'http://lmt-appa:8000', 'http://lmt-appb:8000'
STATE = '/tmp/lmt-state.json'
failed = []


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


def opener(follow=True, jar=None):
    handlers = [urllib.request.HTTPCookieProcessor(jar if jar is not None else http.cookiejar.CookieJar())]
    if not follow:
        handlers.append(NoRedirect())
    return urllib.request.build_opener(*handlers)


def call(method, url, basic=None, bearer=None, data=None, op=None, timeout=25, ctype=None, limit=None):
    headers = {}
    if basic:
        headers['Authorization'] = 'Basic ' + base64.b64encode(f'{basic[0]}:{basic[1]}'.encode()).decode()
    if bearer:
        headers['Authorization'] = 'Bearer ' + bearer
    if ctype:
        headers['Content-Type'] = ctype
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    t0 = time.perf_counter()
    try:
        with (op or opener()).open(req, timeout=timeout) as resp:
            code, hdrs, body = resp.status, dict(resp.headers), resp.read(limit) if limit else resp.read()
    except urllib.error.HTTPError as exc:
        code, hdrs, body = exc.code, dict(exc.headers), exc.read()
    except Exception as exc:  # noqa: BLE001
        code, hdrs, body = type(exc).__name__, {}, b''
    return code, hdrs, body, (time.perf_counter() - t0) * 1000


def js(method, url, **kw):
    code, _, body, _ = call(method, url, **kw)
    try:
        return code, json.loads(body) if body else None
    except ValueError:
        return code, None


def check(cid, what, ok, observed=''):
    print(f'{"PASS" if ok else "FAIL"}  {cid:<5} {what} — {observed}', flush=True)
    if not ok:
        failed.append(cid)
    return ok


def hook_log(app):
    return js('GET', f'{app}/_log')[1] or []


def clear_logs():
    for app in (APPA, APPB):
        call('POST', f'{app}/_clear')


def mode(app, m):
    call('POST', f'{app}/_mode?m={m}')


def save(**kw):
    data = load()
    data.update(kw)
    json.dump(data, open(STATE, 'w'))


def load():
    try:
        return json.load(open(STATE))
    except (OSError, ValueError):
        return {}


def wait_for(fn, seconds=30, step=1.0):
    end = time.time() + seconds
    while True:
        value = fn()
        if value or time.time() > end:
            return value
        time.sleep(step)


def path_of(creds, path):
    return js('GET', f'{AUTH}/v1/paths/{path}', basic=creds)


def hls(path, token, op=None, base=None):
    return call('GET', f'{base or CADDY + "/lab-media-hls"}/{path}/index.m3u8', bearer=token, op=op)


def tcp(host, port):
    try:
        socket.create_connection((host, port), timeout=3).close()
        return 'ouvert'
    except ConnectionRefusedError:
        return 'refusé'
    except OSError as exc:
        return type(exc).__name__


# ─────────────────────────────────────────────────────────────────────────────

def p_ready():
    """Attend que les publications lancées par verify.sh soient prêtes."""
    for creds, path in ((A, 'appa/cam'), (A, 'appa/short'), (B, 'appb/cam'), (B, 'appb/pulled')):
        item = wait_for(lambda: (path_of(creds, path)[1] or {}).get('ready') and path_of(creds, path)[1], 40)
        check('R0', f'chemin {path} prêt', bool(item), json.dumps(item))
    save(ready_a=path_of(A, 'appa/cam')[1]['readyTime'])


def p_whip():
    whip = f'{CADDY}/lab-media-webrtc/appa/cam/whip'
    code, _, _, _ = call('POST', whip, data=b'v=0', ctype='application/sdp')
    check('P7', 'WHIP sans identifiants refusé', code == 401, f'HTTP {code}')
    code, _, _, _ = call('POST', whip, data=b'v=0', ctype='application/sdp', basic=A_PUB)
    check('P8', 'WHIP avec les identifiants de publication d\'appa refusé (WebRTC non ouvert à la publication)',
          code == 401, f'HTTP {code}')


def p_control():
    code, _ = js('GET', f'{AUTH}/v1/paths')
    check('C1', 'contrôle sans identifiants refusé', code == 401, f'HTTP {code}')
    code, _ = js('GET', f'{AUTH}/v1/paths', basic=(A[0], 'mauvais-mot-de-passe'))
    check('C2', 'contrôle avec mauvais mot de passe refusé', code == 401, f'HTTP {code}')
    code, _ = js('GET', f'{AUTH}/v1/paths', basic=(A[0], B[1]))
    check('C3', 'utilisateur d\'appa + mot de passe d\'appb refusé', code == 401, f'HTTP {code}')
    code, _ = js('GET', f'{AUTH}/v1/paths', basic=A_PUB)
    check('C4', 'identifiants de PUBLICATION refusés sur le contrôle', code == 401, f'HTTP {code}')
    code, data = js('GET', f'{AUTH}/v1/paths', basic=A)
    names = sorted(i['path'] for i in (data or {}).get('items', []))
    check('C5', 'appa ne liste que ses chemins', code == 200 and names == [
        'appa/cam', 'appa/short', 'webcam/audio', 'webcam/av', 'webcam/video'], f'{code} {names}')
    code, data = js('GET', f'{AUTH}/v1/paths', basic=B)
    names = sorted(i['path'] for i in (data or {}).get('items', []))
    check('C6', 'appb ne liste que ses chemins', code == 200 and names == ['appb/cam', 'appb/pulled'], f'{code} {names}')
    code, item = path_of(A, 'appa/cam')
    check('C7', 'état d\'un chemin : prêt, pistes', code == 200 and item['ready'] and 'H264' in item['tracks'],
          json.dumps(item))
    code, item = path_of(B, 'appb/pulled')
    check('C8', 'source tirée (RTSP distant) prête', code == 200 and item['ready'] and item['source'] == 'pull',
          json.dumps(item))
    code, data = path_of(A, 'appb/cam')
    check('C9', 'appa ne voit pas l\'état d\'un chemin d\'appb', code == 404, f'HTTP {code} {data}')
    code, data = path_of(A, 'appa/inexistant')
    check('C10', 'chemin inexistant : même réponse que chemin d\'autrui', code == 404 and data['error'] == 'unknown_path',
          f'HTTP {code} {data}')
    for route in ('/v3/paths/list', '/v1/autre', '/'):
        code, _ = js('GET', f'{AUTH}{route}', basic=A)
        check('C11', f'route inconnue {route} : 404, rien de MediaMTX n\'est relayé', code == 404, f'HTTP {code}')


def p_read():
    clear_logs()
    code, _, body, _ = hls('appa/cam', TA)
    la, lb = hook_log(APPA), hook_log(APPB)
    last = la[-1] if la else {}
    b = last.get('body') or {}
    check('L1', 'lecture HLS (par Caddy) autorisée avec le bon jeton', code == 200 and body.startswith(b'#EXTM3U'),
          f'HTTP {code} {body[:20]!r}')
    check('L2', 'relayée au hook d\'appa, avec SA clé, et à lui seul',
          bool(la) and all(x['key_ok'] for x in la) and not lb, f'appa={len(la)} appel(s), appb={len(lb)}')
    wanted = {'ip', 'user', 'password', 'token', 'action', 'path', 'protocol', 'id', 'query', 'userAgent'}
    check('L3', 'corps MediaMTX transmis tel quel (tous les champs, jeton dans token, id de session)',
          set(b) == wanted and b.get('action') == 'read' and b.get('path') == 'appa/cam'
          and b.get('protocol') == 'hls' and b.get('token') == TA and bool(b.get('id')),
          json.dumps({k: ('…' if k == 'token' else v) for k, v in b.items()}))
    clear_logs()
    code, _, _, _ = hls('appa/cam', 'mauvais-jeton')
    check('L4', 'lecture avec mauvais jeton refusée', code == 401, f'HTTP {code}')
    code, _, _, _ = hls('appa/cam', None)
    check('L5', 'lecture sans jeton refusée', code == 401, f'HTTP {code}')
    clear_logs()
    code, _, _, _ = hls('appb/cam', TA)
    la, lb = hook_log(APPA), hook_log(APPB)
    check('L6', 'jeton d\'appa sur un flux d\'appb : relayé à appb seule, refusé',
          code == 401 and not la and len(lb) >= 1, f'HTTP {code} appa={len(la)} appb={len(lb)}')
    code, _, body, _ = hls('appb/cam', TB)
    check('L7', 'appb lit son propre flux', code == 200 and body.startswith(b'#EXTM3U'), f'HTTP {code}')
    code, hdrs, _, _ = call('GET', f'{CADDY}/lab-media-hls/appa/cam/index.m3u8', bearer=TA, op=opener(follow=False))
    loc = hdrs.get('Location', '')
    check('L8', 'Caddy réécrit le Location de HLS avec le préfixe /lab-media-hls/',
          code == 302 and loc.startswith('/lab-media-hls/appa/cam/'), f'HTTP {code} Location={loc}')


def p_hook_modes():
    mode(APPA, '500')
    code, _, _, ms = hls('appa/cam', TA)
    check('H1', 'hook d\'appa qui répond 500 : lecture refusée', code == 401, f'HTTP {code}')
    code, _, _, _ = hls('appb/cam', TB)
    check('H2', '… et appb continue de lire pendant ce temps', code == 200, f'HTTP {code}')
    mode(APPA, 'hang')
    code, _, _, ms = hls('appa/cam', TA)
    # délai du relais (3 s) + délai anti-force-brute de MediaMTX (0 à 4 s) + marge
    check('H3', 'hook d\'appa qui PEND : lecture refusée, en temps borné', code == 401 and ms < 9000,
          f'HTTP {code} en {ms:.0f} ms (hook suspendu 60 s)')
    code, item = path_of(A, 'appa/cam')
    check('H4', 'publication d\'appa/cam toujours prête pendant que son hook pend',
          code == 200 and item['ready'] and item['readyTime'] == load().get('ready_a'), json.dumps(item))
    mode(APPA, 'ok')
    code, _, _, _ = hls('appa/cam', TA)
    check('H5', 'hook rétabli : lecture de nouveau autorisée', code == 200, f'HTTP {code}')


def p_app_down():
    """verify.sh a ARRÊTÉ le conteneur de l'app fictive appa."""
    before = path_of(A, 'appa/cam')[1]
    code, _, _, ms = hls('appa/cam', TA)
    check('D1', 'app autorité arrêtée : lecture refusée (échec fermé)', code == 401, f'HTTP {code} en {ms:.0f} ms')
    time.sleep(4)
    after = path_of(A, 'appa/cam')[1]
    check('D2', 'app autorité arrêtée : la publication continue (même session, octets reçus en hausse)',
          after['ready'] and after['readyTime'] == load().get('ready_a')
          and after['inboundBytes'] > before['inboundBytes'],
          f'inboundBytes {before["inboundBytes"]} → {after["inboundBytes"]}, readyTime {after["readyTime"]}')
    code, _, _, _ = hls('appb/cam', TB)
    check('D3', '… et l\'autre app n\'est pas affectée', code == 200, f'HTTP {code}')


def _sessions(creds, **params):
    query = '&'.join(f'{k}={v}' for k, v in params.items())
    return js('GET', f'{AUTH}/v1/sessions?{query}', basic=creds)


def p_hls_kick():
    clear_logs()
    jar = http.cookiejar.CookieJar()
    op = opener(jar=jar)
    code, _, body, _ = hls('appa/cam', TA, op=op)
    sub = next((l for l in body.decode().splitlines() if l and not l.startswith('#')), 'absente')
    sub_url = f'{CADDY}/lab-media-hls/appa/cam/{sub}'
    hook_ids = [x['body']['id'] for x in hook_log(APPA) if x['body'].get('protocol') == 'hls' and x['status'] == 200]
    code_l, data = _sessions(A, protocol='hls')
    mine = [s for s in (data or {}).get('items', []) if s['id'] in hook_ids]
    check('K1', 'session HLS listée par appa, avec l\'id reçu par son hook', code_l == 200 and len(mine) == 1,
          json.dumps(mine))
    if not mine:
        return
    sid = mine[0]['id']
    code_b, data_b = _sessions(B)
    check('K2', 'appb ne voit pas la session d\'appa', code_b == 200 and sid not in [s['id'] for s in data_b['items']],
          f'{len(data_b["items"])} session(s) vue(s) par appb')
    code_b, _ = js('POST', f'{AUTH}/v1/sessions/hls/{sid}/kick', basic=B)
    still = sid in [s['id'] for s in _sessions(A, protocol='hls')[1]['items']]
    check('K3', 'appb ne peut pas expulser la session d\'appa', code_b == 404 and still, f'HTTP {code_b}, session toujours là : {still}')
    # la session sert encore, sans repasser par le hook (secret de session)
    calls = len(hook_log(APPA))
    code2, _, _, _ = call('GET', sub_url, op=op)
    check('K4', 'avant expulsion : la sous-playlist de la session HLS est servie SANS jeton et SANS appel au hook (d\'où l\'expulsion)',
          code2 == 200 and len(hook_log(APPA)) == calls, f'HTTP {code2}, appels au hook {calls} → {len(hook_log(APPA))}')
    code_k, _, _, _ = call('POST', f'{AUTH}/v1/sessions/hls/{sid}/kick', basic=A, data=b'')
    gone = sid not in [s['id'] for s in _sessions(A, protocol='hls')[1]['items']]
    code3, _, _, _ = call('GET', sub_url, op=op)
    check('K5', 'appa expulse sa session HLS : 204, session disparue, le lecteur est coupé',
          code_k == 204 and gone and code3 != 200, f'kick HTTP {code_k}, disparue : {gone}, requête suivante HTTP {code3}')
    code_k, _ = js('POST', f'{AUTH}/v1/sessions/hls/{sid}/kick', basic=A)
    check('K6', 'expulser une session déjà terminée : 404', code_k == 404, f'HTTP {code_k}')


def p_webrtc_kick():
    """lmt-src (un second MediaMTX) lit appa/cam en WHEP à travers Caddy : vraie session WebRTC."""
    def reader():
        items = (_sessions(A, protocol='webrtc', path='appa/cam')[1] or {}).get('items', [])
        return [s for s in items if s['state'] == 'read' and s['outboundBytes'] > 0]
    found = wait_for(reader, 40)
    check('W1', 'session WebRTC (WHEP par Caddy) ouverte en lecture, média émis', bool(found), json.dumps(found))
    if not found:
        return
    sid, sent = found[0]['id'], found[0]['outboundBytes']
    time.sleep(3)
    now = [s for s in reader() if s['id'] == sid]
    check('W3', 'le flux WebRTC coule (octets émis en hausse)', bool(now) and now[0]['outboundBytes'] > sent,
          f'{sent} → {now[0]["outboundBytes"] if now else "session disparue"}')
    seen_b = [s['id'] for s in _sessions(B)[1]['items']]
    code_b, _ = js('POST', f'{AUTH}/v1/sessions/webrtc/{sid}/kick', basic=B)
    check('W4', 'appb ne voit ni n\'expulse la session WebRTC d\'appa', sid not in seen_b and code_b == 404,
          f'vue par appb : {sid in seen_b}, kick HTTP {code_b}')
    code_k, _, _, _ = call('POST', f'{AUTH}/v1/sessions/webrtc/{sid}/kick', basic=A, data=b'')
    gone = wait_for(lambda: sid not in [s['id'] for s in _sessions(A, protocol='webrtc')[1]['items']], 5, 0.5)
    check('W5', 'appa expulse sa session WebRTC : 204, session disparue', code_k == 204 and gone,
          f'kick HTTP {code_k}, disparue : {gone}')
    clear_logs()
    again = wait_for(lambda: [s for s in reader() if s['id'] != sid], 40)
    new_id = again[0]['id'] if again else None
    hook = [x['body'] for x in hook_log(APPA) if x['body'].get('protocol') == 'webrtc' and x['body'].get('id') == new_id]
    check('W2', 'le lecteur expulsé doit repasser par le hook d\'appa ; l\'id de sa nouvelle session est celui que le hook reçoit (jeton en Authorization: Bearer)',
          bool(hook) and hook[0]['token'] == TA and hook[0]['action'] == 'read', f'nouvelle session {new_id}, {len(hook)} appel(s) au hook')
    # sessions RTSP : la publication d'appa est listée mais ne peut pas être expulsée
    pubs = [s for s in _sessions(A, protocol='rtsp')[1]['items'] if s['state'] == 'publish' and s['path'] == 'appa/cam']
    code_p = js('POST', f'{AUTH}/v1/sessions/rtsp/{pubs[0]["id"]}/kick', basic=A)[0] if pubs else None
    check('W6', 'une session de PUBLICATION n\'est pas expulsable par l\'API (409)', code_p == 409,
          f'{len(pubs)} publication(s) RTSP d\'appa/cam, kick HTTP {code_p}')


def p_recordings():
    code, items = js('GET', f'{AUTH}/v1/recordings?path=appa/cam', basic=A)
    ok = code == 200 and isinstance(items, list) and items and set(items[0]) == {'start', 'duration'}
    check('E1', 'relecture : appa liste les plages de son chemin', ok, f'HTTP {code} {json.dumps(items)[:160]}')
    if ok:
        start = items[-1]['start']
        url = f'{AUTH}/v1/recordings/get?path=appa/cam&start={urllib.request.quote(start)}&duration=4&format=fmp4'
        code, hdrs, body, ms = call('GET', url, basic=A)
        boxes = re.findall(rb'ftyp|moov|moof|mdat', body[:4096] + body[-4096:])
        check('E2', 'relecture : appa lit une plage (fMP4)', code == 200 and len(body) > 2000 and b'ftyp' in body[:64]
              and b'moof' in body, f'HTTP {code}, {len(body)} octets, {hdrs.get("Content-Type")}, boîtes {sorted(set(boxes))}')
        open('/tmp/lmt-clip.mp4', 'wb').write(body)
        code, _, body, _ = call('GET', url, basic=B)
        check('E3', 'appb ne peut pas lire la plage d\'appa', code in (401, 404) and b'ftyp' not in body, f'HTTP {code}')
        code, _, body, _ = call('GET', url.replace('path=appa/cam', 'path=appb/cam'), basic=A)
        check('E4', 'appa ne peut pas lire une plage d\'appb', code == 404 and b'ftyp' not in body, f'HTTP {code}')
        code, data = js('GET', f'{AUTH}/v1/recordings/get?path=appa/cam&start=2001-01-01T00:00:00Z&duration=4', basic=A)
        check('E5', 'plage sans enregistrement : 404 no_recording', code == 404 and data['error'] == 'no_recording',
              f'HTTP {code} {data}')
    code, data = js('GET', f'{AUTH}/v1/recordings?path=appb/cam', basic=A)
    check('E6', 'appa ne peut pas lister les enregistrements d\'appb', code == 404, f'HTTP {code} {data}')
    code, items = js('GET', f'{AUTH}/v1/recordings?path=webcam/video', basic=A)
    check('E7', 'chemin non enregistré : liste vide (200)', code == 200 and items == [], f'HTTP {code} {items}')
    code, items = js('GET', f'{AUTH}/v1/recordings?path=appa/cam&start=2001-01-01T00:00:00Z&end=2001-01-02T00:00:00Z', basic=A)
    check('E10', 'filtre start/end hors de toute plage : liste vide', code == 200 and items == [], f'HTTP {code} {items}')
    code, data = js('GET', f'{AUTH}/v1/recordings?path=appa/cam&start=hier', basic=A)
    check('E11', 'start mal formé : 400', code == 400, f'HTTP {code}')
    code, data = js('GET', f'{AUTH}/v1/recordings', basic=A)
    check('E8', 'relecture sans path : 404, jamais « tous les chemins »', code == 404, f'HTTP {code}')


def p_net():
    for port, what in ((9997, 'API de MediaMTX'), (9996, 'relecture de MediaMTX')):
        state = tcp(MEDIA, port)
        check('N1', f'{what} ({MEDIA}:{port}) fermée depuis dev-net et sso-net', state != 'ouvert', state)
    state = tcp('lmt-media-auth', 9000)
    check('N2', 'hook de lab-media-auth (9000) fermé depuis dev-net', state != 'ouvert', state)
    check('N3', 'RTSP (8554) et API de contrôle (9100) ouverts aux apps',
          tcp(MEDIA, 8554) == 'ouvert' and tcp('lmt-media-auth', 9100) == 'ouvert', 'ouverts')


def p_auth_down():
    """verify.sh a ARRÊTÉ lab-media-auth."""
    code, _ = js('GET', f'{AUTH}/v1/paths', basic=A)
    check('X1', 'lab-media-auth arrêté : API de contrôle injoignable (ni état, ni expulsion)', not isinstance(code, int),
          f'{code}')
    code, _, _, ms = hls('appa/cam', TA)
    check('X2', 'lab-media-auth arrêté : toute nouvelle lecture est refusée', code == 401, f'HTTP {code} en {ms:.0f} ms')


def p_auth_back():
    ok = wait_for(lambda: js('GET', f'{AUTH}/healthz')[0] == 200, 20)
    code, item = path_of(A, 'appa/cam')
    check('X5', 'lab-media-auth relancé : la publication n\'a jamais été coupée (même readyTime)',
          bool(ok) and code == 200 and item['ready'] and item['readyTime'] == load().get('ready_a'), json.dumps(item))
    code, _, _, _ = hls('appa/cam', TA)
    check('X6', 'lab-media-auth relancé : la lecture reprend', code == 200, f'HTTP {code}')


def p_reload():
    """verify.sh a ajouté appa/extra au registre et redémarré lab-media-auth SEUL."""
    wait_for(lambda: js('GET', f'{AUTH}/healthz')[0] == 200, 20)
    item = wait_for(lambda: (path_of(A, 'appa/extra')[0] == 200) and path_of(A, 'appa/extra')[1], 10)
    check('G1', 'chemin ajouté au registre : connu après le seul redémarrage de lab-media-auth', bool(item), json.dumps(item))
    code, cam = path_of(A, 'appa/cam')
    check('G2', 'rechargement à chaud : la publication existante n\'est pas coupée (même readyTime)',
          code == 200 and cam['ready'] and cam['readyTime'] == load().get('ready_a'), json.dumps(cam))


def p_capture():
    def ready():
        items = {i['path']: i for i in js('GET', f'{AUTH}/v1/paths', basic=A)[1]['items']}
        return all(items[p]['ready'] for p in ('webcam/av', 'webcam/video', 'webcam/audio')) and items
    items = wait_for(ready, 40)
    tracks = {p: items[p]['tracks'] for p in ('webcam/av', 'webcam/video', 'webcam/audio')} if items else {}
    check('S1', 'capture.sh (mire) : un encodage, trois chemins webcam/* prêts',
          bool(items) and tracks == {'webcam/av': ['H264', 'Opus'], 'webcam/video': ['H264'], 'webcam/audio': ['Opus']},
          json.dumps(tracks))


PHASES = {name[2:]: fn for name, fn in globals().items() if name.startswith('p_')}

if __name__ == '__main__':
    PHASES[sys.argv[1]]()
    sys.exit(1 if failed else 0)
