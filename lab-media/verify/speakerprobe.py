"""Mesure de latence du haut-parleur pour verify.sh (chantier haut-parleur). Tourne dans lmt-hw.

  speakerprobe.py feed            PCM s16le mono 48 kHz sur la sortie standard, au rythme réel :
                                  silence, puis, une fois la publication prête (/tmp/hp-go) et le
                                  flux fluide depuis 1 s, trois bips de 0,3 s (1 kHz) à +3, +6 et
                                  +9 s, fin à +45 s. Écrit sur la sortie
                                  d'erreur, en JSON, l'heure (horloge de l'hôte) de chaque bip.
  speakerprobe.py watch <fichier> <durée s> <sortie.json>
                                  surveille le fichier où le faux haut-parleur (plugin ALSA
                                  « file ») écrit ce qu'il joue, et note l'heure d'arrivée de
                                  chaque début de bip. Un fichier tronqué (nouvelle ouverture de
                                  la sortie par aplay) est suivi.

Latence mesurée = arrivée dans la sortie ALSA − remise au publieur : encodage Opus, WHIP
(WebRTC) jusqu'à MediaMTX, relais RTSP, décodage, tube, aplay. Ne comprend PAS le tampon de la
vraie carte (au plus MEDIA_SPEAKER_BUFFER_MS) ni le réseau entre le navigateur et le lab.
"""
import json
import math
import os
import struct
import sys
import time

RATE = 48000
TONES = (3.0, 6.0, 9.0)       # après le démarrage effectif du flux
TONE_S = 0.3
END_S = 45.0                  # la parole dure assez pour les contrôles faits pendant (second publieur…)
STABLE_S = 1.0
GO = '/tmp/hp-go'             # posé par verify.sh quand MediaMTX voit la publication prête


def feed():
    """Comme un micro en direct : ce qui n'a pas pu être remis à temps est perdu, jamais rattrapé
    en rafale (le publieur peut mettre plusieurs secondes à démarrer sur un hôte chargé). Les bips
    ne sont programmés qu'une fois la publication prête (fichier GO) et les écritures fluides
    depuis STABLE_S : avant cela, les tampons de `docker run -i` et du publieur peuvent retenir
    des secondes de signal."""
    marks = []
    try:
        _feed(marks)
    finally:                     # même interrompu (tube fermé), les heures des bips sont rendues
        sys.stderr.write(json.dumps({'tones': marks}) + '\n')


def _feed(marks):
    out = sys.stdout.buffer
    last = time.time()
    stable_since = last
    start = None                 # instant de référence des bips
    phase = 0.0
    while start is None or time.time() < start + END_S:
        now = time.time()
        n = min(int((now - last) * RATE), RATE // 20)       # au plus 50 ms : le retard est perdu
        if n <= 0:
            time.sleep(0.002)
            continue
        prev, last = now - n / RATE, now          # ce morceau couvre [prev, now)
        if start is None and now - stable_since >= STABLE_S and os.path.exists(GO):
            start = now
        samples = []
        for i in range(n):
            t = prev + i / RATE
            on = start is not None and any(start + s <= t < start + s + TONE_S for s in TONES)
            samples.append(int(16000 * math.sin(phase)) if on else 0)
            phase += 2 * math.pi * 1000 / RATE
        if start is not None:
            for k, s in enumerate(TONES):
                if len(marks) == k and prev <= start + s < now:
                    marks.append(start + s)           # début du bip (horloge de l'hôte), remis maintenant
        t0 = time.time()
        out.write(struct.pack(f'<{n}h', *samples))
        out.flush()
        if time.time() - t0 > 0.02:      # écriture bloquée : le publieur ne suit pas encore
            stable_since = time.time()
            if start is not None and not marks:
                start = None


def watch(path, duration, dest):
    end = time.time() + duration
    try:                # ce qui est déjà dans le fichier (joué avant) n'est pas mesuré
        offset = os.path.getsize(path)
    except OSError:
        offset = 0
    calm = 0            # trames consécutives sans échantillon fort (> 8000)
    onsets, sessions = [], []
    carry = b''
    while time.time() < end:
        try:
            size = os.path.getsize(path)
        except OSError:
            time.sleep(0.003)
            continue
        if size < offset:                      # aplay a rouvert la sortie : fichier tronqué
            offset, carry = 0, b''
        if size > offset:
            now = time.time()
            if offset == 0:
                sessions.append(now)
            with open(path, 'rb') as fh:
                fh.seek(offset)
                data = carry + fh.read(size - offset)
            offset = size
            usable = len(data) - len(data) % 4         # trames stéréo s16 complètes
            carry = data[usable:]
            for (left, _right) in struct.iter_unpack('<hh', data[:usable]):
                if abs(left) > 8000:
                    if calm > RATE // 5:          # premier échantillon fort après 0,2 s sans : un début de bip
                        onsets.append(now)
                    calm = 0
                else:
                    calm += 1
        time.sleep(0.003)
    with open(dest, 'w') as fh:
        json.dump({'onsets': onsets, 'sessions': sessions}, fh)


if __name__ == '__main__':
    if sys.argv[1] == 'feed':
        feed()
    else:
        watch(sys.argv[2], float(sys.argv[3]), sys.argv[4])
