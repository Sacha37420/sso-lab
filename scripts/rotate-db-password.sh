#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════════════
# rotate-db-password.sh — Rotation À CHAUD des mots de passe PostgreSQL du lab.
#
# QUELS RÔLES (contrat multi-dev) :
#   • devuser  — administration de dev-postgres   → infra/.env : POSTGRES_PASSWORD
#   • gisuser  — administration de dev-postgis    → infra/.env : POSTGIS_PASSWORD
#   • lab      — services du cadriciel (base lab) → infra/dev-roles.env : LAB_PG_PASSWORD
#   • dev_<uid> — un rôle par développeur, sur chaque instance où il existe
#                                                  → infra/dev-roles.env : DEV_PG_PASSWORD__<uid>
#                                                                          DEV_GIS_PASSWORD__<uid>
#
# CE QUE FAIT CE SCRIPT, pour chaque rôle : génère un mot de passe, ALTER ROLE
# sur l'instance EN COURS (un volume déjà initialisé ne change de mot de passe
# que par ALTER ROLE — la variable d'infra/.env n'est lue qu'à la création du
# volume), puis écrit la nouvelle valeur. L'écriture ne vient qu'APRÈS
# l'acceptation par la base : un échec laisse l'ancien mot de passe valide et
# le fichier intact.
#
# La PROPAGATION vers les .env des apps est faite par reset_url.sh, qui ne donne
# à chaque app que le mot de passe du rôle de son propriétaire. setup2.sh
# enchaîne les deux. En usage autonome : `bash scripts/reset_url.sh`, puis
# redémarrer les backends (ils gardent l'ancien mot de passe en mémoire, et
# pg_hba.conf exige un mot de passe sur le réseau : une app non redémarrée
# perd sa base à sa prochaine connexion).
#
# Usage :
#   bash rotate-db-password.sh [--yes] [--only admin|gis|lab|devs]…
#   Sans --only : tout. --only se répète (ex. --only lab --only devs).
# ══════════════════════════════════════════════════════════════════════════════
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
INFRA_ENV="$SCRIPT_DIR/infra/.env"
ROLES_ENV="$SCRIPT_DIR/infra/dev-roles.env"
PG_CONTAINER="${PG_CONTAINER:-dev-postgres}"
GIS_CONTAINER="${GIS_CONTAINER:-dev-postgis}"
export PG_CONTAINER GIS_CONTAINER

FORCE=false
ONLY=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes|-y) FORCE=true ;;
    --only)   [[ $# -gt 1 ]] || { echo "--only requiert une valeur" >&2; exit 1; }; ONLY+=("$2"); shift ;;
    --only=*) ONLY+=("${1#*=}") ;;
    *) echo "Argument inconnu : $1" >&2; exit 1 ;;
  esac
  shift
done
for o in ${ONLY[@]+"${ONLY[@]}"}; do
  case "$o" in admin|gis|lab|devs) ;; *) echo "--only : admin, gis, lab ou devs (reçu : $o)" >&2; exit 1 ;; esac
done
want() { [[ ${#ONLY[@]} -eq 0 ]] && return 0; local o; for o in "${ONLY[@]}"; do [[ "$o" == "$1" ]] && return 0; done; return 1; }

[[ -f "$INFRA_ENV" ]] || { echo "✗ $INFRA_ENV introuvable." >&2; exit 1; }
_env_val() { grep -E "^$1=" "$INFRA_ENV" 2>/dev/null | head -1 | cut -d= -f2-; }
_up() { local up; up="$(docker ps --format '{{.Names}}')"; grep -qx "$1" <<< "$up"; }

if ! $FORCE; then
  echo ""
  echo "⚠️  Rotation des mots de passe PostgreSQL : ${ONLY[*]:-tous les rôles (admin, gis, lab, devs)}."
  echo "   Appliquée à chaud ; les apps doivent ensuite recevoir leur nouveau mot de passe"
  echo "   (reset_url.sh) et être redémarrées."
  printf "   Continuer ? [y/N] "
  read -r c; [[ "$c" =~ ^[Yy]$ ]] || { echo "Annulé."; exit 0; }
fi

FAILED=0

# Rôle d'administration d'une instance : ALTER ROLE puis clé d'infra/.env.
# Le SQL passe par l'entrée standard (le mot de passe n'entre dans aucune ligne
# de commande) ; la clé est réécrite sans sed, pour la même raison.
rotate_admin() {  # <conteneur> <clé USER> <défaut> <clé DB> <défaut> <clé PASSWORD>
  local container="$1" user db new tmp line found=false
  user="$(_env_val "$2")"; user="${user:-$3}"
  db="$(_env_val "$4")";   db="${db:-$5}"
  if ! _up "$container"; then
    echo "✗ Conteneur '$container' non démarré — rotation de ${user} impossible." >&2
    echo "  Démarrez l'infra (bash scripts/recompose_docker.sh --app infra) puis relancez." >&2
    FAILED=$((FAILED + 1)); return
  fi
  new="$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 50 || true)"
  if ! docker exec -i "$container" psql -X -U "$user" -d "$db" -v ON_ERROR_STOP=1 -q > /dev/null 2>&1 <<SQL
ALTER ROLE "$user" WITH PASSWORD '$new';
SQL
  then
    echo "✗ ALTER ROLE ${user} échoué sur ${container} — infra/.env laissé intact, ancien mot de passe toujours valide." >&2
    FAILED=$((FAILED + 1)); return
  fi
  tmp="$(umask 077; mktemp "$INFRA_ENV.XXXXXX")"
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" == "$6="* ]]; then $found || printf '%s=%s\n' "$6" "$new"; found=true
    else printf '%s\n' "$line"; fi
  done < "$INFRA_ENV" > "$tmp"
  $found || printf '\n%s=%s\n' "$6" "$new" >> "$tmp"
  chmod --reference="$INFRA_ENV" "$tmp"; mv "$tmp" "$INFRA_ENV"
  echo "✓ ${user} : mot de passe roté sur ${container} (ALTER ROLE + infra/.env : $6)."
}

want admin && rotate_admin "$PG_CONTAINER"  POSTGRES_USER devuser POSTGRES_DB devdb POSTGRES_PASSWORD
want gis   && rotate_admin "$GIS_CONTAINER" POSTGIS_USER  gisuser POSTGIS_DB  gisdb POSTGIS_PASSWORD

if want lab && grep -qE '^LAB_PG_PASSWORD=' "$ROLES_ENV" 2>/dev/null; then
  bash "$SCRIPT_DIR/scripts/dev-db.sh" rotate lab || FAILED=$((FAILED + 1))
fi
if want devs && [[ -f "$ROLES_ENV" ]]; then
  while IFS= read -r uid; do
    [[ -n "$uid" ]] || continue
    bash "$SCRIPT_DIR/scripts/dev-db.sh" rotate "$uid" || FAILED=$((FAILED + 1))
  done < <(sed -n -E 's/^DEV_PG_PASSWORD__([a-z][a-z0-9]{1,30})=.*/\1/p' "$ROLES_ENV" | sort -u)
fi

if [[ $FAILED -gt 0 ]]; then
  echo "✗ ERROR : $FAILED rotation(s) en échec (voir ci-dessus)." >&2
  exit 1
fi
echo "  → Propagation aux apps : bash scripts/reset_url.sh   (fait automatiquement par setup2.sh), puis redémarrage des backends."
