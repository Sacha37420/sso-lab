#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# create-app-client.sh — Gestion idempotente du client Keycloak d'une application
#
# Pour chaque application :
#   1 — Vérifie le client Keycloak, le crée si absent
#   2 — Régénère le client secret → KEYCLOAK_CLIENT_SECRET dans <app>/.env
#   3 — Synchronise les redirect URIs (localhost, LAN, WAN)
#   4 — Vérifie la présence du Group Membership mapper (claim 'groups')
#   5 — Met à jour KEYCLOAK_* et PORT_KEYCLOAK dans <app>/.env
#
# Usage :
#   ./create-app-client.sh <nom-app> [options]
#
# Options :
#   --client-id <id>       clientId Keycloak si différent du nom du dossier
#                            Exemple : --client-id pgadmin  (dossier infra/)
#   --public               Client public / SPA (pas de secret). Défaut : confidentiel
#   --port <N>             Port de l'application (pour les redirect URIs)
#   --redirect-path <p>    Chemin OAuth2 de retour
#                            Défaut : /*  pour public
#                            Défaut : /login/oauth2/code/keycloak  pour confidentiel
#   --lan-ip <IP>          IP LAN (priorité sur SERVER_URL_LAN dans infra/.env)
#   --wan-ip <IP>          IP WAN (skip l'auto-détection via ipify)
#   --no-wan               Désactive l'ajout des URIs WAN
#   --no-rotate            Conserve le secret existant (ne régénère pas)
#
# Prérequis :
#   - sso-lab/.env rempli (KEYCLOAK_ADMIN_PASSWORD au minimum)
#   - curl, jq, openssl installés
#   - Keycloak accessible sur KEYCLOAK_HOSTNAME_URL
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

# ── Couleurs ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}→${NC} $*"; }
success() { echo -e "${GREEN}✓${NC} $*"; }
warn()    { echo -e "${YELLOW}⚠${NC} $*"; }
die()     { echo -e "${RED}✗ Erreur :${NC} $*" >&2; exit 1; }

# ── Aide ──────────────────────────────────────────────────────────────────────
usage() {
  echo "Usage : $0 <nom-app> [options]"
  echo ""
  echo "  <nom-app>              Identifiant du client Keycloak (= nom du dossier dans dev/)"
  echo "  --client-id <id>       clientId Keycloak (si différent du nom du dossier)"
  echo "  --public               Client public / SPA (Angular, React…). Défaut : confidentiel"
  echo "  --port <N>             Port applicatif (pour les redirect URIs)"
  echo "  --redirect-path <p>    Chemin de retour OAuth2"
  echo "  --lan-ip <IP>          Surcharge SERVER_URL_LAN de infra/.env"
  echo "  --wan-ip <IP>          IP WAN (skip auto-détection)"
  echo "  --no-wan               Ne pas ajouter d'URIs WAN"
  echo "  --no-rotate            Conserver le secret existant"
  echo "  --require-group <g>    Crée un rôle realm <g>-member et l'assigne au groupe <g>"
  echo ""
  echo "Exemples :"
  echo "  $0 mon-api --port 8083"
  echo "  $0 mon-front --public --port 4201"
  echo "  $0 mon-api --no-rotate --port 8083"
  echo "  $0 infra --client-id pgadmin --port 5050"
  exit 1
}

# ── Arguments ─────────────────────────────────────────────────────────────────

# Mode tout-en-un : aucun argument ou premier argument '*'
# → crée les clients pour chaque dossier contenant un docker-compose.yml, sauf sso-lab
if [[ $# -lt 1 ]] || [[ "${1:-}" == "*" ]]; then
  _sd="$(cd "$(dirname "$0")/.." && pwd)"
  [[ $# -gt 0 ]] && shift   # consomme le '*' si présent
  _found=0
  while IFS= read -r _compose; do
    _name="$(basename "$(dirname "$_compose")")"
    [[ "$_name" == "sso-lab" ]] && continue
    _found=$(( _found + 1 ))
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  APP : $_name"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    # Lire les options spécifiques à l'app depuis .keycloak-client-opts
    _app_opts=()
    _opts_file="$(dirname "$_compose")/.keycloak-client-opts"
    if [[ -f "$_opts_file" ]]; then
      while IFS= read -r _opt_line || [[ -n "$_opt_line" ]]; do
        # Ignorer lignes vides et commentaires
        [[ -z "$_opt_line" || "$_opt_line" == \#* ]] && continue
        # shellcheck disable=SC2206
        _app_opts+=( $_opt_line )
      done < "$_opts_file"
    fi
    "$0" "$_name" "${_app_opts[@]+"${_app_opts[@]}"}" "$@" || true   # continue même si une app échoue
  done < <(find "$_sd" -mindepth 2 -maxdepth 2 -name "docker-compose.yml" ! -path "*/_templates/*" | sort)
  [[ $_found -eq 0 ]] && echo "Aucun dossier d'application trouvé dans $_sd"
  exit 0
fi

[[ "${1:-}" == "--help" || "${1:-}" == "-h" ]] && usage

APP_NAME="$1"; shift

# Lire les options depuis .keycloak-client-opts si présent et si aucune option extra n'est passée
_SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
_OPTS_FILE="${_SCRIPT_DIR}/${APP_NAME}/.keycloak-client-opts"
if [[ -f "$_OPTS_FILE" && $# -eq 0 ]]; then
  _extra_opts=()
  while IFS= read -r _opt_line || [[ -n "$_opt_line" ]]; do
    [[ -z "$_opt_line" || "$_opt_line" == \#* ]] && continue
    # shellcheck disable=SC2206
    _extra_opts+=( $_opt_line )
  done < "$_OPTS_FILE"
  if [[ ${#_extra_opts[@]} -gt 0 ]]; then
    set -- "${_extra_opts[@]}"
  fi
fi

CLIENT_TYPE="confidential"
CLIENT_ID=""
APP_PORT=""
REDIRECT_PATH=""
OVERRIDE_LAN_IP=""
OVERRIDE_WAN_IP=""
NO_WAN=false
ROTATE=true
REQUIRE_GROUP=""
CADDY_PATH=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --client-id)       [[ $# -gt 1 ]] || die "--client-id requiert une valeur"; CLIENT_ID="$2"; shift ;;
    --public)          CLIENT_TYPE="public" ;;
    --port)            [[ $# -gt 1 ]] || die "--port requiert une valeur"; APP_PORT="$2"; shift ;;
    --redirect-path)   [[ $# -gt 1 ]] || die "--redirect-path requiert une valeur"; REDIRECT_PATH="$2"; shift ;;
    --lan-ip)          [[ $# -gt 1 ]] || die "--lan-ip requiert une valeur"; OVERRIDE_LAN_IP="$2"; shift ;;
    --wan-ip)          [[ $# -gt 1 ]] || die "--wan-ip requiert une valeur"; OVERRIDE_WAN_IP="$2"; shift ;;
    --no-wan)          NO_WAN=true ;;
    --no-rotate)       ROTATE=false ;;
    --require-group)   [[ $# -gt 1 ]] || die "--require-group requiert une valeur"; REQUIRE_GROUP="$2"; shift ;;
    --caddy-path)      [[ $# -gt 1 ]] || die "--caddy-path requiert une valeur"; CADDY_PATH="$2"; shift ;;
    --caddy-subdomain) [[ $# -gt 1 ]] || die "--caddy-subdomain requiert une valeur"; CADDY_PATH="$2"; shift ;;  # alias rétrocompat
    --help|-h)         usage ;;
    *)                 die "Argument inconnu : '$1'" ;;
  esac
  shift
done

# CLIENT_ID par défaut = nom du dossier (cas spring-app, front-cadriciel…)
# Surcharge via --client-id pour les cas où ils divergent (ex: infra → pgadmin)
[[ -n "$CLIENT_ID" ]] || CLIENT_ID="$APP_NAME"
[[ "$CLIENT_ID" =~ ^[a-zA-Z0-9_-]+$ ]] \
  || die "client-id invalide : '$CLIENT_ID'"

[[ "$APP_NAME" =~ ^[a-zA-Z0-9_-]+$ ]] \
  || die "Nom invalide : '$APP_NAME' (alphanumérique, tirets et underscores uniquement)"


# ── Chemins ───────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SSO_ENV_FILE="$SCRIPT_DIR/sso-lab/.env"
INFRA_ENV_FILE="$SCRIPT_DIR/infra/.env"
APP_DIR="$SCRIPT_DIR/$APP_NAME"
APP_ENV="$APP_DIR/.env"

# ── Extraction d'une valeur depuis un fichier .env ────────────────────────────
# Usage : _env_val <fichier> <clé> [<défaut>]
_env_val() {
  local file="$1" key="$2" default="${3:-}"
  local val=""
  if [[ -f "$file" ]]; then
    val=$(grep -E "^${key}=" "$file" 2>/dev/null \
          | head -1 \
          | cut -d= -f2- \
          | sed 's/[[:space:]]*#.*//' \
          | sed "s/^['\"]//; s/['\"]$//" \
          | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
  fi
  echo "${val:-$default}"
}

# ── Normalisation d'un booléen .env en littéral JSON ──────────────────────────
# Tolère true/1/yes/oui/o ; tout le reste vaut false. Garantit une valeur que
# `jq --argjson` accepte (une saisie libre du .env la ferait échouer).
_bool() {
  case "${1,,}" in
    true|1|yes|y|oui|o) echo "true" ;;
    *)                  echo "false" ;;
  esac
}

# ── Encodage URL d'un composant de chemin/query ───────────────────────────────
# Les alias de flow et noms de groupe peuvent contenir des caractères à échapper.
_urlenc() {
  python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1" \
    2>/dev/null || echo "$1"
}

# ── Mise à jour idempotente d'une variable dans un fichier .env ───────────────
# Usage : upsert_env <fichier> <clé> <valeur>
# Remplace la ligne KEY=... existante (+ éventuelles lignes orphelines suivantes
# issues d'une écriture corrompue) ou ajoute la clé en fin de fichier.
upsert_env() {
  local file="$1" key="$2" value="$3"
  [[ -f "$file" ]] || touch "$file"
  if grep -qE "^${key}=" "$file" 2>/dev/null; then
    # awk : remplace la ligne KEY= et saute les lignes orphelines qui suivent
    # (lignes qui ne ressemblent pas à une entrée .env valide ni à un commentaire)
    awk -v key="$key" -v val="$value" '
      $0 ~ ("^" key "=") { print key "=" val; skip=1; next }
      skip && (/^[A-Za-z_]+=/ || /^#/ || /^[[:space:]]*$/) { skip=0 }
      skip { next }
      { print }
    ' "$file" > "${file}.tmp" && mv "${file}.tmp" "$file"
  else
    printf '\n%s=%s\n' "$key" "$value" >> "$file"
  fi
}

# ── Vérifications des dépendances ─────────────────────────────────────────────
for cmd in curl jq openssl; do
  command -v "$cmd" &>/dev/null || die "'$cmd' est requis (apt install $cmd)"
done

# ── Charger les variables de configuration ────────────────────────────────────
[[ -f "$SSO_ENV_FILE" ]] \
  || die "$SSO_ENV_FILE introuvable.\nCopiez sso-lab/.env.example → sso-lab/.env et remplissez les valeurs."

ADMIN_USER=$(_env_val   "$SSO_ENV_FILE" "KEYCLOAK_ADMIN"         "admin")
ADMIN_PASS=$(_env_val   "$SSO_ENV_FILE" "KEYCLOAK_ADMIN_PASSWORD" "")
REALM="ssolab"

[[ -n "$ADMIN_PASS" ]] || die "KEYCLOAK_ADMIN_PASSWORD vide dans $SSO_ENV_FILE"

# Port Keycloak — source de vérité : PORT_KEYCLOAK dans sso-lab/.env
KC_PORT=$(_env_val "$SSO_ENV_FILE" "PORT_KEYCLOAK" "8080")
KC_PORT="${KC_PORT:-8080}"

# URL admin (appels curl) : localhost depuis le host, keycloak depuis un container Docker
# (hairpin NAT non supporté sur Bbox ; KEYCLOAK_HOSTNAME_URL passe par le WAN)
if [ -f /.dockerenv ]; then
  KEYCLOAK_URL="http://keycloak:${KC_PORT}"
else
  KEYCLOAK_URL="http://localhost:${KC_PORT}"
fi

# URL publique (écrite dans le .env de l'app) : ce que Django/Angular utilisent
# pour valider les JWT — doit correspondre à l'iss des tokens émis par Keycloak
KEYCLOAK_PUBLIC_URL=$(_env_val "$SSO_ENV_FILE" "KEYCLOAK_HOSTNAME_URL" "http://localhost:${KC_PORT}")

# ── IP LAN ────────────────────────────────────────────────────────────────────
LAN_IP=""
if [[ -n "$OVERRIDE_LAN_IP" ]]; then
  LAN_IP="$OVERRIDE_LAN_IP"
else
  _lan_url=$(_env_val "$INFRA_ENV_FILE" "SERVER_URL_LAN" "")
  if [[ -n "$_lan_url" ]]; then
    LAN_IP="${_lan_url#http://}"; LAN_IP="${LAN_IP#https://}"
    LAN_IP="${LAN_IP%%/*}";       LAN_IP="${LAN_IP%%:*}"
  fi
fi

# ── IP WAN ────────────────────────────────────────────────────────────────────
WAN_IP=""
if ! $NO_WAN; then
  if [[ -n "$OVERRIDE_WAN_IP" ]]; then
    WAN_IP="$OVERRIDE_WAN_IP"
  else
    _wan_url=$(_env_val "$INFRA_ENV_FILE" "SERVER_URL_WAN" "")
    if [[ -n "$_wan_url" ]]; then
      WAN_IP="${_wan_url#http://}"; WAN_IP="${WAN_IP#https://}"
      WAN_IP="${WAN_IP%%/*}";       WAN_IP="${WAN_IP%%:*}"
    else
      info "Auto-détection de l'IP WAN (ipify.org)..."
      WAN_IP=$(curl -sf --max-time 5 https://api.ipify.org 2>/dev/null || true)
      if [[ -n "$WAN_IP" ]]; then
        success "IP WAN détectée : $WAN_IP"
      else
        warn "IP WAN non disponible — URIs WAN ignorées (--wan-ip <IP> ou --no-wan pour supprimer ce message)"
      fi
    fi
  fi
fi

# ── Port applicatif (lecture depuis <app>/.env si --port non fourni) ──────────
if [[ -z "$APP_PORT" && -f "$APP_ENV" ]]; then
  # Support multiple naming conventions across templates: try common variants
  for _var in PORT_APP BACKEND_PORT PORT_FRONT FRONTEND_PORT PORT_BACK PORT_FRONTEND PORT_BACKEND; do
    _p=$(_env_val "$APP_ENV" "$_var" "")
    if [[ -n "$_p" && "$_p" =~ ^[0-9]+$ ]]; then
      APP_PORT="$_p"
      info "Port lu depuis $APP_ENV : $APP_PORT ($_var)"
      break
    fi
  done
fi

# ── Chemin de redirection par défaut ─────────────────────────────────────────
if [[ -z "$REDIRECT_PATH" ]]; then
  [[ "$CLIENT_TYPE" == "public" ]] \
    && REDIRECT_PATH="/*" \
    || REDIRECT_PATH="/login/oauth2/code/keycloak"
fi

# ── Récapitulatif ─────────────────────────────────────────────────────────────
echo ""
echo "  Application   : $APP_NAME"
echo "  Client ID     : $CLIENT_ID"
echo "  Type client   : $CLIENT_TYPE"
echo "  Port          : ${APP_PORT:-— (redirect URIs non calculées, utiliser --port)}"
echo "  Redirect path : $REDIRECT_PATH"
echo "  LAN IP        : ${LAN_IP:-—}"
echo "  WAN IP        : ${WAN_IP:-—}"
echo "  Keycloak admin : $KEYCLOAK_URL  (appels API — localhost)"
echo "  Keycloak public: $KEYCLOAK_PUBLIC_URL  (écrit dans .env — realm: $REALM)"
echo "  .env cible    : $APP_ENV"
echo ""

# ── Token admin Keycloak ──────────────────────────────────────────────────────
info "Authentification admin Keycloak..."

TOKEN_RESPONSE=$(curl -sf \
  --data-urlencode "client_id=admin-cli" \
  --data-urlencode "username=$ADMIN_USER" \
  --data-urlencode "password=$ADMIN_PASS" \
  --data-urlencode "grant_type=password" \
  "$KEYCLOAK_URL/realms/master/protocol/openid-connect/token") \
  || die "Impossible de joindre Keycloak sur $KEYCLOAK_URL"

ACCESS_TOKEN=$(echo "$TOKEN_RESPONSE" | jq -r '.access_token // empty')
[[ -n "$ACCESS_TOKEN" ]] || die "Authentification échouée. Vérifiez KEYCLOAK_ADMIN_PASSWORD."
success "Token obtenu."

# ══════════════════════════════════════════════════════════════════════════════
# 0/5 — Vérifier / créer le realm, la fédération LDAP et le group mapper
#        Chaque étape est indépendante et idempotente.
# ══════════════════════════════════════════════════════════════════════════════
info "0/5 — Vérification du realm '$REALM'..."

REALM_EXISTS=$(curl -s \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  "$KEYCLOAK_URL/admin/realms/$REALM" 2>/dev/null | jq -r '.realm // empty')

if [[ -n "$REALM_EXISTS" ]]; then
  success "Realm '$REALM' existant."
else
  info "Realm '$REALM' absent — création en cours..."

  REALM_PAYLOAD=$(jq -n --arg r "$REALM" '{
    realm:                   $r,
    displayName:             "SSO Lab",
    enabled:                 true,
    sslRequired:             "none",
    registrationAllowed:     false,
    loginWithEmailAllowed:   true,
    duplicateEmailsAllowed:  false,
    resetPasswordAllowed:    true,
    editUsernameAllowed:     false,
    bruteForceProtected:     false,
    accessTokenLifespan:     3600,
    ssoSessionIdleTimeout:   43200,
    ssoSessionMaxLifespan:   86400
  }')

  HTTP_STATUS=$(curl -s -o /tmp/_kc_realm.json -w "%{http_code}" \
    -X POST \
    -H "Authorization: Bearer $ACCESS_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$REALM_PAYLOAD" \
    "$KEYCLOAK_URL/admin/realms")
  [[ "$HTTP_STATUS" == "201" ]] \
    || die "Création du realm échouée (HTTP $HTTP_STATUS) : $(cat /tmp/_kc_realm.json)"
  success "Realm '$REALM' créé."
fi

# ── Réglages realm idempotents : inscription, « mot de passe oublié », SMTP ───
#   Appliqués à chaque exécution, donc aussi sur un realm déjà existant : c'est
#   ici — et non dans le payload de création ci-dessus, qui ne joue qu'une fois
#   dans la vie du realm — qu'il faut toucher aux réglages de login.
SMTP_FROM_VAL=$(_env_val "$SSO_ENV_FILE" "SMTP_FROM" "")
SMTP_PASS_CHECK=$(_env_val "$SSO_ENV_FILE" "SMTP_PASSWORD" "")
REGISTRATION_VAL=$(_bool "$(_env_val "$SSO_ENV_FILE" "REGISTRATION_ALLOWED" "false")")
VERIFY_EMAIL_VAL=$(_bool "$(_env_val "$SSO_ENV_FILE" "VERIFY_EMAIL" "true")")

# Un SMTP incomplet n'envoie rien. Or « inscription » et « vérification d'email »
# enferment l'utilisateur dehors si le mail ne part pas : le nouvel inscrit reste
# bloqué sur « vérifiez votre email », et TOUT compte existant à emailVerified=false
# se voit réclamer une validation impossible à la connexion suivante. On désactive
# donc les deux tant que le SMTP n'est pas réellement utilisable.
#   Un relais local sans authentification est légitime (SMTP_USER vide) : on
#   n'exige un mot de passe que si un utilisateur SMTP est déclaré.
SMTP_USER_CHECK=$(_env_val "$SSO_ENV_FILE" "SMTP_USER" "")
SMTP_READY=true
[[ -z "$SMTP_FROM_VAL" ]] && SMTP_READY=false
[[ -n "$SMTP_USER_CHECK" && -z "$SMTP_PASS_CHECK" ]] && SMTP_READY=false
if [[ "$SMTP_READY" != "true" ]]; then
  if [[ "$REGISTRATION_VAL" == "true" || "$VERIFY_EMAIL_VAL" == "true" ]]; then
    warn "  SMTP incomplet dans sso-lab/.env (SMTP_FROM et/ou SMTP_PASSWORD vide)."
    warn "  → inscription et vérification d'email laissées désactivées."
  fi
  REGISTRATION_VAL="false"
  VERIFY_EMAIL_VAL="false"
fi

REALM_LOGIN_PAYLOAD=$(jq -n \
  --argjson registration "$REGISTRATION_VAL" \
  --argjson verify "$VERIFY_EMAIL_VAL" \
  '{
    resetPasswordAllowed: true,
    registrationAllowed:  $registration,
    verifyEmail:          $verify
  }')

if [[ "$SMTP_READY" == "true" ]]; then
  info "  Configuration SMTP du realm (from: $SMTP_FROM_VAL)..."
  SMTP_HOST_VAL=$(_env_val "$SSO_ENV_FILE" "SMTP_HOST" "smtp.gmail.com")
  SMTP_PORT_VAL=$(_env_val "$SSO_ENV_FILE" "SMTP_PORT" "587")
  SMTP_USER_VAL=$(_env_val "$SSO_ENV_FILE" "SMTP_USER" "")
  SMTP_PASS_VAL=$(_env_val "$SSO_ENV_FILE" "SMTP_PASSWORD" "")
  SMTP_DISP_VAL=$(_env_val "$SSO_ENV_FILE" "SMTP_FROM_DISPLAY" "SSO Lab")
  SMTP_STARTTLS_VAL=$(_env_val "$SSO_ENV_FILE" "SMTP_STARTTLS" "true")
  SMTP_SSL_VAL=$(_env_val "$SSO_ENV_FILE" "SMTP_SSL" "false")
  [[ -n "$SMTP_USER_VAL" ]] && SMTP_AUTH_VAL="true" || SMTP_AUTH_VAL="false"

  REALM_LOGIN_PAYLOAD=$(echo "$REALM_LOGIN_PAYLOAD" | jq \
    --arg host "$SMTP_HOST_VAL" --arg port "$SMTP_PORT_VAL" \
    --arg from "$SMTP_FROM_VAL" --arg disp "$SMTP_DISP_VAL" \
    --arg user "$SMTP_USER_VAL" --arg pass "$SMTP_PASS_VAL" \
    --arg starttls "$SMTP_STARTTLS_VAL" --arg ssl "$SMTP_SSL_VAL" \
    --arg auth "$SMTP_AUTH_VAL" \
    '. + {
      smtpServer: {
        host: $host, port: $port, from: $from, fromDisplayName: $disp,
        starttls: $starttls, ssl: $ssl, auth: $auth, user: $user, password: $pass
      }
    }')
else
  info "  SMTP non configuré (SMTP_FROM vide dans sso-lab/.env) — « mot de passe oublié » sans envoi d'email."
fi

info "  Réglages de login du realm (inscription: $REGISTRATION_VAL, vérification email: $VERIFY_EMAIL_VAL)..."
LOGIN_HTTP=$(curl -s -o /tmp/_kc_login.json -w "%{http_code}" \
  -X PUT \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H "Content-Type: application/json" \
  -d "$REALM_LOGIN_PAYLOAD" \
  "$KEYCLOAK_URL/admin/realms/$REALM")
[[ "$LOGIN_HTTP" =~ ^2 ]] \
  && success "  Réglages de login du realm appliqués." \
  || warn    "  Réglages de login du realm : HTTP $LOGIN_HTTP — $(cat /tmp/_kc_login.json)"

# ── Fédération LDAP (vérifiée à chaque exécution) ─────────────────────────────
info "  Vérification du provider LDAP..."

LDAP_ADMIN_PASS=$(_env_val "$SSO_ENV_FILE" "LDAP_ADMIN_PASSWORD" "")
LDAP_DOMAIN_VAL=$(_env_val "$SSO_ENV_FILE" "LDAP_DOMAIN" "ssolab.local")
# dc=ssolab,dc=local ← calculé depuis LDAP_DOMAIN
LDAP_BASE_DN=$(echo "$LDAP_DOMAIN_VAL" \
  | awk -F'.' '{for(i=1;i<=NF;i++) printf "dc=" $i (i<NF ? "," : "\n")}')

[[ -n "$LDAP_ADMIN_PASS" ]] \
  || die "LDAP_ADMIN_PASSWORD vide dans $SSO_ENV_FILE — requis pour configurer la fédération LDAP."

REALM_UUID=$(curl -sf \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  "$KEYCLOAK_URL/admin/realms/$REALM" | jq -r '.id')
[[ -n "$REALM_UUID" ]] || die "Impossible de récupérer l'UUID du realm '$REALM'."

LDAP_PROVIDER_ID=$(curl -sf \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  "$KEYCLOAK_URL/admin/realms/$REALM/components" \
  | jq -r '[.[] | select(.providerType == "org.keycloak.storage.UserStorageProvider" and .name == "ldap")] | .[0].id // empty')

if [[ -n "$LDAP_PROVIDER_ID" ]]; then
  success "  Provider LDAP existant (ID: $LDAP_PROVIDER_ID)."
else
  info "  Provider LDAP absent — création en cours..."

  LDAP_PROVIDER_PAYLOAD=$(jq -n \
    --arg base_dn   "$LDAP_BASE_DN" \
    --arg bind_pass "$LDAP_ADMIN_PASS" \
    --arg realm_id  "$REALM_UUID" \
    '{
      name:         "ldap",
      providerId:   "ldap",
      providerType: "org.keycloak.storage.UserStorageProvider",
      parentId:     $realm_id,
      config: {
        enabled:                     ["true"],
        priority:                    ["0"],
        fullSyncPeriod:              ["-1"],
        changedSyncPeriod:           ["-1"],
        cachePolicy:                 ["DEFAULT"],
        editMode:                    ["WRITABLE"],
        vendor:                      ["other"],
        usernameLDAPAttribute:       ["uid"],
        rdnLDAPAttribute:            ["uid"],
        uuidLDAPAttribute:           ["entryUUID"],
        userObjectClasses:           ["inetOrgPerson, shadowAccount"],
        connectionUrl:               ["ldap://openldap:389"],
        usersDn:                     [("ou=people," + $base_dn)],
        authType:                    ["simple"],
        bindDn:                      [("cn=admin," + $base_dn)],
        bindCredential:              [$bind_pass],
        searchScope:                 ["1"],
        useTruststoreSpi:            ["never"],
        connectionPooling:           ["true"],
        pagination:                  ["true"],
        allowKerberosAuthentication: ["false"],
        debug:                       ["false"],
        importEnabled:               ["true"],
        syncRegistrations:           ["false"],
        validatePasswordPolicy:      ["false"],
        trustEmail:                  ["false"]
      }
    }')

  LDAP_HTTP=$(curl -s -o /tmp/_kc_ldap.json -w "%{http_code}" \
    -X POST \
    -H "Authorization: Bearer $ACCESS_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$LDAP_PROVIDER_PAYLOAD" \
    "$KEYCLOAK_URL/admin/realms/$REALM/components")
  [[ "$LDAP_HTTP" == "201" ]] \
    || die "Configuration LDAP échouée (HTTP $LDAP_HTTP) : $(cat /tmp/_kc_ldap.json)"

  LDAP_PROVIDER_ID=$(curl -sf \
    -H "Authorization: Bearer $ACCESS_TOKEN" \
    "$KEYCLOAK_URL/admin/realms/$REALM/components" \
    | jq -r '[.[] | select(.providerType == "org.keycloak.storage.UserStorageProvider" and .name == "ldap")] | .[0].id // empty')
  [[ -n "$LDAP_PROVIDER_ID" ]] || die "Impossible de récupérer l'ID du provider LDAP après création."
  success "  Provider LDAP créé (ID: $LDAP_PROVIDER_ID)."

  # Synchronisation initiale des utilisateurs (uniquement à la création du provider)
  info "  Synchronisation initiale des utilisateurs depuis LDAP..."
  SYNC_HTTP=$(curl -s -o /tmp/_kc_sync.json -w "%{http_code}" \
    -X POST \
    -H "Authorization: Bearer $ACCESS_TOKEN" \
    "$KEYCLOAK_URL/admin/realms/$REALM/user-storage/$LDAP_PROVIDER_ID/sync?action=triggerFullSync")
  [[ "$SYNC_HTTP" =~ ^2 ]] \
    && success "  Synchronisation utilisateurs terminée." \
    || warn    "  Synchronisation utilisateurs : HTTP $SYNC_HTTP — $(cat /tmp/_kc_sync.json)"
fi

# ── Forcer editMode=WRITABLE + syncRegistrations sur le provider LDAP ─────────
#   editMode=WRITABLE : indispensable pour que « mot de passe oublié » puisse
#     réécrire le mot de passe dans LDAP. Corrige un provider resté en READ_ONLY.
#   syncRegistrations  : sans lui, un compte auto-créé atterrit dans la base
#     interne de Keycloak et non dans l'annuaire — invisible de phpLDAPadmin.
#     Les mappers par défaut couvrent les attributs obligatoires d'inetOrgPerson
#     (cn ← prénom, sn ← nom), que le formulaire d'inscription exige déjà.
LDAP_COMPONENT=$(curl -sf \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  "$KEYCLOAK_URL/admin/realms/$REALM/components/$LDAP_PROVIDER_ID")
CURRENT_EDIT_MODE=$(echo "$LDAP_COMPONENT" | jq -r '.config.editMode[0] // empty')
CURRENT_SYNC_REG=$(echo "$LDAP_COMPONENT" | jq -r '.config.syncRegistrations[0] // empty')
if [[ "$CURRENT_EDIT_MODE" != "WRITABLE" || "$CURRENT_SYNC_REG" != "true" ]]; then
  info "  Provider LDAP → editMode=WRITABLE, syncRegistrations=true (était: ${CURRENT_EDIT_MODE:-?} / ${CURRENT_SYNC_REG:-?})..."
  LDAP_WRITABLE_PAYLOAD=$(echo "$LDAP_COMPONENT" \
    | jq '.config.editMode = ["WRITABLE"] | .config.syncRegistrations = ["true"]')
  EM_HTTP=$(curl -s -o /tmp/_kc_editmode.json -w "%{http_code}" \
    -X PUT \
    -H "Authorization: Bearer $ACCESS_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$LDAP_WRITABLE_PAYLOAD" \
    "$KEYCLOAK_URL/admin/realms/$REALM/components/$LDAP_PROVIDER_ID")
  [[ "$EM_HTTP" =~ ^2 ]] \
    && success "  Provider LDAP en WRITABLE + syncRegistrations." \
    || warn    "  Provider LDAP : HTTP $EM_HTTP — $(cat /tmp/_kc_editmode.json)"
else
  success "  Provider LDAP déjà en WRITABLE + syncRegistrations."
fi

# ── Group Mapper LDAP → Keycloak (vérifié à chaque exécution) ─────────────────
info "  Vérification du Group Mapper LDAP..."

GROUP_MAPPER_KC_ID=$(curl -sf \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  "$KEYCLOAK_URL/admin/realms/$REALM/components?parent=$LDAP_PROVIDER_ID" \
  | jq -r '[.[] | select(.providerType == "org.keycloak.storage.ldap.mappers.LDAPStorageMapper" and .name == "groups")] | .[0].id // empty')

if [[ -n "$GROUP_MAPPER_KC_ID" ]]; then
  success "  Group Mapper LDAP existant (ID: $GROUP_MAPPER_KC_ID)."
else
  info "  Group Mapper absent — création en cours..."

  GROUP_MAPPER_PAYLOAD=$(jq -n \
    --arg parent  "$LDAP_PROVIDER_ID" \
    --arg base_dn "$LDAP_BASE_DN" \
    '{
      name:         "groups",
      providerId:   "group-ldap-mapper",
      providerType: "org.keycloak.storage.ldap.mappers.LDAPStorageMapper",
      parentId:     $parent,
      config: {
        "groups.dn":                            [("ou=groups," + $base_dn)],
        "group.name.ldap.attribute":            ["cn"],
        "group.object.classes":                 ["groupOfNames"],
        "preserve.group.inheritance":           ["true"],
        "ignore.missing.groups":                ["false"],
        "membership.ldap.attribute":            ["member"],
        "membership.attribute.type":            ["DN"],
        "groups.path":                          ["/"],
        "mode":                                 ["LDAP_ONLY"],
        "user.roles.retrieve.strategy":         ["LOAD_GROUPS_BY_MEMBER_ATTRIBUTE"],
        "drop.non.existing.groups.during.sync": ["false"]
      }
    }')

  GRP_HTTP=$(curl -s -o /tmp/_kc_grpmap.json -w "%{http_code}" \
    -X POST \
    -H "Authorization: Bearer $ACCESS_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$GROUP_MAPPER_PAYLOAD" \
    "$KEYCLOAK_URL/admin/realms/$REALM/components")
  case "$GRP_HTTP" in
    201) ;;
    409) ;;
    *)   warn "  Group Mapper : HTTP $GRP_HTTP — $(cat /tmp/_kc_grpmap.json)" ;;
  esac

  GROUP_MAPPER_KC_ID=$(curl -sf \
    -H "Authorization: Bearer $ACCESS_TOKEN" \
    "$KEYCLOAK_URL/admin/realms/$REALM/components?parent=$LDAP_PROVIDER_ID" \
    | jq -r '[.[] | select(.providerType == "org.keycloak.storage.ldap.mappers.LDAPStorageMapper" and .name == "groups")] | .[0].id // empty')
  success "  Group Mapper LDAP créé (ID: ${GROUP_MAPPER_KC_ID:-?})."

  # Synchronisation initiale des groupes (uniquement à la création du mapper)
  if [[ -n "$GROUP_MAPPER_KC_ID" ]]; then
    info "  Synchronisation initiale des groupes depuis LDAP..."
    GRP_SYNC_HTTP=$(curl -s -o /tmp/_kc_grpsync.json -w "%{http_code}" \
      -X POST \
      -H "Authorization: Bearer $ACCESS_TOKEN" \
      "$KEYCLOAK_URL/admin/realms/$REALM/user-storage/$LDAP_PROVIDER_ID/mappers/$GROUP_MAPPER_KC_ID/sync?direction=fedToKeycloak")
    [[ "$GRP_SYNC_HTTP" =~ ^2 ]] \
      && success "  Synchronisation groupes terminée." \
      || warn    "  Synchronisation groupes : HTTP $GRP_SYNC_HTTP — $(cat /tmp/_kc_grpsync.json)"
  fi
fi

# ── Forcer mode=LDAP_ONLY sur le Group Mapper (idempotent) ────────────────────
#   Permet à Keycloak d'écrire l'appartenance aux groupes dans le LDAP (member),
#   donc de gérer les rôles depuis une app (ex. restauration). Corrige un mapper
#   déjà existant resté en READ_ONLY (ou en valeur invalide).
#   NB : pour un group-mapper le mode « écriture » est LDAP_ONLY (≠ editMode du
#   provider qui, lui, vaut WRITABLE) — l'enum LDAPGroupMapperMode n'a pas WRITABLE.
if [[ -n "$GROUP_MAPPER_KC_ID" ]]; then
  GM_COMPONENT=$(curl -sf \
    -H "Authorization: Bearer $ACCESS_TOKEN" \
    "$KEYCLOAK_URL/admin/realms/$REALM/components/$GROUP_MAPPER_KC_ID")
  GM_MODE=$(echo "$GM_COMPONENT" | jq -r '.config.mode[0] // empty')
  if [[ "$GM_MODE" != "LDAP_ONLY" ]]; then
    info "  Passage du Group Mapper en mode=LDAP_ONLY (était: ${GM_MODE:-?})..."
    GM_PAYLOAD=$(echo "$GM_COMPONENT" | jq '.config.mode = ["LDAP_ONLY"]')
    GM_HTTP=$(curl -s -o /tmp/_kc_gmmode.json -w "%{http_code}" \
      -X PUT \
      -H "Authorization: Bearer $ACCESS_TOKEN" \
      -H "Content-Type: application/json" \
      -d "$GM_PAYLOAD" \
      "$KEYCLOAK_URL/admin/realms/$REALM/components/$GROUP_MAPPER_KC_ID")
    [[ "$GM_HTTP" =~ ^2 ]] \
      && success "  Group Mapper en LDAP_ONLY." \
      || warn    "  Group Mapper LDAP_ONLY : HTTP $GM_HTTP — $(cat /tmp/_kc_gmmode.json)"
  else
    success "  Group Mapper déjà en LDAP_ONLY."
  fi
fi

# ══════════════════════════════════════════════════════════════════════════════
# 1/5 — Vérifier / créer le client
# ══════════════════════════════════════════════════════════════════════════════
info "1/5 — Vérification du client '$CLIENT_ID'..."

CLIENT_UUID=$(curl -sf \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  "$KEYCLOAK_URL/admin/realms/$REALM/clients?clientId=$CLIENT_ID" \
  | jq -r '.[0].id // empty')

if [[ -n "$CLIENT_UUID" ]]; then
  success "Client existant (UUID: $CLIENT_UUID)."
else
  info "Client absent — création en cours..."

  [[ "$CLIENT_TYPE" == "public" ]] && IS_PUBLIC="true" || IS_PUBLIC="false"

  CLIENT_PAYLOAD=$(jq -n \
    --arg     cid "$CLIENT_ID" \
    --argjson pub "$IS_PUBLIC" \
    '{
      clientId:                  $cid,
      name:                      $cid,
      enabled:                   true,
      protocol:                  "openid-connect",
      publicClient:              $pub,
      clientAuthenticatorType:   "client-secret",
      standardFlowEnabled:       true,
      directAccessGrantsEnabled: false,
      serviceAccountsEnabled:    false,
      redirectUris:              ["*"],
      webOrigins:                ["*"],
      attributes: { "post.logout.redirect.uris": "+" }
    }')

  HTTP_STATUS=$(curl -s -o /tmp/_kc_create.json -w "%{http_code}" \
    -X POST \
    -H "Authorization: Bearer $ACCESS_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$CLIENT_PAYLOAD" \
    "$KEYCLOAK_URL/admin/realms/$REALM/clients")

  [[ "$HTTP_STATUS" == "201" ]] \
    || die "Création du client échouée (HTTP $HTTP_STATUS) : $(cat /tmp/_kc_create.json)"

  CLIENT_UUID=$(curl -sf \
    -H "Authorization: Bearer $ACCESS_TOKEN" \
    "$KEYCLOAK_URL/admin/realms/$REALM/clients?clientId=$CLIENT_ID" \
    | jq -r '.[0].id // empty')

  [[ -n "$CLIENT_UUID" ]] || die "UUID introuvable après création."
  success "Client créé (UUID: $CLIENT_UUID)."
fi

# ══════════════════════════════════════════════════════════════════════════════
# 2/5 — Secret client (confidentiel uniquement)
# ══════════════════════════════════════════════════════════════════════════════
info "2/5 — Gestion du secret..."

CLIENT_SECRET=""
if [[ "$CLIENT_TYPE" == "confidential" ]]; then
  mkdir -p "$APP_DIR"

  if $ROTATE; then
    # POST sans body : Keycloak génère lui-même le secret et le retourne dans la réponse.
    # Ne pas envoyer de {"value": ...} — Keycloak l'ignore et génère le sien,
    # ce qui provoquerait un décalage entre le .env et Keycloak.
    SECRET_RESPONSE=$(curl -sf \
      -X POST \
      -H "Authorization: Bearer $ACCESS_TOKEN" \
      "$KEYCLOAK_URL/admin/realms/$REALM/clients/$CLIENT_UUID/client-secret") \
      || die "Régénération du secret échouée."
    CLIENT_SECRET=$(echo "$SECRET_RESPONSE" | jq -r '.value // empty')
    [[ -n "$CLIENT_SECRET" ]] || die "Secret vide dans la réponse Keycloak."
    success "Secret régénéré dans Keycloak."
  else
    CLIENT_SECRET=$(curl -sf \
      -H "Authorization: Bearer $ACCESS_TOKEN" \
      "$KEYCLOAK_URL/admin/realms/$REALM/clients/$CLIENT_UUID/client-secret" \
      | jq -r '.value // empty')
    [[ -n "$CLIENT_SECRET" ]] || die "Impossible de lire le secret existant."
    success "Secret existant récupéré."
  fi

  upsert_env "$APP_ENV" "KEYCLOAK_CLIENT_SECRET" "$CLIENT_SECRET"
  success "KEYCLOAK_CLIENT_SECRET mis à jour dans $APP_ENV"
  [[ "$CLIENT_ID" != "$APP_NAME" ]] && info "(client Keycloak : $CLIENT_ID — dossier : $APP_NAME/)"
else
  success "Client public — pas de secret."
fi

# ══════════════════════════════════════════════════════════════════════════════
# 3/5 — Redirect URIs (localhost / LAN / WAN)
# ══════════════════════════════════════════════════════════════════════════════
info "3/5 — Synchronisation des redirect URIs..."

# Lire la config actuelle du client
CLIENT_JSON=$(curl -sf \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  "$KEYCLOAK_URL/admin/realms/$REALM/clients/$CLIENT_UUID")

# Construire la liste des URIs souhaitées
declare -a DESIRED_URIS=()
declare -a DESIRED_ORIGINS=()

if [[ -n "$APP_PORT" ]]; then
  for _host in "localhost" ${LAN_IP:+"$LAN_IP"} ${WAN_IP:+"$WAN_IP"}; do
    DESIRED_URIS+=("http://${_host}:${APP_PORT}${REDIRECT_PATH}")
    DESIRED_ORIGINS+=("http://${_host}:${APP_PORT}")
  done
fi

# URIs HTTPS via Caddy — ajoutées si --caddy-path est fourni et DOMAIN configuré
if [[ -n "$CADDY_PATH" ]]; then
  _ROOT_ENV="$(cd "$(dirname "$0")/.." && pwd)/.env"
  _DOMAIN=$(_env_val "$_ROOT_ENV" "DOMAIN" "CHANGE_ME")
  if [[ "$_DOMAIN" != "CHANGE_ME" && -n "$_DOMAIN" ]]; then
    DESIRED_URIS+=("https://${_DOMAIN}/${CADDY_PATH}${REDIRECT_PATH}")
    DESIRED_ORIGINS+=("https://${_DOMAIN}")
    info "URI HTTPS Caddy : https://${_DOMAIN}/${CADDY_PATH}${REDIRECT_PATH}"
  else
    info "DOMAIN non configuré — URI HTTPS ignorée (--caddy-path ${CADDY_PATH})"
  fi
fi

# Construire les JSON arrays
if [[ ${#DESIRED_URIS[@]} -gt 0 ]]; then
  DESIRED_URIS_JSON=$(printf '%s\n' "${DESIRED_URIS[@]}" | jq -R . | jq -s .)
  DESIRED_ORIGINS_JSON=$(printf '%s\n' "${DESIRED_ORIGINS[@]}" | jq -R . | jq -s .)
else
  DESIRED_URIS_JSON='[]'
  DESIRED_ORIGINS_JSON='[]'
fi

# Fusionner avec les URIs existantes (union sans doublons)
NEW_URIS_JSON=$(echo "$CLIENT_JSON" | jq \
  --argjson d "$DESIRED_URIS_JSON" \
  '((.redirectUris // []) + $d) | unique')

NEW_ORIGINS_JSON=$(echo "$CLIENT_JSON" | jq \
  --argjson d "$DESIRED_ORIGINS_JSON" \
  '((.webOrigins // []) + $d) | unique')

# Comparer avec l'existant
PREV_URIS=$(echo "$CLIENT_JSON"    | jq -Sc '(.redirectUris // []) | sort')
PREV_ORIGINS=$(echo "$CLIENT_JSON" | jq -Sc '(.webOrigins // []) | sort')
NEXT_URIS=$(echo "$NEW_URIS_JSON"       | jq -Sc 'sort')
NEXT_ORIGINS=$(echo "$NEW_ORIGINS_JSON" | jq -Sc 'sort')

if [[ "$NEXT_URIS" != "$PREV_URIS" ]] || [[ "$NEXT_ORIGINS" != "$PREV_ORIGINS" ]]; then
  UPDATED_CLIENT=$(echo "$CLIENT_JSON" | jq \
    --argjson uris    "$NEW_URIS_JSON" \
    --argjson origins "$NEW_ORIGINS_JSON" \
    '.redirectUris = $uris | .webOrigins = $origins | .attributes["post.logout.redirect.uris"] = "+"')

  HTTP_STATUS=$(curl -s -o /tmp/_kc_update.json -w "%{http_code}" \
    -X PUT \
    -H "Authorization: Bearer $ACCESS_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$UPDATED_CLIENT" \
    "$KEYCLOAK_URL/admin/realms/$REALM/clients/$CLIENT_UUID")

  if [[ "$HTTP_STATUS" == "204" ]]; then
    success "Redirect URIs mises à jour :"
    echo "$NEW_URIS_JSON" | jq -r '.[]' | sed 's/^/     • /'
  else
    warn "Mise à jour des URIs : HTTP $HTTP_STATUS — $(cat /tmp/_kc_update.json)"
  fi
else
  success "Redirect URIs déjà complètes."
  echo "$NEW_URIS_JSON" | jq -r '.[]' | sed 's/^/     • /'
fi

# ══════════════════════════════════════════════════════════════════════════════
# 4/5 — Group Membership mapper (claim 'groups' dans les tokens)
# ══════════════════════════════════════════════════════════════════════════════
info "4/5 — Vérification du Group Membership mapper..."

EXISTING_MAPPER=$(curl -sf \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  "$KEYCLOAK_URL/admin/realms/$REALM/clients/$CLIENT_UUID/protocol-mappers/models" \
  | jq -r '[.[] | select(.name == "groups")] | .[0].id // empty')

if [[ -n "$EXISTING_MAPPER" ]]; then
  success "Mapper 'groups' présent (claim injecté dans id_token, access_token, userinfo)."
else
  MAPPER_STATUS=$(curl -s -o /tmp/_kc_mapper.json -w "%{http_code}" \
    -X POST \
    -H "Authorization: Bearer $ACCESS_TOKEN" \
    -H "Content-Type: application/json" \
    -d '{
      "name": "groups",
      "protocol": "openid-connect",
      "protocolMapper": "oidc-group-membership-mapper",
      "consentRequired": false,
      "config": {
        "full.path": "false",
        "id.token.claim": "true",
        "access.token.claim": "true",
        "claim.name": "groups",
        "userinfo.token.claim": "true"
      }
    }' \
    "$KEYCLOAK_URL/admin/realms/$REALM/clients/$CLIENT_UUID/protocol-mappers/models")

  case "$MAPPER_STATUS" in
    201) success "Mapper 'groups' ajouté." ;;
    409) success "Mapper 'groups' déjà présent." ;;
    *)   warn "Impossible d'ajouter le mapper (HTTP $MAPPER_STATUS) — à vérifier manuellement dans Keycloak." ;;
  esac
fi

# ══════════════════════════════════════════════════════════════════════════════
# 5/5 — Mise à jour du .env de l'application
# ══════════════════════════════════════════════════════════════════════════════
info "5/5 — Mise à jour de $APP_ENV..."

mkdir -p "$APP_DIR"
upsert_env "$APP_ENV" "KEYCLOAK_URL"         "$KEYCLOAK_PUBLIC_URL"
upsert_env "$APP_ENV" "KEYCLOAK_REALM"      "$REALM"
upsert_env "$APP_ENV" "KEYCLOAK_CLIENT_ID"  "$CLIENT_ID"
upsert_env "$APP_ENV" "KEYCLOAK_ISSUER_URI" "$KEYCLOAK_PUBLIC_URL/realms/$REALM"
upsert_env "$APP_ENV" "PORT_KEYCLOAK"       "$KC_PORT"
success "$APP_ENV mis à jour."

# ══════════════════════════════════════════════════════════════════════════════
# 6/5 — Restriction d'accès à un ou plusieurs groupes Keycloak (optionnel)
#
#   --require-group accepte une liste séparée par des virgules (g1,g2,...).
#   Trois verrous complémentaires sont posés :
#
#     a) Rôle realm '<groupe>-member' par groupe (conservé : c'est l'ancien
#        contrat, et google-agenda s'appuie encore sur ce nommage).
#     b) Rôle realm '<client>-access', assigné à CHACUN des groupes listés. Un
#        seul rôle assigné à N groupes donne le « OU » qu'on veut (les rôles
#        composites, eux, propagent vers le bas et ne conviendraient pas).
#     c) Override du flow navigateur du client : sous-flow CONDITIONAL qui
#        refuse l'accès si l'utilisateur n'a PAS '<client>-access'.
#
#   Le flow ne garde que la porte du navigateur. La serrure de l'API, elle, est
#   dans le backend (contrôle du claim 'groups' + de 'azp'), alimentée ici par
#   KEYCLOAK_REQUIRED_GROUPS dans le .env de l'app. Sans ce contrôle backend, un
#   token pris sur 'admin-cli' (public, password grant activé par défaut dans le
#   realm) appellerait l'API sans jamais passer par ce flow.
# ══════════════════════════════════════════════════════════════════════════════
if [[ -n "$REQUIRE_GROUP" ]]; then
  info "6/5 — Restriction d'accès aux groupes '$REQUIRE_GROUP'..."

  IFS=',' read -r -a REQUIRE_GROUPS <<< "$REQUIRE_GROUP"
  ACCESS_ROLE="${CLIENT_ID}-access"

  # ── Créer un rôle realm s'il est absent ─────────────────────────────────────
  _ensure_realm_role() {
    local role="$1" desc="$2"
    local exists
    # Pas de -f : un 404 (rôle absent) est le cas nominal ici, et sous
    # `set -euo pipefail` l'échec de curl ferait avorter le script.
    exists=$(curl -s -H "Authorization: Bearer $ACCESS_TOKEN" \
      "$KEYCLOAK_URL/admin/realms/$REALM/roles/$(_urlenc "$role")" | jq -r '.name // empty')
    [[ -n "$exists" ]] && { success "  Rôle '$role' existant."; return 0; }
    local http
    http=$(curl -s -o /tmp/_kc_role.json -w "%{http_code}" -X POST \
      -H "Authorization: Bearer $ACCESS_TOKEN" -H "Content-Type: application/json" \
      -d "$(jq -n --arg n "$role" --arg d "$desc" '{name: $n, description: $d}')" \
      "$KEYCLOAK_URL/admin/realms/$REALM/roles")
    case "$http" in
      201|409) success "  Rôle '$role' créé." ;;
      *)       warn    "  Création du rôle '$role' : HTTP $http — $(cat /tmp/_kc_role.json)" ;;
    esac
  }

  # ── Assigner un rôle realm à un groupe ──────────────────────────────────────
  _assign_role_to_group() {
    local role="$1" group="$2"
    local role_id group_id http
    role_id=$(curl -s -H "Authorization: Bearer $ACCESS_TOKEN" \
      "$KEYCLOAK_URL/admin/realms/$REALM/roles/$(_urlenc "$role")" | jq -r '.id // empty')
    [[ -n "$role_id" ]] || { warn "  Rôle '$role' introuvable — assignation ignorée."; return 1; }
    group_id=$(curl -s -H "Authorization: Bearer $ACCESS_TOKEN" \
      "$KEYCLOAK_URL/admin/realms/$REALM/groups?search=$(_urlenc "$group")" \
      | jq -r --arg g "$group" '[.[] | select(.name == $g)] | .[0].id // empty')
    if [[ -z "$group_id" ]]; then
      warn "  Groupe '$group' introuvable dans Keycloak — synchronisez LDAP puis relancez."
      return 1
    fi
    http=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
      -H "Authorization: Bearer $ACCESS_TOKEN" -H "Content-Type: application/json" \
      -d "$(jq -n --arg i "$role_id" --arg n "$role" '[{id: $i, name: $n}]')" \
      "$KEYCLOAK_URL/admin/realms/$REALM/groups/$group_id/role-mappings/realm")
    [[ "$http" =~ ^2 ]] \
      && success "  Rôle '$role' assigné au groupe '$group'." \
      || warn    "  Assignation '$role' → '$group' : HTTP $http"
  }

  # ── a) et b) : rôles + assignations ─────────────────────────────────────────
  _ensure_realm_role "$ACCESS_ROLE" "Accès à l'application $CLIENT_ID"
  for g in "${REQUIRE_GROUPS[@]}"; do
    g="$(echo "$g" | xargs)"   # trim
    [[ -n "$g" ]] || continue
    _ensure_realm_role "${g}-member" "Membres du groupe $g"
    _assign_role_to_group "${g}-member" "$g" || true
    _assign_role_to_group "$ACCESS_ROLE"  "$g" || true
  done

  # ── c) Flow navigateur dédié : refuse qui n'a pas <client>-access ───────────
  FLOW_ALIAS="require-${CLIENT_ID}"
  SUBFLOW_ALIAS="${FLOW_ALIAS}-gate"

  FLOW_ID=$(curl -sf -H "Authorization: Bearer $ACCESS_TOKEN" \
    "$KEYCLOAK_URL/admin/realms/$REALM/authentication/flows" \
    | jq -r --arg a "$FLOW_ALIAS" '[.[] | select(.alias == $a)] | .[0].id // empty')

  if [[ -n "$FLOW_ID" ]]; then
    success "  Flow '$FLOW_ALIAS' existant."
  else
    info "  Création du flow '$FLOW_ALIAS'..."

    # ── Pourquoi ne PAS copier le flow 'browser' et y greffer la barrière ──────
    #   • À la racine du flow 'browser', Cookie / Identity Provider Redirector /
    #     forms sont ALTERNATIVE. Or Keycloak compte un sous-flow CONDITIONAL non
    #     désactivé comme « required », et « REQUIRED and ALTERNATIVE at same
    #     level » ⇒ il IGNORE les alternatives : le formulaire de login ne
    #     s'affiche plus DU TOUT et plus personne ne peut se connecter.
    #   • Greffer la barrière dans le sous-flow 'forms' évite ça, mais l'utilisateur
    #     qui a déjà une session SSO passe par l'authentificateur Cookie, qui
    #     court-circuite 'forms' : la barrière n'est jamais évaluée. Contournement
    #     vérifié en pratique.
    #
    #   D'où cette structure : on encapsule l'authentification dans UN sous-flow
    #   REQUIRED — plus aucune ALTERNATIVE à la racine — et la barrière devient un
    #   frère CONDITIONAL, donc toujours évalué, cookie SSO ou pas.
    #
    #     <flow>                       (top level)
    #       ├─ <flow>-auth             REQUIRED
    #       │    ├─ Cookie             ALTERNATIVE
    #       │    ├─ Identity Provider Redirector  ALTERNATIVE
    #       │    └─ <flow>-forms       ALTERNATIVE
    #       │         ├─ Username Password Form   REQUIRED
    #       │         └─ <flow>-otp    CONDITIONAL
    #       │              ├─ Condition - user configured  REQUIRED
    #       │              └─ OTP Form                     REQUIRED
    #       └─ <flow>-gate             CONDITIONAL
    #            ├─ Condition - user role (negate)  REQUIRED
    #            └─ Deny access                     REQUIRED
    AUTH_ALIAS="${FLOW_ALIAS}-auth"
    FORMS_ALIAS="${FLOW_ALIAS}-forms"
    OTP_ALIAS="${FLOW_ALIAS}-otp"

    _add_subflow() {   # <flow parent> <alias>
      curl -sf -o /dev/null -X POST \
        -H "Authorization: Bearer $ACCESS_TOKEN" -H "Content-Type: application/json" \
        -d "$(jq -n --arg a "$2" '{alias: $a, type: "basic-flow", provider: "registration-page-form"}')" \
        "$KEYCLOAK_URL/admin/realms/$REALM/authentication/flows/$(_urlenc "$1")/executions/flow" \
        || die "  Création du sous-flow '$2' échouée."
    }
    _add_exec() {      # <flow parent> <provider>
      curl -sf -o /dev/null -X POST \
        -H "Authorization: Bearer $ACCESS_TOKEN" -H "Content-Type: application/json" \
        -d "$(jq -n --arg p "$2" '{provider: $p}')" \
        "$KEYCLOAK_URL/admin/realms/$REALM/authentication/flows/$(_urlenc "$1")/executions/execution" \
        || die "  Ajout de l'exécution '$2' échoué."
    }
    _set_req() {       # <match displayName|providerId> <requirement>
      local execs obj
      execs=$(curl -s -H "Authorization: Bearer $ACCESS_TOKEN" \
        "$KEYCLOAK_URL/admin/realms/$REALM/authentication/flows/$(_urlenc "$FLOW_ALIAS")/executions")
      obj=$(echo "$execs" | jq -c --arg m "$1" \
        '[.[] | select(.displayName == $m or .providerId == $m)] | .[0] // empty')
      [[ -n "$obj" ]] || { warn "  Exécution '$1' introuvable."; return 1; }
      curl -sf -o /dev/null -X PUT \
        -H "Authorization: Bearer $ACCESS_TOKEN" -H "Content-Type: application/json" \
        -d "$(echo "$obj" | jq -c --arg r "$2" '.requirement = $r')" \
        "$KEYCLOAK_URL/admin/realms/$REALM/authentication/flows/$(_urlenc "$FLOW_ALIAS")/executions" \
        || warn "  Requirement '$2' sur '$1' échoué."
    }

    curl -sf -o /dev/null -X POST \
      -H "Authorization: Bearer $ACCESS_TOKEN" -H "Content-Type: application/json" \
      -d "$(jq -n --arg a "$FLOW_ALIAS" --arg c "$CLIENT_ID" \
            '{alias: $a, providerId: "basic-flow", topLevel: true, builtIn: false,
              description: ("Accès réservé — client " + $c)}')" \
      "$KEYCLOAK_URL/admin/realms/$REALM/authentication/flows" \
      || die "  Création du flow '$FLOW_ALIAS' échouée."

    _add_subflow "$FLOW_ALIAS"  "$AUTH_ALIAS"
    _add_exec    "$AUTH_ALIAS"  "auth-cookie"
    _add_exec    "$AUTH_ALIAS"  "identity-provider-redirector"
    _add_subflow "$AUTH_ALIAS"  "$FORMS_ALIAS"
    _add_exec    "$FORMS_ALIAS" "auth-username-password-form"
    _add_subflow "$FORMS_ALIAS" "$OTP_ALIAS"
    _add_exec    "$OTP_ALIAS"   "conditional-user-configured"
    _add_exec    "$OTP_ALIAS"   "auth-otp-form"
    _add_subflow "$FLOW_ALIAS"  "$SUBFLOW_ALIAS"
    _add_exec    "$SUBFLOW_ALIAS" "conditional-user-role"
    _add_exec    "$SUBFLOW_ALIAS" "deny-access-authenticator"

    _set_req "$AUTH_ALIAS"                 "REQUIRED"
    _set_req "auth-cookie"                 "ALTERNATIVE"
    _set_req "identity-provider-redirector" "ALTERNATIVE"
    _set_req "$FORMS_ALIAS"                "ALTERNATIVE"
    _set_req "auth-username-password-form" "REQUIRED"
    _set_req "$OTP_ALIAS"                  "CONDITIONAL"
    _set_req "conditional-user-configured" "REQUIRED"
    _set_req "auth-otp-form"               "REQUIRED"
    _set_req "$SUBFLOW_ALIAS"              "CONDITIONAL"
    _set_req "conditional-user-role"       "REQUIRED"
    _set_req "deny-access-authenticator"   "REQUIRED"

    # negate=true ⇒ la condition est vraie quand l'utilisateur N'A PAS le rôle,
    # et c'est alors seulement que Deny Access s'exécute.
    COND_EXEC_ID=$(curl -s -H "Authorization: Bearer $ACCESS_TOKEN" \
      "$KEYCLOAK_URL/admin/realms/$REALM/authentication/flows/$(_urlenc "$FLOW_ALIAS")/executions" \
      | jq -r '[.[] | select(.providerId == "conditional-user-role")] | .[0].id // empty')
    if [[ -n "$COND_EXEC_ID" ]]; then
      curl -sf -o /dev/null -X POST \
        -H "Authorization: Bearer $ACCESS_TOKEN" -H "Content-Type: application/json" \
        -d "$(jq -n --arg r "$ACCESS_ROLE" --arg a "cfg-${FLOW_ALIAS}" \
              '{alias: $a, config: {condUserRole: $r, negate: "true"}}')" \
        "$KEYCLOAK_URL/admin/realms/$REALM/authentication/executions/$COND_EXEC_ID/config" \
        && success "  Condition « pas de rôle $ACCESS_ROLE » → Deny Access." \
        || warn    "  Configuration de la condition échouée."
    else
      warn "  Exécution 'conditional-user-role' introuvable — condition non configurée."
    fi

    FLOW_ID=$(curl -s -H "Authorization: Bearer $ACCESS_TOKEN" \
      "$KEYCLOAK_URL/admin/realms/$REALM/authentication/flows" \
      | jq -r --arg a "$FLOW_ALIAS" '[.[] | select(.alias == $a)] | .[0].id // empty')
    success "  Flow '$FLOW_ALIAS' créé."
  fi

  # ── Lier le flow au client ──────────────────────────────────────────────────
  if [[ -n "$FLOW_ID" ]]; then
    BIND_HTTP=$(curl -s -o /tmp/_kc_bind.json -w "%{http_code}" -X PUT \
      -H "Authorization: Bearer $ACCESS_TOKEN" -H "Content-Type: application/json" \
      -d "$(jq -n --arg f "$FLOW_ID" '{authenticationFlowBindingOverrides: {browser: $f}}')" \
      "$KEYCLOAK_URL/admin/realms/$REALM/clients/$CLIENT_UUID")
    [[ "$BIND_HTTP" =~ ^2 ]] \
      && success "  Flow '$FLOW_ALIAS' lié au client '$CLIENT_ID'." \
      || warn    "  Liaison flow → client : HTTP $BIND_HTTP — $(cat /tmp/_kc_bind.json)"
  fi
fi

# Propage le cloisonnement au backend, qui est la serrure réelle de l'API.
# Vide si --require-group n'est pas passé ⇒ aucun filtre côté backend.
upsert_env "$APP_ENV" "KEYCLOAK_REQUIRED_GROUPS" "$REQUIRE_GROUP"

# ══════════════════════════════════════════════════════════════════════════════
# Service account : client confidentiel compagnon "<app>-admin"
#   Activé si <app>/.keycloak-service-account-roles existe (1 ligne = 1 rôle du
#   client realm-management). Permet au backend de l'app d'agir en admin Keycloak
#   (créer des utilisateurs, gérer les groupes) via le flux client_credentials —
#   sans toucher au client applicatif (qui peut être public, ex. SPA Angular).
# ══════════════════════════════════════════════════════════════════════════════
SA_ROLES_FILE="$APP_DIR/.keycloak-service-account-roles"
if [[ -f "$SA_ROLES_FILE" ]]; then
  ADMIN_CLIENT_ID="${APP_NAME}-admin"
  info "Service account — client compagnon '$ADMIN_CLIENT_ID'..."

  ADMIN_UUID=$(curl -sf -H "Authorization: Bearer $ACCESS_TOKEN" \
    "$KEYCLOAK_URL/admin/realms/$REALM/clients?clientId=$ADMIN_CLIENT_ID" \
    | jq -r '.[0].id // empty')

  if [[ -z "$ADMIN_UUID" ]]; then
    ADMIN_PAYLOAD=$(jq -n --arg cid "$ADMIN_CLIENT_ID" '{
      clientId: $cid, name: $cid, enabled: true, protocol: "openid-connect",
      publicClient: false, clientAuthenticatorType: "client-secret",
      standardFlowEnabled: false, directAccessGrantsEnabled: false,
      serviceAccountsEnabled: true, redirectUris: [], webOrigins: []
    }')
    AC_HTTP=$(curl -s -o /tmp/_kc_adminclient.json -w "%{http_code}" -X POST \
      -H "Authorization: Bearer $ACCESS_TOKEN" -H "Content-Type: application/json" \
      -d "$ADMIN_PAYLOAD" "$KEYCLOAK_URL/admin/realms/$REALM/clients")
    [[ "$AC_HTTP" == "201" ]] \
      || die "Création du client '$ADMIN_CLIENT_ID' échouée (HTTP $AC_HTTP) : $(cat /tmp/_kc_adminclient.json)"
    ADMIN_UUID=$(curl -sf -H "Authorization: Bearer $ACCESS_TOKEN" \
      "$KEYCLOAK_URL/admin/realms/$REALM/clients?clientId=$ADMIN_CLIENT_ID" | jq -r '.[0].id // empty')
    success "  Client '$ADMIN_CLIENT_ID' créé (UUID: $ADMIN_UUID)."
  else
    success "  Client '$ADMIN_CLIENT_ID' existant (UUID: $ADMIN_UUID)."
  fi

  ADMIN_SECRET=$(curl -sf -H "Authorization: Bearer $ACCESS_TOKEN" \
    "$KEYCLOAK_URL/admin/realms/$REALM/clients/$ADMIN_UUID/client-secret" | jq -r '.value // empty')
  [[ -n "$ADMIN_SECRET" ]] || die "Secret du client '$ADMIN_CLIENT_ID' introuvable."

  SA_USER_ID=$(curl -sf -H "Authorization: Bearer $ACCESS_TOKEN" \
    "$KEYCLOAK_URL/admin/realms/$REALM/clients/$ADMIN_UUID/service-account-user" | jq -r '.id // empty')
  [[ -n "$SA_USER_ID" ]] || die "Service account user introuvable pour '$ADMIN_CLIENT_ID'."

  RM_UUID=$(curl -sf -H "Authorization: Bearer $ACCESS_TOKEN" \
    "$KEYCLOAK_URL/admin/realms/$REALM/clients?clientId=realm-management" | jq -r '.[0].id // empty')
  [[ -n "$RM_UUID" ]] || die "Client realm-management introuvable."

  while IFS= read -r SA_ROLE || [[ -n "$SA_ROLE" ]]; do
    SA_ROLE="$(echo "$SA_ROLE" | sed 's/[[:space:]]*#.*//; s/^[[:space:]]*//; s/[[:space:]]*$//')"
    [[ -z "$SA_ROLE" ]] && continue
    SA_ROLE_JSON=$(curl -sf -H "Authorization: Bearer $ACCESS_TOKEN" \
      "$KEYCLOAK_URL/admin/realms/$REALM/clients/$RM_UUID/roles/$SA_ROLE")
    [[ -n "$(echo "$SA_ROLE_JSON" | jq -r '.id // empty')" ]] \
      || { warn "  Rôle realm-management '$SA_ROLE' introuvable — ignoré."; continue; }
    curl -s -o /dev/null -X POST \
      -H "Authorization: Bearer $ACCESS_TOKEN" -H "Content-Type: application/json" \
      -d "[$(echo "$SA_ROLE_JSON" | jq -c '{id, name}')]" \
      "$KEYCLOAK_URL/admin/realms/$REALM/users/$SA_USER_ID/role-mappings/clients/$RM_UUID"
    success "  Rôle '$SA_ROLE' assigné au service account."
  done < "$SA_ROLES_FILE"

  upsert_env "$APP_ENV" "KEYCLOAK_ADMIN_CLIENT_ID"     "$ADMIN_CLIENT_ID"
  upsert_env "$APP_ENV" "KEYCLOAK_ADMIN_CLIENT_SECRET" "$ADMIN_SECRET"
  success "  Identifiants admin écrits dans $APP_ENV (KEYCLOAK_ADMIN_CLIENT_ID/SECRET)."
fi

# ── Résumé ────────────────────────────────────────────────────────────────────
echo ""
success "Terminé !"
echo ""
echo "─────────────────────────────────────────────────────────────"
echo "  $APP_ENV :"
grep -E "^KEYCLOAK_|^PORT_KEYCLOAK" "$APP_ENV" 2>/dev/null | sed 's/^/  /'
echo "─────────────────────────────────────────────────────────────"
echo ""
if [[ "$CLIENT_TYPE" == "confidential" ]]; then
  echo "  Référence Spring Boot — application.yml :"
  echo "    client-id:     \${KEYCLOAK_CLIENT_ID}"
  echo "    client-secret: \${KEYCLOAK_CLIENT_SECRET}"
  echo "    issuer-uri:    \${KEYCLOAK_ISSUER_URI}"
else
  echo "  Référence Angular — nginx-entrypoint.sh / assets/env.js :"
  echo "    keycloakUrl:      window.location.protocol + '//' + window.location.hostname + ':\${PORT_KEYCLOAK}'"
  echo "    keycloakRealm:    '\${KEYCLOAK_REALM}'"
  echo "    keycloakClientId: '\${KEYCLOAK_CLIENT_ID}'"
fi
echo ""
