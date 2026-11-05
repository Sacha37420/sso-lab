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
# Webcams (chantier webcams) : faux matériel (verify/fakehw.py : faux sysfs, faux nœuds sur des
# mineurs inexistants) branché et débranché à chaud ; la capture tourne par le compose de
# production + verify/compose.test.yml, qui remplace /dev de l'hôte par ces faux nœuds et passe
# en mode testsrc. La vraie caméra n'est ni montée ni ouverte.
# Haut-parleurs (chantier haut-parleur) : faux matériel ALSA (verify/asound.test.conf : le lecteur
# joue dans un fichier, aucune carte son n'est ouverte, aucun son ne sort) ; publication WHIP
# par ffmpeg à travers le Caddy de test ; latence mesurée de bout en bout (verify/speakerprobe.py).
# Publication WebRTC relayée (chantier ecran) : appc, URL de hook lue dans le .env de test
# ("read_hook_env"), chemin appc/a ("whip") ; publication WHIP vidéo réelle (mire H.264).
# Durée : environ 12 minutes (hôte chargé). Code de sortie : 0 si tout est PASS.
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

compose() { docker compose -p lmt --env-file "$RUN/test.env" -f "$HERE/docker-compose.yml" -f "$HERE/verify/compose.test.yml" "$@"; }

cleanup() {
  local ids
  ids="$(docker ps -aq --filter name='^lmt-')"
  [[ -n "$ids" ]] && docker rm -f $ids >/dev/null 2>&1
  [[ -f "$RUN/test.env" ]] && compose down --volumes --remove-orphans >/dev/null 2>&1
  for n in lmt-dev lmt-sso lmt_internal; do docker network rm "$n" >/dev/null 2>&1; done
  for v in lmt-recordings lmt-fixture lmt_config lmt_state lmt_speakers lmt-fakesys lmt-fakedev lmt-fakesnd lmt-speakerout; do docker volume rm "$v" >/dev/null 2>&1; done
  docker image rm lmt-auth lmt-media lmt-capture >/dev/null 2>&1
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
A_CTL=$(rnd); B_CTL=$(rnd); A_PUB=$(rnd); B_PUB=$(rnd); CAP=$(rnd); C_CTL=$(rnd); C_PUB=$(rnd)
TOKEN_A="tokA-$(rnd)"; TOKEN_B="tokB-$(rnd)"; TOKEN_C="tokC-$(rnd)"; KEY_A=$(rnd); KEY_B=$(rnd); KEY_C=$(rnd); HOOK=$(rnd)
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
LAB_MEDIA_APP_APPC_HOOK_KEY=$KEY_C
LAB_MEDIA_APP_APPC_HOOK_URL=http://lmt-appc:8000/hook
LAB_MEDIA_APP_APPC_CONTROL_USER=appc-ctl
LAB_MEDIA_APP_APPC_CONTROL_PASSWORD=$C_CTL
LAB_MEDIA_APP_APPC_PUBLISH_USER=appc-pub
LAB_MEDIA_APP_APPC_PUBLISH_PASSWORD=$C_PUB
LAB_MEDIA_SOURCE_CAPTURE_PUBLISH_USER=capture
LAB_MEDIA_SOURCE_CAPTURE_PUBLISH_PASSWORD=$CAP
LAB_MEDIA_PULL_TEST=rtsp://lmt-src:8554/ext
LAB_MEDIA_SYSFS=/fakesys
LAB_MEDIA_SCAN_S=1
MEDIA_CAPTURE_MAX=2
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
bash "$ROOT/scripts/lab-lock.sh" docker compose -p lmt --env-file "$RUN/test.env" -f "$HERE/docker-compose.yml" --profile capture build -q auth media capture
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
for v in lmt-fakesys lmt-fakedev lmt-fakesnd lmt-speakerout; do docker volume create "$v" >/dev/null; done
# Faux matériel : seul conteneur qui écrit le faux sysfs et crée les faux nœuds (mknod). Il lit
# aussi ce que joue le faux haut-parleur (lmt-speakerout) et fournit le signal de la mesure de latence.
docker run -d --name lmt-hw --network none -v "$HERE/verify:/v:ro" -v lmt-fakesys:/fakesys -v lmt-fakedev:/fakedev \
  -v lmt-fakesnd:/fakesnd -v lmt-speakerout:/speaker-out:ro "$PY_IMG" sleep 3600 >/dev/null
# Le SEUL encodage de la source : 20 s de mire + bip, relus ensuite en copie de flux.
docker run --rm --name lmt-encode --network none --cpus 1 -v lmt-fixture:/fixture --entrypoint ffmpeg lmt-media \
  -hide_banner -nostdin -loglevel error -f lavfi -i "testsrc2=size=320x240:rate=10" \
  -f lavfi -i "sine=frequency=440:sample_rate=48000" -t 20 \
  -c:v libx264 -preset ultrafast -profile:v baseline -pix_fmt yuv420p -g 10 -bf 0 -b:v 150k \
  -c:a libopus -b:a 32k -ac 1 /fixture/test.mkv
expect F1 "source synthétique encodée une fois" "mire 320x240 10 i/s + bip, 20 s"

docker run -d --name lmt-appa --network lmt-dev -v "$HERE/verify:/v:ro" -e HOOK_KEY="$KEY_A" -e GOOD_TOKEN="$TOKEN_A" "$PY_IMG" python /v/fakeapp.py >/dev/null
docker run -d --name lmt-appb --network lmt-dev -v "$HERE/verify:/v:ro" -e HOOK_KEY="$KEY_B" -e GOOD_TOKEN="$TOKEN_B" "$PY_IMG" python /v/fakeapp.py >/dev/null
docker run -d --name lmt-appc --network lmt-dev -v "$HERE/verify:/v:ro" -e HOOK_KEY="$KEY_C" -e GOOD_TOKEN="$TOKEN_C" "$PY_IMG" python /v/fakeapp.py >/dev/null
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
  -e C_USER=appc-ctl -e C_PASS="$C_CTL" -e TOKEN_C="$TOKEN_C" \
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

# ── 6. Webcams : découverte, plafond, capture supervisée ─────────────────────
note "Webcams (chantier webcams) : capture.sh seul"
r="$(docker run --rm --name lmt-capture-nodev --network none -e LAB_MEDIA_SOURCE_CAPTURE_PUBLISH_USER=capture -e LAB_MEDIA_SOURCE_CAPTURE_PUBLISH_PASSWORD="$CAP" \
      -e MEDIA_CAPTURE_PLAN=/inexistant --entrypoint timeout lmt-capture 4 sh /opt/lab-media/capture.sh 2>&1 | tr '\n' '|')"
[[ "$r" == *"superviseur prêt"* && "$r" != *ffmpeg* ]]; expect S0 "capture.sh sans plan (aucune webcam) : attend, ne lance aucun ffmpeg, n'ouvre rien" "${r:0:150}"
r="$(docker run --rm --name lmt-capture-max --network none -e LAB_MEDIA_SOURCE_CAPTURE_PUBLISH_USER=capture -e LAB_MEDIA_SOURCE_CAPTURE_PUBLISH_PASSWORD="$CAP" \
      -e MEDIA_CAPTURE_MAX=9 --entrypoint timeout lmt-capture 4 sh /opt/lab-media/capture.sh 2>&1 | tr '\n' '|')"
[[ "$r" == *"MEDIA_CAPTURE_MAX"* ]]; expect S1 "MEDIA_CAPTURE_MAX hors de 0 à 8 : la capture refuse de démarrer" "${r:0:120}"
cfg="$(compose --profile capture config --format json 2>/dev/null)"
r="$(python3 -c '
import json, sys
c = json.load(sys.stdin)["services"]["capture"]
print(json.dumps({"devices": c.get("devices"), "privileged": c.get("privileged", False),
                  "cgroup": c.get("device_cgroup_rules"), "cap_add": c.get("cap_add"),
                  "hostdev": [v["source"] for v in c["volumes"] if v["target"] in ("/hostdev", "/dev/snd")]}))' <<<"$cfg")"
[[ "$r" == '{"devices": null, "privileged": false, "cgroup": ["c 81:* rmw", "c 116:* rmw"], "cap_add": null, "hostdev": ["fakedev", "fakesnd"]}' ]]
expect Z1 "capture (compose de production) : aucun devices:, pas privileged, aucune capacité ajoutée, cgroup 81 et 116 seulement ; en test /dev de l'hôte n'est pas monté" "$r"

hw() { docker exec lmt-hw python /v/fakehw.py "$@" >/dev/null; }
ffpids() {  # ffpids [motif] : pid des ffmpeg de la capture (dont la ligne de commande contient le motif)
  docker exec lmt-media-capture sh -c 'for p in /proc/[0-9]*; do c=$(tr "\0" " " < $p/cmdline 2>/dev/null); case "$c" in ffmpeg*) echo "${p#/proc/} $c";; esac; done' 2>/dev/null \
    | grep -F -- "${1:-ffmpeg}" | cut -d' ' -f1 | sort | tr '\n' ' '
}
ffcount() { local p; p="$(ffpids "$@")"; wc -w <<<"$p" | tr -d ' '; }
CAM1=usb-1b3f-0001-ssn01abtouchtmppwned; CAM2=usb-1b3f-0002-p9-2; CAM3=usb-1b3f-0003-p9-3
HOSTILE_PRODUCT=$'Cam"; touch /tmp/pwned; $(touch /tmp/pwned2) `id` \x1b[31m‮RTL\n<script>alert(1)</script> '"$(printf 'x%.0s' {1..150})"

note "Webcams : branchements à chaud (faux matériel), capture par le compose de production"
phase m_start
compose --profile capture up -d --no-build capture >/dev/null 2>&1
hw plug 9-1 --pid 0001 --serial 'SN-01:ab;$(touch /tmp/pwned)' --product "$HOSTILE_PRODUCT" --mic
hw plug 9-2 --pid 0002 --product "Cam B"
phase m_two
[[ "$(ffcount)" == 2 ]]; expect M31 "un ffmpeg par webcam capturée" "$(ffcount) ffmpeg"
hw plug 9-3 --pid 0003 --product "Cam C"
phase m_wait
sleep 2; [[ "$(ffcount)" == 2 ]]; expect M32 "au-delà du plafond, aucun ffmpeg de plus" "$(ffcount) ffmpeg"
pid2="$(ffpids "$CAM2")"; docker exec lmt-media-capture kill ${pid2} 2>/dev/null
phase m_restart
new2="$(ffpids "$CAM2")"; [[ -n "$new2" && "$new2" != "$pid2" && "$(ffcount)" == 2 ]]
expect M33 "ffmpeg tué : relancé (nouveau pid), toujours un seul par webcam" "pid ${pid2}→ ${new2}"
hw unplug 9-1
phase m_unplug
r="$(ffpids "$CAM1")"; [[ -z "$r" && "$(ffcount)" == 2 ]]
expect M34 "débranchement : le ffmpeg de la webcam est arrêté (aucun orphelin), la place est reprise" "ffmpeg de CAM1 : '${r}', total $(ffcount)"
pid2="$(ffpids "$CAM2")"
phase m_record_on
n=0; while [[ $n -lt 15 ]] && ! docker exec lmt-media sh -c "ls /recordings/webcam/$CAM2/av/*.mp4" >/dev/null 2>&1; do sleep 1; n=$((n + 1)); done
sleep 3
r="$(docker exec lmt-media sh -c "ls /recordings/webcam/$CAM2/av" 2>&1 | head -2 | tr '\n' ' ')"
grep -q -E "$NAME_RE" <<<"${r%% *}" && [[ "$(ffpids "$CAM2")" == "$pid2" ]]
expect M35 "enregistrement à chaud : segments sous /recordings/webcam/<id>/av, capture non relancée (même pid ffmpeg)" "$r · pid ${pid2}→ $(ffpids "$CAM2")"
phase m_record_check
phase m_record_off
sleep 3; a="$(rec_size "webcam/$CAM2/av")"; sleep 4; b="$(rec_size "webcam/$CAM2/av")"
[[ "$a" == "$b" && "$(ffpids "$CAM2")" == "$pid2" ]]
expect M36 "enregistrement coupé à chaud : plus rien n'est écrit, capture toujours la même" "${a} ko → ${b} ko, pid $(ffpids "$CAM2")"
phase m_errors
for k in $(seq 4 13); do hw plug "9-$k" --pid "$(printf '01%02x' "$k")" --product "Rafale $k"; done
phase m_burst
[[ "$(ffcount)" == 2 ]]; expect M37 "dix webcams d'un coup : toujours 2 ffmpeg (plafond), aucune préemption" "$(ffcount) ffmpeg"
hw unplug-all
phase m_none
sleep 2
r="$(docker exec lmt-media-capture sh -c 'for p in /proc/[0-9]*; do tr "\0" " " < $p/cmdline 2>/dev/null; echo; done' | grep -c -E '^(ffmpeg|sh /opt/lab-media/capture-one.sh)' || true)"
[[ "$r" == 0 ]]; expect M38 "tout débranché : aucun ffmpeg ni travailleur restant dans la capture" "$r processus"
r="$(for c in lmt-media-capture lmt-media-auth lmt-hw; do docker exec "$c" sh -c 'ls /tmp/pwned /tmp/pwned2 2>/dev/null'; done | wc -l)"
logs="$(docker logs lmt-media-capture 2>&1; docker logs lmt-media-auth 2>&1)"
[[ "$r" == 0 ]] && ! grep -q -F -e '$(touch' -e 'touch /tmp' -e '<script>' -e 'Rafale' -e 'Cam B' <<<"$logs"
expect M39 "nom de produit et numéro de série hostiles : rien exécuté, jamais au journal (capture, auth)" "$r fichier(s) témoin, journaux propres"
r="$(docker exec lmt-media-auth cat /state/plan)"
[[ -z "$r" ]]; expect M40 "tout débranché : plan de capture vide" "plan='${r}'"
hw plug 9-2 --pid 0002 --product "Cam B"
phase m_back
pid2="$(ffpids "$CAM2")"
r="$(try_publish "capture:$CAP" webcam/av)"; [[ "$r" != accepté ]]
expect M41 "webcam-ancienne jamais capturée : la source capture ne peut pas publier sur webcam/av" "$r"
r="$(try_publish "capture:$CAP" "webcam/$CAM1/av")"; [[ "$r" != accepté ]]
expect M42 "webcam oubliée : plus aucune publication sur ses chemins" "$r"
# Anciens enregistrements de webcam-ancienne : un segment d'appa/cam recopié sous webcam/av.
docker exec lmt-media sh -c 'mkdir -p /recordings/webcam/av && cp "$(ls -d /recordings/appa/cam/*.mp4 | head -1)" /recordings/webcam/av/'
phase m_legacy

# ── 6 bis. Haut-parleurs (chantier haut-parleur) ─────────────────────────────
note "Haut-parleurs : déclarés au registre, lecteur ALSA sur faux matériel"
WHIP_URL="http://lmt-caddy/lab-media-webrtc/speaker/hp-test/whip"
# Publieur WHIP : ffmpeg dans l'espace réseau de lmt-media (ICE sur la boucle locale, le seul
# candidat qu'il essaie), signalisation par le Caddy de test comme un navigateur.
whip_pub() {  # whip_pub <nom> <arguments d'entrée…> — publication WHIP détachée, jeton d'appa
  local name="$1"; shift
  docker run -d --name "$name" --network container:lmt-media --entrypoint ffmpeg lmt-media \
    -hide_banner -loglevel warning "$@" -c:a libopus -b:a 32k -ac 2 -application lowdelay \
    -f whip -authorization "$TOKEN_A" "$WHIP_URL" >/dev/null
}
spk_pid0="$(ffpids "$CAM2")"; cap_started0="$(docker inspect -f '{{.State.StartedAt}}' lmt-media-capture)"
phase hp_start
r="$(try_publish "appa-pub:$A_PUB" speaker/hp-test)"; [[ "$r" != accepté ]]
expect HP23 "RTSP : publication sur speaker/* refusée avec les identifiants de publication de l'app propriétaire" "$r"
r="$(try_publish "capture:$CAP" speaker/hp-test)"; [[ "$r" != accepté ]]
expect HP24 "RTSP : publication sur speaker/* refusée avec les identifiants de la source capture" "$r"
phase hp_whip

note "Haut-parleurs : prise de parole réelle (WHIP), lecture, second publieur, latence"
docker exec lmt-hw rm -f /tmp/hp-go
docker exec -d lmt-hw python /v/speakerprobe.py watch /speaker-out/hp-test.raw 120 /tmp/hp-watch.json
( docker exec -i lmt-hw python /v/speakerprobe.py feed 2>"$RUN/feed.json" \
    | docker run -i --rm --name lmt-whip1 --network container:lmt-media --entrypoint ffmpeg lmt-media \
        -hide_banner -loglevel warning -f s16le -ar 48000 -ac 1 -i pipe:0 \
        -c:a libopus -b:a 32k -ac 2 -application lowdelay -f whip -authorization "$TOKEN_A" "$WHIP_URL" \
        >"$RUN/whip1.log" 2>&1 ) &
WHIP1=$!
phase hp_talk
docker exec lmt-hw touch /tmp/hp-go     # la publication est prête : les bips de mesure peuvent partir
whip_pub lmt-whip2 -re -f lavfi -i "sine=frequency=330:sample_rate=48000" -t 6
n=0; while [[ $n -lt 15 ]] && ! docker logs lmt-media 2>&1 | grep -q 'already publishing to path .speaker/hp-test'; do sleep 1; n=$((n + 1)); done
r="$(docker logs lmt-media 2>&1 | grep 'already publishing to path .speaker/hp-test' | tail -1 | sed 's/^.*\] //')"
[[ -n "$r" ]]; expect HP26 "second publieur WHIP sur un haut-parleur occupé : MediaMTX le refuse (overridePublisher: no)" "$r"
phase hp_talk2
r=""
for cred in "x:$TOKEN_A" "appa-pub:$A_PUB" "appa-ctl:$A_CTL"; do
  r+="$(BIN=ffprobe ff -hide_banner -loglevel error -rtsp_transport tcp -show_entries stream=codec_name -of csv=p=0 \
        "rtsp://$cred@lmt-media:8554/speaker/hp-test" 2>&1 | grep -o -m1 -E '40[0-9] [A-Za-z ]+|opus' || echo '?') · "
done
[[ "$r" != *opus* && "$(grep -o '401' <<<"$r" | wc -l | tr -d ' ')" == 3 ]]
expect HP25 "lecture RTSP de speaker/* refusée pendant la parole : jeton, identifiants de publication, identifiants de contrôle" "$r"
phase hp_talk3
docker rm -f lmt-whip2 >/dev/null 2>&1
wait "$WHIP1"
n=0; while [[ $n -lt 120 ]] && ! docker exec lmt-hw test -s /tmp/hp-watch.json; do sleep 1; n=$((n + 1)); done
lat="$(docker exec lmt-hw cat /tmp/hp-watch.json 2>/dev/null | python3 -c '
import json, sys
w = json.load(sys.stdin); f = json.load(open(sys.argv[1]))
tones, onsets = f["tones"], w["onsets"]
lat = []
for t in tones:
    after = [o for o in onsets if o >= t]
    if after: lat.append(round((after[0] - t) * 1000))
print(json.dumps({"tones": len(tones), "onsets": len(onsets), "ms": lat}))' "$RUN/feed.json" 2>&1)"
python3 -c 'import json,sys; d=json.loads(sys.argv[1]); sys.exit(0 if d["tones"] == 3 and len(d["ms"]) == 3 else 1)' "$lat" 2>/dev/null
expect HP27 "le lecteur reçoit et joue ce qui est publié : les 3 bips du publieur arrivent dans la sortie ALSA (faux matériel)" "$lat"
python3 -c 'import json,sys; d=json.loads(sys.argv[1]); sys.exit(0 if len(d["ms"]) == 3 and max(d["ms"]) < 1000 else 1)' "$lat" 2>/dev/null
expect HP28 "latence publieur → sortie ALSA < 1 s (Opus, WHIP, MediaMTX, RTSP, décodage, aplay ; hors tampon de la carte et réseau)" "$(python3 -c 'import json,sys; d=json.loads(sys.argv[1]); m=sorted(d["ms"]); print("mesures", d["ms"], "ms, médiane", m[len(m)//2] if m else None, "ms")' "$lat" 2>&1)"
phase hp_after
r="$(docker exec lmt-media sh -c 'ls -d /recordings/speaker 2>&1; ls /recordings' | tr '\n' ' ')"
[[ "$r" == *"No such file"* ]]; expect HP29 "rien n'est enregistré sous speaker/ (aucun dossier dans /recordings)" "$r"
whip_pub lmt-whip3 -re -f lavfi -i "sine=frequency=440:sample_rate=48000" -t 60
phase hp_kick
docker rm -f lmt-whip3 >/dev/null 2>&1
r="$(docker inspect -f '{{.State.Running}} {{.RestartCount}} {{.State.StartedAt}}' lmt-media-capture)"
[[ "$r" == "true 0 $cap_started0" && -n "$spk_pid0" && "$(ffpids "$CAM2")" == "$spk_pid0" ]]
expect HP30 "lecteurs en erreur ou en service : la capture n'a pas redémarré, le ffmpeg de la webcam est le même" "$r · pid ${spk_pid0}→ $(ffpids "$CAM2")"

# ── 6 ter. Publication WebRTC relayée (chantier ecran) ───────────────────────
note "Chemin whip : URL du hook lue dans .env, publication WHIP décidée par le hook de l'app"
WP_URL="http://lmt-caddy/lab-media-webrtc/appc/a/whip"
wp_pub() {  # wp_pub <nom> <durée s> — publication WHIP vidéo seule (mire H.264), jeton d'appc
  docker run -d --name "$1" --network container:lmt-media --cpus 0.5 --entrypoint ffmpeg lmt-media \
    -hide_banner -loglevel warning -re -f lavfi -i "testsrc2=size=160x120:rate=10" -t "$2" \
    -c:v libx264 -preset ultrafast -tune zerolatency -profile:v baseline -pix_fmt yuv420p -g 10 -bf 0 -b:v 100k \
    -f whip -authorization "$TOKEN_C" "$WP_URL" >/dev/null
}
phase wp_start
r="$(try_publish "appc-pub:$C_PUB" appc/a)"; [[ "$r" != accepté ]]
expect WP5 "RTSP : publication sur le chemin whip refusée avec les identifiants de publication de son app" "$r"
r="$(try_publish "capture:$CAP" appc/a)"; [[ "$r" != accepté ]]
expect WP5b "RTSP : publication sur le chemin whip refusée avec les identifiants de la source capture" "$r"
phase wp_rtsp
wp_pub lmt-wp1 90
phase wp_live
r="$(BIN=ffprobe ff -hide_banner -loglevel error -rtsp_transport tcp -show_entries stream=codec_name -of csv=p=0 "rtsp://x:$TOKEN_C@lmt-media:8554/appc/a" 2>&1 | tr '\n' ' ')"
[[ "$r" == *h264* ]]; expect WP10 "lecture RTSP du chemin whip par jeton : relayée au hook d'appc, qui l'accepte (H.264)" "$r"
wp_pub lmt-wp2 8
n=0; while [[ $n -lt 15 ]] && ! docker logs lmt-media 2>&1 | grep -q 'already publishing to path .appc/a'; do sleep 1; n=$((n + 1)); done
r="$(docker logs lmt-media 2>&1 | grep 'already publishing to path .appc/a' | tail -1 | sed 's/^.*\] //')"
[[ -n "$r" ]]; expect WP12 "second publieur WHIP sur le chemin whip occupé : MediaMTX le refuse (overridePublisher: no)" "$r"
phase wp_second
phase wp_kick
docker rm -f lmt-wp1 lmt-wp2 >/dev/null 2>&1
r="$(docker exec lmt-media sh -c 'ls -d /recordings/appc 2>&1' | tr '\n' ' ')"
[[ "$r" == *"No such file"* ]]; expect WP14 "rien n'est enregistré sous appc/ (aucun dossier dans /recordings)" "$r"
r="$(docker exec lmt-media-auth cat /config/mediamtx.yml | grep -A3 '^  "appc/a":' | tr '\n' ' ')"
[[ "$r" == *"record: no"*"overridePublisher: no"* ]]; expect WP15 "mediamtx.yml : appc/a en publisher, record: no, overridePublisher: no" "$r"

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
[[ -n "$pid2" && "$(ffpids "$CAM2")" == "$pid2" ]]
expect X8 "lab-media-auth arrêté : la capture des webcams continue (plan sur disque, même ffmpeg)" "pid ${pid2}→ $(ffpids "$CAM2")"
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
phase m_persist
[[ -n "$pid2" && "$(ffpids "$CAM2")" == "$pid2" ]]
expect G4 "lab-media-auth recréé : le plan relu ne relance pas la capture (même ffmpeg)" "pid ${pid2}→ $(ffpids "$CAM2")"
r="$(docker logs lmt-media 2>&1 | grep -c -i 'reloading configuration')"
[[ "$r" -ge 1 && "$(docker inspect -f '{{.State.StartedAt}}' lmt-media)" == "$started0" ]]
expect G3 "lab-media-auth recréé par compose : MediaMTX a rechargé sa configuration sans redémarrer" "$r rechargement(s) dans son journal"

# ── 8. Enregistrements : forme et rétention ──────────────────────────────────
note "Enregistrements : arborescence, noms, rétention"
tree="$(docker exec lmt-media sh -c 'cd /recordings && find . -type f | sort')"
bad="$(sed 's#.*/##' <<<"$tree" | grep -v -c -E "$NAME_RE" || true)"
dirs="$(sed 's#/[^/]*$##' <<<"$tree" | sort -u | tr '\n' ' ')"
[[ "$bad" == 0 && "$dirs" == *"./appa/cam"* && "$dirs" == *"./webcam/av"* && "$dirs" == *"./webcam/$CAM2/av"* ]]
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
for s in "$A_CTL" "$B_CTL" "$C_CTL" "$A_PUB" "$B_PUB" "$C_PUB" "$CAP" "$TOKEN_A" "$TOKEN_B" "$TOKEN_C" "$KEY_A" "$KEY_B" "$KEY_C" "$HOOK" "lmt-appc"; do
  grep -q -F -- "$s" <<<"$logs" && leak=$((leak + 1))
done
[[ "$leak" == 0 && "$(grep -c '"event":"hook"' <<<"$logs")" -gt 10 ]]
expect J1 "journal de lab-media-auth : décisions présentes, aucun mot de passe, jeton ni clé" "$(grep -c '"event"' <<<"$logs") lignes, $leak secret(s) trouvé(s)"
mleak=0
mlogs="$(docker logs lmt-media 2>&1)"
for s in "$A_CTL" "$B_CTL" "$C_CTL" "$A_PUB" "$B_PUB" "$C_PUB" "$CAP" "$TOKEN_A" "$TOKEN_B" "$TOKEN_C" "$KEY_A" "$KEY_B" "$KEY_C"; do
  grep -q -F -- "$s" <<<"$mlogs" && mleak=$((mleak + 1))
done
hookleak="$(grep -c -F -- "$HOOK" <<<"$mlogs" || true)"
# ffmpeg cite l'URL de publication (donc le mot de passe) dans ses erreurs : on en provoque une.
hw plug 9-20 --pid 0020 --product "Erreur"
r="$(docker run --rm --name lmt-capture-err --network none -v lmt-fakesys:/fakesys:ro -v lmt-fakedev:/hostdev:ro -e SYSFS_ROOT=/fakesys \
      -e MEDIA_CAPTURE_MODE=testsrc -e MEDIA_CAPTURE_RTSP_HOST=nulle-part -e MEDIA_CAPTURE_RUN=/tmp \
      -e LAB_MEDIA_SOURCE_CAPTURE_PUBLISH_USER=capture -e LAB_MEDIA_SOURCE_CAPTURE_PUBLISH_PASSWORD="$CAP" \
      --entrypoint timeout lmt-capture 8 sh /opt/lab-media/capture-one.sh usb-1b3f-0020-p9-20 9-20 0 webcam/usb-1b3f-0020-p9-20 2>&1)"
hw unplug 9-20
! grep -q -F -- "$CAP" <<<"$r" && grep -q -F 'capture:***@nulle-part' <<<"$r"
expect J4 "erreur de publication provoquée : ffmpeg cite l'URL, le mot de passe y est masqué" "$(grep -m1 -o "Slave '[^']*'" <<<"$r" | cut -c1-110)"
clogs="$(docker logs lmt-media-capture 2>&1)"
cleak=0
for s in "$CAP" "$A_CTL" "$TOKEN_A" "$HOOK"; do grep -q -F -- "$s" <<<"$clogs" && cleak=$((cleak + 1)); done
[[ "$cleak" == 0 && -n "$clogs" ]]
expect J3 "journal de la capture : jamais le mot de passe de publication (masqué dans les messages de ffmpeg)" "$(wc -l <<<"$clogs") lignes, $cleak secret(s) trouvé(s)"
[[ "$mleak" == 0 ]]
expect J2 "journal de MediaMTX : aucun identifiant d'app ni jeton" "$mleak secret(s) d'app ; LAB_MEDIA_HOOK_KEY y apparaît $hookleak fois (limite connue, voir README)"

note "Haut-parleurs : capture arrêtée"
docker stop -t 5 lmt-media-capture >/dev/null
phase hp_offline

echo
if [[ $FAILS -eq 0 ]]; then
  printf '\033[0;32m%d contrôles, tous PASS\033[0m\n' "$TOTAL"
else
  printf '\033[0;31m%d contrôle(s) FAIL sur %d\033[0m\n' "$FAILS" "$TOTAL"
fi
$KEEP && echo "Pile laissée en place : bash lab-media/verify.sh --clean pour la supprimer."
[[ $FAILS -eq 0 ]]
