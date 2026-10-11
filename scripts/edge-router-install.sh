#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# edge-router-install.sh — pose le répartiteur 80/443 (~/edge-router/) s'il manque.
#
# Le Caddy de sso-lab ne publie plus 80/443 : c'est ce répartiteur, HORS dépôt
# parce que commun à tous les cadriciels de la machine, qui reçoit ces ports.
# Sur une machine neuve il n'existe pas — donc pas de HTTPS. Ce script copie le
# gabarit versionné (edge-router.example/), y inscrit le domaine du lab et démarre.
#
#   bash scripts/edge-router-install.sh            # pose et démarre s'il manque
#   bash scripts/edge-router-install.sh --check    # ne fait rien, dit ce qu'il ferait
#
# Il ne modifie JAMAIS un ~/edge-router/ existant (code 0, « présent ») : le
# toucher couperait 80/443 pour tous les cadriciels. Ajouter un second cadriciel :
# edge-router.example/README.md.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="${EDGE_ROUTER_DIR:-$HOME/edge-router}"
CHECK=false; [[ "${1:-}" == "--check" ]] && CHECK=true

if [[ -d "$DEST" ]]; then
  echo "répartiteur présent ($DEST) — non modifié"
  exit 0
fi
DOMAIN="$(sed -n 's/^DOMAIN=//p' "$ROOT/sso-lab/.env" 2>/dev/null | head -1 | tr -d '"'"'"'\r')"
if [[ -z "$DOMAIN" || "$DOMAIN" == "CHANGE_ME" ]]; then
  echo "DOMAIN n'est pas renseigné dans sso-lab/.env : pas de HTTPS à répartir, rien à poser." >&2
  exit 0
fi
[[ "$DOMAIN" =~ ^[A-Za-z0-9.-]+$ ]] || { echo "DOMAIN invalide : $DOMAIN" >&2; exit 2; }
if $CHECK; then
  echo "à faire : copier edge-router.example/ vers $DEST (domaine $DOMAIN) et démarrer le répartiteur"
  exit 0
fi
docker network inspect edge-net > /dev/null 2>&1 || docker network create edge-net > /dev/null
tmp="$(mktemp -d "${DEST}.XXXXXX")"
cp "$ROOT/edge-router.example/docker-compose.yml" "$tmp/docker-compose.yml"
sed "s/__DOMAIN__/$DOMAIN/g" "$ROOT/edge-router.example/nginx.conf" > "$tmp/nginx.conf"
chmod 700 "$tmp"
mv "$tmp" "$DEST"
docker compose -f "$DEST/docker-compose.yml" up -d
echo "répartiteur posé dans $DEST et démarré (domaine $DOMAIN)"
