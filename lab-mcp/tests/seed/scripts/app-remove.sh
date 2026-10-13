#!/usr/bin/env bash
# DOUBLE DE TEST de scripts/app-remove.sh (tests/seed/) : dossier et lignes de registre.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$1"
{ printf 'app-remove.sh'; printf ' %q' "$@"; printf '\n'; } >> "$ROOT/.trace/calls.log"
rm -rf "$ROOT/deploiement/$APP"
for f in .owners .ports; do
  [[ -f "$ROOT/$f" ]] && { grep -v "^$APP:" "$ROOT/$f" > "$ROOT/$f.tmp" || true; mv "$ROOT/$f.tmp" "$ROOT/$f"; }
done
echo "✓ (double) $APP retirée"
