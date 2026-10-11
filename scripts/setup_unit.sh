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

# ── Registre + contrôle de sûreté (contrat multi-dev, I1/I4) ──────────────────
# shellcheck source=lib/registry.sh
source "$SCRIPT_DIR/lib/registry.sh"
registry_app_dir "$APP_NAME" > /dev/null || { echo "Nom d'app invalide : '$APP_NAME'" >&2; exit 1; }

# Une app dont le propriétaire n'est pas le superutilisateur vient d'un dépôt
# que le cadriciel ne contrôle pas : son contenu est validé AVANT toute action
# (y compris le nettoyage). Refus ⇒ rien n'est lancé. Placé ici, et pas
# seulement dans setup2.sh, parce que le déploiement « tout le lab » appelle ce
# script directement pour chaque app.
if ! registry_is_superuser "$(registry_app_owner "$APP_NAME")"; then
  # Journal sans secret (contrat v3, I4) : voir setup2.sh.
  export LAB_JOURNAL_REDACT=1
  echo -e "\033[0;36m══ $APP_NAME — contrôle de sûreté (validate-app.sh)\033[0m"
  if ! bash "$SCRIPT_DIR/validate-app.sh" "$APP_NAME"; then
    echo -e "\033[0;31m✗ ERROR : $APP_NAME refusée par validate-app.sh — rien n'a été lancé.\033[0m" >&2
    exit 1
  fi
  echo -e "\033[0;32m✓ $APP_NAME — contenu validé.\033[0m"
fi

# ── Portes de qualité (contrat v5, I4/I8) ─────────────────────────────────────
# Une app « à portes » est une app qui a une ligne dans .owners : toute app d'un
# développeur, et toute app créée après le chantier multi-dev (new-app.sh écrit
# la ligne pour tout le monde). Pour elle, le déploiement change d'ordre :
#
#     build → tests backend → client Keycloak → schéma → démarrage → cloisonnement
#
# et, surtout, il ne commence PAS par clean2.sh : tant que les tests ne sont pas
# verts, les conteneurs en service ne sont pas touchés. Un test rouge arrête
# tout et laisse l'ancienne version tourner. (Le client Keycloak vient APRÈS les
# tests pour la même raison : il régénère le secret d'un client confidentiel,
# ce qui casserait l'authentification de la version encore en service.)
# Les apps historiques, sans ligne .owners, gardent exactement l'ordre d'avant.
GATED=false
registry_has_owner_line "$APP_NAME" && GATED=true
if $GATED && registry_is_superuser "$(registry_app_owner "$APP_NAME")"; then
  # App du superutilisateur créée après le chantier : pas de contrôle de sûreté
  # (il a Docker), mais les règles de développement valent pour tous.
  echo -e "\033[0;36m══ $APP_NAME — portes de qualité (validate-app.sh --quality-only)\033[0m"
  if ! bash "$SCRIPT_DIR/validate-app.sh" "$APP_NAME" --quality-only; then
    echo -e "\033[0;31m✗ ERROR : $APP_NAME refusée par les portes de qualité — rien n'a été lancé.\033[0m" >&2
    exit 1
  fi
fi
APP_DIR_UNIT="$(registry_app_dir "$APP_NAME")"

# Depuis un conteneur (serveur MCP) : si sso-lab est arrêté, on s'arrête AVANT
# le nettoyage — sans Keycloak rien ne pourra être redéployé, autant ne pas
# couper l'app qui tourne. Sur l'hôte, rien ne change (sso-lab y est relancé
# plus bas, comme avant).
# shellcheck source=lib/kcprobe.sh
source "$SCRIPT_DIR/lib/kcprobe.sh"
if kc_probe_in_container; then
  _KC_PORT_EARLY=$(grep -E '^PORT_KEYCLOAK=' "$ROOT_DIR/sso-lab/.env" 2>/dev/null | cut -d= -f2 | tr -d '[:space:]' || true)
  case "$(kc_probe_sso_state "${_KC_PORT_EARLY:-8080}")" in
    up|starting) ;;
    *) echo -e "\033[0;31m✗ ERROR : sso-lab ne répond pas — à relancer depuis l'hôte par l'administrateur du lab. Rien n'a été touché.\033[0m" >&2
       exit 1 ;;
  esac
fi

if $GATED; then
  echo -e "\033[0;36m══ $APP_NAME — pas de nettoyage préalable : la version en service reste en place jusqu'aux tests\033[0m"
else
  echo -e "\033[0;36m══ $APP_NAME — nettoyage (clean2.sh)\033[0m"
  bash "$SCRIPT_DIR/clean2.sh" "$APP_NAME"
  echo -e "\033[0;32m✓ $APP_NAME — remise à zéro.\033[0m"
fi

# ── sso-lab : démarré uniquement s'il ne tourne pas déjà (cas courant lors du
# dispatch parallèle depuis setup2.sh, qui l'a déjà démarré avant) ───────────
echo -e "\033[0;36m══ $APP_NAME — sso-lab\033[0m"
_KC_PORT_PROBE=$(grep -E '^PORT_KEYCLOAK=' "$ROOT_DIR/sso-lab/.env" 2>/dev/null | cut -d= -f2 | tr -d '[:space:]' || true)
_KC_PORT_PROBE="${_KC_PORT_PROBE:-8080}"
# La sonde vise une adresse valable d'où l'on est (scripts/lib/kcprobe.sh) :
# depuis un conteneur, `localhost` ne désigne pas l'hôte.
# shellcheck source=lib/kcprobe.sh
source "$SCRIPT_DIR/lib/kcprobe.sh"
_SSO_STATE="$(kc_probe_sso_state "$_KC_PORT_PROBE")"
if [[ "$_SSO_STATE" == "up" ]]; then
  echo -e "\033[0;33m⚠ sso-lab déjà actif — redémarrage ignoré.\033[0m"
elif kc_probe_in_container; then
  # Depuis un conteneur (serveur MCP), on ne relance JAMAIS sso-lab : c'est
  # l'infrastructure commune, et un `docker compose up` lancé d'ici résoudrait
  # les chemins du compose depuis ce conteneur. Soit Keycloak démarre (on
  # l'attend juste en dessous), soit c'est une panne à traiter depuis l'hôte.
  if [[ "$_SSO_STATE" == "starting" ]]; then
    echo -e "\033[0;33m⚠ le conteneur keycloak tourne mais ne répond pas encore — attente.\033[0m"
  else
    echo -e "\033[0;31m✗ ERROR : sso-lab ne répond pas (état : ${_SSO_STATE}) — à relancer depuis l'hôte par l'administrateur du lab. L'app n'a pas été redéployée.\033[0m" >&2
    exit 1
  fi
else
  bash "$SCRIPT_DIR/recompose_docker.sh" --app sso-lab
  echo -e "\033[0;32m✓ sso-lab démarré.\033[0m"
fi

# ── Attente Keycloak (immédiat si déjà prêt — coût quasi nul lors du dispatch
# parallèle, où sso-lab est déjà démarré par setup2.sh avant l'appel) ────────
KC_PORT=$(grep -E '^PORT_KEYCLOAK=' "$ROOT_DIR/sso-lab/.env" 2>/dev/null | cut -d= -f2 | tr -d '[:space:]' || true)
KC_PORT="${KC_PORT:-8080}"
KC_HEALTH="$(kc_probe_url "$KC_PORT")"
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

BACKEND_TESTS="non-lancé"
if $GATED; then
  _dc() { docker compose --project-directory "$APP_DIR_UNIT" -f "$APP_DIR_UNIT/docker-compose.yml" "$@"; }
  echo -e "\033[0;36m══ $APP_NAME — build (la version en service n'est pas touchée)\033[0m"
  if ! _dc build 2>&1 | sed 's/^/  /'; then
    echo -e "\033[0;31m✗ ERROR : $APP_NAME — build en échec. Rien n'a été mis en service ; la version précédente tourne toujours.\033[0m" >&2
    exit 1
  fi
  echo -e "\033[0;36m══ $APP_NAME — tests backend avant mise en service (app-test.sh)\033[0m"
  _test_out="$(bash "$SCRIPT_DIR/app-test.sh" "$APP_NAME" 2>&1)"; _test_rc=$?
  printf '%s\n' "$_test_out" | grep -v '^RESULTAT=' | sed 's/^/  /'
  BACKEND_TESTS="$(printf '%s\n' "$_test_out" | sed -n 's/^RESULTAT=//p' | tail -1)"
  [[ -n "$BACKEND_TESTS" ]] || BACKEND_TESTS="ko"
  if [[ $_test_rc -ne 0 || "$BACKEND_TESTS" == "ko" ]]; then
    echo -e "\033[0;31m✗ ERROR : $APP_NAME — tests backend ROUGES. Le déploiement s'arrête ici : rien n'a été mis en service, la version précédente tourne toujours.\033[0m" >&2
    exit 1
  fi
  echo -e "\033[0;32m✓ $APP_NAME — tests backend : ${BACKEND_TESTS}.\033[0m"
fi

# Les deux étapes suivantes n'affichent plus une coche verte sur un échec.
#   • client Keycloak en échec : l'app est démarrée quand même (pour une app
#     historique, clean2.sh l'a déjà arrêtée : ne pas la redémarrer la laisserait
#     hors service pour un incident Keycloak passager), mais le script se
#     termine en ERREUR — son .env n'a peut-être pas reçu ses clés KEYCLOAK_*.
#   • schéma impossible : on NE démarre PAS. Sans son schéma, Django écrit dans
#     `public` et croit ses migrations faites — backend « up », base vide.
CLIENT_FAILED=false
echo -e "\033[0;36m══ $APP_NAME — client Keycloak\033[0m"
if bash "$SCRIPT_DIR/create-app-client.sh" "$APP_NAME"; then
  echo -e "\033[0;32m✓ $APP_NAME — client Keycloak configuré.\033[0m"
else
  CLIENT_FAILED=true
  echo -e "\033[0;31m✗ ERROR : $APP_NAME — create-app-client.sh a échoué (voir ci-dessus). Le déploiement continue, mais se terminera en erreur.\033[0m" >&2
fi

echo -e "\033[0;36m══ $APP_NAME — schéma Postgres\033[0m"
if ! bash "$SCRIPT_DIR/ensure-schemas.sh" "$APP_NAME"; then
  echo -e "\033[0;31m✗ ERROR : $APP_NAME — schéma PostgreSQL impossible (base du propriétaire absente, ou .env désignant une autre base). Les containers ne sont PAS démarrés.\033[0m" >&2
  exit 1
fi
echo -e "\033[0;32m✓ $APP_NAME — schéma vérifié.\033[0m"

echo -e "\033[0;36m══ $APP_NAME — démarrage des containers\033[0m"
# Un build ou un démarrage raté est une ERREUR, dite comme telle et rendue par
# le code de sortie : sans ça, l'appelant (setup2.sh, serveur MCP) lirait
# « ✓ déployée » sur une app qui ne tourne pas.
if $GATED; then
  # Les images sont déjà construites et testées : on remplace les conteneurs.
  # Ni `down`, ni suppression de volumes — les données d'un volume nommé
  # survivent au déploiement.
  if ! _dc up -d --remove-orphans 2>&1 | sed 's/^/  /'; then
    echo -e "\033[0;31m✗ ERROR : $APP_NAME — démarrage des containers en échec (voir le journal ci-dessus).\033[0m" >&2
    exit 1
  fi
  # Les images remplacées n'ont plus de nom : on ne les laisse pas s'empiler.
  docker image prune -f > /dev/null 2>&1 || true
elif ! bash "$SCRIPT_DIR/recompose_docker.sh" --app "$APP_NAME" --force; then
  echo -e "\033[0;31m✗ ERROR : $APP_NAME — build ou démarrage des containers en échec (voir le journal ci-dessus).\033[0m" >&2
  exit 1
fi
# Déploiement réussi : on retient QUEL commit tourne (lu par app-status.sh).
# Seulement ici — jamais sur un refus de validate-app.sh ni sur un build raté,
# qui sortent plus haut.
registry_record_deployed "$APP_NAME" "$BACKEND_TESTS" "non-lancé" \
  || echo -e "\033[1;33m⚠ SHA déployé non enregistré (dossier d'état inaccessible) — app-status.sh rendra l'ancien.\033[0m"
echo -e "\033[0;32m✓ $APP_NAME déployée.\033[0m"

# (Contrat v11, I4 : plus de synchronisation d'un catalogue de tests vers
# lab-admin ici — ni appel à son `catalog-sync`, ni génération de
# SETUP_CATALOG_KEY dans son .env. Un déploiement n'écrit plus rien chez lab-admin.)

# ── Test de cloisonnement après déploiement (contrat v5, I4) ──────────────────
# Pour une app « à portes » seulement (pour les apps historiques, l'exécution
# reste déclenchée à la main depuis lab-admin). Navigateur réel dans lab-runner,
# un seul run à la fois sur tout le lab (il répond 409 s'il est occupé). Le
# verdict est ENREGISTRÉ avec le déploiement et affiché ; un échec n'annule pas
# le déploiement — mais « absent » veut dire « aucun test trouvé », jamais
# « tout va bien ».
if $GATED; then
  echo -e "\033[0;36m══ $APP_NAME — test de cloisonnement (lab-runner)\033[0m"
  CLOISON="non-lancé"
  _run="$(docker exec lab-runner curl -s --max-time 900 -X POST -H 'Content-Type: application/json' \
            -d "{\"app\":\"${APP_NAME}\"}" "http://localhost:4300/run" 2>/dev/null || true)"
  case "$(jq -r 'if type == "array" then (if length == 0 then "absent" elif all(.[]; .status == "PASSED") then "ok" else "ko" end) else "non-lancé" end' <<< "$_run" 2>/dev/null)" in
    ok)     CLOISON="ok" ;;
    ko)     CLOISON="ko" ;;
    absent) CLOISON="absent" ;;
    *)      CLOISON="non-lancé" ;;
  esac
  registry_record_deployed "$APP_NAME" - "$CLOISON" || true
  case "$CLOISON" in
    ok)     echo -e "\033[0;32m✓ Cloisonnement : tous les tests passent.\033[0m" ;;
    ko)     echo -e "\033[0;31m✗ Cloisonnement : au moins un test ÉCHOUE — l'app est déployée, mais son cloisonnement est à corriger :\033[0m"
            jq -r '.[] | select(.status != "PASSED") | "    " + .status + " — " + .title' <<< "$_run" 2>/dev/null | head -20 ;;
    absent) echo -e "\033[1;33m⚠ Cloisonnement : aucun test trouvé pour cette app (ce n'est pas « tout va bien »).\033[0m" ;;
    *)      echo -e "\033[1;33m⚠ Cloisonnement : test non lancé (lab-runner occupé, arrêté, ou app injoignable) : $(jq -r '.error // empty' <<< "$_run" 2>/dev/null | cut -c1-160)\033[0m" ;;
  esac
fi

if $CLIENT_FAILED; then
  echo -e "\033[0;31m✗ ERROR : $APP_NAME est démarrée, mais son client Keycloak n'a pas pu être configuré — à relancer.\033[0m" >&2
  exit 1
fi
