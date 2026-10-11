#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# workspace-image.sh — l'image des espaces de travail, lab-workspace:latest.
#
# Usage :
#   bash scripts/workspace-image.sh check     code 0 si l'image existe (lecture seule)
#   bash scripts/workspace-image.sh ensure    la construit SEULEMENT si elle manque
#   bash scripts/workspace-image.sh build     la (re)construit
#
# POURQUOI CE SCRIPT : `workspace/` n'a pas de docker-compose.yml — aucun
# déploiement ne construit son image. Le moteur (lab-mcp) ne sait que lancer
# `lab-workspace:latest` : sans elle, aucun espace de travail ne s'ouvre. Elle
# était construite à la main, sous l'étiquette `:dev`, puis ré-étiquetée.
# Le build (≈ 8 min à froid) se fait sous le verrou de déploiement : une seule
# construction lourde à la fois sur cette machine.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/registry.sh
source "$SCRIPT_DIR/lib/registry.sh"
# shellcheck source=lib/lock.sh
source "$SCRIPT_DIR/lib/lock.sh"
ROOT="$(registry_root)"
IMAGE="${LAB_WS_IMAGE:-lab-workspace:latest}"

have() { docker image inspect "$IMAGE" > /dev/null 2>&1; }

case "${1:-}" in
  check)
    have && { echo "  ✔ image $IMAGE présente"; exit 0; }
    echo "  ✘ image $IMAGE absente (bash scripts/workspace-image.sh build)"; exit 1 ;;
  ensure)
    have && { echo "  ✔ image $IMAGE déjà présente"; exit 0; } ;;
  build) ;;
  *) echo "Usage : bash scripts/workspace-image.sh check|ensure|build" >&2; exit 2 ;;
esac

[[ -f "$ROOT/workspace/Dockerfile" ]] || { echo "✗ workspace/Dockerfile introuvable — image non construite" >&2; exit 1; }
lab_lock_acquire "workspace-image.sh build" || exit $?
echo "▶ construction de $IMAGE (workspace/) — plusieurs minutes à froid"
if docker build -t "$IMAGE" "$ROOT/workspace" 2>&1 | sed 's/^/  /'; then
  echo "✓ image $IMAGE construite"
else
  echo "✗ ERROR : construction de $IMAGE en échec" >&2
  exit 1
fi
