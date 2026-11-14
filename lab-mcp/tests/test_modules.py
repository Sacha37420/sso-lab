"""Modules du lab (chantier « modules », contrat v1, I4) — essais du moteur.

Aucun Docker, aucun réseau, aucune pièce du lab : le moteur livré (labmcp/, monté depuis le dossier de
travail) contre une racine FACTICE créée dans /tmp. Lancement : `bash lab-mcp/tests/modules/run.sh`
(conteneur jetable de l'image du moteur, `--network none`, sans socket Docker).

Ce qui est réel :
  • labmcp/ en entier : la route web, l'authentification (seule la clé de vérification est une clé de
    test, comme harness.py), la file de jobs, `labmcp.chain` lancé par le VRAI `scripts/lab-lock.sh` ;
  • une COPIE de tout `scripts/` du dépôt : `lab-modules.sh` + `lib/modules.py` (I2), `app-env.sh`,
    `lib/fresh-env.sh`, `lab-lock.sh`… sont les vrais.
Ce qui est remplacé (tests/modules/scripts/) : `app-sync.sh`, `validate-app.sh`, `setup2.sh`,
`storage-shares.sh`, `app-status.sh` (doubles qui notent leurs appels dans .trace/calls.log) ;
`lab-modules.sh` est un enregistreur qui note l'appel puis exécute le vrai. L'état des conteneurs vient
d'un fichier (LAB_MODULES_PS), que le double de `setup2.sh` complète quand il « démarre » une app.

    python /tests/test_modules.py               tous les essais
    python /tests/test_modules.py --trace F     des DÉPLOIEMENTS seuls, tracés dans F (run.sh les joue avec
                                                le code d'avant et le code courant, et compare)
"""
import asyncio
import fcntl
import glob
import http.server
import json
import logging
import os
import re
import shutil
import subprocess
import sys
import threading
import time
import unittest

import httpx
import uvicorn
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import rsa

TRACE_OUT = sys.argv[sys.argv.index("--trace") + 1] if "--trace" in sys.argv else ""
REAL_SCRIPTS = "/lab-scripts"      # scripts/ du dépôt, en lecture seule
DOMAIN = "lab.test"
BASE = "http://127.0.0.1:8000"
SU = "zzroot"
SECRET = "VALEUR-SECRETE-9c2e71b4"          # valeur d'un réglage : ne doit sortir nulle part
SECRET2 = "AUTRE-VALEUR-SECRETE-5d03aa"

# ── racine factice ───────────────────────────────────────────────────────────
ROOT = "/tmp/zz-modules-root"
shutil.rmtree(ROOT, ignore_errors=True)
shutil.copytree(REAL_SCRIPTS, os.path.join(ROOT, "scripts"), ignore=shutil.ignore_patterns("tests"))
shutil.copy(os.path.join(ROOT, "scripts", "lab-modules.sh"), os.path.join(ROOT, "scripts", "lab-modules.real.sh"))
for name in os.listdir("/tests/modules/scripts"):                            # doubles + enregistreur
    shutil.copy(os.path.join("/tests/modules/scripts", name), os.path.join(ROOT, "scripts", name))
TRACE = os.path.join(ROOT, ".trace")
STATE = os.path.join(ROOT, ".lab-state")
for d in (TRACE, STATE, os.path.join(ROOT, "deploiement")):
    os.makedirs(d)


def write(rel, text):
    path = os.path.join(ROOT, rel)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(text)


def unit(rel, desc=None, env="SECRET_KEY=x\n", example=None):
    write(f"{rel}/docker-compose.yml", "services: {}\n")
    if env is not None:
        write(f"{rel}/.env", env)
    if example is not None:
        write(f"{rel}/.env.example", example)
    if desc is not None:
        write(f"{rel}/lab-module.json", json.dumps({"schema": 1, "name": os.path.basename(rel),
                                                    "label": os.path.basename(rel), **desc}))


write(".env", f"LAB_SUPERUSER={SU}\nDOMAIN={DOMAIN}\n")
write(".devs", f"devtest\n{SU}\n")
write(".owners", "mdev:devtest\nbeta:zzroot\n")
write(".ports", "zeta:9001:9002\nbeta:9003:9004\nmdev:9005:9006\ngamma:9007:9008\neta:9009:9010\n")
for u in ("sso-lab", "infra", "runner", "storage", "oauth-hub", "lab-admin", "lab-mcp"):
    unit(u)
dep = lambda *names: {"requires": {"modules": [{"name": n} for n in names]}}   # noqa: E731
unit("deploiement/alpha", dep("storage"))
unit("deploiement/beta", {**dep("alpha"), "settings": [
    {"key": "BETA_KEY", "question": "Clé de beta ?", "required": True, "secret": True},
    {"key": "BETA_OPT", "question": "Option de beta ?", "required": False, "secret": True}]},
    env="SECRET_KEY=x\nBETA_OPT=\n")
unit("deploiement/gamma", dep(), env=None, example="SECRET_KEY=CHANGE_ME\nGAMMA_MODE=simple\n")
unit("deploiement/delta", dep("gamma"))
unit("deploiement/epsilon", dep())
unit("deploiement/zeta", dep())
write("deploiement/zeta/frontend/e2e/cloisonnement.spec.ts", "// spec\n")
unit("deploiement/eta", dep())
unit("deploiement/mdev", dep())
PS = os.path.join(ROOT, ".ps")
write(".ps", "".join(f"{u}\trunning\n" for u in ("sso-lab", "infra", "runner", "oauth-hub", "lab-admin",
                                                    "lab-mcp", "zeta")))
CALLS = os.path.join(TRACE, "calls.log")
open(CALLS, "w").close()
os.environ.update(LAB_ROOT=ROOT, DOMAIN=DOMAIN, LAB_SUPERUSER=SU, LAB_STATE_DIR=STATE,
                  LAB_WORK_DIR=os.path.join(ROOT, "work"), LAB_MODULES_PS=PS,
                  LAB_RUNNER_URL="http://127.0.0.1:9201", OAUTH_HUB_INTERNAL_URL="http://127.0.0.1:9101",
                  GITHUB_API_URL="http://127.0.0.1:9102", LAB_MCP_JOB_LOCK_TIMEOUT="3")

sys.path.insert(0, "/tests")
from labmcp import auth, config  # noqa: E402
from labmcp.server import build  # noqa: E402

client = type(sys)("client")
exec(compile(open("/tests/client.py").read().replace("sys.exit(main())", ""), "/tests/client.py", "exec"),
     client.__dict__)

_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
with open("/tmp/test-issuer-key.pem", "wb") as fh:
    fh.write(_key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                                serialization.NoEncryption()))


class _TestKeys:
    class _K:
        key = _key.public_key()

    def get_signing_key_from_jwt(self, _token):
        return self._K


_orig_init = auth.Authenticator.__init__


def _patched_init(self, *args, **kwargs):
    _orig_init(self, *args, **kwargs)
    self._jwks = _TestKeys()


auth.Authenticator.__init__ = _patched_init

LOGGED: list[str] = []          # tout ce que le moteur écrit dans ses journaux (audit compris)


class _Keep(logging.Handler):
    def emit(self, record):
        LOGGED.append(self.format(record) + (" " + record.exc_text if record.exc_text else ""))


logging.getLogger().addHandler(_Keep())
logging.getLogger().setLevel(logging.INFO)
logging.getLogger("httpx").setLevel(logging.WARNING)

# ── faux lab-runner : répond [] (aucun test) ; retient sa réponse tant que RUNNER_GATE est fermé ──
RUNNER_GATE = threading.Event()
RUNNER_GATE.set()
RUNNER_HIT = threading.Event()


class _Runner(http.server.BaseHTTPRequestHandler):
    def do_POST(self):  # noqa: N802
        self.rfile.read(int(self.headers.get("Content-Length") or 0))
        RUNNER_HIT.set()
        RUNNER_GATE.wait(60)
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(b"[]")

    def log_message(self, *_a):
        pass


threading.Thread(target=http.server.ThreadingHTTPServer(("127.0.0.1", 9201), _Runner).serve_forever,
                 daemon=True).start()

APP = build(config.load())
_server = uvicorn.Server(uvicorn.Config(APP, host="127.0.0.1", port=8000, log_level="warning", access_log=False))
threading.Thread(target=_server.run, daemon=True).start()
for _ in range(100):
    try:
        if httpx.get(BASE + "/mcp/healthz", timeout=2).status_code == 200:
            break
    except httpx.HTTPError:
        time.sleep(0.1)
else:
    sys.exit("le serveur d'essai ne répond pas")

RESPONSES: list[str] = []       # toutes les réponses du moteur reçues par les essais


# ── outils ───────────────────────────────────────────────────────────────────
def web(method, path, body=None, *, uid=SU, raw=None, token=None, **claims):
    token = token or client.mint(uid, DOMAIN, "lab-admin", **claims)
    content = raw if raw is not None else (None if body is None else json.dumps(body).encode("utf-8"))
    r = httpx.request(method, BASE + "/mcp/api" + path, content=content, timeout=120,
                      headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"})
    RESPONSES.append(r.text)
    return r.status_code, r.json()


def wait_job(job_id, timeout=120):
    end = time.time() + timeout
    while time.time() < end:
        status, job = web("GET", f"/jobs/{job_id}?tail=1000")
        assert status == 200, job
        if job["terminal"]:
            return job
        time.sleep(0.1)
    raise AssertionError("job jamais terminé")


def wait_running(job_id):
    for _ in range(300):
        _, job = web("GET", f"/jobs/{job_id}?tail=0")
        if job["state"] == "running":
            return job
        time.sleep(0.05)
    raise AssertionError("job jamais démarré")


def read(path):
    with open(path, encoding="utf-8", newline="") as fh:
        return fh.read()


def steps_of(job):
    return [m.group(1) for line in job["log"] for m in [re.search(r"\[lab-mcp\] étape « ([a-z0-9_]+) »", line)] if m]


def calls_since(mark):
    return read(CALLS)[mark:].splitlines()


def mark():
    return len(read(CALLS))


def flag(name, on=True):
    path = os.path.join(TRACE, name)
    if on:
        open(path, "w").close()
    elif os.path.exists(path):
        os.unlink(path)


def script_env():
    """Environnement de lab-modules.sh tel que le moteur le lui donne (procs.base_env)."""
    return {"PATH": "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin", "HOME": "/tmp",
            "LANG": "C.UTF-8", "LAB_SUPERUSER": SU, "LAB_STATE_DIR": STATE, "LAB_MODULES_PS": PS,
            "LAB_WORK_DIR": os.path.join(ROOT, "work")}


def direct(*args):
    """Ce que rend le VRAI lab-modules.sh, lancé directement (sans l'enregistreur)."""
    out = subprocess.run(["bash", os.path.join(ROOT, "scripts", "lab-modules.real.sh"), *args],
                         capture_output=True, text=True, env=script_env(), cwd=ROOT).stdout
    return json.loads(out.strip().splitlines()[-1])


def install(body, **kw):
    return web("POST", "/modules/install", body, **kw)


class Sampler:
    """Relève les arguments de TOUS les processus du conteneur, toutes les 10 ms."""

    def __init__(self):
        self.seen: set[str] = set()
        self._stop = threading.Event()
        self._thread = threading.Thread(target=self._run, daemon=True)

    def _run(self):
        while not self._stop.is_set():
            for path in glob.glob("/proc/[0-9]*/cmdline"):
                try:
                    with open(path, "rb") as fh:
                        self.seen.add(fh.read().replace(b"\0", b" ").decode("utf-8", "replace").strip())
                except OSError:
                    pass
            time.sleep(0.01)

    def __enter__(self):
        self._thread.start()
        return self

    def __exit__(self, *exc):
        self._stop.set()
        self._thread.join()


# ═════════════════════════════════════════════════════════════════════════════
# --trace : des déploiements seuls, pour la comparaison avec le moteur d'avant (run.sh compare)
# ═════════════════════════════════════════════════════════════════════════════
def deploy_trace(app):
    before = mark()
    with Sampler() as sampler:
        status, started = web("POST", f"/projects/{app}/deploy", {})
        assert status == 200, started
        job = wait_job(started["job_id"])
    return {"app": app, "reponse": {k: v for k, v in started.items() if k != "job_id"},
            "etat": job["state"], "etape": job["step"], "etapes": steps_of(job), "journal": job["log"],
            "resultat": job["result"], "scripts": calls_since(before),
            "chaine": sorted(c for c in sampler.seen if "labmcp.chain" in c and c.startswith("/"))}


def trace_all():
    flag("fail-validate-mdev")
    flag("fail-sync-gamma")
    flag("fail-tests-eta")
    out = [deploy_trace(a) for a in ("zeta", "beta", "mdev", "gamma", "eta")]
    flag("fail-build-zeta")
    out.append(deploy_trace("zeta"))
    for f in ("fail-validate-mdev", "fail-sync-gamma", "fail-tests-eta", "fail-build-zeta"):
        flag(f, False)
    text = json.dumps(out, ensure_ascii=False, indent=1, sort_keys=True)
    return re.sub(r"pid=[0-9]+ depuis [0-9: -]+", "pid=<n> depuis <date>", text)


if TRACE_OUT:
    with open(TRACE_OUT, "w", encoding="utf-8") as fh:
        fh.write(trace_all() + "\n")
    print(f"trace écrite : {TRACE_OUT}")
    sys.exit(0)

ROUTES = [("GET", "/modules", None), ("GET", "/modules/alpha", None), ("GET", "/modules/alpha?check=1", None),
          ("POST", "/modules/plan", {"modules": ["alpha"]}), ("POST", "/modules/install", {"modules": ["alpha"]})]


# ═════════════════════════════════════════════════════════════════════════════
class T1_Lecture(unittest.TestCase):
    """Lecture : formes d'I2 rendues telles quelles."""

    def test_1_liste(self):
        status, data = web("GET", "/modules")
        self.assertEqual(status, 200, data)
        self.assertIsNone(data.pop("job"))
        self.assertEqual(data, direct("list", "--json"))
        names = [m["name"] for m in data["modules"]]
        for n in ("alpha", "beta", "storage", "lab-mcp", "sso-lab"):
            self.assertIn(n, names)
        alpha = next(m for m in data["modules"] if m["name"] == "alpha")
        self.assertEqual(alpha["state"], "not_installed")
        self.assertNotIn("SECRET_KEY=x", json.dumps(data))

    def test_2_detail(self):
        status, data = web("GET", "/modules/beta")
        self.assertEqual(status, 200, data)
        self.assertEqual(data, direct("show", "beta", "--json"))
        self.assertNotIn("checks", data)
        self.assertEqual([s["key"] for s in data["settings"]], ["BETA_KEY", "BETA_OPT"])
        status, data = web("GET", "/modules/beta?check=1")
        self.assertEqual(status, 200, data)
        self.assertIn("checks", data)
        self.assertIn(data["ok"], (True, False))
        self.assertIn("settings", [c["what"] for c in data["checks"]])
        self.assertFalse(next(c for c in data["checks"] if c["what"] == "settings")["ok"])  # BETA_KEY requis, non réglé

    def test_3_detail_inconnu(self):
        for name in ("nope", "A-B", "x" * 70, "_x"):
            with self.subTest(name):
                status, data = web("GET", f"/modules/{name}")
                self.assertEqual((status, data["error"]), (404, "not_found"), data)

    def test_4_plan(self):
        status, data = web("POST", "/modules/plan", {"modules": ["beta"]})
        self.assertEqual(status, 200, data)
        self.assertEqual(data, direct("plan", "--json", "--for-engine", "beta"))
        self.assertEqual([(s["module"], s["action"]) for s in data["steps"]],
                         [("storage", "install"), ("alpha", "install"), ("beta", "install")])
        self.assertEqual(data["settings_missing"][0]["key"], "BETA_KEY")
        status, data = web("POST", "/modules/plan", {"modules": ["zeta"], "reinstall": True, "with_deps": False})
        self.assertEqual(status, 200, data)
        self.assertEqual([(s["module"], s["action"]) for s in data["steps"]], [("zeta", "reinstall")])

    def test_5_plan_non_realisable_rendu_tel_quel(self):
        """Un plan bloqué n'est pas une erreur de la route plan : il est rendu, ok=false."""
        status, data = web("POST", "/modules/plan", {"modules": ["lab-mcp", "nope"], "reinstall": True})
        self.assertEqual(status, 200, data)
        self.assertEqual(data, direct("plan", "--json", "--for-engine", "--reinstall", "lab-mcp,nope"))
        self.assertFalse(data["ok"])
        self.assertEqual({b["module"]: b["cause"] for b in data["blocked"]}, {"lab-mcp": "engine_self", "nope": "unknown"})


class T2_Refus(unittest.TestCase):
    """Superutilisateur seul ; jeton d'espace refusé ; aucun outil MCP ; corps validés."""

    def test_1_dev_non_superutilisateur(self):
        for method, path, body in ROUTES:
            with self.subTest(path):
                status, data = web(method, path, body, uid="devtest")
                self.assertEqual((status, data["error"], data["detail"]), (403, "forbidden", "Réservé au superutilisateur."))

    def test_2_compte_hors_developers(self):
        for method, path, body in ROUTES:
            with self.subTest(path):
                status, data = web(method, path, body, uid="intrus", groups=[])
                self.assertEqual((status, data["error"]), (403, "forbidden"), data)

    def test_3_jeton_d_espace(self):
        # Par l'entrée web : refusé dès l'authentification.
        status, data = web("GET", "/modules", token="labws_" + "a" * 40)
        self.assertEqual((status, data["error"]), (403, "forbidden"), data)
        # Par le moteur (comme si un jeton d'espace atteignait l'opération) : hors WS_OPS.
        from labmcp.auth import Caller
        from labmcp.engine import WS_OPS
        from labmcp.errors import LabError
        engine = APP.engine
        ws = Caller(username=SU, uid=SU, entrance="mcp", in_developers=True, initialized=True, scope_app="zeta")
        for op, kw in (("modules", {}), ("module", {"name": "alpha"}), ("module_plan", {"modules": ["alpha"]}),
                       ("module_install", {"modules": ["alpha"]})):
            with self.subTest(op):
                self.assertNotIn(op, WS_OPS)
                with self.assertRaises(LabError) as ctx:
                    asyncio.run(engine.call(op, ws, **kw))
                self.assertEqual(ctx.exception.code, "forbidden")

    def test_4_aucun_outil_mcp(self):
        status, tools = asyncio.run(client.mcp_call(BASE, client.mint(SU, DOMAIN, "lab-mcp"), None, {}))
        self.assertEqual(status, 200, tools)
        self.assertTrue(tools)
        self.assertFalse([t for t in tools if "module" in t], tools)

    def test_5_corps_refuses(self):
        bad = {
            "sans modules": {},
            "modules pas une liste": {"modules": "alpha"},
            "liste vide": {"modules": []},
            "21 noms": {"modules": [f"m{i}" for i in range(21)]},
            "nom invalide": {"modules": ["Alpha"]},
            "nom avec chemin": {"modules": ["../alpha"]},
            "nom pas une chaîne": {"modules": [12]},
            "reinstall chaîne": {"modules": ["alpha"], "reinstall": "true"},
            "with_deps entier": {"modules": ["alpha"], "with_deps": 1},
            "reinstall null": {"modules": ["alpha"], "reinstall": None},
            "champ inconnu": {"modules": ["alpha"], "force": True},
        }
        for path in ("/modules/plan", "/modules/install"):
            for label, body in bad.items():
                with self.subTest(f"{path} — {label}"):
                    status, data = web("POST", path, body)
                    self.assertEqual((status, data["error"]), (400, "invalid"), data)
        status, data = web("POST", "/modules/plan", raw=b"[1]")
        self.assertEqual((status, data["error"]), (400, "invalid"))
        status, data = web("POST", "/modules/plan", {"modules": ["alpha"], "settings": {}})
        self.assertEqual((status, data["error"]), (400, "invalid"), "settings n'est pas un champ de plan")
        self.assertIsNone(web("GET", "/modules")[1]["job"], "un refus ne lance aucun job")

    def test_6_reglages_refuses(self):
        ok = {"BETA_KEY": SECRET}
        bad = {
            "settings pas un objet": ["x"],
            "module invalide": {"Beta": ok},
            "réglages pas un objet": {"beta": "x"},
            "clé invalide": {"beta": {**ok, "beta_opt": "x"}},
            "valeur pas une chaîne": {"beta": {"BETA_KEY": 12}},
            "valeur avec retour à la ligne": {"beta": {"BETA_KEY": SECRET + "\nX=1"}},
            "valeur avec retour chariot": {"beta": {"BETA_KEY": SECRET + "\r"}},
            "valeur avec octet nul": {"beta": {"BETA_KEY": SECRET + "\x00"}},
            "valeur de 4097 caractères": {"beta": {"BETA_KEY": SECRET + "x" * (4097 - len(SECRET))}},
            "clé non déclarée": {"beta": {**ok, "NOPE": SECRET}},
            "clé gérée": {"beta": {**ok, "DB_PASSWORD": SECRET}},
            "module hors du plan": {"beta": ok, "zeta": {"ZETA_KEY": SECRET}},
        }
        for label, settings in bad.items():
            with self.subTest(label):
                status, data = install({"modules": ["beta"], "settings": settings})
                self.assertEqual((status, data["error"]), (400, "invalid"), data)
                self.assertNotIn(SECRET, json.dumps(data))
        # Un module du plan qui n'est qu'un « keep » ne reçoit pas de réglage.
        status, data = install({"modules": ["beta", "zeta"], "settings": {"beta": ok, "zeta": {"ZETA_KEY": SECRET}}})
        self.assertEqual((status, data["error"]), (400, "invalid"), data)
        self.assertEqual(data["reasons"], ["zeta : ZETA_KEY non déclaré par un module à installer"])
        status, data = install({"modules": ["beta"], "settings": {"beta": {"BETA_KEY": "x" * 4096}}, "reinstall": False})
        self.assertNotEqual(status, 400, "4096 caractères exactement sont admis")  # job lancé : à attendre
        self.assertEqual(status, 200, data)
        wait_job(data["job_id"])
        # On remet beta et ses dépendances dans l'état de départ pour la suite.
        reset_installed()

    def test_7_reglage_requis_manquant(self):
        for settings in (None, {}, {"beta": {}}, {"beta": {"BETA_KEY": ""}}, {"beta": {"BETA_OPT": SECRET}}):
            with self.subTest(settings):
                body = {"modules": ["beta"]} | ({} if settings is None else {"settings": settings})
                status, data = install(body)
                self.assertEqual((status, data["error"]), (400, "invalid"), data)
                self.assertEqual(data["reasons"], ["beta : BETA_KEY requis"])

    def test_8_plan_non_realisable(self):
        status, data = install({"modules": ["alpha", "nope"]})
        self.assertEqual((status, data["error"]), (400, "invalid"), data)
        self.assertEqual(data["reasons"], [direct("plan", "--json", "--for-engine", "alpha,nope")["blocked"][0]["reason"]])
        status, data = install({"modules": ["lab-mcp"], "reinstall": True})                     # engine_self
        self.assertEqual((status, data["error"]), (400, "invalid"), data)
        blocked = direct("plan", "--json", "--for-engine", "--reinstall", "lab-mcp")["blocked"]
        self.assertEqual(blocked[0]["cause"], "engine_self")
        self.assertEqual(data["reasons"], [b["reason"] for b in blocked])
        status, data = install({"modules": ["sso-lab"]})                                          # socle
        self.assertEqual((status, data["error"]), (400, "invalid"), data)
        self.assertIsNone(web("GET", "/modules")[1]["job"])


def reset_installed():
    """Revient à l'état de départ : seuls le socle, une partie du cadriciel et zeta tournent ; beta sans
    BETA_KEY ; sélection vide."""
    write(".ps", "".join(f"{u}\trunning\n" for u in ("sso-lab", "infra", "runner", "oauth-hub", "lab-admin",
                                                        "lab-mcp", "zeta")))
    write("deploiement/beta/.env", "SECRET_KEY=x\nBETA_OPT=\n")
    shutil.rmtree(os.path.join(STATE, "modules"), ignore_errors=True)


class T3_Installation(unittest.TestCase):
    """Le job modules : ordre des scripts, relance, échecs, file, verrou, non-fuite."""

    @classmethod
    def setUpClass(cls):
        reset_installed()

    def test_1_module_et_sa_dependance(self):
        before = mark()
        LOGGED.clear()
        RESPONSES.clear()
        with Sampler() as sampler:
            status, started = install({"modules": ["beta"], "settings": {"beta": {"BETA_KEY": SECRET, "BETA_OPT": ""}}})
            self.assertEqual(status, 200, started)
            self.assertEqual({k: started[k] for k in ("kind", "app", "jobs_ahead")}, {"kind": "modules", "app": "", "jobs_ahead": 0})
            self.assertIn(started["state"], ("queued", "running"))
            self.assertEqual(set(started), {"job_id", "kind", "app", "state", "jobs_ahead", "plan"})
            self.assertEqual([(s["module"], s["action"]) for s in started["plan"]["steps"]],
                             [("storage", "install"), ("alpha", "install"), ("beta", "install")])
            job = wait_job(started["job_id"])
        self.assertEqual(job["state"], "succeeded", job["log"])
        self.assertEqual((job["kind"], job["app"], job["launched_by"]), ("modules", "", SU))
        self.assertEqual(steps_of(job), ["module_storage", "module_alpha", "module_beta"])
        self.assertIn("══ [lab-mcp] étape « module_storage » — install de storage", job["log"])
        sha = lambda a: subprocess.run(["sh", "-c", f"printf %s {a} | sha1sum | cut -c1-40"],  # noqa: E731
                                       capture_output=True, text=True).stdout.strip()
        self.assertEqual(job["result"], {"ok": True, "step": "done", "skipped": [], "results": [
            {"module": m, "action": "install", "ok": True, "step": "done", "sha": sha(m)} for m in ("storage", "alpha", "beta")]})
        per = lambda m, extra=(), gate=(): [  # noqa: E731
            f"lab-modules.sh prepare {m}", *extra, f"app-sync.sh {m}", *gate, f"setup2.sh {m} --yes",
            f"app-status.sh {m}", "lab-modules.sh show storage --json", "storage-shares.sh ",
            f"lab-modules.sh selection add {m} --by {SU}"]
        # Le plan est calculé deux fois : par le serveur (validation, réponse) puis par la chaîne, sous le verrou.
        expected = (["lab-modules.sh plan --json --for-engine beta"] * 2 + ["lab-modules.sh list --json"]
                    + per("storage") + per("alpha")
                    + per("beta", ["lab-modules.sh settings beta"], ["validate-app.sh beta --quality-only"]))
        self.assertEqual([c.rstrip() for c in calls_since(before)], [c.rstrip() for c in expected])
        # Le réglage requis est écrit (par le vrai app-env.sh), l'option vide ne l'est pas ; la sélection est mémorisée.
        self.assertIn(f"BETA_KEY={SECRET}", read(os.path.join(ROOT, "deploiement/beta/.env")))
        self.assertIn("BETA_OPT=\n", read(os.path.join(ROOT, "deploiement/beta/.env")))
        self.assertIn("   BETA_KEY: écrit", job["log"])
        sel = json.loads(read(os.path.join(STATE, "modules", "selection.json")))
        self.assertEqual((sorted(sel["modules"]), sel["by"]), (["alpha", "beta"], SU))
        # Le module installé est en service ; le moteur le voit.
        status, data = web("GET", "/modules")
        self.assertEqual({m["name"]: m["state"] for m in data["modules"] if m["name"] in ("alpha", "beta", "storage")},
                         {"alpha": "installed", "beta": "installed", "storage": "installed"})
        self.assertIsNone(data["job"])
        # ── non-fuite de la valeur : journal du job, résultat, réponses, journaux du moteur (audit compris),
        #    arguments de tout processus, environnement de setup2.sh ; fichier de réglages supprimé.
        self.assertNotIn(SECRET, json.dumps(job, ensure_ascii=False))
        self.assertNotIn(SECRET, "\n".join(RESPONSES))
        self.assertTrue(any('"audit": true' in ln and "module_install" in ln for ln in LOGGED), LOGGED[-5:])
        self.assertNotIn(SECRET, "\n".join(LOGGED))
        self.assertFalse([c for c in sampler.seen if SECRET in c])
        self.assertTrue([c for c in sampler.seen if "labmcp.chain modules zzroot 0 0 beta" in c], sampler.seen)
        env = read(os.path.join(TRACE, "env-setup2-beta"))
        self.assertNotIn(SECRET, env)
        self.assertNotIn("LAB_MCP_SETTINGS_FILE", env)
        self.assertEqual(glob.glob("/tmp/lab-mcp-settings-*"), [])

    def test_2_relance(self):
        # Rien à faire : alpha et storage en service ⇒ deux « keep », aucun script de déploiement.
        before = mark()
        status, started = install({"modules": ["alpha"]})
        self.assertEqual(status, 200, started)
        job = wait_job(started["job_id"])
        self.assertEqual(job["state"], "succeeded", job["log"])
        self.assertEqual(job["result"], {"ok": True, "step": "done", "results": [], "skipped": []})
        self.assertEqual(steps_of(job), ["module_storage", "module_alpha"])
        self.assertIn("══ [lab-mcp] étape « module_alpha » — keep de alpha", job["log"])
        self.assertEqual(calls_since(before), ["lab-modules.sh plan --json --for-engine alpha"] * 2 + ["lab-modules.sh list --json"])
        # reinstall : le demandé seul.
        before = mark()
        status, started = install({"modules": ["alpha"], "reinstall": True})
        job = wait_job(started["job_id"])
        self.assertEqual([(r["module"], r["action"]) for r in job["result"]["results"]], [("alpha", "reinstall")])
        self.assertNotIn("setup2.sh storage --yes", calls_since(before))
        self.assertIn("setup2.sh alpha --yes", calls_since(before))
        self.assertIn("lab-modules.sh plan --json --for-engine --reinstall alpha", calls_since(before))
        # reinstall + with_deps : la dépendance aussi, dans l'ordre.
        before = mark()
        status, started = install({"modules": ["alpha"], "reinstall": True, "with_deps": True})
        job = wait_job(started["job_id"])
        self.assertEqual(job["state"], "succeeded", job["log"])
        self.assertEqual([(r["module"], r["action"]) for r in job["result"]["results"]],
                         [("storage", "reinstall"), ("alpha", "reinstall")])
        setups = [c for c in calls_since(before) if c.startswith("setup2.sh")]
        self.assertEqual(setups, ["setup2.sh storage --yes", "setup2.sh alpha --yes"])
        self.assertIn("lab-modules.sh plan --json --for-engine --reinstall --with-deps alpha", calls_since(before))
        # Réglage déjà posé + valeur fournie : jamais réécrit (« déjà réglé »), et le pas réussit.
        status, started = install({"modules": ["beta"], "reinstall": True, "settings": {"beta": {"BETA_KEY": SECRET2}}})
        self.assertEqual(status, 200, started)
        job = wait_job(started["job_id"])
        self.assertEqual(job["state"], "succeeded", job["log"])
        self.assertIn("   BETA_KEY: déjà réglé", job["log"])
        self.assertIn(f"BETA_KEY={SECRET}", read(os.path.join(ROOT, "deploiement/beta/.env")))
        self.assertNotIn(SECRET2, json.dumps(job, ensure_ascii=False) + "\n".join(LOGGED))

    def test_3_echec_d_un_pas(self):
        """gamma échoue au build : delta (qui en dépend) est sauté, epsilon (indépendant) est joué."""
        flag("fail-build-gamma")
        try:
            before = mark()
            status, started = install({"modules": ["delta", "epsilon"]})
            self.assertEqual(status, 200, started)
            job = wait_job(started["job_id"])
        finally:
            flag("fail-build-gamma", False)
        self.assertEqual(job["state"], "failed")
        self.assertEqual(steps_of(job), ["module_epsilon", "module_gamma", "module_delta"])
        res = job["result"]
        self.assertEqual((res["ok"], res["step"]), (False, "gamma"))
        self.assertEqual([(r["module"], r["ok"], r["step"]) for r in res["results"]],
                         [("epsilon", True, "done"), ("gamma", False, "build")])
        self.assertIn("build en échec", res["results"][1]["error"])
        self.assertEqual(res["results"][1]["sha"], subprocess.run(["sh", "-c", "printf %s gamma | sha1sum | cut -c1-40"],
                                                                   capture_output=True, text=True).stdout.strip())
        self.assertEqual(res["skipped"], [{"module": "delta", "reason": "dépend de gamma, en échec"}])
        self.assertIn("gamma", res["error"])
        self.assertIn("delta", res["error"])
        self.assertEqual(set(res), {"ok", "step", "results", "skipped", "error"})
        calls = calls_since(before)
        self.assertNotIn("app-sync.sh delta", calls)
        self.assertNotIn("lab-modules.sh selection add gamma --by zzroot", calls)
        self.assertIn("lab-modules.sh selection add epsilon --by zzroot", calls)
        # prepare a créé le .env de gamma depuis son gabarit (vrai lab-modules.sh prepare).
        self.assertIn("GAMMA_MODE=simple", read(os.path.join(ROOT, "deploiement/gamma/.env")))

    def test_4_echec_sync_et_partages(self):
        flag("fail-sync-delta")
        flag("fail-shares")
        try:
            status, started = install({"modules": ["delta"]})
            job = wait_job(started["job_id"])
        finally:
            flag("fail-sync-delta", False)
            flag("fail-shares", False)
        res = job["result"]
        # gamma passe (le partage en échec est signalé, pas bloquant), delta échoue à l'alignement.
        self.assertEqual([(r["module"], r["ok"], r["step"]) for r in res["results"]],
                         [("gamma", True, "done"), ("delta", False, "sync")])
        self.assertIsNone(res["results"][1]["sha"])
        self.assertTrue(any("⚠ storage-shares.sh a rendu 1" in ln for ln in job["log"]), job["log"])
        self.assertEqual((res["ok"], res["step"], res["skipped"]), (False, "delta", []))

    def test_5_un_seul_job_modules_mais_tests_all_libre(self):
        flag("hold-epsilon")
        try:
            status, first = install({"modules": ["epsilon"], "reinstall": True})
            self.assertEqual(status, 200, first)
            wait_running(first["job_id"])
            self.assertEqual(web("GET", "/modules")[1]["job"], first["job_id"])
            status, data = install({"modules": ["alpha"], "reinstall": True})
            self.assertEqual((status, data["error"], data["job_id"]), (409, "job_exists", first["job_id"]), data)
            # Un tests_all (app "" lui aussi) n'est pas bloqué par le job modules…
            status, tests_all = web("POST", "/tests/run-all")
            self.assertEqual(status, 200, tests_all)
            self.assertEqual(tests_all["apps"], ["zeta"])
            # … et un déploiement non plus.
            status, dep_job = web("POST", "/projects/zeta/deploy", {})
            self.assertEqual(status, 200, dep_job)
        finally:
            flag("hold-epsilon", False)
        self.assertEqual(wait_job(first["job_id"])["state"], "succeeded")
        wait_job(tests_all["job_id"])
        wait_job(dep_job["job_id"])
        # Dans l'autre sens : un tests_all en cours ne bloque pas un job modules.
        RUNNER_GATE.clear()
        RUNNER_HIT.clear()
        try:
            status, tests_all = web("POST", "/tests/run-all")
            self.assertEqual(status, 200, tests_all)
            self.assertTrue(RUNNER_HIT.wait(20))
            self.assertEqual(web("GET", f"/jobs/{tests_all['job_id']}?tail=0")[1]["state"], "running")
            status, data = web("POST", "/tests/run-all")
            self.assertEqual((status, data["error"]), (409, "job_exists"), "tests_all reste unique")
            status, mods = install({"modules": ["epsilon"], "reinstall": True})
            self.assertEqual(status, 200, mods)
            self.assertEqual(mods["jobs_ahead"], 1)
        finally:
            RUNNER_GATE.set()
        wait_job(tests_all["job_id"])
        self.assertEqual(wait_job(mods["job_id"])["state"], "succeeded")

    def test_6_verrou_occupe(self):
        fd = os.open(os.path.join(STATE, "deploy.lock"), os.O_RDWR | os.O_CREAT, 0o600)
        fcntl.flock(fd, fcntl.LOCK_EX)
        try:
            status, started = install({"modules": ["beta"], "reinstall": True,
                                       "settings": {"beta": {"BETA_OPT": SECRET2}}})
            self.assertEqual(status, 200, started)
            before = mark()      # après le plan du serveur : la chaîne, elle, ne doit rien lancer
            job = wait_job(started["job_id"], timeout=60)
        finally:
            fcntl.flock(fd, fcntl.LOCK_UN)
            os.close(fd)
        self.assertEqual(job["state"], "failed")
        self.assertEqual(job["step"], "lock")
        res = job["result"]
        self.assertEqual((res["ok"], res["step"], res["results"], res["skipped"]), (False, "lock", [], []))
        self.assertIn("verrou", res["error"])
        self.assertNotIn("exit_code", res)
        self.assertEqual(calls_since(before), [], "rien n'a été lancé")
        self.assertEqual(glob.glob("/tmp/lab-mcp-settings-*"), [], "le serveur supprime le fichier de réglages")
        self.assertNotIn(SECRET2, read(os.path.join(ROOT, "deploiement/beta/.env")))

    def test_7_la_chaine_revalide(self):
        """Arguments ou réglages non recevables remis DIRECTEMENT à la chaîne : rien n'est lancé."""
        env = {**script_env(), "LAB_ROOT": ROOT, "PYTHONPATH": "/app", "LAB_LOCK_TIMEOUT": "5"}
        cases = [["modules", SU, "2", "0", "alpha"], ["modules", "Root!", "0", "0", "alpha"],
                 ["modules", SU, "0", "0", "../alpha"], ["modules", SU, "0", "0", ",".join(f"m{i}" for i in range(21))]]
        for args in cases:
            with self.subTest(args):
                before = mark()
                proc = subprocess.run(["bash", os.path.join(ROOT, "scripts", "lab-lock.sh"), sys.executable, "-m",
                                       "labmcp.chain", *args], env=env, cwd=ROOT, capture_output=True, text=True)
                self.assertEqual(proc.returncode, 2, proc.stdout + proc.stderr)
                self.assertEqual(calls_since(before), [])
        # Fichier de réglages mal formé : refus, et le fichier est supprimé.
        path = "/tmp/zz-reglages-mal-formes.json"
        with open(path, "w") as fh:
            json.dump({"beta": {"BETA_KEY": "a\nb"}}, fh)
        before = mark()
        proc = subprocess.run(["bash", os.path.join(ROOT, "scripts", "lab-lock.sh"), sys.executable, "-m",
                               "labmcp.chain", "modules", SU, "0", "0", "beta"],
                              env={**env, "LAB_MCP_SETTINGS_FILE": path}, cwd=ROOT, capture_output=True, text=True)
        self.assertEqual(proc.returncode, 2, proc.stdout + proc.stderr)
        self.assertFalse(os.path.exists(path))
        self.assertEqual(calls_since(before), [])

    def test_8_deploiement_inchange(self):
        """Un déploiement seul garde ses étapes à lui (sync, validate, setup) — la comparaison complète
        avec le moteur d'avant est `run.sh compare`."""
        status, started = web("POST", "/projects/beta/deploy", {})
        job = wait_job(started["job_id"])
        self.assertEqual(job["state"], "succeeded", job["log"])
        self.assertEqual(steps_of(job), ["sync", "validate", "setup"])
        self.assertIn("exit_code", job["result"])


if __name__ == "__main__":
    unittest.main(argv=[sys.argv[0], "-v"])
