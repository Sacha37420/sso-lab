#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════════════
# rotate-secrets-full.sh — Rotation COMPLÈTE de tous les secrets automatisables
# du lab, à utiliser sur suspicion de fuite large ou par précaution périodique.
#
# Enchaîne, dans cet ordre :
#   1. POSTGRES_PASSWORD (rotate-db-password.sh)          — à chaud
#   2. SECRET_KEY de chaque app Django (rotate-app-secret.sh)
#   3. KEYCLOAK_CLIENT_SECRET de chaque app (create-app-client.sh, sans nom
#      d'app : rotation par défaut, mode tout-en-un)
#   4. LDAP_ADMIN_PASSWORD / KEYCLOAK_ADMIN_PASSWORD / LDAP_CONFIG_PASSWORD
#      (rotate-secrets.sh)                                 — à chaud
#   5. Mot de passe de CHAQUE compte LDAP (rotate-ldap-user-passwords.sh) — à
#      chaud, avec email au titulaire si une adresse réelle + le SMTP de
#      sso-lab/.env sont configurés (voir notify-password-email.sh)
#   6. CODE_SERVER_COOKIE_SECRET + CODE_SERVER_CLIENT_SECRET
#      (sso-lab/setup-code-server-auth.sh --rotate)
#   7. Propagation réseau (reset_url.sh)
#   8. Redémarrage de TOUS les services (recompose_docker.sh --force) pour que
#      chaque backend relise son .env — sans ce redémarrage les secrets rotés
#      aux étapes 2/3/6 restent écrits mais inactifs (Django/oauth2-proxy ne
#      relisent pas leur .env à chaud).
#
# Volontairement PAS setup2.sh en étape finale : son étape « génération des
# secrets » (init-secrets.sh sans --init-ldif-password) réécrirait sso-lab/.env
# avec de NOUVELLES valeurs KEYCLOAK_ADMIN_PASSWORD/LDAP_*_PASSWORD non
# appliquées aux services — désynchronisant le .env de ce que l'étape 4 vient
# tout juste d'appliquer à chaud. On rappelle donc directement les scripts
# unitaires (mêmes briques que setup2.sh --rotate-secrets, en plus complet) et
# on termine par un simple redémarrage.
#
# NON couverts (non automatisables sans risque, voir README) :
#   BBOX_ADMIN_PASSWORD (routeur — verrouillage possible de l'admin en cas
#     d'erreur de script) et SMTP_PASSWORD (mot de passe d'application Gmail —
#     nécessite une action interactive côté compte Google).
#
# Effets de bord assumés : TOUTES les sessions, sur TOUTES les apps, sont
# invalidées ; tous les comptes LDAP reçoivent un nouveau mot de passe.
#
# Usage :
#   bash rotate-secrets-full.sh                          # confirmation interactive
#   bash rotate-secrets-full.sh --yes
#   bash rotate-secrets-full.sh --yes --keep-password carpeta,naty
# ══════════════════════════════════════════════════════════════════════════════
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

FORCE=false
KEEP_PASSWORD=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes|-y) FORCE=true ;;
    --keep-password)
      [[ $# -gt 1 ]] || { echo "--keep-password requiert une valeur" >&2; exit 1; }
      KEEP_PASSWORD="$2"; shift ;;
    --keep-password=*) KEEP_PASSWORD="${1#*=}" ;;
    *) echo "Argument inconnu : $1" >&2; exit 1 ;;
  esac
  shift
done

step(){ echo -e "\n\033[0;36m══ $* \033[0m"; }
ok(){   echo -e "\033[0;32m✓\033[0m $*"; }
die(){  echo -e "\033[0;31m✗\033[0m $*" >&2; exit 1; }

if ! $FORCE; then
  cat <<'EOF'

⚠️  ROTATION COMPLÈTE DE TOUS LES SECRETS DU LAB.

  Sont rotés : mot de passe PostgreSQL partagé, SECRET_KEY et
  KEYCLOAK_CLIENT_SECRET de chaque app, secrets admin de sso-lab (LDAP
  admin/config, Keycloak admin), secrets code-server (cookie + client
  Keycloak), ET le mot de passe de CHAQUE compte LDAP.

  Effets de bord :
   • TOUTES les sessions, sur TOUTES les apps, seront invalidées.
   • Tous les services redémarrent (indisponibilité de quelques minutes).
   • Chaque utilisateur LDAP ayant une adresse réelle reçoit son nouveau
     mot de passe PAR EMAIL, automatiquement.

  NON couverts (à roter manuellement si besoin, voir README) :
   • BBOX_ADMIN_PASSWORD (interface web de la Bbox)
   • SMTP_PASSWORD (mot de passe d'application Gmail)

EOF
  printf "  Continuer ? [y/N] "
  read -r c; [[ "$c" =~ ^[Yy]$ ]] || { echo "Annulé."; exit 0; }
fi

YES_ARGS=(); $FORCE && YES_ARGS+=( --yes )
KEEP_ARGS=(); [[ -n "$KEEP_PASSWORD" ]] && KEEP_ARGS+=( --keep-password "$KEEP_PASSWORD" )

step "1/8  Mot de passe PostgreSQL partagé (à chaud)"
bash "$SCRIPT_DIR/rotate-db-password.sh" "${YES_ARGS[@]}" \
  || die "Rotation DB échouée — arrêt avant tout autre changement."

step "2/8  SECRET_KEY de chaque app Django"
while IFS= read -r _envf; do
  [[ "$_envf" == "$ROOT_DIR/.env" ]] && continue
  _app="$(basename "$(dirname "$_envf")")"
  [[ "$_app" == "sso-lab" || "$_app" == "infra" ]] && continue
  bash "$SCRIPT_DIR/rotate-app-secret.sh" "$_app" || true
done < <(find "$ROOT_DIR" -maxdepth 2 -name ".env" | sort)

step "3/8  KEYCLOAK_CLIENT_SECRET de chaque app (mode tout-en-un)"
bash "$SCRIPT_DIR/create-app-client.sh"

step "4/8  Secrets admin sso-lab — LDAP admin/config, Keycloak admin (à chaud)"
bash "$SCRIPT_DIR/rotate-secrets.sh" "${YES_ARGS[@]}" \
  || die "Rotation des secrets admin sso-lab échouée — arrêt."

step "5/8  Mot de passe de chaque compte LDAP (à chaud, email au titulaire)"
bash "$SCRIPT_DIR/rotate-ldap-user-passwords.sh" "${YES_ARGS[@]}" "${KEEP_ARGS[@]}"

step "6/8  Secrets code-server (cookie oauth2-proxy + client Keycloak)"
bash "$ROOT_DIR/sso-lab/setup-code-server-auth.sh" --rotate

step "7/8  Propagation réseau (reset_url.sh)"
bash "$SCRIPT_DIR/reset_url.sh"

step "8/8  Redémarrage de tous les services (recompose_docker.sh --force)"
bash "$SCRIPT_DIR/recompose_docker.sh" --force

echo ""
ok "Rotation complète terminée — tous les secrets automatisables sont rotés et actifs."
echo ""
echo "  ⚠ À roter manuellement si besoin (non automatisable) :"
echo "     • BBOX_ADMIN_PASSWORD — interface web de la Bbox"
echo "     • SMTP_PASSWORD       — mot de passe d'application Gmail"
