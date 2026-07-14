#!/usr/bin/env bash
# open-bbox-ports2.sh — ouvre les ports Bbox adaptés au mode HTTP/HTTPS
#
# Mode HTTPS (DOMAIN configuré) : seulement 80 (challenge ACME + redirect) et 443 (HTTPS)
#   → Caddy gère tout le trafic entrant ; les ports d'app ne sont pas exposés sur Internet.
# Mode HTTP  (DOMAIN=CHANGE_ME) : tous les PORT_* de ports.env (comportement identique
#   à open-bbox-ports.sh — accès direct par port).
#
# Utilise l'API REST Bbox (Bouygues Telecom).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# ── Sources ───────────────────────────────────────────────────────────────────
source "$SCRIPT_DIR/.env"        # → SERVER_URL_LAN, DOMAIN
source "$SCRIPT_DIR/bbox.env"    # → BBOX_URL, BBOX_IP, BBOX_ADMIN_PASSWORD

# Extraire l'IP depuis SERVER_URL_LAN (http://192.168.1.50 → 192.168.1.50)
LAN_IP="${SERVER_URL_LAN#http://}"
LAN_IP="${LAN_IP#https://}"
LAN_IP="${LAN_IP%%/*}"

# ── Ports à ouvrir selon le mode ─────────────────────────────────────────────
if [[ "${DOMAIN:-CHANGE_ME}" != "CHANGE_ME" ]]; then
  echo "Mode HTTPS — domaine : ${DOMAIN}"
  echo "→ Seuls 80 (HTTP-01 / redirect) et 443 (HTTPS) seront ouverts."
  PORT_LINES=("PORT_HTTP=80" "PORT_HTTPS=443")
else
  echo "Mode HTTP — DOMAIN non configuré."
  echo "→ Ouverture de tous les PORT_* de ports.env."
  mapfile -t PORT_LINES < <(
    grep -E '^PORT_[A-Z_]+=[0-9]+' "$SCRIPT_DIR/ports.env" \
    | sed 's/[[:space:]]*#.*//'   \
    | sort -t= -k2 -n -u
  )
fi

echo ""
echo "Cible LAN : $LAN_IP"
echo "Bbox      : $BBOX_URL"
echo ""

# --resolve force mabbox.bytel.fr → IP locale (pas de DNS externe requis)
RESOLVE="--resolve mabbox.bytel.fr:443:${BBOX_IP}"

# ── Authentification Bbox : session cookie ───────────────────────────────────
SESSION_TOKEN=$(curl -sk $RESOLVE \
  -X POST "$BBOX_URL/api/v1/login" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  --data-urlencode "password=$BBOX_ADMIN_PASSWORD" \
  -D - | grep "Set-Cookie: BBOX_ID" | sed 's/.*BBOX_ID=//;s/;.*//' | tr -d '[:space:]')

if [[ -z "$SESSION_TOKEN" ]]; then
  echo "⚠  Authentification Bbox échouée — vérifier BBOX_URL, BBOX_IP et BBOX_ADMIN_PASSWORD" >&2
  exit 1
fi

# ── Obtenir le btoken (device token requis pour les écritures) ────────────────
BTOKEN=$(curl -sk $RESOLVE \
  -H "Cookie: BBOX_ID=$SESSION_TOKEN" \
  "$BBOX_URL/api/v1/device/token" \
  | python3 -c "import json,sys; print(json.load(sys.stdin)[0]['device']['token'])")

if [[ -z "$BTOKEN" ]]; then
  echo "⚠  Impossible d'obtenir le device token Bbox" >&2
  exit 1
fi

echo "Authentification OK."
echo ""

# ── Récupérer les règles existantes (ports externes déjà ouverts) ─────────────
EXISTING_PORTS=$(curl -sk $RESOLVE \
  -H "Cookie: BBOX_ID=$SESSION_TOKEN" \
  "$BBOX_URL/api/v1/nat/rules" \
  | python3 -c "
import json, sys
rules = json.load(sys.stdin)[0]['nat']['rules']
for r in rules:
    if r.get('externalport'):
        print(r['externalport'])
" 2>/dev/null || true)

# ── Ouverture des ports ───────────────────────────────────────────────────────
for line in "${PORT_LINES[@]}"; do
  VAR="${line%%=*}"
  PORT="${line##*=}"
  NAME="${VAR#PORT_}"
  NAME="${NAME,,}"        # lowercase

  echo -n "  → $NAME ($PORT/TCP) ... "

  if echo "$EXISTING_PORTS" | grep -qx "$PORT"; then
    echo "déjà existante"
    continue
  fi

  HTTP=$(curl -sk $RESOLVE -o /dev/null -w "%{http_code}" \
    -X POST "$BBOX_URL/api/v1/nat/rules?btoken=$BTOKEN" \
    -H "Cookie: BBOX_ID=$SESSION_TOKEN" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "enable=1&description=$NAME&protocol=tcp&ipaddress=$LAN_IP&external_port=$PORT&ipremote=&internal_port=$PORT&range=&ipprotocol=IPv4" \
    || echo "000")

  case "$HTTP" in
    200|201) echo "OK" ;;
    *)       echo "erreur HTTP $HTTP" ;;
  esac
done

echo ""
echo "Terminé."
