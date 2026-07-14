#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# reset_url.sh — Propage les adresses réseau depuis bbox.env vers tous les
#                fichiers .env des projets du workspace.
#
# Sources de vérité :
#   bbox.env  → SERVER_URL_LAN, SERVER_URL_WAN
#   .env      → DOMAIN, ACME_EMAIL  (racine du workspace)
#
# En mode HTTP  (DOMAIN=CHANGE_ME) : URLs basées sur l'IP WAN + ports directs.
# En mode HTTPS (DOMAIN configuré) : URLs basées sur les sous-domaines Caddy.
#
# Usage :
#   1. Éditer bbox.env → renseigner SERVER_URL_WAN (IP publique WAN)
#   2. Optionnel : éditer .env → renseigner DOMAIN et ACME_EMAIL
#   3. ./reset_url.sh
#   4. Redémarrer les stacks concernées (voir instructions en fin de script)
#
# Idempotent : peut être relancé sans risque.
# Ne crée pas de nouvelles clés — met uniquement à jour les clés existantes.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# ── Lecture d'une valeur dans un fichier .env ──────────────────────────────
_env_val() {
  local file="$1" key="$2" default="${3:-}"
  local val
  val=$(grep -E "^${key}[[:space:]]*=" "$file" 2>/dev/null \
        | tail -1 | cut -d'=' -f2- | sed 's/[[:space:]]*#.*//' \
        | tr -d "\"'" | xargs 2>/dev/null || true)
  echo "${val:-$default}"
}

# ── Mise à jour d'une clé existante dans un .env (no-op si absente) ───────
upsert_env() {
  local file="$1" key="$2" val="$3"
  [[ -f "$file" ]] || return 0
  if grep -qE "^${key}[[:space:]]*=" "$file"; then
    sed -i "s|^${key}[[:space:]]*=.*|${key}=${val}|" "$file"
    printf "    ✓ %-30s → %s\n" "${key}" "${val}"
  fi
}

# ── Lecture des sources ────────────────────────────────────────────────────
BBOX_ENV="$SCRIPT_DIR/bbox.env"
ROOT_ENV="$SCRIPT_DIR/.env"

[[ -f "$BBOX_ENV" ]] || { echo "❌  bbox.env introuvable dans $SCRIPT_DIR" >&2; exit 1; }

SERVER_URL_LAN="$(_env_val "$BBOX_ENV" SERVER_URL_LAN)"
SERVER_URL_WAN="$(_env_val "$BBOX_ENV" SERVER_URL_WAN)"

# PORT_KEYCLOAK  : sso-lab/.env  (source de vérité — c'est là que Keycloak est défini)
# HPORT_POSTGRES : infra/.env    (port interne Postgres)
# DB_PASSWORD    : infra/.env    (POSTGRES_PASSWORD — mot de passe partagé du rôle
#                                 devuser ; source de vérité unique pour tout le lab)
PORT_KEYCLOAK="$(_env_val  "$SCRIPT_DIR/sso-lab/.env" PORT_KEYCLOAK  "8080")"
HPORT_POSTGRES="$(_env_val "$SCRIPT_DIR/infra/.env"   HPORT_POSTGRES "5432")"
DB_PASSWORD="$(_env_val    "$SCRIPT_DIR/infra/.env"   POSTGRES_PASSWORD)"

REALM="ssolab"

# ── Lecture du domaine HTTPS ──────────────────────────────────────────────
DOMAIN="CHANGE_ME"
ACME_EMAIL="CHANGE_ME"
if [[ -f "$ROOT_ENV" ]]; then
  DOMAIN="$(_env_val "$ROOT_ENV" DOMAIN "CHANGE_ME")"
  ACME_EMAIL="$(_env_val "$ROOT_ENV" ACME_EMAIL "CHANGE_ME")"
fi

# ── Validation de SERVER_URL_WAN ─────────────────────────────────────────
if [[ -z "$SERVER_URL_WAN" ]]; then
  echo "❌  SERVER_URL_WAN manquant dans bbox.env" >&2; exit 1
fi
if [[ "$SERVER_URL_WAN" == *"CHANGE_ME"* ]]; then
  echo "❌  SERVER_URL_WAN non configuré dans bbox.env (contient encore CHANGE_ME)" >&2
  echo "    Exemple : SERVER_URL_WAN=http://203.0.113.42" >&2
  echo "" >&2
  echo "    Astuce : connaître son IP WAN courante :" >&2
  echo "      curl -s https://api.ipify.org" >&2
  exit 1
fi

# Format : doit commencer par http:// ou https://
if [[ ! "$SERVER_URL_WAN" =~ ^https?://[^/]+ ]]; then
  echo "❌  SERVER_URL_WAN format invalide : '$SERVER_URL_WAN'" >&2
  echo "    Attendu : http://203.0.113.42  ou  https://mon-domaine.example.com" >&2
  exit 1
fi

# Extraction de l'host (sans schéma ni slash final)
_wan_host="${SERVER_URL_WAN#http://}"
_wan_host="${_wan_host#https://}"
_wan_host="${_wan_host%%/*}"
_wan_host="${_wan_host%%:*}"   # retire le port éventuel

# ── Vérification des IPs (LAN + WAN) ────────────────────────────────────
echo "=== Validation des adresses réseau ==="
WARNINGS=0

# ── LAN : détection via la table de routage ───────────────────────────────
_lan_host="${SERVER_URL_LAN#http://}"
_lan_host="${_lan_host#https://}"
_lan_host="${_lan_host%%/*}"
_lan_host="${_lan_host%%:*}"

DETECTED_LAN_IP=""
DETECTED_LAN_IP=$(ip route get 8.8.8.8 2>/dev/null \
  | awk '/src/ { for(i=1;i<=NF;i++) if($i=="src") { print $(i+1); exit } }' \
  || true)
if [[ -n "$DETECTED_LAN_IP" ]]; then
  printf "  IP LAN détectée  : %s\n" "$DETECTED_LAN_IP"
  printf "  IP LAN configurée: %s\n" "$_lan_host"
  if [[ "$DETECTED_LAN_IP" == "$_lan_host" ]]; then
    echo "  ✅  IP LAN correcte."
  else
    echo "  ⚠️  AVERTISSEMENT : l'IP LAN configurée ($_lan_host) ne correspond pas"
    echo "      à l'IP LAN actuelle ($DETECTED_LAN_IP)."
    echo "      Mettez à jour SERVER_URL_LAN dans bbox.env puis relancez reset_url.sh."
    WARNINGS=$(( WARNINGS + 1 ))
  fi
else
  echo "  ⚠️  Impossible de détecter l'IP LAN (ip route indisponible ?)"
  WARNINGS=$(( WARNINGS + 1 ))
fi
echo ""

# ── WAN : détection via api.ipify.org ────────────────────────────────────
DETECTED_WAN_IP=""
if DETECTED_WAN_IP=$(curl -sf --max-time 5 https://api.ipify.org 2>/dev/null); then
  printf "  IP WAN détectée  : %s\n" "$DETECTED_WAN_IP"
  printf "  IP WAN configurée: %s\n" "$_wan_host"
  if [[ "$DETECTED_WAN_IP" == "$_wan_host" ]]; then
    echo "  ✅  IP WAN correcte."
  else
    echo "  ⚠️  AVERTISSEMENT : l'IP configurée ($_wan_host) ne correspond pas"
    echo "      à l'IP WAN actuelle ($DETECTED_WAN_IP)."
    echo "      Causes possibles : DDNS non mis à jour, VPN actif, double NAT."
    WARNINGS=$(( WARNINGS + 1 ))
  fi
else
  echo "  ⚠️  Impossible de joindre api.ipify.org (pas d'accès internet ?)"
  WARNINGS=$(( WARNINGS + 1 ))
fi

# ── Vérification que le port Keycloak est joignable depuis le WAN ─────────
KC_WAN_CHECK="${SERVER_URL_WAN}:${PORT_KEYCLOAK}/realms/${REALM:-ssolab}"
printf "\n  Test accès Keycloak WAN : %s\n" "$KC_WAN_CHECK"
HTTP_CODE=$(curl -sf --max-time 8 -o /dev/null -w "%{http_code}" "$KC_WAN_CHECK" 2>/dev/null || echo "000")
if [[ "$HTTP_CODE" =~ ^[23] ]]; then
  echo "  ✅  Keycloak répond (HTTP $HTTP_CODE) — port-forwarding OK."
elif [[ "$HTTP_CODE" == "000" ]]; then
  echo "  ⚠️  AVERTISSEMENT : Keycloak injoignable sur ${_wan_host}:${PORT_KEYCLOAK}"
  echo "      Vérifier : port-forwarding Bbox (${PORT_KEYCLOAK} → 192.168.1.50:${PORT_KEYCLOAK})"
  echo "               + Keycloak en cours d'exécution"
  echo "               + hairpin NAT supporté par la box"
  WARNINGS=$(( WARNINGS + 1 ))
else
  echo "  ⚠️  Keycloak répond HTTP $HTTP_CODE (inattendu) sur $KC_WAN_CHECK"
  WARNINGS=$(( WARNINGS + 1 ))
fi

if [[ $WARNINGS -gt 0 ]]; then
  echo ""
  echo "  ⚠️  $WARNINGS avertissement(s) — la propagation va quand même continuer."
  echo "      Corriger les problèmes réseau avant de redémarrer les stacks."
fi
echo ""

# ── Variables dérivées ────────────────────────────────────────────────────
KC_URL="${SERVER_URL_WAN}:${PORT_KEYCLOAK}"          # IP WAN directe (toujours)

# En mode HTTPS, les URLs publiques Keycloak passent par Caddy (sous-domaine auth.)
if [[ "$DOMAIN" != "CHANGE_ME" && -n "$DOMAIN" ]]; then
  KC_PUBLIC_URL="https://${DOMAIN}/auth"
  KC_ISSUER_URI="https://${DOMAIN}/auth/realms/${REALM}"
  KC_HOSTNAME_URL="https://${DOMAIN}/auth"
  URL_MODE="HTTPS — domaine : ${DOMAIN} (Caddy path /auth)"
else
  KC_PUBLIC_URL="${KC_URL}"
  KC_ISSUER_URI="${KC_URL}/realms/${REALM}"
  KC_HOSTNAME_URL="${KC_URL}"
  URL_MODE="HTTP — IP directe (DOMAIN non configuré)"
fi

echo "=== reset_url ==="
echo "  MODE              : ${URL_MODE}"
echo "  LAN               : ${SERVER_URL_LAN}"
echo "  WAN               : ${SERVER_URL_WAN}"
echo "  Keycloak direct   : ${KC_URL}"
echo "  Keycloak public   : ${KC_PUBLIC_URL}"
echo "  Keycloak issuer   : ${KC_ISSUER_URI}"
echo "  PORT_KEYCLOAK     : ${PORT_KEYCLOAK}"
echo "  HPORT_POSTGRES    : ${HPORT_POSTGRES}"
echo ""

# ── Parcours de tous les .env des sous-projets ────────────────────────────
STACKS_TO_RESTART=()

while IFS= read -r envfile; do
  # Exclure bbox.env, les .env.example et les fichiers hors sous-dossiers
  [[ "$(basename "$envfile")" == "bbox.env"    ]] && continue
  [[ "$(basename "$envfile")" == *.example     ]] && continue
  [[ "$(basename "$envfile")" == "ports.env"   ]] && continue

  rel="${envfile#"$SCRIPT_DIR"/}"
  dir="$(dirname "$rel")"

  # Snapshot avant modif pour détecter si quelque chose a changé
  before=$(md5sum "$envfile" 2>/dev/null | cut -d' ' -f1)

  upsert_env "$envfile" SERVER_URL_LAN       "$SERVER_URL_LAN"
  upsert_env "$envfile" SERVER_URL_WAN       "$SERVER_URL_WAN"
  upsert_env "$envfile" KEYCLOAK_PUBLIC_URL  "$KC_PUBLIC_URL"
  upsert_env "$envfile" KEYCLOAK_URL         "$KC_URL"
  upsert_env "$envfile" KEYCLOAK_ISSUER_URI  "$KC_ISSUER_URI"
  upsert_env "$envfile" KEYCLOAK_HOSTNAME_URL "$KC_HOSTNAME_URL"
  upsert_env "$envfile" PORT_KEYCLOAK        "$PORT_KEYCLOAK"
  upsert_env "$envfile" HPORT_POSTGRES       "$HPORT_POSTGRES"
  upsert_env "$envfile" HPORT_DB             "$HPORT_POSTGRES"   # alias spring-app
  # Mot de passe DB partagé : aligne chaque app sur infra/.env. upsert_env est un
  # no-op si la clé est absente, donc infra/.env et sso-lab/.env (sans DB_PASSWORD)
  # ne sont pas touchés. Vide ⇒ on ne propage pas (évite d'effacer une valeur).
  [[ -n "$DB_PASSWORD" ]] && upsert_env "$envfile" DB_PASSWORD "$DB_PASSWORD"
  upsert_env "$envfile" DOMAIN               "$DOMAIN"
  upsert_env "$envfile" ACME_EMAIL           "$ACME_EMAIL"

  after=$(md5sum "$envfile" 2>/dev/null | cut -d' ' -f1)

  if [[ "$before" != "$after" ]]; then
    echo "▶ $rel  (modifié)"
    STACKS_TO_RESTART+=("$dir")
  fi

done < <(find "$SCRIPT_DIR" -maxdepth 2 \( -name ".env" -o -name "sso-lab.env" \) | sort)

echo ""
echo "✅  Terminé."

if [[ ${#STACKS_TO_RESTART[@]} -gt 0 ]]; then
  echo ""
  echo "Des fichiers .env ont été modifiés. Pour appliquer les changements :"
  echo ""
  echo "  bash recompose_docker.sh --force"
fi
