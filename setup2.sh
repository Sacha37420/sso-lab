#!/usr/bin/env bash
# setup2.sh — Initialisation complète du projet, version paramétrable par app
#
# Usage :
#   bash setup2.sh [nom-app] [--yes]
#
# Si nom-app est fourni, seules les étapes applicables à cette app sont lancées.
# Sinon, comportement identique à setup.sh (toutes les apps).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="${1:-}"
FORCE=false
PORTS_REGISTRY="$SCRIPT_DIR/.ports"

# Gestion du flag --yes
if [[ "$APP_NAME" == "--yes" || "$APP_NAME" == "-y" ]]; then
  FORCE=true
  APP_NAME=""
elif [[ "${2:-}" == "--yes" || "${2:-}" == "-y" ]]; then
  FORCE=true
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

# ── 2. Propagation des adresses réseau ────────────────────────────────
echo -e "\033[0;36m══ 2/7  Propagation des adresses réseau (reset_url.sh)\033[0m"
bash "$SCRIPT_DIR/reset_url.sh"
echo -e "\033[0;32m✓ Adresses réseau propagées.\033[0m"

# ── 3. Génération des mots de passe forts ─────────────────────────────
if [[ -z "$APP_NAME" ]]; then
  echo -e "\033[0;36m══ 3/7  Génération des secrets\033[0m"
  if $FORCE; then
    bash "$SCRIPT_DIR/init-secrets.sh" --yes
  else
    bash "$SCRIPT_DIR/init-secrets.sh"
  fi
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
