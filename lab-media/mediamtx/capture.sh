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
#
# Haut-parleurs (chantier haut-parleur) : même supervision pour un second plan,
# /state/speakers (une ligne par haut-parleur déclaré au registre) :
#     <id> <pcm ALSA> <carte du mixeur|-> <contrôle|-> <volume|->
# un lecteur speaker-one.sh par ligne (8 au plus), arrêté et attendu de même. Un lecteur en
# échec n'arrête rien d'autre : la capture vidéo continue.
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
SPEAKERS="${MEDIA_SPEAKER_PLAN:-/state/speakers}"
RUN="${MEDIA_CAPTURE_RUN:-/tmp/lab-capture}"
SRUN="$RUN/spk"
rm -rf "$RUN" && mkdir -p "$RUN" "$SRUN" || die "dossier de travail $RUN"

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

# ── haut-parleurs ──
# valid_speaker <id> <pcm> <carte|-> <contrôle|-> <volume|-> [reste] : 0 si la ligne est bien formée.
valid_speaker() {
  [ $# -eq 5 ] || return 1
  case "$1" in [a-z][a-z0-9-]*) ;; *) return 1;; esac
  case "$1" in *[!a-z0-9-]*|usb-*|webcam*) return 1;; esac
  [ "${#1}" -le 41 ] || return 1
  case "$2" in ''|*[!A-Za-z0-9_:=,.-]*) return 1;; esac
  [ "${#2}" -le 64 ] || return 1
  if [ "$3" = - ]; then
    [ "$4" = - ] && [ "$5" = - ] || return 1
  else
    case "$3" in ''|*[!A-Za-z0-9_]*) return 1;; esac
    case "$4" in ''|*[!A-Za-z0-9_-]*) return 1;; esac
    case "$5" in ''|*[!0-9]*) return 1;; esac
    [ "${#3}" -le 32 ] && [ "${#4}" -le 44 ] && [ "$5" -le 100 ] || return 1
  fi
  return 0
}

desired_speakers() {
  n=0
  [ -f "$SPEAKERS" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    # shellcheck disable=SC2086
    set -f; set -- $line; set +f
    if ! valid_speaker "$@"; then log "ligne de haut-parleur ignorée (mal formée)"; continue; fi
    [ "$n" -lt 8 ] || { log "8 haut-parleurs au plus : ligne ignorée ($1)"; continue; }
    n=$((n + 1))
    echo "$1 $2 $3 $4 $5"
  done < "$SPEAKERS"
}

is_speaker() {  # is_speaker <pid> <id>
  alive "$1" && tr '\0' ' ' < "/proc/$1/cmdline" 2>/dev/null | grep -q -F "speaker-one.sh $2 "
}

stop_speaker() {   # stop_speaker <id>
  id="$1"; pid="$(cat "$SRUN/$id.pid" 2>/dev/null)"
  if is_speaker "$pid" "$id"; then
    kill -TERM "$pid" 2>/dev/null
    i=0; while alive "$pid" && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
    alive "$pid" && kill -KILL "$pid" 2>/dev/null
  fi
  [ -n "$pid" ] && wait "$pid" 2>/dev/null
  # Filet (lecteur tué net) : son ffmpeg (URL …/speaker/<id>) et son aplay, après vérification.
  ffp="$(cat "$SRUN/$id.ff" 2>/dev/null)"; app="$(cat "$SRUN/$id.ap" 2>/dev/null)"
  if [ -n "$ffp" ] && alive "$ffp" && tr '\0' ' ' < "/proc/$ffp/cmdline" 2>/dev/null | grep -q -F "/speaker/$id "; then
    kill -KILL "$ffp" 2>/dev/null
  fi
  if [ -n "$app" ] && alive "$app" && tr '\0' ' ' < "/proc/$app/cmdline" 2>/dev/null | grep -q '^aplay '; then
    kill -KILL "$app" 2>/dev/null
  fi
  rm -f "$SRUN/$id.pid" "$SRUN/$id.line" "$SRUN/$id.ff" "$SRUN/$id.ap" "${MEDIA_SPEAKER_STATUS_DIR:-/speakers}/$id"
  log "haut-parleur $id : lecteur arrêté"
}

stop_all() {
  for f in "$RUN"/*.pid; do [ -e "$f" ] || continue; id="${f##*/}"; stop_worker "${id%.pid}"; done
  for f in "$SRUN"/*.pid; do [ -e "$f" ] || continue; id="${f##*/}"; stop_speaker "${id%.pid}"; done
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
  # 3. haut-parleurs : même chose
  spk="$(desired_speakers)"
  for f in "$SRUN"/*.line; do
    [ -e "$f" ] || continue
    id="${f##*/}"; id="${id%.line}"
    printf '%s\n' "$spk" | grep -q -x -F "$(cat "$f")" || stop_speaker "$id"
  done
  while IFS=' ' read -r id pcm card ctl vol; do
    [ -n "$id" ] || continue
    pid="$(cat "$SRUN/$id.pid" 2>/dev/null)"
    if is_speaker "$pid" "$id"; then continue; fi
    if [ -n "$pid" ]; then wait "$pid" 2>/dev/null; log "haut-parleur $id : lecteur mort, relance"; fi
    sh /opt/lab-media/speaker-one.sh "$id" "$pcm" "$card" "$ctl" "$vol" &
    echo $! > "$SRUN/$id.pid"
    echo "$id $pcm $card $ctl $vol" > "$SRUN/$id.line"
    log "haut-parleur $id : lecteur lancé (sortie $pcm)"
  done <<SPK_EOF
$spk
SPK_EOF
  sleep 1 &
  wait $!
done
