#!/bin/sh
# Travailleur de capture d'UNE webcam (lancé et arrêté par capture.sh, chantier webcams).
#
#   capture-one.sh <id> <port USB> <micro 0|1> <base des chemins>
#
# Boucle : résoudre les nœuds (sysfs seulement, rien n'est ouvert), lancer UN ffmpeg qui encode
# une fois et publie par le muxer tee :
#     <base>/video  H.264 seul      <base>/av  H.264 (+ Opus s'il y a un micro)
#     <base>/audio  Opus seul — seulement s'il y a un micro (webcam sans micro : vidéo seule)
# puis recommencer à la moindre sortie de ffmpeg (débranchement, MediaMTX redémarré, refus).
# SIGTERM : ffmpeg est tué ET attendu avant de sortir — jamais d'orphelin.
#
# Les nœuds sont retrouvés à CHAQUE lancement à partir du port USB (/sys/bus/usb/devices/<port>) :
# un renumérotage videoN ou cardN après ré-énumération est donc suivi. Avant d'ouvrir quoi que
# ce soit on vérifie que l'appareil branché sur ce port a bien le vendor:product de l'identifiant
# (une autre caméra branchée entre-temps sur le même port n'est pas capturée sous ce nom), que
# l'interface est de classe vidéo et le nœud d'index 0, et que le nœud de /hostdev a le même
# majeur:mineur que sysfs.
#
# MEDIA_CAPTURE_MODE=testsrc : même résolution des nœuds (sur un faux sysfs dans verify.sh),
# mais mire et bip synthétiques à la place des périphériques : AUCUN périphérique ouvert.
set -u

ID="$1"; PORT="$2"; AUDIO="$3"; BASE_PATH="$4"
MODE="${MEDIA_CAPTURE_MODE:-device}"
SYSFS="${SYSFS_ROOT:-/sys}"
HOSTDEV="${HOSTDEV_ROOT:-/hostdev}"
SND="${SND_DIR:-/dev/snd}"
RETRY="${MEDIA_CAPTURE_RETRY_S:-3}"
RUN="${MEDIA_CAPTURE_RUN:-/tmp/lab-capture}"
# « lab-media-rtsp » : alias de MediaMTX sur le réseau interne de lab-media.
URL="rtsp://${LAB_MEDIA_SOURCE_CAPTURE_PUBLISH_USER}:${LAB_MEDIA_SOURCE_CAPTURE_PUBLISH_PASSWORD}@${MEDIA_CAPTURE_RTSP_HOST:-lab-media-rtsp}:8554/${BASE_PATH}"
VID="$(echo "$ID" | cut -d- -f2)"; PID_="$(echo "$ID" | cut -d- -f3)"
ff=""

log() { echo "[capture] $ID : $*" >&2; }

stop() {
  if [ -n "$ff" ]; then kill -TERM "$ff" 2>/dev/null; wait "$ff" 2>/dev/null; fi
  rm -f "$RUN/$ID.ff"
  exit 0
}
trap stop TERM INT

# resolve : pose VIDEO_IN et AUDIO_IN, ou rend 1 avec une raison sur la sortie standard.
resolve() {
  VIDEO_IN=""; AUDIO_IN=""
  dev="$SYSFS/bus/usb/devices/$PORT"
  [ -d "$dev" ] || { echo "rien sur le port $PORT"; return 1; }
  [ "$(cat "$dev/idVendor" 2>/dev/null)" = "$VID" ] && [ "$(cat "$dev/idProduct" 2>/dev/null)" = "$PID_" ] \
    || { echo "un autre appareil est sur le port $PORT"; return 1; }
  for v in "$dev/$PORT":*/video4linux/video*; do
    [ -d "$v" ] || continue
    [ "$(cat "$v/index" 2>/dev/null)" = "0" ] || continue
    iface="${v%/video4linux/*}"
    [ "$(cat "$iface/bInterfaceClass" 2>/dev/null)" = "0e" ] || continue
    n="${v##*/}"
    case "$n" in video[0-9]*) ;; *) continue;; esac
    case "$n" in video*[!0-9]*) continue;; esac
    node="$HOSTDEV/$n"
    [ -c "$node" ] || { echo "$n absent de $HOSTDEV (ré-énumération en cours ?)"; return 1; }
    got="$(printf '%d:%d' "0x$(stat -c %t "$node")" "0x$(stat -c %T "$node")")"
    [ "$got" = "$(cat "$v/dev" 2>/dev/null)" ] || { echo "$n incohérent (nœud $got ≠ sysfs)"; return 1; }
    VIDEO_IN="$node"
    break
  done
  [ -n "$VIDEO_IN" ] || { echo "aucun nœud vidéo de capture (index 0) sur le port $PORT"; return 1; }
  if [ "$AUDIO" = 1 ]; then
    for c in "$dev/$PORT":*/sound/card*; do
      [ -d "$c" ] || continue
      num="${c##*/card}"
      case "$num" in ''|*[!0-9]*) continue;; esac
      for p in "$SND/pcmC${num}D"*c; do
        [ -c "$p" ] || continue
        d="${p##*D}"; d="${d%c}"
        case "$d" in ''|*[!0-9]*) continue;; esac
        AUDIO_IN="plughw:${num},${d}"   # plughw : mono ou stéréo, le micro décide
        break 2
      done
    done
  fi
  return 0
}

ENC_V="-c:v libx264 -preset veryfast -tune zerolatency -profile:v baseline -level:v 3.1 -g 30 -keyint_min 30 -sc_threshold 0 -bf 0"
ENC_A="-c:a libopus -b:a 32k -ar 48000 -ac 1 -application lowdelay"
OUT_V="[f=rtsp:rtsp_transport=tcp:select=v]${URL}/video"
OUT_A="[f=rtsp:rtsp_transport=tcp:select=a]${URL}/audio"
OUT_AV="[f=rtsp:rtsp_transport=tcp]${URL}/av"

# Le journal de ffmpeg peut citer l'URL de publication, donc le mot de passe de la source :
# il passe par un tube qui le masque avant d'atteindre la sortie d'erreur du conteneur.
FIFO="$RUN/$ID.err"
masked_log() {
  rm -f "$FIFO"; mkfifo -m 600 "$FIFO" || return 1
  PW="$LAB_MEDIA_SOURCE_CAPTURE_PUBLISH_PASSWORD"   # [A-Za-z0-9_-] : sans danger dans sed
  ( while IFS= read -r l; do
      case "$l" in *"$PW"*) l="$(printf '%s' "$l" | sed "s#$PW#***#g")";; esac
      echo "[ffmpeg $ID] $l" >&2
    done < "$FIFO" ) &
}

run_ffmpeg() {   # run_ffmpeg <essai> : en arrière-plan, pid dans $ff
  masked_log
  with_audio=0; [ -n "$AUDIO_IN" ] && with_audio=1
  if [ "$MODE" = testsrc ]; then
    SIZE="${MEDIA_CAPTURE_TEST_SIZE:-320x240}"
    case "$SIZE" in *[!0-9x]*) SIZE=320x240;; esac
    # shellcheck disable=SC2086
    if [ $with_audio = 1 ]; then
      ffmpeg -hide_banner -nostdin -loglevel warning \
        -re -f lavfi -i "testsrc2=size=${SIZE}:rate=15" -re -f lavfi -i "sine=frequency=440:sample_rate=48000" \
        -map 0:v:0 -map 1:a:0 -vf "format=yuv420p" $ENC_V -b:v 200k -maxrate 200k -bufsize 400k $ENC_A \
        -f tee "${OUT_V}|${OUT_A}|${OUT_AV}" 2>"$FIFO" &
    else
      ffmpeg -hide_banner -nostdin -loglevel warning \
        -re -f lavfi -i "testsrc2=size=${SIZE}:rate=15" \
        -map 0:v:0 -vf "format=yuv420p" $ENC_V -b:v 200k -maxrate 200k -bufsize 400k \
        -f tee "${OUT_V}|${OUT_AV}" 2>"$FIFO" &
    fi
  else
    # Essai pair : MJPEG 1280x720 (la plupart des webcams UVC ; décodage MJPEG + x264, aucun
    # H.264 natif supposé). Essai impair, après un échec rapide : format par défaut du pilote.
    if [ $(($1 % 2)) -eq 0 ]; then FMT="-input_format mjpeg -video_size 1280x720"; else FMT=""; fi
    # shellcheck disable=SC2086
    if [ $with_audio = 1 ]; then
      ffmpeg -hide_banner -nostdin -loglevel warning \
        -thread_queue_size 64 -f v4l2 $FMT -timestamps mono2abs -i "$VIDEO_IN" \
        -thread_queue_size 1024 -f alsa -channels 1 -sample_rate 48000 -i "$AUDIO_IN" \
        -map 0:v:0 -map 1:a:0 -vf "fps=15,format=yuv420p" \
        $ENC_V -b:v 1000k -maxrate 1000k -bufsize 2000k $ENC_A \
        -f tee "${OUT_V}|${OUT_A}|${OUT_AV}" 2>"$FIFO" &
    else
      ffmpeg -hide_banner -nostdin -loglevel warning \
        -thread_queue_size 64 -f v4l2 $FMT -timestamps mono2abs -i "$VIDEO_IN" \
        -map 0:v:0 -vf "fps=15,format=yuv420p" \
        $ENC_V -b:v 1000k -maxrate 1000k -bufsize 2000k \
        -f tee "${OUT_V}|${OUT_AV}" 2>"$FIFO" &
    fi
  fi
  ff=$!
  echo "$ff" > "$RUN/$ID.ff"
}

attempt=0; last=""
while :; do
  if why="$(resolve)"; then
    resolve   # (dans ce shell : pose VIDEO_IN et AUDIO_IN)
    [ "$AUDIO" = 1 ] && [ -z "$AUDIO_IN" ] && log "micro introuvable sur le port $PORT : vidéo seule pour cet essai"
    log "ffmpeg (essai $attempt, mode $MODE, micro $([ -n "$AUDIO_IN" ] && echo oui || echo non))"
    t0="$(date +%s)"
    run_ffmpeg "$attempt"
    wait "$ff"; code=$?
    ff=""; rm -f "$RUN/$ID.ff"
    ran=$(( $(date +%s) - t0 ))
    log "ffmpeg terminé (code $code après ${ran} s), nouvelle tentative dans ${RETRY} s"
    # Un échec rapide fait alterner le format d'entrée ; un ffmpeg qui a tourné garde le sien.
    [ "$ran" -lt 15 ] && attempt=$((attempt + 1))
    last=""
  else
    [ "$why" != "$last" ] && log "attente : $why"
    last="$why"
  fi
  sleep "$RETRY" &
  wait $!
done
