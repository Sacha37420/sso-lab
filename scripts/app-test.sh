#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# app-test.sh — lance les tests BACKEND d'une app, dans un conteneur jetable de
#               l'image qui vient d'être construite.
# Contrat « multi-dev » v5, interfaces I4/I8.
#
# Usage :
#   bash scripts/app-test.sh <app>
#
# Code : 0 = tests verts, ou aucun test backend à lancer ;
#        1 = tests rouges (ou impossibles à lancer : image absente, base…) ;
#        2 = erreur d'usage.
# Dernière ligne de stdout, lisible par une machine :
#        « RESULTAT=ok » · « RESULTAT=ko » · « RESULTAT=absent »
#
# Appelé par setup_unit.sh ENTRE le build et le démarrage : un test rouge
# arrête le déploiement et laisse la version précédente en service. Peut aussi
# être lancé seul, après un `docker compose build`.
#
# QUELLE COMMANDE : la première ligne de la section « ## Commande de test » de
# FEUILLE_DE_ROUTE.md ; à défaut `python manage.py test`. Le mot « aucune »
# déclare qu'il n'y a pas de test backend.
# QUEL SERVICE : celui dont le contexte de build contient manage.py ; à défaut
# le service nommé `backend` ; à défaut, rien à tester (RESULTAT=absent).
#
# LA BASE — le point qui demande un détour : le lanceur de tests de Django crée
# une base `test_<nom>`, or le rôle d'une app (dev_<uid>) est NOCREATEDB, et
# c'est voulu (I2). Le test tourne donc avec un rôle TRANSITOIRE, créé pour
# l'occasion par le rôle d'administration de l'instance :
#     lab_test_<aléa>   LOGIN CREATEDB, membre de dev_<uid>, mot de passe aléatoire
# Il peut créer sa base de test et lire ce que lit l'app — rien de plus que ce
# que le code testé sait déjà faire une fois déployé. À la fin, quoi qu'il
# arrive : ses bases sont supprimées, puis le rôle. Les données de l'app ne
# sont jamais touchées par le lanceur (il travaille dans test_<nom>).
# Pour une app historique (rôle devuser, superutilisateur), aucun rôle
# transitoire : le .env est utilisé tel quel.
#
# ENFERMEMENT du conteneur de test : réseau dev-net seul (la base), aucun
# volume, aucun port, cap_drop ALL, no-new-privileges, 1 Go, 1 vCPU, 512
# processus, durée bornée (LAB_TEST_TIMEOUT, défaut 900 s). Les variables
# passent par un fichier d'environnement temporaire en 600 — rien en argument.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/registry.sh
source "$SCRIPT_DIR/lib/registry.sh"
# shellcheck source=lib/lock.sh
source "$SCRIPT_DIR/lib/lock.sh"
ROOT="$(registry_root)"

log()    { echo "$*" >&2; }
result() { echo "RESULTAT=$1"; }
die()    { echo "✗ app-test : $*" >&2; result ko; exit 1; }

[[ $# -eq 1 ]] || { echo "Usage : bash scripts/app-test.sh <app>" >&2; exit 2; }
APP="$1"
APP_DIR="$(registry_app_dir "$APP")" || { echo "✗ nom d'app invalide : '$APP'" >&2; exit 2; }
COMPOSE="$APP_DIR/docker-compose.yml"
[[ -f "$COMPOSE" ]] || { echo "✗ app inconnue : '$APP'" >&2; exit 2; }

# ── Commande de test ──────────────────────────────────────────────────────────
TEST_CMD=""
if [[ -f "$APP_DIR/FEUILLE_DE_ROUTE.md" ]]; then
  TEST_CMD="$(awk '
      /^## Commande de test[[:space:]]*$/ { inside = 1; next }
      inside && /^## /                    { exit }
      inside && /^[[:space:]]*$/          { next }
      inside && /^[[:space:]]*<!--/       { next }
      inside { gsub(/^[[:space:]]*`?|`?[[:space:]]*$/, ""); print; exit }' "$APP_DIR/FEUILLE_DE_ROUTE.md")"
fi
[[ -n "$TEST_CMD" ]] || TEST_CMD="python manage.py test"
if [[ "${TEST_CMD,,}" == "aucune" || "${TEST_CMD,,}" == "aucun" ]]; then
  log "· $APP : la feuille de route déclare qu'il n'y a pas de test backend."
  result absent; exit 0
fi
# Lancée par `sh -c` DANS le conteneur de l'app : c'est le code du dev, dans son
# image, avec ses droits. Une seule ligne, longueur bornée.
[[ "$TEST_CMD" != *$'\n'* && ${#TEST_CMD} -le 500 ]] || die "commande de test invalide dans FEUILLE_DE_ROUTE.md (une ligne, 500 caractères au plus)"

# ── Service et image ──────────────────────────────────────────────────────────
MODEL="$(docker compose --project-directory "$APP_DIR" -f "$COMPOSE" config --format json --no-env-resolution 2>/dev/null)" \
  || die "docker-compose.yml illisible"
SERVICE="$(jq -r '.services | to_entries[] | select(.value.build != null)
                  | [.key, (.value.build.context // "")] | @tsv' <<< "$MODEL" \
           | while IFS=$'\t' read -r _s _ctx; do [[ -f "$_ctx/manage.py" ]] && { echo "$_s"; break; }; done)"
if [[ -z "$SERVICE" ]]; then
  SERVICE="$(jq -r '.services | has("backend") | if . then "backend" else "" end' <<< "$MODEL")"
fi
if [[ -z "$SERVICE" ]]; then
  log "· $APP : aucun service backend (pas de manage.py dans un contexte de build) — rien à tester."
  result absent; exit 0
fi
IMAGE="$(jq -r --arg s "$SERVICE" --arg p "$APP" '.services[$s].image // ($p + "-" + $s)' <<< "$MODEL")"
docker image inspect "$IMAGE" > /dev/null 2>&1 \
  || die "image '$IMAGE' absente — construire d'abord (docker compose build), ce que fait le déploiement"

lab_lock_acquire "app-test.sh $APP" || exit $?

# ── Base : rôle transitoire pour une app à rôle dev_<uid> ─────────────────────
_env() { grep -E "^$1=" "$APP_DIR/.env" 2>/dev/null | tail -1 | cut -d= -f2- | sed -e "s/^['\"]//" -e "s/['\"]\$//"; }
_infra() { grep -E "^$1=" "$ROOT/infra/.env" 2>/dev/null | tail -1 | cut -d= -f2-; }
DB_HOST="$(_env DB_HOST)"; DB_USER="$(_env DB_USER)"; DB_NAME="$(_env DB_NAME)"
if [[ "$DB_HOST" == "postgis" ]]; then
  PG_CONTAINER="dev-postgis"; PG_ADMIN="$(_infra POSTGIS_USER)"; PG_ADMIN="${PG_ADMIN:-gisuser}"; PASS_KEY="POSTGIS_PASSWORD"
else
  PG_CONTAINER="dev-postgres"; PG_ADMIN="$(_infra POSTGRES_USER)"; PG_ADMIN="${PG_ADMIN:-devuser}"; PASS_KEY="DB_PASSWORD"
fi
psql_admin() { docker exec -i "$PG_CONTAINER" psql -X -U "$PG_ADMIN" -d postgres -v ON_ERROR_STOP=1 -q "$@"; }

TMP="$(umask 077; mktemp -d)"
TEST_ROLE=""
CNAME="${APP}-test-$$"
cleanup() {
  docker rm -f "$CNAME" > /dev/null 2>&1 || true
  if [[ -n "$TEST_ROLE" ]]; then
    # Bases créées par le rôle transitoire (test_<nom>, et leurs variantes
    # parallèles test_<nom>_1…), puis le rôle lui-même.
    local db
    while IFS= read -r db; do
      [[ "$db" =~ ^[A-Za-z0-9_]+$ ]] || continue
      psql_admin <<< "DROP DATABASE IF EXISTS \"$db\" WITH (FORCE);" > /dev/null 2>&1 || true
    done < <(docker exec "$PG_CONTAINER" psql -X -U "$PG_ADMIN" -d postgres -tAc \
               "SELECT datname FROM pg_database d JOIN pg_roles r ON r.oid = d.datdba WHERE r.rolname = '${TEST_ROLE}'" < /dev/null 2>/dev/null || true)
    # Le droit CONNECT sur « postgres » est une dépendance : sans ce REVOKE,
    # DROP ROLE échoue et le rôle transitoire resterait en base.
    psql_admin <<< "REVOKE CONNECT ON DATABASE postgres FROM \"${TEST_ROLE}\";" > /dev/null 2>&1 || true
    psql_admin <<< "DROP ROLE IF EXISTS \"${TEST_ROLE}\";" > /dev/null 2>&1 \
      || log "⚠ le rôle transitoire ${TEST_ROLE} n'a pas pu être supprimé (${PG_CONTAINER}) — à retirer à la main"
  fi
  [[ -d "$TMP" ]] && { find "$TMP" -type f -delete 2>/dev/null; rmdir "$TMP" 2>/dev/null; } || true
}
trap cleanup EXIT

# Fichier d'environnement du conteneur de test : le .env de l'app, puis nos
# surcharges (docker prend la DERNIÈRE occurrence d'une clé).
grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$APP_DIR/.env" > "$TMP/env" 2>/dev/null || true

if [[ "$DB_USER" =~ ^dev_[a-z][a-z0-9]{1,30}$ && -n "$DB_NAME" ]]; then
  TEST_ROLE="lab_test_$(LC_ALL=C tr -dc 'a-z0-9' < /dev/urandom | head -c 12 || true)"
  TEST_PW="$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 40 || true)"
  [[ ${#TEST_ROLE} -eq 21 && ${#TEST_PW} -eq 40 ]] || die "génération du rôle de test impossible"
  # SQL sur stdin : le mot de passe ne passe par aucune ligne de commande.
  if ! psql_admin <<SQL
CREATE ROLE "${TEST_ROLE}" WITH LOGIN CREATEDB NOSUPERUSER NOCREATEROLE NOREPLICATION PASSWORD '${TEST_PW}' VALID UNTIL 'tomorrow';
GRANT "${DB_USER}" TO "${TEST_ROLE}";
-- La base de maintenance « postgres » est fermée à PUBLIC (dev-db.sh
-- lockdown-connect) : sans ce droit, le lanceur de tests de Django ne peut ni
-- créer ni SUPPRIMER sa base de test (« cannot drop the currently open
-- database », constaté le 2026-10-11). Droit limité à ce rôle transitoire.
GRANT CONNECT ON DATABASE postgres TO "${TEST_ROLE}";
SQL
  then
    TEST_ROLE=""
    die "création du rôle de test impossible sur ${PG_CONTAINER}"
  fi
  printf 'DB_USER=%s\n%s=%s\n' "$TEST_ROLE" "$PASS_KEY" "$TEST_PW" >> "$TMP/env"
  log "· rôle transitoire ${TEST_ROLE} créé pour la base de test (supprimé en sortie)"
fi

# ── Lancement ─────────────────────────────────────────────────────────────────
TIMEOUT="${LAB_TEST_TIMEOUT:-900}"; [[ "$TIMEOUT" =~ ^[0-9]+$ ]] || TIMEOUT=900
log "▶ tests backend de $APP — service « $SERVICE », image $IMAGE"
log "  commande : $TEST_CMD"
# La commande est transmise par une variable d'environnement et lancée par
# `sh -c` : pas d'interpolation côté hôte.
printf 'LAB_TEST_CMD=%s\n' "$TEST_CMD" >> "$TMP/env"
rc=0
timeout --signal=TERM --kill-after=20 "$TIMEOUT" \
  docker run --rm --name "$CNAME" \
    --network dev-net \
    --env-file "$TMP/env" \
    --cap-drop ALL --security-opt no-new-privileges \
    --memory 1g --memory-swap 1g --cpus 1 --pids-limit 512 \
    --entrypoint sh "$IMAGE" -c 'exec sh -c "$LAB_TEST_CMD"' 2>&1 || rc=$?

if [[ $rc -eq 0 ]]; then
  log "✓ tests backend de $APP : verts"
  result ok; exit 0
fi
if [[ $rc -eq 124 || $rc -eq 137 ]]; then
  log "✗ tests backend de $APP : interrompus après ${TIMEOUT}s (ou mémoire dépassée) — code $rc"
else
  log "✗ tests backend de $APP : ROUGES (code $rc)"
fi
result ko; exit 1
