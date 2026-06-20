#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# setup-code-server-auth.sh
#
# Crée le client Keycloak "code-server" pour oauth2-proxy et génère les
# secrets manquants dans sso-lab/.env.
#
# Prérequis : Keycloak démarré, create-app-client.sh disponible dans dev/
#
# Usage :
#   bash sso-lab/setup-code-server-auth.sh
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}→${NC} $*"; }
success() { echo -e "${GREEN}✓${NC} $*"; }
warn()    { echo -e "${YELLOW}⚠${NC} $*"; }
die()     { echo -e "${RED}✗${NC} $*" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="${SCRIPT_DIR}/.env"
CREATE_CLIENT="${ROOT_DIR}/create-app-client.sh"

[[ -f "$CREATE_CLIENT" ]] || die "create-app-client.sh introuvable dans $ROOT_DIR"
[[ -f "$ENV_FILE" ]]      || die ".env introuvable dans $SCRIPT_DIR"

# ── Cookie secret ─────────────────────────────────────────────────────────────
# oauth2-proxy exige exactement 16, 24 ou 32 octets (base64url).
CURRENT_COOKIE=$(grep "^CODE_SERVER_COOKIE_SECRET=" "$ENV_FILE" | cut -d= -f2- || true)
if [[ -z "$CURRENT_COOKIE" ]]; then
  COOKIE_SECRET=$(openssl rand -base64 32 | tr -d '\n=')
  # S'assurer que la longueur est correcte (32 bytes → 44 chars base64, on coupe à 32)
  COOKIE_SECRET="${COOKIE_SECRET:0:32}"
  if grep -q "^CODE_SERVER_COOKIE_SECRET=" "$ENV_FILE"; then
    sed -i "s|^CODE_SERVER_COOKIE_SECRET=.*|CODE_SERVER_COOKIE_SECRET=${COOKIE_SECRET}|" "$ENV_FILE"
  else
    echo "CODE_SERVER_COOKIE_SECRET=${COOKIE_SECRET}" >> "$ENV_FILE"
  fi
  success "CODE_SERVER_COOKIE_SECRET généré"
else
  info "CODE_SERVER_COOKIE_SECRET déjà renseigné — conservé"
fi

# ── Client Keycloak ───────────────────────────────────────────────────────────
info "Création/mise à jour du client Keycloak 'code-server'..."

# Répertoire temporaire avec un nom valide à l'intérieur de dev/
# (create-app-client.sh valide ^[a-zA-Z0-9_-]+$ et cherche le .env dans dev/<nom>)
TMP_NAME="_code-server-setup"
TMP_APP="${ROOT_DIR}/${TMP_NAME}"
mkdir -p "$TMP_APP"
echo "KEYCLOAK_CLIENT_SECRET=" > "${TMP_APP}/.env"
trap 'rm -rf "$TMP_APP"' EXIT

bash "$CREATE_CLIENT" "$TMP_NAME" \
  --client-id code-server \
  --redirect-path /oauth2/callback

# Récupérer le secret
CLIENT_SECRET=$(grep "^KEYCLOAK_CLIENT_SECRET=" "${TMP_APP}/.env" | cut -d= -f2-)
[[ -n "$CLIENT_SECRET" ]] || die "Secret vide — vérifiez la sortie de create-app-client.sh ci-dessus"

# Écrire dans sso-lab/.env sous le bon nom
if grep -q "^CODE_SERVER_CLIENT_SECRET=" "$ENV_FILE"; then
  sed -i "s|^CODE_SERVER_CLIENT_SECRET=.*|CODE_SERVER_CLIENT_SECRET=${CLIENT_SECRET}|" "$ENV_FILE"
else
  echo "CODE_SERVER_CLIENT_SECRET=${CLIENT_SECRET}" >> "$ENV_FILE"
fi
success "CODE_SERVER_CLIENT_SECRET mis à jour dans sso-lab/.env"

echo ""
echo "─────────────────────────────────────────────"
success "Terminé. Redémarrer oauth2-proxy pour appliquer :"
echo "  docker compose -f sso-lab/docker-compose.yml up -d oauth2-proxy"
echo "─────────────────────────────────────────────"
