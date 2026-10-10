#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# app-logs.sh — journaux des conteneurs d'une app.
# Contrat « multi-dev » v2, interface I4.
#
# Usage : bash scripts/app-logs.sh <app> [service] [--tail N]
#
#   service : nom du service Compose (backend, frontend…) ; absent = tous.
#   --tail  : nombre de lignes PAR CONTENEUR, 1 à 2000 (défaut 200). Une valeur
#             au-delà de 2000 est refusée, pas tronquée en silence.
#
# Sortie : texte, chaque ligne préfixée « <service> | » ; stdout et stderr des
# conteneurs sont fusionnés sur stdout. Lecture seule, ne prend pas le verrou.
#
# Les conteneurs sont retrouvés par ÉTIQUETTE de projet Compose : on ne lit que
# ceux de CETTE app, et ça marche même si docker-compose.yml est cassé.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/registry.sh
source "$SCRIPT_DIR/lib/registry.sh"

usage() { echo "Usage : bash scripts/app-logs.sh <app> [service] [--tail N]" >&2; exit 2; }

APP=""; SERVICE=""; TAIL=200
while [[ $# -gt 0 ]]; do
  case "$1" in
    --tail)   [[ $# -gt 1 ]] || usage; TAIL="$2"; shift ;;
    --tail=*) TAIL="${1#*=}" ;;
    -*)       usage ;;
    *)        if [[ -z "$APP" ]]; then APP="$1"; elif [[ -z "$SERVICE" ]]; then SERVICE="$1"; else usage; fi ;;
  esac
  shift
done
[[ -n "$APP" ]] || usage
[[ "$TAIL" =~ ^[0-9]{1,4}$ ]] && (( TAIL >= 1 && TAIL <= 2000 )) \
  || { echo "✗ --tail : entier de 1 à 2000 attendu (reçu : '$TAIL')" >&2; exit 2; }
[[ -z "$SERVICE" || "$SERVICE" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,62}$ ]] \
  || { echo "✗ nom de service invalide : '$SERVICE'" >&2; exit 2; }

APP_DIR="$(registry_app_dir "$APP")" || { echo "✗ nom d'app invalide : '$APP'" >&2; exit 1; }
[[ -f "$APP_DIR/docker-compose.yml" ]] || { echo "✗ app inconnue : '$APP'" >&2; exit 1; }

FILTERS=(--filter "label=com.docker.compose.project=${APP}")
[[ -n "$SERVICE" ]] && FILTERS+=(--filter "label=com.docker.compose.service=${SERVICE}")

FOUND=0
while IFS=$'\t' read -r _id _svc; do
  [[ -n "$_id" ]] || continue
  FOUND=$((FOUND + 1))
  docker logs --tail "$TAIL" "$_id" 2>&1 | sed "s/^/${_svc} | /"
done < <(docker ps -a "${FILTERS[@]}" --format '{{.ID}}\t{{.Label "com.docker.compose.service"}}' 2>/dev/null | sort -k2)

if [[ $FOUND -eq 0 ]]; then
  if [[ -n "$SERVICE" ]]; then echo "✗ aucun conteneur pour le service '$SERVICE' de '$APP' (non déployé ?)" >&2
  else echo "✗ aucun conteneur pour '$APP' (non déployée ?)" >&2; fi
  exit 1
fi
