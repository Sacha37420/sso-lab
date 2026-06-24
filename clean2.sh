#!/usr/bin/env bash
# clean2.sh — Nettoyage ciblé ou global du projet
# Usage :
#   bash clean2.sh           ← tout nettoyer (comme clean.sh)
#   bash clean2.sh mon-app   ← ne nettoyer que mon-app
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="${1:-}"

# ── 1. Arrêt des stacks Docker et suppression des volumes ──────────────
echo "=== 1/4  Arrêt des stacks Docker et suppression des volumes ==="
if [[ -n "$APP_NAME" ]]; then
  DIR="$SCRIPT_DIR/$APP_NAME"
  if [[ -f "$DIR/docker-compose.yml" ]]; then
    echo "■ $APP_NAME — down --volumes ..."
    docker compose -f "$DIR/docker-compose.yml" down --volumes --remove-orphans 2>&1 | sed 's/^/  /' || true
  else
    echo "■ Pas de docker-compose.yml pour $APP_NAME"
  fi
else
  # Global : infra est protégée — ses volumes contiennent la base PostgreSQL
  # partagée par toutes les apps. On l'arrête sans --volumes.
  COMPOSE_DIRS=()
  while IFS= read -r compose; do
    dir="$(dirname "$compose")"
    COMPOSE_DIRS+=("$dir")
  done < <(find "$SCRIPT_DIR" -mindepth 2 -maxdepth 2 -name "docker-compose.yml" ! -path "*/_templates/*" | sort -r)
  for dir in "${COMPOSE_DIRS[@]}"; do
    compose="$dir/docker-compose.yml"
    [[ -f "$compose" ]] || continue
    name="$(basename "$dir")"
    if [[ "$name" == "infra" || "$name" == "sso-lab" ]]; then
      echo "■ $name — down (volumes préservés — infrastructure partagée) ..."
      docker compose -f "$compose" down --remove-orphans 2>&1 | sed 's/^/  /' || true
    else
      echo "■ $name — down --volumes ..."
      docker compose -f "$compose" down --volumes --remove-orphans 2>&1 | sed 's/^/  /' || true
    fi
  done
fi
echo ""

# ── 2. Suppression des images construites localement ──────────────────
echo "=== 2/4  Suppression des images buildées localement ==="
if [[ -n "$APP_NAME" ]]; then
  IMG_NAME="${APP_NAME//-/_}"
  if docker image inspect "$IMG_NAME" &>/dev/null; then
    echo "■ Suppression de l'image : $IMG_NAME"
    docker rmi "$IMG_NAME" 2>&1 | sed 's/^/  /' || true
  else
    echo "■ Image absente (déjà supprimée) : $IMG_NAME"
  fi
else
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
fi
echo ""

# ── 3. Cache de build Docker ─────────────────────────────────────────
echo "=== 3/4  Nettoyage du cache de build Docker ==="
docker builder prune -f 2>&1 | sed 's/^/  /'
echo ""

# ── 4. Artefacts de build applicatifs ───────────────────────────────
echo "=== 4/4  Suppression des artefacts de build applicatifs ==="
if [[ -n "$APP_NAME" ]]; then
  # Maven
  MAVEN_TARGET="$SCRIPT_DIR/$APP_NAME/target"
  if [[ -d "$MAVEN_TARGET" ]]; then
    echo "■ Maven : suppression de $APP_NAME/target/"
    rm -rf "$MAVEN_TARGET"
  fi
  # Angular
  ANGULAR_DIST="$SCRIPT_DIR/$APP_NAME/dist"
  ANGULAR_CACHE="$SCRIPT_DIR/$APP_NAME/.angular"
  if [[ -d "$ANGULAR_DIST" ]]; then
    echo "■ Angular : suppression de $APP_NAME/dist/"
    rm -rf "$ANGULAR_DIST"
  fi
  if [[ -d "$ANGULAR_CACHE" ]]; then
    echo "■ Angular : suppression de $APP_NAME/.angular/ (cache)"
    rm -rf "$ANGULAR_CACHE"
  fi
else
  # Global : comme clean.sh
  MAVEN_TARGET="$SCRIPT_DIR/spring-app/target"
  if [[ -d "$MAVEN_TARGET" ]]; then
    echo "■ Maven : suppression de spring-app/target/"
    rm -rf "$MAVEN_TARGET"
  fi
  ANGULAR_DIST="$SCRIPT_DIR/front-cadriciel/dist"
  ANGULAR_CACHE="$SCRIPT_DIR/front-cadriciel/.angular"
  if [[ -d "$ANGULAR_DIST" ]]; then
    echo "■ Angular : suppression de front-cadriciel/dist/"
    rm -rf "$ANGULAR_DIST"
  fi
  if [[ -d "$ANGULAR_CACHE" ]]; then
    echo "■ Angular : suppression de front-cadriciel/.angular/ (cache)"
    rm -rf "$ANGULAR_CACHE"
  fi
fi

if [[ -z "$APP_NAME" ]]; then
  echo "=== Nettoyage des conteneurs et images orphelins ==="
  # Liste tous les conteneurs dont le dossier n'existe plus
  docker ps -a --format '{{.ID}} {{.Names}}' | while read -r id name; do
    # On suppose que le nom du conteneur commence par le nom du dossier (convention new-app.sh)
    base="${name%%-*}"
    if [[ ! -d "$SCRIPT_DIR/$base" && "$base" != "sso-lab" && "$base" != "infra" ]]; then
      echo "■ Suppression conteneur orphelin : $name ($id)"
      docker rm -f "$id" 2>&1 | sed 's/^/  /' || true
    fi
  done
  # Supprime toutes les images qui ne sont plus utilisées par un conteneur
  docker image prune -a -f 2>&1 | sed 's/^/  /'
  echo ""
fi

echo "══════════════════════════════════════════════════════════════"
