#!/usr/bin/env bash
# clean.sh — Remet le projet à zéro
#   1. Arrête toutes les stacks et supprime les volumes Docker
#   2. Supprime les images Docker construites localement
#   3. Vide le cache de build Docker
#   4. Supprime les artefacts de build applicatifs (Maven, Angular)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ── 1. Arrêt des stacks + suppression des volumes ─────────────────────────────
echo "=== 1/4  Arrêt des stacks Docker et suppression des volumes ==="

# Ordre inverse de démarrage pour respecter les dépendances
COMPOSE_DIRS=()
while IFS= read -r compose; do
  dir="$(dirname "$compose")"
  COMPOSE_DIRS+=("$dir")
done < <(find "$SCRIPT_DIR" -mindepth 2 -maxdepth 2 -name "docker-compose.yml" ! -path "*/_templates/*" | sort -r)

for dir in "${COMPOSE_DIRS[@]}"; do
  compose="$dir/docker-compose.yml"
  [[ -f "$compose" ]] || continue
  name="$(basename "$dir")"
  echo "■ $name — down --volumes ..."
  docker compose -f "$compose" down --volumes --remove-orphans 2>&1 | sed 's/^/  /' || true
done
echo ""

# ── 2. Suppression des images construites localement ──────────────────────────
echo "=== 2/4  Suppression des images buildées localement ==="
LOCAL_IMAGES=(
  "front-cadriciel-front-cadriciel"
  "spring-app-spring-app"
)
for img in "${LOCAL_IMAGES[@]}"; do
  if docker image inspect "$img" &>/dev/null; then
    echo "■ Suppression de l'image : $img"
    docker rmi "$img" 2>&1 | sed 's/^/  /' || true
  else
    echo "■ Image absente (déjà supprimée) : $img"
  fi
done
echo ""

# ── 3. Cache de build Docker ───────────────────────────────────────────────────
echo "=== 3/4  Nettoyage du cache de build Docker ==="
docker builder prune -f 2>&1 | sed 's/^/  /'
echo ""

# ── 4. Artefacts de build applicatifs ─────────────────────────────────────────
echo "=== 4/4  Suppression des artefacts de build applicatifs ==="

# Maven — spring-app
MAVEN_TARGET="$SCRIPT_DIR/spring-app/target"
if [[ -d "$MAVEN_TARGET" ]]; then
  echo "■ Maven : suppression de spring-app/target/"
  rm -rf "$MAVEN_TARGET"
else
  echo "■ Maven : spring-app/target/ déjà absent"
fi

# Angular — dist/ et cache .angular/
ANGULAR_DIST="$SCRIPT_DIR/front-cadriciel/dist"
ANGULAR_CACHE="$SCRIPT_DIR/front-cadriciel/.angular"
if [[ -d "$ANGULAR_DIST" ]]; then
  echo "■ Angular : suppression de front-cadriciel/dist/"
  rm -rf "$ANGULAR_DIST"
else
  echo "■ Angular : front-cadriciel/dist/ déjà absent"
fi
if [[ -d "$ANGULAR_CACHE" ]]; then
  echo "■ Angular : suppression de front-cadriciel/.angular/ (cache)"
  rm -rf "$ANGULAR_CACHE"
else
  echo "■ Angular : front-cadriciel/.angular/ déjà absent"
fi

echo ""
echo "══════════════════════════════════════════════════════════════"
echo "  Nettoyage terminé."
echo "  Relancer le projet : bash recompose_docker.sh --force"
echo "══════════════════════════════════════════════════════════════"
