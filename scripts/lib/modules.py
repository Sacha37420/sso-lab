#!/usr/bin/env python3
"""scripts/lib/modules.py — catalogue des modules du lab, état, plan d'installation.

Chantier « modules », contrat v1 (chantiers/modules/CONTRAT.md, I1 et I2). SEUL endroit qui lit
une description de module et qui résout des dépendances : `lab-modules.sh` l'appelle, `install.sh`
et le moteur passent par `lab-modules.sh`. Deux implémentations de la résolution (shell et Python)
finiraient par ne plus donner le même ordre.

Lecture seule, à une exception près : `selection-add` écrit la sélection mémorisée (I5).
Aucune valeur de `.env` n'est jamais écrite sur la sortie : seulement « réglé ou non ».

Usage (racine du lab en premier argument, comme validate_compose.py reçoit ses chemins) :
    modules.py <racine> list
    modules.py <racine> show <nom> [--check] [--groups-file <fichier>]
    modules.py <racine> plan [--reinstall] [--with-deps] [--for-engine] <nom>[,<nom>…]
    modules.py <racine> selection
    modules.py <racine> selection-add <nom>[,…] [--by <uid>]
    modules.py <racine> declared-settings <nom>      # une clé déclarée par ligne (pour `settings`)
    modules.py <racine> hook <nom>                   # « script timeout_s » si un script est déclaré, rien sinon
Sortie JSON sur UNE ligne. Codes : 0 succès, 1 refus/échec métier (JSON rendu quand même), 2 usage.

Réglage de TEST seulement : LAB_MODULES_PS=<fichier> remplace l'appel à `docker ps` (lignes
« projet<TAB>état »). Il ne peut que changer l'état AFFICHÉ, jamais rien écrire.
"""
from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time

SCHEMA = 1
NAME_RE = re.compile(r"^[a-z0-9][a-z0-9_-]{0,62}$")
UID_RE = re.compile(r"^[a-z][a-z0-9]{1,30}$")
KEY_RE = re.compile(r"^[A-Z][A-Z0-9_]{0,63}$")
CMD_RE = re.compile(r"^[a-z0-9][a-z0-9._+-]{0,40}$")
VERSION_RE = re.compile(r"^[0-9]+(\.[0-9]+){0,3}$")
GROUP_RE = re.compile(r"^[A-Za-z0-9_-]{1,64}$")
MAX_BYTES = 64 * 1024

SOCLE = ("sso-lab", "infra", "runner")
REQUIRED_CADRE = ("storage", "oauth-hub", "lab-admin", "lab-mcp")
ENGINE = "lab-mcp"
CATEGORIES = ("socle", "cadriciel", "application")
CAT_ORDER = {c: i for i, c in enumerate(CATEGORIES)}

TOP_KEYS = {"schema", "name", "label", "description", "category", "required", "owner", "priority",
            "provides", "requires", "resources", "settings", "groups", "install"}
REQ_KEYS = {"modules", "system", "domain"}
RES_KEYS = {"build_ram_mb", "disk_mb", "build_minutes", "heavy_build"}
SET_KEYS = {"key", "question", "required", "secret"}
INST_KEYS = {"script", "windows", "timeout_s"}


def is_managed(key: str) -> bool:
    """Clés gérées par le cadriciel — MÊME liste que `scripts/app-env.sh is_managed` (les deux
    doivent bouger ensemble). Une description ne peut pas faire demander l'une d'elles."""
    if re.match(r"^(DB_|POSTGIS_|KEYCLOAK_|LAB_|COMPOSE_|DOCKER_)", key):
        return True
    return key in {"SECRET_KEY", "DOMAIN", "HOST_DEV_ROOT", "SERVER_URL_LAN", "SERVER_URL_WAN",
                   "PORT_KEYCLOAK", "HPORT_POSTGRES", "HPORT_DB", "ACME_EMAIL", "PORT_BACKEND",
                   "PORT_FRONTEND", "BACKEND_URL", "FRONTEND_URL", "SCRIPT_NAME"}


def placeholder(value: str) -> bool:
    return (not value) or "CHANGE_ME" in value or "VOTRE_IP_WAN" in value


def out(obj: dict, code: int = 0) -> None:
    sys.stdout.write(json.dumps(obj, ensure_ascii=False, separators=(",", ":")) + "\n")
    sys.exit(code)


def usage(msg: str) -> None:
    sys.stderr.write(f"modules.py : {msg}\n")
    sys.exit(2)


# ─────────────────────────────────────────────────────────────────────────────
# Lecture du lab
# ─────────────────────────────────────────────────────────────────────────────
def read_env(path: str) -> dict[str, str]:
    """Clés d'un .env (dernière occurrence ; commentaire de fin et guillemets retirés)."""
    values: dict[str, str] = {}
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            for line in fh:
                m = re.match(r"^([A-Za-z_][A-Za-z0-9_]*)=(.*)$", line.rstrip("\n"))
                if m:
                    v = re.sub(r"\s+#.*$", "", m.group(2)).strip()
                    values[m.group(1)] = v.strip("'\"")
    except OSError:
        pass
    return values


class Lab:
    def __init__(self, root: str) -> None:
        self.root = os.path.realpath(root)
        self.env = read_env(os.path.join(self.root, ".env"))
        self.superuser = os.environ.get("LAB_SUPERUSER") or self.env.get("LAB_SUPERUSER") or "sacha"
        self.state_dir = os.environ.get("LAB_STATE_DIR") or self.env.get("LAB_STATE_DIR") or os.path.join(self.root, ".lab-state")
        self._ps: dict[str, list[str]] | None = None

    # ── fichiers de registre ───────────────────────────────────────────────
    def lines(self, rel: str) -> list[str]:
        try:
            with open(os.path.join(self.root, rel), encoding="utf-8", errors="replace") as fh:
                return [ln.rstrip("\n") for ln in fh if ln.strip() and not ln.lstrip().startswith("#")]
        except OSError:
            return []

    def owner(self, name: str) -> str:
        found = ""
        for ln in self.lines(".owners"):
            parts = ln.split(":")
            if len(parts) >= 2 and parts[0] == name:
                found = parts[1].strip()
        return found if UID_RE.fullmatch(found or "") else self.superuser

    def has_owner_line(self, name: str) -> bool:
        return any(ln.split(":")[0] == name for ln in self.lines(".owners"))

    def priorities(self) -> dict[str, tuple[int, int]]:
        out_: dict[str, tuple[int, int]] = {}
        for ln in self.lines("scripts/app-priorities.conf"):
            parts = ln.strip().split(":")
            if len(parts) >= 3 and parts[1].isdigit() and parts[2].isdigit():
                out_[parts[0]] = (int(parts[1]), int(parts[2]))
        return out_

    def showcase(self) -> dict[str, tuple[str, str]]:
        out_: dict[str, tuple[str, str]] = {}
        for ln in self.lines(".app-descriptions"):
            parts = [p.strip() for p in ln.split("|")]
            if len(parts) >= 3 and parts[0]:
                out_[parts[0]] = (parts[1], parts[2])
        return out_

    def submodules(self) -> dict[str, str]:
        """Chemin (relatif) → nom de section, d'après .gitmodules (lu sans git)."""
        out_: dict[str, str] = {}
        section = ""
        for ln in self.lines(".gitmodules"):
            m = re.match(r'^\s*\[submodule\s+"([^"]+)"\]', ln)
            if m:
                section = m.group(1)
                continue
            m = re.match(r"^\s*path\s*=\s*(\S+)", ln)
            if m and section:
                out_[m.group(1)] = section
        return out_

    # ── dossiers ────────────────────────────────────────────────────────────
    def dir_of(self, name: str) -> str:
        """Même règle que registry_app_dir : deploiement/<nom> s'il existe, sinon la racine."""
        dep = os.path.join(self.root, "deploiement", name)
        return dep if os.path.isdir(dep) else os.path.join(self.root, name)

    def unit_names(self) -> set[str]:
        """Toute unité connue : dossier avec docker-compose.yml, sous-module déclaré, entrée du catalogue."""
        names: set[str] = set()
        for base in (self.root, os.path.join(self.root, "deploiement")):
            try:
                entries = os.listdir(base)
            except OSError:
                continue
            for e in entries:
                if e in ("_templates", "deploiement", "modules") or e.startswith("."):
                    continue
                if NAME_RE.fullmatch(e) and os.path.isfile(os.path.join(base, e, "docker-compose.yml")):
                    names.add(e)
        for path in self.submodules():
            n = os.path.basename(path.rstrip("/"))
            if NAME_RE.fullmatch(n):
                names.add(n)
        try:
            for f in os.listdir(os.path.join(self.root, "modules")):
                if f.endswith(".json") and NAME_RE.fullmatch(f[:-5]):
                    names.add(f[:-5])
        except OSError:
            pass
        return names

    # ── conteneurs ──────────────────────────────────────────────────────────
    def ps(self) -> dict[str, list[str]]:
        if self._ps is not None:
            return self._ps
        lines: list[str] = []
        fixture = os.environ.get("LAB_MODULES_PS")
        if fixture:
            try:
                with open(fixture, encoding="utf-8") as fh:
                    lines = fh.read().splitlines()
            except OSError:
                lines = []
        elif shutil.which("docker"):
            try:
                proc = subprocess.run(
                    ["docker", "ps", "-a", "--format", '{{.Label "com.docker.compose.project"}}\t{{.State}}'],
                    capture_output=True, text=True, timeout=20)
                lines = proc.stdout.splitlines() if proc.returncode == 0 else []
            except (OSError, subprocess.SubprocessError):
                lines = []
        self._ps = {}
        for ln in lines:
            project, _, state = ln.partition("\t")
            if project:
                self._ps.setdefault(project, []).append(state.strip())
        return self._ps

    def deployed(self, name: str) -> dict | None:
        try:
            with open(os.path.join(self.state_dir, "deployed", name + ".json"), encoding="utf-8") as fh:
                data = json.load(fh)
            return {"sha": data.get("sha"), "at": data.get("at")} if isinstance(data, dict) else None
        except (OSError, ValueError):
            return None

    # ── sélection mémorisée (I5) ────────────────────────────────────────────
    def selection_path(self) -> str:
        return os.path.join(self.state_dir, "modules", "selection.json")

    def selection(self) -> dict:
        try:
            with open(self.selection_path(), encoding="utf-8") as fh:
                data = json.load(fh)
            mods = [m for m in data.get("modules") or [] if isinstance(m, str) and NAME_RE.fullmatch(m)]
            return {"memorized": True, "modules": sorted(set(mods)), "updated_at": data.get("updated_at"),
                    "by": data.get("by") if isinstance(data.get("by"), str) else None}
        except (OSError, ValueError, AttributeError):
            return {"memorized": False, "modules": [], "updated_at": None, "by": None}

    def selection_add(self, names: list[str], by: str) -> dict:
        cur = self.selection()
        # I5 : le socle et le cadriciel obligatoire ne figurent jamais dans la sélection (toujours installés).
        names = [n for n in names if n not in SOCLE and n not in REQUIRED_CADRE]
        mods = sorted(set(cur["modules"]) | set(names))
        doc = {"schema": SCHEMA, "modules": mods, "updated_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"), "by": by}
        d = os.path.dirname(self.selection_path())
        os.makedirs(d, mode=0o700, exist_ok=True)
        fd, tmp = tempfile.mkstemp(prefix=".selection.", dir=d)   # créé en 0600
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(doc, fh, ensure_ascii=False)
            fh.write("\n")
        os.replace(tmp, self.selection_path())
        return self.selection()


# ─────────────────────────────────────────────────────────────────────────────
# Description d'un module (I1)
# ─────────────────────────────────────────────────────────────────────────────
def _int(v, lo, hi):
    return isinstance(v, int) and not isinstance(v, bool) and lo <= v <= hi


def validate(doc: object, name: str) -> list[str]:
    """Raisons de refus d'une description (liste vide = valide)."""
    errs: list[str] = []
    if not isinstance(doc, dict):
        return ["la description n'est pas un objet JSON"]
    for k in doc:
        if k not in TOP_KEYS:
            errs.append(f"clé inconnue : « {k} »")
    if doc.get("schema") != SCHEMA:
        errs.append(f"schema : {SCHEMA} attendu")
    if doc.get("name") != name:
        errs.append(f"name : « {name} » attendu (nom du dossier)")
    lab = doc.get("label")
    if not isinstance(lab, str) or not lab.strip() or len(lab) > 80:
        errs.append("label : texte de 1 à 80 caractères obligatoire")
    if "description" in doc and (not isinstance(doc["description"], str) or len(doc["description"]) > 400):
        errs.append("description : texte de 400 caractères au plus")
    if "category" in doc and doc["category"] not in CATEGORIES:
        errs.append("category : socle, cadriciel ou application")
    if "required" in doc and not isinstance(doc["required"], bool):
        errs.append("required : booléen")
    if "owner" in doc and not (isinstance(doc["owner"], str) and UID_RE.fullmatch(doc["owner"])):
        errs.append("owner : uid du lab")
    if "priority" in doc and not _int(doc["priority"], 0, 999):
        errs.append("priority : entier de 0 à 999")
    prov = doc.get("provides", {})
    if not isinstance(prov, dict) or set(prov) - {"interface"} or (
            "interface" in prov and not (isinstance(prov["interface"], str) and VERSION_RE.fullmatch(prov["interface"]))):
        errs.append("provides : {\"interface\": \"<version>\"}")
    req = doc.get("requires", {})
    if not isinstance(req, dict):
        errs.append("requires : objet")
        req = {}
    for k in req:
        if k not in REQ_KEYS:
            errs.append(f"requires : clé inconnue « {k} »")
    mods = req.get("modules", [])
    if not isinstance(mods, list):
        errs.append("requires.modules : liste")
        mods = []
    for m in mods:
        if not isinstance(m, dict) or set(m) - {"name", "interface"}:
            errs.append("requires.modules : objets {name, interface?}")
            continue
        if not (isinstance(m.get("name"), str) and NAME_RE.fullmatch(m["name"])):
            errs.append("requires.modules : nom de module invalide")
        elif m["name"] == name:
            errs.append("requires.modules : un module ne dépend pas de lui-même")
        if "interface" in m and not (isinstance(m["interface"], str) and VERSION_RE.fullmatch(m["interface"])):
            errs.append(f"requires.modules : version d'interface invalide pour {m.get('name')}")
    sysreq = req.get("system", [])
    if not isinstance(sysreq, list):
        errs.append("requires.system : liste")
        sysreq = []
    for s in sysreq:
        if not isinstance(s, dict) or set(s) - {"command", "min_version", "why"}:
            errs.append("requires.system : objets {command, min_version?, why?}")
            continue
        if not (isinstance(s.get("command"), str) and CMD_RE.fullmatch(s["command"])):
            errs.append("requires.system : commande invalide")
        if "min_version" in s and not (isinstance(s["min_version"], str) and VERSION_RE.fullmatch(s["min_version"])):
            errs.append(f"requires.system : min_version invalide pour {s.get('command')}")
        if "why" in s and (not isinstance(s["why"], str) or len(s["why"]) > 200):
            errs.append("requires.system : why, texte de 200 caractères au plus")
    if "domain" in req and not isinstance(req["domain"], bool):
        errs.append("requires.domain : booléen")
    res = doc.get("resources", {})
    if not isinstance(res, dict) or set(res) - RES_KEYS:
        errs.append("resources : {build_ram_mb, disk_mb, build_minutes, heavy_build}")
        res = {}
    for k, hi in (("build_ram_mb", 64000), ("disk_mb", 1000000), ("build_minutes", 1440)):
        if k in res and not _int(res[k], 0, hi):
            errs.append(f"resources.{k} : entier positif")
    if "heavy_build" in res and not isinstance(res["heavy_build"], bool):
        errs.append("resources.heavy_build : booléen")
    sets = doc.get("settings", [])
    if not isinstance(sets, list):
        errs.append("settings : liste")
        sets = []
    seen: set[str] = set()
    for s in sets:
        if not isinstance(s, dict):
            errs.append("settings : objets")
            continue
        for k in s:
            if k not in SET_KEYS:
                # « value », « default »… : jamais de valeur dans une description.
                errs.append(f"settings : clé « {k} » interdite (aucune valeur dans une description)")
        key = s.get("key")
        if not (isinstance(key, str) and KEY_RE.fullmatch(key)):
            errs.append("settings : key au format ^[A-Z][A-Z0-9_]{0,63}$")
            continue
        if is_managed(key):
            errs.append(f"settings : {key} est une clé gérée par le cadriciel")
        if key in seen:
            errs.append(f"settings : {key} en double")
        seen.add(key)
        q = s.get("question")
        if not isinstance(q, str) or not q.strip() or len(q) > 300:
            errs.append(f"settings : question de 1 à 300 caractères pour {key}")
        for b in ("required", "secret"):
            if b in s and not isinstance(s[b], bool):
                errs.append(f"settings : {b} booléen pour {key}")
    groups = doc.get("groups", [])
    if not isinstance(groups, list) or not all(isinstance(g, str) and GROUP_RE.fullmatch(g) for g in groups):
        errs.append("groups : liste de noms de groupe")
    inst = doc.get("install")
    if inst is not None:
        if not isinstance(inst, dict) or set(inst) - INST_KEYS:
            errs.append("install : null ou {script, windows, timeout_s?}")
        else:
            if inst.get("script") != "install.sh":
                errs.append("install.script : « install.sh » (à la racine du module)")
            if inst.get("windows") != "install.bat":
                errs.append("install.windows : « install.bat » (à la racine du module)")
            if "timeout_s" in inst and not _int(inst["timeout_s"], 10, 3600):
                errs.append("install.timeout_s : 10 à 3600")
    return errs


def deduce(lab: Lab, name: str, path: str | None) -> dict:
    """Description d'un module qui n'en porte aucune (I1, « description déduite »)."""
    label, desc = lab.showcase().get(name, (name, ""))
    groups: list[str] = []
    if path:
        try:
            with open(os.path.join(path, ".keycloak-client-opts"), encoding="utf-8") as fh:
                m = re.search(r"--require-group\s+(\S+)", fh.read())
            if m:
                groups = [g for g in m.group(1).split(",") if GROUP_RE.fullmatch(g)]
        except OSError:
            pass
    in_dep = bool(path) and os.path.dirname(path) == os.path.join(lab.root, "deploiement")
    category = "socle" if name in SOCLE else ("application" if in_dep else "cadriciel")
    return {"schema": SCHEMA, "name": name, "label": label or name, "description": desc,
            "category": category, "required": name in SOCLE or name in REQUIRED_CADRE,
            "requires": {"modules": [], "system": [], "domain": False}, "settings": [],
            "groups": groups, "install": None}


def load(lab: Lab, name: str) -> dict:
    """Item d'I2 pour un module (description résolue + état)."""
    path = lab.dir_of(name)
    exists = os.path.isdir(path)
    rel = os.path.relpath(path, lab.root) if exists else None
    source, doc, errors = "deduced", None, []
    for src, f in (("module", os.path.join(path, "lab-module.json") if exists else None),
                   ("catalogue", os.path.join(lab.root, "modules", name + ".json"))):
        if f and os.path.lexists(f):
            source = src
            try:
                if os.path.islink(f) or os.path.getsize(f) > MAX_BYTES:
                    raise ValueError("fichier lien symbolique ou trop gros (64 Kio au plus)")
                with open(f, encoding="utf-8") as fh:
                    doc = json.load(fh)
                errors = validate(doc, name)
            except (OSError, ValueError) as exc:
                errors = [f"{os.path.relpath(f, lab.root)} illisible : {exc}"[:300]]
                doc = None
            break
    base = deduce(lab, name, path if exists else None)
    if doc is None or errors:
        if doc is None and not errors:
            doc = base
        else:
            doc = {**base, **({k: v for k, v in doc.items() if k in ("label", "description", "category")
                               and isinstance(v, str)} if isinstance(doc, dict) else {})}
    valid = not errors
    prio_conf = lab.priorities().get(name)
    req = doc.get("requires") or {}
    res = doc.get("resources") or {}
    heavy = bool(res.get("heavy_build")) or (exists and os.path.exists(os.path.join(path, ".heavy-build")))
    resources = {"build_ram_mb": res.get("build_ram_mb", prio_conf[1] if prio_conf else 1500),
                 "disk_mb": res.get("disk_mb"), "build_minutes": res.get("build_minutes"), "heavy_build": heavy}
    category = doc.get("category") or base["category"]
    required = name in SOCLE or name in REQUIRED_CADRE   # D3 : la liste fait foi, pas la description
    env = read_env(os.path.join(path, ".env")) if exists else {}
    settings = [{"key": s["key"], "question": s.get("question", ""), "required": bool(s.get("required")),
                 "secret": bool(s.get("secret")), "set": not placeholder(env.get(s["key"], ""))}
                for s in (doc.get("settings") or []) if isinstance(s, dict) and "key" in s]

    # État
    compose = exists and os.path.isfile(os.path.join(path, "docker-compose.yml"))
    states = lab.ps().get(name, [])
    running = sum(1 for s in states if s == "running")
    if not valid:
        state = "invalid"
    elif not exists:
        state = "absent"
    elif not compose:
        state = "inaccessible" if not os.listdir(path) else "absent"
    elif running:
        state = "installed"
    elif states:
        state = "stopped"
    else:
        state = "not_installed"
    if state == "absent" and rel in lab.submodules():
        state = "inaccessible"
    owner_decl = doc.get("owner")
    warnings = []
    if owner_decl and owner_decl != lab.owner(name):
        warnings.append(f"owner déclaré « {owner_decl} » ≠ .owners (« {lab.owner(name)} ») : .owners fait foi")
    inst = doc.get("install") if valid else None
    item = {
        "name": name, "label": doc.get("label") or name, "description": doc.get("description") or "",
        "category": category, "required": required, "owner": lab.owner(name), "path": rel,
        "source": source, "valid": valid, "errors": errors, "state": state,
        "containers": {"running": running, "total": len(states)},
        "no_autodeploy": exists and os.path.exists(os.path.join(path, ".no-autodeploy")),
        "selected": False,
        "priority": doc.get("priority", prio_conf[0] if prio_conf else (0 if name in SOCLE else 50)),
        "provides": {"interface": (doc.get("provides") or {}).get("interface")},
        "requires": {"modules": [{"name": m["name"], "interface": m.get("interface")}
                                 for m in (req.get("modules") or []) if isinstance(m, dict) and "name" in m],
                     "system": [dict(s) for s in (req.get("system") or []) if isinstance(s, dict)],
                     "domain": bool(req.get("domain")) or name == ENGINE},
        "resources": resources, "settings": settings, "groups": list(doc.get("groups") or []),
        "install": ({"script": inst["script"], "windows": inst["windows"], "timeout_s": inst.get("timeout_s", 900)}
                    if isinstance(inst, dict) else None),
        "deployed": lab.deployed(name),
    }
    if warnings:
        item["warnings"] = warnings
    return item


def catalogue(lab: Lab) -> dict[str, dict]:
    sel = lab.selection()
    items = {n: load(lab, n) for n in lab.unit_names()}
    for it in items.values():
        it["selected"] = it["required"] or it["name"] in sel["modules"]
    return items


def sorted_items(items: dict[str, dict]) -> list[dict]:
    return sorted(items.values(), key=lambda i: (CAT_ORDER.get(i["category"], 9), i["name"]))


# ─────────────────────────────────────────────────────────────────────────────
# Vérifications (show --check)
# ─────────────────────────────────────────────────────────────────────────────
def _vtuple(v: str) -> tuple[int, ...]:
    return tuple(int(x) for x in v.split("."))


def check_system(req: dict) -> dict:
    cmd = req.get("command", "")
    what = f"system:{cmd}"
    path = shutil.which(cmd)
    if not path:
        return {"what": what, "ok": False, "detail": f"commande « {cmd} » absente" + (f" — {req['why']}" if req.get("why") else "")}
    want = req.get("min_version")
    if not want:
        return {"what": what, "ok": True, "detail": f"{cmd} présent ({path})"}
    try:
        proc = subprocess.run([path, "--version"], capture_output=True, text=True, timeout=10)
        m = re.search(r"\d+(?:\.\d+)+", (proc.stdout or "") + (proc.stderr or ""))
    except (OSError, subprocess.SubprocessError):
        m = None
    if not m:
        return {"what": what, "ok": None, "detail": f"{cmd} présent, version illisible (≥ {want} attendue)"}
    have = m.group(0)
    h, w = _vtuple(have), _vtuple(want)
    n = max(len(h), len(w))
    ok = h + (0,) * (n - len(h)) >= w + (0,) * (n - len(w))
    return {"what": what, "ok": ok, "detail": f"{cmd} {have} (≥ {want} attendue)"}


def has_domain(lab: Lab) -> bool:
    return not placeholder(lab.env.get("DOMAIN", ""))


def checks(lab: Lab, items: dict[str, dict], name: str, groups_file: str | None) -> list[dict]:
    it = items[name]
    res: list[dict] = []
    for s in it["requires"]["system"]:
        res.append(check_system(s))
    if it["requires"]["domain"]:
        res.append({"what": "domain", "ok": has_domain(lab),
                    "detail": "DOMAIN renseigné (HTTPS)" if has_domain(lab) else "exige DOMAIN (HTTPS) dans le .env racine"})
    miss = [s["key"] for s in it["settings"] if not s["set"]]
    req_miss = [s["key"] for s in it["settings"] if s["required"] and not s["set"]]
    if it["settings"]:
        res.append({"what": "settings", "ok": not req_miss,
                    "detail": ("tous les réglages sont posés" if not miss else
                               f"non réglés : {', '.join(miss)}" + (f" (requis : {', '.join(req_miss)})" if req_miss else ""))})
    deps_bad = []
    for d in it["requires"]["modules"]:
        dep = items.get(d["name"])
        if dep is None:
            deps_bad.append(f"{d['name']} inconnu")
        elif dep["state"] not in ("installed",):
            deps_bad.append(f"{d['name']} : {dep['state']}")
        elif d.get("interface") and dep["provides"]["interface"] and \
                d["interface"].split(".")[0] != dep["provides"]["interface"].split(".")[0]:
            deps_bad.append(f"{d['name']} sert l'interface {dep['provides']['interface']}, {d['interface']} attendue")
    if it["requires"]["modules"]:
        res.append({"what": "dependencies", "ok": not deps_bad,
                    "detail": "dépendances en service" if not deps_bad else "; ".join(deps_bad)})
    if it["groups"]:
        if groups_file is None:
            res.append({"what": "groups", "ok": None, "detail": "groupes non vérifiés (Keycloak injoignable d'ici)"})
        else:
            try:
                with open(groups_file, encoding="utf-8") as fh:
                    known = {ln.strip() for ln in fh if ln.strip()}
            except OSError:
                known = set()
            missing = [g for g in it["groups"] if g not in known]
            res.append({"what": "groups", "ok": not missing,
                        "detail": "groupes présents dans le realm" if not missing else
                        f"groupes absents du realm (à créer dans l'annuaire LDAP) : {', '.join(missing)}"})
    return res


# ─────────────────────────────────────────────────────────────────────────────
# Plan (I2, « plan --json »)
# ─────────────────────────────────────────────────────────────────────────────
def plan(lab: Lab, items: dict[str, dict], requested: list[str], reinstall: bool, with_deps: bool,
         for_engine: bool) -> dict:
    blocked: dict[str, dict] = {}
    warnings: list[str] = []
    reasons: dict[str, str] = {}

    def block(mod: str, cause: str, reason: str) -> None:
        blocked.setdefault(mod, {"module": mod, "cause": cause, "reason": reason})

    # 1. Fermeture transitive, détection de cycle (DFS colorié).
    order: list[str] = []
    color: dict[str, int] = {}

    def visit(n: str, stack: list[str]) -> None:
        if color.get(n) == 2:
            return
        if color.get(n) == 1:
            cyc = stack[stack.index(n):] + [n]
            for m in cyc[:-1]:
                block(m, "cycle", "dépendances circulaires : " + " → ".join(cyc))
            return
        color[n] = 1
        it = items.get(n)
        if it is not None:
            for d in it["requires"]["modules"]:
                dn = d["name"]
                if dn in SOCLE:
                    continue
                reasons.setdefault(dn, f"dépendance de {n}")
                if dn not in items:
                    block(dn, "unknown", f"module « {dn} » inconnu du lab (ni dossier, ni catalogue)")
                    color[dn] = 2
                    continue
                visit(dn, stack + [n])
        color[n] = 2
        order.append(n)

    for r in requested:
        reasons.setdefault(r, "demandé")
        if r not in items:
            block(r, "unknown", f"module « {r} » inconnu du lab (ni dossier, ni catalogue)")
            continue
        visit(r, [])

    # 2. Blocages propres à chaque module de la fermeture.
    domain = has_domain(lab)
    for n in order:
        it = items[n]
        installed = it["state"] == "installed"
        if it["category"] == "socle":
            if n in requested:
                block(n, "socle", f"{n} fait partie du socle : il s'installe par scripts/install.sh, jamais ici")
            continue
        if not it["valid"]:
            block(n, "invalid", f"description de {n} invalide : " + "; ".join(it["errors"][:3]))
            continue
        if it["state"] == "inaccessible":
            block(n, "inaccessible", f"{n} : sous-module non extrait (dépôt privé ou inaccessible ?)")
            continue
        if it["state"] == "absent":
            block(n, "absent", f"{n} : décrit au catalogue, mais aucun dossier sur ce lab")
            continue
        wants_action = (n in requested and (reinstall or not installed)) or \
                       (n not in requested and (not installed or (reinstall and with_deps)))
        if for_engine and n == ENGINE and wants_action:
            block(n, "engine_self", "le moteur ne se réinstalle pas lui-même : bash scripts/setup2.sh lab-mcp --yes (sur l'hôte)")
            continue
        if wants_action and it["no_autodeploy"]:
            block(n, "no_autodeploy", f"{n} est marqué .no-autodeploy : à installer à la main (bash scripts/setup2.sh {n} --yes)")
            continue
        if wants_action and it["requires"]["domain"] and not domain:
            block(n, "domain", f"{n} exige DOMAIN (HTTPS) : relancer install.sh avec --domain <fqdn>")
            continue
        if wants_action:
            bad = [c for c in (check_system(s) for s in it["requires"]["system"]) if c["ok"] is False]
            if bad:
                block(n, "system", f"{n} : " + "; ".join(c["detail"] for c in bad))
                continue
        for d in it["requires"]["modules"]:
            dep = items.get(d["name"])
            if dep and d.get("interface") and dep["provides"]["interface"] and \
                    d["interface"].split(".")[0] != dep["provides"]["interface"].split(".")[0]:
                block(n, "interface", f"{n} attend l'interface {d['interface']} de {d['name']}, "
                                      f"qui sert {dep['provides']['interface']}")
            elif dep and d.get("interface") and not dep["provides"]["interface"]:
                warnings.append(f"{n} attend l'interface {d['interface']} de {d['name']}, qui n'en déclare aucune")

    # 3. Propagation : un module bloqué bloque ceux qui en dépendent.
    changed = True
    while changed:
        changed = False
        for n in order:
            if n in blocked or n not in items:
                continue
            for d in items[n]["requires"]["modules"]:
                if d["name"] in blocked:
                    block(n, "dependency", f"{n} dépend de {d['name']}, qui ne peut pas être installé")
                    changed = True
                    break

    # 4. Ordre topologique (Kahn) départagé par priorité puis nom.
    # Seulement ce que demandent les modules demandés NON bloqués : une dépendance d'un module
    # refusé n'a rien à faire dans le plan.
    needed: set[str] = set()
    todo = [r for r in requested if r in items and r not in blocked]
    while todo:
        n = todo.pop()
        if n in needed:
            continue
        needed.add(n)
        todo.extend(d["name"] for d in items[n]["requires"]["modules"] if d["name"] in items)
    closure = [n for n in order if n in needed and items[n]["category"] != "socle"]
    pending = set(closure)
    deps_of = {n: {d["name"] for d in items[n]["requires"]["modules"] if d["name"] in pending} for n in closure}
    steps_order: list[str] = []
    while pending:
        ready = sorted((n for n in pending if not (deps_of[n] & pending)),
                       key=lambda n: (items[n]["priority"], n))
        if not ready:      # cycle : déjà bloqué, on vide dans l'ordre stable
            ready = sorted(pending, key=lambda n: (items[n]["priority"], n))
        n = ready[0]
        steps_order.append(n)
        pending.discard(n)

    steps = []
    for n in steps_order:
        if n in blocked:
            continue
        it = items[n]
        installed = it["state"] == "installed"
        if n in requested:
            action = "reinstall" if (installed and reinstall) else ("keep" if installed else "install")
        else:
            action = "reinstall" if (installed and reinstall and with_deps) else ("keep" if installed else "install")
        steps.append({"module": n, "action": action, "reason": reasons.get(n, ""),
                      "hook": it["install"] is not None, "resources": it["resources"],
                      "settings": it["settings"] if action != "keep" else []})
    missing = []
    for st in steps:
        for s in st["settings"]:
            if not s["set"]:
                missing.append({"module": st["module"], "key": s["key"], "question": s["question"],
                                "required": s["required"], "secret": s["secret"]})
    missing.sort(key=lambda m: (not m["required"], m["module"], m["key"]))
    ok = not any(r in blocked for r in requested) and bool(requested)
    return {"ok": ok, "requested": requested, "reinstall": reinstall, "with_deps": with_deps,
            "steps": steps, "blocked": [blocked[k] for k in blocked], "settings_missing": missing,
            "warnings": warnings}


# ─────────────────────────────────────────────────────────────────────────────
def names_arg(raw: str) -> list[str]:
    names = [n.strip() for n in raw.split(",") if n.strip()]
    if not names or len(names) > 50 or not all(NAME_RE.fullmatch(n) for n in names):
        usage("liste de modules invalide")
    seen: list[str] = []
    for n in names:
        if n not in seen:
            seen.append(n)
    return seen


def main(argv: list[str]) -> None:
    if len(argv) < 2:
        usage("usage : modules.py <racine> <commande> …")
    lab = Lab(argv[0])
    cmd, rest = argv[1], argv[2:]
    flags = {a for a in rest if a.startswith("--")}
    if cmd == "list":
        items = catalogue(lab)
        out({"schema": SCHEMA, "selection": lab.selection(), "modules": sorted_items(items)})
    if cmd == "show":
        pos = [a for a in rest if not a.startswith("--")]
        opt: dict[str, str | None] = {"--groups-file": None, "--hook-file": None}
        for o in opt:
            if o in rest:
                i = rest.index(o)
                opt[o] = rest[i + 1] if i + 1 < len(rest) else usage(f"{o} <fichier>")
                pos = [a for a in pos if a != opt[o]]
        groups_file = opt["--groups-file"]
        if len(pos) != 1 or not NAME_RE.fullmatch(pos[0]):
            usage("show <nom>")
        items = catalogue(lab)
        if pos[0] not in items:
            out({"error": "not_found", "detail": f"module « {pos[0]} » inconnu du lab"}, 1)
        item = items[pos[0]]
        if "--check" in flags:
            item["checks"] = checks(lab, items, pos[0], groups_file)
            if opt["--hook-file"]:
                # Rendu de `module-hook.sh --check` : 1re ligne = code (ou « skip <raison> »), puis la sortie.
                try:
                    with open(opt["--hook-file"], encoding="utf-8", errors="replace") as fh:
                        lines = fh.read().splitlines()
                except OSError:
                    lines = []
                head = lines[0] if lines else "skip rendu absent"
                if head.startswith("skip"):
                    item["checks"].append({"what": "hook", "ok": None, "detail": head[5:] or "non joué", "output": []})
                else:
                    rc = int(head) if head.isdigit() else 1
                    item["checks"].append({"what": "hook", "ok": rc == 0,
                                           "detail": "install.sh --check : rien ne manque" if rc == 0 else
                                           f"install.sh --check a rendu {rc} : quelque chose manque", "output": lines[1:201]})
            item["ok"] = item["valid"] and all(c["ok"] is not False for c in item["checks"])
        out(item)
    if cmd == "plan":
        pos = [a for a in rest if not a.startswith("--")]
        if len(pos) != 1 or flags - {"--reinstall", "--with-deps", "--for-engine", "--json"}:
            usage("plan [--reinstall] [--with-deps] [--for-engine] <nom>[,…]")
        items = catalogue(lab)
        p = plan(lab, items, names_arg(pos[0]), "--reinstall" in flags, "--with-deps" in flags, "--for-engine" in flags)
        out(p, 0 if p["ok"] else 1)
    if cmd == "selection":
        out(lab.selection())
    if cmd == "selection-add":
        pos, by = [], lab.superuser
        it = iter(rest)
        for a in it:
            if a == "--by":
                by = next(it, "")
            else:
                pos.append(a)
        if len(pos) != 1 or not UID_RE.fullmatch(by or ""):
            usage("selection-add <nom>[,…] [--by <uid>]")
        out(lab.selection_add(names_arg(pos[0]), by))
    if cmd in ("declared-settings", "hook"):
        if len(rest) != 1 or not NAME_RE.fullmatch(rest[0]):
            usage(f"{cmd} <nom>")
        item = load(lab, rest[0])
        if cmd == "declared-settings":
            sys.stdout.write("".join(s["key"] + "\n" for s in item["settings"]))
        elif item["install"]:
            sys.stdout.write(f"{item['install']['script']} {item['install']['timeout_s']}\n")
        sys.exit(0 if item["valid"] else 1)
    usage(f"commande inconnue : {cmd}")


if __name__ == "__main__":
    main(sys.argv[1:])
