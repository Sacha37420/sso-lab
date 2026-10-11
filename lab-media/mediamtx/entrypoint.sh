#!/bin/sh
# Lance MediaMTX avec la configuration dérivée du registre (écrite par lab-media-auth dans
# /config) et les surcharges MTX_* tirées de .env. Toute clé manquante ou mal formée => arrêt
# immédiat (jamais de défaut silencieux sur un secret).
set -eu

die() { echo "[entrypoint] ERREUR : $*" >&2; exit 1; }

for k in LAB_MEDIA_HOOK_KEY MEDIA_WEBRTC_PORT; do
  eval "v=\${$k:-}"
  [ -n "$v" ] || die "clé $k absente ou vide dans .env"
done
# Injectée dans une URL : on n'accepte que [A-Za-z0-9_-] plutôt que d'échapper.
case "$LAB_MEDIA_HOOK_KEY" in *[!A-Za-z0-9_-]*) die "LAB_MEDIA_HOOK_KEY contient des caractères hors [A-Za-z0-9_-]";; esac
case "$MEDIA_WEBRTC_PORT" in ''|*[!0-9]*) die "MEDIA_WEBRTC_PORT non numérique";; esac

# Adresse de CE conteneur sur le réseau interne de lab-media : l'alias « lab-media-ctl »
# n'existe que là. L'API et la relecture n'écoutent que sur elle — elles ne sont pas ouvertes
# sur dev-net ni sur sso-net, quels que soient les identifiants.
CTL_IP="$(getent hosts lab-media-ctl | awk 'NR==1{print $1}')"
[ -n "$CTL_IP" ] || die "alias lab-media-ctl introuvable (réseau interne absent du compose ?)"

export MTX_AUTHHTTPADDRESS="http://lab-media-hook:9000/hook?key=${LAB_MEDIA_HOOK_KEY}"
export MTX_APIADDRESS="${CTL_IP}:9997"
export MTX_PLAYBACKADDRESS="${CTL_IP}:9996"
# ICE WebRTC (UDP + TCP sur le même port, publié tel quel sur l'hôte).
export MTX_WEBRTCLOCALUDPADDRESS=":${MEDIA_WEBRTC_PORT}"
export MTX_WEBRTCLOCALTCPADDRESS=":${MEDIA_WEBRTC_PORT}"
if [ "${MEDIA_WEBRTC_IPS_FROM_INTERFACES:-no}" = "yes" ]; then
  # Essais sans port publié seulement : annonce les adresses des réseaux Docker.
  export MTX_WEBRTCIPSFROMINTERFACES=yes
else
  [ -n "${MEDIA_WEBRTC_HOSTS:-}" ] || die "clé MEDIA_WEBRTC_HOSTS absente ou vide dans .env"
  export MTX_WEBRTCADDITIONALHOSTS="${MEDIA_WEBRTC_HOSTS}"
fi

CONF=/config/mediamtx.yml
n=0
while [ ! -s "$CONF" ]; do
  n=$((n + 1))
  [ "$n" -le 60 ] || die "$CONF absent après 60 s (lab-media-auth a-t-il démarré ?)"
  sleep 1
done

exec /mediamtx "$CONF"
