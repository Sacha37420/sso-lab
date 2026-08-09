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

USERS=$(curl -sf -H "Authorization: Bearer $TOKEN" \
  "$KC_URL/admin/realms/$REALM/users?max=1000")

# ── Passe 1 : adresses factices @ssolab.local — TOUJOURS, sans garde-fou ──────
# Une adresse @ssolab.local ne peut pas recevoir de courrier : le compte qui la
# porte resterait bloqué sur l'écran de vérification pour toujours. Un inscrit
# réel, lui, ne peut pas s'en attribuer une (il fournit une vraie adresse), donc
# valider celles-ci d'office ne contourne jamais la vérification de personne.
# C'est ce qui rend cette passe sûre même inscription ouverte — contrairement à
# la passe 2 ci-dessous.
#
# Indispensable pour les comptes de test E2E (e2e_member) : ils DOIVENT avoir un
# email, faute de quoi les APIs du lab rejettent leurs appels (le claim `email`
# est exigé, voir api/authentication.py) — mais cet email est nécessairement
# factice. Sans cette passe, leur donner une adresse les bloquerait au login,
# c'est-à-dire pire qu'avant.
FAKE_COUNT=0
while IFS=$'\t' read -r ID USERNAME EMAIL VERIFIED; do
  [[ -n "$ID" ]] || continue
  [[ "$VERIFIED" == "true" ]] && continue
  [[ "$EMAIL" == *"@ssolab.local" ]] || continue
  HTTP=$(curl -s -o /dev/null -w "%{http_code}" \
    -X PUT -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
    -d '{"emailVerified": true}' "$KC_URL/admin/realms/$REALM/users/$ID")
  if [[ "$HTTP" =~ ^2 ]]; then
    success "  $USERNAME <$EMAIL> — adresse factice, marquée vérifiée d'office."
    FAKE_COUNT=$((FAKE_COUNT + 1))
  else
    warn "  $USERNAME <$EMAIL> — échec (HTTP $HTTP)."
  fi
done < <(echo "$USERS" | jq -r '.[] | [.id, .username, (.email // ""), (.emailVerified | tostring)] | @tsv')
[[ $FAKE_COUNT -gt 0 ]] && success "$FAKE_COUNT compte(s) à adresse factice validé(s)."

# ── Passe 2 : adresses réelles ───────────────────────────────────────────────
# Garde-fou : si l'inscription est déjà ouverte, des comptes en attente de
# vérification peuvent exister — on ne les valide pas à l'aveugle.
REG_OPEN=$(curl -sf -H "Authorization: Bearer $TOKEN" \
  "$KC_URL/admin/realms/$REALM" | jq -r '.registrationAllowed')
if [[ "$REG_OPEN" == "true" && "$FORCE" != "true" ]]; then
  warn "L'inscription libre est déjà ouverte sur le realm '$REALM'."
  warn "Les adresses factices ci-dessus ont été validées (sans risque), mais les"
  warn "adresses RÉELLES non vérifiées sont laissées telles quelles : les valider"
  warn "d'office validerait aussi celles des inscrits en attente."
  warn "Relancer avec --force si c'est bien l'intention."
  exit 0
fi
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
    warn "            si VERIFY_EMAIL=true, ni appeler la moindre API du lab :"
    warn "            lui en attribuer une, factice si le compte est synthétique)."
    continue
  fi
  # Déjà traitée par la passe 1.
  [[ "$EMAIL" == *"@ssolab.local" ]] && continue
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
