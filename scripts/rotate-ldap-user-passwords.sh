#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════════════
# rotate-ldap-user-passwords.sh — Rotation À CHAUD des mots de passe des
# UTILISATEURS LDAP (annuaire ou=people), sans wipe de volume.
#
# Contrairement à init-secrets.sh --init-ldif-password (qui ne réécrit que
# init.ldif/sso-lab/.env et n'a d'effet qu'après suppression + recréation des
# volumes LDAP/Keycloak), ce script applique le nouveau mot de passe au compte
# EN COURS via l'API admin Keycloak (kcadm set-password). La fédération LDAP du
# realm ssolab est en editMode=WRITABLE (voir create-app-client.sh) : Keycloak
# répercute lui-même l'écriture vers l'annuaire — exactement le chemin déjà
# emprunté par le flow « mot de passe oublié ». Aucun wipe, aucun downtime.
#
# Chaque mot de passe est VÉRIFIÉ (grant password contre le realm ssolab, avec
# la NOUVELLE valeur) avant d'être persisté dans init.ldif/sso-lab/.env : en cas
# d'échec pour un compte, on l'ignore et on continue les autres plutôt que de
# tout interrompre.
#
# Notification : si un email réel est configuré pour l'utilisateur (pas
# uid@ssolab.local) et que le SMTP de sso-lab/.env est renseigné, le nouveau mot
# de passe lui est envoyé via notify-password-email.sh (best-effort — un échec
# d'envoi n'annule jamais la rotation, le mot de passe reste appliqué et
# consultable dans sso-lab/.env).
#
# Usage :
#   bash rotate-ldap-user-passwords.sh                        # tous, avec confirmation
#   bash rotate-ldap-user-passwords.sh --yes
#   bash rotate-ldap-user-passwords.sh --yes --keep-password carpeta,naty
# ══════════════════════════════════════════════════════════════════════════════
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SSO_ENV="$SCRIPT_DIR/sso-lab/.env"
INIT_LDIF="$SCRIPT_DIR/sso-lab/ldap/init.ldif"

info(){ echo -e "\033[0;36m→\033[0m $*"; }
ok(){   echo -e "\033[0;32m✓\033[0m $*"; }
warn(){ echo -e "\033[0;33m⚠\033[0m $*"; }
die(){  echo -e "\033[0;31m✗\033[0m $*" >&2; exit 1; }

FORCE=false
KEEP_PASSWORD=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes|-y) FORCE=true ;;
    --keep-password)
      [[ $# -gt 1 ]] || die "--keep-password requiert une valeur"
      KEEP_PASSWORD="$2"; shift ;;
    --keep-password=*) KEEP_PASSWORD="${1#*=}" ;;
    *) die "Argument inconnu : $1" ;;
  esac
  shift
done

[[ -f "$SSO_ENV" ]]   || die "Fichier introuvable : $SSO_ENV"
[[ -f "$INIT_LDIF" ]] || die "Fichier introuvable : $INIT_LDIF"
docker ps --format '{{.Names}}' | grep -qx keycloak || die "Conteneur 'keycloak' non démarré."

env_val(){ grep -E "^$1=" "$SSO_ENV" 2>/dev/null | head -1 | cut -d= -f2-; }
gen_pass(){ LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 50; }

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

KC_PORT="$(env_val PORT_KEYCLOAK)"; KC_PORT="${KC_PORT:-8080}"
KA="$(env_val KEYCLOAK_ADMIN)"; KA="${KA:-admin}"
KADMIN_PASS="$(env_val KEYCLOAK_ADMIN_PASSWORD)"
[[ -n "$KADMIN_PASS" ]] || die "KEYCLOAK_ADMIN_PASSWORD introuvable dans $SSO_ENV"

# ── Liste des comptes (uid + email) depuis init.ldif ──────────────────────────
# Même source que init-secrets.sh --init-ldif-password : init.ldif reste la
# liste de référence des comptes du lab, wipe ou pas.
mapfile -t USERS < <(python3 - "$INIT_LDIF" <<'PY'
import re, sys
path = sys.argv[1]
uid, mail = None, None
for line in open(path, encoding='utf-8'):
    line = line.rstrip('\n')
    m = re.match(r'^dn: uid=([^,]+),', line)
    if m:
        if uid:
            print(f"{uid}\t{mail or ''}")
        uid, mail = m.group(1), None
    elif line.startswith('dn:'):
        if uid:
            print(f"{uid}\t{mail or ''}")
        uid = None
    elif uid and line.startswith('mail:'):
        mail = line.split(':', 1)[1].strip()
if uid:
    print(f"{uid}\t{mail or ''}")
PY
)
[[ ${#USERS[@]} -gt 0 ]] || die "Aucun utilisateur trouvé dans $INIT_LDIF"

declare -A SKIP
IFS=',' read -ra _KEEP_ARR <<< "$KEEP_PASSWORD"
for u in "${_KEEP_ARR[@]:-}"; do
  [[ -n "$u" ]] && SKIP["$(echo "$u" | tr '[:upper:]' '[:lower:]' | xargs)"]=1
done

if ! $FORCE; then
  echo ""
  echo "⚠️  Rotation À CHAUD du mot de passe de ${#USERS[@]} compte(s) LDAP (annuaire ou=people)."
  echo "   Chaque nouveau mot de passe est écrit dans sso-lab/.env et, si une adresse"
  echo "   email réelle et le SMTP sont configurés, ENVOYÉ PAR EMAIL au titulaire."
  [[ -n "$KEEP_PASSWORD" ]] && echo "   Préservés (--keep-password) : $KEEP_PASSWORD"
  printf "   Continuer ? [y/N] "
  read -r c; [[ "$c" =~ ^[Yy]$ ]] || { echo "Annulé."; exit 0; }
fi

# ── Authentification kcadm (une fois, réutilisée pour tous les comptes) ───────
docker exec keycloak /opt/keycloak/bin/kcadm.sh config credentials \
  --server http://localhost:8080 --realm master --user "$KA" --password "$KADMIN_PASS" >/dev/null 2>&1 \
  || die "kcadm : authentification admin échouée."

cp "$INIT_LDIF" "${INIT_LDIF}.bak"

_rotated=0; _kept=0; _failed=0
for entry in "${USERS[@]}"; do
  uid="${entry%%$'\t'*}"
  email="${entry#*$'\t'}"
  uid_lc="$(echo "$uid" | tr '[:upper:]' '[:lower:]')"

  if [[ -n "${SKIP[$uid_lc]:-}" ]]; then
    echo "⏭️   ${uid} (préservé)"
    _kept=$(( _kept + 1 ))
    continue
  fi

  NEW=$(gen_pass)

  if ! docker exec keycloak /opt/keycloak/bin/kcadm.sh set-password \
       -r ssolab --username "$uid" --new-password "$NEW" >/dev/null 2>&1; then
    warn "${uid} : kcadm set-password échoué — ignoré, ancien mot de passe conservé."
    _failed=$(( _failed + 1 ))
    continue
  fi

  # Vérification : grant password contre le realm ssolab avec la NOUVELLE valeur
  # (même technique que le contrôle azp/groups documenté dans CLAUDE.md).
  TOK=$(curl -s -X POST "http://localhost:${KC_PORT}/realms/ssolab/protocol/openid-connect/token" \
        --data-urlencode grant_type=password --data-urlencode client_id=admin-cli \
        --data-urlencode "username=$uid" --data-urlencode "password=$NEW" \
        | python3 -c 'import sys,json; print(json.load(sys.stdin).get("access_token",""))' 2>/dev/null)

  if [[ -z "$TOK" ]]; then
    warn "${uid} : vérification post-rotation échouée — mot de passe potentiellement dans un état incohérent, à vérifier manuellement."
    _failed=$(( _failed + 1 ))
    continue
  fi

  # init.ldif reste la référence pour un futur --restart-sso-lab (bootstrap).
  python3 - "$INIT_LDIF" "$uid" "$NEW" <<'PY'
import re, sys
path, target_uid, new_pass = sys.argv[1], sys.argv[2], sys.argv[3]
lines = open(path, encoding='utf-8').read().split('\n')
uid, out = None, []
for line in lines:
    m = re.match(r'^dn: uid=([^,]+),', line)
    if m:
        uid = m.group(1)
    elif line.startswith('dn:'):
        uid = None
    if uid == target_uid and line.startswith('userPassword:'):
        line = 'userPassword: ' + new_pass
    out.append(line)
open(path, 'w', encoding='utf-8').write('\n'.join(out))
PY

  upsert_env "${uid^^}_PASSWORD" "$NEW"
  ok "${uid} : mot de passe roté (Keycloak/LDAP + init.ldif + sso-lab/.env)."
  _rotated=$(( _rotated + 1 ))

  if [[ -n "$email" ]]; then
    bash "$(dirname "$0")/notify-password-email.sh" "$uid" "$email" "$NEW"
  else
    echo "  ⏭️  ${uid} : pas d'adresse email dans init.ldif — pas d'email."
  fi
done

echo ""
echo "→ ${_rotated} roté(s), ${_kept} préservé(s), ${_failed} échec(s)."
[[ $_failed -eq 0 ]] || warn "Des comptes n'ont pas pu être rotés — voir les messages ci-dessus."
ok "Terminé. sso-lab/.env et init.ldif sont synchronisés avec Keycloak/LDAP — aucun wipe requis."
