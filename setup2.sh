#!/usr/bin/env bash
# setup2.sh — Initialisation complète du projet, version paramétrable par app
#
# Usage :
#   bash setup2.sh [nom-app] [--yes] [--restart-sso-lab] [--rotate-secrets] [--keep-password <uids>]
#
# --keep-password carpeta,naty : exclut ces comptes du renouvellement de mot de
#   passe (liste CSV, insensible à la casse). Leur mot de passe actuel est conservé
#   dans init.ldif et recopié dans sso-lab/.env. Sans effet hors --restart-sso-lab.
#
# --rotate-secrets : régénère les secrets applicatifs AVANT le redéploiement, puis
#   les propage et redémarre. Deux rotations :
#     • SECRET_KEY Django de l'app ciblée (ou de toutes les apps si aucun nom) —
#       invalide les sessions en cours de cette/ces app(s) ;
#     • mot de passe PostgreSQL partagé (rôle devuser), à chaud via ALTER ROLE,
#       écrit dans infra/.env et propagé à toutes les apps par reset_url.sh.
#   À utiliser sur fuite d'un secret, ou périodiquement. Le fonctionnement normal
#   (sans ce drapeau) ne régénère jamais ces secrets : il se contente d'aligner le
#   DB_PASSWORD de chaque app sur infra/.env (auto-réparation via reset_url.sh).
#
# Si nom-app est fourni, seules les étapes applicables à cette app sont lancées.
# Sinon, comportement identique à setup.sh (toutes les apps).
#
# --restart-sso-lab : repart d'une identité VIERGE. Arrête sso-lab, supprime ses
#   volumes d'identité (annuaire LDAP + realm Keycloak), puis appelle
#   init-secrets.sh avec --init-ldif-password — qui régénère TOUS les mots de
#   passe, y compris ceux des utilisateurs LDAP dans init.ldif.
#   À utiliser quand on veut réinitialiser les mots de passe : c'est la seule
#   façon cohérente, puisque osixia ne rejoue init.ldif que sur un volume vierge.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PORTS_REGISTRY="$SCRIPT_DIR/.ports"

APP_NAME=""
FORCE=false
RESTART_SSO_LAB=false
ROTATE_SECRETS=false
KEEP_PASSWORD=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes|-y)          FORCE=true ;;
    --restart-sso-lab) RESTART_SSO_LAB=true ;;
    --rotate-secrets)  ROTATE_SECRETS=true ;;
    --keep-password)
      [[ $# -gt 1 ]] || { echo "--keep-password requiert une valeur" >&2; exit 1; }
      KEEP_PASSWORD="$2"; shift ;;
    --keep-password=*) KEEP_PASSWORD="${1#*=}" ;;
    -*)                echo "Option inconnue : $1" >&2; exit 1 ;;
    *)                 [[ -z "$APP_NAME" ]] && APP_NAME="$1" ;;
  esac
  shift
done

# ── 0. Réinitialisation de sso-lab (--restart-sso-lab) ────────────────────────
if $RESTART_SSO_LAB; then
  echo -e "\033[0;36m══ 0/7  Réinitialisation de sso-lab (identité vierge)\033[0m"

  # Volumes SUPPRIMÉS — l'identité, et rien d'autre :
  #   ldap-data / ldap-config : l'annuaire. Le vider est ce qui permet à osixia
  #     de rejouer init.ldif au prochain démarrage (il ne bootstrappe QUE sur un
  #     volume vierge) — donc d'appliquer les nouveaux mots de passe.
  #   keycloak-data           : le realm. Recréé par create-app-client.sh (realm,
  #     fédération LDAP, clients, rôles et flows de restriction).
  #
  # Volumes PRÉSERVÉS — délibérément, malgré le « supprime ses volumes » :
  #   caddy-data       : les certificats Let's Encrypt. Les perdre relancerait
  #     l'émission, plafonnée à 5 certificats/semaine et par domaine : on peut
  #     rester sans HTTPS plusieurs jours. Rien à voir avec l'identité.
  #   code-server-data : extensions et réglages VS Code.
  docker compose -f "$SCRIPT_DIR/sso-lab/docker-compose.yml" \
                 --env-file "$SCRIPT_DIR/sso-lab/.env" \
                 down --remove-orphans 2>&1 | sed 's/^/  /' || true

  for _vol in sso-lab_ldap-data sso-lab_ldap-config sso-lab_keycloak-data; do
    if docker volume inspect "$_vol" > /dev/null 2>&1; then
      docker volume rm "$_vol" > /dev/null 2>&1 \
        && echo "  ■ volume $_vol supprimé" \
        || echo -e "  \033[0;31m✗ échec de suppression de $_vol\033[0m"
    else
      echo "  ■ volume $_vol absent — ignoré"
    fi
  done
  echo -e "\033[0;32m✓ sso-lab réinitialisé (caddy-data et code-server-data préservés).\033[0m"
fi

# ── Auto-enregistrement des ports si l'app est absente de .ports ──────
if [[ -n "$APP_NAME" ]] && ! grep -qE "^${APP_NAME}:" "$PORTS_REGISTRY" 2>/dev/null; then
  DC="$SCRIPT_DIR/$APP_NAME/docker-compose.yml"
  if [[ -f "$DC" ]]; then
    # Convention : container port 8000 = backend Django, port 80 = frontend nginx
    BPORT=$(grep -E '^\s+- "[0-9]+:8000"' "$DC" | sed 's/.*"\([0-9]*\):8000".*/\1/' | head -1)
    FPORT=$(grep -E '^\s+- "[0-9]+:80"' "$DC" | sed 's/.*"\([0-9]*\):80".*/\1/' | head -1)
    echo "${APP_NAME}:${BPORT:-}:${FPORT:-}" >> "$PORTS_REGISTRY"
    echo -e "  \033[0;32m✔ $APP_NAME enregistré dans .ports (backend: ${BPORT:-—}  frontend: ${FPORT:-—})\033[0m"
  fi
fi

# ── 1. Nettoyage complet ──────────────────────────────────────────────
echo -e "\033[0;36m══ 1/7  Nettoyage complet (clean2.sh)\033[0m"
if [[ -n "$APP_NAME" ]]; then
  bash "$SCRIPT_DIR/clean2.sh" "$APP_NAME"
else
  bash "$SCRIPT_DIR/clean2.sh"
fi
echo -e "\033[0;32m✓ Projet remis à zéro.\033[0m"

# ── 1bis. Rotation des secrets applicatifs (--rotate-secrets) ─────────────────
# Placée ICI, entre le nettoyage et reset_url : la rotation DB écrit le nouveau
# mot de passe dans infra/.env, et l'étape 2 (reset_url) le propage aussitôt aux
# .env des apps. Postgres est encore debout (clean2.sh épargne l'infra), ce qui
# permet l'ALTER ROLE à chaud. La rotation précède le démarrage des stacks (7),
# donc les containers repartent d'emblée avec les nouveaux secrets.
if $ROTATE_SECRETS; then
  echo -e "\033[0;36m══ 1bis  Rotation des secrets applicatifs (--rotate-secrets)\033[0m"

  # Mot de passe DB partagé (lab-wide par nature).
  bash "$SCRIPT_DIR/rotate-db-password.sh" --yes || {
    echo -e "\033[0;31m✗ Rotation DB échouée — arrêt avant tout redéploiement.\033[0m" >&2; exit 1; }

  # SECRET_KEY Django : l'app ciblée, ou toutes les apps si aucun nom fourni.
  if [[ -n "$APP_NAME" ]]; then
    bash "$SCRIPT_DIR/rotate-app-secret.sh" "$APP_NAME" || true
  else
    while IFS= read -r _envf; do
      [[ "$_envf" == "$SCRIPT_DIR/.env" ]] && continue   # .env racine du workspace
      _app="$(basename "$(dirname "$_envf")")"
      [[ "$_app" == "sso-lab" || "$_app" == "infra" ]] && continue
      bash "$SCRIPT_DIR/rotate-app-secret.sh" "$_app" || true
    done < <(find "$SCRIPT_DIR" -maxdepth 2 -name ".env" | sort)
  fi
  echo -e "\033[0;32m✓ Secrets applicatifs rotés.\033[0m"
fi

# ── 2. Propagation des adresses réseau ────────────────────────────────
echo -e "\033[0;36m══ 2/7  Propagation des adresses réseau (reset_url.sh)\033[0m"
bash "$SCRIPT_DIR/reset_url.sh"
echo -e "\033[0;32m✓ Adresses réseau propagées.\033[0m"

# ── 3. Génération des mots de passe forts ─────────────────────────────
# Aussi déclenché par --restart-sso-lab même avec un nom d'app : les volumes
# d'identité viennent d'être supprimés, il FAUT régénérer les secrets — sinon le
# .env garderait des mots de passe qui ne correspondent plus à rien.
if [[ -z "$APP_NAME" ]] || $RESTART_SSO_LAB; then
  echo -e "\033[0;36m══ 3/7  Génération des secrets\033[0m"
  SECRET_ARGS=()
  $FORCE           && SECRET_ARGS+=( --yes )
  $RESTART_SSO_LAB && SECRET_ARGS+=( --init-ldif-password )
  [[ -n "$KEEP_PASSWORD" ]] && SECRET_ARGS+=( --keep-password "$KEEP_PASSWORD" )
  bash "$SCRIPT_DIR/init-secrets.sh" "${SECRET_ARGS[@]+"${SECRET_ARGS[@]}"}"
  echo -e "\033[0;32m✓ Secrets générés.\033[0m"
fi

# ── 4. Démarrage de sso-lab ───────────────────────────────────────────
echo -e "\033[0;36m══ 4/7  Démarrage de sso-lab (Keycloak + LDAP)\033[0m"
_KC_PORT_PROBE=$(grep -E '^PORT_KEYCLOAK=' "$SCRIPT_DIR/sso-lab/.env" 2>/dev/null | cut -d= -f2 | tr -d '[:space:]' || true)
_KC_PORT_PROBE="${_KC_PORT_PROBE:-8080}"
if [[ -n "$APP_NAME" ]] && curl -sf "http://localhost:${_KC_PORT_PROBE}/realms/master" > /dev/null 2>&1; then
  echo -e "\033[0;33m⚠ sso-lab déjà actif — redémarrage ignoré.\033[0m"
else
  bash "$SCRIPT_DIR/recompose_docker.sh" --app sso-lab
  echo -e "\033[0;32m✓ sso-lab démarré.\033[0m"
fi

# ── 5. Attente Keycloak ───────────────────────────────────────────────
echo -e "\033[0;36m══ 5/7  Attente de Keycloak\033[0m"
KC_PORT=$(grep -E '^PORT_KEYCLOAK=' "$SCRIPT_DIR/sso-lab/.env" 2>/dev/null | cut -d= -f2 | tr -d '[:space:]' || true)
KC_PORT="${KC_PORT:-8080}"
# Depuis un container Docker (ex: code-server), utiliser le hostname keycloak
if [ -f /.dockerenv ]; then
  KC_HEALTH="http://keycloak:${KC_PORT}/realms/master"
else
  KC_HEALTH="http://localhost:${KC_PORT}/realms/master"
fi
TIMEOUT=300
ELAPSED=0
echo "   Sonde : $KC_HEALTH"
until curl -sf "$KC_HEALTH" > /dev/null 2>&1; do
  if [[ $ELAPSED -ge $TIMEOUT ]]; then
    echo -e "\033[0;31m✗ Erreur : Keycloak n'a pas répondu après ${TIMEOUT}s.\033[0m" >&2; exit 1
  fi
  printf "   Keycloak pas encore prêt (%ds)…\r" "$ELAPSED"
  sleep 3
  ELAPSED=$((ELAPSED + 3))
done
echo ""
echo -e "\033[0;32m✓ Keycloak prêt (${ELAPSED}s).\033[0m"
if [[ $ELAPSED -gt 3 ]]; then
  echo "   Attente de 20s pour laisser Keycloak finaliser son initialisation…"
  sleep 20
else
  echo "   Keycloak était déjà prêt, pas d'attente."
fi

# ── 6. Realm + LDAP + clients Keycloak ───────────────────────────────
echo -e "\033[0;36m══ 6/7  Configuration Keycloak (realm, LDAP, clients)\033[0m"
if [[ -n "$APP_NAME" ]]; then
  bash "$SCRIPT_DIR/create-app-client.sh" "$APP_NAME"
else
  bash "$SCRIPT_DIR/create-app-client.sh"
fi
# Client code-server (oauth2-proxy) : recréé si absent (idempotent)
bash "$SCRIPT_DIR/sso-lab/setup-code-server-auth.sh"
echo -e "\033[0;32m✓ Clients Keycloak configurés.\033[0m"

# ── 6ter. Emails des comptes existants (après un realm neuf) ─────────────────
# Le realm vient d'être recréé : tous les comptes importés de LDAP repartent à
# emailVerified=false. Si VERIFY_EMAIL est activé un jour, ceux dont l'adresse est
# factice (hassan@ssolab.local, maria@ssolab.local) ne pourraient plus se connecter.
if $RESTART_SSO_LAB; then
  echo -e "\033[0;36m══ Validation des emails des comptes existants\033[0m"
  bash "$SCRIPT_DIR/sso-lab/verify-existing-emails.sh" || true
fi

# ── 6bis. Schémas Postgres ───────────────────────────────────────────
# Impérativement avant le démarrage des containers : c'est à son lancement que le
# backend Django exécute `migrate`. Si le schéma n'existe pas encore (00_schemas.sql
# n'est joué qu'à l'initialisation du volume), Django écrit dans public et croit ses
# migrations déjà appliquées — backend up, logs propres, base vide.
echo -e "\033[0;36m══ Vérification des schémas Postgres (ensure-schemas.sh)\033[0m"
if [[ -n "$APP_NAME" ]]; then
  bash "$SCRIPT_DIR/ensure-schemas.sh" "$APP_NAME"
else
  bash "$SCRIPT_DIR/ensure-schemas.sh"
fi
echo -e "\033[0;32m✓ Schémas vérifiés.\033[0m"

# ── 7. Démarrage des stacks ──────────────────────────────────────────
echo -e "\033[0;36m══ 7/7  Démarrage des stacks\033[0m"
if [[ -n "$APP_NAME" ]]; then
  bash "$SCRIPT_DIR/recompose_docker.sh" --app "$APP_NAME" --force
else
  bash "$SCRIPT_DIR/recompose_docker.sh" --force
fi
echo -e "\033[0;32m✓ Stacks démarrées.\033[0m"

# ── 8. Génération de ports.env ───────────────────────────────────────
echo -e "\033[0;36m══ Génération de ports.env (get-ports-list.sh)\033[0m"
bash "$SCRIPT_DIR/get-ports-list.sh"
echo -e "\033[0;32m✓ ports.env généré.\033[0m"

# ── 9. Ouverture des ports Bbox ──────────────────────────────────────
# HTTPS (DOMAIN configuré) → seulement 80+443 ; HTTP → tous les PORT_*
echo -e "\033[0;36m══ Ouverture des ports sur la Bbox (open-bbox-ports2.sh)\033[0m"
BBOX_IP=$(grep -E '^BBOX_IP=' "$SCRIPT_DIR/bbox.env" 2>/dev/null | cut -d= -f2 | tr -d '[:space:]' || true)
BBOX_IP="${BBOX_IP:-192.168.1.254}"
if curl -sk --max-time 3 "https://${BBOX_IP}/api/v1/device" > /dev/null 2>&1; then
  bash "$SCRIPT_DIR/open-bbox-ports2.sh"
  echo -e "\033[0;32m✓ Ports ouverts sur la Bbox.\033[0m"
else
  echo -e "\033[1;33m⚠ Bbox non détectée sur ${BBOX_IP} — ouvrez les ports manuellement.\033[0m"
  echo -e "\033[1;33m⚠ Relancez manuellement : bash open-bbox-ports2.sh\033[0m"
  echo -e "\033[1;33m⚠ Ou configurez la redirection de port dans l'interface de votre routeur.\033[0m"
fi

echo ""
echo "════════════════════════════════════════════════════════════════════"
echo "  Setup terminé."
echo "════════════════════════════════════════════════════════════════════"
