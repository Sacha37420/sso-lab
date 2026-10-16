#!/bin/sh
# Source interne « webcams de l'hôte » (chantier webcams, contrat v1) — SUPERVISEUR.
#
# lab-media-auth découvre les webcams (sysfs), tient l'inventaire et écrit le PLAN de capture
# (/state/plan, une ligne par webcam à capturer, au plus MEDIA_CAPTURE_MAX) :
#     <id> <port USB> <micro 0|1> <base des chemins>
# Ce superviseur lit le plan chaque seconde et tient UN travailleur (capture-one.sh, donc un
# ffmpeg) par ligne :
#   * ligne apparue            → travailleur lancé ;
#   * ligne disparue ou changée (débranchement, micro apparu, plafond) → travailleur arrêté,
#     son ffmpeg tué et attendu (jamais d'orphelin), puis relancé s'il le faut ;
#   * travailleur mort          → relancé au passage suivant.
# Le plan est relu, jamais cru : chaque champ est revalidé ici, et le plafond est réappliqué
# (au plus MEDIA_CAPTURE_MAX lignes prises, quoi que contienne le fichier).
#
# Aucune chaîne venue du matériel (nom de produit, numéro de série) n'arrive jusqu'ici : le
# plan n'en contient pas, par construction (labmediaauth/devices.py).
set -u

log() { echo "[capture] $*" >&2; }
die() { log "ERREUR : $*"; exit 1; }

USER_="${LAB_MEDIA_SOURCE_CAPTURE_PUBLISH_USER:-}"
PASS_="${LAB_MEDIA_SOURCE_CAPTURE_PUBLISH_PASSWORD:-}"
[ -n "$USER_" ] && [ -n "$PASS_" ] || die "LAB_MEDIA_SOURCE_CAPTURE_PUBLISH_USER/PASSWORD absents de .env"
# Injectés dans une URL et dans la syntaxe du muxer tee : [A-Za-z0-9_-] seulement.
for v in "$USER_" "$PASS_"; do
  case "$v" in *[!A-Za-z0-9_-]*) die "identifiants de capture hors [A-Za-z0-9_-]";; esac
done
case "${MEDIA_CAPTURE_MODE:-device}" in device|testsrc) ;; *) die "MEDIA_CAPTURE_MODE ∈ device, testsrc";; esac
MAX="${MEDIA_CAPTURE_MAX:-2}"
case "$MAX" in ''|*[!0-9]*) die "MEDIA_CAPTURE_MAX doit être un entier de 0 à 8";; esac
[ "$MAX" -le 8 ] || die "MEDIA_CAPTURE_MAX doit être un entier de 0 à 8"
PLAN="${MEDIA_CAPTURE_PLAN:-/state/plan}"
RUN="${MEDIA_CAPTURE_RUN:-/tmp/lab-capture}"
rm -rf "$RUN" && mkdir -p "$RUN" || die "dossier de travail $RUN"

# valid <id> <port> <micro> <base> [reste] : 0 si la ligne est bien formée.
valid() {
  [ $# -eq 4 ] || return 1
  case "$1" in usb-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]-[sp]?*) ;; *) return 1;; esac
  case "$1" in *[!a-z0-9-]*) return 1;; esac
  [ "${#1}" -le 60 ] || return 1
  case "$2" in ''|*[!0-9.-]*|[!0-9]*) return 1;; esac
  [ "${#2}" -le 32 ] || return 1
  case "$3" in 0|1) ;; *) return 1;; esac
  case "$4" in ''|*[!a-z0-9/-]*|/*|*//*) return 1;; esac
  case "$4" in */"$1") ;; *) return 1;; esac
  return 0
}

# Lignes voulues : celles du plan qui sont valides, les MAX premières.
desired() {
  n=0
  [ -f "$PLAN" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    # shellcheck disable=SC2086
    set -f; set -- $line; set +f
    if ! valid "$@"; then log "ligne de plan ignorée (mal formée)"; continue; fi
    [ "$n" -lt "$MAX" ] || { log "plafond de $MAX atteint : ligne de plan ignorée ($1)"; continue; }
    n=$((n + 1))
    echo "$1 $2 $3 $4"
  done < "$PLAN"
}

alive() {   # alive <pid> : vivant et pas zombie
  [ -n "$1" ] && [ -r "/proc/$1/stat" ] || return 1
  st="$(sed 's/^.*) \(.\).*/\1/' "/proc/$1/stat" 2>/dev/null)"
  [ "$st" != "Z" ]
}

is_worker() {  # is_worker <pid> <id> : ce pid est bien le travailleur vivant de cette webcam
  alive "$1" && tr '\0' ' ' < "/proc/$1/cmdline" 2>/dev/null | grep -q -F "capture-one.sh $2 "
}

stop_worker() {   # stop_worker <id>
  id="$1"; pid="$(cat "$RUN/$id.pid" 2>/dev/null)"; ff="$(cat "$RUN/$id.ff" 2>/dev/null)"
  if is_worker "$pid" "$id"; then
    kill -TERM "$pid" 2>/dev/null
    i=0; while alive "$pid" && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
    alive "$pid" && kill -KILL "$pid" 2>/dev/null
  fi
  [ -n "$pid" ] && wait "$pid" 2>/dev/null
  # Filet : si le travailleur n'a pas pu tuer son ffmpeg (tué net), on le fait — après avoir
  # vérifié que ce pid est bien un ffmpeg qui publie sous CETTE webcam (pas un pid recyclé).
  if [ -n "$ff" ] && alive "$ff" && tr '\0' ' ' < "/proc/$ff/cmdline" 2>/dev/null | grep -q -F "/$id/"; then
    kill -TERM "$ff" 2>/dev/null; sleep 1; alive "$ff" && kill -KILL "$ff" 2>/dev/null
  fi
  rm -f "$RUN/$id.pid" "$RUN/$id.ff" "$RUN/$id.line"
  log "$id : capture arrêtée"
}

stop_all() {
  for f in "$RUN"/*.pid; do [ -e "$f" ] || continue; id="${f##*/}"; stop_worker "${id%.pid}"; done
}
trap 'stop_all; exit 0' TERM INT

log "superviseur prêt (mode ${MEDIA_CAPTURE_MODE:-device}, plafond $MAX, plan $PLAN)"
while :; do
  want="$(desired)"
  # 1. arrêter ce qui n'est plus voulu tel quel
  for f in "$RUN"/*.line; do
    [ -e "$f" ] || continue
    id="${f##*/}"; id="${id%.line}"
    printf '%s\n' "$want" | grep -q -x -F "$(cat "$f")" || stop_worker "$id"
  done
  # 2. lancer (ou relancer) ce qui est voulu
  while IFS=' ' read -r id port audio base; do
    [ -n "$id" ] || continue
    pid="$(cat "$RUN/$id.pid" 2>/dev/null)"
    if is_worker "$pid" "$id"; then continue; fi
    if [ -n "$pid" ]; then wait "$pid" 2>/dev/null; log "$id : travailleur mort, relance"; fi
    sh /opt/lab-media/capture-one.sh "$id" "$port" "$audio" "$base" &
    echo $! > "$RUN/$id.pid"
    echo "$id $port $audio $base" > "$RUN/$id.line"
    log "$id : capture lancée (port $port, micro $audio)"
  done <<PLAN_EOF
$want
PLAN_EOF
  sleep 1 &
  wait $!
done
