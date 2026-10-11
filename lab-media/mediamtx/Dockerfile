# Image commune à MediaMTX (service `media`) et à la capture (service `capture`).
# Épinglée par digest : MediaMTX 1.21.1 + ffmpeg (alpine). Ne pas passer sur un tag
# flottant : le comportement du hook, de HLS et des expulsions a été vérifié sur CETTE version.
FROM bluenviron/mediamtx:1.21.1-ffmpeg@sha256:00ef3d1a243f3769ca36769b47df241a0c269c83a7735005b817505c49adb651

COPY entrypoint.sh capture.sh wait-devices.sh /opt/lab-media/

ENTRYPOINT ["/bin/sh", "/opt/lab-media/entrypoint.sh"]
