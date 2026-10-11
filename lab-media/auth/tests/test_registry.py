"""Tests sans réseau : registre, propriété des chemins, décisions du hook hors relais."""
import json
import unittest

from labmediaauth import registry as R
from labmediaauth import server as S

S16 = 'x' * 16
ENV = {
    'LAB_MEDIA_HOOK_KEY': 'hook-key-0123456789',
    'LAB_MEDIA_APP_APPA_HOOK_KEY': 'a' * 20,
    'LAB_MEDIA_APP_APPA_CONTROL_USER': 'appa-ctl', 'LAB_MEDIA_APP_APPA_CONTROL_PASSWORD': 'ca' * 10,
    'LAB_MEDIA_APP_APPA_PUBLISH_USER': 'appa-pub', 'LAB_MEDIA_APP_APPA_PUBLISH_PASSWORD': 'pa' * 10,
    'LAB_MEDIA_APP_APP_B_HOOK_KEY': 'b' * 20,
    'LAB_MEDIA_APP_APP_B_CONTROL_USER': 'appb-ctl', 'LAB_MEDIA_APP_APP_B_CONTROL_PASSWORD': 'cb' * 10,
    'LAB_MEDIA_SOURCE_CAPTURE_PUBLISH_USER': 'capture', 'LAB_MEDIA_SOURCE_CAPTURE_PUBLISH_PASSWORD': 'pc' * 10,
    'LAB_MEDIA_PULL_CAM': 'rtsp://u:p@10.0.0.9:554/s1',
}
REG = {
    'version': 1,
    'apps': {
        'appa': {'prefixes': ['appa', 'webcam'], 'read_hook': 'http://appa:8000/hook', 'publish': True},
        'app-b': {'prefixes': ['appb'], 'read_hook': 'http://appb:8000/hook'},
    },
    'sources': {'capture': {'paths': ['webcam/av']}},
    'paths': {'appa/cam': {'record': True, 'segment': '10s', 'delete_after': '30s'},
              'webcam/av': {'record': True}, 'appb/cam': {}, 'appb/ip': {'source_env': 'LAB_MEDIA_PULL_CAM'}},
}


def load(reg=None, env=None):
    return R.load(json.dumps(reg or REG), env or ENV)


def changed(**patch):
    reg = json.loads(json.dumps(REG))
    for dotted, value in patch.items():
        node = reg
        keys = dotted.split('__')
        for k in keys[:-1]:
            node = node[k]
        node[keys[-1]] = value
    return reg


class RegistryTests(unittest.TestCase):
    def test_owner_respects_segment_boundary(self):
        reg = load()
        self.assertEqual(reg.owner('appa/cam').name, 'appa')
        self.assertEqual(reg.owner('webcam/av').name, 'appa')
        self.assertEqual(reg.owner('appb/cam').name, 'app-b')
        for path in ('appab/cam', 'webcamx', 'appa/../appb/cam', '/appa/cam', 'appa//cam', 'APPA/cam',
                     'appa/cam/', '', None, 42, 'autre/cam'):
            self.assertIsNone(reg.owner(path), path)

    def test_app_paths_are_only_its_own(self):
        reg = load()
        self.assertEqual(reg.app_paths(reg.apps['appa']), ['appa/cam', 'webcam/av'])
        self.assertEqual(reg.app_paths(reg.apps['app-b']), ['appb/cam', 'appb/ip'])

    def test_conflicting_prefixes_refused(self):
        for prefixes in (['appa'], ['appa/sub'], ['webcam']):
            with self.assertRaises(R.RegistryError):
                load(changed(**{'apps__app-b__prefixes': prefixes}))

    def test_path_without_owner_refused(self):
        with self.assertRaises(R.RegistryError):
            load(changed(paths__autre={}))

    def test_secret_rules(self):
        for key, value in (('LAB_MEDIA_APP_APPA_HOOK_KEY', ''), ('LAB_MEDIA_APP_APPA_HOOK_KEY', 'CHANGE_ME_CHANGE_ME'),
                           ('LAB_MEDIA_APP_APPA_CONTROL_PASSWORD', 'court'),
                           ('LAB_MEDIA_APP_APPA_CONTROL_PASSWORD', 'avec espace et : ' + S16),
                           ('LAB_MEDIA_APP_APP_B_CONTROL_USER', 'appa-ctl'),          # doublon
                           ('LAB_MEDIA_SOURCE_CAPTURE_PUBLISH_USER', 'appa-pub'),     # doublon
                           ('LAB_MEDIA_PULL_CAM', 'http://pas-rtsp')):
            with self.assertRaises(R.RegistryError, msg=key):
                load(env={**ENV, key: value})

    def test_unknown_keys_and_bad_values_refused(self):
        for patch in ({'apps__appa__authHTTPExclude': True}, {'paths__appa/cam__segment': '1 h'},
                      {'apps__appa__read_hook': 'http://appa:8000/hook?key=x'},
                      {'apps__appa__publish_protocols': ['webrtc']}, {'sources__capture__paths': ['appb/ip']},
                      {'sources__capture__paths': ['webcam/inconnu']}, {'version': 2}):
            with self.assertRaises(R.RegistryError, msg=str(patch)):
                load(changed(**patch))

    def test_render(self):
        base = 'logLevel: info\napi: yes\n'
        out = R.render_mediamtx(base, load())
        self.assertIn('authMethod: http\nauthHTTPExclude: []\n', out)
        self.assertIn('  "webcam/av":\n    source: publisher\n    record: yes\n    recordFormat: fmp4\n'
                      '    recordPath: /recordings/%path/%Y-%m-%d_%H-%M-%S-%f\n'
                      '    recordSegmentDuration: 1h\n    recordDeleteAfter: 7d\n', out)
        self.assertIn('  "appb/ip":\n    source: "rtsp://u:p@10.0.0.9:554/s1"\n', out)
        self.assertNotIn('all', out.split('paths:')[1])
        for forbidden in ('authHTTPExclude: [{action: publish}]\n', 'paths:\n  all:\n', 'authMethod: internal\n',
                          'authInternalUsers: []\n'):
            with self.assertRaises(R.RegistryError):
                R.render_mediamtx(base + forbidden, load())


class FakeState:
    def __init__(self):
        self.registry = load()
        self.internal = R.Creds('lab-media-auth', 'i' * 40)
        self.relayed = []


class HookDecisionTests(unittest.TestCase):
    def setUp(self):
        self.state = FakeState()
        self._relay = S.relay_read
        S.relay_read = lambda state, app, raw: (state.relayed.append(app.name) or (True, 'stub'))

    def tearDown(self):
        S.relay_read = self._relay

    def decide(self, **body):
        return S.decide(self.state, json.dumps(body).encode())[0]

    def test_publish(self):
        ok = dict(action='publish', protocol='rtsp')
        self.assertTrue(self.decide(**ok, path='appa/cam', user='appa-pub', password='pa' * 10))
        self.assertTrue(self.decide(**ok, path='webcam/av', user='capture', password='pc' * 10))
        self.assertTrue(self.decide(**ok, path='webcam/av', user='appa-pub', password='pa' * 10))
        denied = [
            dict(path='appa/cam', user='appa-pub', password='faux'),
            dict(path='appa/cam', user='', password=''),
            dict(path='appa/cam'),
            dict(path='appb/cam', user='appa-pub', password='pa' * 10),      # préfixe d'une autre app
            dict(path='appa/cam', user='capture', password='pc' * 10),       # source hors de ses chemins
            dict(path='appa/inconnu', user='appa-pub', password='pa' * 10),  # chemin non déclaré
            dict(path='appb/ip', user='appa-pub', password='pa' * 10),
            dict(path='appa/cam', user='appa-ctl', password='ca' * 10),      # identifiants de contrôle
            dict(path='appa/cam', user='lab-media-auth', password='i' * 40),  # identifiants internes
            dict(path='appb/cam', user='appb-ctl', password='cb' * 10),      # app-b n'a pas "publish"
            dict(path=None, user='appa-pub', password='pa' * 10),
        ]
        for body in denied:
            self.assertFalse(self.decide(**ok, **body), body)
        # WHIP : fermé, même avec de bons identifiants.
        self.assertFalse(self.decide(action='publish', protocol='webrtc', path='appa/cam',
                                     user='appa-pub', password='pa' * 10))
        self.assertFalse(self.decide(action='publish', protocol='webrtc', path='webcam/av',
                                     user='capture', password='pc' * 10))

    def test_internal_actions(self):
        for action in ('api', 'playback', 'metrics', 'pprof'):
            self.assertTrue(self.decide(action=action, user='lab-media-auth', password='i' * 40))
            self.assertFalse(self.decide(action=action, user='appa-ctl', password='ca' * 10))
            self.assertFalse(self.decide(action=action, user='appa-pub', password='pa' * 10))
            self.assertFalse(self.decide(action=action))

    def test_read_goes_to_owner_only(self):
        self.assertTrue(self.decide(action='read', path='appb/cam', token='t'))
        self.assertTrue(self.decide(action='read', path='webcam/av', token='t'))
        self.assertEqual(self.state.relayed, ['app-b', 'appa'])
        self.assertFalse(self.decide(action='read', path='autre/cam', token='t'))
        self.assertFalse(self.decide(action='read', path='appa/inconnu', token='t'))
        self.assertEqual(self.state.relayed, ['app-b', 'appa'])

    def test_everything_else_denied(self):
        self.assertFalse(self.decide(action='autre', path='appa/cam'))
        self.assertFalse(S.decide(self.state, b'pas du json')[0])
        self.assertFalse(S.decide(self.state, b'[]')[0])


class RelayTests(unittest.TestCase):
    """Relais réel vers un hook local : 200, refus, panne, lenteur, saturation."""

    def setUp(self):
        import threading
        from http.server import BaseHTTPRequestHandler, HTTPServer, ThreadingHTTPServer
        test = self
        test.mode, test.seen = 'ok', []

        class H(BaseHTTPRequestHandler):
            def do_POST(self):
                body = self.rfile.read(int(self.headers['Content-Length']))
                test.seen.append((self.path, body))
                if test.mode == 'hang':
                    import time
                    time.sleep(1.5)
                code = {'ok': 200, 'deny': 401, '500': 500, 'hang': 200, '204': 204}[test.mode]
                self.send_response(code)
                self.send_header('Content-Length', '0')
                self.end_headers()

            def log_message(self, *a):
                pass

        self.httpd = ThreadingHTTPServer(('127.0.0.1', 0), H)
        self.httpd.daemon_threads = True
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()
        port = self.httpd.server_address[1]
        reg = json.loads(json.dumps(REG))
        reg['apps']['appa']['read_hook'] = f'http://127.0.0.1:{port}/api/media-auth/'
        reg['apps']['app-b']['read_hook'] = 'http://127.0.0.1:9/hook'      # port fermé
        import os
        import tempfile
        fd, self.path = tempfile.mkstemp(suffix='.json')
        os.write(fd, json.dumps(reg).encode())
        os.close(fd)
        self.state = S.State({**ENV, 'LAB_MEDIA_AUTH_REGISTRY_FILE': self.path, 'LAB_MEDIA_READ_HOOK_TIMEOUT_S': '0.5'})

    def tearDown(self):
        import os
        self.httpd.shutdown()
        self.httpd.server_close()
        os.unlink(self.path)

    def read(self, path='appa/cam'):
        raw = json.dumps({'action': 'read', 'path': path, 'token': 'jeton', 'id': 'abc'}).encode()
        return S.decide(self.state, raw), raw

    def test_relay(self):
        (ok, info), raw = self.read()
        self.assertTrue(ok)
        self.assertEqual(self.seen, [('/api/media-auth/?key=' + 'a' * 20, raw)])   # corps tel quel, clé de l'app
        for mode in ('deny', '500', '204'):          # tout ce qui n'est pas 200 refuse
            self.mode = mode
            self.assertFalse(self.read()[0][0], mode)
        (ok, info), _ = self.read('appb/cam')        # hook injoignable
        self.assertFalse(ok)
        self.assertIn('injoignable', info['reason'])

    def test_hanging_hook_is_bounded_and_does_not_starve(self):
        import time
        self.mode = 'hang'
        t0 = time.perf_counter()
        (ok, info), _ = self.read()
        self.assertFalse(ok)
        self.assertLess(time.perf_counter() - t0, 1.0)
        self.assertIn('délai dépassé', info['reason'])
        import threading
        results = []
        threads = [threading.Thread(target=lambda: results.append(self.read()[0])) for _ in range(20)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()
        self.assertFalse(any(ok for ok, _ in results))
        self.assertTrue(any('saturé' in info['reason'] for _, info in results))


if __name__ == '__main__':
    unittest.main()
