#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# ensure-schemas.sh — garantit que le schéma Postgres de chaque app existe
#                     dans la base *qui tourne*.
#
# POURQUOI
#   infra/init/00_schemas.sql (ou infra/init-postgis/00_schemas.sql) n'est joué
#   qu'à l'initialisation du volume Postgres. Une app créée alors que l'instance
#   tourne déjà n'a donc pas son schéma. Django, dont le search_path est
#   « <schema>,public », se rabat alors sur public et y crée ses tables — en
#   silence : comme toutes les apps du lab partagent le même app label « api »,
#   Django y lit un « api|0001_initial » laissé par une autre app, conclut
#   « No migrations to apply » et ne crée aucune table, sans la moindre erreur.
#   Symptôme : backend up, logs propres, base vide.
#
#   Ce script rejoue les CREATE SCHEMA à chaud. Il est idempotent.
#
#   DEUX INSTANCES possibles (cf. infra/docker-compose.yml) : 'postgres' (base
#   devdb, la grande majorité des apps) et 'postgis' (base gisdb, apps SIG type
#   carto-lab — extension PostGIS absente de l'image alpine de 'postgres'). Le
#   choix se lit dans DB_HOST de chaque app : ce script route donc chaque app
#   vers le bon container au lieu de cibler dev-postgres pour toutes.
#
# USAGE
#   bash ensure-schemas.sh            # toutes les apps déclarant un DB_SCHEMA
#   bash ensure-schemas.sh mon-app    # une seule app
#
#   Appelé automatiquement par new-app.sh (à la création) et par setup2.sh
#   (avant le démarrage des containers, donc avant le premier `migrate`).
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
ok()   { echo -e "  ${GREEN}✔ $*${NC}"; }
warn() { echo -e "  ${YELLOW}⚠ $*${NC}"; }
info() { echo -e "  ${CYAN}→ $*${NC}"; }

DEV_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ONLY_APP="${1:-}"

RUNNING_CONTAINERS="$(docker ps --format '{{.Names}}' || true)"
_container_up() { grep -qx "$1" <<< "$RUNNING_CONTAINERS"; }

created=0
checked=0

for env_file in "$DEV_DIR"/*/.env; do
  [[ -f "$env_file" ]] || continue

  app="$(basename "$(dirname "$env_file")")"
  [[ -n "$ONLY_APP" && "$app" != "$ONLY_APP" ]] && continue

  # shellcheck disable=SC2016
  schema="$(sed -n 's/^DB_SCHEMA=//p'  "$env_file" | tr -d '"'"'"'\r' | xargs || true)"
  [[ -z "$schema" ]] && continue   # app sans base (Angular seul, etc.)

  host="$(sed -n 's/^DB_HOST=//p' "$env_file" | tr -d '"'"'"'\r' | xargs || true)"
  db="$(sed -n 's/^DB_NAME=//p'  "$env_file" | tr -d '"'"'"'\r' | xargs || true)"
  user="$(sed -n 's/^DB_USER=//p' "$env_file" | tr -d '"'"'"'\r' | xargs || true)"

  # Route vers le bon container selon l'instance déclarée par l'app (DB_HOST).
  if [[ "$host" == "postgis" ]]; then
    container="dev-postgis"; db="${db:-gisdb}"; user="${user:-gisuser}"
  else
    container="dev-postgres"; db="${db:-devdb}"; user="${user:-devuser}"
  fi

  checked=$((checked + 1))

  if ! _container_up "$container"; then
    warn "${app} → container '${container}' non démarré, schéma '${schema}' ignoré"
    continue
  fi

  exists="$(docker exec "$container" psql -U "$user" -d "$db" -tAc \
    "SELECT 1 FROM pg_namespace WHERE nspname = '${schema}'" 2>/dev/null || true)"

  if [[ "$exists" == "1" ]]; then
    info "${app} → schéma '${schema}' déjà présent (${container})"
    continue
  fi

  if docker exec "$container" psql -U "$user" -d "$db" -v ON_ERROR_STOP=1 -q \
    -c "CREATE SCHEMA IF NOT EXISTS \"${schema}\" AUTHORIZATION \"${user}\";"; then
    ok "${app} → schéma '${schema}' créé (${container})"
    created=$((created + 1))
  else
    warn "${app} → échec de création du schéma '${schema}' sur ${container}"
  fi
done

if [[ -n "$ONLY_APP" && $checked -eq 0 ]]; then
  warn "Aucun DB_SCHEMA trouvé pour '${ONLY_APP}' (app sans base ?)."
fi

[[ $created -gt 0 ]] && ok "${created} schéma(s) créé(s)."
exit 0
