"""Enchaînements exécutés SOUS LE VERROU de déploiement (contrat I4/I5).

Ce module n'est jamais importé par le serveur : il est LANCÉ par lui, ainsi —

    bash scripts/lab-lock.sh python3 -m labmcp.chain deploy <app> [<sha>]
    bash scripts/lab-lock.sh python3 -m labmcp.chain create <uid> <nom> <type> <visibilité> <groupes>

POURQUOI UN PROCESSUS À PART : le contrat demande que la création et le
déploiement s'enchaînent « sous le verrou », et interdit au serveur de poser son
propre `flock` (les scripts appelés attendraient alors jusqu'à l'échec).
`lab-lock.sh` prend le verrou, exporte `LAB_LOCK_HELD`, puis exécute UNE
commande : c'est ce programme. Chaque script qu'il lance constate que le verrou
est tenu par un ancêtre et ne le reprend pas. Les appels à l'API GitHub de la
création (vérification, création, suppression du dépôt) ont lieu ici, donc sous
le même verrou que le contrôle du nom et l'écriture du registre.

Entrées : arguments déjà validés par le serveur (revalidés ici) ; pour `create`
seulement, jeton GitHub de l'appelant dans LAB_GIT_TOKEN et, s'il y a une graine
(seed.py), le chemin d'un fichier 0600 qui la porte dans LAB_MCP_SEED_FILE — son
CONTENU ne passe jamais par un argument, une variable d'environnement ni le
journal. Un DÉPLOIEMENT ne
reçoit plus aucun jeton (v5) : app-sync.sh lit la clé de déploiement du projet,
déposée ici à sa création. Sorties : journal lisible sur stdout (relayé au
développeur), résultat structuré dans le fichier LAB_MCP_RESULT_FILE.

Le jeton n'est transmis qu'aux deux scripts qui parlent à GitHub. Ni
validate-app.sh ni setup2.sh ne le reçoivent : `docker compose` interpole
`${VAR}` depuis son environnement, donc le docker-compose.yml d'un développeur
pourrait sinon lire le jeton de celui qui déploie (cas du superutilisateur qui
déploie l'app d'un autre).
"""
from __future__ import annotations

import json
import os
import re
import secrets
import subprocess
import sys

from . import seed as seed_rules
from .github import Github, GithubError, LOGIN_RE
from .registry import Registry, valid_app, valid_uid

ROOT = os.environ.get("LAB_ROOT", "")
SCRIPTS = os.path.join(ROOT, "scripts")
RESULT_FILE = os.environ.pop("LAB_MCP_RESULT_FILE", "")
TOKEN = os.environ.pop("LAB_GIT_TOKEN", "")
GITHUB_API = os.environ.pop("GITHUB_API_URL", "https://api.github.com")
GITHUB_WEB = os.environ.pop("GITHUB_WEB_URL", "https://github.com").rstrip("/")
HOOK_BASE = os.environ.pop("LAB_HOOK_BASE", "").rstrip("/")
# Retiré de l'environnement comme le jeton : aucun script lancé d'ici ne connaît ce chemin.
SEED_FILE = os.environ.pop("LAB_MCP_SEED_FILE", "")

SHA_RE = re.compile(r"^[0-9a-f]{7,40}$")
NAME_RE = re.compile(r"^[a-z][a-z0-9-]{1,38}[a-z0-9]$")
GROUPS_RE = re.compile(r"^[A-Za-z0-9_-]+(,[A-Za-z0-9_-]+)*$")
_ANSI = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]")


def say(msg: str) -> None:
    print(msg, flush=True)


def step(name: str, label: str) -> None:
    say(f"══ [lab-mcp] étape « {name} » — {label}")


def finish(result: dict, code: int) -> "None":
    if RESULT_FILE:
        tmp = RESULT_FILE + ".tmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(result, fh, ensure_ascii=False)
        os.replace(tmp, RESULT_FILE)
    sys.exit(code)


def child_env(with_token: bool = False, extra: dict[str, str] | None = None) -> dict[str, str]:
    """Environnement d'un script : celui hérité de lab-lock.sh (LAB_LOCK_HELD
    compris — c'est lui qui évite la reprise du verrou), sans rien de ce
    programme-ci, et avec le jeton seulement si demandé."""
    env = {k: v for k, v in os.environ.items() if k not in ("PYTHONPATH", "LAB_ROOT")}
    if with_token:
        env["LAB_GIT_TOKEN"] = TOKEN
    if extra:
        env.update(extra)
    return env


def run_script(name: str, args: list[str], *, with_token: bool = False,
               extra_env: dict[str, str] | None = None, stdin: str | None = None,
               capture_stdout: bool = False) -> tuple[int, str]:
    """Lance scripts/<name>. stderr rejoint toujours notre stdout (le journal).
    `capture_stdout` : stdout est rendu à l'appelant au lieu d'être journalisé
    (scripts dont stdout est une DONNÉE : SHA, raisons de refus)."""
    sys.stdout.flush()
    proc = subprocess.run(
        ["bash", os.path.join(SCRIPTS, name), *args],
        cwd=ROOT,
        env=child_env(with_token, extra_env),
        input=stdin,
        stdin=None if stdin is not None else subprocess.DEVNULL,
        stdout=subprocess.PIPE if capture_stdout else sys.stdout,
        stderr=sys.stdout,
        text=True,
    )
    return proc.returncode, _ANSI.sub("", proc.stdout or "") if capture_stdout else ""


def run_streaming(name: str, args: list[str], watch) -> int:
    """Comme run_script, mais chaque ligne de sortie passe aussi par `watch`."""
    sys.stdout.flush()
    proc = subprocess.Popen(["bash", os.path.join(SCRIPTS, name), *args], cwd=ROOT, env=child_env(),
                            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            text=True, errors="replace")
    assert proc.stdout is not None
    for line in proc.stdout:
        line = line.rstrip("\n")
        print(line, flush=True)
        try:
            watch(_ANSI.sub("", line))
        except Exception:
            pass
    return proc.wait()


# ─────────────────────────────────────────────────────────────────────────────
# deploy = app-sync.sh → validate-app.sh → setup2.sh
# ─────────────────────────────────────────────────────────────────────────────
def deploy(app: str, sha: str) -> None:
    if not valid_app(app) or (sha and not SHA_RE.fullmatch(sha)):
        finish({"ok": False, "step": "arguments", "error": "arguments invalides"}, 2)
    registry = Registry(ROOT)

    step("sync", f"alignement de {app} sur un commit présent sur origin (app-sync.sh)")
    code, out = run_script("app-sync.sh", [app] + ([sha] if sha else []), capture_stdout=True)
    resolved = out.strip().splitlines()[-1].strip() if out.strip() else ""
    if code != 0 or not re.fullmatch(r"[0-9a-f]{40}", resolved):
        finish({"ok": False, "step": "sync", "exit_code": code,
                "error": "app-sync.sh a refusé — voir le journal (commit absent d'origin, dépôt injoignable, "
                         "clé de déploiement absente ou refusée, fichier réservé suivi par git…)"}, 1)
    say(f"   commit déployable : {resolved}")

    # Mêmes portes que setup2.sh/setup_unit.sh (I4 v5), dites ici d'abord pour que
    # le résultat du job porte les raisons :
    #   • app d'un développeur            → contrôle de sûreté complet + portes de qualité ;
    #   • app du superutilisateur AVEC ligne .owners (créée après le chantier)
    #                                     → portes de qualité seulement ;
    #   • app historique (sans ligne)     → aucune.
    owner_is_su = registry.is_superuser(registry.app_owner(app))
    gate_args = None
    if not owner_is_su:
        gate_args = [app]
    elif registry.has_owner_line(app):
        gate_args = [app, "--quality-only"]
    if gate_args:
        step("validate", "contrôle du dépôt (validate-app.sh" + (" --quality-only)" if len(gate_args) > 1 else ")"))
        code, out = run_script("validate-app.sh", gate_args, capture_stdout=True)
        if code != 0:
            reasons = [ln for ln in out.splitlines() if ln.strip()]
            for ln in reasons:
                say(f"   ✗ {ln}")
            finish({"ok": False, "step": "validate", "exit_code": code, "sha": resolved,
                    "reasons": reasons, "error": "validate-app.sh a refusé le dépôt — rien n'a été lancé"}, 1)
        say("   ✓ contenu validé")

    step("setup", f"déploiement (setup2.sh {app} --yes)")
    # setup2.sh ne rend qu'un code : l'étape en échec se lit sur sa ligne ERROR
    # (build, tests backend). C'est un classement d'affichage, pas une interface.
    seen = {"at": "setup"}

    def watch(line: str) -> None:
        if "ERROR" in line:
            if "tests backend ROUGES" in line:
                seen["at"] = "tests_backend"
            elif "build en échec" in line:
                seen["at"] = "build"
            elif "refusée par" in line:
                seen["at"] = "validate"

    code = run_streaming("setup2.sh", [app, "--yes"], watch)
    if code != 0:
        result = {"ok": False, "step": seen["at"], "exit_code": code, "sha": resolved,
                  "error": {"tests_backend": "tests backend ROUGES — rien n'a été mis en service",
                            "build": "build en échec — rien n'a été mis en service",
                            "validate": "dépôt refusé par les portes du lab — rien n'a été lancé",
                            }.get(seen["at"], "setup2.sh a échoué — voir le journal (lignes ERROR)")
                           + ". La version précédente reste en service."}
        if seen["at"] == "tests_backend":
            result["tests"] = {"backend": "ko", "cloisonnement": "non-lancé"}
        finish(result, 1)
    # Résultat des tests enregistré par le déploiement (I4 v5), relu par la
    # commande qui fait foi : app-status.sh.
    tests, at = None, None
    code, out = run_script("app-status.sh", [app], capture_stdout=True)
    try:
        status = json.loads(out)
        tests, at = status.get("tests"), status.get("at")
    except ValueError:
        pass
    say(f"══ [lab-mcp] {app} déployée au commit {resolved}" + (f" — tests : {json.dumps(tests, ensure_ascii=False)}" if tests else ""))
    finish({"ok": True, "step": "done", "sha": resolved, "tests": tests, "at": at}, 0)


# ─────────────────────────────────────────────────────────────────────────────
# create = check-app-name.sh → dépôt absent ? → création du dépôt →
#          new-app.sh --owner → [graine] → app-register.sh   (retour arrière si échec)
# ─────────────────────────────────────────────────────────────────────────────
def read_seed() -> "dict | None":
    """La graine déposée par le serveur, ou None s'il n'y en a pas. Le fichier est
    supprimé dès qu'il est lu. Illisible ou non recevable : rien n'est créé."""
    if not SEED_FILE:
        return None
    try:
        with open(SEED_FILE, encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        data = None
    finally:
        try:
            os.unlink(SEED_FILE)
        except OSError:
            pass
    if seed_rules.validate(data):
        finish({"ok": False, "step": "arguments", "error": "graine (seed) illisible ou non recevable",
                "rollback": "rien n'avait été créé"}, 2)
    return data


def create(uid: str, name: str, app_type: str, visibility: str, groups: str) -> None:
    if (not valid_uid(uid) or not NAME_RE.fullmatch(name) or app_type not in ("3", "4", "5")
            or visibility not in ("private", "public") or not GROUPS_RE.fullmatch(groups) or not TOKEN):
        finish({"ok": False, "step": "arguments", "error": "arguments invalides"}, 2)
    seed = read_seed()
    registry = Registry(ROOT)

    step("check_name", f"règles de nommage (check-app-name.sh {name})")
    code, out = run_script("check-app-name.sh", [name], capture_stdout=True)
    if code != 0:
        reasons = [ln for ln in out.splitlines() if ln.strip()]
        for ln in reasons:
            say(f"   ✗ {ln}")
        finish({"ok": False, "step": "check_name", "reasons": reasons,
                "error": f"le nom « {name} » est refusé", "rollback": "rien n'avait été créé"}, 1)
    say("   ✓ nom accepté")

    gh = Github(GITHUB_API, TOKEN)
    repo_created = False
    scaffold_started = False
    login = ""
    phase = "repo_check"

    def rollback(failed_step: str, error: str) -> None:
        """Retour en arrière complet : dossier, registre, schéma (app-remove.sh),
        puis le dépôt GitHub — seulement s'il vient d'être créé par CET appel."""
        notes: list[str] = []
        clean = True
        if scaffold_started:
            # Garde-fou : on ne retire que ce que new-app.sh vient d'inscrire au
            # nom de ce dev. Le nom était libre (contrôlé sous ce même verrou).
            if registry.has_owner_line(name) and registry.app_owner(name) == uid:
                say(f"══ [lab-mcp] retour arrière — app-remove.sh {name} --yes")
                rc, _ = run_script("app-remove.sh", [name, "--yes"])
                if rc == 0 and not os.path.exists(os.path.join(ROOT, name)):
                    notes.append("dossier, lignes de registre et schéma retirés")
                else:
                    clean = False
                    notes.append(f"app-remove.sh a rendu {rc} : restes possibles dans {ROOT}/{name} — "
                                 "à faire retirer par le superutilisateur")
            elif os.path.exists(os.path.join(ROOT, name)):
                clean = False
                notes.append(f"le dossier {name} existe sans ligne .owners à votre nom : non retiré — "
                             "à faire retirer par le superutilisateur")
        for leftover in (os.path.join(registry.state_dir(), "auto-deploy", name + ".json"),
                         os.path.join(registry.state_dir(), "deploy-keys", name),
                         os.path.join(registry.state_dir(), "deploy-keys", name + ".pub")):
            try:
                os.unlink(leftover)
            except OSError:
                pass
        if repo_created:
            try:
                gh.delete_repo(login, name)
                notes.append(f"dépôt GitHub {login}/{name} supprimé")
            except GithubError as exc:
                clean = False
                notes.append(
                    f"le dépôt GitHub {login}/{name} (vide) n'a PAS pu être supprimé ({exc}) — la portée "
                    "« delete_repo » n'est pas accordée au lab. Supprimez-le vous-même avant de recommencer : "
                    f"{GITHUB_WEB}/{login}/{name}/settings")
        for n in notes:
            say(f"   ↩ {n}")
        finish({"ok": False, "step": failed_step, "error": error,
                "rollback_complete": clean, "rollback": notes or ["rien n'avait été créé"]}, 1)

    try:
        step("repo_check", "le dépôt ne doit pas déjà exister sur votre compte GitHub")
        me = gh.user()
        login = me["login"]
        if not LOGIN_RE.fullmatch(login):
            rollback("repo_check", "login GitHub inattendu")
        if gh.repo_exists(login, name):
            rollback("repo_check", f"le dépôt {login}/{name} existe déjà sur GitHub — choisissez un autre nom "
                                   "ou supprimez-le")
        say(f"   ✓ {login}/{name} est libre")

        phase = "repo_create"
        step("repo_create", f"création du dépôt {visibility} {login}/{name}")
        gh.create_repo(name, private=(visibility == "private"))
        repo_created = True
        say("   ✓ dépôt créé (vide)")
    except GithubError as exc:
        rollback(phase, str(exc))

    step("scaffold", f"new-app.sh --owner {uid}")
    # Réponses aux questions de new-app.sh, dans l'ordre : nom, type, port(s)
    # (ligne vide = port suggéré, recalculé sous verrou), scaffold, groupe(s),
    # instance PostgreSQL (1 = postgres ; question absente pour Angular seul).
    answers = [name, app_type]
    answers += {"3": [""], "4": ["", ""], "5": [""]}[app_type]
    answers += ["O", groups]
    if app_type in ("3", "4"):
        answers.append("1")
    scaffold_started = True
    code, _ = run_script("new-app.sh", ["--owner", uid], stdin="\n".join(answers) + "\n")
    if code != 0:
        rollback("scaffold", f"new-app.sh a échoué (code {code}) — voir le journal")

    if seed is not None:
        # Avant app-register.sh : les deux fichiers partent dans le PREMIER commit.
        step("seed", f"lots et cahier des charges de la spécification ({seed_rules.ROADMAP_FILE}, "
                     f"{seed_rules.CAHIER_FILE})")
        try:
            done = seed_rules.apply(registry.app_dir(name), seed)
        except seed_rules.SeedError as exc:
            rollback("seed", f"la graine n'a pas pu être posée : {exc}")
        say(f"   ✓ {done['lots']} lot(s) métier dans {seed_rules.ROADMAP_FILE} (en-tête, commande de test et "
            f"Lot 1 du gabarit gardés), {seed_rules.CAHIER_FILE} écrit")

    step("register", "premier commit, push, enregistrement comme sous-module (app-register.sh)")
    url = f"{GITHUB_WEB}/{login}/{name}.git"
    code, out = run_script(
        "app-register.sh", [name, url], with_token=True, capture_stdout=True,
        extra_env={
            "LAB_GIT_AUTHOR_NAME": re.sub(r"[\r\n<>]", " ", str(me["name"]))[:100],
            # Adresse « noreply » de GitHub : rattache le commit au compte du dev
            # sans exposer ni demander son adresse réelle.
            "LAB_GIT_AUTHOR_EMAIL": f"{me['id']}+{login}@users.noreply.github.com",
        },
    )
    sha = out.strip().splitlines()[-1].strip() if out.strip() else ""
    if code != 0 or not re.fullmatch(r"[0-9a-f]{40}", sha):
        rollback("register", f"app-register.sh a échoué (code {code}) — voir le journal")

    # Clé de déploiement (I4 v5) : c'est elle qui permet ensuite de déployer sans
    # le jeton GitHub de personne. Sans elle un dépôt privé serait indéployable :
    # son échec est donc un échec de la création.
    step("deploy_key", "clé de déploiement en lecture seule")
    state = registry.state_dir()
    key_path = os.path.join(state, "deploy-keys", name)
    try:
        from cryptography.hazmat.primitives import serialization
        from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
        key = Ed25519PrivateKey.generate()
        os.makedirs(os.path.dirname(key_path), mode=0o700, exist_ok=True)
        fd = os.open(key_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "wb") as fh:
            fh.write(key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.OpenSSH,
                                       serialization.NoEncryption()))
        public = key.public_key().public_bytes(serialization.Encoding.OpenSSH,
                                               serialization.PublicFormat.OpenSSH).decode()
        with open(key_path + ".pub", "w", encoding="utf-8") as fh:
            fh.write(public + f" lab-deploy-{name}\n")
        gh.add_deploy_key(login, name, public)
        say("   ✓ clé publique déposée sur le dépôt (lecture seule), clé privée gardée par le lab")
    except (GithubError, OSError) as exc:
        rollback("deploy_key", f"clé de déploiement : {exc}")

    # Webhook du déploiement automatique : créé maintenant (c'est le seul moment
    # où l'on tient le jeton GitHub), INACTIF côté lab tant que le dev ne l'a pas
    # activé. Son échec n'annule pas la création.
    auto = {"enabled": False, "secret": "", "hook_id": 0}
    if HOOK_BASE:
        step("webhook", "webhook du déploiement automatique (désactivé par défaut)")
        try:
            secret = secrets.token_hex(32)
            auto["hook_id"] = gh.create_hook(login, name, f"{HOOK_BASE}/{name}", secret)
            auto["secret"] = secret
            say("   ✓ webhook créé")
        except GithubError as exc:
            say(f"   ⚠ webhook non créé ({exc}) — le déploiement automatique ne sera pas disponible")
    auto_path = os.path.join(state, "auto-deploy", name + ".json")
    try:
        os.makedirs(os.path.dirname(auto_path), mode=0o700, exist_ok=True)
        fd = os.open(auto_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(auto, fh)
    except OSError:
        pass

    ports = registry.ports().get(name, ("", ""))
    say(f"══ [lab-mcp] {name} créée — dépôt {url}, premier commit {sha}")
    finish({"ok": True, "step": "done", "app": name, "repo_url": url, "sha": sha,
            "ports": {"backend": ports[0], "frontend": ports[1]},
            "auto_deploy_available": bool(auto["secret"])}, 0)


def main(argv: list[str]) -> None:
    if not ROOT or not os.path.isdir(SCRIPTS) or not os.environ.get("LAB_LOCK_HELD"):
        # Lancé hors de lab-lock.sh : on refuse plutôt que d'agir sans verrou.
        print("labmcp.chain doit être lancé par scripts/lab-lock.sh", file=sys.stderr)
        sys.exit(2)
    if len(argv) in (2, 3) and argv[0] == "deploy":
        deploy(argv[1], argv[2] if len(argv) == 3 else "")
    elif len(argv) == 6 and argv[0] == "create":
        create(*argv[1:])
    else:
        print("usage : labmcp.chain deploy <app> [sha] | create <uid> <nom> <type> <visibilité> <groupes>",
              file=sys.stderr)
        sys.exit(2)


if __name__ == "__main__":
    main(sys.argv[1:])
