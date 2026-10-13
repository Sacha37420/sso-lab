"""Adresse d'essai d'un développeur (chantier « essai-dev », contrat v1, I2) — essais du moteur.

Aucun Docker, aucun réseau, aucune pièce du lab : le moteur livré (labmcp/, monté depuis le dossier de
travail) contre une racine FACTICE créée dans /tmp. Lancement : `bash lab-mcp/tests/preview/run.sh`
(conteneur jetable de l'image du moteur, `--network none`).

Ce qui est réel :
  • labmcp/ en entier : les deux entrées (routes web, outils MCP par le client du SDK),
    l'authentification (seule la clé de vérification est une clé de test, comme harness.py), la file
    de jobs, la veille du terme ;
  • `scripts/lab-lock.sh` et `scripts/lib/{registry,lock}.sh` du dépôt : le verrou est le vrai.
Ce qui est remplacé : `scripts/app-preview.sh`, par le double de tests/preview/scripts/ — il rend
l'interface I1 du contrat (lignes, `RESULTAT=`, codes) et note, pour chaque appel, ses arguments,
son environnement et si le verrou de déploiement est réellement tenu.
"""
import asyncio
import contextlib
import dataclasses
import datetime
import fcntl
import json
import logging
import os
import secrets
import shutil
import sys
import threading
import time
import unittest

import httpx
import uvicorn
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import rsa

REAL_SCRIPTS = "/lab-scripts"
DOMAIN = "lab.test"
BASE = "http://127.0.0.1:8000"
TTL_H = 12

# ── racine factice ───────────────────────────────────────────────────────────
ROOT = "/tmp/zz-preview-root"
shutil.rmtree(ROOT, ignore_errors=True)
os.makedirs(os.path.join(ROOT, "scripts", "lib"))
os.makedirs(os.path.join(ROOT, ".trace"))
for rel in ("lab-lock.sh", "lib/registry.sh", "lib/lock.sh"):                 # les VRAIS
    shutil.copy(os.path.join(REAL_SCRIPTS, rel), os.path.join(ROOT, "scripts", rel))
DOUBLE = os.path.join(ROOT, "scripts", "app-preview.sh")
shutil.copy("/tests/preview/scripts/app-preview.sh", DOUBLE)
STATE = os.path.join(ROOT, ".lab-state")
WORK = os.path.join(ROOT, "work")
QUEUE_APPS = [f"zzq{n}" for n in range(1, 10)]
#        projet       propriétaire (None = pas de ligne .owners : superutilisateur)   dossier de travail
APPS = [("zzapp", "devtest", True), ("zzapp2", "devtest", True), ("zznowork", "devtest", False),
        ("zzother", "devother", True), ("zzsu", None, True)] + [(a, "devtest", True) for a in QUEUE_APPS]
with open(os.path.join(ROOT, ".devs"), "w") as fh:
    fh.write("devtest\ndevother\nzzroot\n")
PORTS = "".join(f"{app}:18100:14100\n" for app, _, _ in APPS)
with open(os.path.join(ROOT, ".ports"), "w") as fh:
    fh.write(PORTS)
with open(os.path.join(ROOT, ".owners"), "w") as fh:
    fh.write("".join(f"{app}:{owner}\n" for app, owner, _ in APPS if owner))
for app, owner, has_work in APPS:
    os.makedirs(os.path.join(ROOT, "deploiement", app))
    with open(os.path.join(ROOT, "deploiement", app, "docker-compose.yml"), "w") as fh:
        fh.write("services: {}\n")
    if has_work:
        os.makedirs(os.path.join(WORK, owner or "zzroot", app))
CALLS = os.path.join(ROOT, ".trace", "preview-calls.log")
MODE = os.path.join(ROOT, ".trace", "preview-mode.json")
os.environ.update(LAB_ROOT=ROOT, DOMAIN=DOMAIN, LAB_SUPERUSER="zzroot", LAB_STATE_DIR=STATE, LAB_WORK_DIR=WORK,
                  OAUTH_HUB_INTERNAL_URL="http://127.0.0.1:9101", GITHUB_API_URL="http://127.0.0.1:9102",
                  LAB_MCP_JOB_LOCK_TIMEOUT="3", LAB_MCP_QUICK_LOCK_TIMEOUT="2", LAB_PREVIEW_TTL_H=str(TTL_H),
                  # Ce qui NE DOIT PAS arriver jusqu'au script : un secret de l'environnement du moteur.
                  ZZ_SECRET_DU_MOTEUR="ne-doit-pas-fuir")

sys.path.insert(0, "/tests")
from labmcp import auth, config, preview  # noqa: E402
from labmcp.access import digest  # noqa: E402
from labmcp.engine import Engine  # noqa: E402
from labmcp.server import build  # noqa: E402
from labmcp.workspaces import Workspace  # noqa: E402

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

LOGGED: list[str] = []


class _Keep(logging.Handler):
    def emit(self, record):
        LOGGED.append(self.format(record))


logging.getLogger().addHandler(_Keep())
logging.getLogger().setLevel(logging.INFO)
logging.getLogger("httpx").setLevel(logging.WARNING)

CFG = config.load()
APP = build(CFG)
ENGINE: Engine = APP.engine
LOOP = asyncio.new_event_loop()
_server = uvicorn.Server(uvicorn.Config(APP, host="127.0.0.1", port=8000, log_level="warning", access_log=False))
threading.Thread(target=lambda: LOOP.run_until_complete(_server.serve()), daemon=True).start()
for _ in range(100):
    try:
        if httpx.get(BASE + "/mcp/healthz", timeout=2).status_code == 200:
            break
    except httpx.HTTPError:
        time.sleep(0.1)
else:
    sys.exit("le serveur d'essai ne répond pas")


# ── outils ───────────────────────────────────────────────────────────────────
def web(method, path, uid="devtest", token=None):
    token = token or client.mint(uid, DOMAIN, "lab-admin")
    r = httpx.request(method, BASE + "/mcp/api" + path, timeout=120, headers={"Authorization": f"Bearer {token}"})
    return r.status_code, r.json()


def mcp(tool, args=None, uid="devtest", token=None):
    return asyncio.run(client.mcp_call(BASE, token or client.mint(uid, DOMAIN, "lab-mcp"), tool, args or {}))


def on_loop(coro):
    """Joue une coroutine dans la boucle du serveur (là où vivent la file de jobs et la veille)."""
    return asyncio.run_coroutine_threadsafe(coro, LOOP).result(120)


def sweep():
    return on_loop(ENGINE.preview_sweep())


def wait_job(job_id, uid="devtest"):
    for _ in range(900):
        status, job = web("GET", f"/jobs/{job_id}?tail=1000", uid)
        assert status == 200, job
        if job["terminal"]:
            return job
        time.sleep(0.1)
    raise AssertionError("job jamais terminé")


def calls():
    try:
        with open(CALLS) as fh:
            return [json.loads(line) for line in fh if line.strip()]
    except OSError:
        return []


def argvs():
    return [c["argv"] for c in calls()]


def set_mode(**mode):
    with open(MODE, "w") as fh:
        json.dump(mode, fh)


def state_file(uid):
    return os.path.join(STATE, "preview", uid, "state.json")


def iso(hours_ago=0.0):
    when = datetime.datetime.now().astimezone().replace(microsecond=0) - datetime.timedelta(hours=hours_ago)
    return when.isoformat()


def put_state(uid, app, built_at, services=("running", "running")):
    os.makedirs(os.path.dirname(state_file(uid)), exist_ok=True)
    names = ("backend", "frontend")
    with open(state_file(uid), "w") as fh:
        json.dump({"app": app, "built_at": built_at, "groups": ["developers"],
                   "services": [{"service": n, "state": s} for n, s in zip(names, services)]}, fh)


@contextlib.contextmanager
def lab_lock():
    """Tient le VRAI verrou de déploiement, comme le ferait un `setup2.sh` lancé à la main."""
    os.makedirs(STATE, exist_ok=True)
    fd = os.open(os.path.join(STATE, "deploy.lock"), os.O_RDWR | os.O_CREAT, 0o600)
    fcntl.flock(fd, fcntl.LOCK_EX)
    try:
        yield
    finally:
        os.close(fd)


def ws_token(uid, app):
    """Jeton d'espace injecté pour (uid, app) sans conteneur (comme harness.py)."""
    token = "labws_" + secrets.token_urlsafe(32)
    ENGINE.ws._ws[uid] = Workspace(uid=uid, app=app, token_hash=digest(token), opened_by=uid, with_github=False)
    return token


def audits(op):
    out = []
    for line in LOGGED:
        try:
            entry = json.loads(line)
        except ValueError:
            continue
        if isinstance(entry, dict) and entry.get("audit") and entry.get("op") == op:
            out.append(entry)
    return out


ABSENT = {"state": "absent", "current": False, "app": None, "url": None, "api_url": None, "groups": [],
          "built_at": None, "expires_at": None, "services": []}
ESSAI_KEYS = ["state", "current", "app", "url", "api_url", "groups", "built_at", "expires_at", "services"]


class Base(unittest.TestCase):
    maxDiff = None

    def setUp(self):
        for _ in range(600):        # aucun job d'un essai précédent ne doit traîner
            if not [j for j in ENGINE.jobs._jobs.values() if j.state in ("queued", "running")]:
                break
            time.sleep(0.1)
        shutil.rmtree(os.path.join(STATE, "preview"), ignore_errors=True)
        for path in (MODE, CALLS):
            with contextlib.suppress(OSError):
                os.unlink(path)
        ENGINE.ws._ws.clear()
        ENGINE._preview_err.clear()
        with open(os.path.join(ROOT, ".ports"), "w") as fh:
            fh.write(PORTS)
        if not os.path.exists(DOUBLE):
            shutil.copy("/tests/preview/scripts/app-preview.sh", DOUBLE)

    def build(self, app="zzapp", uid="devtest", **mode):
        if mode:
            set_mode(**mode)
        status, ticket = web("POST", f"/projects/{app}/preview", uid)
        self.assertEqual(status, 200, ticket)
        return ticket, wait_job(ticket["job_id"], uid)


class T1_Annonce(Base):
    def test_1_outils_annonces(self):
        """Les trois outils existent ; un jeton d'espace se les voit annoncer avec les douze autres."""
        _, tools = mcp(None)
        for tool in ("preview_deploy", "preview_status", "preview_stop"):
            self.assertIn(tool, tools)
        _, ws_tools = asyncio.run(client.mcp_call(BASE, ws_token("devtest", "zzapp"), None, {}))
        self.assertEqual(ws_tools, sorted(["whoami", "status", "logs", "env_list", "env_get", "env_set", "env_unset",
                                           "deploy", "run_tests", "job_status", "sql", "smtp_status",
                                           "preview_deploy", "preview_status", "preview_stop"]))

    def test_2_veille_lancee_au_demarrage_du_serveur(self):
        """La veille du terme tourne dans la boucle du serveur sans attendre une requête d'essai."""
        self.assertIsNotNone(ENGINE._preview_task)
        self.assertFalse(ENGINE._preview_task.done())


class T2_Lecture(Base):
    def test_1_absent_forme_exacte(self):
        status, essai = web("GET", "/projects/zzapp/preview")
        self.assertEqual((status, essai), (200, ABSENT))
        self.assertEqual(list(essai), ESSAI_KEYS)
        self.assertEqual(mcp("preview_status", {"app": "zzapp"}), (200, ABSENT))

    def test_2_get_ne_lance_que_status_sans_verrou(self):
        """GET ne lance que `status <propriétaire>`, ne prend pas le verrou, et répond pendant qu'il est tenu."""
        put_state("devtest", "zzapp", iso(1))
        with lab_lock():
            started = time.time()
            status, essai = web("GET", "/projects/zzapp/preview")
            elapsed = time.time() - started
        self.assertEqual(status, 200, essai)
        self.assertLess(elapsed, 1.5, "GET a attendu le verrou")
        self.assertEqual(argvs(), [["status", "devtest"]])
        # Le double constate que le verrou est tenu (par l'essai, ici) : la preuve que GET ne l'a pas
        # ATTENDU est le délai ci-dessus ; la preuve qu'il ne l'a pas PRIS est l'appel suivant, sans personne.
        os.unlink(CALLS)
        self.assertEqual(web("GET", "/projects/zzapp/preview")[0], 200)
        self.assertEqual([(c["argv"], c["lock"]) for c in calls()], [(["status", "devtest"], False)])
        self.assertNotIn("LAB_LOCK_HELD", calls()[0]["env"])

    def test_3_objet_essai(self):
        built = iso(2)
        put_state("devtest", "zzapp", built)
        status, essai = web("GET", "/projects/zzapp/preview")
        self.assertEqual(status, 200)
        expires = (datetime.datetime.fromisoformat(built) + datetime.timedelta(hours=TTL_H)).isoformat()
        self.assertEqual(essai, {
            "state": "running", "current": True, "app": "zzapp",
            "url": "https://lab.test/dev-devtest/", "api_url": "https://lab.test/dev-devtest-api/",
            "groups": ["developers"], "built_at": built, "expires_at": expires,
            "services": [{"service": "backend", "state": "running"}, {"service": "frontend", "state": "running"}]})
        self.assertEqual(list(essai), ESSAI_KEYS)
        self.assertEqual(expires[-6:], built[-6:], "expires_at garde le décalage horaire de built_at")
        self.assertEqual(mcp("preview_status", {"app": "zzapp"}), (200, essai), "les deux entrées rendent le même objet")

    def test_4_adresse_sur_un_autre_projet(self):
        """`current: false` et `app` nomme l'autre projet du même propriétaire."""
        put_state("devtest", "zzapp2", iso(1), services=("running", "exited"))
        _, essai = web("GET", "/projects/zzapp/preview")
        self.assertEqual((essai["current"], essai["app"], essai["state"]), (False, "zzapp2", "degraded"))
        self.assertIsNotNone(essai["expires_at"])
        _, other = web("GET", "/projects/zzapp2/preview")
        self.assertTrue(other["current"])
        put_state("devtest", "zzapp2", iso(1), services=("exited", "exited"))
        self.assertEqual(web("GET", "/projects/zzapp2/preview")[1]["state"], "stopped")

    def test_5_date_illisible_toleree_en_lecture(self):
        for built in (None, "hier", "2026-10-13T15:02:11"):       # la dernière n'a pas de décalage horaire
            put_state("devtest", "zzapp", built)
            status, essai = web("GET", "/projects/zzapp/preview")
            self.assertEqual((status, essai["state"], essai["built_at"], essai["expires_at"]),
                             (200, "running", built, None))

    def test_6_sortie_de_status_inexploitable(self):
        put_state("devtest", "zzapp", iso(1))
        for how in ("garbage", "wrong-uid", "exit1", "bad-state", "bad-url", "no-line"):
            with self.subTest(how):
                set_mode(status=how)
                status, body = web("GET", "/projects/zzapp/preview")
                self.assertEqual((status, body["error"]), (500, "failed"), body)
                self.assertEqual(mcp("preview_status", {"app": "zzapp"})[1]["error"], "failed")


class T3_Construction(Base):
    def test_1_ticket_job_resultat(self):
        status, ticket = web("POST", "/projects/zzapp/preview")
        self.assertEqual(status, 200, ticket)
        job_id = ticket.pop("job_id")
        self.assertRegex(job_id, r"^[0-9a-f]{16}$")
        self.assertEqual(ticket, {"kind": "preview", "app": "zzapp", "state": "queued", "jobs_ahead": 0})
        job = wait_job(job_id)
        self.assertEqual((job["state"], job["kind"], job["app"], job["launched_by"]),
                         ("succeeded", "preview", "zzapp", "devtest"))
        result = job["result"]
        self.assertEqual(list(result), ["ok", "step", "preview"])
        self.assertEqual((result["ok"], result["step"]), (True, "done"))
        essai = result["preview"]
        self.assertEqual(list(essai), ESSAI_KEYS)
        self.assertEqual((essai["state"], essai["current"], essai["app"]), ("running", True, "zzapp"))
        self.assertEqual(essai, web("GET", "/projects/zzapp/preview")[1])
        # Le journal : les lignes du script, pas la ligne de résultat.
        self.assertIn("→ (double) build de dev-devtest", job["log"])
        self.assertIn("✓ (double) essai de zzapp en service", job["log"])
        self.assertFalse([line for line in job["log"] if "RESULTAT=" in line])
        # Ce qui a été lancé : `up <propriétaire> <app>` SOUS le verrou, puis `status` sans.
        made = [(c["argv"], c["lock"]) for c in calls()]
        self.assertEqual(made[:2], [(["up", "devtest", "zzapp"], True), (["status", "devtest"], False)])
        self.assertIn("LAB_LOCK_HELD", calls()[0]["env"])
        self.assertTrue(audits("preview_deploy") and audits("job:preview"))

    def test_2_environnement_du_script(self):
        """Rien de l'environnement du moteur n'arrive au script, hors la liste fermée de procs.base_env."""
        self.build()
        allowed = {"PATH", "HOME", "LANG", "LAB_LOCK_TIMEOUT", "LAB_SUPERUSER", "LAB_STATE_DIR", "LAB_WORK_DIR",
                   "LAB_LOCK_HELD", "PWD", "OLDPWD", "SHLVL", "_", "LC_CTYPE"}
        for call in calls():
            self.assertFalse(set(call["env"]) - allowed, call)

    def test_3_outil_mcp_meme_operation(self):
        status, ticket = mcp("preview_deploy", {"app": "zzapp"})
        self.assertEqual(status, 200, ticket)
        self.assertEqual({k: v for k, v in ticket.items() if k != "job_id"},
                         {"kind": "preview", "app": "zzapp", "state": "queued", "jobs_ahead": 0})
        for _ in range(300):
            _, job = mcp("job_status", {"job_id": ticket["job_id"]})
            if job["terminal"]:
                break
            time.sleep(0.1)
        self.assertEqual((job["state"], job["result"]["step"], job["result"]["preview"]["current"]),
                         ("succeeded", "done", True))

    def test_4_echec_du_script_relaye(self):
        _, job = self.build(up="fail")
        self.assertEqual(job["state"], "failed")
        self.assertEqual(job["result"], {
            "ok": False, "step": "validate", "error": "le dépôt est refusé par le contrôle de sûreté",
            "reasons": ["[ports] aucun port ne peut être publié", "[bind] montage hors du dossier"]})
        self.assertEqual(job["step"], "validate")
        _, job = self.build(up="fail-noreasons")
        self.assertEqual(job["result"], {"ok": False, "step": "build", "error": "le build a échoué", "reasons": []})

    def test_5_resultat_absent_illisible_ou_incoherent(self):
        """Jamais un succès : chaque cas donne un job `failed`, étape `interne`."""
        for how in ("no-result", "crash", "garbage", "not-object", "wrong-uid", "wrong-app", "ok-exit1",
                    "trailing", "ok-not-bool", "bad-step", "no-state"):
            with self.subTest(how):
                with contextlib.suppress(OSError):
                    os.unlink(state_file("devtest"))
                _, job = self.build(up=how)
                self.assertEqual(job["state"], "failed", job["result"])
                self.assertEqual(list(job["result"]), ["ok", "step", "error", "reasons"])
                self.assertEqual((job["result"]["ok"], job["result"]["step"], job["result"]["reasons"]),
                                 (False, "interne", []), job["result"])
                self.assertNotIn("preview", job["result"])

    def test_6_etat_illisible_apres_un_succes(self):
        _, job = self.build(status="garbage")
        self.assertEqual((job["state"], job["result"]["step"]), ("failed", "interne"))

    def test_7_verrou_occupe(self):
        with lab_lock():
            _, job = self.build()
        self.assertEqual((job["state"], job["result"]["ok"], job["result"]["step"], job["result"]["reasons"]),
                         ("failed", False, "lock", []))
        self.assertEqual(argvs(), [], "le script a été lancé malgré le verrou")

    def test_8_superutilisateur_remplit_l_adresse_du_proprietaire(self):
        ticket, job = self.build("zzapp", uid="zzroot")
        self.assertEqual((job["state"], job["launched_by"]), ("succeeded", "zzroot"))
        self.assertEqual(argvs()[0], ["up", "devtest", "zzapp"])
        self.assertEqual(job["result"]["preview"]["url"], "https://lab.test/dev-devtest/")
        # … et le propriétaire voit le job et l'essai.
        self.assertEqual(web("GET", f"/jobs/{ticket['job_id']}", "devtest")[0], 200)
        self.assertTrue(web("GET", "/projects/zzapp/preview", "devtest")[1]["current"])
        # Le superutilisateur LIT l'adresse du propriétaire, pas la sienne.
        os.unlink(CALLS)
        self.assertEqual(web("GET", "/projects/zzapp/preview", "zzroot")[1], job["result"]["preview"])
        self.assertEqual(argvs(), [["status", "devtest"]])
        # Projet sans ligne .owners : l'adresse est celle du superutilisateur.
        os.unlink(CALLS)
        _, job = self.build("zzsu", uid="zzroot")
        self.assertEqual((job["state"], argvs()[0]), ("succeeded", ["up", "zzroot", "zzsu"]))


class T4_Droits(Base):
    def test_1_autre_developpeur_404_rien_lance(self):
        put_state("devtest", "zzapp", iso(1))
        for method in ("POST", "GET", "DELETE"):
            status, body = web(method, "/projects/zzapp/preview", "devother")
            self.assertEqual((status, body["error"]), (404, "not_found"), (method, body))
        for tool in ("preview_deploy", "preview_status", "preview_stop"):
            status, body = mcp(tool, {"app": "zzapp"}, "devother")
            self.assertEqual((status, body["error"]), (-1, "not_found"), (tool, body))
        self.assertEqual(calls(), [], "quelque chose a été lancé pour un autre développeur")
        self.assertFalse(ENGINE.jobs.active("preview"))
        self.assertTrue(os.path.exists(state_file("devtest")))
        # Indistinct d'un projet inconnu.
        unknown = web("GET", "/projects/zzinconnu/preview", "devother")[1]
        refused = web("GET", "/projects/zzapp/preview", "devother")[1]
        self.assertEqual(unknown["error"], refused["error"])

    def test_2_noms_invalides(self):
        for name in ("..", "dev-devtest", "zzapp%2F..", "ZZAPP"):
            for method in ("POST", "GET", "DELETE"):
                r = httpx.request(method, f"{BASE}/mcp/api/projects/{name}/preview",
                                  headers={"Authorization": "Bearer " + client.mint("devtest", DOMAIN, "lab-admin")})
                self.assertEqual(r.status_code, 404, (method, name))
        self.assertEqual(calls(), [])

    def test_3_compte_non_initialise(self):
        status, body = web("POST", "/projects/zzapp/preview", "devnouveau")
        self.assertEqual((status, body["error"]), (409, "not_initialized"))
        token = client.mint("devhors", DOMAIN, "lab-admin", groups=[])
        self.assertEqual(web("GET", "/projects/zzapp/preview", token=token)[0], 403)
        self.assertEqual(calls(), [])

    def test_4_jeton_d_espace(self):
        """Un jeton d'espace n'agit que pour son uid, sur le projet ouvert."""
        token = ws_token("devtest", "zzapp")
        self.assertEqual(mcp("preview_status", {"app": "zzapp"}, token=token), (200, ABSENT))
        status, ticket = mcp("preview_deploy", {"app": "zzapp"}, token=token)
        self.assertEqual(status, 200, ticket)
        for _ in range(300):
            _, job = mcp("job_status", {"job_id": ticket["job_id"]}, token=token)
            if job["terminal"]:
                break
            time.sleep(0.1)
        self.assertEqual((job["state"], job["launched_by"]), ("succeeded", "devtest"))
        self.assertEqual(argvs()[:2], [["status", "devtest"], ["up", "devtest", "zzapp"]])
        self.assertEqual(mcp("preview_stop", {"app": "zzapp"}, token=token), (200, {"app": "zzapp", "stopped": True}))
        os.unlink(CALLS)
        # Un autre projet du MÊME développeur, le projet d'un autre, un projet inconnu : not_found.
        for app in ("zzapp2", "zzother", "zzinconnu"):
            for tool in ("preview_deploy", "preview_status", "preview_stop"):
                status, body = mcp(tool, {"app": app}, token=token)
                self.assertEqual((status, body["error"]), (-1, "not_found"), (tool, app))
        # Le jeton de l'espace d'un AUTRE développeur ne touche pas à l'adresse de devtest.
        other = ws_token("devother", "zzother")
        put_state("devtest", "zzapp", iso(1))
        for tool in ("preview_deploy", "preview_status", "preview_stop"):
            status, body = mcp(tool, {"app": "zzapp"}, token=other)
            self.assertEqual((status, body["error"]), (-1, "not_found"), tool)
        self.assertEqual(calls(), [])
        self.assertTrue(os.path.exists(state_file("devtest")))
        # … et il agit bien sur la sienne (`status devother`, jamais un autre uid).
        self.assertEqual(mcp("preview_status", {"app": "zzother"}, token=other), (200, ABSENT))
        self.assertEqual(argvs(), [["status", "devother"]])
        # Un jeton d'espace ne vaut pas à l'entrée web.
        self.assertEqual(web("GET", "/projects/zzapp/preview", token=token)[0], 403)

    def test_5_le_script_ne_decide_d_aucun_droit(self):
        """Un état qui nomme le projet d'un autre ne donne rien de plus à personne : `current: false`,
        aucun arrêt possible, et la veille démonte cet essai sans propriétaire légitime."""
        put_state("devother", "zzapp", iso(1))                 # l'adresse de devother « montre » le projet de devtest
        self.assertEqual(web("GET", "/projects/zzapp/preview", "devother")[0], 404)
        _, essai = web("GET", "/projects/zzother/preview", "devother")
        self.assertEqual((essai["current"], essai["app"]), (False, "zzapp"))
        self.assertEqual(web("DELETE", "/projects/zzother/preview", "devother"), (200, {"app": "zzother", "stopped": False}))
        self.assertEqual(web("GET", "/projects/zzapp/preview", "devtest")[1], ABSENT)   # devtest n'en voit rien
        self.assertEqual(sweep(), ["devother"])
        self.assertFalse(os.path.exists(state_file("devother")))


class T5_ErreursImmediates(Base):
    def test_1_no_workspace(self):
        status, body = web("POST", "/projects/zznowork/preview")
        self.assertEqual(status, 409)
        self.assertEqual(list(body), ["error", "detail"])
        self.assertEqual(body["error"], "no_workspace")
        self.assertEqual(mcp("preview_deploy", {"app": "zznowork"}), (-1, body))
        self.assertEqual(calls(), [])

    def test_2_job_exists_et_file_pleine(self):
        set_mode(delay=4)
        status, first = web("POST", "/projects/zzq1/preview")
        self.assertEqual(status, 200, first)
        status, body = web("POST", "/projects/zzq1/preview")
        self.assertEqual((status, body["error"], body["job_id"]), (409, "job_exists", first["job_id"]))
        tickets = [first]
        for app in QUEUE_APPS[1:8]:
            status, ticket = web("POST", f"/projects/{app}/preview")
            self.assertEqual(status, 200, ticket)
            tickets.append(ticket)
        self.assertEqual([t["jobs_ahead"] for t in tickets], list(range(8)))
        status, body = web("POST", f"/projects/{QUEUE_APPS[8]}/preview")
        self.assertEqual((status, body["error"]), (429, "queue_full"))
        set_mode(delay=0)
        for ticket in tickets:
            self.assertEqual(wait_job(ticket["job_id"])["state"], "succeeded")
        # Une adresse par développeur : le dernier construit l'emporte.
        self.assertEqual(web("GET", "/projects/zzq8/preview")[1]["current"], True)
        self.assertEqual(web("GET", "/projects/zzq1/preview")[1]["app"], "zzq8")

    def test_3_script_absent(self):
        os.unlink(DOUBLE)
        for method in ("POST", "GET", "DELETE"):
            status, body = web(method, "/projects/zzapp/preview")
            self.assertEqual((status, body["error"]), (503, "unavailable"), (method, body))
        self.assertEqual(sweep(), [])

    def test_4_lab_sans_domaine(self):
        real = ENGINE.cfg
        ENGINE.cfg = dataclasses.replace(real, domain="CHANGE_ME")
        try:
            status, body = web("POST", "/projects/zzapp/preview")
        finally:
            ENGINE.cfg = real
        self.assertEqual((status, body["error"]), (503, "unavailable"))
        self.assertEqual(calls(), [])

    def test_5_essai_et_deploiement_ne_se_bloquent_pas(self):
        """Un job d'essai en cours ne refuse pas un déploiement du même projet, et inversement."""
        set_mode(delay=2)
        status, essai = web("POST", "/projects/zzapp/preview")
        self.assertEqual(status, 200)
        r = httpx.post(BASE + "/mcp/api/projects/zzapp/deploy", json={}, timeout=30,
                       headers={"Authorization": "Bearer " + client.mint("devtest", DOMAIN, "lab-admin")})
        self.assertEqual((r.status_code, r.json()["kind"]), (200, "deploy"), r.text)
        r2 = httpx.post(BASE + "/mcp/api/projects/zzapp/deploy", json={}, timeout=30,
                        headers={"Authorization": "Bearer " + client.mint("devtest", DOMAIN, "lab-admin")})
        self.assertEqual((r2.status_code, r2.json()["job_id"]), (409, r.json()["job_id"]))
        self.assertEqual(wait_job(essai["job_id"])["state"], "succeeded")
        self.assertEqual(wait_job(r.json()["job_id"])["kind"], "deploy")     # échoue ici (aucun app-sync.sh) : sans objet


class T6_Arret(Base):
    def test_1_arrete_ce_projet(self):
        put_state("devtest", "zzapp", iso(1))
        self.assertEqual(web("DELETE", "/projects/zzapp/preview"), (200, {"app": "zzapp", "stopped": True}))
        self.assertEqual([(c["argv"], c["lock"]) for c in calls()],
                         [(["status", "devtest"], False), (["down", "devtest"], True)])
        self.assertEqual(web("GET", "/projects/zzapp/preview")[1], ABSENT)
        self.assertEqual(web("DELETE", "/projects/zzapp/preview"), (200, {"app": "zzapp", "stopped": False}))

    def test_2_adresse_sur_un_autre_projet_rien_arrete(self):
        put_state("devtest", "zzapp2", iso(1))
        self.assertEqual(web("DELETE", "/projects/zzapp/preview"), (200, {"app": "zzapp", "stopped": False}))
        self.assertEqual(mcp("preview_stop", {"app": "zzapp"}), (200, {"app": "zzapp", "stopped": False}))
        self.assertEqual(argvs(), [["status", "devtest"], ["status", "devtest"]], "un `down` a été lancé")
        self.assertTrue(os.path.exists(state_file("devtest")))

    def test_3_superutilisateur_arrete_l_essai_du_proprietaire(self):
        put_state("devtest", "zzapp", iso(1))
        self.assertEqual(web("DELETE", "/projects/zzapp/preview", "zzroot"), (200, {"app": "zzapp", "stopped": True}))
        self.assertEqual(argvs()[-1], ["down", "devtest"])

    def test_4_verrou_occupe(self):
        put_state("devtest", "zzapp", iso(1))
        with lab_lock():
            status, body = web("DELETE", "/projects/zzapp/preview")
        self.assertEqual((status, body["error"]), (423, "busy"))
        self.assertTrue(os.path.exists(state_file("devtest")))
        self.assertNotIn(["down", "devtest"], argvs())

    def test_5_resultat_de_down_inexploitable(self):
        for how in ("garbage", "fail", "wrong-uid"):
            with self.subTest(how):
                put_state("devtest", "zzapp", iso(1))
                set_mode(down=how)
                status, body = web("DELETE", "/projects/zzapp/preview")
                self.assertEqual((status, body["error"]), (500, "failed"), body)

    def test_6_arret_pendant_un_build(self):
        """Pendant qu'un build tient la main, l'arrêt répond `busy` au lieu de démonter après coup."""
        set_mode(delay=5)
        status, ticket = web("POST", "/projects/zzapp/preview")
        self.assertEqual(status, 200)
        time.sleep(1)
        status, body = web("DELETE", "/projects/zzapp/preview")
        self.assertEqual((status, body["error"]), (423, "busy"), body)
        self.assertEqual(wait_job(ticket["job_id"])["state"], "succeeded")
        self.assertTrue(web("GET", "/projects/zzapp/preview")[1]["current"])


class T7_Terme(Base):
    def test_1_echu_demonte_frais_garde(self):
        put_state("devtest", "zzapp", iso(TTL_H + 1))
        put_state("devother", "zzother", iso(TTL_H - 1))
        before = len(audits("preview_expire"))
        self.assertEqual(sweep(), ["devtest"])
        self.assertFalse(os.path.exists(state_file("devtest")))
        self.assertTrue(os.path.exists(state_file("devother")))
        downs = [(c["argv"], c["lock"]) for c in calls() if c["argv"][0] == "down"]
        self.assertEqual(downs, [(["down", "devtest"], True)])
        entry = audits("preview_expire")[before:]
        self.assertEqual(len(entry), 1)
        self.assertEqual((entry[0]["user"], entry[0]["app"], entry[0]["result"]), ("(moteur)", "zzapp", "ok"))
        self.assertIn("terme échu", entry[0]["detail"])
        self.assertEqual(sweep(), [])

    def test_2_juste_avant_et_juste_apres_le_terme(self):
        put_state("devtest", "zzapp", iso(TTL_H - 0.01))
        self.assertEqual(sweep(), [])
        put_state("devtest", "zzapp", iso(TTL_H + 0.01))
        self.assertEqual(sweep(), ["devtest"])

    def test_3_jamais_sous_un_build(self):
        """L'essai précédent est échu, un build est en cours : rien n'est démonté, ni pendant ni après."""
        put_state("devtest", "zzapp", iso(TTL_H + 5))
        set_mode(delay=4)
        status, ticket = web("POST", "/projects/zzapp/preview")
        self.assertEqual(status, 200)
        seen = []
        while not web("GET", f"/jobs/{ticket['job_id']}")[1]["terminal"]:
            seen.append(sweep())
            time.sleep(0.3)
        self.assertGreater(len(seen), 3)
        self.assertEqual([s for s in seen if s], [])
        self.assertEqual(sweep(), [], "l'essai tout juste construit a été démonté")
        self.assertNotIn("down", [a[0] for a in argvs()])
        self.assertEqual(web("GET", "/projects/zzapp/preview")[1]["state"], "running")

    def test_4_build_en_file_derriere_un_autre(self):
        """Même protection quand le build de ce développeur attend son tour dans la file."""
        put_state("devtest", "zzapp", iso(TTL_H + 5))
        set_mode(delay=3)
        _, first = web("POST", "/projects/zzother/preview", "devother")
        _, second = web("POST", "/projects/zzapp/preview")
        self.assertEqual(second["jobs_ahead"], 1)
        self.assertEqual(sweep(), [])
        self.assertEqual(wait_job(first["job_id"], "devother")["state"], "succeeded")
        self.assertEqual(wait_job(second["job_id"])["state"], "succeeded")
        self.assertNotIn("down", [a[0] for a in argvs()])

    def test_4b_protections_propres_au_moteur(self):
        """Les deux cas ci-dessus sont aussi couverts par le verrou du lab (le build le tient). Ici le
        verrou est LIBRE : seules les protections du moteur empêchent le démontage — un job d'essai
        connu pour ce développeur (pas encore lancé), ou un `up`/`down` du moteur qui a la main."""
        from labmcp.jobs import Job
        put_state("devtest", "zzapp", iso(TTL_H + 5))
        put_state("devother", "zzother", iso(TTL_H + 5))
        ENGINE.jobs._jobs["0" * 16] = Job(id="0" * 16, kind="preview", app="zzapp2", owner="zzroot")   # en file
        try:
            self.assertEqual(sweep(), ["devother"], "seul l'essai du développeur SANS build en attente part")
        finally:
            del ENGINE.jobs._jobs["0" * 16]
        self.assertTrue(os.path.exists(state_file("devtest")))

        async def held():
            async with ENGINE._preview_gate():
                return await ENGINE.preview_sweep()

        self.assertEqual(on_loop(held()), [])
        self.assertTrue(os.path.exists(state_file("devtest")))
        self.assertEqual(sweep(), ["devtest"])

    def test_5_verrou_du_lab_occupe(self):
        """Un déploiement (ou un build lancé à la main) tient le verrou : la veille n'attend pas, et repasse."""
        put_state("devtest", "zzapp", iso(TTL_H + 1))
        with lab_lock():
            started = time.time()
            self.assertEqual(sweep(), [])
            self.assertLess(time.time() - started, 8)
        self.assertTrue(os.path.exists(state_file("devtest")))
        self.assertEqual(sweep(), ["devtest"])

    def test_6_date_illisible_ou_future(self):
        for built in (None, "hier", "2026-10-13T15:02:11", iso(-2)):
            with self.subTest(built):
                put_state("devtest", "zzapp", built)
                self.assertEqual(sweep(), ["devtest"])
        put_state("devtest", "zzapp", iso(-0.05))      # trois minutes d'avance d'horloge : toléré
        self.assertEqual(sweep(), [])

    def test_7_projet_retire(self):
        put_state("devtest", "zzapp", iso(1))
        with open(os.path.join(ROOT, ".ports"), "w") as fh:
            fh.write(PORTS.replace("zzapp:18100:14100\n", ""))
        self.assertEqual(sweep(), ["devtest"])
        self.assertIn("projet a été retiré", audits("preview_expire")[-1]["detail"])

    def test_8_developpeur_desinscrit(self):
        """Un dossier d'état suffit à faire regarder une adresse, même hors de `.devs`."""
        put_state("ancien", "zzapp", iso(1))
        self.assertEqual(sweep(), ["ancien"])
        self.assertEqual(sweep(), [])

    def test_9_erreur_de_veille_journalisee_une_fois(self):
        put_state("devtest", "zzapp", iso(TTL_H + 1))
        set_mode(status="garbage")
        before = len(audits("preview_expire"))
        self.assertEqual((sweep(), sweep(), sweep()), ([], [], []))
        errors = [e for e in audits("preview_expire")[before:] if e["result"] == "error"]
        self.assertEqual(len([e for e in errors if "devtest" in e["detail"]]), 1)
        set_mode(down="fail")
        self.assertEqual(sweep(), [])
        self.assertTrue(os.path.exists(state_file("devtest")))
        set_mode()
        self.assertEqual(sweep(), ["devtest"])


class T8_Redemarrage(Base):
    def test_1_le_terme_survit_a_un_redemarrage(self):
        """Un moteur NEUF (aucune mémoire) : son démarrage relit l'état et démonte ce qui est échu."""
        put_state("devtest", "zzapp", iso(TTL_H + 1))
        put_state("devother", "zzother", iso(1))
        fresh = Engine(CFG)
        asyncio.run(fresh.startup())
        self.assertFalse(os.path.exists(state_file("devtest")))
        self.assertTrue(os.path.exists(state_file("devother")))
        self.assertEqual([c["argv"] for c in calls() if c["argv"][0] == "down"], [["down", "devtest"]])
        # … et il rend, pour l'essai gardé, le même terme qu'avant le redémarrage.
        st = asyncio.run(fresh._preview_status("devother"))
        self.assertEqual(preview.view(st, "zzother", TTL_H), web("GET", "/projects/zzother/preview", "devother")[1])

    def test_2_veille_sans_aucune_requete(self):
        """Sans requête : la veille de fond démonte seule un essai qui arrive à son terme."""
        put_state("devtest", "zzapp", iso(0.002))                       # construit il y a 7 s
        short = Engine(dataclasses.replace(CFG, preview_ttl_h=10 / 3600))  # terme : 10 s

        async def live():
            short.preview_watch()
            first = os.path.exists(state_file("devtest"))
            await asyncio.sleep(1)
            mid = os.path.exists(state_file("devtest"))
            for _ in range(40):
                if not os.path.exists(state_file("devtest")):
                    break
                await asyncio.sleep(0.25)
            short._preview_task.cancel()
            return first, mid, os.path.exists(state_file("devtest"))

        self.assertEqual(asyncio.run(live()), (True, True, False))


if __name__ == "__main__":
    unittest.main(verbosity=2, warnings="ignore")
