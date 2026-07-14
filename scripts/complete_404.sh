#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# complete_404.sh — remplit le tableau des applications de la page 404 du lab
#
# Source des données :
#   .app-descriptions            nom affiché + description (et sélection des
#                                apps à publier : seules celles listées sortent)
#   <app>/docker-compose.yml     lien vers le front, déduit du label
#                                caddy.handle_path (source de vérité du routage)
#
# Le tableau est réinjecté entre les marqueurs APPS:START / APPS:END de
# sso-lab/fallback/html/404.html. Le reste de la page (design) reste éditable à
# la main.
#
# La page est servie par le container `fallback`, qui reçoit tout ce qu'aucun
# préfixe d'app ne matche. Le fichier étant bind-monté, la mise à jour est
# immédiate : aucun redémarrage de container n'est nécessaire.
#
# Usage : bash complete_404.sh [--dry-run]
#           --dry-run   affiche le tableau généré sans modifier la page
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DESCRIPTIONS="$SCRIPT_DIR/.app-descriptions"
TARGET="$SCRIPT_DIR/sso-lab/fallback/html/404.html"
MARK_START='<!-- APPS:START'
MARK_END='<!-- APPS:END -->'

DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

[[ -f "$DESCRIPTIONS" ]] || { echo "✗ Introuvable : $DESCRIPTIONS" >&2; exit 1; }
[[ -f "$TARGET" ]]       || { echo "✗ Introuvable : $TARGET" >&2; exit 1; }
grep -q "$MARK_START" "$TARGET" && grep -q "$MARK_END" "$TARGET" \
  || { echo "✗ Marqueurs APPS:START / APPS:END absents de $TARGET" >&2; exit 1; }

# Échappe les caractères qui casseraient le HTML (& en premier, sinon il
# ré-échapperait les entités produites par les substitutions suivantes).
escape_html() {
  printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g'
}

# Préfixe front d'une app = son label caddy.handle_path qui ne finit pas par
# -api (celui-là route le backend). Une app qui n'en a pas n'est pas publiable.
front_prefix() {
  local app="$1" compose="$SCRIPT_DIR/$1/docker-compose.yml"
  [[ -f "$compose" ]] || return 1
  grep -o 'caddy\.handle_path: "/[^"]*"' "$compose" \
    | sed 's|.*"\(/[^"]*\)/\*"|\1/|' \
    | grep -v -- '-api/$' \
    | head -1
}

rows=""
listed_apps=""
count=0

while IFS='|' read -r app name desc link; do
  # Ignore les commentaires et les lignes vides
  app="${app#"${app%%[![:space:]]*}"}"        # trim gauche
  [[ -z "$app" || "$app" == \#* ]] && continue

  if [[ -z "${name:-}" || -z "${desc:-}" ]]; then
    echo "⚠ Ligne ignorée (nom ou description manquant) : $app" >&2
    continue
  fi

  if [[ -z "${link:-}" ]]; then
    if ! link="$(front_prefix "$app")" || [[ -z "$link" ]]; then
      echo "⚠ $app : aucun label caddy.handle_path front trouvé — précisez le lien en 4e champ" >&2
      continue
    fi
  fi

  listed_apps+="$app "
  count=$((count + 1))
  rows+="          <tr>
            <td><strong>$(escape_html "$name")</strong></td>
            <td class=\"desc\">$(escape_html "$desc")</td>
            <td class=\"link\"><a href=\"$(escape_html "$link")\">$(escape_html "$link")</a></td>
          </tr>
"
done < "$DESCRIPTIONS"

if [[ "$count" -eq 0 ]]; then
  echo "✗ Aucune application exploitable dans $DESCRIPTIONS" >&2
  exit 1
fi

# Signale les apps qui exposent un front mais n'apparaissent pas sur la page :
# un oubli dans .app-descriptions les rendrait invisibles en silence.
for compose in "$SCRIPT_DIR"/*/docker-compose.yml; do
  app="$(basename "$(dirname "$compose")")"
  [[ "$app" == "sso-lab" || "$app" == "infra" ]] && continue
  [[ " $listed_apps " == *" $app "* ]] && continue
  front_prefix "$app" >/dev/null 2>&1 && [[ -n "$(front_prefix "$app")" ]] \
    && echo "ℹ $app expose un front mais n'est pas listé dans .app-descriptions" >&2
done

if [[ "$DRY_RUN" -eq 1 ]]; then
  printf '%s' "$rows"
  echo "→ $count application(s), page non modifiée (--dry-run)" >&2
  exit 0
fi

# Réécrit la zone entre les marqueurs.
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

awk -v rows="$rows" -v start="$MARK_START" -v end="$MARK_END" '
  index($0, start) { print; printf "%s", rows; skip = 1; next }
  index($0, end)   { skip = 0 }
  !skip            { print }
' "$TARGET" > "$tmp"

cat "$tmp" > "$TARGET"

echo "✓ $TARGET mis à jour — $count application(s)"
