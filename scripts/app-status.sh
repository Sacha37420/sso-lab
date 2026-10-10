#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# app-status.sh — état des conteneurs d'une app + SHA déployé.
# Contrat « multi-dev » v2, interface I4.
#
# Usage : bash scripts/app-status.sh <app>
#
# Sortie (stdout, une ligne JSON) :
#   {"sha": "<40 hex>|null", "services": [{"service","state","health","image"}],
#    "at": "<ISO 8601>|null", "tests": {"backend": …, "cloisonnement": …}|null}
#
#   at, tests : date du dernier déploiement réussi et verdict des tests qui
#              l'ont accompagné (<LAB_STATE_DIR>/deployed/<app>.json) —
#              "ok" · "ko" · "absent" (aucun test trouvé) · "non-lancé".
#
#   sha      : commit du dernier déploiement RÉUSSI (enregistré par
#              setup_unit.sh dans <LAB_STATE_DIR>/deployed/<app>.json) — pas le commit
#              extrait dans $ROOT/<app>, qui peut avoir été refusé ou n'avoir
#              jamais buildé. null si l'app n'a jamais été déployée avec succès
#              (ou pas depuis que cet enregistrement existe).
#   services : un objet par conteneur du projet Compose, y compris arrêté.
#              `health` vaut "" pour un service sans healthcheck.
#              Liste vide = rien n'est déployé.
#
# Lecture seule, ne prend pas le verrou. Code ≠ 0 seulement si l'app est
# inconnue ou si Docker ne répond pas.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/registry.sh
source "$SCRIPT_DIR/lib/registry.sh"

[[ $# -eq 1 ]] || { echo "Usage : bash scripts/app-status.sh <app>" >&2; exit 2; }
APP="$1"
APP_DIR="$(registry_app_dir "$APP")" || { echo "✗ nom d'app invalide : '$APP'" >&2; exit 1; }
[[ -f "$APP_DIR/docker-compose.yml" ]] || { echo "✗ app inconnue : '$APP'" >&2; exit 1; }

# Dernier déploiement RÉUSSI (enregistré par setup_unit.sh), pas le commit
# extrait dans le dossier : après un déploiement refusé ou raté, les deux
# diffèrent, et c'est celui qui tourne qu'on doit nommer.
DEPLOYED='{"sha":null,"at":null,"tests":null}'
if _d="$(registry_deployed_json "$APP")"; then DEPLOYED="$_d"; fi

# Interrogation par ÉTIQUETTE de projet, pas par `docker compose ps` : ce
# dernier relit et interpole docker-compose.yml, donc échoue sur un fichier
# cassé — précisément le moment où l'on veut connaître l'état.
if ! RAW="$(docker ps -a --filter "label=com.docker.compose.project=${APP}" \
              --format '{{.Label "com.docker.compose.service"}}\t{{.State}}\t{{.Status}}\t{{.Image}}' 2>/dev/null)"; then
  echo "✗ Docker ne répond pas" >&2; exit 1
fi

printf '%s\n' "$RAW" | jq -R -s -c --argjson d "$DEPLOYED" '
  { sha: $d.sha,
    services: [ split("\n")[] | select(length > 0) | split("\t")
                | { service: .[0], state: .[1],
                    health: ( if (.[2] | test("\\(healthy\\)")) then "healthy"
                              elif (.[2] | test("\\(unhealthy\\)")) then "unhealthy"
                              elif (.[2] | test("\\(health: starting\\)")) then "starting"
                              else "" end ),
                    image: .[3] } ] | sort_by(.service),
    at: $d.at,
    tests: $d.tests }'
