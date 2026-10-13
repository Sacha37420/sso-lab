#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# tests/preview/run.sh — adresse d'essai d'un développeur (chantier « essai-dev », I2).
#
#   bash lab-mcp/tests/preview/run.sh         tests/test_preview.py (≈ 1 min 30)
#
# NE TOUCHE À RIEN DU LAB : ni `lab-mcp` en service, ni un projet, ni `.owners`/`.ports`/`.devs`, ni
# Keycloak, ni une base, ni un essai réel. Ne construit aucune image : le moteur d'essai est l'image
# du moteur déjà présente (LAB_MCP_IMAGE, défaut « lab-mcp-lab-mcp:latest ») avec labmcp/ et tests/
# du DOSSIER DE TRAVAIL montés par-dessus, en lecture seule. Conteneur jetable `zz-preview-mcp`,
# `--network none`, sans socket Docker, sans port publié, sans label `caddy`. Du dépôt, seul
# `scripts/` est monté, en lecture seule (pour le VRAI lab-lock.sh) : la racine du lab vue par le
# moteur d'essai est un dossier factice créé DANS le conteneur, et `scripts/app-preview.sh` y est un
# DOUBLE (tests/preview/scripts/) qui rend l'interface I1 du contrat sans rien construire.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MCP="$(cd "$HERE/../.." && pwd)"
DEV="$(cd "$MCP/.." && pwd)"
ENGINE_IMAGE="${LAB_MCP_IMAGE:-lab-mcp-lab-mcp:latest}"
P="zz-preview-mcp"

docker image inspect "$ENGINE_IMAGE" > /dev/null 2>&1 || { echo "image absente : $ENGINE_IMAGE (cet essai n'en construit aucune)" >&2; exit 2; }
trap 'docker rm -f "$P" > /dev/null 2>&1' EXIT
echo "════ Adresse d'essai — tests/test_preview.py ════"
docker run --rm --name "$P" --network none --cap-drop ALL --security-opt no-new-privileges \
  --user "$(id -u):$(id -g)" -e HOME=/tmp \
  -v "$MCP/labmcp:/app/labmcp:ro" -v "$MCP/tests:/tests:ro" -v "$DEV/scripts:/lab-scripts:ro" \
  "$ENGINE_IMAGE" python -u /tests/test_preview.py "$@"
