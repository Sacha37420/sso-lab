#!/bin/sh
# Lecteur d'UN haut-parleur (chantier haut-parleur, contrat v1) — lancé et arrêté par capture.sh.
#
#   speaker-one.sh <id> <pcm ALSA> <carte du mixeur|-> <contrôle|-> <volume|->
#
# Ce que dit une personne autorisée (publication WHIP sur speaker/<id>, décidée par le hook de
# l'app) est lu ici en RTSP — ce lecteur est le SEUL à pouvoir lire ce chemin, avec les
# identifiants de la source capture — et joué sur la sortie ALSA déclarée au registre :
#
#   ffmpeg (RTSP → PCM s16le 48 kHz stéréo, sans tampon)  ─fifo─▶  aplay (tampon ALSA borné)
#
# Déroulé :
#   1. au démarrage (et après toute erreur de sortie) : réglage du mixeur — `<contrôle>` mis à
#      `<volume>` % et réactivé (unmute) ; rien d'autre n'est touché, ni les entrées (micros), ni
#      « Auto-Mute Mode » — puis essai d'ouverture de la sortie (0,1 s de silence) ;
#   2. statut écrit dans <MEDIA_SPEAKER_STATUS_DIR>/<id> : `idle`, `error mixer` ou
#      `error output`, rafraîchi toutes les 2 s (lab-media-auth le lit ; trop vieux = capture absente) ;
#   3. attente d'un déclencheur dans /state/talk (écrit par lab-media-auth) : ligne
#      `<id> <génération> <prêt>`. Génération plus récente (une publication vient d'être autorisée) :
#      connexion tentée toutes les 0,3 s pendant 15 s au plus ; « prêt » à 1 : connexion tentée.
#      Sinon, AUCUNE connexion : ni appel au hook, ni ouverture de la carte son ;
#   4. la carte son n'est ouverte qu'au premier échantillon reçu (porte `dd` : 4 octets = une
#      trame, écartée) — une tentative sans publieur ne l'ouvre jamais.
#
# Un échec ALSA (carte absente, contrôle inconnu, sortie occupée) passe le statut à `error` et
# fait réessayer toutes les 5 s : jamais d'arrêt du conteneur ni de la capture vidéo (ce
# travailleur est un processus à part, relancé par le superviseur s'il meurt).
# SIGTERM : ffmpeg et aplay sont tués ET attendus, le statut est retiré.
set -u

ID="$1"; PCM="$2"; MCARD="$3"; MCTL="$4"; MVOL="$5"
STATUS_DIR="${MEDIA_SPEAKER_STATUS_DIR:-/speakers}"
TALK="${MEDIA_SPEAKER_TALK:-/state/talk}"
RUN="${MEDIA_CAPTURE_RUN:-/tmp/lab-capture}/spk"
PW="$LAB_MEDIA_SOURCE_CAPTURE_PUBLISH_PASSWORD"     # [A-Za-z0-9_-] : contrôlé par capture.sh
URL="rtsp://${LAB_MEDIA_SOURCE_CAPTURE_PUBLISH_USER}:${PW}@${MEDIA_CAPTURE_RTSP_HOST:-lab-media-rtsp}:8554/speaker/${ID}"
# Tampon ALSA : la latence ajoutée par la carte est au plus ce tampon ; la lecture démarre à sa
# moitié (marge contre la gigue du réseau). 40 à 1000 ms, défaut 160.
BUF_MS="${MEDIA_SPEAKER_BUFFER_MS:-160}"
case "$BUF_MS" in ''|*[!0-9]*) BUF_MS=160;; esac
if [ "$BUF_MS" -lt 40 ] || [ "$BUF_MS" -gt 1000 ]; then BUF_MS=160; fi
ST="$STATUS_DIR/$ID"
FIFO="$RUN/$ID.pcm"
ff=""; ap=""

log() { echo "[speaker] $ID : $*" >&2; }
# Une panne qui dure ne remplit pas le journal : un message d'échec n'est répété que s'il change.
last_fail=""
fail() { [ "$1" = "$last_fail" ] || log "$1"; last_fail="$1"; }
status() { printf '%s\n' "$1" > "$ST.tmp" 2>/dev/null && mv -f "$ST.tmp" "$ST"; }

stop() {
  [ -n "$ff" ] && kill -TERM "$ff" 2>/dev/null
  [ -n "$ap" ] && kill -TERM "$ap" 2>/dev/null
  [ -n "$ff" ] && wait "$ff" 2>/dev/null
  [ -n "$ap" ] && wait "$ap" 2>/dev/null
  rm -f "$ST" "$ST.tmp" "$FIFO" "$RUN/$ID.ff" "$RUN/$ID.ap"
  exit 0
}
trap stop TERM INT

pause() { sleep "$1" & wait $!; }

# Erreurs d'ffmpeg (elles citent l'URL, donc le mot de passe) : masquées avant le journal.
show_errors() {   # show_errors <fichier> <étiquette>
  [ -s "$1" ] || return 0
  sed "s#$PW#***#g; s#^#[$2 $ID] #" "$1" | head -20 >&2
}

mixer() {
  [ "$MCARD" = - ] && return 0
  out="$(amixer -q -c "$MCARD" sset "$MCTL" "${MVOL}%" unmute 2>&1)" && return 0
  fail "réglage du mixeur (carte $MCARD, $MCTL ${MVOL} %) en échec : $(printf '%s' "$out" | head -1) — nouvel essai toutes les 5 s"
  return 1
}

probe() {
  out="$(head -c 19200 /dev/zero | aplay -q -D "$PCM" -t raw -f S16_LE -c 2 -r 48000 2>&1)" && return 0
  fail "sortie $PCM impossible à ouvrir : $(printf '%s' "$out" | head -1) — nouvel essai toutes les 5 s"
  return 1
}

read_talk() {   # pose GEN et READY ; builtins seulement (lu toutes les 0,2 s)
  GEN=0; READY=0
  [ -r "$TALK" ] || return 0
  while read -r i g r _; do
    [ "$i" = "$ID" ] || continue
    case "$g" in ''|*[!0-9]*) g=0;; esac
    [ "$r" = 1 ] || r=0
    GEN="$g"; READY="$r"
    break
  done < "$TALK"
}

# play : 0 = parole jouée jusqu'au bout ; 10 = rien reçu (pas de publieur), carte non ouverte ;
# autre = échec de la sortie ALSA.
play() {
  ffmpeg -nostdin -hide_banner -loglevel error -fflags nobuffer -probesize 32 -analyzeduration 0 \
    -rtsp_transport tcp -timeout 5000000 -i "$URL" -vn -sn -dn -ac 2 -ar 48000 \
    -flush_packets 1 -f s16le pipe:1 > "$FIFO" 2>"$RUN/$ID.fferr" &
  ff=$!; echo "$ff" > "$RUN/$ID.ff"
  ( n="$(dd bs=4 count=1 iflag=fullblock 2>/dev/null | wc -c)"
    [ "$n" -eq 4 ] || exit 10
    exec aplay -q -D "$PCM" -t raw -f S16_LE -c 2 -r 48000 \
      --buffer-time=$((BUF_MS * 1000)) --period-time=$((BUF_MS * 250)) --start-delay=$((BUF_MS * 500))
  ) < "$FIFO" 2>"$RUN/$ID.aperr" &
  ap=$!; echo "$ap" > "$RUN/$ID.ap"
  wait "$ap"; rc=$?
  kill -TERM "$ff" 2>/dev/null; wait "$ff" 2>/dev/null
  ff=""; ap=""; rm -f "$RUN/$ID.ff" "$RUN/$ID.ap"
  if [ "$rc" -ne 10 ]; then
    show_errors "$RUN/$ID.fferr" ffmpeg
    show_errors "$RUN/$ID.aperr" aplay
  fi
  return "$rc"
}

mkdir -p "$RUN" "$STATUS_DIR" || exit 1
rm -f "$FIFO"; mkfifo -m 600 "$FIFO" || exit 1
# Battement : rafraîchit le statut tant que CE travailleur vit ($$ = lui, même dans ce sous-shell).
( while kill -0 $$ 2>/dev/null; do touch "$ST" 2>/dev/null; sleep 2; done ) &

read_talk; last="$GEN"          # une génération d'avant le démarrage ne déclenche rien
pending=""; until_s=0; ready_out=0
while :; do
  if [ "$ready_out" = 0 ]; then
    if ! mixer; then status "error mixer"; pause 5; continue; fi
    if ! probe; then status "error output"; pause 5; continue; fi
    ready_out=1; status idle; last_fail=""
    if [ "$MCARD" = - ]; then mix="mixeur non touché"; else mix="mixeur $MCARD $MCTL ${MVOL} % activé"; fi
    log "prêt (sortie $PCM, $mix, tampon ${BUF_MS} ms)"
  fi
  read_talk
  # Génération = instant (ms) de la dernière publication autorisée : seule une génération PLUS
  # RÉCENTE déclenche (lab-media-auth redémarré repart de 0 : rien à jouer).
  if [ "$GEN" != "$last" ]; then
    [ "$GEN" -gt "$last" ] && { pending=1; until_s=$(( $(date +%s) + 15 )); }
    last="$GEN"
  fi
  want="$READY"
  if [ -n "$pending" ]; then
    if [ "$(date +%s)" -le "$until_s" ]; then want=1; else pending=""; fi
  fi
  if [ "$want" != 1 ]; then pause 0.2; continue; fi
  play; rc=$?
  case "$rc" in
    0)  pending=""; log "fin de parole" ;;
    10) pause 0.3 ;;
    *)  log "sortie ALSA en échec (aplay, code $rc)"; status "error output"; ready_out=0; pending=""; pause 5 ;;
  esac
done
