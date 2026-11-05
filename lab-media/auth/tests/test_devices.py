"""Tests sans réseau : découverte des webcams (faux sysfs), inventaire, plan, API I1 du gestionnaire."""
import json
import os
import shutil
import tempfile
import unittest

from labmediaauth import devices as D
from labmediaauth import registry as R

from .test_registry import ENV

HOSTILE = '"; touch /tmp/pwned; $(reboot) `id` \x1b[31m‮RTL\n<script>alert(1)</script>' + 'x' * 200

REG = {
    'version': 1,
    'apps': {
        'appa': {'prefixes': ['appa', 'webcam'], 'read_hook': 'http://appa:8000/hook', 'publish': True},
        'app-b': {'prefixes': ['appb'], 'read_hook': 'http://appb:8000/hook'},
    },
    'sources': {'capture': {'devices': True}},
    'devices': {
        'prefix': 'webcam', 'source': 'capture', 'segment': '1h', 'delete_after': '7d',
        'legacy': {'id': 'webcam-ancienne', 'model': 'USB PHY 2.0', 'vendor_id': '1224', 'product_id': '2a25',
                   'serial': '', 'usb_port': '', 'has_audio': True,
                   'first_seen': '2026-10-10T17:57:12+00:00', 'last_seen': '2026-10-14T20:30:00+00:00',
                   'paths': {'av': 'webcam/av', 'video': 'webcam/video', 'audio': 'webcam/audio'}},
    },
    'paths': {'appa/cam': {}, 'appb/cam': {}},
}


class FakeSys:
    """Arborescence sysfs minimale, de la forme de celle de l'hôte (liens de classe → devices/)."""

    def __init__(self, root):
        self.root = root
        for d in ('class/video4linux', 'class/sound', 'devices'):
            os.makedirs(os.path.join(root, d), exist_ok=True)
        self.minor = 100

    def _w(self, path, text):
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, 'wb') as fh:
            fh.write(text.encode() if isinstance(text, str) else text)

    def _link(self, cls, name, target):
        os.symlink(os.path.relpath(target, os.path.join(self.root, 'class', cls)),
                   os.path.join(self.root, 'class', cls, name))

    def plug(self, port, vid='1b3f', pid='0001', product='Cam', serial=None, mic=False, iface_class='0e',
             with_index0=True):
        dev = os.path.join(self.root, 'devices', 'usb9', port)
        self._w(os.path.join(dev, 'idVendor'), vid + '\n')
        self._w(os.path.join(dev, 'idProduct'), pid + '\n')
        self._w(os.path.join(dev, 'product'), product + '\n')
        if serial is not None:
            self._w(os.path.join(dev, 'serial'), serial + '\n')
        iface = os.path.join(dev, f'{port}:1.0')
        self._w(os.path.join(iface, 'bInterfaceClass'), iface_class + '\n')
        for index in ((0, 1) if with_index0 else (1,)):
            self.minor += 1
            name = f'video{self.minor}'
            node = os.path.join(iface, 'video4linux', name)
            self._w(os.path.join(node, 'index'), f'{index}\n')
            self._w(os.path.join(node, 'dev'), f'81:{self.minor}\n')
            self._link('video4linux', name, node)
        if mic:
            self.minor += 1
            card = os.path.join(dev, f'{port}:1.2', 'sound', f'card{self.minor}')
            self._w(os.path.join(card, 'id'), 'U20\n')
            pcm = os.path.join(card, f'pcmC{self.minor}D0c')
            os.makedirs(pcm)
            self._link('sound', f'card{self.minor}', card)
            self._link('sound', f'pcmC{self.minor}D0c', pcm)

    def unplug(self, port):
        dev = os.path.join(self.root, 'devices', 'usb9', port)
        for cls in ('video4linux', 'sound'):
            base = os.path.join(self.root, 'class', cls)
            for name in os.listdir(base):
                if os.path.realpath(os.path.join(base, name)).startswith(dev + '/'):
                    os.unlink(os.path.join(base, name))
        shutil.rmtree(dev)


class Clock:
    def __init__(self):
        self.t = 1_800_000_000.0

    def __call__(self):
        return self.t


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.sys = FakeSys(os.path.join(self.tmp, 'sys'))
        self.state_dir = os.path.join(self.tmp, 'state')
        os.makedirs(self.state_dir)
        self.changes = 0
        self.clock = Clock()
        self.reg = R.load(json.dumps(REG), ENV)

    def tearDown(self):
        shutil.rmtree(self.tmp)

    def manager(self, **env):
        def changed():
            self.changes += 1
        return D.Manager(self.reg, {'LAB_MEDIA_SYSFS': self.sys.root, 'LAB_MEDIA_STATE_DIR': self.state_dir,
                                    'MEDIA_CAPTURE_MAX': '2', **env}, changed, clock=self.clock)

    def ticks(self, m, n=2):
        for _ in range(n):
            self.clock.t += 2
            m.tick()

    def plan(self):
        with open(os.path.join(self.state_dir, 'plan')) as fh:
            return fh.read()

    def states(self, m, ready=frozenset()):
        return {i['id']: i['state'] for i in m.list(set(ready))}


class IdentifierTests(unittest.TestCase):
    def test_forms(self):
        self.assertEqual(D.device_id('32e4', '9230', '', '3-4'), 'usb-32e4-9230-p3-4')
        self.assertEqual(D.device_id('32e4', '9230', '', '1-1.2.3'), 'usb-32e4-9230-p1-1-2-3')
        self.assertEqual(D.device_id('046d', '0825', 'AB:12-cd/34', '3-4'), 'usb-046d-0825-sab12cd34')
        self.assertEqual(D.device_id('046d', '0825', 'X' * 60, '3-4'), 'usb-046d-0825-s' + 'x' * 24)
        # numéro de série réduit à rien : forme « port »
        self.assertEqual(D.device_id('046d', '0825', '!!! ---', '3-4'), 'usb-046d-0825-p3-4')
        self.assertEqual(D.device_id('046d', '0825', HOSTILE, '3-4'),
                         'usb-046d-0825-stouchtmppwnedrebootid31m')
        for ident in ('usb-32e4-9230-p3-4', D.device_id('046d', '0825', HOSTILE, '3-4')):
            self.assertRegex(ident, r'^usb-[0-9a-f]{4}-[0-9a-f]{4}-[sp][a-z0-9-]{1,40}$')

    def test_clean_text(self):
        out = D.clean_text(HOSTILE, 100)
        self.assertLessEqual(len(out), 100)
        self.assertNotRegex(out, r'[\x00-\x1f\x7f‮]')


class ScanTests(Base):
    def test_scan(self):
        self.sys.plug('9-1', serial='SN-01', mic=True, product=HOSTILE)
        self.sys.plug('9-2', vid='32e4', pid='9230')                      # sans série, sans micro
        self.sys.plug('9-3', iface_class='01')                             # pas une interface vidéo
        self.sys.plug('9-4', with_index0=False)                            # métadonnées seulement
        self.sys.plug('9-5.3', vid='ABCD', pid='00EF')                     # hexadécimal en majuscules
        found = D.scan(self.sys.root)
        self.assertEqual(sorted(found), ['usb-1b3f-0001-ssn01', 'usb-32e4-9230-p9-2', 'usb-abcd-00ef-p9-5-3'])
        cam1 = found['usb-1b3f-0001-ssn01']
        self.assertTrue(cam1.has_audio)
        self.assertEqual(cam1.serial, 'SN-01')
        self.assertEqual(cam1.usb_port, '9-1')
        self.assertLessEqual(len(cam1.model), 100)
        self.assertNotIn('\n', cam1.model)
        self.assertFalse(found['usb-32e4-9230-p9-2'].has_audio)

    def test_mic_of_another_device_is_not_associated(self):
        self.sys.plug('9-1')
        self.sys.plug('9-2', mic=True, iface_class='01')       # micro seul, autre appareil
        self.assertFalse(D.scan(self.sys.root)['usb-1b3f-0001-p9-1'].has_audio)

    def test_missing_sysfs(self):
        self.assertEqual(D.scan(os.path.join(self.tmp, 'absent')), {})


class ManagerTests(Base):
    def test_legacy_entry(self):
        m = self.manager()
        items = m.list(set())
        self.assertEqual(len(items), 1)
        legacy = items[0]
        self.assertEqual((legacy['id'], legacy['state'], legacy['connected'], legacy['record']),
                         ('webcam-ancienne', 'legacy', False, False))
        self.assertEqual(legacy['paths'], {'av': 'webcam/av', 'video': 'webcam/video', 'audio': 'webcam/audio',
                                           'talk': None})
        with self.assertRaises(D.DeviceError) as ctx:
            m.set_record('webcam-ancienne', True)
        self.assertEqual((ctx.exception.status, ctx.exception.code), (409, 'legacy'))
        extra, publishable, _ = m.path_confs()
        self.assertFalse(extra['webcam/av'].record)
        self.assertTrue(extra['webcam/av'].retain)             # purge des anciens segments
        self.assertNotIn('webcam/av', publishable)             # jamais capturée

    def test_discovery_cap_and_states(self):
        m = self.manager()
        self.sys.plug('9-1', serial='SN-01', mic=True)
        self.clock.t += 2
        m.tick()
        self.assertEqual(len(m.list(set())), 1, 'un nouveau venu doit être vu deux fois de suite')
        self.clock.t += 2
        m.tick()
        self.sys.plug('9-2')
        self.ticks(m)
        self.sys.plug('9-3')
        self.ticks(m)
        st = self.states(m, ready={'webcam/usb-1b3f-0001-ssn01/av'})
        self.assertEqual(st, {'webcam-ancienne': 'legacy', 'usb-1b3f-0001-ssn01': 'live',
                              'usb-1b3f-0001-p9-2': 'starting', 'usb-1b3f-0001-p9-3': 'waiting'})
        self.assertEqual(self.plan(), 'usb-1b3f-0001-ssn01 9-1 1 webcam/usb-1b3f-0001-ssn01\n'
                                      'usb-1b3f-0001-p9-2 9-2 0 webcam/usb-1b3f-0001-p9-2\n')
        cam2 = m.get('usb-1b3f-0001-p9-2', set())
        self.assertEqual(cam2['paths'], {'av': 'webcam/usb-1b3f-0001-p9-2/av',
                                         'video': 'webcam/usb-1b3f-0001-p9-2/video', 'audio': None, 'talk': None})
        self.assertFalse(cam2['has_audio'])
        self.clock.t += D.CAPTURE_GRACE_S + 1
        item = m.get('usb-1b3f-0001-p9-2', set())
        self.assertEqual(item['state'], 'error')
        self.assertIn('error_detail', item)
        self.assertEqual(m.get('usb-1b3f-0001-p9-2', None)['error_detail'], 'Serveur média injoignable.')
        # débranchement : hors ligne, sa place va à la webcam en attente, sans préemption
        self.sys.unplug('9-1')
        self.ticks(m, 1)
        st = self.states(m)
        self.assertEqual(st['usb-1b3f-0001-ssn01'], 'offline')
        self.assertEqual(st['usb-1b3f-0001-p9-3'], 'starting')
        self.assertEqual(self.plan().splitlines(), ['usb-1b3f-0001-p9-2 9-2 0 webcam/usb-1b3f-0001-p9-2',
                                                    'usb-1b3f-0001-p9-3 9-3 0 webcam/usb-1b3f-0001-p9-3'])
        # rebranché : plus ancien que cam3, mais ne la déloge pas
        self.sys.plug('9-1', serial='SN-01', mic=True)
        self.ticks(m, 1)
        self.assertEqual(self.states(m)['usb-1b3f-0001-ssn01'], 'waiting')
        off = m.get('usb-1b3f-0001-ssn01', set())
        self.assertTrue(off['connected'])

    def test_ten_at_once_respects_cap(self):
        m = self.manager(MEDIA_CAPTURE_MAX='2')
        for k in range(10):
            self.sys.plug(f'9-{k + 1}')
        self.ticks(m)
        self.assertEqual(len(self.plan().splitlines()), 2)
        st = self.states(m)
        self.assertEqual(sum(1 for s in st.values() if s == 'starting'), 2)
        self.assertEqual(sum(1 for s in st.values() if s == 'waiting'), 8)
        for k in range(10):
            self.sys.unplug(f'9-{k + 1}')
        self.ticks(m, 1)
        self.assertEqual(self.plan(), '')

    def test_cap_bounds(self):
        for bad in ('-1', '9', 'deux', '2.5'):
            with self.assertRaises(R.RegistryError, msg=bad):
                self.manager(MEDIA_CAPTURE_MAX=bad)
        m = self.manager(MEDIA_CAPTURE_MAX='0')
        self.sys.plug('9-1')
        self.ticks(m)
        self.assertEqual(self.states(m)['usb-1b3f-0001-p9-1'], 'waiting')

    def test_record_persistence_and_restart(self):
        m = self.manager()
        self.sys.plug('9-1', mic=True)
        self.sys.plug('9-2')
        self.ticks(m)
        before = self.changes
        m.set_record('usb-1b3f-0001-p9-2', True)
        self.assertEqual(self.changes, before + 1)
        self.assertTrue(m.path_confs()[0]['webcam/usb-1b3f-0001-p9-2/av'].record)
        m.set_record('usb-1b3f-0001-p9-2', True)               # sans changement : rien à réécrire
        self.assertEqual(self.changes, before + 1)
        plan = self.plan()
        # « redémarrage » : nouveau gestionnaire, même dossier d'état
        m2 = self.manager()
        m2.tick()
        self.assertTrue(m2.get('usb-1b3f-0001-p9-2', set())['record'])
        self.assertEqual(self.plan(), plan)
        self.assertEqual(m2.get('usb-1b3f-0001-p9-1', set())['first_seen'],
                         m.get('usb-1b3f-0001-p9-1', set())['first_seen'])
        with self.assertRaises(D.DeviceError) as ctx:
            m2.set_record('usb-0000-0000-p1-1', True)
        self.assertEqual(ctx.exception.status, 404)

    def test_restart_keeps_assignment_even_if_older_device_waits(self):
        m = self.manager(MEDIA_CAPTURE_MAX='1')
        self.sys.plug('9-1')
        self.ticks(m)
        self.sys.unplug('9-1')
        self.sys.plug('9-2')
        self.ticks(m)
        self.sys.plug('9-1')
        self.ticks(m)
        self.assertEqual(self.plan().split(' ')[0], 'usb-1b3f-0001-p9-2')
        m2 = self.manager(MEDIA_CAPTURE_MAX='1')
        m2.tick()
        self.assertEqual(self.plan().split(' ')[0], 'usb-1b3f-0001-p9-2')

    def test_forget(self):
        m = self.manager()
        self.sys.plug('9-1')
        self.ticks(m)
        with self.assertRaises(D.DeviceError) as ctx:
            m.forget('usb-1b3f-0001-p9-1')
        self.assertEqual((ctx.exception.status, ctx.exception.code), (409, 'connected'))
        self.sys.unplug('9-1')
        self.ticks(m, 1)
        m.forget('usb-1b3f-0001-p9-1')
        self.assertNotIn('usb-1b3f-0001-p9-1', [i['id'] for i in m.list(set())])
        extra, publishable, retained = m.path_confs()
        self.assertNotIn('webcam/usb-1b3f-0001-p9-1/av', extra)
        self.assertIn('webcam/usb-1b3f-0001-p9-1/av', retained)        # purge laissée à MediaMTX
        self.assertTrue(retained['webcam/usb-1b3f-0001-p9-1/av'].retain)
        # la rétention expire
        self.clock.t += 7 * 86400 + 1
        m.tick()
        self.assertNotIn('webcam/usb-1b3f-0001-p9-1/av', m.path_confs()[2])
        # l'héritée peut être oubliée, et le reste après redémarrage
        m.forget('webcam-ancienne')
        self.assertEqual(m.list(set()), [])
        self.assertIn('webcam/av', m.path_confs()[2])
        self.assertEqual(self.manager().list(set()), [])

    def test_plan_never_carries_hardware_strings(self):
        m = self.manager()
        self.sys.plug('9-1', serial=HOSTILE, product=HOSTILE, mic=True)
        self.ticks(m)
        plan = self.plan()
        self.assertRegex(plan, r'^usb-[0-9a-f-]+-s[a-z0-9]+ 9-1 1 webcam/usb-[a-z0-9-]+\n$')
        item = m.list(set())[-1]
        self.assertEqual(json.loads(json.dumps(item))['model'], item['model'])
        self.assertNotIn('\n', item['model'])
        self.assertLessEqual(len(item['model']), 100)

    def test_corrupt_inventory_refuses_to_start(self):
        with open(os.path.join(self.state_dir, 'inventory.json'), 'w') as fh:
            fh.write('{pas du json')
        with self.assertRaises(R.RegistryError):
            self.manager()

    def test_registry_merge_and_render(self):
        m = self.manager()
        self.sys.plug('9-1', mic=True)
        self.ticks(m)
        m.set_record('usb-1b3f-0001-p9-1', True)
        extra, publishable, retained = m.path_confs()
        reg = R.with_paths(self.reg, extra, publishable)
        self.assertEqual(reg.owner('webcam/usb-1b3f-0001-p9-1/av').name, 'appa')
        self.assertIn('webcam/usb-1b3f-0001-p9-1/audio', reg.sources['capture'].paths)
        self.assertNotIn('webcam/av', reg.sources['capture'].paths)
        self.assertEqual(self.reg.sources['capture'].paths, frozenset())    # le registre du fichier est intact
        out = R.render_mediamtx('logLevel: info\n', reg, retained)
        self.assertIn('  "webcam/usb-1b3f-0001-p9-1/av":\n    source: publisher\n    record: yes\n', out)
        self.assertIn('  "webcam/av":\n    source: publisher\n    record: no\n    recordFormat: fmp4\n', out)
        self.assertIn('    recordDeleteAfter: 7d\n', out)
        self.assertIn('  "webcam/usb-1b3f-0001-p9-1/video":\n    source: publisher\n    record: no\n', out)


SPK_REG = json.loads(json.dumps(REG))
SPK_REG['apps']['appa']['prefixes'] = ['appa', 'webcam', 'speaker']
SPK_REG['devices']['speakers'] = {
    'hp-jack': {'model': 'Haut-parleur (prise jack)', 'pcm': 'plughw:CARD=PCH,DEV=0',
                'mixer': {'card': 'PCH'}},
    'hp-libre': {'model': 'Sans mixeur', 'pcm': 'null', 'mixer': None},
}
SPK_FIELDS = {'id', 'kind', 'model', 'vendor_id', 'product_id', 'serial', 'usb_port', 'has_audio', 'connected',
              'state', 'record', 'first_seen', 'last_seen', 'paths'}


class SpeakerTests(Base):
    def setUp(self):
        super().setUp()
        self.reg = R.load(json.dumps(SPK_REG), ENV)
        self.status = os.path.join(self.tmp, 'speakers')
        os.makedirs(self.status)

    def manager(self, **env):
        return super().manager(LAB_MEDIA_SPEAKER_STATUS_DIR=self.status, **env)

    def write_status(self, ident, text, age=0.0):
        path = os.path.join(self.status, ident)
        with open(path, 'w') as fh:
            fh.write(text + '\n')
        os.utime(path, (self.clock.t - age, self.clock.t - age))

    def read_state(self, name):
        with open(os.path.join(self.state_dir, name)) as fh:
            return fh.read()

    def test_registry(self):
        hp = self.reg.devices.speakers['hp-jack']
        self.assertEqual((hp.pcm, hp.mixer.card, hp.mixer.control, hp.mixer.volume),
                         ('plughw:CARD=PCH,DEV=0', 'PCH', 'Master', 80))       # défauts : Master, 80 %
        self.assertIsNone(self.reg.devices.speakers['hp-libre'].mixer)

    def test_bad_speakers(self):
        def broken(mutate):
            reg = json.loads(json.dumps(SPK_REG))
            mutate(reg)
            return reg
        cases = [
            lambda r: r['apps']['appa'].update(prefixes=['appa', 'webcam']),                 # préfixe absent
            lambda r: r['apps']['app-b'].update(prefixes=['appb', 'speaker']) or
            r['apps']['appa'].update(prefixes=['appa', 'webcam']),                             # autre app
            lambda r: r['devices']['speakers'].update({'usb-1234-5678-p1-1': r['devices']['speakers']['hp-libre']}),
            lambda r: r['devices']['speakers'].update({'webcam-x': r['devices']['speakers']['hp-libre']}),
            lambda r: r['devices']['speakers'].update({'Hp': r['devices']['speakers']['hp-libre']}),
            lambda r: r['devices']['speakers']['hp-jack'].update(pcm='plughw:0,0; reboot'),
            lambda r: r['devices']['speakers']['hp-jack'].update(pcm='hw 0'),
            lambda r: r['devices']['speakers']['hp-jack'].update(mixer={'card': 'PCH', 'volume': 101}),
            lambda r: r['devices']['speakers']['hp-jack'].update(mixer={'card': 'PCH', 'volume': True}),
            lambda r: r['devices']['speakers']['hp-jack'].update(mixer={'card': 'PCH', 'control': 'Line Out'}),
            lambda r: r['devices']['speakers']['hp-jack'].update(mixer={'card': 'P C H'}),
            lambda r: r['devices']['speakers']['hp-jack'].update(mixer={'control': 'Master'}),
            lambda r: r['devices']['speakers']['hp-jack'].pop('mixer'),
            lambda r: r['devices']['speakers']['hp-jack'].update(record=True),
            lambda r: r['devices']['speakers']['hp-jack'].update(model='a\nb'),
            lambda r: r['paths'].update({'speaker/x': {}}),
        ]
        for i, mutate in enumerate(cases):
            with self.assertRaises(R.RegistryError, msg=str(i)):
                R.load(json.dumps(broken(mutate)), ENV)

    def test_paths_plan_and_render(self):
        m = self.manager()
        extra, publishable, _ = m.path_confs()
        self.assertTrue(extra['speaker/hp-jack'].talk)
        self.assertFalse(extra['speaker/hp-jack'].record)
        self.assertNotIn('speaker/hp-jack', publishable)          # la source ne publie jamais dessus
        reg = R.with_paths(self.reg, extra, publishable)
        self.assertTrue(reg.is_talk('speaker/hp-jack'))
        self.assertFalse(reg.is_talk('appa/cam'))
        out = R.render_mediamtx('logLevel: info\n', reg)
        self.assertIn('  "speaker/hp-jack":\n    source: publisher\n    record: no\n  "', out)
        self.assertEqual(self.read_state('speakers'), 'hp-jack plughw:CARD=PCH,DEV=0 PCH Master 80\n'
                                                      'hp-libre null - - -\n')
        self.assertEqual(self.read_state('talk'), 'hp-jack 0 0\nhp-libre 0 0\n')

    def test_states(self):
        m = self.manager()
        st = lambda ready=frozenset(): {i['id']: i for i in m.list(set(ready)) if i['kind'] == 'speaker'}
        items = st()
        self.assertEqual(list(items), ['hp-jack', 'hp-libre'])
        hp = items['hp-jack']
        self.assertEqual(set(hp), SPK_FIELDS)
        self.assertEqual((hp['state'], hp['connected'], hp['record'], hp['has_audio']), ('offline', False, False, False))
        self.assertEqual(hp['paths'], {'av': None, 'video': None, 'audio': None, 'talk': 'speaker/hp-jack'})
        self.assertEqual((hp['vendor_id'], hp['product_id'], hp['serial'], hp['usb_port']), ('', '', '', ''))
        self.write_status('hp-jack', 'idle')
        self.assertEqual(st()['hp-jack']['state'], 'idle')
        self.assertTrue(st()['hp-jack']['connected'])
        self.assertEqual(st({'speaker/hp-jack'})['hp-jack']['state'], 'talking')
        self.assertEqual(m.get('hp-jack', None)['state'], 'error')          # MediaMTX injoignable
        self.write_status('hp-jack', 'error mixer')
        hp = st()['hp-jack']
        self.assertEqual((hp['state'], hp['error_detail']), ('error', D.SPEAKER_ERRORS['mixer']))
        self.write_status('hp-jack', 'error output')
        self.assertEqual(st({'speaker/hp-jack'})['hp-jack']['error_detail'], D.SPEAKER_ERRORS['output'])
        self.write_status('hp-jack', 'idle', age=D.SPEAKER_STALE_S + 1)      # capture arrêtée
        self.assertEqual(st()['hp-jack']['state'], 'offline')

    def test_not_recordable_not_forgettable(self):
        m = self.manager()
        for call, code in ((lambda: m.set_record('hp-jack', True), 'not_recordable'),
                           (lambda: m.set_record('hp-jack', False), 'not_recordable'),
                           (lambda: m.check_recordable('hp-jack'), 'not_recordable'),
                           (lambda: m.forget('hp-jack'), 'not_forgettable')):
            with self.assertRaises(D.DeviceError) as ctx:
                call()
            self.assertEqual((ctx.exception.status, ctx.exception.code), (409, code))
        self.assertEqual(m.get('hp-jack', set())['id'], 'hp-jack')

    def test_first_seen_persists(self):
        m = self.manager()
        first = m.get('hp-jack', set())['first_seen']
        self.clock.t += 3600
        self.assertEqual(self.manager().get('hp-jack', set())['first_seen'], first)

    def test_talk_triggers(self):
        m = self.manager()
        m.update_talk({'speaker/hp-jack'})         # au démarrage : une parole en cours est retrouvée
        self.assertEqual(self.read_state('talk'), 'hp-jack 0 1\nhp-libre 0 0\n')
        m.update_talk(set())                       # finie
        self.assertFalse(m.talk['hp-jack']['active'])
        self.clock.t += D.TALK_PENDING_S + 1
        m.update_talk(set())
        self.assertFalse(m.talk_active())          # plus rien d'attendu : MediaMTX n'est plus interrogé
        m.talk_allowed('speaker/hp-jack')
        gen = m.talk['hp-jack']['gen']
        self.assertGreater(gen, 0)
        self.assertEqual(self.read_state('talk'), f'hp-jack {gen} 0\nhp-libre 0 0\n')
        self.assertTrue(m.talk_active())
        m.update_talk(set())                       # pas encore arrivée : toujours attendue
        self.assertTrue(m.talk_active())
        m.update_talk({'speaker/hp-jack'})
        self.assertEqual(self.read_state('talk'), f'hp-jack {gen} 1\nhp-libre 0 0\n')
        m.update_talk(set())
        self.assertFalse(m.talk_active())
        self.assertEqual(self.read_state('talk'), f'hp-jack {gen} 0\nhp-libre 0 0\n')
        m.talk_allowed('speaker/hp-jack')
        self.assertGreater(m.talk['hp-jack']['gen'], gen)
        m.talk_allowed('webcam/av')                # pas un haut-parleur : rien
        self.clock.t += D.TALK_PENDING_S + 1
        m.update_talk(set())                       # jamais arrivée
        self.assertFalse(m.talk_active())


class RegistryDevicesTests(unittest.TestCase):
    def test_bad_devices_sections(self):
        def broken(**patch):
            reg = json.loads(json.dumps(REG))
            for k, v in patch.items():
                node = reg
                keys = k.split('__')
                for key in keys[:-1]:
                    node = node[key]
                node[keys[-1]] = v
            return reg
        for patch in ({'devices__prefix': 'autre'}, {'devices__source': 'inconnue'},
                      {'devices__segment': '1 h'}, {'devices__legacy__id': 'usb-1234-5678-p1-1'},
                      {'devices__legacy__paths': {'av': 'appb/cam', 'video': 'webcam/video', 'audio': 'webcam/audio'}},
                      {'devices__legacy__first_seen': '2026-10-10 17:57'}, {'devices__extra': 1},
                      {'sources__capture': {'paths': []}}, {'paths__webcam/av': {}}):
            with self.assertRaises(R.RegistryError, msg=str(patch)):
                R.load(json.dumps(broken(**patch)), ENV)


if __name__ == '__main__':
    unittest.main()
