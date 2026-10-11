#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# storage-shares.sh — crée dans `storage` les partages de groupe attendus.
#
# Usage :
#   bash scripts/storage-shares.sh            crée ou réaligne ce qui manque
#   bash scripts/storage-shares.sh --check    lecture seule : dit ce qui manque (code 1 s'il manque quelque chose)
#
# La liste vit dans scripts/storage-shares.conf. Le propriétaire de chaque
# partage est le superutilisateur du lab (LAB_SUPERUSER).
#
# IDEMPOTENT ET SANS ÉCRITURE INUTILE : un partage déjà présent avec les bons
# groupes n'est pas touché (la commande Django, elle, réécrit toujours) — l'état
# est lu d'abord, par la commande `shell` de Django dans le conteneur de storage.
# Il faut que storage-backend tourne et que ses migrations soient passées.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/registry.sh
source "$SCRIPT_DIR/lib/registry.sh"
CONF="$SCRIPT_DIR/storage-shares.conf"
CONTAINER="${STORAGE_CONTAINER:-storage-backend}"

CHECK=false
case "${1:-}" in
  '') ;;
  --check) CHECK=true ;;
  *) echo "Usage : bash scripts/storage-shares.sh [--check]" >&2; exit 2 ;;
esac
[[ -f "$CONF" ]] || { echo "✗ $CONF introuvable" >&2; exit 1; }
OWNER="$(registry_superuser)"

if ! docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null | grep -q true; then
  echo "✗ $CONTAINER n'est pas démarré — partages non vérifiés" >&2
  exit 1
fi

# État actuel : « nom<TAB>groupes » pour chaque partage lié à un groupe.
CURRENT="$(docker exec "$CONTAINER" python manage.py shell -c "
from api.models import Share
for s in Share.objects.exclude(required_groups='').exclude(required_groups__isnull=True):
    print(s.name + '\t' + s.required_groups)" 2>/dev/null)" \
  || { echo "✗ lecture des partages impossible dans $CONTAINER (migrations passées ?)" >&2; exit 1; }

missing=0
while IFS=: read -r name groups; do
  [[ -z "$name" || "$name" == \#* ]] && continue
  if [[ ! "$name" =~ ^[a-z0-9][a-z0-9-]*$ || ! "$groups" =~ ^[A-Za-z0-9_-]+(,[A-Za-z0-9_-]+)*$ ]]; then
    echo "✗ ligne invalide dans storage-shares.conf : ${name}:${groups}" >&2; missing=$((missing + 1)); continue
  fi
  have="$(awk -F'\t' -v n="$name" '$1 == n { print $2; exit }' <<< "$CURRENT")"
  if [[ "$have" == "$groups" ]]; then
    echo "  ✔ partage ${name} : présent (${groups})"
  elif $CHECK; then
    if [[ -z "$have" ]]; then echo "  ✘ partage ${name} : absent"; else echo "  ✘ partage ${name} : groupes « ${have} », attendu « ${groups} »"; fi
    missing=$((missing + 1))
  else
    if docker exec "$CONTAINER" python manage.py create_group_share "$name" --owner "$OWNER" --required-groups "$groups" 2>&1 | sed 's/^/  /'; then
      :
    else
      echo "  ✘ partage ${name} : création en échec" >&2; missing=$((missing + 1))
    fi
  fi
done < "$CONF"
[[ $missing -eq 0 ]]
