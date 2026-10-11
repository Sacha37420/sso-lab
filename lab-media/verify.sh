#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# verify.sh — prouve la brique lab-media en réel, sans matériel et sans toucher au lab.
#
#   bash lab-media/verify.sh            lance tout, nettoie à la fin
#   bash lab-media/verify.sh --keep     laisse la pile de test en place (lmt-*) pour l'explorer
#   bash lab-media/verify.sh --clean    supprime seulement une pile de test restée en place
#
# Pile ISOLÉE : même docker-compose.yml que la production, projet « lmt », conteneurs,
# réseaux et volumes préfixés lmt-. Jamais dev-net ni sso-net, jamais le Caddy du lab (le
# label Caddy est détourné vers « lmtcaddy », lu par un Caddy de test), aucun périphérique
# ouvert, un seul port publié et sur 127.0.0.1 (ICE de test). Sources synthétiques : UN
# encodage court au début (mire 320x240), puis des copies de flux ; l'essai de capture.sh
# (mire, 320x240) est le seul autre encodage et tourne seul.
#
# Deux apps fictives, appa et appb, aux préfixes distincts : voir verify/registry.test.json.
# Durée : environ 4 minutes. Code de sortie : 0 si tout est PASS.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"
RUN="$HERE/verify/.run"
ICE_PORT=18189
PY_IMG="python:3.12-slim@sha256:02108f5d322dd89f1c9e552442c25acb0543dfdbc455693a5599624f20d9155d"
CADDY_IMG="lucaslorentz/caddy-docker-proxy:ci-alpine"
MTX_IMG="bluenviron/mediamtx:1.21.1-ffmpeg@sha256:00ef3d1a243f3769ca36769b47df241a0c269c83a7735005b817505c49adb651"
NAME_RE='^[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}-[0-9]{2}-[0-9]{2}-[0-9]{6}\.mp4$'
KEEP=false; FAILS=0; TOTAL=0

compose() { docker compose -p lmt --env-file "$RUN/test.env" -f "$HERE/docker-compose.yml" "$@"; }

cleanup() {
  local ids
  ids="$(docker ps -aq --filter name='^lmt-')"
  [[ -n "$ids" ]] && docker rm -f $ids >/dev/null 2>&1
  [[ -f "$RUN/test.env" ]] && compose down --volumes --remove-orphans >/dev/null 2>&1
  for n in lmt-dev lmt-sso lmt_internal; do docker network rm "$n" >/dev/null 2>&1; done
  for v in lmt-recordings lmt-fixture lmt_config; do docker volume rm "$v" >/dev/null 2>&1; done
  docker image rm lmt-auth lmt-media >/dev/null 2>&1
  rm -rf "$RUN"
}

case "${1:-}" in
  --clean) cleanup; echo "pile de test supprimée"; exit 0 ;;
  --keep) KEEP=true ;;
  '') ;;
  *) echo "usage : verify.sh [--keep|--clean]" >&2; exit 2 ;;
esac

note()  { printf '\n\033[0;36m══ %s\033[0m\n' "$*"; }
result() {  # result <PASS|FAIL> <id> <texte>
  TOTAL=$((TOTAL + 1)); [[ "$1" == FAIL ]] && FAILS=$((FAILS + 1))
  printf '%s  %-5s %s\n' "$1" "$2" "$3"
}
expect() {  # expect <id> <texte> <observé> — PASS si la commande précédente a réussi
  local rc=$?
  if [[ $rc -eq 0 ]]; then result PASS "$1" "$2 — $3"; else result FAIL "$1" "$2 — $3"; fi
}
phase() {   # phase <nom> : contrôles lancés dans lmt-client
  local out
  out="$(docker exec lmt-client python /v/checks.py "$1" 2>&1)"
  printf '%s\n' "$out"
  TOTAL=$((TOTAL + $(grep -c -E '^(PASS|FAIL) ' <<<"$out")))
  FAILS=$((FAILS + $(grep -c -E '^FAIL ' <<<"$out")))
  grep -q -E '^(PASS|FAIL) ' <<<"$out" || { result FAIL "$1" "phase sans résultat (erreur du script de contrôle)"; }
}
rnd() { head -c 18 /dev/urandom | od -An -tx1 | tr -d ' \n'; }
ff()  { docker run --rm --network "${NET:-lmt-dev}" -v lmt-fixture:/fixture:ro --entrypoint "${BIN:-ffmpeg}" lmt-media "$@"; }
# Publication d'essai de 3 s (copie de flux). Affiche « accepté » ou la raison du refus.
try_publish() {
  local out
  out="$(ff -hide_banner -nostdin -loglevel error -re -i /fixture/test.mkv -t 3 -c copy \
          -f rtsp -rtsp_transport tcp "rtsp://$1@lmt-media:8554/$2" 2>&1)"
  if [[ -z "$out" ]]; then echo "accepté"; else grep -o -m1 -E '40[0-9] [A-Za-z ]+|Server returned [^)]*\)' <<<"$out" || echo "refusé : ${out:0:80}"; fi
}
publisher() {  # publisher <nom> <réseau> <url> : publication continue, en copie de flux
  docker run -d --name "$1" --network "$2" --cpus 0.3 -v lmt-fixture:/fixture:ro --entrypoint ffmpeg lmt-media \
    -hide_banner -nostdin -loglevel error -re -stream_loop -1 -i /fixture/test.mkv -c copy \
    -f rtsp -rtsp_transport tcp "$3" >/dev/null
}
rec_size() { docker exec lmt-media sh -c "du -sk /recordings/$1 | cut -f1"; }

# ── 0. Préalables ────────────────────────────────────────────────────────────
if [[ -n "$(docker ps -aq --filter name='^lmt-')" || -n "$(docker network ls -q --filter name='^lmt')" ]]; then
  echo "Une pile de test lmt-* existe déjà : bash lab-media/verify.sh --clean" >&2; exit 2
fi
if ss -H -tlnu 2>/dev/null | awk '{print $5}' | grep -q -E ":${ICE_PORT}\$"; then
  echo "Le port de test ${ICE_PORT} est pris sur l'hôte." >&2; exit 2
fi
$KEEP || trap cleanup EXIT

mkdir -p "$RUN"
A_CTL=$(rnd); B_CTL=$(rnd); A_PUB=$(rnd); B_PUB=$(rnd); CAP=$(rnd)
TOKEN_A="tokA-$(rnd)"; TOKEN_B="tokB-$(rnd)"; KEY_A=$(rnd); KEY_B=$(rnd); HOOK=$(rnd)
cp "$HERE/verify/registry.test.json" "$RUN/registry.json"
cat > "$RUN/test.env" <<ENV
LAB_MEDIA_PREFIX=lmt-media
LAB_MEDIA_SSO_NET=lmt-sso
LAB_MEDIA_DEV_NET=lmt-dev
LAB_MEDIA_RECORDINGS_VOLUME=lmt-recordings
LAB_MEDIA_CADDY_LABEL=lmtcaddy
LAB_MEDIA_ICE_BIND=127.0.0.1
LAB_MEDIA_REGISTRY=$RUN/registry.json
LAB_MEDIA_ENV_FILE=$RUN/test.env
COMPOSE_PROFILES=
DOMAIN=http://lmt-caddy
MEDIA_WEBRTC_PORT=$ICE_PORT
MEDIA_WEBRTC_IPS_FROM_INTERFACES=yes
LAB_MEDIA_HOOK_KEY=$HOOK
LAB_MEDIA_READ_HOOK_TIMEOUT_S=3
LAB_MEDIA_APP_APPA_HOOK_KEY=$KEY_A
LAB_MEDIA_APP_APPA_CONTROL_USER=appa-ctl
LAB_MEDIA_APP_APPA_CONTROL_PASSWORD=$A_CTL
LAB_MEDIA_APP_APPA_PUBLISH_USER=appa-pub
LAB_MEDIA_APP_APPA_PUBLISH_PASSWORD=$A_PUB
LAB_MEDIA_APP_APPB_HOOK_KEY=$KEY_B
LAB_MEDIA_APP_APPB_CONTROL_USER=appb-ctl
LAB_MEDIA_APP_APPB_CONTROL_PASSWORD=$B_CTL
LAB_MEDIA_APP_APPB_PUBLISH_USER=appb-pub
LAB_MEDIA_APP_APPB_PUBLISH_PASSWORD=$B_PUB
LAB_MEDIA_SOURCE_CAPTURE_PUBLISH_USER=capture
LAB_MEDIA_SOURCE_CAPTURE_PUBLISH_PASSWORD=$CAP
LAB_MEDIA_PULL_TEST=rtsp://lmt-src:8554/ext
ENV
chmod 600 "$RUN/test.env"
cat > "$RUN/src.yml" <<YML
# Second MediaMTX de test : une « caméra IP » (chemin ext, tiré par lab-media) et un lecteur
# WHEP (chemin whep-a : lit appa/cam à travers le Caddy de test, comme un navigateur).
logLevel: info
api: no
rtmp: no
srt: no
moq: no
hls: no
webrtc: no
rtspTransports: [tcp]
paths:
  ext:
  whep-a:
    source: whep://lmt-caddy/lab-media-webrtc/appa/cam/whep
    whepBearerToken: $TOKEN_A
YML

# ── 1. Images (sous le verrou du lab) et tests sans réseau ───────────────────
note "Construction des images (verrou du lab)"
bash "$ROOT/scripts/lab-lock.sh" docker compose -p lmt --env-file "$RUN/test.env" -f "$HERE/docker-compose.yml" build -q auth media
rc=$?
[[ $rc -eq 75 ]] && { echo "Verrou du lab occupé (75) : réessayer plus tard." >&2; exit 75; }
[[ $rc -eq 0 ]] || { echo "Construction en échec ($rc)." >&2; exit 1; }

note "Tests sans réseau (registre, propriété des chemins, décisions du hook)"
out="$(docker run --rm --name lmt-unit lmt-auth python -m unittest 2>&1 | tail -3)"
grep -q '^OK' <<<"$out"; expect U1 "tests unitaires de lab-media-auth" "$(tr '\n' ' ' <<<"$out")"

# ── 2. Pile de test ──────────────────────────────────────────────────────────
note "Pile de test (réseaux, source synthétique, apps fictives, lab-media)"
docker network create --internal lmt-dev >/dev/null
docker network create lmt-sso >/dev/null
docker volume create lmt-recordings >/dev/null
docker volume create lmt-fixture >/dev/null
# Le SEUL encodage de la source : 20 s de mire + bip, relus ensuite en copie de flux.
docker run --rm --name lmt-encode --network none --cpus 1 -v lmt-fixture:/fixture --entrypoint ffmpeg lmt-media \
  -hide_banner -nostdin -loglevel error -f lavfi -i "testsrc2=size=320x240:rate=10" \
  -f lavfi -i "sine=frequency=440:sample_rate=48000" -t 20 \
  -c:v libx264 -preset ultrafast -profile:v baseline -pix_fmt yuv420p -g 10 -bf 0 -b:v 150k \
  -c:a libopus -b:a 32k -ac 1 /fixture/test.mkv
expect F1 "source synthétique encodée une fois" "mire 320x240 10 i/s + bip, 20 s"

docker run -d --name lmt-appa --network lmt-dev -v "$HERE/verify:/v:ro" -e HOOK_KEY="$KEY_A" -e GOOD_TOKEN="$TOKEN_A" "$PY_IMG" python /v/fakeapp.py >/dev/null
docker run -d --name lmt-appb --network lmt-dev -v "$HERE/verify:/v:ro" -e HOOK_KEY="$KEY_B" -e GOOD_TOKEN="$TOKEN_B" "$PY_IMG" python /v/fakeapp.py >/dev/null
compose up -d --no-build auth media >/dev/null 2>&1
expect F2 "docker compose up (le compose de production, projet lmt)" "$(docker ps --filter name='^lmt-media' --format '{{.Names}}:{{.Status}}' | tr '\n' ' ')"
docker run -d --name lmt-caddy --network lmt-sso -e CADDY_INGRESS_NETWORKS=lmt-sso -e CADDY_DOCKER_LABEL_PREFIX=lmtcaddy \
  -v /var/run/docker.sock:/var/run/docker.sock:ro "$CADDY_IMG" >/dev/null
docker run -d --name lmt-src --network lmt-sso -v "$RUN/src.yml:/mediamtx.yml:ro" "$MTX_IMG" >/dev/null
docker network connect lmt-dev lmt-src
docker run -d --name lmt-client --network lmt-dev -v "$HERE/verify:/v:ro" \
  -e AUTH_URL=http://lmt-media-auth:9100 -e CADDY_URL=http://lmt-caddy -e MEDIA_HOST=lmt-media \
  -e A_USER=appa-ctl -e A_PASS="$A_CTL" -e B_USER=appb-ctl -e B_PASS="$B_CTL" \
  -e A_PUB_USER=appa-pub -e A_PUB_PASS="$A_PUB" -e TOKEN_A="$TOKEN_A" -e TOKEN_B="$TOKEN_B" \
  "$PY_IMG" sleep 3600 >/dev/null
docker network connect lmt-sso lmt-client
sleep 4
if [[ "$(docker inspect -f '{{.State.Running}} {{.RestartCount}}' lmt-media 2>/dev/null)" != "true 0" ]]; then
  echo "lab-media de test non démarré — journal de lab-media-auth :" >&2
  docker logs --tail 5 lmt-media-auth >&2; docker logs --tail 5 lmt-media >&2
  exit 1
fi

lab_caddy_sees="$(docker ps --filter name='^lmt-' --format '{{.Labels}}' | tr ',' '\n' | grep -c -E '^caddy(\.|=|_)' || true)"
[[ "$lab_caddy_sees" == 0 ]]; expect F3 "aucun conteneur de test ne porte de label « caddy » (le Caddy du lab ne les voit pas)" "$lab_caddy_sees label(s)"
published="$(docker ps --filter name='^lmt-' --format '{{.Ports}}' | tr ',' '\n' | grep -- '->' | grep -v '127\.0\.0\.1:' | grep -c . || true)"
[[ "$published" == 0 ]]; expect F4 "aucun port de test publié hors 127.0.0.1" "$published port(s) publié(s) ailleurs"

# ── 3. Publication ───────────────────────────────────────────────────────────
note "Publication (I2) — essais de 3 s en copie de flux"
r="$(try_publish "appa-pub:$A_PUB" appa/cam)";        [[ "$r" == accepté ]];  expect P1 "publication d'appa sous son préfixe, bons identifiants" "$r"
r="$(try_publish "appa-pub:mauvais" appa/cam)";       [[ "$r" == *401* ]];    expect P2 "mauvais mot de passe refusé" "$r"
r="$(try_publish "" appa/cam | sed 's/^@//')";        [[ "$r" == *401* ]];    expect P3 "sans identifiants refusé" "$r"
r="$(try_publish "appa-pub:$A_PUB" appb/cam)";        [[ "$r" == *401* ]];    expect P4 "identifiants d'appa sous le préfixe d'appb refusés" "$r"
r="$(try_publish "appb-pub:$B_PUB" appa/cam)";        [[ "$r" == *401* ]];    expect P5 "identifiants d'appb sous le préfixe d'appa refusés" "$r"
r="$(try_publish "appa-pub:$A_PUB" appa/inconnu)";    [[ "$r" != accepté ]];  expect P6 "chemin non déclaré au registre refusé" "$r"
r="$(try_publish "appb-pub:$B_PUB" appb/pulled)";     [[ "$r" != accepté ]];  expect P9 "publication sur un chemin tiré refusée" "$r"
r="$(try_publish "capture:$CAP" appa/cam)";           [[ "$r" == *401* ]];    expect P10 "identifiants de la source capture hors de ses chemins refusés" "$r"
r="$(try_publish "appa-ctl:$A_CTL" appa/cam)";        [[ "$r" == *401* ]];    expect P11 "identifiants de CONTRÔLE refusés pour publier" "$r"

publisher lmt-pub-a   lmt-dev "rtsp://appa-pub:$A_PUB@lmt-media:8554/appa/cam"
publisher lmt-pub-a2  lmt-dev "rtsp://appa-pub:$A_PUB@lmt-media:8554/appa/short"
publisher lmt-pub-b   lmt-dev "rtsp://appb-pub:$B_PUB@lmt-media:8554/appb/cam"
publisher lmt-pub-ext lmt-dev "rtsp://lmt-src:8554/ext"
T_START=$(date +%s)
phase ready
phase whip

# ── 4. Contrôle, lecture ─────────────────────────────────────────────────────
note "API de contrôle (I3) — cloisonnement entre apps"
phase control
note "Lecture (I2) — relais au hook de l'app propriétaire"
phase read
r="$(BIN=ffprobe ff -hide_banner -loglevel error -rtsp_transport tcp -show_entries stream=codec_name -of csv=p=0 "rtsp://x:$TOKEN_A@lmt-media:8554/appa/cam" 2>&1 | tr '\n' ' ')"
[[ "$r" == *h264* ]]; expect L9 "lecture RTSP par une app (jeton en mot de passe)" "$r"
r="$(BIN=ffprobe ff -hide_banner -loglevel error -rtsp_transport tcp -show_entries stream=codec_name -of csv=p=0 "rtsp://x:$TOKEN_B@lmt-media:8554/appa/cam" 2>&1 | tr '\n' ' ')"
[[ "$r" == *401* ]]; expect L10 "lecture RTSP d'appa/cam avec le jeton d'appb refusée" "${r:0:90}"

note "Hook d'app en panne : 500, puis suspendu"
phase hook_modes
r="$(docker logs lmt-media-auth 2>&1 | grep 'délai dépassé' | tail -1)"
ms="$(sed -n 's/.*"ms":\([0-9.]*\).*/\1/p' <<<"$r")"
[[ -n "$ms" ]] && awk -v m="$ms" 'BEGIN{exit !(m >= 2900 && m <= 3600)}'
expect H6 "délai du relais borné à LAB_MEDIA_READ_HOOK_TIMEOUT_S (3 s), sous les 10 s de MediaMTX" "décision rendue en ${ms:-?} ms"

note "App autorité ARRÊTÉE"
s0="$(rec_size appa/cam)"
docker stop -t 1 lmt-appa >/dev/null
phase app_down
s1="$(rec_size appa/cam)"
[[ "$s1" -gt "$s0" ]]; expect D4 "app autorité arrêtée : l'enregistrement continue" "appa/cam ${s0} ko → ${s1} ko"
docker start lmt-appa >/dev/null; sleep 2

note "Expulsion : HLS et WebRTC"
phase hls_kick
phase webrtc_kick
note "Relecture"
phase recordings
r="$(docker exec lmt-client cat /tmp/lmt-clip.mp4 2>/dev/null | docker run --rm -i --network none --entrypoint ffprobe lmt-media -v error -show_entries stream=codec_name:format=duration -of csv=p=0 pipe:0 2>&1 | tr '\n' ' ')"
[[ "$r" == *h264* && "$r" == *opus* ]]; expect E9 "la plage relue est un fMP4 lisible (H.264 + Opus)" "$r"

# ── 5. Réseau ────────────────────────────────────────────────────────────────
note "Cloisonnement réseau"
phase net
r="$(docker run --rm --name lmt-probe --network lmt_internal -e K="$HOOK" -e U=appa-ctl -e P="$A_CTL" "$PY_IMG" python -c '
import base64, os, urllib.request, urllib.error
def get(url, auth=None, data=None):
    h = {"Authorization": "Basic " + base64.b64encode(auth.encode()).decode()} if auth else {}
    try: return urllib.request.urlopen(urllib.request.Request(url, headers=h, data=data), timeout=8).status
    except urllib.error.HTTPError as e: return e.code
    except Exception as e: return type(e).__name__
e = os.environ
print(get("http://lab-media-ctl:9997/v3/paths/list"), get("http://lab-media-ctl:9997/v3/paths/list", e["U"] + ":" + e["P"]),
      get("http://lab-media-ctl:9996/list?path=appa/cam", e["U"] + ":" + e["P"]),
      get("http://lab-media-hook:9000/hook?key=faux", data=b"{\"action\":\"api\"}"),
      get("http://lab-media-hook:9000/hook?key=" + e["K"], data=b"{\"action\":\"api\",\"user\":\"" + e["U"].encode() + b"\",\"password\":\"" + e["P"].encode() + b"\"}"))
' 2>&1)"
[[ "$r" == "401 401 401 401 401" ]]; expect N4 "depuis le réseau interne même : API et relecture de MediaMTX refusées sans les identifiants internes (anonyme, identifiants d'app), hook refusé (mauvaise clé ; bonne clé + identifiants d'app)" "$r"

# ── 6. Capture (mire) — le seul autre encodage, lancé seul ──────────────────
note "Source interne : capture.sh"
r="$(docker run --rm --name lmt-capture-nodev --network none -e LAB_MEDIA_SOURCE_CAPTURE_PUBLISH_USER=capture -e LAB_MEDIA_SOURCE_CAPTURE_PUBLISH_PASSWORD="$CAP" \
      -e MEDIA_DEVICE_VIDEO=/dev/v4l/by-id/inexistant -e MEDIA_DEVICE_AUDIO=hw:CARD=AUCUNE,DEV=0 -e MEDIA_DEVICE_WAIT_MAX_S=2 \
      --entrypoint timeout lmt-media 6 sh /opt/lab-media/capture.sh 2>&1 | head -4 | tr '\n' '|')"
[[ "$r" == *"attente"* ]]; expect S0 "capture.sh, mode device sans périphérique : attend et le dit, n'ouvre rien" "${r:0:170}"
docker run -d --name lmt-capture --network lmt_internal --cpus 1 -e MEDIA_CAPTURE_MODE=testsrc \
  -e LAB_MEDIA_SOURCE_CAPTURE_PUBLISH_USER=capture -e LAB_MEDIA_SOURCE_CAPTURE_PUBLISH_PASSWORD="$CAP" \
  --entrypoint sh lmt-media /opt/lab-media/capture.sh >/dev/null
phase capture
sleep 3
r="$(docker exec lmt-media sh -c 'ls /recordings/webcam/av' | head -3 | tr '\n' ' ')"
grep -q -E "$NAME_RE" <<<"${r%% *}"; expect S2 "webcam/av enregistré sous /recordings/webcam/av/<date>.mp4, même forme de nom que l'existant" "$r"
docker rm -f lmt-capture >/dev/null

# ── 7. Arrêt de lab-media-auth ───────────────────────────────────────────────
note "lab-media-auth ARRÊTÉ (cycle de vie)"
started0="$(docker inspect -f '{{.State.StartedAt}}' lmt-media)"
s0="$(rec_size appa/cam)"
docker stop -t 2 lmt-media-auth >/dev/null
phase auth_down
r="$(try_publish "appb-pub:$B_PUB" appb/cam)"; [[ "$r" != accepté ]]
expect X3 "lab-media-auth arrêté : aucune NOUVELLE publication ne s'authentifie" "$r"
sleep 3
s1="$(rec_size appa/cam)"; alive="$(docker inspect -f '{{.State.Running}}' lmt-pub-a lmt-pub-b | tr '\n' ' ')"
[[ "$s1" -gt "$s0" && "$alive" == "true true " ]]
expect X4 "lab-media-auth arrêté : publications en cours et enregistrement CONTINUENT" "appa/cam ${s0} ko → ${s1} ko, ffmpeg en vie : $alive"
docker start lmt-media-auth >/dev/null
phase auth_back
[[ "$(docker inspect -f '{{.State.StartedAt}}' lmt-media)" == "$started0" ]]
expect X7 "MediaMTX n'a pas redémarré avec lab-media-auth" "StartedAt inchangé ($started0)"

note "Ajout d'un chemin au registre, rechargement à chaud"
python3 - "$RUN/registry.json" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p)); d['paths']['appa/extra'] = {}
open(p, 'w').write(json.dumps(d, indent=2))     # même inode : le montage du conteneur le voit
PY
# Comme en service après un ajout d'app (nouveaux secrets dans .env) : le conteneur de
# lab-media-auth est RECRÉÉ (nouvelle adresse sur le réseau interne), pas MediaMTX.
compose up -d --no-build --force-recreate --no-deps auth >/dev/null 2>&1
phase reload
r="$(docker logs lmt-media 2>&1 | grep -c -i 'reloading configuration')"
[[ "$r" -ge 1 && "$(docker inspect -f '{{.State.StartedAt}}' lmt-media)" == "$started0" ]]
expect G3 "lab-media-auth recréé par compose : MediaMTX a rechargé sa configuration sans redémarrer" "$r rechargement(s) dans son journal"

# ── 8. Enregistrements : forme et rétention ──────────────────────────────────
note "Enregistrements : arborescence, noms, rétention"
tree="$(docker exec lmt-media sh -c 'cd /recordings && find . -type f | sort')"
bad="$(sed 's#.*/##' <<<"$tree" | grep -v -c -E "$NAME_RE" || true)"
dirs="$(sed 's#/[^/]*$##' <<<"$tree" | sort -u | tr '\n' ' ')"
[[ "$bad" == 0 && "$dirs" == *"./appa/cam"* && "$dirs" == *"./webcam/av"* ]]
expect V1 "arborescence /recordings/<chemin>/AAAA-MM-JJ_HH-MM-SS-µµµµµµ.mp4" "dossiers : $dirs · noms hors forme : $bad"
elapsed=$(( $(date +%s) - T_START )); while [[ $elapsed -lt 75 ]]; do sleep 5; elapsed=$(( $(date +%s) - T_START )); done
n="$(docker exec lmt-media sh -c 'ls /recordings/appa/short | wc -l')"
oldest="$(docker exec lmt-media sh -c 'f=$(ls /recordings/appa/short | head -1); echo $(( $(date +%s) - $(stat -c %Y /recordings/appa/short/$f) ))')"
[[ "$n" -ge 2 && "$n" -le 9 && "$oldest" -le 45 ]]
expect V2 "rétention (segments de 5 s, purge à 20 s) : les anciens segments sont supprimés" "${elapsed} s de publication ≈ $((elapsed / 5)) segments écrits, $n présents, le plus ancien modifié il y a ${oldest} s"
n1h="$(docker exec lmt-media sh -c 'ls /recordings/appa/cam | wc -l')"
[[ "$n1h" -ge 1 && "$n1h" -le 4 ]]
expect V3 "segments horaires : pas de découpe intempestive (un fichier par publication tant que l'heure ne tourne pas)" "$n1h fichier(s) pour appa/cam"

# ── 9. Journaux sans secret ──────────────────────────────────────────────────
note "Journaux"
logs="$(docker logs lmt-media-auth 2>&1)"
leak=0
for s in "$A_CTL" "$B_CTL" "$A_PUB" "$B_PUB" "$CAP" "$TOKEN_A" "$TOKEN_B" "$KEY_A" "$KEY_B" "$HOOK"; do
  grep -q -F -- "$s" <<<"$logs" && leak=$((leak + 1))
done
[[ "$leak" == 0 && "$(grep -c '"event":"hook"' <<<"$logs")" -gt 10 ]]
expect J1 "journal de lab-media-auth : décisions présentes, aucun mot de passe, jeton ni clé" "$(grep -c '"event"' <<<"$logs") lignes, $leak secret(s) trouvé(s)"
mleak=0
mlogs="$(docker logs lmt-media 2>&1)"
for s in "$A_CTL" "$B_CTL" "$A_PUB" "$B_PUB" "$CAP" "$TOKEN_A" "$TOKEN_B" "$KEY_A" "$KEY_B"; do
  grep -q -F -- "$s" <<<"$mlogs" && mleak=$((mleak + 1))
done
hookleak="$(grep -c -F -- "$HOOK" <<<"$mlogs" || true)"
[[ "$mleak" == 0 ]]
expect J2 "journal de MediaMTX : aucun identifiant d'app ni jeton" "$mleak secret(s) d'app ; LAB_MEDIA_HOOK_KEY y apparaît $hookleak fois (limite connue, voir README)"

echo
if [[ $FAILS -eq 0 ]]; then
  printf '\033[0;32m%d contrôles, tous PASS\033[0m\n' "$TOTAL"
else
  printf '\033[0;31m%d contrôle(s) FAIL sur %d\033[0m\n' "$FAILS" "$TOTAL"
fi
$KEEP && echo "Pile laissée en place : bash lab-media/verify.sh --clean pour la supprimer."
[[ $FAILS -eq 0 ]]
