#!/usr/bin/env bash
# setup_unit.sh — Déploiement complet d'UNE application, hors bootstrap infra/
# sso-lab (supposé déjà démarré — cf. setup2.sh pour l'orchestration globale,
# qui dispatche cette commande en parallèle pour toutes les apps du lab).
# Utilisable seul aussi, en développement, pour redéployer une app sans
# toucher au reste du lab : `bash scripts/setup_unit.sh mon-app --yes`.
#
# Usage :
#   bash setup_unit.sh <nom-app> [--yes]
#
# Enchaîne, pour cette app uniquement :
#   1. clean2.sh <app>            — arrêt + suppression des containers/volumes
#   2. sso-lab                    — démarré s'il ne tourne pas déjà, attente Keycloak
#   3. create-app-client.sh <app> — client Keycloak (créé/mis à jour)
#   4. ensure-schemas.sh <app>    — schéma Postgres (rattrapage à chaud)
#   5. recompose_docker.sh --app <app> --force — build + démarrage des containers
#
# --rotate-secrets et --restart-sso-lab ne sont PAS supportés ici : ce sont des
# opérations touchant l'infra partagée (mot de passe Postgres, identité
# sso-lab) — pas sûres à lancer en parallèle pour plusieurs apps à la fois.
# `setup2.sh` les garde sur son chemin séquentiel d'origine, sans passer par ce
# script, précisément pour cette raison.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

APP_NAME=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes|-y) ;;  # accepté pour compat CLI avec setup2.sh, sans effet ici
    -*) echo "Option inconnue : $1" >&2; exit 1 ;;
    *) [[ -z "$APP_NAME" ]] && APP_NAME="$1" ;;
  esac
  shift
done
[[ -z "$APP_NAME" ]] && { echo "Usage : bash setup_unit.sh <nom-app> [--yes]" >&2; exit 1; }

echo -e "\033[0;36m══ $APP_NAME — nettoyage (clean2.sh)\033[0m"
bash "$SCRIPT_DIR/clean2.sh" "$APP_NAME"
echo -e "\033[0;32m✓ $APP_NAME — remise à zéro.\033[0m"

# ── sso-lab : démarré uniquement s'il ne tourne pas déjà (cas courant lors du
# dispatch parallèle depuis setup2.sh, qui l'a déjà démarré avant) ───────────
echo -e "\033[0;36m══ $APP_NAME — sso-lab\033[0m"
_KC_PORT_PROBE=$(grep -E '^PORT_KEYCLOAK=' "$ROOT_DIR/sso-lab/.env" 2>/dev/null | cut -d= -f2 | tr -d '[:space:]' || true)
_KC_PORT_PROBE="${_KC_PORT_PROBE:-8080}"
if curl -sf "http://localhost:${_KC_PORT_PROBE}/realms/master" > /dev/null 2>&1; then
  echo -e "\033[0;33m⚠ sso-lab déjà actif — redémarrage ignoré.\033[0m"
else
  bash "$SCRIPT_DIR/recompose_docker.sh" --app sso-lab
  echo -e "\033[0;32m✓ sso-lab démarré.\033[0m"
fi

# ── Attente Keycloak (immédiat si déjà prêt — coût quasi nul lors du dispatch
# parallèle, où sso-lab est déjà démarré par setup2.sh avant l'appel) ────────
KC_PORT=$(grep -E '^PORT_KEYCLOAK=' "$ROOT_DIR/sso-lab/.env" 2>/dev/null | cut -d= -f2 | tr -d '[:space:]' || true)
KC_PORT="${KC_PORT:-8080}"
if [ -f /.dockerenv ]; then
  KC_HEALTH="http://keycloak:${KC_PORT}/realms/master"
else
  KC_HEALTH="http://localhost:${KC_PORT}/realms/master"
fi
TIMEOUT=300
ELAPSED=0
until curl -sf "$KC_HEALTH" > /dev/null 2>&1; do
  if [[ $ELAPSED -ge $TIMEOUT ]]; then
    echo -e "\033[0;31m✗ $APP_NAME — Keycloak n'a pas répondu après ${TIMEOUT}s.\033[0m" >&2
    exit 1
  fi
  sleep 3
  ELAPSED=$((ELAPSED + 3))
done
if [[ $ELAPSED -gt 3 ]]; then
  echo "   Keycloak venait de démarrer — 20s pour laisser finaliser son initialisation…"
  sleep 20
fi

echo -e "\033[0;36m══ $APP_NAME — client Keycloak\033[0m"
bash "$SCRIPT_DIR/create-app-client.sh" "$APP_NAME"
echo -e "\033[0;32m✓ $APP_NAME — client Keycloak configuré.\033[0m"

echo -e "\033[0;36m══ $APP_NAME — schéma Postgres\033[0m"
bash "$SCRIPT_DIR/ensure-schemas.sh" "$APP_NAME"
echo -e "\033[0;32m✓ $APP_NAME — schéma vérifié.\033[0m"

echo -e "\033[0;36m══ $APP_NAME — démarrage des containers\033[0m"
bash "$SCRIPT_DIR/recompose_docker.sh" --app "$APP_NAME" --force
echo -e "\033[0;32m✓ $APP_NAME déployée.\033[0m"

# ── Catalogue des tests E2E (voir CLAUDE.md, section "Tests end-to-end") ──────
# Best-effort, jamais fatal : lab-runner et/ou lab-admin peuvent ne pas être
# up (déploiement d'une app isolée, lab-admin down…) sans que ça doive
# empêcher le déploiement de $APP_NAME lui-même. Ne fait que LISTER les tests
# (--list, pas de navigateur) — jamais d'exécution réelle ici.
if [[ "$APP_NAME" != "runner" && "$APP_NAME" != "lab-admin" && "$APP_NAME" != "infra" && "$APP_NAME" != "sso-lab" ]]; then
  echo -e "\033[0;36m══ $APP_NAME — catalogue des tests E2E\033[0m"

  LAB_ADMIN_ENV="$ROOT_DIR/lab-admin/.env"
  if [[ -f "$LAB_ADMIN_ENV" ]]; then
    # Auto-génère SETUP_CATALOG_KEY dans lab-admin/.env s'il est absent —
    # jamais à saisir à la main (même logique que les autres secrets
    # auto-générés du repo, ex. rotate-app-secret.sh).
    if ! grep -qE '^SETUP_CATALOG_KEY=.+' "$LAB_ADMIN_ENV"; then
      _new_key="$(openssl rand -hex 32)"
      if grep -qE '^SETUP_CATALOG_KEY=' "$LAB_ADMIN_ENV"; then
        sed -i "s|^SETUP_CATALOG_KEY=.*|SETUP_CATALOG_KEY=${_new_key}|" "$LAB_ADMIN_ENV"
      else
        echo "SETUP_CATALOG_KEY=${_new_key}" >> "$LAB_ADMIN_ENV"
      fi
      echo "   ■ SETUP_CATALOG_KEY généré dans lab-admin/.env (redéployer lab-admin pour l'appliquer)."
    fi
    SETUP_KEY="$(grep -E '^SETUP_CATALOG_KEY=' "$LAB_ADMIN_ENV" | cut -d= -f2- | tr -d '[:space:]')"

    # Passe par `docker exec lab-runner curl ...` plutôt que localhost:<port
    # publié> — les ports publiés le sont sur l'hôte du démon Docker, pas
    # forcément sur celui d'où ce script est lancé (ex. code-server, dont le
    # localhost ne voit pas les ports publiés du démon distant). lab-runner
    # et lab-admin-backend partagent le réseau sso-net, donc le nom de
    # conteneur + le port interne (8000) suffisent, où que ce script tourne.
    LIST_JSON="$(docker exec lab-runner curl -sf "http://localhost:4300/list?app=${APP_NAME}" 2>/dev/null || true)"
    if [[ -n "$LIST_JSON" && -n "$SETUP_KEY" ]]; then
      if docker exec lab-runner curl -sf -X POST \
           -H "X-Setup-Key: ${SETUP_KEY}" -H 'Content-Type: application/json' \
           -d "{\"app\":\"${APP_NAME}\",\"tests\":${LIST_JSON}}" \
           "http://lab-admin-backend:8000/api/debug/catalog-sync/" > /dev/null; then
        echo -e "\033[0;32m✓ Catalogue E2E à jour.\033[0m"
      else
        echo -e "\033[1;33m⚠ Catalogue E2E non mis à jour (lab-admin injoignable) — déploiement non affecté.\033[0m"
      fi
    else
      echo -e "\033[1;33m⚠ Catalogue E2E ignoré (lab-runner non démarré ou clé absente) — déploiement non affecté.\033[0m"
    fi
  else
    echo -e "\033[1;33m⚠ Catalogue E2E ignoré (lab-admin non déployé) — déploiement non affecté.\033[0m"
  fi
fi
