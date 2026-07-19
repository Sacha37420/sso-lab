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
#   bash sso-lab/setup-code-server-auth.sh --rotate   # force la rotation des
#     deux secrets (CODE_SERVER_COOKIE_SECRET + CLIENT_SECRET) même s'ils sont
#     déjà renseignés — utilisé par rotate-secrets-full.sh. Sans ce flag,
#     comportement par défaut inchangé : ne génère que ce qui manque, jamais de
#     rotation surprise au fil des `setup2.sh` habituels. Restart d'oauth2-proxy
#     et code-server requis après (sinon "unauthorized_client" — cf. plus bas).
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

ROTATE=false
for a in "$@"; do
  case "$a" in
    --rotate) ROTATE=true ;;
    *) echo "Argument inconnu : $a" >&2; exit 1 ;;
  esac
done

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}→${NC} $*"; }
success() { echo -e "${GREEN}✓${NC} $*"; }
warn()    { echo -e "${YELLOW}⚠${NC} $*"; }
die()     { echo -e "${RED}✗${NC} $*" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="${SCRIPT_DIR}/.env"
CREATE_CLIENT="${ROOT_DIR}/scripts/create-app-client.sh"

[[ -f "$CREATE_CLIENT" ]] || die "create-app-client.sh introuvable dans $ROOT_DIR/scripts"
[[ -f "$ENV_FILE" ]]      || die ".env introuvable dans $SCRIPT_DIR"

# ── Cookie secret ─────────────────────────────────────────────────────────────
# oauth2-proxy exige exactement 16, 24 ou 32 octets (base64url).
CURRENT_COOKIE=$(grep "^CODE_SERVER_COOKIE_SECRET=" "$ENV_FILE" | cut -d= -f2- || true)
if [[ -z "$CURRENT_COOKIE" || "$ROTATE" == "true" ]]; then
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

# --no-rotate : le secret n'est généré qu'à la création du client. Sans ce flag,
# chaque run rotationnerait le secret dans Keycloak alors que le container
# oauth2-proxy garde l'ancien (Config.Env est figé à la création) → token
# exchange en "unauthorized_client" et 500 sur /code/oauth2/callback. Avec
# --rotate (rotation volontaire), on l'omet exprès — c'est à l'appelant de
# redémarrer oauth2-proxy et code-server juste après.
CREATE_CLIENT_ARGS=( "$TMP_NAME" --client-id code-server --redirect-path /oauth2/callback )
$ROTATE || CREATE_CLIENT_ARGS+=( --no-rotate )
bash "$CREATE_CLIENT" "${CREATE_CLIENT_ARGS[@]}"

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

# ── Audience mapper (aud: code-server dans l'access token) ───────────────────
# Sans ce mapper, oauth2-proxy rejette le token car aud=[account] ≠ code-server.
info "Ajout du mapper d'audience Keycloak (idempotent)..."

KC_PORT=$(grep -E '^PORT_KEYCLOAK=' "$ENV_FILE" | cut -d= -f2 | tr -d '[:space:]' || echo "8080")
KC_ADMIN_USER=$(grep -E '^KEYCLOAK_ADMIN=' "$ENV_FILE" | cut -d= -f2 | tr -d '[:space:]' || echo "admin")
KC_ADMIN_PASS=$(grep -E '^KEYCLOAK_ADMIN_PASSWORD=' "$ENV_FILE" | cut -d= -f2 | tr -d '[:space:]')
KC_URL="http://localhost:${KC_PORT}"

KC_TOKEN=$(curl -s -X POST "${KC_URL}/realms/master/protocol/openid-connect/token" \
  -d "client_id=admin-cli&grant_type=password&username=${KC_ADMIN_USER}&password=${KC_ADMIN_PASS}" \
  | jq -r .access_token)
[[ -n "$KC_TOKEN" && "$KC_TOKEN" != "null" ]] || die "Impossible d'obtenir un token admin Keycloak"

CLIENT_UUID=$(curl -s -H "Authorization: Bearer $KC_TOKEN" \
  "${KC_URL}/admin/realms/ssolab/clients?clientId=code-server" | jq -r '.[0].id')
[[ -n "$CLIENT_UUID" && "$CLIENT_UUID" != "null" ]] || die "Client code-server introuvable dans ssolab"

EXISTING=$(curl -s -H "Authorization: Bearer $KC_TOKEN" \
  "${KC_URL}/admin/realms/ssolab/clients/${CLIENT_UUID}/protocol-mappers/models" \
  | jq -r '.[] | select(.name == "audience-code-server") | .name')

if [[ -z "$EXISTING" ]]; then
  HTTP=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST "${KC_URL}/admin/realms/ssolab/clients/${CLIENT_UUID}/protocol-mappers/models" \
    -H "Authorization: Bearer $KC_TOKEN" \
    -H "Content-Type: application/json" \
    -d '{
      "name": "audience-code-server",
      "protocol": "openid-connect",
      "protocolMapper": "oidc-audience-mapper",
      "config": {
        "included.client.audience": "code-server",
        "id.token.claim": "false",
        "access.token.claim": "true"
      }
    }')
  [[ "$HTTP" == "201" ]] && success "Audience mapper créé" || die "Échec création mapper (HTTP $HTTP)"
else
  info "Audience mapper déjà présent — conservé"
fi

# ── Application du secret à oauth2-proxy ─────────────────────────────────────
# Indispensable : Docker fige Config.Env à la création du container, un simple
# restart ne relit pas le .env. --force-recreate garantit la prise en compte du
# secret même si le reste de la config est inchangé ; --no-deps évite de
# redémarrer keycloak et code-server au passage.
info "Recréation d'oauth2-proxy pour appliquer le secret..."
docker compose -f "${SCRIPT_DIR}/docker-compose.yml" up -d --no-deps --force-recreate oauth2-proxy \
  || die "Échec de la recréation d'oauth2-proxy"

echo ""
echo "─────────────────────────────────────────────"
success "Terminé — oauth2-proxy est à jour."
echo "─────────────────────────────────────────────"
