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
#   UNE BASE PAR DÉVELOPPEUR (contrat multi-dev, I2) : le schéma est créé dans
#   la base que déclare le .env de l'app (DB_NAME — devdb/gisdb pour les apps
#   historiques, dev_<uid>/gis_<uid> sinon), et il appartient au rôle de l'app
#   (DB_USER). La création elle-même est faite par le rôle d'ADMINISTRATION de
#   l'instance (POSTGRES_USER / POSTGIS_USER de infra/.env, via le socket local
#   du conteneur) : un rôle dev_<uid> n'a pas à savoir créer quoi que ce soit
#   pour que son app démarre, et ce script n'a pas à connaître son mot de passe.
#   Pour une app dont le propriétaire n'est pas le superutilisateur, le .env
#   doit désigner SA base et SON rôle — sinon le schéma n'est pas créé : on ne
#   fabrique jamais un schéma dans la base de quelqu'un d'autre.
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
# shellcheck source=lib/registry.sh
source "$DEV_DIR/scripts/lib/registry.sh"
ONLY_APP="${1:-}"
if [[ -n "$ONLY_APP" ]] && ! registry_app_dir "$ONLY_APP" > /dev/null; then
  echo "Nom d'app invalide : '$ONLY_APP'" >&2; exit 1
fi

_infra_val() { grep -E "^$1=" "$DEV_DIR/infra/.env" 2>/dev/null | tail -1 | cut -d= -f2- || true; }
PG_ADMIN="$(_infra_val POSTGRES_USER)";  PG_ADMIN="${PG_ADMIN:-devuser}"
GIS_ADMIN="$(_infra_val POSTGIS_USER)";  GIS_ADMIN="${GIS_ADMIN:-gisuser}"
SUPERUSER="$(registry_superuser)"

RUNNING_CONTAINERS="$(docker ps --format '{{.Names}}' || true)"
_container_up() { grep -qx "$1" <<< "$RUNNING_CONTAINERS"; }

created=0
checked=0
refused=0

# Les deux emplacements d'apps (contrat v5) : $ROOT/<app> et deploiement/<app>.
while IFS= read -r _env_dir; do
  env_file="$_env_dir/.env"
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
    container="${GIS_CONTAINER:-dev-postgis}"; db="${db:-gisdb}"; user="${user:-gisuser}"; admin="$GIS_ADMIN"
    own_db_prefix="gis_"
  else
    container="${PG_CONTAINER:-dev-postgres}"; db="${db:-devdb}"; user="${user:-devuser}"; admin="$PG_ADMIN"
    own_db_prefix="dev_"
  fi

  checked=$((checked + 1))

  # Ces trois valeurs partent dans du SQL : on n'accepte que des identifiants.
  if [[ ! "$schema" =~ ^[a-z_][a-z0-9_]*$ || ! "$db" =~ ^[a-z_][a-z0-9_]*$ || ! "$user" =~ ^[a-z_][a-z0-9_]*$ ]]; then
    warn "${app} → DB_SCHEMA/DB_NAME/DB_USER ne sont pas des identifiants simples, schéma ignoré"
    refused=$((refused + 1))
    continue
  fi

  # App d'un développeur : elle ne vit QUE dans sa base, avec son rôle.
  owner="$(registry_app_owner "$app")"
  if [[ "$owner" != "$SUPERUSER" ]]; then
    if [[ "$db" != "${own_db_prefix}${owner}" || "$user" != "dev_${owner}" ]]; then
      warn "${app} (propriétaire ${owner}) → .env désigne ${db}/${user} au lieu de ${own_db_prefix}${owner}/dev_${owner} — schéma NON créé"
      refused=$((refused + 1))
      continue
    fi
  fi

  if ! _container_up "$container"; then
    warn "${app} → container '${container}' non démarré, schéma '${schema}' ignoré"
    continue
  fi

  db_ok="$(docker exec "$container" psql -X -U "$admin" -d postgres -tAc \
    "SELECT 1 FROM pg_database WHERE datname = '${db}'" 2>/dev/null || true)"
  if [[ "$db_ok" != "1" ]]; then
    warn "${app} → base '${db}' absente de ${container} — schéma '${schema}' ignoré (bash scripts/dev-db.sh ensure <uid>)"
    refused=$((refused + 1))
    continue
  fi

  exists="$(docker exec "$container" psql -X -U "$admin" -d "$db" -tAc \
    "SELECT 1 FROM pg_namespace WHERE nspname = '${schema}'" 2>/dev/null || true)"

  if [[ "$exists" == "1" ]]; then
    info "${app} → schéma '${schema}' déjà présent (${container})"
    continue
  fi

  if docker exec "$container" psql -X -U "$admin" -d "$db" -v ON_ERROR_STOP=1 -q \
    -c "CREATE SCHEMA IF NOT EXISTS \"${schema}\" AUTHORIZATION \"${user}\";"; then
    ok "${app} → schéma '${schema}' créé (${container})"
    created=$((created + 1))
  else
    warn "${app} → échec de création du schéma '${schema}' sur ${container}"
  fi
done < <(registry_dirs_with .env)

if [[ -n "$ONLY_APP" && $checked -eq 0 ]]; then
  warn "Aucun DB_SCHEMA trouvé pour '${ONLY_APP}' (app sans base ?)."
fi

[[ $created -gt 0 ]] && ok "${created} schéma(s) créé(s)."
# En mode « une app », un schéma refusé ou impossible est une erreur de
# l'appelant ; en mode « toutes », on ne fait pas échouer le lab pour une app.
[[ -n "$ONLY_APP" && $refused -gt 0 ]] && exit 1
exit 0
