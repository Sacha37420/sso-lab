#!/usr/bin/env bash
# clean2.sh — Nettoyage ciblé ou global du projet
# Usage :
#   bash clean2.sh           ← tout nettoyer (comme clean.sh)
#   bash clean2.sh mon-app   ← ne nettoyer que mon-app
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
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
  # Global : infra ET sso-lab sont protégées — on les arrête sans --volumes.
  #   - infra   : ses volumes contiennent la base PostgreSQL partagée par les apps.
  #   - sso-lab : ses volumes contiennent le realm Keycloak (clients, fédération)
  #               et l'annuaire LDAP — coûteux à reconstruire.
  # Pour wiper sso-lab volontairement : clean2.sh sso-lab (branche ciblée ci-dessus).
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
# Ignoré si tous les Dockerfiles marqués "lourds" (.heavy-build, cf.
# atelier-3d/backend/) dans le périmètre nettoyé sont inchangés depuis leur
# dernier build réussi (.heavy-build.sha256, écrit par recompose_docker.sh) —
# évite de redéclencher une compilation de plusieurs dizaines de minutes
# (COLMAP/OpenMVS, FreeCAD) à chaque nettoyage alors que rien n'a changé. Un
# seul Dockerfile marqué modifié (ou jamais buildé avec succès) suffit à
# redéclencher le nettoyage normalement — et une app sans aucun marqueur
# `.heavy-build` dans le périmètre a toujours son cache nettoyé comme avant.
echo "=== 3/4  Nettoyage du cache de build Docker ==="
_PRUNE_SEARCH_ROOT="$SCRIPT_DIR"
[[ -n "$APP_NAME" ]] && _PRUNE_SEARCH_ROOT="$SCRIPT_DIR/$APP_NAME"
_HEAVY_FOUND=false
_HEAVY_CHANGED=false
while IFS= read -r _marker; do
  _HEAVY_FOUND=true
  _mdir="$(dirname "$_marker")"
  _dockerfile="$_mdir/Dockerfile"
  if [[ ! -f "$_dockerfile" ]]; then
    _HEAVY_CHANGED=true
    continue
  fi
  _current_hash="$(sha256sum "$_dockerfile" | cut -d' ' -f1)"
  _stored_hash="$(cat "$_mdir/.heavy-build.sha256" 2>/dev/null || true)"
  [[ "$_current_hash" != "$_stored_hash" ]] && _HEAVY_CHANGED=true
done < <(find "$_PRUNE_SEARCH_ROOT" -maxdepth 4 -name ".heavy-build" 2>/dev/null)

if $_HEAVY_FOUND && ! $_HEAVY_CHANGED; then
  echo "■ Dockerfile(s) lourd(s) inchangé(s) depuis le dernier build réussi — nettoyage du cache ignoré."
else
  docker builder prune -f 2>&1 | sed 's/^/  /'
fi
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
fi

if [[ -z "$APP_NAME" ]]; then
  echo "=== Nettoyage des conteneurs et images orphelins ==="
  # Liste tous les conteneurs dont le dossier n'existe plus
  docker ps -a --format '{{.ID}} {{.Names}}' | while read -r id name; do
    # Ignore tout conteneur qui n'appartient PAS à cet arbre (ex. un second
    # cadriciel sibling comme dev2/, sur le même démon Docker) : sans ce filtre,
    # `docker ps -a` étant global, un conteneur dont le nom ne matche aucun
    # dossier d'app ICI (parce qu'il appartient à l'AUTRE arbre) serait traité
    # comme orphelin et détruit — vécu en incident réel (setup2.sh d'un second
    # cadriciel vide a supprimé tous les conteneurs de celui-ci). Comparaison
    # sur le working_dir du projet Compose, jamais sur le nom du conteneur.
    wd="$(docker inspect "$id" --format '{{ index .Config.Labels "com.docker.compose.project.working_dir" }}' 2>/dev/null || true)"

    # Conteneur qui n'a pas été créé par docker compose : ce script gère des
    # projets Compose de CET arbre, rien d'autre. Sans étiquette, impossible de
    # savoir à qui il appartient — on n'y touche pas.
    [[ -n "$wd" ]] || continue

    # Hors de cet arbre (ex. dev2/) : pas notre affaire.
    if [[ "$wd" != "$SCRIPT_DIR" && "$wd" != "$SCRIPT_DIR"/* ]]; then
      continue
    fi

    # Dossier d'origine du projet, déduit du working_dir Compose — et NON du nom
    # du conteneur. L'ancienne heuristique prenait le préfixe avant le premier
    # tiret (`${name%%-*}`), donc « robot-lab-backend » → « robot » : aucun
    # dossier de ce nom, le conteneur était déclaré orphelin et détruit. Vérifié
    # à blanc : 41 des 45 conteneurs du lab y passaient, dont dev-postgres,
    # caddy, keycloak et lab-runner — toute app dont le dossier contient un
    # tiret. L'étiquette Compose, elle, donne le dossier exact.
    rel="${wd#"$SCRIPT_DIR"/}"
    base="${rel%%/*}"

    if [[ -n "$base" && ! -d "$SCRIPT_DIR/$base" ]]; then
      echo "■ Suppression conteneur orphelin : $name ($id) — dossier $base/ absent"
      docker rm -f "$id" 2>&1 | sed 's/^/  /' || true
    fi
  done
  # Supprime toutes les images qui ne sont plus utilisées par un conteneur
  docker image prune -a -f 2>&1 | sed 's/^/  /'
  echo ""
fi

echo "══════════════════════════════════════════════════════════════"
