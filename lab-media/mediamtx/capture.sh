#!/bin/sh
# Source interne « périphérique de l'hôte » (contrat lab-media, I4) — reprise de
# deploiement/peripheriques/media/publish.sh.
# UN SEUL ffmpeg : ouvre caméra + micro, encode UNE fois, publie les 3 chemins via le muxer
# tee (aucun ré-encodage par sortie).
#   <préfixe>/video  H.264 seul   <préfixe>/audio  Opus seul   <préfixe>/av  H.264 + Opus
# Caméra Jieli 1224:2a25 : MJPEG 1280x720 (25 i/s imposés par le pilote) ou YUYV 640x480 max,
# aucun H.264 natif => décodage MJPEG + x264. Le passage à 15 i/s se fait par le filtre fps.
#
# Boucle : attente des périphériques (sysfs seulement), ffmpeg, puis on recommence à la moindre
# sortie de ffmpeg (ré-énumération USB, MediaMTX ou lab-media-auth redémarré, refus du hook).
#
# MEDIA_CAPTURE_MODE=testsrc : mire + bip synthétiques à la place des périphériques, même
# encodage, même tee, mêmes identifiants. N'ouvre AUCUN périphérique : sert à prouver la
# chaîne sans matériel (verify.sh) et à diagnostiquer la brique caméra débranchée.
set -u

die() { echo "[capture] ERREUR : $*" >&2; exit 1; }

USER_="${LAB_MEDIA_SOURCE_CAPTURE_PUBLISH_USER:-}"
PASS_="${LAB_MEDIA_SOURCE_CAPTURE_PUBLISH_PASSWORD:-}"
[ -n "$USER_" ] && [ -n "$PASS_" ] || die "LAB_MEDIA_SOURCE_CAPTURE_PUBLISH_USER/PASSWORD absents de .env"
# Injectés dans une URL et dans la syntaxe du muxer tee : [A-Za-z0-9_-] seulement.
for v in "$USER_" "$PASS_"; do
  case "$v" in *[!A-Za-z0-9_-]*) die "identifiants de capture hors [A-Za-z0-9_-]";; esac
done
PREFIX="${MEDIA_CAPTURE_PREFIX:-webcam}"
case "$PREFIX" in *[!a-z0-9_/-]*|'') die "MEDIA_CAPTURE_PREFIX invalide";; esac
MODE="${MEDIA_CAPTURE_MODE:-device}"
# « lab-media-rtsp » : alias de MediaMTX sur le réseau interne de lab-media.
BASE="rtsp://${USER_}:${PASS_}@${MEDIA_CAPTURE_RTSP_HOST:-lab-media-rtsp}:8554/${PREFIX}"
RETRY="${MEDIA_CAPTURE_RETRY_S:-3}"

run_device() {
  # Attendre caméra + carte son (sysfs seulement, rien n'est ouvert) — voir wait-devices.sh.
  sh /opt/lab-media/wait-devices.sh || return 1
  # Lien by-id de l'hôte relu sous /hostdev (montage live) : résolu à CHAQUE lancement, il
  # suit les ré-énumérations USB. Jamais de /dev/video0 figé.
  VIDEO_IN="/hostdev${MEDIA_DEVICE_VIDEO#/dev}"
  ffmpeg -hide_banner -nostdin -loglevel warning \
    -thread_queue_size 64 \
    -f v4l2 -input_format mjpeg -video_size 1280x720 -timestamps mono2abs -i "${VIDEO_IN}" \
    -thread_queue_size 1024 \
    -f alsa -channels 1 -sample_rate 48000 -i "${MEDIA_DEVICE_AUDIO}" \
    -map 0:v:0 -map 1:a:0 \
    -vf "fps=15,format=yuv420p" \
    -c:v libx264 -preset veryfast -tune zerolatency -profile:v baseline -level:v 3.1 \
    -b:v 1000k -maxrate 1000k -bufsize 2000k -g 30 -keyint_min 30 -sc_threshold 0 -bf 0 \
    -c:a libopus -b:a 32k -ar 48000 -ac 1 -application lowdelay \
    -f tee \
    "[f=rtsp:rtsp_transport=tcp:select=v]${BASE}/video|[f=rtsp:rtsp_transport=tcp:select=a]${BASE}/audio|[f=rtsp:rtsp_transport=tcp]${BASE}/av"
}

run_testsrc() {
  SIZE="${MEDIA_CAPTURE_TEST_SIZE:-320x240}"
  case "$SIZE" in *[!0-9x]*) die "MEDIA_CAPTURE_TEST_SIZE invalide";; esac
  ffmpeg -hide_banner -nostdin -loglevel warning \
    -re -f lavfi -i "testsrc2=size=${SIZE}:rate=15" \
    -re -f lavfi -i "sine=frequency=440:sample_rate=48000" \
    -map 0:v:0 -map 1:a:0 \
    -vf "format=yuv420p" \
    -c:v libx264 -preset veryfast -tune zerolatency -profile:v baseline -level:v 3.1 \
    -b:v 200k -maxrate 200k -bufsize 400k -g 30 -keyint_min 30 -sc_threshold 0 -bf 0 \
    -c:a libopus -b:a 32k -ar 48000 -ac 1 -application lowdelay \
    -f tee \
    "[f=rtsp:rtsp_transport=tcp:select=v]${BASE}/video|[f=rtsp:rtsp_transport=tcp:select=a]${BASE}/audio|[f=rtsp:rtsp_transport=tcp]${BASE}/av"
}

case "$MODE" in
  device)
    case "${MEDIA_DEVICE_VIDEO:-}" in /dev/*) ;; *) die "MEDIA_DEVICE_VIDEO doit être un lien /dev/... de l'hôte (by-id)";; esac
    [ -n "${MEDIA_DEVICE_AUDIO:-}" ] || die "MEDIA_DEVICE_AUDIO absent de .env"
    ;;
  testsrc) ;;
  *) die "MEDIA_CAPTURE_MODE ∈ device, testsrc";;
esac

trap 'kill "$child" 2>/dev/null; exit 0' TERM INT
while :; do
  echo "[capture] publication ${PREFIX}/{video,audio,av} (mode ${MODE})" >&2
  "run_${MODE}" &
  child=$!
  wait "$child"
  echo "[capture] ffmpeg terminé (code $?), nouvelle tentative dans ${RETRY}s" >&2
  sleep "$RETRY" &
  child=$!
  wait "$child"
done
