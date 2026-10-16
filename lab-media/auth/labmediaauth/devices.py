"""Webcams USB de l'hôte (chantier webcams, contrat v1 : I0 et I1).

Ce module tient trois choses, et lab-media-auth est leur SEUL écrivain :

  * la DÉCOUVERTE : lecture de sysfs (rien n'est ouvert, aucun nœud /dev n'est touché), toutes
    les LAB_MEDIA_SCAN_S secondes. Un périphérique = un appareil USB dont une interface de
    classe vidéo (0e) porte un nœud video4linux d'index 0 (le nœud de capture ; l'index 1 est
    celui des métadonnées) ;
  * l'INVENTAIRE persistant (`<état>/inventory.json`) : toutes les webcams déjà vues, leur
    réglage d'enregistrement, les chemins oubliés gardés jusqu'à leur purge ;
  * le PLAN de capture (`<état>/plan`) : les webcams que lab-media-capture doit capturer, au
    plus MEDIA_CAPTURE_MAX. Une ligne par webcam : `<id> <port USB> <micro 0|1> <base>`,
    rien d'autre — aucune chaîne venue du matériel (nom, numéro de série) n'y entre.

Le nom de produit et le numéro de série sont des données HOSTILES : un appareil USB les choisit
librement. Ils ne servent qu'à l'affichage (`model`, `serial`, nettoyés et bornés) et, pour le
numéro de série, à l'identifiant après réduction à [a-z0-9]. Ils ne vont jamais dans un chemin,
une commande, ni le journal.
"""
from __future__ import annotations

import json
import os
import re
import threading
import time
from dataclasses import dataclass
from datetime import datetime

from . import registry as reg_mod

ID_RE = re.compile(r'^usb-[0-9a-f]{4}-[0-9a-f]{4}-[sp][a-z0-9-]{1,40}$')
PORT_RE = re.compile(r'^[0-9]{1,3}-[0-9]{1,3}(\.[0-9]{1,3}){0,6}$')
HEX4_RE = re.compile(r'^[0-9a-f]{4}$')
VIDEO_RE = re.compile(r'^video[0-9]{1,4}$')
CARD_RE = re.compile(r'^card([0-9]{1,3})$')
PCM_CAPTURE_RE = re.compile(r'^pcmC([0-9]{1,3})D([0-9]{1,3})c$')
CONTROL_CHARS = re.compile(r'[\x00-\x1f\x7f-\x9f  ‪-‮⁦-⁩]')
MODEL_MAX = 100
SERIAL_MAX = 64
STATES = ('live', 'waiting', 'starting', 'error', 'offline', 'legacy')
CAPTURE_GRACE_S = 20       # au-delà, une webcam planifiée mais non publiée est « error »
LAST_SEEN_PERSIST_S = 60   # last_seen d'une webcam branchée : écrit au plus une fois par minute
MAX_CAPTURE_LIMIT = 8      # MEDIA_CAPTURE_MAX est borné à [0, 8] (2 vCPU)


class DeviceError(Exception):
    def __init__(self, status: int, code: str, detail: str):
        super().__init__(detail)
        self.status, self.code, self.detail = status, code, detail


# ═════════════════════════════════════════════════════════════════════════════
# Découverte (sysfs seulement)
# ═════════════════════════════════════════════════════════════════════════════

def _read(path: str, limit: int = 256) -> str | None:
    try:
        with open(path, 'rb') as fh:
            raw = fh.read(limit + 1)
    except OSError:
        return None
    return raw[:limit].decode('utf-8', 'replace').strip('\n').strip()


def clean_text(value: str | None, limit: int) -> str:
    """Texte d'affichage : caractères de contrôle et de bidirectionnalité retirés, borné."""
    if not value:
        return ''
    return CONTROL_CHARS.sub('', value).strip()[:limit]


def device_id(vendor: str, product: str, serial: str, port: str) -> str | None:
    """Identifiant I0. None si l'appareil ne permet pas d'en former un valide."""
    reduced = re.sub(r'[^a-z0-9]', '', (serial or '').lower())[:24]
    if reduced:
        candidate = f'usb-{vendor}-{product}-s{reduced}'
    else:
        candidate = f'usb-{vendor}-{product}-p{port.replace(".", "-")}'
    return candidate if ID_RE.match(candidate) else None


@dataclass(frozen=True)
class Seen:
    """Une webcam vue branchée par un passage de la découverte."""
    id: str
    model: str
    vendor_id: str
    product_id: str
    serial: str
    usb_port: str
    has_audio: bool


def scan(sysfs: str) -> dict[str, Seen]:
    """Toutes les webcams branchées, d'après sysfs. Ne lève jamais : un appareil illisible
    ou incohérent est ignoré (il sera revu au passage suivant)."""
    found: dict[str, Seen] = {}
    v4l = os.path.join(sysfs, 'class', 'video4linux')
    try:
        names = sorted(os.listdir(v4l), key=lambda n: (len(n), n))
    except OSError:
        return found
    for name in names:
        if not VIDEO_RE.match(name):
            continue
        node = os.path.join(v4l, name)
        if _read(os.path.join(node, 'index')) != '0':
            continue
        real = os.path.realpath(node)                     # …/<port>/<port>:<c>.<i>/video4linux/videoN
        iface = os.path.dirname(os.path.dirname(real))
        usbdev = os.path.dirname(iface)
        port = os.path.basename(usbdev)
        if not PORT_RE.match(port) or not os.path.basename(iface).startswith(port + ':'):
            continue
        if _read(os.path.join(iface, 'bInterfaceClass')) != '0e':
            continue
        vendor = (_read(os.path.join(usbdev, 'idVendor')) or '').lower()
        product = (_read(os.path.join(usbdev, 'idProduct')) or '').lower()
        if not HEX4_RE.match(vendor) or not HEX4_RE.match(product):
            continue
        serial = clean_text(_read(os.path.join(usbdev, 'serial')), SERIAL_MAX)
        ident = device_id(vendor, product, serial, port)
        if ident is None or ident in found:
            continue          # deux fonctions vidéo sur un même appareil : la première seulement
        found[ident] = Seen(id=ident, model=clean_text(_read(os.path.join(usbdev, 'product')), MODEL_MAX),
                            vendor_id=vendor, product_id=product, serial=serial, usb_port=port,
                            has_audio=_has_capture_card(sysfs, usbdev))
    return found


def _has_capture_card(sysfs: str, usbdev: str) -> bool:
    """Vrai si une carte son du MÊME appareil USB a un périphérique PCM de capture."""
    sound = os.path.join(sysfs, 'class', 'sound')
    try:
        entries = os.listdir(sound)
    except OSError:
        return False
    cards = set()
    for entry in entries:
        m = CARD_RE.match(entry)
        if m and os.path.realpath(os.path.join(sound, entry)).startswith(usbdev + '/'):
            cards.add(m.group(1))
    return any((m := PCM_CAPTURE_RE.match(e)) and m.group(1) in cards for e in entries)


# ═════════════════════════════════════════════════════════════════════════════
# Inventaire
# ═════════════════════════════════════════════════════════════════════════════

@dataclass
class Device:
    id: str
    model: str
    vendor_id: str
    product_id: str
    serial: str
    usb_port: str
    has_audio: bool
    record: bool
    first_seen: float
    last_seen: float
    legacy: bool = False
    legacy_paths: dict | None = None
    # en mémoire seulement
    connected: bool = False
    assigned_at: float | None = None

    STORED = ('model', 'vendor_id', 'product_id', 'serial', 'usb_port', 'has_audio', 'record',
              'first_seen', 'last_seen')


def iso(epoch: float) -> str:
    return datetime.fromtimestamp(epoch).astimezone().isoformat(timespec='seconds')


class Manager:
    """Inventaire, plan et chemins des webcams. Tout passe sous `self.lock`."""

    def __init__(self, base: reg_mod.Registry, env: dict, on_change, clock=time.time):
        conf = base.devices
        if conf is None:
            raise reg_mod.RegistryError('Manager sans section "devices" au registre')
        self.base, self.conf, self.clock = base, conf, clock
        self.on_change = on_change              # appelé (sous verrou) quand les chemins changent
        self.sysfs = env.get('LAB_MEDIA_SYSFS', '/sys')
        self.dir = env.get('LAB_MEDIA_STATE_DIR', '/state')
        self.scan_s = float(env.get('LAB_MEDIA_SCAN_S', '2'))
        if not 0.2 <= self.scan_s <= 30:
            raise reg_mod.RegistryError('LAB_MEDIA_SCAN_S doit être entre 0.2 et 30')
        raw_max = env.get('MEDIA_CAPTURE_MAX', '2') or '2'
        if not raw_max.isdigit() or int(raw_max) > MAX_CAPTURE_LIMIT:
            raise reg_mod.RegistryError(f'MEDIA_CAPTURE_MAX doit être un entier de 0 à {MAX_CAPTURE_LIMIT}')
        self.max = int(raw_max)
        self.owner = base.owner(conf.prefix)
        self.lock = threading.RLock()
        self.devices: dict[str, Device] = {}
        self.retained: dict[str, float] = {}     # chemin → fin de rétention (epoch)
        self.legacy_forgotten = False
        self.pending: dict[str, int] = {}        # id nouveau → passages consécutifs où il est vu
        self.assigned: list[str] = []
        self._persisted_last_seen = 0.0
        self._load()
        self.assigned = [i for i in self._read_plan() if i in self.devices and not self.devices[i].legacy]

    # ── persistance ──────────────────────────────────────────────────────────
    @property
    def inventory_file(self) -> str:
        return os.path.join(self.dir, 'inventory.json')

    @property
    def plan_file(self) -> str:
        return os.path.join(self.dir, 'plan')

    def _load(self) -> None:
        try:
            with open(self.inventory_file, encoding='utf-8') as fh:
                data = json.load(fh)
        except FileNotFoundError:
            data = {'version': 1, 'devices': {}, 'retained': {}, 'legacy_forgotten': False}
        except (OSError, ValueError) as exc:
            # Jamais de remise à zéro silencieuse : on y perdrait les réglages d'enregistrement.
            raise reg_mod.RegistryError(f'inventaire {self.inventory_file} illisible ({type(exc).__name__})') from exc
        if not isinstance(data, dict) or data.get('version') != 1:
            raise reg_mod.RegistryError('inventaire : objet attendu avec "version": 1')
        for ident, row in (data.get('devices') or {}).items():
            if not ID_RE.match(ident) or not isinstance(row, dict) or set(row) != set(Device.STORED):
                raise reg_mod.RegistryError('inventaire : entrée de périphérique mal formée')
            dev = Device(id=ident, **row)
            if not (isinstance(dev.record, bool) and isinstance(dev.has_audio, bool)
                    and HEX4_RE.match(dev.vendor_id) and HEX4_RE.match(dev.product_id)
                    and isinstance(dev.first_seen, (int, float)) and isinstance(dev.last_seen, (int, float))
                    and PORT_RE.match(dev.usb_port)):
                raise reg_mod.RegistryError('inventaire : valeurs de périphérique mal formées')
            dev.model = clean_text(dev.model, MODEL_MAX)
            dev.serial = clean_text(dev.serial, SERIAL_MAX)
            self.devices[ident] = dev
        for path, until in (data.get('retained') or {}).items():
            if reg_mod.PATH_RE.match(path) and isinstance(until, (int, float)):
                self.retained[path] = float(until)
        self.legacy_forgotten = bool(data.get('legacy_forgotten'))
        legacy = self.conf.legacy
        if legacy is not None and not self.legacy_forgotten:
            self.devices[legacy.id] = Device(
                id=legacy.id, model=legacy.model, vendor_id=legacy.vendor_id,
                product_id=legacy.product_id, serial=legacy.serial, usb_port=legacy.usb_port,
                has_audio=legacy.has_audio, record=False, first_seen=legacy.first_seen,
                last_seen=legacy.last_seen, legacy=True, legacy_paths=dict(legacy.paths))

    def _save(self) -> None:
        data = {
            'version': 1,
            'devices': {d.id: {k: getattr(d, k) for k in Device.STORED}
                        for d in self.devices.values() if not d.legacy},
            'retained': self.retained,
            'legacy_forgotten': self.legacy_forgotten,
        }
        self._atomic(self.inventory_file, json.dumps(data, indent=1, sort_keys=True), 0o640)
        self._persisted_last_seen = self.clock()

    def _read_plan(self) -> list[str]:
        try:
            with open(self.plan_file, encoding='ascii') as fh:
                return [line.split(' ', 1)[0] for line in fh if ID_RE.match(line.split(' ', 1)[0])]
        except (OSError, UnicodeDecodeError):
            return []

    def _write_plan(self) -> None:
        lines = []
        for ident in self.assigned:
            dev = self.devices[ident]
            base = self.paths_of(dev)['av'].rsplit('/', 1)[0]
            lines.append(f'{ident} {dev.usb_port} {1 if dev.has_audio else 0} {base}\n')
        content = ''.join(lines)
        try:
            with open(self.plan_file, encoding='ascii') as fh:
                if fh.read() == content:
                    return
        except (OSError, UnicodeDecodeError):
            pass
        self._atomic(self.plan_file, content, 0o644)

    @staticmethod
    def _atomic(path: str, content: str, mode: int) -> None:
        tmp = f'{path}.tmp'
        with open(tmp, 'w', encoding='utf-8') as fh:
            fh.write(content)
        os.chmod(tmp, mode)
        os.replace(tmp, path)

    # ── chemins ──────────────────────────────────────────────────────────────
    def paths_of(self, dev: Device) -> dict:
        if dev.legacy:
            return dict(dev.legacy_paths)
        base = f'{self.conf.prefix}/{dev.id}'
        return {'av': f'{base}/av', 'video': f'{base}/video',
                'audio': f'{base}/audio' if dev.has_audio else None}

    def path_confs(self) -> tuple[dict, frozenset, dict]:
        """(chemins des périphériques, chemins publiables par la source, chemins retenus)."""
        conf, extra, publishable = self.conf, {}, set()
        for dev in self.devices.values():
            for kind, path in self.paths_of(dev).items():
                if path is None:
                    continue
                av = kind == 'av'
                extra[path] = reg_mod.PathConf(name=path, record=av and dev.record and not dev.legacy,
                                               segment=conf.segment, delete_after=conf.delete_after,
                                               retain=av)
                if not dev.legacy:
                    publishable.add(path)
        retained = {p: reg_mod.PathConf(name=p, segment=conf.segment, delete_after=conf.delete_after, retain=True)
                    for p in self.retained if p not in extra}
        return extra, frozenset(publishable), retained

    # ── un passage de la découverte ──────────────────────────────────────────
    def tick(self) -> None:
        seen = scan(self.sysfs)
        now = self.clock()
        with self.lock:
            paths_changed = saved = False
            for ident in list(self.pending):
                if ident not in seen:
                    del self.pending[ident]
            for ident, s in seen.items():
                dev = self.devices.get(ident)    # (un identifiant usb-… n'est jamais celui de l'héritée)
                if dev is None:
                    # Un nouveau venu doit être vu deux fois de suite : la carte son d'une webcam
                    # apparaît parfois un instant après son nœud vidéo.
                    self.pending[ident] = self.pending.get(ident, 0) + 1
                    if self.pending[ident] < 2:
                        continue
                    del self.pending[ident]
                    dev = Device(id=ident, model=s.model, vendor_id=s.vendor_id, product_id=s.product_id,
                                 serial=s.serial, usb_port=s.usb_port, has_audio=s.has_audio, record=False,
                                 first_seen=now, last_seen=now)
                    self.devices[ident] = dev
                    self.retained = {p: t for p, t in self.retained.items() if p not in self.paths_of(dev).values()}
                    paths_changed = saved = True
                    log('device', change='new', id=ident, has_audio=s.has_audio)
                if not dev.connected:
                    dev.connected = True
                    log('device', change='connected', id=ident)
                if s.has_audio and not dev.has_audio:      # un micro trouvé reste acquis
                    dev.has_audio = True
                    paths_changed = saved = True
                if (s.model, s.serial, s.usb_port) != (dev.model, dev.serial, dev.usb_port):
                    dev.model, dev.serial, dev.usb_port = s.model, s.serial, s.usb_port
                    saved = True
                dev.last_seen = now
            for dev in self.devices.values():
                if dev.connected and dev.id not in seen:
                    dev.connected = False
                    dev.assigned_at = None
                    saved = True
                    log('device', change='disconnected', id=dev.id)
            expired = [p for p, until in self.retained.items() if until <= now]
            for p in expired:
                del self.retained[p]
                paths_changed = saved = True
            self._replan(now)
            if paths_changed:
                self.on_change()
            stale = now - self._persisted_last_seen >= LAST_SEEN_PERSIST_S
            if saved or (stale and any(d.connected for d in self.devices.values())):
                self._save()
            self._write_plan()

    def _replan(self, now: float) -> None:
        """Les webcams déjà capturées gardent leur place (jamais de préemption) ; les places
        libres vont aux webcams branchées en attente, la plus anciennement vue d'abord."""
        keep = [i for i in self.assigned if i in self.devices and self.devices[i].connected][:self.max]
        waiting = sorted((d for d in self.devices.values()
                          if d.connected and not d.legacy and d.id not in keep),
                         key=lambda d: (d.first_seen, d.id))
        for dev in waiting[:max(0, self.max - len(keep))]:
            keep.append(dev.id)
            dev.assigned_at = now
            log('device', change='capture', id=dev.id)
        for ident in keep:
            if self.devices[ident].assigned_at is None:
                self.devices[ident].assigned_at = now
        for ident in set(self.assigned) - set(keep):
            if ident in self.devices:
                self.devices[ident].assigned_at = None
            log('device', change='capture-stop', id=ident)
        self.assigned = keep

    # ── API I1 ───────────────────────────────────────────────────────────────
    def owns(self, app) -> bool:
        return self.owner is not None and app is not None and app.name == self.owner.name

    def describe(self, dev: Device, ready: set | None, now: float) -> dict:
        paths = self.paths_of(dev)
        item = {
            'id': dev.id, 'kind': 'webcam', 'model': dev.model,
            'vendor_id': dev.vendor_id, 'product_id': dev.product_id, 'serial': dev.serial,
            'usb_port': dev.usb_port, 'has_audio': dev.has_audio,
            'connected': dev.connected, 'state': None, 'record': dev.record and not dev.legacy,
            'first_seen': iso(dev.first_seen),
            'last_seen': iso(now if dev.connected else dev.last_seen),
            'paths': paths,
        }
        if dev.legacy:
            item['state'] = 'legacy'
        elif not dev.connected:
            item['state'] = 'offline'
        elif dev.id not in self.assigned:
            item['state'] = 'waiting'
        elif ready is not None and paths['av'] in ready:
            item['state'] = 'live'
        elif dev.assigned_at is not None and now - dev.assigned_at < CAPTURE_GRACE_S:
            item['state'] = 'starting'
        else:
            item['state'] = 'error'
            item['error_detail'] = (
                'Serveur média injoignable.' if ready is None else
                f'Aucun flux publié depuis plus de {CAPTURE_GRACE_S} s : capture arrêtée ou en échec '
                '(voir le journal de lab-media-capture).')
        return item

    def list(self, ready: set | None) -> list[dict]:
        now = self.clock()
        with self.lock:
            devs = sorted(self.devices.values(), key=lambda d: (d.first_seen, d.id))
            return [self.describe(d, ready, now) for d in devs]

    def get(self, ident: str, ready: set | None) -> dict:
        with self.lock:
            dev = self.devices.get(ident)
            if dev is None:
                raise DeviceError(404, 'unknown_device', 'Périphérique inconnu pour cette app.')
            return self.describe(dev, ready, self.clock())

    def set_record(self, ident: str, record: bool) -> None:
        with self.lock:
            dev = self.devices.get(ident)
            if dev is None:
                raise DeviceError(404, 'unknown_device', 'Périphérique inconnu pour cette app.')
            if dev.legacy:
                raise DeviceError(409, 'legacy', "L'entrée héritée ne s'enregistre plus.")
            if dev.record != record:
                dev.record = record
                self._save()
                self.on_change()
                log('device', change='record', id=ident, record=record)

    def forget(self, ident: str) -> None:
        with self.lock:
            dev = self.devices.get(ident)
            if dev is None:
                raise DeviceError(404, 'unknown_device', 'Périphérique inconnu pour cette app.')
            if dev.connected:
                raise DeviceError(409, 'connected', 'Un périphérique branché ne peut pas être oublié.')
            until = self.clock() + _seconds(self.conf.delete_after)
            for path in self.paths_of(dev).values():
                if path is not None:
                    self.retained[path] = until
            del self.devices[ident]
            if dev.legacy:
                self.legacy_forgotten = True
            self._save()
            self.on_change()
            log('device', change='forgotten', id=ident)


def _seconds(duration: str) -> int:
    return int(duration[:-1]) * {'s': 1, 'm': 60, 'h': 3600, 'd': 86400}[duration[-1]]


def log(event: str, **fields) -> None:   # remplacé par server.log au démarrage
    pass
