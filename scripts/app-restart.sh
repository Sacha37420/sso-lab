#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# app-restart.sh — applique un changement de CONFIGURATION sans reconstruire.
# Contrat « multi-dev » v9, interface I10.
#
# Usage :
#   bash scripts/app-restart.sh <app>
#
# Fait, sous le verrou de déploiement : `docker compose up -d --no-build`.
# Compose recrée les conteneurs dont la configuration a changé (le .env en fait
# partie) — TOUS les services du projet, donc aussi un worker Celery, qui doit
# recevoir les mêmes variables que le backend.
#
# Code : 0 = les conteneurs tournent avec la nouvelle configuration, sur les
#            MÊMES images qu'avant ;
#        1 = refus ou échec (le message dit lequel) ;
#        2 = erreur d'usage.
#
# CE QUE LE SCRIPT GARANTIT : aucun code nouveau n'entre en service par ce
# chemin. Un déploiement passe par les tests (setup2.sh) ; un redémarrage ne
# doit pas pouvoir les contourner. Deux contrôles :
#   • AVANT de toucher quoi que ce soit : pour chaque service construit par le
#     projet, l'image que désigne aujourd'hui son étiquette doit être celle sur
#     laquelle tourne son conteneur. Ce n'est PAS toujours le cas : après un
#     déploiement refusé par un test rouge, l'étiquette <app>-<service> désigne
#     le build rejeté, et un `up` démarrerait justement celui-là. Dans ce cas :
#     refus, rien n'est touché ;
#   • APRÈS : l'identifiant d'image de chaque conteneur est comparé à celui
#     d'avant ; la moindre différence est une erreur (code 1).
#
# Refuse une app jamais déployée (aucun conteneur du projet) : il n'y a rien à
# redémarrer, et la démarrer ici contournerait le déploiement.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/registry.sh
source "$SCRIPT_DIR/lib/registry.sh"
# shellcheck source=lib/lock.sh
source "$SCRIPT_DIR/lib/lock.sh"

log() { echo "$*" >&2; }
die() { echo "✗ ERROR app-restart : $*" >&2; exit 1; }

[[ $# -eq 1 ]] || { echo "Usage : bash scripts/app-restart.sh <app>" >&2; exit 2; }
APP="$1"
[[ "$APP" =~ ^[a-z][a-z0-9-]{1,38}[a-z0-9]$ ]] || die "nom d'app invalide : '$APP'"
APP_DIR="$(registry_app_dir "$APP")" || die "nom d'app invalide : '$APP'"
COMPOSE="$APP_DIR/docker-compose.yml"
[[ -f "$COMPOSE" ]] || die "app inconnue : '$APP'"

lab_lock_acquire "app-restart.sh $APP" || exit $?

dc() { docker compose --project-directory "$APP_DIR" -f "$COMPOSE" "$@"; }
# « service<TAB>identifiant d'image » pour chaque conteneur du projet, trié.
images_now() {
  local id svc
  while IFS=$'\t' read -r id svc; do
    [[ -n "$id" ]] || continue
    printf '%s\t%s\n' "$svc" "$(docker inspect -f '{{.Image}}' "$id" 2>/dev/null)"
  done < <(docker ps -a --filter "label=com.docker.compose.project=${APP}" \
             --format '{{.ID}}\t{{.Label "com.docker.compose.service"}}' 2>/dev/null) | sort
}

BEFORE="$(images_now)"
[[ -n "$BEFORE" ]] || die "'$APP' n'a jamais été déployée (aucun conteneur) — la déployer d'abord"

# ── Contrôle préalable : l'étiquette d'image désigne-t-elle ce qui tourne ? ───
MODEL="$(dc config --format json --no-env-resolution 2>/dev/null)" || die "docker-compose.yml illisible — rien n'a été touché"
while IFS=$'\t' read -r svc image; do
  [[ -n "$svc" ]] || continue
  running="$(awk -F'\t' -v s="$svc" '$1 == s { print $2; exit }' <<< "$BEFORE")"
  [[ -n "$running" ]] || die "le service « $svc » n'a aucun conteneur : la composition a changé depuis le dernier déploiement — redéployer (rien n'a été touché)"
  tagged="$(docker image inspect -f '{{.Id}}' "$image" 2>/dev/null || true)"
  [[ -n "$tagged" ]] || die "l'image « $image » du service « $svc » n'existe plus localement — redéployer (rien n'a été touché)"
  if [[ "$tagged" != "$running" ]]; then
    die "l'image « $image » ne désigne plus ce qui tourne pour « $svc » (un build plus récent n'a pas été mis en service, p. ex. refusé par ses tests) : un redémarrage le démarrerait sans test. Redéployer d'abord. Rien n'a été touché."
  fi
done < <(jq -r --arg p "$APP" '.services | to_entries[]
           | [.key, (.value.image // ($p + "-" + .key))] | @tsv' <<< "$MODEL")

# ── Redémarrage ───────────────────────────────────────────────────────────────
log "▶ $APP — application de la configuration (up -d --no-build)"
# --pull never : une image tierce (redis…) n'est pas remplacée par une plus récente non plus.
if ! dc up -d --no-build --pull never --remove-orphans 2>&1 | sed 's/^/  /' >&2; then
  die "docker compose up a échoué (voir ci-dessus)"
fi

AFTER="$(images_now)"
if [[ "$BEFORE" != "$AFTER" ]]; then
  log "  avant : $(tr '\n' ' ' <<< "$BEFORE")"
  log "  après : $(tr '\n' ' ' <<< "$AFTER")"
  die "les images en service ont CHANGÉ pendant le redémarrage — anomalie : redéployer par setup2.sh"
fi

# Tous les conteneurs doivent tourner (ou s'être terminés normalement : tâche d'initialisation).
BAD="$(docker ps -a --filter "label=com.docker.compose.project=${APP}" \
         --format '{{.Label "com.docker.compose.service"}}\t{{.State}}\t{{.Status}}' 2>/dev/null \
       | awk -F'\t' '$2 != "running" && !($2 == "exited" && $3 ~ /^Exited \(0\)/) { print $1 " (" $2 ")" }' | tr '\n' ' ')"
[[ -z "$BAD" ]] || die "après redémarrage, ces services ne tournent pas : $BAD"

log "✓ $APP redémarrée : $(wc -l <<< "$AFTER" | tr -d ' ') service(s), mêmes images qu'avant."
