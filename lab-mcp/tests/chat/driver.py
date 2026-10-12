"""Essai de bout en bout de l'écran de conversation (chantier espace-chat, I2 et I3).

Lancé par tests/chat/run.sh dans le conteneur jetable `zz-chat-mcp-engine` (image du moteur,
labmcp/ monté depuis le dossier de travail). Ce processus est À LA FOIS le moteur — le serveur
livré, comme dans tests/harness.py : clé de vérification de test, doubles d'oauth-hub et de GitHub —
et celui qui joue le scénario, à travers une VRAIE passerelle (gateway/Caddyfile du dossier de
travail) précédée d'un Caddy qui tient lieu de celui du lab, vers de FAUX espaces
(tests/chat/fake_space.py).

Ce qui est remplacé dans le moteur, et rien d'autre :
  • les commandes `docker` du gestionnaire d'espaces et le pare-feu (aucun socket Docker ici) : les
    faux espaces sont créés d'avance par run.sh, sous le préfixe `zz-chat-mcp-ws-` ;
  • scripts/work-clone.sh, par un script factice dans une racine factice (/tmp/root).
Tout le reste est le code livré : authentification, route, opération, ticket, cookie, décision par
requête, attente de la cible, sondes par la passerelle, ramasse-miettes d'inactivité.
"""
import base64
import json
import logging
import os
import socket
import sys
import threading
import time
from urllib.parse import urlsplit

ROOT = "/tmp/root"
os.makedirs(f"{ROOT}/scripts", exist_ok=True)
open(f"{ROOT}/scripts/lab-lock.sh", "w").close()
with open(f"{ROOT}/scripts/work-clone.sh", "w") as fh:
    fh.write('#!/usr/bin/env bash\nmkdir -p "$LAB_WORK_DIR/$1/$2" && echo "$LAB_WORK_DIR/$1/$2"\n')
APPS = {"zzapp": "alice", "zzbob": "bob", "zzcarol": "carol"}
for app in APPS:
    os.makedirs(f"{ROOT}/deploiement/{app}", exist_ok=True)
    open(f"{ROOT}/deploiement/{app}/docker-compose.yml", "w").close()
open(f"{ROOT}/.devs", "w").write("alice\nbob\ncarol\nzzroot\n")
open(f"{ROOT}/.owners", "w").write("".join(f"{a}:{u}\n" for a, u in APPS.items()))
open(f"{ROOT}/.ports", "w").write("".join(f"{a}:1800{i}:1400{i}\n" for i, a in enumerate(APPS)))
DOMAIN = "lab.test"
IDLE_S = 6
os.environ.update(
    LAB_ROOT=ROOT, DOMAIN=DOMAIN, LAB_SUPERUSER="zzroot", LAB_STATE_DIR=f"{ROOT}/.lab-state",
    LAB_WORK_DIR="/tmp/work", LAB_WS_PREFIX=os.environ["FAKE_PREFIX"],
    LAB_WS_GATEWAY_URL=f"http://{os.environ['GATEWAY']}:8080", LAB_WS_IDLE_MIN=str(IDLE_S / 60),
    OAUTH_HUB_INTERNAL_URL="http://127.0.0.1:9101", GITHUB_API_URL="http://127.0.0.1:9102")

import httpx  # noqa: E402
import jwt  # noqa: E402
import uvicorn  # noqa: E402
from cryptography.hazmat.primitives.asymmetric import rsa  # noqa: E402

sys.path.insert(0, "/tests")
import doubles  # noqa: E402

from labmcp import auth, config, firewall, workspaces  # noqa: E402
from labmcp.server import build  # noqa: E402

KEY = rsa.generate_private_key(public_exponent=65537, key_size=2048)


class _TestKeys:
    class _K:
        key = KEY.public_key()

    def get_signing_key_from_jwt(self, _token):
        return self._K


_orig_init = auth.Authenticator.__init__


def _patched_init(self, *a, **kw):
    _orig_init(self, *a, **kw)
    self._jwks = _TestKeys()


auth.Authenticator.__init__ = _patched_init
DOCKER_CALLS: list[str] = []


async def _no_docker(self, *args, env=None, timeout=60):
    DOCKER_CALLS.append(" ".join(args[:3]))
    return 0, "", ""


async def _no_firewall(self, force=False):
    return None


workspaces.WorkspaceManager._docker = _no_docker
firewall.Firewall.ensure = _no_firewall

logging.basicConfig(level=logging.WARNING, stream=sys.stdout, format="%(message)s")
doubles.start()
cfg = config.load()
app = build(cfg)
threading.Thread(target=lambda: uvicorn.run(app, host="0.0.0.0", port=8000, log_level="warning", access_log=False),
                 daemon=True).start()

ENGINE = "http://127.0.0.1:8000"
FRONT = os.environ["FRONT"]          # Caddy qui tient lieu de celui du lab → passerelle
GATEWAY = os.environ["GATEWAY"]
PREFIX = os.environ["FAKE_PREFIX"]
results: list[tuple[bool, str]] = []


def check(ok: bool, label: str, detail: object = "") -> bool:
    results.append((bool(ok), label))
    print(("  OK     " if ok else "  ÉCHEC  ") + label + (f"   → {detail}" if detail != "" and not ok else ""), flush=True)
    return bool(ok)


def title(text: str) -> None:
    print(f"\n── {text}", flush=True)


def mint(uid: str) -> str:
    return jwt.encode({"iss": f"https://{DOMAIN}/auth/realms/ssolab", "exp": int(time.time()) + 900, "typ": "Bearer",
                       "azp": "lab-admin", "preferred_username": uid, "email": f"{uid}@ssolab.local",
                       "groups": ["developers"]}, KEY, algorithm="RS256")


def api(uid: str, method: str, path: str, body=None, timeout=60) -> tuple[int, dict]:
    kw = {} if body is None else {"json": body}
    r = httpx.request(method, ENGINE + "/mcp/api" + path, headers={"Authorization": f"Bearer {mint(uid)}"},
                      timeout=timeout, **kw)
    return r.status_code, r.json()


def is_open(uid: str) -> bool:
    return bool(api(uid, "GET", "/me")[1]["workspace"]["open"])


def raw(path: str, cookie: str = "", *, method: str = "GET", host: str = FRONT, body: bytes = b"",
        upgrade: bool = False, origin: str = "") -> tuple[int, dict, bytes]:
    """Une requête écrite À LA MAIN (le chemin part tel quel, « .. » et « %xx » compris), avec
    l'en-tête Host public. Rend (statut, en-têtes, corps) ; pour un WebSocket accepté, envoie une
    trame et rend l'écho comme corps."""
    s = socket.create_connection((host, 8080), timeout=15)
    lines = [f"{method} {path} HTTP/1.1", f"Host: {DOMAIN}"]
    if cookie:
        lines.append(f"Cookie: {cookie}")
    if upgrade:
        key = base64.b64encode(os.urandom(16)).decode()
        lines += ["Upgrade: websocket", "Connection: Upgrade", f"Sec-WebSocket-Key: {key}", "Sec-WebSocket-Version: 13"]
        if origin:
            lines.append(f"Origin: {origin}")
    else:
        lines.append("Connection: close")
    if body:
        lines += ["Content-Type: application/json", f"Content-Length: {len(body)}"]
    s.sendall(("\r\n".join(lines) + "\r\n\r\n").encode() + body)
    buf = b""
    while b"\r\n\r\n" not in buf:
        chunk = s.recv(65536)
        if not chunk:
            break
        buf += chunk
    head, _, rest = buf.partition(b"\r\n\r\n")
    first, *hlines = head.decode("latin-1").split("\r\n")
    status = int(first.split(" ")[1])
    headers = {}
    for line in hlines:
        k, _, v = line.partition(":")
        headers[k.strip().lower()] = v.strip()
    if upgrade and status == 101:
        msg, mask = b"bonjour", os.urandom(4)
        s.sendall(bytes([0x81, 0x80 | len(msg)]) + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(msg)))
        while len(rest) < 2 or len(rest) < 2 + rest[1]:
            more = s.recv(4096)
            if not more:
                break
            rest += more
        s.close()
        return status, headers, rest[2:2 + rest[1]]
    if not upgrade:
        while True:
            chunk = s.recv(65536)
            if not chunk:
                break
            rest += chunk
        if headers.get("transfer-encoding") == "chunked":
            out, data = b"", rest
            while data:
                size, _, data = data.partition(b"\r\n")
                n = int(size or b"0", 16)
                if not n:
                    break
                out, data = out + data[:n], data[n + 2:]
            rest = out
    s.close()
    return status, headers, rest


def seen(reply: tuple[int, dict, bytes]) -> dict:
    try:
        return json.loads(reply[2] or b"{}")
    except ValueError:
        return {"brut": reply[2][:80].decode("latin-1")}


def fake(uid: str, query: str) -> dict:
    """Commande directe au faux espace (jamais par la passerelle : ne compte pas comme une activité)."""
    return httpx.get(f"http://{PREFIX}{uid}:8080/{query}", timeout=5).json()


def exchange(url: str) -> tuple[int, str, str]:
    """Présente l'URL à ticket comme le ferait le navigateur ; rend (statut, Location, cookie « nom=valeur »)."""
    u = urlsplit(url)
    status, headers, _ = raw(f"{u.path}?{u.query}")
    return status, headers.get("location", ""), headers.get("set-cookie", "").split(";", 1)[0]


def wait_until(cond, timeout: float) -> float | None:
    t0 = time.time()
    while time.time() - t0 < timeout:
        if cond():
            return time.time() - t0
        time.sleep(0.5)
    return None


# ═════════════════════════════════════════════════════════════════════════════
for _ in range(100):
    try:
        if (httpx.get(ENGINE + "/mcp/healthz", timeout=2).status_code == 200
                and raw("/introuvable")[0] == 404 and fake("alice", "__conns") and fake("bob", "__conns")):
            break
    except Exception:
        pass
    time.sleep(0.3)
else:
    print("ÉCHEC : la pile d'essai n'a pas démarré")
    sys.exit(2)

title("1. Ouverture d'une conversation (I3) — route réelle du moteur")
t0 = time.time()
code, out = api("alice", "POST", "/projects/zzapp/workspace", {"target": "chat-claude"})
check(code == 200 and out.get("target") == "chat-claude" and out.get("reused") is False, "POST …/workspace {target: chat-claude} → 200", out)
u = urlsplit(out["url"])
check((u.scheme, u.netloc, u.path) == ("https", DOMAIN, "/ws/alice/_chat/") and u.query.startswith("agent=claude&ticket="),
      "url = https://<DOMAIN>/ws/alice/_chat/?agent=claude&ticket=…", out["url"][:60])
check(time.time() - t0 < 10, "le service répondant, l'ouverture n'attend pas", f"{time.time() - t0:.1f} s")
code, bad = api("alice", "POST", "/projects/zzapp/workspace", {"target": "terminal"})
check(code == 400 and bad.get("error") == "invalid" and bad.get("field") == "target", "cible inconnue → 400 invalid, field: target", bad)
code, bad = api("alice", "POST", "/projects/zzbob/workspace", {"target": "chat-claude"})
check(code == 404, "conversation sur le projet d'un autre → 404, comme l'éditeur", bad)

title("2. Sans session : refus, sur tout ce qui est sous _chat")
check(raw("/ws/alice/_chat/")[0] == 401, "GET /ws/alice/_chat/ sans cookie → 401")
check(raw("/ws/alice/_chat/healthz")[0] == 401, "GET …/_chat/healthz sans cookie → 401")
check(raw("/ws/alice/_chat/activity")[0] == 401, "GET …/_chat/activity sans cookie → 401")
check(raw("/ws/alice/_chat/ws", upgrade=True, origin=f"https://{DOMAIN}")[0] == 401, "WebSocket …/_chat/ws sans cookie → 401")
check(raw("/ws/alice/_chat/", method="POST", body=b"{}")[0] == 401, "POST …/_chat/ sans cookie → 401")
check(raw("/ws/alice/_chat/?agent=claude&ticket=" + "A" * 43)[0] == 401, "ticket inventé → 401")
r = raw("/ws/alice/_chat?agent=claude&ticket=TTT")
check(r[0] == 308 and r[1].get("location") == "/ws/alice/_chat/?agent=claude&ticket=TTT",
      "/ws/alice/_chat sans barre → 308, paramètres conservés", r[1].get("location"))
r = raw("/ws/alice/_chat")
check(r[0] == 308 and r[1].get("location") == "/ws/alice/_chat/", "/ws/alice/_chat sans paramètre → 308 vers …/_chat/", r[1].get("location"))

title("3. Échange du ticket : `agent` conservé, cookie limité à /ws/<uid>/")
u = urlsplit(out["url"])
status, headers, _ = raw(f"{u.path}?{u.query}")
setc = headers.get("set-cookie", "")
check(status == 302 and headers.get("location") == "/ws/alice/_chat/?agent=claude", "302 vers /ws/alice/_chat/?agent=claude", headers.get("location"))
attrs = [p.strip() for p in setc.split(";")]
check(attrs[0].startswith("lab_ws_alice=") and "Path=/ws/alice/" in attrs and "HttpOnly" in attrs and "Secure" in attrs
      and "SameSite=Lax" in attrs, "Set-Cookie lab_ws_alice ; Path=/ws/alice/ ; HttpOnly ; Secure ; SameSite=Lax", attrs[1:])
ALICE = attrs[0]
check(raw(f"{u.path}?{u.query}")[0] == 401, "le même ticket rejoué → 401")

title("4. Relais HTTP de _chat vers le service de conversation (:8090), préfixe retiré")
r = raw("/ws/alice/_chat/?agent=claude", ALICE)
s = seen(r)
check(r[0] == 200 and (s.get("qui"), s.get("service"), s.get("chemin"), s.get("agent")) == ("alice", "chat", "/?agent=claude", "claude"),
      "GET /ws/alice/_chat/?agent=claude → service de conversation d'alice, chemin « /?agent=claude »", s)
check(s.get("host") == DOMAIN and s.get("x_forwarded_host") == DOMAIN, "hôte public transmis inchangé (Host et X-Forwarded-Host)", s)
s = seen(raw("/ws/alice/_chat/a/b.js?x=1&y=2", ALICE))
check((s.get("service"), s.get("chemin")) == ("chat", "/a/b.js?x=1&y=2"), "chemin profond et paramètres relayés tels quels", s)
s = seen(raw("/ws/alice/_chat/api/envoi", ALICE, method="POST", body=b'{"texte": "bonjour"}'))
check((s.get("service"), s.get("methode"), s.get("corps")) == ("chat", "POST", '{"texte": "bonjour"}'), "POST et son corps relayés", s)
s = seen(raw("/ws/alice/_chat/healthz", ALICE))
check(s == {"ok": True}, "…/_chat/healthz → {ok: true} du service", s)

title("5. Relais WebSocket de _chat")
r = raw("/ws/alice/_chat/ws", ALICE, upgrade=True, origin=f"https://{DOMAIN}")
check(r[0] == 101 and r[2] == b"chat@alice /ws : bonjour", "WebSocket …/_chat/ws → 101, écho du service de conversation, chemin « /ws »", r[2])
r = raw("/ws/alice/_chat/sous/dossier/flux?conv=3", ALICE, upgrade=True, origin=f"https://{DOMAIN}")
check(r[0] == 101 and r[2] == b"chat@alice /sous/dossier/flux?conv=3 : bonjour", "WebSocket sur un chemin profond", r[2])
r = raw("/ws/alice/_chat/ws", ALICE, upgrade=True, origin="https://evil.example")
check(r[0] == 403, "Origin étranger : le refus (403) du service arrive jusqu'au client", r[0])
check(raw("/ws/alice/_chat/ws", "lab_ws_alice=" + "B" * 43, upgrade=True, origin=f"https://{DOMAIN}")[0] == 401,
      "WebSocket avec un cookie inventé → 401")

title("6. Éditeur inchangé, et même session pour les deux")
s = seen(raw("/ws/alice/", ALICE))
check((s.get("qui"), s.get("service"), s.get("chemin"), s.get("host")) == ("alice", "editor", "/", DOMAIN),
      "GET /ws/alice/ → éditeur (:8080), chemin « / »", s)
s = seen(raw("/ws/alice/static/x.js?v=1", ALICE))
check((s.get("service"), s.get("chemin")) == ("editor", "/static/x.js?v=1"), "chemin profond de l'éditeur", s)
r = raw("/ws/alice/stable/sock", ALICE, upgrade=True, origin=f"https://{DOMAIN}")
check(r[0] == 101 and r[2] == b"editor@alice /stable/sock : bonjour", "WebSocket de l'éditeur → écho de l'éditeur", r[2])
r = raw("/ws/alice")
check(r[0] == 308 and r[1].get("location") == "/ws/alice/", "/ws/alice → 308 vers /ws/alice/ (inchangé)", r[1].get("location"))
check(raw("/ws/alice/")[0] == 401, "éditeur sans cookie → 401 (inchangé)")
for path in ("/ws/alice/_chatx/y", "/ws/alice/_cha", "/ws/alice/x/_chat/y", "/ws/alice/_Chat/"):
    s = seen(raw(path, ALICE))
    check(s.get("service") == "editor" and s.get("chemin") == path[len("/ws/alice"):], f"{path} n'est pas la conversation → éditeur", s)
    check(raw(path)[0] == 401, f"{path} sans cookie → 401")
code, ed = api("alice", "POST", "/projects/zzapp/workspace")
check(code == 200 and ed["target"] == "editor" and ed["reused"] is True, "POST …/workspace sans corps → editor, reused: true (l'espace n'est pas refermé)", ed)
check(set(ed) == {"url", "uid", "app", "target", "reused", "ticket_expires_in", "workspace"}, "même forme de réponse, plus « target »", sorted(ed))
status, loc, cookie2 = exchange(ed["url"].replace("?ticket=", "?folder=/work/zzapp&ticket="))
check(status == 302 and loc == "/ws/alice/?folder=%2Fwork%2Fzzapp" and cookie2.startswith("lab_ws_alice="),
      "ticket de l'éditeur → 302 vers /ws/alice/ (paramètres conservés, inchangé)", loc)
s = seen(raw("/ws/alice/_chat/?agent=vibe", cookie2))
check((s.get("service"), s.get("agent")) == ("chat", "vibe"), "la session ouverte par l'éditeur ouvre aussi la conversation (même espace)", s)
code, vb = api("alice", "POST", "/projects/zzapp/workspace", {"target": "chat-vibe"})
status, loc, _ = exchange(vb["url"])
check(vb["reused"] is True and (status, loc) == (302, "/ws/alice/_chat/?agent=vibe"), "chat-vibe : 302 vers /ws/alice/_chat/?agent=vibe", loc)
check(DOCKER_CALLS.count("run -d --name") == 1, "un seul conteneur démarré pour les trois ouvertures d'alice", DOCKER_CALLS)

title("7. Le cookie d'un autre uid est refusé")
code, bo = api("bob", "POST", "/projects/zzbob/workspace")
status, loc, BOB = exchange(bo["url"])
check(status == 302 and BOB.startswith("lab_ws_bob="), "bob ouvre SON espace et obtient SON cookie", (status, loc))
check(seen(raw("/ws/bob/", BOB)).get("qui") == "bob", "bob entre chez lui")
bob_as_alice = BOB.replace("lab_ws_bob=", "lab_ws_alice=")
for label, cookie in (("cookie de bob", BOB), ("valeur du cookie de bob sous le nom d'alice", bob_as_alice),
                      ("les deux cookies de bob", f"{BOB}; {bob_as_alice}")):
    check(raw("/ws/alice/_chat/?agent=claude", cookie)[0] == 401, f"{label} sur /ws/alice/_chat/ → 401")
    check(raw("/ws/alice/_chat/ws", cookie, upgrade=True, origin=f"https://{DOMAIN}")[0] == 401, f"{label} sur le WebSocket d'alice → 401")
    check(raw("/ws/alice/", cookie)[0] == 401, f"{label} sur l'éditeur d'alice → 401")
code, bo2 = api("bob", "POST", "/projects/zzbob/workspace")
ticket_bob = urlsplit(bo2["url"]).query.split("ticket=")[1]
check(raw(f"/ws/alice/_chat/?agent=claude&ticket={ticket_bob}")[0] == 401, "ticket de bob présenté sur la conversation d'alice → 401")
check(raw("/ws/bob/_chat/", ALICE)[0] == 401, "cookie d'alice sur /ws/bob/_chat/ → 401")
check(raw("/ws/zzz/_chat/", ALICE)[0] == 401, "espace inexistant → 401")
check(raw("/ws/Alice/_chat/", ALICE)[0] == 404, "uid mal formé → 404, sans question au moteur ni relais")
# URL tordues : l'uid interrogé et l'uid servi viennent de la même capture — jamais le contenu d'un autre.
for path in ("/ws/alice/_chat/../../bob/_chat/", "/ws/alice/_chat/..%2f..%2fbob/", "/ws/alice/../bob/_chat/x",
             "/ws/bob/../alice/_chat/x", "/ws/alice/%5Fchat/x", "/ws/alice/_chat/%2e%2e/%2e%2e/bob/", "/ws/alice//_chat/x",
             "//ws/bob/_chat/"):
    with_alice, with_none = raw(path, ALICE), raw(path)
    who = seen(with_alice).get("qui")
    check(with_none[0] in (401, 404, 308, 400) and who in (None, "alice"),
          f"{path} : jamais servi sans session, jamais le contenu de bob avec celle d'alice", (with_none[0], with_alice[0], who))
    with_bob = raw(path, BOB)
    check(seen(with_bob).get("qui") in (None, "bob"), f"{path} : avec la session de bob, jamais le contenu d'alice", seen(with_bob))

title("8. Aucune connexion gardée ouverte vers l'espace (keepalive off)")
for _ in range(5):
    raw("/ws/alice/_chat/x", ALICE)
    raw("/ws/alice/x", ALICE)
time.sleep(1)
conns = fake("alice", "__conns")
check(conns == {"editor": 1, "chat": 0}, "après 10 requêtes : 0 connexion vers :8090, 1 vers :8080 (celle de cette question)", conns)

title("9. L'ouverture attend le /healthz du service de conversation")
DELAY = 8
fake("carol", f"__set?chat_in={DELAY}")       # le service de conversation de carol n'écoutera que dans 8 s
check(raw("/ws/carol/_chat/healthz")[0] == 401, "(avant) carol n'a pas d'espace ouvert")
t0 = time.time()
code, ca = api("carol", "POST", "/projects/zzcarol/workspace", {"target": "chat-vibe"})
took = time.time() - t0
check(code == 200 and ca["reused"] is False, "espace neuf, cible chat-vibe → 200", ca)
check(DELAY - 1.5 <= took, f"service prêt au bout de {DELAY} s : la réponse l'a attendu ({took:.1f} s)", took)
check(took < 25, "… et moins que la limite commune de 25 s", took)
status, loc, CAROL = exchange(ca["url"])
s = seen(raw(loc, CAROL))
check(status == 302 and (s.get("qui"), s.get("service"), s.get("agent")) == ("carol", "chat", "vibe"),
      "la première page répond aussitôt (pas de 502)", s)
t0 = time.time()
code, bv = api("bob", "POST", "/projects/zzbob/workspace", {"target": "chat-claude"})
took = time.time() - t0
check(code == 200 and bv["reused"] is True and 24 <= took <= 32,
      f"espace SANS service de conversation (image ancienne) : 200 après la limite de 25 s, pas d'erreur ({took:.1f} s)", (code, took))
status, loc, _ = exchange(bv["url"])
check(status == 302 and raw(loc, BOB)[0] == 502, "… et l'URL rendue donne alors un 502 de la passerelle (comme l'éditeur trop lent)", (status, loc))
check(seen(raw("/ws/bob/", BOB)).get("service") == "editor", "… l'éditeur du même espace répond toujours")

title(f"10. Inactivité (limite {IDLE_S} s, ramasse-miettes réel, sondes par la passerelle)")
# Plus aucune requête de dev ne passe à partir d'ici. Battement de l'éditeur coupé là où il faut.
fake("alice", "__set?activity=live&beat=0")     # alice : seule la conversation vit (un tour d'assistant dure)
fake("bob", "__set?beat=live")                  # bob   : pas de service de conversation, l'éditeur bat
fake("carol", "__set?activity=old&beat=0")      # carol : conversation à l'arrêt, éditeur fermé
t = wait_until(lambda: not is_open("carol"), 25)
check(t is not None and t >= 2, f"carol — /activity ancien, aucun autre signe : espace FERMÉ ({t and round(t, 1)} s)", t)
time.sleep(max(0, 3 * IDLE_S - (t or 0)))
check(is_open("alice"), f"alice — /activity récent, aucune requête, éditeur muet depuis {3 * IDLE_S} s : espace GARDÉ")
check(is_open("bob"), "bob — service de conversation absent, l'éditeur bat : espace GARDÉ (l'absence ne ferme pas)")
check(raw("/ws/carol/_chat/", CAROL)[0] == 401, "le cookie de carol ne vaut plus rien une fois l'espace fermé")
fake("alice", "__set?activity=old")
fake("bob", "__set?beat=0")
t = wait_until(lambda: not is_open("alice"), 25)
check(t is not None and t >= 2, f"alice — la conversation s'arrête : espace FERMÉ {IDLE_S} s plus tard ({t and round(t, 1)} s)", t)
t = wait_until(lambda: not is_open("bob"), 25)
check(t is not None, "bob — service absent et plus aucun signe : espace FERMÉ (l'absence ne garde pas)", t)
for mode in ("error", "future", "garbage", "missing"):
    fake("alice", "__set?activity=live&beat=live")
    code, _o = api("alice", "POST", "/projects/zzapp/workspace")
    fake("alice", f"__set?activity={mode}&beat=0")
    t = wait_until(lambda: not is_open("alice"), 25)
    check(code == 200 and t is not None, f"alice — /activity en mode « {mode} » : ignoré, espace FERMÉ ({t and round(t, 1)} s)", t)
check(not any("activity" in c or "_chat" in c for c in DOCKER_CALLS), "aucune commande docker propre à la conversation (même conteneur, même réseau)")
runs = DOCKER_CALLS.count("run -d --name")
check(runs == 3 + 4, f"conteneurs démarrés par le moteur : alice, bob, carol, puis 4 réouvertures d'alice ({runs})", runs)

failed = [label for ok, label in results if not ok]
print(f"\n{len(results) - len(failed)}/{len(results)} contrôles passés" + ("" if not failed else " — ÉCHECS :"))
for label in failed:
    print("  ✗", label)
sys.exit(1 if failed else 0)
