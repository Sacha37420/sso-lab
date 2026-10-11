"""Registre des apps, des sources et des chemins (contrat lab-media, I1 et I4).

Le registre est un fichier JSON sans aucun secret. Les secrets viennent de
l'environnement (lab-media/.env), sous des noms DÉRIVÉS du nom de l'entrée :

    app « mon-app »      LAB_MEDIA_APP_MON_APP_HOOK_KEY
                         LAB_MEDIA_APP_MON_APP_CONTROL_USER / _CONTROL_PASSWORD
                         LAB_MEDIA_APP_MON_APP_PUBLISH_USER / _PUBLISH_PASSWORD   (si "publish": true)
    source « capture »   LAB_MEDIA_SOURCE_CAPTURE_PUBLISH_USER / _PUBLISH_PASSWORD
    chemin tiré          la clé nommée par "source_env" (URL rtsp://… complète)

Toute incohérence arrête le service au démarrage : jamais de défaut silencieux
sur un secret, jamais de chemin sans propriétaire.
"""
from __future__ import annotations

import json
import re
from dataclasses import dataclass, field

NAME_RE = re.compile(r'^[a-z][a-z0-9-]{0,39}$')
SEGMENT = r'[a-z0-9][a-z0-9_-]{0,39}'
PATH_RE = re.compile(rf'^{SEGMENT}(/{SEGMENT}){{0,5}}$')
SECRET_RE = re.compile(r'^[A-Za-z0-9_-]+$')
DURATION_RE = re.compile(r'^[1-9][0-9]{0,5}(s|m|h|d)$')
PULL_RE = re.compile(r'^rtsps?://[^\s"\'\\]+$')
MIN_SECRET = 16

RECORD_PATH = '/recordings/%path/%Y-%m-%d_%H-%M-%S-%f'


class RegistryError(ValueError):
    pass


@dataclass(frozen=True)
class Creds:
    user: str
    password: str


@dataclass(frozen=True)
class App:
    name: str
    prefixes: tuple[str, ...]
    hook_url: str                 # sans la clé
    hook_key: str
    control: Creds
    publish: Creds | None


@dataclass(frozen=True)
class Source:
    name: str
    paths: frozenset[str]
    publish: Creds


@dataclass(frozen=True)
class PathConf:
    name: str
    record: bool = False
    segment: str = '1h'
    delete_after: str = '7d'
    pull_url: str | None = None   # None = « publisher »
    on_demand: bool = False


@dataclass
class Registry:
    apps: dict[str, App] = field(default_factory=dict)
    sources: dict[str, Source] = field(default_factory=dict)
    paths: dict[str, PathConf] = field(default_factory=dict)

    # ── propriété ────────────────────────────────────────────────────────────
    def owner(self, path) -> App | None:
        """App propriétaire de `path` : celle dont un préfixe est `path` ou un
        ancêtre de `path` (frontière de segment : « web » ne possède pas « webcam »)."""
        if not isinstance(path, str) or not PATH_RE.match(path):
            return None
        for app in self.apps.values():
            for prefix in app.prefixes:
                if path == prefix or path.startswith(prefix + '/'):
                    return app
        return None

    def owns(self, app: App, path) -> bool:
        owner = self.owner(path)
        return owner is not None and owner.name == app.name

    def app_paths(self, app: App) -> list[str]:
        return sorted(p for p in self.paths if self.owns(app, p))

    def app_by_control_user(self, user: str) -> App | None:
        for app in self.apps.values():
            if app.control.user == user:
                return app
        return None


def _env_key(kind: str, name: str, suffix: str) -> str:
    return f'LAB_MEDIA_{kind}_{name.upper().replace("-", "_")}_{suffix}'


def _secret(env: dict, key: str, *, minimum: int = MIN_SECRET) -> str:
    value = env.get(key, '')
    if not value:
        raise RegistryError(f'clé {key} absente ou vide dans .env')
    if 'CHANGE_ME' in value:
        raise RegistryError(f'clé {key} encore à CHANGE_ME')
    if not SECRET_RE.match(value):
        raise RegistryError(f'clé {key} : caractères hors [A-Za-z0-9_-]')
    if len(value) < minimum:
        raise RegistryError(f'clé {key} : moins de {minimum} caractères')
    return value


def _creds(env: dict, kind: str, name: str, role: str) -> Creds:
    return Creds(
        user=_secret(env, _env_key(kind, name, f'{role}_USER'), minimum=3),
        password=_secret(env, _env_key(kind, name, f'{role}_PASSWORD')),
    )


def load(text: str, env: dict) -> Registry:
    try:
        raw = json.loads(text)
    except ValueError as exc:
        raise RegistryError(f'registre illisible : {exc}') from exc
    if not isinstance(raw, dict) or raw.get('version') != 1:
        raise RegistryError('registre : objet attendu avec "version": 1')
    unknown = set(raw) - {'version', 'apps', 'sources', 'paths', '_doc'}
    if unknown:
        raise RegistryError(f'registre : clés inconnues {sorted(unknown)}')

    reg = Registry()

    for name, conf in (raw.get('apps') or {}).items():
        if not NAME_RE.match(name):
            raise RegistryError(f'app « {name} » : nom invalide')
        if not isinstance(conf, dict):
            raise RegistryError(f'app « {name} » : objet attendu')
        unknown = set(conf) - {'prefixes', 'read_hook', 'publish'}
        if unknown:
            raise RegistryError(f'app « {name} » : clés inconnues {sorted(unknown)}')
        prefixes = conf.get('prefixes')
        if not isinstance(prefixes, list) or not prefixes:
            raise RegistryError(f'app « {name} » : "prefixes" (liste non vide) requis')
        for prefix in prefixes:
            if not isinstance(prefix, str) or not PATH_RE.match(prefix):
                raise RegistryError(f'app « {name} » : préfixe invalide {prefix!r}')
        hook_url = conf.get('read_hook')
        if (not isinstance(hook_url, str) or not re.match(r'^https?://[^\s?#]+$', hook_url)):
            raise RegistryError(f'app « {name} » : "read_hook" doit être une URL http(s) sans query')
        publish = conf.get('publish', False)
        if not isinstance(publish, bool):
            raise RegistryError(f'app « {name} » : "publish" booléen attendu')
        reg.apps[name] = App(
            name=name,
            prefixes=tuple(prefixes),
            hook_url=hook_url,
            hook_key=_secret(env, _env_key('APP', name, 'HOOK_KEY')),
            control=_creds(env, 'APP', name, 'CONTROL'),
            publish=_creds(env, 'APP', name, 'PUBLISH') if publish else None,
        )

    # Préfixes disjoints : ni doublon, ni préfixe ancêtre d'un autre.
    seen: list[tuple[str, str]] = []
    for app in reg.apps.values():
        for prefix in app.prefixes:
            for other, other_app in seen:
                if (prefix == other or prefix.startswith(other + '/')
                        or other.startswith(prefix + '/')):
                    raise RegistryError(
                        f'préfixes en conflit : « {prefix} » ({app.name}) et « {other} » ({other_app})')
            seen.append((prefix, app.name))

    for name, conf in (raw.get('paths') or {}).items():
        if not PATH_RE.match(name):
            raise RegistryError(f'chemin « {name} » : nom invalide')
        if reg.owner(name) is None:
            raise RegistryError(f'chemin « {name} » : aucun préfixe d\'app ne le possède')
        if not isinstance(conf, dict):
            raise RegistryError(f'chemin « {name} » : objet attendu')
        unknown = set(conf) - {'record', 'segment', 'delete_after', 'source_env', 'on_demand'}
        if unknown:
            raise RegistryError(f'chemin « {name} » : clés inconnues {sorted(unknown)}')
        for key in ('segment', 'delete_after'):
            if key in conf and not (isinstance(conf[key], str) and DURATION_RE.match(conf[key])):
                raise RegistryError(f'chemin « {name} » : "{key}" de la forme 30s, 10m, 1h, 7d')
        for key in ('record', 'on_demand'):
            if not isinstance(conf.get(key, False), bool):
                raise RegistryError(f'chemin « {name} » : "{key}" booléen attendu')
        pull_url = None
        if 'source_env' in conf:
            key = conf['source_env']
            if not isinstance(key, str) or not re.match(r'^LAB_MEDIA_PULL_[A-Z0-9_]+$', key):
                raise RegistryError(f'chemin « {name} » : "source_env" doit nommer une clé LAB_MEDIA_PULL_…')
            pull_url = env.get(key, '')
            if not PULL_RE.match(pull_url):
                raise RegistryError(f'chemin « {name} » : {key} doit être une URL rtsp:// ou rtsps://')
        reg.paths[name] = PathConf(
            name=name,
            record=conf.get('record', False),
            segment=conf.get('segment', '1h'),
            delete_after=conf.get('delete_after', '7d'),
            pull_url=pull_url,
            on_demand=conf.get('on_demand', False),
        )

    for name, conf in (raw.get('sources') or {}).items():
        if not NAME_RE.match(name):
            raise RegistryError(f'source « {name} » : nom invalide')
        paths = conf.get('paths') if isinstance(conf, dict) else None
        if not isinstance(paths, list) or not paths or set(conf) - {'paths'}:
            raise RegistryError(f'source « {name} » : seule clé attendue "paths" (liste non vide)')
        for path in paths:
            if path not in reg.paths:
                raise RegistryError(f'source « {name} » : chemin « {path} » non déclaré dans "paths"')
            if reg.paths[path].pull_url:
                raise RegistryError(f'source « {name} » : « {path} » est un chemin tiré, personne n\'y publie')
        reg.sources[name] = Source(name=name, paths=frozenset(paths),
                                   publish=_creds(env, 'SOURCE', name, 'PUBLISH'))

    # Un nom d'utilisateur désigne une seule entrée : c'est par lui qu'on la retrouve.
    users: dict[str, str] = {}
    for app in reg.apps.values():
        for role, creds in (('contrôle', app.control), ('publication', app.publish)):
            if creds is None:
                continue
            label = f'{role} de {app.name}'
            if creds.user in users:
                raise RegistryError(f'utilisateur « {creds.user} » en double ({users[creds.user]}, {label})')
            users[creds.user] = label
    for source in reg.sources.values():
        label = f'source {source.name}'
        if source.publish.user in users:
            raise RegistryError(f'utilisateur « {source.publish.user} » en double ({users[source.publish.user]}, {label})')
        users[source.publish.user] = label
    return reg


def render_mediamtx(base_yml: str, reg: Registry) -> str:
    """mediamtx.yml complet : la base fixe + la section `paths:` dérivée du registre.

    Aucun chemin générique : tout chemin absent du registre est refusé par MediaMTX."""
    if re.search(r'^(paths|authHTTPExclude|authMethod|authInternalUsers)\s*:', base_yml, re.M):
        raise RegistryError('mediamtx.base.yml ne doit définir ni paths ni authentification')
    out = [base_yml.rstrip('\n'), '',
           '# ── Généré par lab-media-auth depuis le registre — ne pas éditer ──',
           'authMethod: http',
           'authHTTPExclude: []',
           'paths:']
    if not reg.paths:
        out[-1] = 'paths: {}'
    for name in sorted(reg.paths):
        conf = reg.paths[name]
        out.append(f'  {json.dumps(name)}:')
        if conf.pull_url:
            out.append(f'    source: {json.dumps(conf.pull_url)}')
            out.append('    rtspTransport: tcp')
            out.append(f'    sourceOnDemand: {"yes" if conf.on_demand else "no"}')
        else:
            out.append('    source: publisher')
        if conf.record:
            out += ['    record: yes',
                    '    recordFormat: fmp4',
                    f'    recordPath: {RECORD_PATH}',
                    f'    recordSegmentDuration: {conf.segment}',
                    f'    recordDeleteAfter: {conf.delete_after}']
        else:
            out.append('    record: no')
    return '\n'.join(out) + '\n'
