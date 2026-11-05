"""Chantier ecran, I1 : URL de hook lue dans .env ("read_hook_env"), chemins « publication WebRTC
relayée » ("whip"), en-tête X-Lab-Media-Key du relais, relais vers un hook https."""
import json
import os
import shutil
import subprocess
import tempfile
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from labmediaauth import registry as R
from labmediaauth import server as S

from .test_registry import ENV as BASE_ENV, REG as BASE_REG

HOOK_URL = 'https://app.example/hook/'
ENV = {
    **BASE_ENV,
    'LAB_MEDIA_APP_ECRAN_HOOK_KEY': 'e' * 24,
    'LAB_MEDIA_APP_ECRAN_HOOK_URL': HOOK_URL,
    'LAB_MEDIA_APP_ECRAN_CONTROL_USER': 'ecran-ctl', 'LAB_MEDIA_APP_ECRAN_CONTROL_PASSWORD': 'ce' * 10,
    'LAB_MEDIA_APP_ECRAN_PUBLISH_USER': 'ecran-pub', 'LAB_MEDIA_APP_ECRAN_PUBLISH_PASSWORD': 'pe' * 10,
}


def reg_with(app=None, path=None, extra_paths=None, sources=None):
    reg = json.loads(json.dumps(BASE_REG))
    reg['apps']['ecran'] = app if app is not None else {'prefixes': ['ecran'], 'read_hook_env': True}
    reg['paths']['ecran/a'] = path if path is not None else {'whip': True}
    reg['paths'].update(extra_paths or {})
    if sources is not None:
        reg['sources'] = sources
    return reg


def load(reg=None, env=None):
    return R.load(json.dumps(reg if reg is not None else reg_with()), env if env is not None else ENV)


class ReadHookEnvTests(unittest.TestCase):
    def test_url_comes_from_env(self):
        reg = load()
        self.assertEqual(reg.apps['ecran'].hook_url, HOOK_URL)
        self.assertEqual(reg.apps['ecran'].hook_key, 'e' * 24)
        for url in ('http://ecran-backend:8000/api/hook/', 'https://app.example:8443/x/hook',
                    'https://app.example'):
            self.assertEqual(load(env={**ENV, 'LAB_MEDIA_APP_ECRAN_HOOK_URL': url}).apps['ecran'].hook_url, url)

    def test_explicit_false_is_the_usual_read_hook(self):
        reg = load(reg_with(app={'prefixes': ['ecran'], 'read_hook_env': False,
                                 'read_hook': 'http://ecran-backend:8000/hook'}))
        self.assertEqual(reg.apps['ecran'].hook_url, 'http://ecran-backend:8000/hook')

    def test_refusals(self):
        env_cases = [
            {k: v for k, v in ENV.items() if k != 'LAB_MEDIA_APP_ECRAN_HOOK_URL'},   # absente
            {**ENV, 'LAB_MEDIA_APP_ECRAN_HOOK_URL': ''},
            {**ENV, 'LAB_MEDIA_APP_ECRAN_HOOK_URL': 'CHANGE_ME'},
            {**ENV, 'LAB_MEDIA_APP_ECRAN_HOOK_URL': 'https://CHANGE_ME/hook/'},
            {**ENV, 'LAB_MEDIA_APP_ECRAN_HOOK_URL': 'https://app.example/hook/?key=x'},   # query
            {**ENV, 'LAB_MEDIA_APP_ECRAN_HOOK_URL': 'https://app.example/hook/#f'},
            {**ENV, 'LAB_MEDIA_APP_ECRAN_HOOK_URL': 'ftp://app.example/hook/'},
            {**ENV, 'LAB_MEDIA_APP_ECRAN_HOOK_URL': 'app.example/hook/'},
            {**ENV, 'LAB_MEDIA_APP_ECRAN_HOOK_URL': 'https://app.example/ho ok/'},
            {**ENV, 'LAB_MEDIA_APP_ECRAN_HOOK_URL': 'https://app.example/hook/\n'},
        ]
        for env in env_cases:
            with self.assertRaises(R.RegistryError, msg=repr(env.get('LAB_MEDIA_APP_ECRAN_HOOK_URL'))) as ctx:
                load(env=env)
            # L'URL n'apparaît jamais dans le message (elle n'a pas à être publique).
            url = env.get('LAB_MEDIA_APP_ECRAN_HOOK_URL')
            if url and 'app.example' in url:
                self.assertNotIn('app.example', str(ctx.exception))
        app_cases = [
            {'prefixes': ['ecran'], 'read_hook_env': True, 'read_hook': 'http://ecran-backend:8000/hook'},
            {'prefixes': ['ecran'], 'read_hook_env': 'true'},
            {'prefixes': ['ecran'], 'read_hook_env': 1},
            {'prefixes': ['ecran'], 'read_hook_env': False},          # ni l'un ni l'autre
            {'prefixes': ['ecran']},
        ]
        for app in app_cases:
            with self.assertRaises(R.RegistryError, msg=str(app)):
                load(reg_with(app=app))

    def test_other_secrets_still_required(self):
        for key in ('LAB_MEDIA_APP_ECRAN_HOOK_KEY', 'LAB_MEDIA_APP_ECRAN_CONTROL_USER',
                    'LAB_MEDIA_APP_ECRAN_CONTROL_PASSWORD'):
            with self.assertRaises(R.RegistryError, msg=key):
                load(env={k: v for k, v in ENV.items() if k != key})

    def test_state_refuses_to_start(self):
        fd, path = tempfile.mkstemp(suffix='.json')
        os.write(fd, json.dumps(reg_with()).encode())
        os.close(fd)
        try:
            env = {k: v for k, v in ENV.items() if k != 'LAB_MEDIA_APP_ECRAN_HOOK_URL'}
            with self.assertRaises(R.RegistryError):
                S.State({**env, 'LAB_MEDIA_AUTH_REGISTRY_FILE': path})
        finally:
            os.unlink(path)


class WhipRegistryTests(unittest.TestCase):
    def test_loaded(self):
        reg = load()
        self.assertTrue(reg.is_whip('ecran/a'))
        self.assertTrue(reg.never_recorded('ecran/a'))
        for path in ('appa/cam', 'ecran', 'ecran/b', 'ecran/a/x', None, 42):
            self.assertFalse(reg.is_whip(path), path)
        self.assertFalse(reg.paths['ecran/a'].record)
        self.assertEqual(reg.app_paths(reg.apps['ecran']), ['ecran/a'])
        # "whip": false = chemin ordinaire
        self.assertFalse(load(reg_with(path={'whip': False, 'record': True})).is_whip('ecran/a'))

    def test_refusals(self):
        for conf in ({'whip': True, 'record': True}, {'whip': True, 'record': False},
                     {'whip': True, 'segment': '1h'}, {'whip': True, 'delete_after': '7d'},
                     {'whip': True, 'source_env': 'LAB_MEDIA_PULL_CAM'}, {'whip': True, 'on_demand': True},
                     {'whip': True, 'on_demand': False}, {'whip': 'yes'}, {'whip': 1}, {'whip': None}):
            with self.assertRaises(R.RegistryError, msg=str(conf)):
                load(reg_with(path=conf))

    def test_no_source_may_list_it(self):
        with self.assertRaises(R.RegistryError):
            load(reg_with(sources={'capture': {'paths': ['webcam/av', 'ecran/a']}}))

    def test_render(self):
        out = R.render_mediamtx('logLevel: info\n', load())
        self.assertIn('  "ecran/a":\n    source: publisher\n    record: no\n    overridePublisher: no\n', out)
        block = out.split('  "ecran/a":\n')[1].split('\n  "')[0]
        self.assertNotIn('recordPath', block)
        self.assertNotIn('recordDeleteAfter', block)
        # Même si un PathConf était forgé avec record=True, le rendu ne l'enregistre pas.
        reg = load()
        reg.paths['ecran/a'] = R.PathConf(name='ecran/a', record=True, retain=True, whip=True)
        out = R.render_mediamtx('logLevel: info\n', reg)
        self.assertIn('  "ecran/a":\n    source: publisher\n    record: no\n    overridePublisher: no\n', out)
        self.assertNotIn('record: yes', out.split('  "ecran/a":\n')[1].split('\n  "')[0])


class FakeState:
    def __init__(self):
        self.registry = load()
        self.internal = R.Creds('lab-media-auth', 'i' * 40)
        self.relayed = []
        self.devices = None


class WhipDecisionTests(unittest.TestCase):
    def setUp(self):
        self.state = FakeState()
        self.verdict = (True, 'stub')
        self._relay = S.relay_read
        S.relay_read = lambda state, app, raw: (state.relayed.append((app.name, raw)) or self.verdict)

    def tearDown(self):
        S.relay_read = self._relay

    def decide(self, **body):
        raw = json.dumps(body).encode()
        return S.decide(self.state, raw)[0], raw

    def test_whip_publish_relayed_to_the_owner_as_is(self):
        body = dict(ip='192.0.2.1', user='', password='', token='ep1.jeton', action='publish',
                    path='ecran/a', protocol='webrtc', id='0c0c1eba', query='', userAgent='x')
        ok, raw = self.decide(**body)
        self.assertTrue(ok)
        self.assertEqual(self.state.relayed, [('ecran', raw)])          # corps tel quel, app propriétaire
        self.verdict = (False, 'hook de ecran : 401')
        self.assertFalse(self.decide(**body)[0])

    def test_credentials_never_open_a_publication(self):
        creds = [dict(user='ecran-pub', password='pe' * 10),            # publication de l'app propriétaire
                 dict(user='appa-pub', password='pa' * 10),             # publication d'une autre app
                 dict(user='capture', password='pc' * 10),              # source
                 dict(user='ecran-ctl', password='ce' * 10),            # contrôle
                 dict(user='lab-media-auth', password='i' * 40),        # internes
                 {}]
        for protocol in ('rtsp', 'rtmp', 'srt', 'hls', None, 'WEBRTC'):
            for c in creds:
                self.assertFalse(self.decide(action='publish', protocol=protocol, path='ecran/a', token='t', **c)[0],
                                 (protocol, c))
        self.assertEqual(self.state.relayed, [])                        # l'app n'est même pas consultée
        # En WebRTC, des identifiants présents ne court-circuitent rien : c'est le hook qui tranche.
        self.verdict = (False, 'hook de ecran : 401')
        for c in creds:
            self.assertFalse(self.decide(action='publish', protocol='webrtc', path='ecran/a', **c)[0], c)
        self.assertEqual(len(self.state.relayed), len(creds))

    def test_whip_still_closed_elsewhere(self):
        for path in ('appa/cam', 'appb/cam', 'ecran', 'ecran/b', 'ecran/a/x', 'webcam/av'):
            self.assertFalse(self.decide(action='publish', protocol='webrtc', path=path, token='t')[0], path)
        self.assertEqual(self.state.relayed, [])
        # et RTSP par identifiants reste ouvert là où il l'était
        self.assertTrue(self.decide(action='publish', protocol='rtsp', path='appa/cam',
                                    user='appa-pub', password='pa' * 10)[0])

    def test_read_relayed_normally(self):
        for protocol in ('webrtc', 'hls', 'rtsp'):
            ok, raw = self.decide(action='read', protocol=protocol, path='ecran/a', token='er1.t')
            self.assertTrue(ok, protocol)
        self.assertEqual([a for a, _ in self.state.relayed], ['ecran'] * 3)   # l'app impose WebRTC elle-même
        self.verdict = (False, 'hook de ecran : 401')
        self.assertFalse(self.decide(action='read', protocol='webrtc', path='ecran/a', token='er1.t')[0])
        # identifiants de source ou d'app : la lecture reste à l'app
        self.verdict = (False, 'hook de ecran : 401')
        self.assertFalse(self.decide(action='read', protocol='rtsp', path='ecran/a',
                                     user='capture', password='pc' * 10)[0])

    def test_internal_actions_not_relayed(self):
        for action in ('api', 'playback', 'metrics', 'pprof'):
            self.assertFalse(self.decide(action=action, path='ecran/a', token='t')[0])
        self.assertEqual(self.state.relayed, [])


class _Hook:
    """Hook local : enregistre (chemin, en-têtes, corps) et répond selon `mode`."""

    def __init__(self, ssl_context=None):
        test = self
        self.mode, self.seen = 'ok', []

        class H(BaseHTTPRequestHandler):
            def do_POST(self):
                body = self.rfile.read(int(self.headers['Content-Length']))
                test.seen.append((self.path, dict(self.headers), body))
                if test.mode == 'hang':
                    time.sleep(1.5)
                self.send_response({'ok': 200, 'deny': 401, 'hang': 200, 'redirect': 302}[test.mode])
                if test.mode == 'redirect':
                    self.send_header('Location', '/ailleurs')
                self.send_header('Content-Length', '0')
                self.end_headers()

            def log_message(self, *a):
                pass

        self.httpd = ThreadingHTTPServer(('127.0.0.1', 0), H)
        self.httpd.daemon_threads = True
        if ssl_context is not None:
            self.httpd.socket = ssl_context.wrap_socket(self.httpd.socket, server_side=True)
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()
        self.port = self.httpd.server_address[1]

    def close(self):
        self.httpd.shutdown()
        self.httpd.server_close()


def _state(env):
    fd, path = tempfile.mkstemp(suffix='.json')
    os.write(fd, json.dumps(reg_with()).encode())
    os.close(fd)
    try:
        return S.State({**env, 'LAB_MEDIA_AUTH_REGISTRY_FILE': path, 'LAB_MEDIA_READ_HOOK_TIMEOUT_S': '0.5'})
    finally:
        os.unlink(path)


def _publish(state):
    raw = json.dumps({'action': 'publish', 'path': 'ecran/a', 'protocol': 'webrtc', 'token': 'ep1.t',
                      'id': 'abc', 'user': '', 'password': ''}).encode()
    return S.decide(state, raw), raw


class WhipRelayTests(unittest.TestCase):
    """Relais réel (http) : clé en query ET en en-tête, échec fermé."""

    def setUp(self):
        self.hook = _Hook()
        self.state = _state({**ENV, 'LAB_MEDIA_APP_ECRAN_HOOK_URL': f'http://127.0.0.1:{self.hook.port}/api/ecran/media-auth/'})

    def tearDown(self):
        self.hook.close()

    def test_key_in_query_and_header(self):
        (ok, info), raw = _publish(self.state)
        self.assertTrue(ok, info)
        path, headers, body = self.hook.seen[0]
        self.assertEqual(path, '/api/ecran/media-auth/?key=' + 'e' * 24)
        self.assertEqual(headers.get('X-Lab-Media-Key'), 'e' * 24)
        self.assertEqual(headers.get('Content-Type'), 'application/json')
        self.assertEqual(body, raw)

    def test_fail_closed(self):
        for mode in ('deny', 'redirect'):
            self.hook.mode = mode
            self.assertFalse(_publish(self.state)[0][0], mode)
        self.hook.mode = 'hang'
        t0 = time.perf_counter()
        (ok, info), _ = _publish(self.state)
        self.assertFalse(ok)
        self.assertLess(time.perf_counter() - t0, 1.0)
        self.assertIn('délai dépassé', info['reason'])
        self.hook.close()
        state = _state({**ENV, 'LAB_MEDIA_APP_ECRAN_HOOK_URL': f'http://127.0.0.1:{self.hook.port}/x/'})
        (ok, info), _ = _publish(state)
        self.assertFalse(ok)
        self.assertIn('injoignable', info['reason'])
        self.hook = _Hook()     # pour tearDown

    def test_header_for_every_app(self):
        """L'en-tête part aussi vers le hook d'une app au "read_hook" écrit au registre."""
        reg = reg_with()
        reg['apps']['appa']['read_hook'] = f'http://127.0.0.1:{self.hook.port}/hook'
        fd, path = tempfile.mkstemp(suffix='.json')
        os.write(fd, json.dumps(reg).encode())
        os.close(fd)
        try:
            state = S.State({**ENV, 'LAB_MEDIA_AUTH_REGISTRY_FILE': path, 'LAB_MEDIA_READ_HOOK_TIMEOUT_S': '0.5'})
        finally:
            os.unlink(path)
        ok, _ = S.decide(state, json.dumps({'action': 'read', 'path': 'appa/cam', 'token': 't'}).encode())
        self.assertTrue(ok)
        p, headers, _ = self.hook.seen[0]
        self.assertEqual((p, headers.get('X-Lab-Media-Key')), ('/hook?key=' + 'a' * 20, 'a' * 20))


@unittest.skipUnless(shutil.which('openssl'), 'openssl absent : certificat de test impossible')
class HttpsRelayTests(unittest.TestCase):
    """Relais vers un hook https : certificat vérifié (refus sinon), puis accepté avec son AC."""

    def setUp(self):
        import ssl
        self.dir = tempfile.mkdtemp()
        self.cert, key = os.path.join(self.dir, 'c.pem'), os.path.join(self.dir, 'k.pem')
        subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
                        '-subj', '/CN=127.0.0.1', '-addext', 'subjectAltName=IP:127.0.0.1',
                        '-keyout', key, '-out', self.cert], check=True, capture_output=True)
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain(self.cert, key)
        self.hook = _Hook(ctx)
        self.url = f'https://127.0.0.1:{self.hook.port}/api/ecran/media-auth/'
        self._old = os.environ.get('SSL_CERT_FILE')

    def tearDown(self):
        if self._old is None:
            os.environ.pop('SSL_CERT_FILE', None)
        else:
            os.environ['SSL_CERT_FILE'] = self._old
        self.hook.close()
        shutil.rmtree(self.dir)

    def test_unverified_certificate_refused(self):
        os.environ['SSL_CERT_FILE'] = os.path.join(self.dir, 'aucune-ac.pem')
        (ok, info), _ = _publish(_state({**ENV, 'LAB_MEDIA_APP_ECRAN_HOOK_URL': self.url}))
        self.assertFalse(ok)
        self.assertIn('injoignable', info['reason'])
        self.assertEqual(self.hook.seen, [])        # rien n'est parti : ni corps, ni clé

    def test_verified_certificate_accepted(self):
        os.environ['SSL_CERT_FILE'] = self.cert      # lu par le contexte par défaut de http.client
        (ok, info), raw = _publish(_state({**ENV, 'LAB_MEDIA_APP_ECRAN_HOOK_URL': self.url}))
        self.assertTrue(ok, info)
        path, headers, body = self.hook.seen[0]
        self.assertEqual((path, headers.get('X-Lab-Media-Key'), body),
                         ('/api/ecran/media-auth/?key=' + 'e' * 24, 'e' * 24, raw))


class WhipControlTests(unittest.TestCase):
    """API de contrôle sur un chemin « whip » : pas de relecture ; publieur expulsable par son app
    (et par elle seule) ; publication RTSP d'un autre chemin toujours non expulsable."""

    SESSIONS = [
        {'id': 'aaaa-1', 'path': 'ecran/a', 'state': 'publish'},
        {'id': 'bbbb-2', 'path': 'ecran/a', 'state': 'read'},
        {'id': 'cccc-3', 'path': 'appa/cam', 'state': 'publish'},
    ]

    def handler(self):
        test = self
        state = FakeState()
        state.mtx_list = lambda endpoint: [dict(s) for s in test.SESSIONS]

        def mtx_json(method, path):
            test.kicked.append(path)
            return 200, None
        state.mtx_json = mtx_json
        state._mtx = lambda *a, **k: (_ for _ in ()).throw(AssertionError('relecture interrogée'))
        h = S.ControlHandler.__new__(S.ControlHandler)
        h.state, h.command = state, 'GET'
        h.sent = []
        h.send_json = lambda code, data: h.sent.append((code, data))
        h.send_empty = lambda code, headers=None: h.sent.append((code, None))
        h.done = lambda app, status, **f: True
        self.kicked = []
        return h, state.registry

    def test_no_recordings(self):
        h, reg = self.handler()
        app = reg.apps['ecran']
        h.recordings_list(app, {'path': 'ecran/a'})
        h.recordings_get(app, {'path': 'ecran/a', 'start': '2026-11-05T00:00:00Z', 'duration': '10'})
        self.assertEqual([c for c, _ in h.sent], [404, 404])
        self.assertEqual({d['error'] for _, d in h.sent}, {'unknown_path'})

    def test_kick(self):
        h, reg = self.handler()
        ecran, appa = reg.apps['ecran'], reg.apps['appa']
        h.session_kick(ecran, 'webrtc', 'aaaa-1')            # publieur du chemin whip : expulsé
        h.session_kick(ecran, 'webrtc', 'bbbb-2')            # lecteur : expulsé
        self.assertEqual([c for c, _ in h.sent], [204, 204])
        self.assertEqual(self.kicked, ['/v3/webrtcsessions/kick/aaaa-1', '/v3/webrtcsessions/kick/bbbb-2'])
        h.sent.clear()
        h.session_kick(appa, 'webrtc', 'aaaa-1')             # une autre app : indiscernable d'inconnue
        h.session_kick(appa, 'rtsp', 'cccc-3')               # publication RTSP ordinaire : jamais
        self.assertEqual([(c, d['error']) for c, d in h.sent], [(404, 'unknown_session'), (409, 'not_a_reader')])
        self.assertEqual(len(self.kicked), 2)


if __name__ == '__main__':
    unittest.main()
