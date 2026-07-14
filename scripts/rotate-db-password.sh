#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════════════
# rotate-db-password.sh — Rotation À CHAUD du mot de passe PostgreSQL partagé.
#
# CONTEXTE : toutes les apps du lab partagent le rôle `devuser` de la base
# `devdb` (isolées seulement par schéma). Le mot de passe est donc unique pour
# tout le lab. Sa source de vérité est infra/.env : POSTGRES_PASSWORD.
#
# CE QUE FAIT CE SCRIPT :
#   1. génère un nouveau mot de passe (50 car. alphanumériques) ;
#   2. ALTER ROLE devuser sur le Postgres EN COURS (le mot de passe d'un volume
#      déjà initialisé ne se change QUE par ALTER ROLE — POSTGRES_PASSWORD dans
#      infra/.env n'est lu qu'à la création du volume, jamais ensuite) ;
#   3. écrit la nouvelle valeur dans infra/.env.
#
# La PROPAGATION vers le DB_PASSWORD de chaque app est faite par reset_url.sh
# (source : ce même POSTGRES_PASSWORD). setup2.sh enchaîne les deux dans le bon
# ordre. En usage autonome, lancer `bash reset_url.sh` juste après, puis
# redémarrer les backends.
#
# À noter : `devuser` est en `trust` sur les réseaux Docker/LAN (voir
# infra/init/01_pg_hba_trust.sh), donc les backends restent connectés même avec
# un ancien mot de passe en mémoire. La rotation ferme malgré tout le chemin
# scram-sha-256 (accès mot de passe) et retire la valeur publiée de la circulation.
#
# Usage :
#   bash rotate-db-password.sh [--yes]
# ══════════════════════════════════════════════════════════════════════════════
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
INFRA_ENV="$SCRIPT_DIR/infra/.env"
PG_CONTAINER="${PG_CONTAINER:-dev-postgres}"

FORCE=false
for a in "$@"; do
  case "$a" in
    --yes|-y) FORCE=true ;;
    *) echo "Argument inconnu : $a" >&2; exit 1 ;;
  esac
done

[[ -f "$INFRA_ENV" ]] || { echo "✗ $INFRA_ENV introuvable." >&2; exit 1; }

_env_val() { grep -E "^$1=" "$INFRA_ENV" 2>/dev/null | head -1 | cut -d= -f2-; }
DB_USER="$(_env_val POSTGRES_USER)"; DB_USER="${DB_USER:-devuser}"
DB_NAME="$(_env_val POSTGRES_DB)";   DB_NAME="${DB_NAME:-devdb}"

# Postgres doit tourner : ALTER ROLE agit sur l'instance vivante, pas sur infra/.env.
if ! docker ps --format '{{.Names}}' | grep -qx "$PG_CONTAINER"; then
  echo "✗ Conteneur '$PG_CONTAINER' non démarré — rotation impossible." >&2
  echo "  Démarrez l'infra (bash recompose_docker.sh --app infra) puis relancez." >&2
  exit 1
fi

if ! $FORCE; then
  echo ""
  echo "⚠️  Rotation du mot de passe PostgreSQL PARTAGÉ (rôle '$DB_USER', base '$DB_NAME')."
  echo "   Impacte TOUTES les apps du lab. Nouveau mot de passe appliqué à chaud,"
  echo "   écrit dans infra/.env, puis propagé aux apps par reset_url.sh."
  printf "   Continuer ? [y/N] "
  read -r c; [[ "$c" =~ ^[Yy]$ ]] || { echo "Annulé."; exit 0; }
fi

NEW=$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 50)

# ALTER ROLE — le mot de passe est purement alphanumérique, donc sans quote à
# échapper dans la chaîne SQL.
if ! docker exec "$PG_CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" -v ON_ERROR_STOP=1 -q \
       -c "ALTER ROLE \"$DB_USER\" WITH PASSWORD '$NEW';" >/dev/null 2>&1; then
  echo "✗ ALTER ROLE échoué — infra/.env laissé intact, ancien mot de passe toujours valide." >&2
  exit 1
fi

# La base a bien accepté le changement : on peut mettre à jour la source de vérité.
if grep -qE '^POSTGRES_PASSWORD=' "$INFRA_ENV"; then
  sed -i "s|^POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=${NEW}|" "$INFRA_ENV"
else
  printf '\nPOSTGRES_PASSWORD=%s\n' "$NEW" >> "$INFRA_ENV"
fi

echo "✓ Mot de passe PostgreSQL roté (ALTER ROLE + infra/.env)."
echo "  → Propagation aux apps : bash reset_url.sh   (fait automatiquement par setup2.sh)"
