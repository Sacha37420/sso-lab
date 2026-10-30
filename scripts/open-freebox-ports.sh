#!/usr/bin/env bash
# open-freebox-ports.sh — redirections de ports de la Freebox vers le serveur du lab
#
# Pendant d'open-bbox-ports2.sh pour une Freebox (API Freebox OS, dev.freebox.fr/sdk/os).
#
#   authorize  une seule fois : demande un jeton d'application. La demande s'affiche sur
#              l'écran du Freebox Server, il faut la valider avec ses boutons (≈ 1 min 30).
#              Puis, dans Freebox OS → Paramètres → Gestion des accès → Applications,
#              cocher « Modification des réglages de la Freebox » pour « Lab dev ».
#   status     IP publique, plage de ports (IPv4 partagée ou full-stack), redirections.
#   apply      crée les redirections manquantes (défaut).
#
# Mode HTTPS (DOMAIN configuré) : 80 et 443 en TCP, plus 8189 TCP+UDP (ICE de lab-media).
# Mode HTTP  (DOMAIN=CHANGE_ME) : tous les PORT_* de ports.env, en TCP.
#
# L'API n'accepte pas le mot de passe administrateur : FREEBOX_ADMIN_PASSWORD n'est pas lu.
# Le jeton est dans <LAB_STATE_DIR>/freebox-app-token (600), jamais en argument ni au journal.
# Une redirection existante vers une autre machine est signalée, jamais modifiée.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
_val() { grep -E "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2- | sed 's/[[:space:]]*#.*//' | tr -d '[:space:]"' || true; }

FREEBOX_IP="$(_val "$ROOT/bbox.env" FREEBOX_IP)"
SERVER_URL_LAN="$(_val "$ROOT/.env" SERVER_URL_LAN)"
DOMAIN="$(_val "$ROOT/.env" DOMAIN)"
STATE_DIR="$(_val "$ROOT/.env" LAB_STATE_DIR)"

export FBX_HOST="${FREEBOX_IP:-192.168.1.254}"
export FBX_TOKEN_FILE="${STATE_DIR:-$ROOT/.lab-state}/freebox-app-token"
export FBX_LAN_IP="$(sed -E 's#^https?://##; s#/.*##' <<<"$SERVER_URL_LAN")"
export FBX_DOMAIN="${DOMAIN:-CHANGE_ME}"
export FBX_PORTS_ENV="$ROOT/ports.env"

exec python3 -I - "${1:-apply}" <<'PY'
import hmac, hashlib, json, os, re, socket, sys, time, urllib.request, urllib.error

HOST, TOKEN_FILE = os.environ["FBX_HOST"], os.environ["FBX_TOKEN_FILE"]
LAN_IP, DOMAIN = os.environ["FBX_LAN_IP"], os.environ["FBX_DOMAIN"]
APP_ID = "fr.lab.dev"
CMD = sys.argv[1]

def call(method, path, body=None, session=None, base=None):
    req = urllib.request.Request(f"http://{HOST}{API if base is None else base}{path}", method=method,
                                 data=json.dumps(body).encode() if body is not None else None)
    req.add_header("Content-Type", "application/json")
    if session:
        req.add_header("X-Fbx-App-Auth", session)
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            data = json.load(r)
    except urllib.error.HTTPError as e:
        data = json.load(e)
    if not data.get("success", True):
        raise SystemExit(f"⚠  Freebox : {data.get('error_code')} — {data.get('msg')}")
    return data.get("result") if "success" in data else data

info = call("GET", "/api_version", base="")
API = f"{info['api_base_url']}v{info['api_version'].split('.')[0]}/"

def authorize():
    if os.path.exists(TOKEN_FILE):
        raise SystemExit(f"Jeton déjà présent ({TOKEN_FILE}). Le supprimer pour en redemander un.")
    r = call("POST", "login/authorize/", {"app_id": APP_ID, "app_name": "Lab dev",
             "app_version": "1", "device_name": socket.gethostname()})
    token, track = r["app_token"], r["track_id"]
    print(f"Demande envoyée à « {info.get('device_name', 'Freebox')} ».")
    print("→ Validez-la sur l'écran du Freebox Server avec ses boutons.")
    while True:
        status = call("GET", f"login/authorize/{track}")["status"]
        if status != "pending":
            break
        time.sleep(2)
    if status != "granted":
        raise SystemExit(f"⚠  Autorisation : {status}")
    os.makedirs(os.path.dirname(TOKEN_FILE), exist_ok=True)
    fd = os.open(TOKEN_FILE, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write(token)
    print(f"✓ Jeton enregistré ({TOKEN_FILE}).")
    print("→ Freebox OS → Paramètres → Gestion des accès → Applications → « Lab dev » :")
    print("  cocher « Modification des réglages de la Freebox », puis lancer « apply ».")

def login():
    try:
        token = open(TOKEN_FILE).read().strip()
    except FileNotFoundError:
        raise SystemExit(f"⚠  Pas de jeton : lancer d'abord « bash scripts/open-freebox-ports.sh authorize ».")
    challenge = call("GET", "login/")["challenge"]
    pw = hmac.new(token.encode(), challenge.encode(), hashlib.sha1).hexdigest()
    r = call("POST", "login/session/", {"app_id": APP_ID, "password": pw})
    return r["session_token"], r.get("permissions", {})

def wanted():
    if DOMAIN != "CHANGE_ME":
        return [("http", 80, "tcp"), ("https", 443, "tcp"),
                ("lab-media-ice", 8189, "tcp"), ("lab-media-ice", 8189, "udp")]
    out = []
    for line in open(os.environ["FBX_PORTS_ENV"]):
        m = re.match(r"^PORT_([A-Z_]+)=(\d+)", line)
        if m:
            out.append((m.group(1).lower(), int(m.group(2)), "tcp"))
    return sorted(set(out), key=lambda x: x[1])

if CMD == "authorize":
    authorize(); sys.exit()
if CMD not in ("status", "apply"):
    raise SystemExit("usage : open-freebox-ports.sh [authorize|status|apply]")

session, perms = login()
conn = call("GET", "connection/", session=session)
rng = conn.get("ipv4_port_range") or [0, 65535]
full_stack = rng[0] <= 1 and rng[1] >= 65535
redirs = call("GET", "fw/redir/", session=session) or []

if CMD == "status":
    print(f"Box        : {info.get('box_model_name')} (API {info['api_version']})")
    print(f"IP publique: {conn.get('ipv4')} — état {conn.get('state')}")
    print(f"Ports IPv4 : {rng[0]}-{rng[1]} — {'full-stack' if full_stack else 'IPv4 PARTAGÉE : 80/443 impossibles'}")
    print(f"Droit « réglages » : {'oui' if perms.get('settings') else 'NON'}")
    print("Redirections :")
    for r in redirs:
        print(f"  {'✓' if r['enabled'] else '✗'} {r['wan_port_start']}-{r['wan_port_end']}/{r['ip_proto']}"
              f" → {r['lan_ip']}:{r['lan_port']}  ({r.get('comment', '')})")
    if not redirs:
        print("  (aucune)")
    sys.exit()

if not perms.get("settings"):
    raise SystemExit("⚠  L'application n'a pas le droit « Modification des réglages de la Freebox »"
                     " (Freebox OS → Paramètres → Gestion des accès → Applications).")
if not full_stack:
    print(f"⚠  IPv4 partagée (ports {rng[0]}-{rng[1]}) : demander l'IPv4 full-stack dans l'espace abonné.")

print(f"Cible LAN : {LAN_IP}  —  {'HTTPS, domaine ' + DOMAIN if DOMAIN != 'CHANGE_ME' else 'HTTP, tous les PORT_*'}\n")
failed = 0
for name, port, proto in wanted():
    print(f"  → {name} ({port}/{proto.upper()}) ... ", end="")
    hit = [r for r in redirs if r["ip_proto"] == proto and r["wan_port_start"] <= port <= r["wan_port_end"]]
    if any(r["lan_ip"] == LAN_IP and r["lan_port"] == port for r in hit):
        print("déjà existante"); continue
    if hit:
        print(f"⚠ déjà redirigé vers {hit[0]['lan_ip']}:{hit[0]['lan_port']} — laissé tel quel"); failed += 1; continue
    try:
        call("POST", "fw/redir/", {"enabled": True, "comment": f"lab {name}", "lan_ip": LAN_IP,
             "lan_port": port, "wan_port_start": port, "wan_port_end": port,
             "ip_proto": proto, "src_ip": "0.0.0.0"}, session=session)
        print("OK")
    except SystemExit as e:
        print(e); failed += 1
call("POST", "login/logout/", {}, session=session)
print("\nTerminé." if not failed else f"\n{failed} redirection(s) non posée(s).")
sys.exit(1 if failed else 0)
PY
