#!/usr/bin/env bash
# recompose_docker.sh — Gère le cycle de vie des stacks docker-compose
#
# Usage :
#   bash recompose_docker.sh [--app <nom>] [--force]
#
#   --app <nom>   Cible une stack spécifique (nom = nom du sous-dossier)
#   --force / -f  Arrête la stack avant de la relancer
#
# Comportement :
#   Sans --app, sans --force  → démarre uniquement les stacks inactives
#   Sans --app, avec --force  → arrête puis redémarre toutes les stacks
#   Avec --app, sans --force  → démarre la stack si elle est inactive
#   Avec --app, avec --force  → arrête puis redémarre la stack ciblée
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# ── Parsing des arguments ──────────────────────────────────────────────────────
APP_NAME=""
FORCE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app)       APP_NAME="${2:?--app requiert un nom de stack}"; shift 2 ;;
    --force|-f)  FORCE=true; shift ;;
    *) echo "Option inconnue : $1" >&2
       echo "Usage : bash recompose_docker.sh [--app <nom>] [--force]" >&2
       exit 1 ;;
  esac
done

# ── Ordre de démarrage canonique ───────────────────────────────────────────────
# sso-lab en premier (crée sso-lab_sso-net utilisé par infra),
# infra en second, puis tous les autres dossiers découverts dynamiquement
ORDERED_DIRS=("$SCRIPT_DIR/sso-lab" "$SCRIPT_DIR/infra")
while IFS= read -r compose; do
  dir="$(dirname "$compose")"
  [[ "$dir" == "$SCRIPT_DIR/sso-lab" || "$dir" == "$SCRIPT_DIR/infra" ]] && continue
  ORDERED_DIRS+=("$dir")
done < <(find "$SCRIPT_DIR" -mindepth 2 -maxdepth 2 -name "docker-compose.yml" ! -path "*/_templates/*" | sort)

# ── Fonctions utilitaires ──────────────────────────────────────────────────────

# Retourne le dossier d'une stack par son nom, exit 1 si introuvable
find_dir() {
  local name="$1"
  for dir in "${ORDERED_DIRS[@]}"; do
    [[ "$(basename "$dir")" == "$name" ]] && echo "$dir" && return 0
  done
  return 1
}

# Vrai si la stack a au moins un conteneur démarré
is_active() {
  local dir="$1"
  docker compose -f "$dir/docker-compose.yml" ps -q 2>/dev/null | grep -q .
}

# Retourne un label si la stack contient du code à construire (cherche dans les sous-dossiers)
build_label() {
  local dir="$1"
  local parts=()
  find "$dir" -maxdepth 2 -name "angular.json"                                       -print -quit 2>/dev/null | grep -q . && parts+=("Angular")
  find "$dir" -maxdepth 2 \( -name "manage.py" -o -name "requirements.txt" \)        -print -quit 2>/dev/null | grep -q . && parts+=("Django")
  [[ ${#parts[@]} -gt 0 ]] && printf " (%s → --build)" "$(IFS=+; echo "${parts[*]}")"
}

# Lance la stack (ajoute --build si Angular ou Django détecté dans les sous-dossiers)
compose_up() {
  local dir="$1"
  local build_flag=""
  [[ -n "$(build_label "$dir")" ]] && build_flag="--build"
  docker compose -f "$dir/docker-compose.yml" up -d $build_flag 2>&1 | sed 's/^/  /'
}

# Arrête la stack
compose_down() {
  local dir="$1"
  docker compose -f "$dir/docker-compose.yml" down 2>&1 | sed 's/^/  /' || true
}

# Traite une stack unique selon le flag --force
process_stack() {
  local dir="$1"
  local name
  name="$(basename "$dir")"
  [[ -f "$dir/docker-compose.yml" ]] || return 0

  local label
  label="$(build_label "$dir")"

  if [[ "$FORCE" == true ]]; then
    echo "■ $name — arrêt..."
    compose_down "$dir"
    echo "▶ $name — démarrage${label}..."
    compose_up "$dir"
    echo ""
  else
    if is_active "$dir"; then
      echo "✓ $name — déjà actif"
    else
      echo "▶ $name — démarrage${label}..."
      compose_up "$dir"
      echo ""
    fi
  fi
}

# ── Point d'entrée ─────────────────────────────────────────────────────────────
if [[ -n "$APP_NAME" ]]; then

  # ─ Mode mono-stack ────────────────────────────────────────────────────────
  APP_DIR="$(find_dir "$APP_NAME")" || {
    echo "Erreur : aucune stack trouvée pour '$APP_NAME'" >&2
    available="$(for d in "${ORDERED_DIRS[@]}"; do [[ -f "$d/docker-compose.yml" ]] && echo -n "$(basename "$d") "; done)"
    echo "Stacks disponibles : $available" >&2
    exit 1
  }
  process_stack "$APP_DIR"

else

  # ─ Mode toutes stacks ─────────────────────────────────────────────────────
  if [[ "$FORCE" == true ]]; then

    echo "=== Arrêt de toutes les stacks (ordre inverse) ==="
    for (( i=${#ORDERED_DIRS[@]}-1; i>=0; i-- )); do
      dir="${ORDERED_DIRS[$i]}"
      [[ -f "$dir/docker-compose.yml" ]] || continue
      echo "■ $(basename "$dir") — arrêt..."
      compose_down "$dir"
    done
    echo ""

    echo "=== Démarrage de toutes les stacks ==="
    for dir in "${ORDERED_DIRS[@]}"; do
      [[ -f "$dir/docker-compose.yml" ]] || continue
      local_label="$(build_label "$dir")"
      echo "▶ $(basename "$dir") — démarrage${local_label}..."
      compose_up "$dir"
      echo ""
    done

  else

    echo "=== Démarrage des stacks inactives ==="
    started=0
    for dir in "${ORDERED_DIRS[@]}"; do
      [[ -f "$dir/docker-compose.yml" ]] || continue
      name="$(basename "$dir")"
      if is_active "$dir"; then
        echo "✓ $name — déjà actif"
      else
        local_label="$(build_label "$dir")"
        echo "▶ $name — démarrage${local_label}..."
        compose_up "$dir"
        started=$((started + 1))
        echo ""
      fi
    done
    echo ""
    [[ $started -gt 0 ]] && echo "$started stack(s) démarrée(s)." || echo "Tout est déjà actif."

  fi
fi
