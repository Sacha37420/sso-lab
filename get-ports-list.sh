#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# get-ports-list.sh — génère ports.env à la racine de dev/
#
# Parcourt tous les .env des sous-services et extrait les variables PORT_* et
# HPORT_*, puis les regroupe par service dans dev/ports.env.
#
# Usage : bash get-ports-list.sh
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT="$SCRIPT_DIR/ports.env"

{
  printf '# ══════════════════════════════════════════════════════════════════════\n'
  printf '# ports.env — généré automatiquement par get_ports_list.sh\n'
  printf '# %s\n' "$(date '+%Y-%m-%d %H:%M')"
  printf '# ══════════════════════════════════════════════════════════════════════\n'
  printf '#\n'
  printf '# PORT_*  → port exposé sur l'\''hôte\n'
  printf '# HPORT_* → port interne uniquement (non exposé sur l'\''hôte)\n'
  printf '# ══════════════════════════════════════════════════════════════════════\n'

  # Parcourt les .env dans les sous-dossiers directs de dev/ (profondeur 2)
  while IFS= read -r -d '' env_file; do
    # Exclure le ports.env lui-même et le .env racine de dev/
    [[ "$env_file" == "$OUTPUT" ]]            && continue
    [[ "$env_file" == "$SCRIPT_DIR/.env" ]]   && continue

    service_name="$(basename "$(dirname "$env_file")")"

    # Extraire les lignes PORT_* et HPORT_* (avec leurs éventuels commentaires inline)
    ports="$(grep -E '^H?PORT_[A-Z_]+=' "$env_file" 2>/dev/null || true)"
    [[ -z "$ports" ]] && continue

    printf '\n# ── %s\n' "$service_name"
    printf '%s\n' "$ports"

  done < <(find "$SCRIPT_DIR" -mindepth 2 -maxdepth 2 -name ".env" -print0 \
             | sort -z)

} > "$OUTPUT"

echo "→ $OUTPUT généré."
