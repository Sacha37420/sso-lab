#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════════════
# init-secrets.sh — Génère des mots de passe forts (50 chars alphanumériques)
# pour les comptes accessibles depuis le WAN et les écrit dans sso-lab/.env.
#
# Mots de passe concernés (exposition WAN) :
#   KEYCLOAK_ADMIN_PASSWORD  — console admin Keycloak (port 8080)
#   LDAP_ADMIN_PASSWORD      — phpLDAPadmin (port 8081)
#   LDAP_CONFIG_PASSWORD     — phpLDAPadmin (cn=config bind)
#
# Non modifiés (non exposés WAN ou gérés ailleurs) :
#   POSTGRES_PASSWORD / DB_PASSWORD  (internes, pas de port exposé)
#   PGADMIN_DEFAULT_PASSWORD         (pgAdmin en OAuth2 uniquement)
#   KEYCLOAK_CLIENT_SECRET           (géré par create-app-client.sh)
#   Mots de passe utilisateurs LDAP  (définis manuellement dans init.ldif)
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

# ── Confirmation ──────────────────────────────────────────────────────────────
FORCE=false
[[ "${1:-}" == "--yes" || "${1:-}" == "-y" ]] && FORCE=true

if ! $FORCE; then
  echo ""
  echo "⚠️  Ce script va REMPLACER les mots de passe des comptes WAN du projet."
  echo "   (KEYCLOAK_ADMIN, LDAP_ADMIN/CONFIG)"
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

echo ""
echo "✅  Tous les secrets ont été régénérés."
echo ""
echo "════════════════════════════════════════════════════════════════════"
echo "  ⚠ Ces nouveaux secrets ne valent que pour des volumes NEUFS."
echo "  Pour des services DÉJÀ EN COURS, n'utilisez PAS ce script :"
echo "  préférez  ./rotate-secrets.sh  qui applique la rotation à chaud"
echo "  (LDAP + bindCredential Keycloak + .env) sans recréer les volumes."
echo ""
echo "  Sinon, actions requises pour appliquer ces changements :"
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
