#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════════════
# init-secrets.sh — Génère des mots de passe forts (50 chars alphanumériques)
# pour les comptes accessibles depuis le WAN et les écrit dans sso-lab/.env.
#
# Mots de passe concernés (exposition WAN) :
#   KEYCLOAK_ADMIN_PASSWORD  — console admin Keycloak (port 8080)
#   LDAP_ADMIN_PASSWORD      — phpLDAPadmin (port 8081)
#   LDAP_CONFIG_PASSWORD     — phpLDAPadmin (cn=config bind)
#   SACHA/HASSAN/LEA/ELODIE_PASSWORD — comptes LDAP, login via Keycloak
#
# Non modifiés (non exposés WAN ou gérés ailleurs) :
#   POSTGRES_PASSWORD / DB_PASSWORD  (internes, pas de port exposé)
#   PGADMIN_DEFAULT_PASSWORD         (pgAdmin en OAuth2 uniquement)
#   KEYCLOAK_CLIENT_SECRET           (géré par create-app-client.sh)
#
# Usage :
#   ./init-secrets.sh          ← demande confirmation interactive
#   ./init-secrets.sh --yes    ← pas de prompt (CI / premier setup)
# ══════════════════════════════════════════════════════════════════════════════
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

SSO_ENV="$SCRIPT_DIR/sso-lab/.env"

# ── Génère un mot de passe alphanumérique de 50 caractères ───────────────────
gen_pass() {
  LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 50
}

LDIF="$SCRIPT_DIR/sso-lab/ldap/init.ldif"

# ── Remplace KEY=valeur dans un .env (nettoie les éventuelles lignes orphelines
#    issues d'une écriture corrompue antérieure) ou ajoute la clé en fin de fichier.
upsert_env() {
  local file="$1" key="$2" value="$3"
  [[ -f "$file" ]] || touch "$file"
  if grep -qE "^${key}=" "$file" 2>/dev/null; then
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

# ── Met à jour userPassword d'un uid dans init.ldif ─────────────────────────
upsert_ldif_password() {
  local file="$1" uid="$2" password="$3"
  awk -v uid="$uid" -v pwd="$password" '
    /^dn: uid=/ { in_user = ($0 ~ ("^dn: uid=" uid ",")) }
    in_user && /^userPassword:/ { print "userPassword: " pwd; next }
    { print }
  ' "$file" > "${file}.tmp" && mv "${file}.tmp" "$file"
}

# ── Confirmation ──────────────────────────────────────────────────────────────
FORCE=false
[[ "${1:-}" == "--yes" || "${1:-}" == "-y" ]] && FORCE=true

if ! $FORCE; then
  echo ""
  echo "⚠️  Ce script va REMPLACER les mots de passe des comptes WAN du projet."
  echo "   (KEYCLOAK_ADMIN, LDAP_ADMIN/CONFIG, utilisateurs LDAP)"
  echo "   Les KEYCLOAK_CLIENT_SECRET ne sont pas modifiés."
  echo ""
  echo "   Les nouveaux mots de passe ne s'appliquent qu'après suppression"
  echo "   et recréation des volumes LDAP et Keycloak."
  echo "   (voir instructions en fin de script)"
  echo ""
  printf "   Continuer ? [y/N] "
  read -r confirm
  [[ "$confirm" =~ ^[Yy]$ ]] || { echo "Annulé."; exit 0; }
fi

echo ""
echo "=== Génération des secrets (comptes WAN) ==="
echo ""

# ── LDAP ──────────────────────────────────────────────────────────────────────
LDAP_ADMIN_PASS=$(gen_pass)
LDAP_CONFIG_PASS=$(gen_pass)
upsert_env "$SSO_ENV" "LDAP_ADMIN_PASSWORD"  "$LDAP_ADMIN_PASS"
upsert_env "$SSO_ENV" "LDAP_CONFIG_PASSWORD" "$LDAP_CONFIG_PASS"
echo "✅  LDAP_ADMIN_PASSWORD                → sso-lab"
echo "✅  LDAP_CONFIG_PASSWORD               → sso-lab"

# ── Keycloak — compte admin ───────────────────────────────────────────────────
KC_ADMIN_PASS=$(gen_pass)
upsert_env "$SSO_ENV" "KEYCLOAK_ADMIN_PASSWORD" "$KC_ADMIN_PASS"
echo "✅  KEYCLOAK_ADMIN_PASSWORD            → sso-lab"

# ── Utilisateurs LDAP de test ─────────────────────────────────────────────────
SACHA_PASS=$(gen_pass)
HASSAN_PASS=$(gen_pass)
LEA_PASS=$(gen_pass)
ELODIE_PASS=$(gen_pass)

upsert_env "$SSO_ENV" "SACHA_PASSWORD"   "$SACHA_PASS"
upsert_env "$SSO_ENV" "HASSAN_PASSWORD"  "$HASSAN_PASS"
upsert_env "$SSO_ENV" "LEA_PASSWORD"     "$LEA_PASS"
upsert_env "$SSO_ENV" "ELODIE_PASSWORD"  "$ELODIE_PASS"

upsert_ldif_password "$LDIF" "sacha"  "$SACHA_PASS"
upsert_ldif_password "$LDIF" "hassan" "$HASSAN_PASS"
upsert_ldif_password "$LDIF" "lea"    "$LEA_PASS"
upsert_ldif_password "$LDIF" "elodie" "$ELODIE_PASS"
echo "✅  SACHA/HASSAN/LEA/ELODIE_PASSWORD   → sso-lab/.env + sso-lab/ldap/init.ldif"

echo ""
echo "✅  Tous les secrets ont été régénérés."
echo ""
echo "════════════════════════════════════════════════════════════════════"
echo "  Actions requises pour appliquer les changements :"
echo ""
echo "  1. Supprimer les volumes sso-lab (LDAP et Keycloak persist leurs mots"
echo "     de passe dans leurs volumes au premier démarrage) :"
echo ""
echo "       docker compose -f sso-lab/docker-compose.yml down -v"
echo ""
echo "  2. Relancer toutes les stacks :"
echo ""
echo "       bash recompose_docker.sh --force"
echo ""
echo "  3. Re-créer les clients Keycloak (nouveau mot de passe admin) :"
echo ""
echo "       ./create-app-client.sh infra            --port 5050 --redirect-path /oauth2/authorize"
echo "       ./create-app-client.sh spring-app       --port 8082"
echo "       ./create-app-client.sh front-cadriciel  --port 4200"
echo "═══════════════════════════════════════════════════════════════════"
