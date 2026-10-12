#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# tests/chat/run.sh — écran de conversation d'un espace (chantier espace-chat, I2/I3).
#
#   bash lab-mcp/tests/chat/run.sh            tests du moteur seul, puis essai de la passerelle
#   bash lab-mcp/tests/chat/run.sh unit       tests du moteur seul (≈ 25 s, sans réseau)
#   bash lab-mcp/tests/chat/run.sh gateway    essai de bout en bout par la passerelle (≈ 2 min)
#
# NE TOUCHE À RIEN DU LAB EN SERVICE : ni `lab-mcp`, ni `lab-ws-gateway`, ni un espace réel, ni le
# pare-feu, ni une base. Ne construit aucune image : le moteur d'essai est l'image du moteur déjà
# présente (LAB_MCP_IMAGE, défaut « lab-mcp-lab-mcp:latest ») avec labmcp/ et tests/ du DOSSIER DE
# TRAVAIL montés par-dessus ; la passerelle est l'image Caddy du lab avec gateway/Caddyfile du
# dossier de travail ; les faux espaces sont `python:3.12-slim`.
#
# Tout est jetable et nommé `zz-chat-mcp-*`, sur un réseau `--internal` (aucune sortie), sans
# socket Docker, sans port publié, sans label `caddy` (le Caddy du lab lit les labels de tous les
# conteneurs). Tout est retiré en sortie, succès ou échec.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MCP="$(cd "$HERE/../.." && pwd)"
ENGINE_IMAGE="${LAB_MCP_IMAGE:-lab-mcp-lab-mcp:latest}"
CADDY_IMAGE="lucaslorentz/caddy-docker-proxy:ci-alpine"
FAKE_IMAGE="python:3.12-slim"
P="zz-chat-mcp"
NET="$P-net"
WHAT="${1:-all}"

for image in "$ENGINE_IMAGE" "$CADDY_IMAGE" "$FAKE_IMAGE"; do
  docker image inspect "$image" > /dev/null 2>&1 || { echo "image absente : $image (cet essai n'en construit ni n'en tire aucune)" >&2; exit 2; }
done

cleanup() {
  docker rm -f "$P-unit" "$P-engine" "$P-gw" "$P-front" "$P-ws-alice" "$P-ws-bob" "$P-ws-carol" > /dev/null 2>&1
  docker network rm "$NET" > /dev/null 2>&1
}
trap cleanup EXIT
cleanup
status=0

if [[ "$WHAT" == all || "$WHAT" == unit ]]; then
  echo "════ Tests du moteur seul (tests/test_chat.py) ════"
  docker run --rm --name "$P-unit" --network none \
    -v "$MCP/labmcp:/app/labmcp:ro" -v "$MCP/tests:/tests:ro" \
    "$ENGINE_IMAGE" python /tests/test_chat.py || status=1
fi

if [[ "$WHAT" == all || "$WHAT" == gateway ]]; then
  echo "════ Essai par la passerelle (tests/chat/driver.py) ════"
  docker network create --internal "$NET" > /dev/null || exit 2
  common=(-d --network "$NET" --cap-drop ALL --security-opt no-new-privileges --read-only)
  fake() {  # fake <uid> [variables…]
    local uid="$1"; shift
    docker run "${common[@]}" --name "$P-ws-$uid" -e "WHO=$uid" "$@" \
      -v "$HERE/fake_space.py:/fake_space.py:ro" "$FAKE_IMAGE" python -u /fake_space.py > /dev/null
  }
  fake alice                                   # éditeur + service de conversation
  fake bob -e CHAT=off                         # image sans le service : rien sur :8090
  fake carol -e CHAT=later                     # service lent à démarrer (à la commande de l'essai)
  # La passerelle : le Caddyfile LIVRÉ, tel quel ; seuls changent le nom du moteur et le préfixe des espaces.
  docker run "${common[@]}" --name "$P-gw" --tmpfs /config --tmpfs /data \
    -e "LAB_ENGINE_ADDR=$P-engine:8000" -e "LAB_WS_PREFIX=$P-ws-" \
    -v "$MCP/gateway/Caddyfile:/etc/caddy/Caddyfile:ro" \
    "$CADDY_IMAGE" run --config /etc/caddy/Caddyfile --adapter caddyfile > /dev/null
  # Tient lieu du Caddy du lab devant elle (pose X-Forwarded-Host).
  docker run "${common[@]}" --name "$P-front" --tmpfs /config --tmpfs /data -e "GATEWAY=$P-gw" \
    -v "$HERE/front.Caddyfile:/etc/caddy/Caddyfile:ro" \
    "$CADDY_IMAGE" run --config /etc/caddy/Caddyfile --adapter caddyfile > /dev/null
  docker run --rm --name "$P-engine" --network "$NET" --cap-drop ALL --security-opt no-new-privileges \
    -e "GATEWAY=$P-gw" -e "FRONT=$P-front" -e "FAKE_PREFIX=$P-ws-" \
    -v "$MCP/labmcp:/app/labmcp:ro" -v "$MCP/tests:/tests:ro" \
    "$ENGINE_IMAGE" python -u /tests/chat/driver.py || status=1
  if [[ "$status" != 0 ]]; then
    echo "──── journal de la passerelle (fin) ────"; docker logs --tail 15 "$P-gw" 2>&1
  fi
fi
exit "$status"
