#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────
# setup-keycloak-pgadmin.sh
#
# Configure Keycloak pour pgAdmin via le realm applicatif 'ssolab' :
#   1/5  Token admin (via realm master)
#   2/5  Création du realm 'ssolab' s'il n'existe pas
#   3/5  Fédération LDAP → synchronise les users/groupes OpenLDAP
#   4/5  Client OAuth2 confidentiel 'pgadmin' (Authorization Code Flow)
#   5/5  Mapper "Group Membership" → claim 'groups' dans le JWT
#
# Prérequis :
#   - sso-lab en cours d'exécution  (docker compose -f sso-lab/docker-compose.yml up -d)
#   - jq installé                   (apt/brew install jq)
#
# Usage :
#   bash infra/setup-keycloak-pgadmin.sh
#
# Le script affiche le secret à copier dans infra/.env
# Idempotent : peut être relancé sans risque.
# ─────────────────────────────────────────────────────────────────
set -euo pipefail

KEYCLOAK_URL="http://localhost:8080"
REALM="ssolab"
ADMIN_USER="admin"
ADMIN_PASSWORD="adminpassword"
CLIENT_ID="infra"
PGADMIN_URL="http://localhost:5050"
# IP publique du serveur (pour les redirect_uri Keycloak)
# Doit correspondre à KEYCLOAK_PUBLIC_URL dans infra/.env
SERVER_IP="${SERVER_IP:-192.168.1.50}"
PGADMIN_PUBLIC_URL="http://${SERVER_IP}:5050"

# LDAP (doit correspondre à sso-lab/.env et docker-compose.yml)
# bitnami/openldap écoute sur le port 1389 en interne, mappé sur 389 à l'extérieur
# Keycloak accède via le réseau Docker → port interne 1389
LDAP_HOST="ldap://openldap:389"
LDAP_BIND_DN="cn=admin,dc=ssolab,dc=local"
LDAP_BIND_PASSWORD="adminpassword"
LDAP_USERS_DN="ou=people,dc=ssolab,dc=local"
LDAP_GROUPS_DN="ou=groups,dc=ssolab,dc=local"

# Utilise le secret fourni en variable d'env, ou en génère un.
CLIENT_SECRET="${KEYCLOAK_CLIENT_SECRET:-$(openssl rand -hex 32)}"

# ── 1/5  Token admin (realm master) ──────────────────────────────
echo "── 1/5  Récupération du token admin Keycloak …"
TOKEN=$(curl -sf -X POST \
  "$KEYCLOAK_URL/realms/master/protocol/openid-connect/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "client_id=admin-cli&username=$ADMIN_USER&password=$ADMIN_PASSWORD&grant_type=password" \
  | jq -r '.access_token')
echo "   Token OK."

# ── 2/5  Création du realm 'ssolab' ──────────────────────────────
echo "── 2/5  Création du realm '$REALM' …"
REALM_STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
  "$KEYCLOAK_URL/admin/realms" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d "{
    \"realm\"            : \"$REALM\",
    \"displayName\"      : \"SSO Lab\",
    \"enabled\"          : true,
    \"registrationAllowed\": false,
    \"loginWithEmailAllowed\": true,
    \"duplicateEmailsAllowed\": false,
    \"resetPasswordAllowed\": false,
    \"editUsernameAllowed\": false,
    \"bruteForceProtected\": true
  }")

if [[ "$REALM_STATUS" == "201" ]]; then
  echo "   Realm créé (HTTP 201)."
elif [[ "$REALM_STATUS" == "409" ]]; then
  echo "   Realm déjà existant (HTTP 409) — aucune modification."
else
  echo "   Erreur inattendue HTTP $REALM_STATUS" >&2; exit 1
fi

# ── 3/5  Fédération LDAP ─────────────────────────────────────────
echo "── 3/5  Configuration de la fédération LDAP …"

# Vérifie si un provider LDAP existe déjà
EXISTING_LDAP=$(curl -sf \
  "$KEYCLOAK_URL/admin/realms/$REALM/components?type=org.keycloak.storage.UserStorageProvider" \
  -H "Authorization: Bearer $TOKEN" | jq -r '.[0].id // empty')

if [[ -n "$EXISTING_LDAP" ]]; then
  echo "   Fédération LDAP déjà configurée (id: $EXISTING_LDAP) — ignoré."
  LDAP_ID="$EXISTING_LDAP"
else
  LDAP_ID=$(curl -sf -X POST \
    "$KEYCLOAK_URL/admin/realms/$REALM/components" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -D - -o /dev/null \
    -d "{
      \"name\"           : \"openldap\",
      \"providerId\"     : \"ldap\",
      \"providerType\"   : \"org.keycloak.storage.UserStorageProvider\",
      \"config\": {
        \"enabled\"                  : [\"true\"],
        \"priority\"                 : [\"0\"],
        \"fullSyncPeriod\"           : [\"-1\"],
        \"changedSyncPeriod\"        : [\"-1\"],
        \"cachePolicy\"              : [\"DEFAULT\"],
        \"evictionDay\"              : [],
        \"evictionHour\"             : [],
        \"evictionMinute\"           : [],
        \"maxLifespan\"              : [],
        \"batchSizeForSync\"         : [\"1000\"],
        \"editMode\"                 : [\"READ_ONLY\"],
        \"importEnabled\"            : [\"true\"],
        \"syncRegistrations\"        : [\"false\"],
        \"vendor\"                   : [\"other\"],
        \"usernameLDAPAttribute\"    : [\"uid\"],
        \"rdnLDAPAttribute\"         : [\"uid\"],
        \"uuidLDAPAttribute\"        : [\"entryUUID\"],
        \"userObjectClasses\"        : [\"inetOrgPerson\"],
        \"connectionUrl\"            : [\"$LDAP_HOST\"],
        \"usersDn\"                  : [\"$LDAP_USERS_DN\"],
        \"authType\"                 : [\"simple\"],
        \"bindDn\"                   : [\"$LDAP_BIND_DN\"],
        \"bindCredential\"           : [\"$LDAP_BIND_PASSWORD\"],
        \"searchScope\"              : [\"1\"],
        \"validatePasswordPolicy\"   : [\"false\"],
        \"trustEmail\"               : [\"true\"],
        \"useTruststoreSpi\"         : [\"ldapsOnly\"],
        \"connectionPooling\"        : [\"true\"],
        \"pagination\"               : [\"true\"],
        \"allowKerberosAuthentication\": [\"false\"],
        \"debug\"                    : [\"false\"],
        \"useKerberosForPasswordAuthentication\": [\"false\"]
      }
    }" 2>/dev/null | grep -i '^location:' | sed 's|.*/||' | tr -d '\r\n')
  echo "   Fédération LDAP créée (id: $LDAP_ID)."

  # ── Mapper de groupes LDAP ──────────────────────────────────────
  echo "   Ajout du mapper de groupes LDAP …"
  curl -sf -X POST \
    "$KEYCLOAK_URL/admin/realms/$REALM/components" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d "{
      \"name\"         : \"groups\",
      \"providerId\"   : \"group-ldap-mapper\",
      \"providerType\" : \"org.keycloak.storage.ldap.mappers.LDAPStorageMapper\",
      \"parentId\"     : \"$LDAP_ID\",
      \"config\": {
        \"mode\"                          : [\"READ_ONLY\"],
        \"membership.attribute.type\"     : [\"DN\"],
        \"group.name.ldap.attribute\"     : [\"cn\"],
        \"membership.ldap.attribute\"     : [\"member\"],
        \"preserve.group.inheritance\"    : [\"true\"],
        \"ignore.missing.groups\"         : [\"false\"],
        \"groups.dn\"                     : [\"$LDAP_GROUPS_DN\"],
        \"group.object.classes\"          : [\"groupOfNames\"],
        \"groups.path\"                   : [\"/\"],
        \"drop.non.existing.groups.during.sync\": [\"false\"],
        \"memberof.ldap.attribute\"       : [\"memberOf\"]
      }
    }" > /dev/null
  echo "   Mapper de groupes ajouté."

  # ── Synchronisation initiale ────────────────────────────────────
  echo "   Synchronisation initiale des utilisateurs …"
  SYNC_STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
    "$KEYCLOAK_URL/admin/realms/$REALM/user-storage/$LDAP_ID/sync?action=triggerFullSync" \
    -H "Authorization: Bearer $TOKEN")
  echo "   Sync HTTP $SYNC_STATUS."
fi

# ── 4/5  Création du client pgAdmin ──────────────────────────────
echo "── 4/5  Création du client '$CLIENT_ID' …"
HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
  "$KEYCLOAK_URL/admin/realms/$REALM/clients" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d "{
    \"clientId\"                : \"$CLIENT_ID\",
    \"name\"                    : \"pgAdmin\",
    \"description\"             : \"pgAdmin 4 — accès réservé au groupe developers\",
    \"rootUrl\"                 : \"$PGADMIN_PUBLIC_URL\",
    \"redirectUris\"            : [
      \"$PGADMIN_URL/oauth2/authorize\",
      \"$PGADMIN_PUBLIC_URL/oauth2/authorize\"
    ],
    \"webOrigins\"              : [\"$PGADMIN_URL\", \"$PGADMIN_PUBLIC_URL\"],
    \"publicClient\"            : false,
    \"secret\"                  : \"$CLIENT_SECRET\",
    \"standardFlowEnabled\"     : true,
    \"directAccessGrantsEnabled\": false
  }")

if [[ "$HTTP_STATUS" == "201" ]]; then
  echo "   Client créé (HTTP 201)."
elif [[ "$HTTP_STATUS" == "409" ]]; then
  echo "   Client déjà existant (HTTP 409) — mise à jour du secret …"
  CLIENT_UUID=$(curl -sf \
    "$KEYCLOAK_URL/admin/realms/$REALM/clients?clientId=$CLIENT_ID" \
    -H "Authorization: Bearer $TOKEN" | jq -r '.[0].id')
  curl -sf -X POST \
    "$KEYCLOAK_URL/admin/realms/$REALM/clients/$CLIENT_UUID/client-secret" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"value\": \"$CLIENT_SECRET\"}" > /dev/null
  echo "   Secret mis à jour."
else
  echo "   Erreur inattendue HTTP $HTTP_STATUS" >&2; exit 1
fi

# ── UUID du client ────────────────────────────────────────────────
CLIENT_UUID=$(curl -sf \
  "$KEYCLOAK_URL/admin/realms/$REALM/clients?clientId=$CLIENT_ID" \
  -H "Authorization: Bearer $TOKEN" | jq -r '.[0].id')
echo "   UUID : $CLIENT_UUID"

# ── 5/5  Mapper Group Membership ─────────────────────────────────
echo "── 5/5  Ajout du mapper 'groups' (Group Membership) …"
MAP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
  "$KEYCLOAK_URL/admin/realms/$REALM/clients/$CLIENT_UUID/protocol-mappers/models" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "name"             : "groups",
    "protocol"         : "openid-connect",
    "protocolMapper"   : "oidc-group-membership-mapper",
    "consentRequired"  : false,
    "config": {
      "full.path"           : "false",
      "id.token.claim"      : "true",
      "access.token.claim"  : "true",
      "claim.name"          : "groups",
      "userinfo.token.claim": "true"
    }
  }')

if [[ "$MAP_STATUS" == "201" ]]; then
  echo "   Mapper ajouté (HTTP 201)."
elif [[ "$MAP_STATUS" == "409" ]]; then
  echo "   Mapper déjà présent (HTTP 409) — aucune modification."
else
  echo "   Erreur inattendue HTTP $MAP_STATUS" >&2; exit 1
fi

# ── Résultat ──────────────────────────────────────────────────────
echo ""
echo "══════════════════════════════════════════════════════════════"
echo "  Configuration terminée."
echo ""
echo "  Copiez la ligne suivante dans  infra/.env  :"
echo ""
  echo "  KEYCLOAK_CLIENT_SECRET=$CLIENT_SECRET"
echo ""
echo "  Puis démarrez (ou redémarrez) pgAdmin :"
echo "    cd infra && docker compose up -d pgadmin"
echo "══════════════════════════════════════════════════════════════"
