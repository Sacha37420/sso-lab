#!/usr/bin/env bash
# DOUBLE DE TEST de scripts/app-sync.sh (tests/modules/) : rend un SHA de 40 caractères propre à l'app,
# ou refuse si .trace/fail-sync-<app> existe.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
echo "app-sync.sh $*" >> "$ROOT/.trace/calls.log"
if [[ -f "$ROOT/.trace/fail-sync-$1" ]]; then echo "✗ app-sync : commit absent d'origin (double)" >&2; exit 1; fi
printf '%s' "$1" | sha1sum | cut -c1-40
