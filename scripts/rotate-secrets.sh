#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════════════
# rotate-secrets.sh — Rotation À CHAUD des secrets WAN (services déjà en cours)
#
# Contrairement à init-secrets.sh (qui ne réécrit que sso-lab/.env et exige de
# recréer les volumes), ce script applique le nouveau secret au service EN COURS,
# propage les dépendances, PUIS met à jour sso-lab/.env. Aucun wipe, aucun downtime.
#
# Secrets gérés :
#   LDAP_ADMIN_PASSWORD     → olcRootPW de olcDatabase={1}mdb   + bindCredential Keycloak
#   KEYCLOAK_ADMIN_PASSWORD → kcadm set-password (realm master)
#   LDAP_CONFIG_PASSWORD    → olcRootPW de olcDatabase={0}config
#
# Chaque secret est vérifié (bind / auth avec la NOUVELLE valeur) AVANT d'écrire
# le .env : en cas d'échec on s'arrête, l'ancienne valeur reste valide partout.
#
# Usage :
#   bash rotate-secrets.sh                       # les 3, avec confirmation
#   bash rotate-secrets.sh --yes                 # les 3, sans prompt
#   bash rotate-secrets.sh --only=ldap-admin     # un seul (ldap-admin|keycloak-admin|ldap-config)
# ══════════════════════════════════════════════════════════════════════════════
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SSO_ENV="$SCRIPT_DIR/sso-lab/.env"

info(){ echo -e "\033[0;36m→\033[0m $*"; }
ok(){   echo -e "\033[0;32m✓\033[0m $*"; }
warn(){ echo -e "\033[0;33m⚠\033[0m $*"; }
die(){  echo -e "\033[0;31m✗\033[0m $*" >&2; exit 1; }

FORCE=false; ONLY=""
for a in "$@"; do
  case "$a" in
    --yes|-y) FORCE=true ;;
    --only=*) ONLY="${a#--only=}" ;;
    *) die "Argument inconnu : $a" ;;
  esac
done

[[ -f "$SSO_ENV" ]] || die "Fichier introuvable : $SSO_ENV"
command -v jq >/dev/null || die "jq requis."
docker ps --format '{{.Names}}' | grep -qx openldap || die "Conteneur 'openldap' non démarré."
docker ps --format '{{.Names}}' | grep -qx keycloak || die "Conteneur 'keycloak' non démarré."

env_val(){ grep -E "^$1=" "$SSO_ENV" 2>/dev/null | head -1 | cut -d= -f2-; }
gen_pass(){ LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 50; }

# Remplace KEY=val (et nettoie d'éventuelles lignes orphelines) ou ajoute la clé.
upsert_env(){
  local key="$1" value="$2"
  if grep -qE "^${key}=" "$SSO_ENV" 2>/dev/null; then
    awk -v key="$key" -v val="$value" '
      $0 ~ ("^" key "=") { print key "=" val; skip=1; next }
      skip && (/^[A-Za-z_]+=/ || /^#/ || /^[[:space:]]*$/) { skip=0 }
      skip { next }
      { print }
    ' "$SSO_ENV" > "${SSO_ENV}.tmp" && mv "${SSO_ENV}.tmp" "$SSO_ENV"
  else
    printf '\n%s=%s\n' "$key" "$value" >> "$SSO_ENV"
  fi
}

KC_PORT=$(env_val PORT_KEYCLOAK); KC_PORT="${KC_PORT:-8080}"
KC_URL="http://localhost:${KC_PORT}"
KA=$(env_val KEYCLOAK_ADMIN); KA="${KA:-admin}"

kc_token(){ # $1 = mot de passe admin
  curl -s -X POST "$KC_URL/realms/master/protocol/openid-connect/token" \
    --data-urlencode grant_type=password --data-urlencode client_id=admin-cli \
    --data-urlencode "username=$KA" --data-urlencode "password=$1" \
    | jq -r '.access_token // empty'
}

# ── LDAP admin (DIT) : olcRootPW {1}mdb + bindCredential Keycloak ──────────────
rotate_ldap_admin(){
  info "Rotation LDAP_ADMIN_PASSWORD (à chaud)..."
  local CFG NEW HASH TOK PID COMP CODE
  CFG=$(env_val LDAP_CONFIG_PASSWORD)
  NEW=$(gen_pass)

  # Token Keycloak AVANT toute modif (avec l'admin actuel).
  TOK=$(kc_token "$(env_val KEYCLOAK_ADMIN_PASSWORD)")
  [[ -n "$TOK" ]] || die "Auth Keycloak admin échouée (pré-rotation LDAP)."
  PID=$(curl -s -H "Authorization: Bearer $TOK" "$KC_URL/admin/realms/ssolab/components" \
        | jq -r '[.[]|select(.providerType=="org.keycloak.storage.UserStorageProvider" and .name=="ldap")][0].id // empty')
  [[ -n "$PID" ]] || die "Provider LDAP introuvable dans Keycloak."

  # 1) Changer olcRootPW du mdb.
  HASH=$(docker exec openldap slappasswd -h '{SSHA}' -s "$NEW") || die "slappasswd échoué."
  docker exec -i openldap ldapmodify -x -H ldap://localhost -D "cn=admin,cn=config" -w "$CFG" >/dev/null 2>&1 <<EOF || die "ldapmodify olcRootPW (mdb) échoué."
dn: olcDatabase={1}mdb,cn=config
changetype: modify
replace: olcRootPW
olcRootPW: $HASH
EOF
  # 2) Vérifier le bind LDAP avec la nouvelle valeur.
  docker exec openldap ldapwhoami -x -H ldap://localhost -D "cn=admin,dc=ssolab,dc=local" -w "$NEW" >/dev/null 2>&1 \
    || die "Bind LDAP avec le nouveau mot de passe échoué — rotation annulée."

  # 3) Propager au bindCredential de la fédération Keycloak.
  COMP=$(curl -s -H "Authorization: Bearer $TOK" "$KC_URL/admin/realms/ssolab/components/$PID")
  echo "$COMP" | jq --arg p "$NEW" '.config.bindCredential=[$p]' > /tmp/_rot_ldap.json
  CODE=$(curl -s -o /dev/null -w '%{http_code}' -X PUT \
    -H "Authorization: Bearer $TOK" -H "Content-Type: application/json" \
    -d @/tmp/_rot_ldap.json "$KC_URL/admin/realms/ssolab/components/$PID")
  [[ "$CODE" =~ ^2 ]] || die "MAJ bindCredential Keycloak échouée (HTTP $CODE)."

  # 4) Vérifier que Keycloak relit bien le LDAP.
  curl -s -H "Authorization: Bearer $TOK" "$KC_URL/admin/realms/ssolab/users?max=1" \
    | jq -e 'type=="array"' >/dev/null \
    || die "Keycloak ne lit plus le LDAP après MAJ du bindCredential."

  upsert_env LDAP_ADMIN_PASSWORD "$NEW"
  ok "LDAP_ADMIN_PASSWORD roté (LDAP + bindCredential Keycloak + .env)."
}

# ── Keycloak admin (realm master) ─────────────────────────────────────────────
rotate_keycloak_admin(){
  info "Rotation KEYCLOAK_ADMIN_PASSWORD (à chaud)..."
  local OLD NEW
  OLD=$(env_val KEYCLOAK_ADMIN_PASSWORD)
  NEW=$(gen_pass)
  docker exec keycloak /opt/keycloak/bin/kcadm.sh config credentials \
    --server http://localhost:8080 --realm master --user "$KA" --password "$OLD" >/dev/null 2>&1 \
    || die "kcadm : auth avec l'ancien mot de passe échouée."
  docker exec keycloak /opt/keycloak/bin/kcadm.sh set-password \
    -r master --username "$KA" --new-password "$NEW" >/dev/null 2>&1 \
    || die "kcadm set-password échoué."
  [[ -n "$(kc_token "$NEW")" ]] || die "Auth Keycloak avec le nouveau mot de passe échouée."
  upsert_env KEYCLOAK_ADMIN_PASSWORD "$NEW"
  ok "KEYCLOAK_ADMIN_PASSWORD roté (Keycloak + .env)."
}

# ── LDAP config (cn=config) — en dernier car change le bind utilisé ci-dessus ──
rotate_ldap_config(){
  info "Rotation LDAP_CONFIG_PASSWORD (à chaud)..."
  local OLD NEW HASH
  OLD=$(env_val LDAP_CONFIG_PASSWORD)
  NEW=$(gen_pass)
  HASH=$(docker exec openldap slappasswd -h '{SSHA}' -s "$NEW") || die "slappasswd échoué."
  docker exec -i openldap ldapmodify -x -H ldap://localhost -D "cn=admin,cn=config" -w "$OLD" >/dev/null 2>&1 <<EOF || die "ldapmodify olcRootPW (config) échoué."
dn: olcDatabase={0}config,cn=config
changetype: modify
replace: olcRootPW
olcRootPW: $HASH
EOF
  docker exec openldap ldapwhoami -x -H ldap://localhost -D "cn=admin,cn=config" -w "$NEW" >/dev/null 2>&1 \
    || die "Bind cn=config avec le nouveau mot de passe échoué — rotation annulée."
  upsert_env LDAP_CONFIG_PASSWORD "$NEW"
  ok "LDAP_CONFIG_PASSWORD roté (cn=config + .env)."
}

# ── Confirmation ──────────────────────────────────────────────────────────────
if ! $FORCE; then
  echo ""
  echo "⚠️  Rotation À CHAUD des secrets (${ONLY:-les 3}) sur les services en cours."
  echo "   Les nouveaux secrets sont appliqués live puis écrits dans sso-lab/.env."
  printf "   Continuer ? [y/N] "
  read -r c; [[ "$c" =~ ^[Yy]$ ]] || { echo "Annulé."; exit 0; }
fi

# Ordre important : ldap-admin (utilise config pw + admin KC actuels) → keycloak-admin
# → ldap-config (modifie en dernier le bind cn=config réutilisé plus haut).
case "$ONLY" in
  "")              rotate_ldap_admin; rotate_keycloak_admin; rotate_ldap_config ;;
  ldap-admin)      rotate_ldap_admin ;;
  keycloak-admin)  rotate_keycloak_admin ;;
  ldap-config)     rotate_ldap_config ;;
  *) die "Valeur --only inconnue : '$ONLY' (ldap-admin|keycloak-admin|ldap-config)." ;;
esac

echo ""
ok "Terminé. sso-lab/.env est synchronisé avec les services en cours — aucun wipe requis."
