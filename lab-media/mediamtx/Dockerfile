# Images de MediaMTX (service `media`) et de la capture (service `capture`).
# Épinglée par digest : MediaMTX 1.21.1 + ffmpeg (alpine). Ne pas passer sur un tag
# flottant : le comportement du hook, de HLS et des expulsions a été vérifié sur CETTE version.
#
# Trois étapes : `base` (commune), `capture` (+ alsa-utils pour le haut-parleur : amixer et
# aplay, + les scripts de capture), et la DERNIÈRE, `media`, que construit le service `media`
# (son `build: ./mediamtx` sans cible). MediaMTX n'a donc ni alsa-utils ni scripts de capture.
FROM bluenviron/mediamtx:1.21.1-ffmpeg@sha256:00ef3d1a243f3769ca36769b47df241a0c269c83a7735005b817505c49adb651 AS base
COPY entrypoint.sh /opt/lab-media/
ENTRYPOINT ["/bin/sh", "/opt/lab-media/entrypoint.sh"]

FROM base AS capture
# Alpine 3.24 (celle de l'image épinglée) : alsa-utils 1.2.15.
# v4l-utils : v4l2-ctl, pour le gain automatique des webcams (capture-one.sh).
RUN apk add --no-cache 'alsa-utils~1.2.15' 'v4l-utils~1.32'
COPY capture.sh capture-one.sh speaker-one.sh /opt/lab-media/

FROM base AS media
