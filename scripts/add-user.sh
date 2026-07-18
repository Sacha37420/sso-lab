#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# add-user.sh — Crée un nouvel utilisateur dans le realm Keycloak 'ssolab'
#
# Le provider LDAP du realm est en editMode=WRITABLE + syncRegistrations=true
# (voir create-app-client.sh) : tout utilisateur/mot de passe/appartenance à un
# groupe créé via l'API Admin Keycloak est donc écrit directement dans l'annuaire
# LDAP — ce script ne touche jamais LDAP en direct, uniquement l'API Keycloak.
#
# Déroulé interactif :
#   1. Nom d'utilisateur, prénom, nom, email
#   2. Affiche les groupes requis/utiles par application, puis la liste complète
#      des groupes existants (avec, pour chacun, les apps qui l'exigent)
#   3. Choix des groupes à attribuer
#   4. Récapitulatif + confirmation
#   5. Génère un mot de passe de 50 caractères (même format que init-secrets.sh)
#   6. Crée l'utilisateur, définit son mot de passe, l'ajoute aux groupes choisis
#   7. Envoie un email (lien de base du serveur + groupes + mot de passe) via le
#      SMTP configuré dans sso-lab/.env — ou affiche un avertissement si le SMTP
#      n'est pas configuré (le mot de passe reste alors affiché en clair ici)
#
# Ce script NE CRÉE PAS de groupes : ils doivent déjà exister dans l'annuaire
# (phpLDAPadmin, ou entrée ajoutée à la main dans sso-lab/ldap/init.ldif puis
# `setup2.sh --restart-sso-lab` sur un lab tout neuf).
#
# Ce script ne gère que la CRÉATION de nouveaux comptes : si le nom d'utilisateur
# ou l'email existe déjà, il s'arrête sans rien modifier (pas de réinitialisation
# silencieuse du mot de passe d'un compte existant).
#
# Prérequis : curl, jq, python3 — sso-lab/.env rempli (KEYCLOAK_ADMIN_PASSWORD)
# Usage     : bash scripts/add-user.sh
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

# ── Couleurs ──────────────────────────────────────────────────────────────────
BOLD='\033[1m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; RED='\033[0;31m'; CYAN='\033[0;36m'; NC='\033[0m'

step() { echo -e "\n${BOLD}${BLUE}▶ $*${NC}"; }
ok()   { echo -e "  ${GREEN}✔ $*${NC}"; }
warn() { echo -e "  ${YELLOW}⚠ $*${NC}"; }
err()  { echo -e "\n${RED}${BOLD}✘ Erreur : $*${NC}\n" >&2; exit 1; }
info() { echo -e "  ${CYAN}→ $*${NC}"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SSO_ENV="$SCRIPT_DIR/sso-lab/.env"
ROOT_ENV="$SCRIPT_DIR/.env"
REALM="ssolab"

for cmd in curl jq python3; do
  command -v "$cmd" &>/dev/null || err "'$cmd' est requis (apt install $cmd)"
done
[[ -f "$SSO_ENV" ]] || err "$SSO_ENV introuvable."

# ── Lecture d'une clé dans un .env ────────────────────────────────────────────
_env_val() {
  local file="$1" key="$2" default="${3:-}"
  local val=""
  if [[ -f "$file" ]]; then
    val=$(grep -E "^${key}=" "$file" 2>/dev/null \
          | head -1 | cut -d= -f2- \
          | sed 's/[[:space:]]*#.*//' \
          | sed "s/^['\"]//; s/['\"]\$//" \
          | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
  fi
  echo "${val:-$default}"
}

# ── Génère un mot de passe alphanumérique de 50 caractères (cf. init-secrets.sh) ──
gen_pass() {
  LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 50
}

# ══════════════════════════════════════════════════════════════════════════════
# Connexion Keycloak (admin)
# ══════════════════════════════════════════════════════════════════════════════
step "Connexion à Keycloak"

ADMIN_USER=$(_env_val "$SSO_ENV" "KEYCLOAK_ADMIN" "admin")
ADMIN_PASS=$(_env_val "$SSO_ENV" "KEYCLOAK_ADMIN_PASSWORD" "")
[[ -n "$ADMIN_PASS" ]] || err "KEYCLOAK_ADMIN_PASSWORD vide dans $SSO_ENV"

KC_PORT=$(_env_val "$SSO_ENV" "PORT_KEYCLOAK" "8080")
if [ -f /.dockerenv ]; then
  KEYCLOAK_URL="http://keycloak:${KC_PORT}"
else
  KEYCLOAK_URL="http://localhost:${KC_PORT}"
fi

TOKEN_RESPONSE=$(curl -sf \
  --data-urlencode "client_id=admin-cli" \
  --data-urlencode "username=$ADMIN_USER" \
  --data-urlencode "password=$ADMIN_PASS" \
  --data-urlencode "grant_type=password" \
  "$KEYCLOAK_URL/realms/master/protocol/openid-connect/token") \
  || err "Impossible de joindre Keycloak sur $KEYCLOAK_URL"
ACCESS_TOKEN=$(echo "$TOKEN_RESPONSE" | jq -r '.access_token // empty')
[[ -n "$ACCESS_TOKEN" ]] || err "Authentification échouée. Vérifiez KEYCLOAK_ADMIN_PASSWORD."
ok "Connecté."

# ══════════════════════════════════════════════════════════════════════════════
# Identité du nouvel utilisateur
# ══════════════════════════════════════════════════════════════════════════════
echo -e "\n${BOLD}╔════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║   Nouvel utilisateur — SSO Lab          ║${NC}"
echo -e "${BOLD}╚════════════════════════════════════════╝${NC}\n"

read -rp "Nom d'utilisateur (uid, ex: julien) : " USERNAME
[[ "$USERNAME" =~ ^[a-zA-Z0-9_-]+$ ]] || err "Nom d'utilisateur invalide (alphanumérique, tirets, underscores)."

EXISTING_UID=$(curl -sf -H "Authorization: Bearer $ACCESS_TOKEN" \
  "$KEYCLOAK_URL/admin/realms/$REALM/users?username=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "$USERNAME")&exact=true" \
  | jq -r '.[0].username // empty')
[[ -z "$EXISTING_UID" ]] || err "Le nom d'utilisateur '$USERNAME' existe déjà — ce script ne gère que la création."

read -rp "Prénom : " FIRST_NAME
[[ -n "$FIRST_NAME" ]] || err "Le prénom ne peut pas être vide."

read -rp "Nom de famille : " LAST_NAME
[[ -n "$LAST_NAME" ]] || err "Le nom de famille ne peut pas être vide."

read -rp "Email : " EMAIL
[[ "$EMAIL" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]] || err "Email invalide."

EXISTING_EMAIL=$(curl -sf -H "Authorization: Bearer $ACCESS_TOKEN" \
  "$KEYCLOAK_URL/admin/realms/$REALM/users?email=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "$EMAIL")&exact=true" \
  | jq -r '.[0].username // empty')
[[ -z "$EXISTING_EMAIL" ]] || err "Cet email est déjà utilisé par le compte '$EXISTING_EMAIL'."

# ══════════════════════════════════════════════════════════════════════════════
# Groupes requis/utiles par application
# ══════════════════════════════════════════════════════════════════════════════
step "Groupes requis ou utiles par application"

declare -A APP_GROUPS   # app -> "g1,g2,..." (peut être vide)
while IFS= read -r _compose; do
  _app="$(basename "$(dirname "$_compose")")"
  [[ "$_app" == "sso-lab" ]] && continue
  _app_env="$(dirname "$_compose")/.env"
  _groups=""
  if [[ -f "$_app_env" ]]; then
    _groups=$(_env_val "$_app_env" "KEYCLOAK_REQUIRED_GROUPS" "")
  fi
  # Repli sur .keycloak-client-opts si l'app n'a jamais été déployée (pas de .env
  # encore écrit par create-app-client.sh — KEYCLOAK_REQUIRED_GROUPS n'existe qu'après).
  if [[ -z "$_groups" ]]; then
    _opts_file="$(dirname "$_compose")/.keycloak-client-opts"
    if [[ -f "$_opts_file" ]]; then
      _groups=$(grep -oE -- '--require-group[[:space:]]+[^[:space:]]+' "$_opts_file" | awk '{print $2}')
    fi
  fi
  APP_GROUPS["$_app"]="$_groups"
done < <(find "$SCRIPT_DIR" -mindepth 2 -maxdepth 2 -name "docker-compose.yml" ! -path "*/_templates/*" | sort)

for _app in "${!APP_GROUPS[@]}"; do
  echo "$_app"$'\t'"${APP_GROUPS[$_app]}"
done | sort | while IFS=$'\t' read -r _app _groups; do
  _label="${_groups:-(aucun — authentification seule)}"
  printf "  %-34s : %s\n" "$_app" "$_label"
done

# ══════════════════════════════════════════════════════════════════════════════
# Liste des groupes existants (source : Keycloak, synchronisé depuis LDAP)
# ══════════════════════════════════════════════════════════════════════════════
step "Groupes disponibles"

ALL_GROUPS_JSON=$(curl -sf -H "Authorization: Bearer $ACCESS_TOKEN" \
  "$KEYCLOAK_URL/admin/realms/$REALM/groups?max=200")
mapfile -t GROUP_NAMES < <(echo "$ALL_GROUPS_JSON" | jq -r '.[].name' | sort)

[[ ${#GROUP_NAMES[@]} -gt 0 ]] || err "Aucun groupe trouvé dans Keycloak — l'annuaire LDAP est-il peuplé ?"

# Index inversé : groupe -> apps qui le requièrent
_required_by() {
  local g="$1" out=""
  for _app in "${!APP_GROUPS[@]}"; do
    IFS=',' read -r -a _gl <<< "${APP_GROUPS[$_app]}"
    for _gg in "${_gl[@]}"; do
      [[ "$(echo "$_gg" | xargs)" == "$g" ]] && out="${out:+$out, }$_app"
    done
  done
  echo "$out"
}

for i in "${!GROUP_NAMES[@]}"; do
  g="${GROUP_NAMES[$i]}"
  req="$(_required_by "$g")"
  printf "  %2d) %-14s %s\n" "$((i+1))" "$g" "${req:+(requis par : $req)}"
done

echo ""
read -rp "Groupes à attribuer (numéros séparés par des virgules, ex: 1,3 ; vide = aucun) : " GROUP_SELECTION

declare -a SELECTED_GROUPS=()
if [[ -n "$GROUP_SELECTION" ]]; then
  IFS=',' read -r -a _indices <<< "$GROUP_SELECTION"
  for _idx in "${_indices[@]}"; do
    _idx="$(echo "$_idx" | xargs)"
    [[ "$_idx" =~ ^[0-9]+$ ]] || err "Sélection invalide : '$_idx'"
    _pos=$((_idx - 1))
    [[ $_pos -ge 0 && $_pos -lt ${#GROUP_NAMES[@]} ]] || err "Numéro hors liste : '$_idx'"
    SELECTED_GROUPS+=("${GROUP_NAMES[$_pos]}")
  done
fi

# ══════════════════════════════════════════════════════════════════════════════
# Récapitulatif + confirmation
# ══════════════════════════════════════════════════════════════════════════════
step "Récapitulatif"
echo "  Utilisateur : $USERNAME"
echo "  Nom complet : $FIRST_NAME $LAST_NAME"
echo "  Email       : $EMAIL"
if [[ ${#SELECTED_GROUPS[@]} -gt 0 ]]; then
  echo "  Groupes     : $(IFS=', '; echo "${SELECTED_GROUPS[*]}")"
else
  warn "Aucun groupe sélectionné : ce compte n'aura accès à AUCUNE application du lab."
fi
echo ""
read -rp "Créer ce compte ? [o/N] " CONFIRM
[[ "$CONFIRM" =~ ^[oOyY]$ ]] || { echo "Annulé."; exit 0; }

# ══════════════════════════════════════════════════════════════════════════════
# Création
# ══════════════════════════════════════════════════════════════════════════════
step "Création du compte"

PASSWORD=$(gen_pass)

HTTP=$(curl -s -o /tmp/_add_user_create.json -w "%{http_code}" -X POST \
  -H "Authorization: Bearer $ACCESS_TOKEN" -H "Content-Type: application/json" \
  -d "$(jq -n --arg u "$USERNAME" --arg e "$EMAIL" --arg f "$FIRST_NAME" --arg l "$LAST_NAME" \
        '{username: $u, email: $e, firstName: $f, lastName: $l, enabled: true, emailVerified: true}')" \
  "$KEYCLOAK_URL/admin/realms/$REALM/users")
[[ "$HTTP" == "201" ]] || err "Création de l'utilisateur échouée (HTTP $HTTP) : $(cat /tmp/_add_user_create.json)"
ok "Utilisateur '$USERNAME' créé (écrit dans LDAP)."

USER_ID=$(curl -sf -H "Authorization: Bearer $ACCESS_TOKEN" \
  "$KEYCLOAK_URL/admin/realms/$REALM/users?username=$USERNAME&exact=true" | jq -r '.[0].id // empty')
[[ -n "$USER_ID" ]] || err "UUID introuvable après création."

HTTP=$(curl -s -o /tmp/_add_user_pw.json -w "%{http_code}" -X PUT \
  -H "Authorization: Bearer $ACCESS_TOKEN" -H "Content-Type: application/json" \
  -d "$(jq -n --arg v "$PASSWORD" '{type:"password", value:$v, temporary:false}')" \
  "$KEYCLOAK_URL/admin/realms/$REALM/users/$USER_ID/reset-password")
[[ "$HTTP" =~ ^2 ]] || err "Définition du mot de passe échouée (HTTP $HTTP) : $(cat /tmp/_add_user_pw.json)"
ok "Mot de passe défini."

for g in "${SELECTED_GROUPS[@]}"; do
  gid=$(echo "$ALL_GROUPS_JSON" | jq -r --arg g "$g" '[.[] | select(.name == $g)] | .[0].id // empty')
  if [[ -z "$gid" ]]; then
    warn "Groupe '$g' introuvable — ignoré."
    continue
  fi
  HTTP=$(curl -s -o /dev/null -w "%{http_code}" -X PUT \
    -H "Authorization: Bearer $ACCESS_TOKEN" \
    "$KEYCLOAK_URL/admin/realms/$REALM/users/$USER_ID/groups/$gid")
  [[ "$HTTP" =~ ^2 ]] \
    && ok "Ajouté au groupe '$g'." \
    || warn "Ajout au groupe '$g' : HTTP $HTTP"
done

rm -f /tmp/_add_user_create.json /tmp/_add_user_pw.json

# ══════════════════════════════════════════════════════════════════════════════
# Lien de base du serveur (mêmes règles que reset_url.sh)
# ══════════════════════════════════════════════════════════════════════════════
DOMAIN_VAL=$(_env_val "$ROOT_ENV" "DOMAIN" "$(_env_val "$SSO_ENV" "DOMAIN" "CHANGE_ME")")
if [[ "$DOMAIN_VAL" != "CHANGE_ME" && -n "$DOMAIN_VAL" ]]; then
  BASE_URL="https://${DOMAIN_VAL}"
else
  BASE_URL=$(_env_val "$ROOT_ENV" "SERVER_URL_WAN" "$(_env_val "$SSO_ENV" "SERVER_URL_WAN" "")")
fi

# ══════════════════════════════════════════════════════════════════════════════
# Email
# ══════════════════════════════════════════════════════════════════════════════
step "Envoi de l'email"

SMTP_HOST_VAL=$(_env_val "$SSO_ENV" "SMTP_HOST" "")
SMTP_PORT_VAL=$(_env_val "$SSO_ENV" "SMTP_PORT" "587")
SMTP_USER_VAL=$(_env_val "$SSO_ENV" "SMTP_USER" "")
SMTP_PASS_VAL=$(_env_val "$SSO_ENV" "SMTP_PASSWORD" "")
SMTP_FROM_VAL=$(_env_val "$SSO_ENV" "SMTP_FROM" "")
SMTP_DISP_VAL=$(_env_val "$SSO_ENV" "SMTP_FROM_DISPLAY" "SSO Lab")
SMTP_STARTTLS_VAL=$(_env_val "$SSO_ENV" "SMTP_STARTTLS" "true")
SMTP_SSL_VAL=$(_env_val "$SSO_ENV" "SMTP_SSL" "false")

GROUPS_LIST="$(IFS=', '; echo "${SELECTED_GROUPS[*]:-aucun}")"

if [[ -z "$SMTP_HOST_VAL" || -z "$SMTP_FROM_VAL" ]]; then
  warn "SMTP non configuré (SMTP_HOST/SMTP_FROM vide dans $SSO_ENV) — email non envoyé."
else
  MAIL_STATUS=$(python3 - "$SMTP_HOST_VAL" "$SMTP_PORT_VAL" "$SMTP_USER_VAL" "$SMTP_PASS_VAL" \
    "$SMTP_FROM_VAL" "$SMTP_DISP_VAL" "$SMTP_STARTTLS_VAL" "$SMTP_SSL_VAL" \
    "$EMAIL" "$FIRST_NAME" "$USERNAME" "$PASSWORD" "$BASE_URL" "$GROUPS_LIST" <<'PY'
import smtplib, ssl, sys
from email.mime.text import MIMEText
from email.utils import formataddr

(host, port, user, password, mail_from, from_display, starttls, use_ssl,
 to_email, first_name, username, new_password, base_url, groups_list) = sys.argv[1:15]

body = f"""Bonjour {first_name},

Un compte vient d'être créé pour vous sur le SSO Lab.

Adresse du serveur : {base_url or '(non configurée)'}
Identifiant         : {username}
Mot de passe        : {new_password}
Groupes             : {groups_list}

Conservez ce mot de passe en lieu sûr — vous pourrez le changer une fois connecté.
"""

msg = MIMEText(body, "plain", "utf-8")
msg["Subject"] = "Votre accès au SSO Lab"
msg["From"] = formataddr((from_display, mail_from))
msg["To"] = to_email

try:
    port = int(port)
    if use_ssl.lower() in ("true", "1", "yes"):
        server = smtplib.SMTP_SSL(host, port, timeout=15, context=ssl.create_default_context())
    else:
        server = smtplib.SMTP(host, port, timeout=15)
        if starttls.lower() in ("true", "1", "yes"):
            server.starttls(context=ssl.create_default_context())
    if user:
        server.login(user, password)
    server.sendmail(mail_from, [to_email], msg.as_string())
    server.quit()
    print("OK")
except Exception as e:
    print(f"ERREUR: {e}")
PY
)
  if [[ "$MAIL_STATUS" == "OK" ]]; then
    ok "Email envoyé à $EMAIL."
  else
    warn "Échec de l'envoi de l'email : ${MAIL_STATUS#ERREUR: }"
  fi
fi

# ══════════════════════════════════════════════════════════════════════════════
# Résumé final (filet de sécurité si l'email a échoué ou n'est pas configuré)
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "═══════════════════════════════════════════════════════════════════"
ok "Compte créé."
echo "  Utilisateur : $USERNAME"
echo "  Email       : $EMAIL"
echo "  Mot de passe : $PASSWORD"
echo "  Groupes     : $GROUPS_LIST"
echo "  Lien serveur : ${BASE_URL:-(non configuré)}"
echo "═══════════════════════════════════════════════════════════════════"
