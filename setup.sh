#!/usr/bin/env bash
# setup.sh — Initialisation complète du projet depuis zéro
#
#   1. Remet à zéro le projet          (clean.sh)
#   2. Génère des mots de passe forts  (init-secrets.sh)
#   3. Démarre sso-lab                 (Keycloak + LDAP)
#   4. Attend que Keycloak soit prêt
#   5. Crée realm, LDAP, clients       (create-app-client.sh)
#   6. Démarre toutes les stacks       (recompose_docker.sh --force)
#   7. Génère ports.env                (get-ports-list.sh)
#   8. Ouvre les ports sur la Bbox     (open-bbox-ports.sh — Bbox uniquement)
#
# Usage :
#   bash setup.sh          ← demande confirmation à chaque étape sensible
#   bash setup.sh --yes    ← aucun prompt (CI)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ── Couleurs ──────────────────────────────────────────────────────────────────
CYAN='\033[0;36m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
step()    { echo -e "\n${CYAN}══ $* ${NC}"; }
success() { echo -e "${GREEN}✓${NC} $*"; }
warn()    { echo -e "${YELLOW}⚠${NC} $*"; }
die()     { echo -e "${RED}✗ Erreur :${NC} $*" >&2; exit 1; }

FORCE=false
[[ "${1:-}" == "--yes" || "${1:-}" == "-y" ]] && FORCE=true

# ── 1. Nettoyage complet ──────────────────────────────────────────────────────
step "1/7  Nettoyage complet (clean.sh)"
bash "$SCRIPT_DIR/clean.sh"
success "Projet remis à zéro."

# ── 2. Propagation des adresses réseau ────────────────────────────────────────
step "2/7  Propagation des adresses réseau (reset_url.sh)"
bash "$SCRIPT_DIR/reset_url.sh"
success "Adresses réseau propagées."

# ── 3. Génération des mots de passe forts ─────────────────────────────────────
step "3/7  Génération des secrets"
if $FORCE; then
  bash "$SCRIPT_DIR/init-secrets.sh" --yes
else
  bash "$SCRIPT_DIR/init-secrets.sh"
fi
success "Secrets générés."

# ── 4. Démarrage de sso-lab ───────────────────────────────────────────────────
step "4/7  Démarrage de sso-lab (Keycloak + LDAP)"
bash "$SCRIPT_DIR/recompose_docker.sh" --app sso-lab
success "sso-lab démarré."

# ── 5. Attente Keycloak ───────────────────────────────────────────────────────
step "5/7  Attente de Keycloak"

# Récupère le port Keycloak depuis sso-lab/.env (défaut 8080)
KC_PORT=$(grep -E '^PORT_KEYCLOAK=' "$SCRIPT_DIR/sso-lab/.env" 2>/dev/null \
          | cut -d= -f2 | tr -d '[:space:]' || true)
KC_PORT="${KC_PORT:-8080}"
# /health/ready n'est pas activé en start-dev → on sonde /realms/master
# qui répond 200 dès que Keycloak est opérationnel
KC_HEALTH="http://localhost:${KC_PORT}/realms/master"

echo "   Sonde : $KC_HEALTH"
TIMEOUT=300
ELAPSED=0
until curl -sf "$KC_HEALTH" > /dev/null 2>&1; do
  if [[ $ELAPSED -ge $TIMEOUT ]]; then
    die "Keycloak n'a pas répondu après ${TIMEOUT}s. Vérifiez : docker logs keycloak"
  fi
  printf "   Keycloak pas encore prêt (%ds)…\r" "$ELAPSED"
  sleep 3
  ELAPSED=$((ELAPSED + 3))
done
echo ""
success "Keycloak prêt (${ELAPSED}s)."

echo "   Attente de 20s pour laisser Keycloak finaliser son initialisation…"
sleep 20

# ── 6. Realm + LDAP + clients Keycloak ───────────────────────────────────────
step "6/9  Configuration Keycloak (realm, LDAP, clients)"
bash "$SCRIPT_DIR/create-app-client.sh"
success "Clients Keycloak configurés."

# ── 7. Démarrage de toutes les stacks ─────────────────────────────────────────
step "7/9  Démarrage de toutes les stacks"
bash "$SCRIPT_DIR/recompose_docker.sh" --force
success "Toutes les stacks sont démarrées."

# ── 8. Génération de ports.env ────────────────────────────────────────────────
step "8/9  Génération de ports.env (get-ports-list.sh)"
bash "$SCRIPT_DIR/get-ports-list.sh"
success "ports.env généré."

# ── 9. Ouverture des ports Bbox ───────────────────────────────────────────────
step "9/9  Ouverture des ports sur la Bbox (open-bbox-ports.sh)"

# Vérifier que la Bbox est joignable avant de lancer le script
BBOX_IP=$(grep -E '^BBOX_IP=' "$SCRIPT_DIR/bbox.env" 2>/dev/null \
           | cut -d= -f2 | tr -d '[:space:]' || true)
BBOX_IP="${BBOX_IP:-192.168.1.254}"

if curl -sk --max-time 3 "https://${BBOX_IP}/api/v1/device" > /dev/null 2>&1; then
  bash "$SCRIPT_DIR/open-bbox-ports.sh"
  success "Ports ouverts sur la Bbox."
else
  warn "Bbox non détectée sur ${BBOX_IP} — ouvrez les ports manuellement."
  warn "Relancez manuellement : bash open-bbox-ports.sh"
  warn "Ou configurez la redirection de port dans l'interface de votre routeur."
fi

echo ""
echo "════════════════════════════════════════════════════════════════════"
echo "  Setup terminé."
echo "════════════════════════════════════════════════════════════════════"
