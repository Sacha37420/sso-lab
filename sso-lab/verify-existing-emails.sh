#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# verify-existing-emails.sh
#
# Marque emailVerified=true sur les comptes DÉJÀ présents dans le realm.
#
# Pourquoi : activer VERIFY_EMAIL=true impose la validation de l'adresse à la
# connexion à TOUS les comptes dont emailVerified=false — y compris les comptes
# LDAP historiques. Ceux dont l'adresse est factice (hassan@ssolab.local,
# maria@ssolab.local) ne recevraient jamais le mail et resteraient bloqués sur
# l'écran de vérification. On les considère donc comme vérifiés d'office.
#
# À lancer UNE FOIS, juste avant d'ouvrir l'inscription.
# ⚠ Ne pas relancer une fois l'inscription ouverte : le script validerait
#   d'office l'adresse des nouveaux inscrits en attente de vérification, ce qui
#   viderait la vérification d'email de son sens. Il refuse de le faire seul et
#   demande --force pour passer outre.
#
# Usage :
#   bash sso-lab/verify-existing-emails.sh [--force]
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}→${NC} $*"; }
success() { echo -e "${GREEN}✓${NC} $*"; }
warn()    { echo -e "${YELLOW}⚠${NC} $*"; }
die()     { echo -e "${RED}✗${NC} $*" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"
FORCE=false
[[ "${1:-}" == "--force" ]] && FORCE=true

[[ -f "$ENV_FILE" ]] || die ".env introuvable dans $SCRIPT_DIR"
command -v jq >/dev/null || die "jq est requis."

_env_val() {
  grep -E "^$1=" "$ENV_FILE" 2>/dev/null | head -1 | cut -d= -f2- \
    | sed 's/[[:space:]]*#.*//; s/^["'"'"']//; s/["'"'"']$//' \
    | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

KC_URL="http://localhost:$(_env_val PORT_KEYCLOAK)"
KC_ADMIN="$(_env_val KEYCLOAK_ADMIN)"
KC_PASS="$(_env_val KEYCLOAK_ADMIN_PASSWORD)"
REALM="$(_env_val KEYCLOAK_REALM)"
REALM="${REALM:-ssolab}"

info "Keycloak : $KC_URL  (realm: $REALM)"

TOKEN=$(curl -sf \
  -d "client_id=admin-cli" -d "username=$KC_ADMIN" -d "password=$KC_PASS" \
  -d "grant_type=password" \
  "$KC_URL/realms/master/protocol/openid-connect/token" | jq -r '.access_token // empty')
[[ -n "$TOKEN" ]] || die "Authentification admin Keycloak échouée."

# Garde-fou : si l'inscription est déjà ouverte, des comptes en attente de
# vérification peuvent exister — on ne les valide pas à l'aveugle.
REG_OPEN=$(curl -sf -H "Authorization: Bearer $TOKEN" \
  "$KC_URL/admin/realms/$REALM" | jq -r '.registrationAllowed')
if [[ "$REG_OPEN" == "true" && "$FORCE" != "true" ]]; then
  warn "L'inscription libre est déjà ouverte sur le realm '$REALM'."
  warn "Valider d'office les emails maintenant validerait aussi ceux des inscrits"
  warn "en attente. Relancer avec --force si c'est bien l'intention."
  exit 1
fi

USERS=$(curl -sf -H "Authorization: Bearer $TOKEN" \
  "$KC_URL/admin/realms/$REALM/users?max=1000")
TOTAL=$(echo "$USERS" | jq 'length')
info "$TOTAL compte(s) dans le realm."

COUNT=0
while IFS=$'\t' read -r ID USERNAME EMAIL VERIFIED; do
  [[ -n "$ID" ]] || continue
  if [[ "$VERIFIED" == "true" ]]; then
    info "  $USERNAME — déjà vérifié, ignoré."
    continue
  fi
  if [[ -z "$EMAIL" || "$EMAIL" == "null" ]]; then
    warn "  $USERNAME — aucune adresse email, ignoré (ne pourra pas se connecter"
    warn "            si VERIFY_EMAIL=true : lui en attribuer une)."
    continue
  fi
  HTTP=$(curl -s -o /dev/null -w "%{http_code}" \
    -X PUT \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d '{"emailVerified": true}' \
    "$KC_URL/admin/realms/$REALM/users/$ID")
  if [[ "$HTTP" =~ ^2 ]]; then
    success "  $USERNAME <$EMAIL> — marqué vérifié."
    COUNT=$((COUNT + 1))
  else
    warn "  $USERNAME <$EMAIL> — échec (HTTP $HTTP)."
  fi
done < <(echo "$USERS" | jq -r '.[] | [.id, .username, (.email // ""), (.emailVerified | tostring)] | @tsv')

success "$COUNT compte(s) marqué(s) comme vérifié(s)."
