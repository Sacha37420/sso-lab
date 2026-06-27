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
  _sd="$(cd "$(dirname "$0")" && pwd)"
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
_SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
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
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
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

# ── Réglages realm idempotents : « mot de passe oublié » + SMTP ───────────────
#   Appliqués à chaque exécution (donc aussi sur un realm déjà existant).
#   Le SMTP est lu depuis sso-lab/.env. Tant que SMTP_FROM est vide, on ne
#   touche pas à la config SMTP : le lien « mot de passe oublié » s'affichera
#   mais ne pourra pas envoyer d'email.
SMTP_FROM_VAL=$(_env_val "$SSO_ENV_FILE" "SMTP_FROM" "")
if [[ -n "$SMTP_FROM_VAL" ]]; then
  info "  Configuration SMTP du realm (from: $SMTP_FROM_VAL)..."
  SMTP_HOST_VAL=$(_env_val "$SSO_ENV_FILE" "SMTP_HOST" "smtp.gmail.com")
  SMTP_PORT_VAL=$(_env_val "$SSO_ENV_FILE" "SMTP_PORT" "587")
  SMTP_USER_VAL=$(_env_val "$SSO_ENV_FILE" "SMTP_USER" "")
  SMTP_PASS_VAL=$(_env_val "$SSO_ENV_FILE" "SMTP_PASSWORD" "")
  SMTP_DISP_VAL=$(_env_val "$SSO_ENV_FILE" "SMTP_FROM_DISPLAY" "SSO Lab")
  SMTP_STARTTLS_VAL=$(_env_val "$SSO_ENV_FILE" "SMTP_STARTTLS" "true")
  SMTP_SSL_VAL=$(_env_val "$SSO_ENV_FILE" "SMTP_SSL" "false")
  [[ -n "$SMTP_USER_VAL" ]] && SMTP_AUTH_VAL="true" || SMTP_AUTH_VAL="false"

  REALM_SMTP_PAYLOAD=$(jq -n \
    --arg host "$SMTP_HOST_VAL" --arg port "$SMTP_PORT_VAL" \
    --arg from "$SMTP_FROM_VAL" --arg disp "$SMTP_DISP_VAL" \
    --arg user "$SMTP_USER_VAL" --arg pass "$SMTP_PASS_VAL" \
    --arg starttls "$SMTP_STARTTLS_VAL" --arg ssl "$SMTP_SSL_VAL" \
    --arg auth "$SMTP_AUTH_VAL" \
    '{
      resetPasswordAllowed: true,
      smtpServer: {
        host: $host, port: $port, from: $from, fromDisplayName: $disp,
        starttls: $starttls, ssl: $ssl, auth: $auth, user: $user, password: $pass
      }
    }')

  SMTP_HTTP=$(curl -s -o /tmp/_kc_smtp.json -w "%{http_code}" \
    -X PUT \
    -H "Authorization: Bearer $ACCESS_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$REALM_SMTP_PAYLOAD" \
    "$KEYCLOAK_URL/admin/realms/$REALM")
  [[ "$SMTP_HTTP" =~ ^2 ]] \
    && success "  SMTP du realm configuré." \
    || warn    "  SMTP du realm : HTTP $SMTP_HTTP — $(cat /tmp/_kc_smtp.json)"
else
  info "  SMTP non configuré (SMTP_FROM vide dans sso-lab/.env) — « mot de passe oublié » sans envoi d'email."
fi

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

# ── Forcer editMode=WRITABLE sur le provider LDAP (idempotent) ────────────────
#   Indispensable pour que « mot de passe oublié » puisse réécrire le mot de
#   passe dans LDAP. Corrige le mode si le provider existait déjà en READ_ONLY.
LDAP_COMPONENT=$(curl -sf \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  "$KEYCLOAK_URL/admin/realms/$REALM/components/$LDAP_PROVIDER_ID")
CURRENT_EDIT_MODE=$(echo "$LDAP_COMPONENT" | jq -r '.config.editMode[0] // empty')
if [[ "$CURRENT_EDIT_MODE" != "WRITABLE" ]]; then
  info "  Passage du provider LDAP en editMode=WRITABLE (était: ${CURRENT_EDIT_MODE:-?})..."
  LDAP_WRITABLE_PAYLOAD=$(echo "$LDAP_COMPONENT" | jq '.config.editMode = ["WRITABLE"]')
  EM_HTTP=$(curl -s -o /tmp/_kc_editmode.json -w "%{http_code}" \
    -X PUT \
    -H "Authorization: Bearer $ACCESS_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$LDAP_WRITABLE_PAYLOAD" \
    "$KEYCLOAK_URL/admin/realms/$REALM/components/$LDAP_PROVIDER_ID")
  [[ "$EM_HTTP" =~ ^2 ]] \
    && success "  Provider LDAP en WRITABLE." \
    || warn    "  editMode WRITABLE : HTTP $EM_HTTP — $(cat /tmp/_kc_editmode.json)"
else
  success "  Provider LDAP déjà en WRITABLE."
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
        "mode":                                 ["READ_ONLY"],
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
  _ROOT_ENV="$(cd "$(dirname "$0")" && pwd)/.env"
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
# 6/5 — Restriction d'accès à un groupe Keycloak (optionnel)
#        Crée un rôle realm <groupe>-member et l'assigne au groupe LDAP.
#        L'application (backend) vérifie ce groupe via le claim JWT 'groups'.
# ══════════════════════════════════════════════════════════════════════════════
if [[ -n "$REQUIRE_GROUP" ]]; then
  info "6/5 — Restriction d'accès au groupe '$REQUIRE_GROUP'..."

  ROLE_NAME="${REQUIRE_GROUP}-member"

  # ── Créer le realm role si absent ───────────────────────────────────────────
  ROLE_EXISTS=$(curl -sf \
    -H "Authorization: Bearer $ACCESS_TOKEN" \
    "$KEYCLOAK_URL/admin/realms/$REALM/roles/$ROLE_NAME" 2>/dev/null \
    | jq -r '.name // empty')

  if [[ -z "$ROLE_EXISTS" ]]; then
    ROLE_HTTP=$(curl -s -o /tmp/_kc_role.json -w "%{http_code}" \
      -X POST \
      -H "Authorization: Bearer $ACCESS_TOKEN" \
      -H "Content-Type: application/json" \
      -d "{\"name\": \"$ROLE_NAME\", \"description\": \"Membres du groupe $REQUIRE_GROUP — accès $CLIENT_ID\"}" \
      "$KEYCLOAK_URL/admin/realms/$REALM/roles")
    case "$ROLE_HTTP" in
      201) success "  Rôle realm '$ROLE_NAME' créé." ;;
      409) success "  Rôle realm '$ROLE_NAME' existant." ;;
      *)   warn    "  Création du rôle : HTTP $ROLE_HTTP — $(cat /tmp/_kc_role.json)" ;;
    esac
  else
    success "  Rôle realm '$ROLE_NAME' existant."
  fi

  # ── Récupérer l'ID du rôle ──────────────────────────────────────────────────
  ROLE_ID=$(curl -sf \
    -H "Authorization: Bearer $ACCESS_TOKEN" \
    "$KEYCLOAK_URL/admin/realms/$REALM/roles/$ROLE_NAME" \
    | jq -r '.id // empty')

  if [[ -z "$ROLE_ID" ]]; then
    warn "  Impossible de récupérer l'ID du rôle '$ROLE_NAME' — assignation ignorée."
  else
    # ── Trouver le groupe dans Keycloak (synchronisé depuis LDAP) ─────────────
    GROUP_KC_ID=$(curl -sf \
      -H "Authorization: Bearer $ACCESS_TOKEN" \
      "$KEYCLOAK_URL/admin/realms/$REALM/groups?search=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$REQUIRE_GROUP'))" 2>/dev/null || echo "$REQUIRE_GROUP")" \
      | jq -r --arg g "$REQUIRE_GROUP" '[.[] | select(.name == $g)] | .[0].id // empty')

    if [[ -z "$GROUP_KC_ID" ]]; then
      warn "  Groupe '$REQUIRE_GROUP' introuvable dans Keycloak."
      warn "  Synchronisez les groupes LDAP puis relancez ce script."
    else
      # ── Assigner le rôle au groupe ────────────────────────────────────────────
      ASSIGN_HTTP=$(curl -s -o /dev/null -w "%{http_code}" \
        -X POST \
        -H "Authorization: Bearer $ACCESS_TOKEN" \
        -H "Content-Type: application/json" \
        -d "[{\"id\": \"$ROLE_ID\", \"name\": \"$ROLE_NAME\"}]" \
        "$KEYCLOAK_URL/admin/realms/$REALM/groups/$GROUP_KC_ID/role-mappings/realm")
      [[ "$ASSIGN_HTTP" =~ ^2 ]] \
        && success "  Rôle '$ROLE_NAME' assigné au groupe '$REQUIRE_GROUP'." \
        || warn    "  Assignation rôle→groupe : HTTP $ASSIGN_HTTP"
    fi
  fi
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
