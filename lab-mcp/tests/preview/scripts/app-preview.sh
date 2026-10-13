#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# DOUBLE DE TEST de scripts/app-preview.sh (tests/preview/) — interface I1 du contrat « essai-dev » v1.
# Ne touche ni Docker, ni une base, ni Keycloak : il tient l'état d'un essai dans
# <LAB_STATE_DIR>/preview/<uid>/state.json et rend les lignes et le RESULTAT= du contrat.
#
#   up <uid> <app> | down <uid> | status <uid>      (codes 0 / 1 / 2, comme le vrai)
#
# Chaque appel est noté dans <racine>/.trace/preview-calls.log (une ligne JSON) : arguments, noms des
# variables d'environnement reçues, et si le verrou de déploiement est RÉELLEMENT tenu à cet instant
# (essai de flock non bloquant — pas la variable LAB_LOCK_HELD, qui ne prouve rien).
# Le comportement se règle dans <racine>/.trace/preview-mode.json : {"up": …, "status": …, "down": …,
# "delay": secondes} — voir les cas ci-dessous.
# ─────────────────────────────────────────────────────────────────────────────
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export DOUBLE_ROOT="$ROOT"
exec python3 - "$@" <<'PY'
import datetime, fcntl, json, os, shutil, sys, time

root = os.environ["DOUBLE_ROOT"]
state_dir = os.environ.get("LAB_STATE_DIR") or os.path.join(root, ".lab-state")
argv = sys.argv[1:]
try:
    mode = json.load(open(os.path.join(root, ".trace", "preview-mode.json")))
except (OSError, ValueError):
    mode = {}


def lock_held():
    path = os.path.join(state_dir, "deploy.lock")
    try:
        fd = os.open(path, os.O_RDWR | os.O_CREAT, 0o600)
    except OSError:
        return False
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        return True
    finally:
        os.close(fd)
    return False


with open(os.path.join(root, ".trace", "preview-calls.log"), "a") as fh:
    fh.write(json.dumps({"argv": argv, "lock": lock_held(), "stdin_closed": not sys.stdin.isatty(),
                         "env": sorted(k for k in os.environ if k != "DOUBLE_ROOT")}) + "\n")


def result(obj, code=0):
    print("RESULTAT=" + json.dumps(obj, ensure_ascii=False), flush=True)
    sys.exit(code)


def state_path(uid):
    return os.path.join(state_dir, "preview", uid, "state.json")


def read_state(uid):
    try:
        return json.load(open(state_path(uid)))
    except (OSError, ValueError):
        return None


def urls(uid):
    return f"https://lab.test/dev-{uid}/", f"https://lab.test/dev-{uid}-api/"


if len(argv) == 3 and argv[0] == "up":
    _, uid, app = argv
    how = mode.get("up", "ok")
    print(f"→ (double) copie du dossier de travail de {app}", flush=True)
    time.sleep(float(mode.get("delay", 0)))
    print(f"→ (double) build de dev-{uid}", flush=True)
    if how == "fail":
        print("✗ (double) le dépôt est refusé", flush=True)
        result({"ok": False, "step": "validate", "error": "le dépôt est refusé par le contrôle de sûreté",
                "reasons": ["[ports] aucun port ne peut être publié", "[bind] montage hors du dossier"]}, 1)
    if how == "fail-noreasons":
        result({"ok": False, "step": "build", "error": "le build a échoué"}, 1)
    if how == "bad-step":
        result({"ok": False, "step": "Étape Bizarre !", "error": "x"}, 1)
    if how == "no-result":
        sys.exit(0)
    if how == "crash":
        print("Traceback (double) : plantage", file=sys.stderr, flush=True)
        sys.exit(3)
    if how == "garbage":
        print("RESULTAT={pas du json", flush=True)
        sys.exit(0)
    if how == "not-object":
        print('RESULTAT=["ok"]', flush=True)
        sys.exit(0)
    built = mode.get("built_at") or datetime.datetime.now().astimezone().replace(microsecond=0).isoformat()
    services = [{"service": "backend", "state": "running"}, {"service": "frontend", "state": "running"}]
    if how != "no-state":
        os.makedirs(os.path.dirname(state_path(uid)), exist_ok=True)
        json.dump({"app": app, "built_at": built, "services": services, "groups": ["developers"]},
                  open(state_path(uid), "w"))
    url, api = urls(uid)
    ok = {"ok": True, "uid": uid, "app": app, "url": url, "api_url": api, "groups": ["developers"],
          "database": f"dev_{uid}", "schema": app.replace("-", "_") + "__essai", "built_at": built,
          "services": services}
    if how == "wrong-uid":
        ok["uid"] = "quelquunautre"
    if how == "wrong-app":
        ok["app"] = "une-autre-app"
    if how == "ok-not-bool":
        ok["ok"] = "oui"
    print(f"✓ (double) essai de {app} en service", flush=True)
    if how == "trailing":
        print("RESULTAT=" + json.dumps(ok), flush=True)
        print("une ligne après le résultat", flush=True)
        sys.exit(0)
    result(ok, 1 if how == "ok-exit1" else 0)

if len(argv) == 2 and argv[0] == "down":
    uid = argv[1]
    how = mode.get("down", "ok")
    if how == "garbage":
        print("RESULTAT=n'importe quoi", flush=True)
        sys.exit(0)
    if how == "fail":
        result({"ok": False, "step": "down", "error": "arrêt impossible"}, 1)
    had = read_state(uid) is not None
    if had:
        os.unlink(state_path(uid))
    print(f"→ (double) essai de {uid} arrêté" if had else "→ (double) rien à arrêter", flush=True)
    result({"ok": True, "uid": "quelquunautre" if how == "wrong-uid" else uid, "stopped": had})

if len(argv) == 2 and argv[0] == "status":
    uid = argv[1]
    how = mode.get("status", "ok")
    if how == "exit1":
        print("✗ (double) état illisible", file=sys.stderr)
        sys.exit(1)
    if how == "no-line":
        print("aucune ligne de résultat")
        sys.exit(0)
    if how == "garbage":
        print("RESULTAT={{{")
        sys.exit(0)
    st = read_state(uid)
    if st is None:
        out = {"uid": uid, "state": "absent", "app": None, "url": None, "api_url": None, "groups": [],
               "built_at": None, "services": []}
    else:
        states = [s["state"] for s in st["services"]]
        if all(s == "running" for s in states):
            state = "running"
        elif all(s == "exited" for s in states):
            state = "stopped"
        else:
            state = "degraded"
        url, api = urls(uid)
        out = {"uid": uid, "state": state, "app": st["app"], "url": url, "api_url": api,
               "groups": st.get("groups", []), "built_at": st["built_at"], "services": st["services"]}
    if how == "wrong-uid":
        out["uid"] = "quelquunautre"
    if how == "bad-state":
        out["state"] = "magnifique"
    if how == "bad-url" and out["url"]:
        out["url"] = "javascript:alert(1)"
    print("→ (double) état lu")
    result(out)

print("usage : app-preview.sh up <uid> <app> | down <uid> | status <uid>", file=sys.stderr)
sys.exit(2)
PY
