# shellcheck shell=bash
# ─────────────────────────────────────────────────────────────────────────────
# scripts/lib/kcadmin.sh — lecture de l'API Admin Keycloak (à SOURCER, après
# registry.sh). Mêmes identifiants que scripts/add-user.sh et
# create-app-client.sh (KEYCLOAK_ADMIN / KEYCLOAK_ADMIN_PASSWORD de
# sso-lab/.env, client admin-cli du realm master).
#
# Aucun secret sur une ligne de commande : le mot de passe est lu par curl sur
# un descripteur de fichier, le jeton passe par un fichier de configuration lu
# sur un descripteur lui aussi. argv est lisible par `ps` pour tout compte de
# l'hôte.
#
#   kc_admin_login           → code 0 et jeton en mémoire ; 1 sinon (message sur stderr)
#   kc_admin_get <chemin>    → corps JSON de GET /admin/realms/ssolab<chemin>
#   kc_user_groups <uid>     → un nom de groupe par ligne ;
#                              code 0 = compte trouvé, 3 = compte introuvable,
#                              1 = Keycloak injoignable / erreur
# ─────────────────────────────────────────────────────────────────────────────

_KC_REALM="ssolab"
_KC_URL=""
_KC_TOKEN=""

kc_admin_login() {
  local sso_env admin_user admin_pass kc_port
  sso_env="$(registry_root)/sso-lab/.env"
  command -v curl > /dev/null && command -v jq > /dev/null \
    || { echo "curl et jq sont requis" >&2; return 1; }
  [[ -f "$sso_env" ]] || { echo "sso-lab/.env introuvable" >&2; return 1; }
  _kc_v() { grep -E "^$1=" "$sso_env" 2>/dev/null | head -1 | cut -d= -f2- \
            | sed -e 's/[[:space:]]*#.*//' -e "s/^['\"]//" -e "s/['\"]\$//"; }
  admin_user="$(_kc_v KEYCLOAK_ADMIN)";  admin_user="${admin_user:-admin}"
  admin_pass="$(_kc_v KEYCLOAK_ADMIN_PASSWORD)"
  kc_port="$(_kc_v PORT_KEYCLOAK)";      kc_port="${kc_port:-8080}"
  [[ -n "$admin_pass" ]] || { echo "KEYCLOAK_ADMIN_PASSWORD vide dans sso-lab/.env" >&2; return 1; }
  if [[ -f /.dockerenv ]]; then _KC_URL="http://keycloak:${kc_port}"; else _KC_URL="http://localhost:${kc_port}"; fi
  _KC_TOKEN="$(curl -sf --max-time 15 \
                 --data-urlencode "client_id=admin-cli" --data-urlencode "grant_type=password" \
                 --data-urlencode "username=${admin_user}" --data-urlencode "password@/dev/fd/3" \
                 "${_KC_URL}/realms/master/protocol/openid-connect/token" 3< <(printf '%s' "$admin_pass") 2>/dev/null \
               | jq -r '.access_token // empty' 2>/dev/null || true)"
  [[ -n "$_KC_TOKEN" ]] || { echo "Keycloak injoignable ou authentification admin refusée (${_KC_URL})" >&2; return 1; }
  return 0
}

kc_admin_get() {
  curl -sf --max-time 20 -K /dev/fd/3 "${_KC_URL}/admin/realms/${_KC_REALM}$1" \
    3< <(printf 'header = "Authorization: Bearer %s"\n' "$_KC_TOKEN")
}

# NB : appelée dans une substitution de commande, donc dans un sous-shell — le
# jeton obtenu ici n'est pas conservé par l'appelant, ce qui est voulu (un seul
# appel par exécution de script).
kc_user_groups() {
  local uid="$1" users id
  [[ -n "$_KC_TOKEN" ]] || kc_admin_login || return 1
  # <uid> est déjà validé par l'appelant (^[a-z][a-z0-9]{1,30}$) : rien à encoder.
  users="$(kc_admin_get "/users?username=${uid}&exact=true")" || return 1
  id="$(jq -r '.[0].id // empty' <<< "$users" 2>/dev/null)"
  [[ -n "$id" ]] || return 3
  users="$(kc_admin_get "/users/${id}/groups?max=200")" || return 1
  jq -r '.[].name' <<< "$users" || return 1
}
