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
#
# Avec --init-ldif-password, les mots de passe des utilisateurs LDAP sont eux
# aussi régénérés (50 caractères aléatoires), à la fois dans sso-lab/ldap/init.ldif
# et dans sso-lab/.env (clés <UID>_PASSWORD).
#
# Usage :
#   ./init-secrets.sh                        ← demande confirmation interactive
#   ./init-secrets.sh --yes                  ← pas de prompt (CI / premier setup)
#   ./init-secrets.sh --yes --init-ldif-password
#       ← régénère AUSSI les mots de passe utilisateurs dans init.ldif
#
#   ⚠ --init-ldif-password n'a d'effet que sur un volume LDAP NEUF : osixia ne
#     rejoue le bootstrap ldif qu'à l'initialisation du volume. Sur un annuaire
#     déjà peuplé, les nouveaux mots de passe ne seraient jamais appliqués et le
#     .env mentirait sur l'état réel. Utiliser `setup2.sh --restart-sso-lab`, qui
#     supprime les volumes d'identité avant d'appeler ce script avec ce flag.
# ══════════════════════════════════════════════════════════════════════════════
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

SSO_ENV="$SCRIPT_DIR/sso-lab/.env"
INIT_LDIF="$SCRIPT_DIR/sso-lab/ldap/init.ldif"

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

# ── Arguments ─────────────────────────────────────────────────────────────────
FORCE=false
INIT_LDIF_PASSWORD=false
KEEP_PASSWORD=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes|-y)             FORCE=true ;;
    --init-ldif-password) INIT_LDIF_PASSWORD=true ;;
    --keep-password)
      [[ $# -gt 1 ]] || { echo "--keep-password requiert une valeur" >&2; exit 1; }
      KEEP_PASSWORD="$2"; shift ;;
    --keep-password=*)    KEEP_PASSWORD="${1#*=}" ;;
    *) echo "Option inconnue : $1" >&2; exit 1 ;;
  esac
  shift
done

if ! $FORCE; then
  echo ""
  echo "⚠️  Ce script va REMPLACER les mots de passe des comptes WAN du projet."
  echo "   (KEYCLOAK_ADMIN, LDAP_ADMIN/CONFIG)"
  $INIT_LDIF_PASSWORD && echo "   ET les mots de passe de TOUS les utilisateurs LDAP (init.ldif)."
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

# ── Utilisateurs LDAP (init.ldif) — uniquement avec --init-ldif-password ──────
#   init.ldif porte les mots de passe en clair, en dur : c'est lui la source de
#   vérité au bootstrap. On réécrit chaque `userPassword:` et on recopie la valeur
#   dans sso-lab/.env sous <UID>_PASSWORD, pour qu'elle reste consultable.
if $INIT_LDIF_PASSWORD; then
  echo ""
  echo "=== Mots de passe des utilisateurs LDAP (init.ldif) ==="
  echo ""
  if [[ ! -f "$INIT_LDIF" ]]; then
    echo "❌  $INIT_LDIF introuvable — abandon." >&2
    exit 1
  fi
  [[ -n "$KEEP_PASSWORD" ]] && echo "   Préservés (--keep-password) : $KEEP_PASSWORD" && echo ""
  cp "$INIT_LDIF" "${INIT_LDIF}.bak"
  _new=0; _kept=0
  while IFS=$'\t' read -r _status _kv; do
    [[ -n "${_kv:-}" ]] || continue
    upsert_env "$SSO_ENV" "${_kv%%=*}" "${_kv#*=}"
    if [[ "$_status" == "keep" ]]; then
      echo "⏭️   ${_kv%%=*}  (inchangé)"
      _kept=$(( _kept + 1 ))
    else
      echo "✅  ${_kv%%=*}"
      _new=$(( _new + 1 ))
    fi
  done < <(python3 - "$INIT_LDIF" "$KEEP_PASSWORD" <<'PY'
import re, secrets, string, sys

path = sys.argv[1]
keep = {u.strip().lower() for u in (sys.argv[2] if len(sys.argv) > 2 else '').split(',') if u.strip()}
alphabet = string.ascii_letters + string.digits
lines = open(path, encoding='utf-8').read().split('\n')

uid, creds, out = None, {}, []
for line in lines:
    m = re.match(r'^dn: uid=([^,]+),', line)
    if m:
        uid = m.group(1)
        # None ⇒ à préserver : on lira la valeur existante sur la ligne userPassword.
        creds[uid] = None if uid.lower() in keep else ''.join(
            secrets.choice(alphabet) for _ in range(50))
    elif line.startswith('dn:'):
        uid = None          # entrée non-utilisateur (ou=, cn=groupe…)
    if uid and line.startswith('userPassword:'):
        if creds[uid] is None:
            # Mot de passe préservé : ligne laissée telle quelle, valeur juste
            # recopiée dans le .env pour qu'elle y reste consultable.
            creds[uid] = line.split(':', 1)[1].strip()
        else:
            line = 'userPassword: ' + creds[uid]
    out.append(line)

open(path, 'w', encoding='utf-8').write('\n'.join(out))
for u, p in creds.items():
    status = 'keep' if u.lower() in keep else 'new'
    print(f"{status}\t{u.upper()}_PASSWORD={p}")
PY
  )
  echo ""
  echo "   → $_new régénéré(s), $_kept préservé(s) — init.ldif et sso-lab/.env à jour"
  echo "   → sauvegarde de l'ancien fichier : ${INIT_LDIF}.bak"
fi

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
