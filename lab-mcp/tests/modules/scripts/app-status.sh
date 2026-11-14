#!/usr/bin/env bash
# DOUBLE DE TEST de scripts/app-status.sh (tests/modules/) : une ligne JSON fixe.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
echo "app-status.sh $*" >> "$ROOT/.trace/calls.log"
printf '{"sha": "%s", "services": [], "at": "2026-11-14T10:00:00+01:00", "tests": {"backend": "ok", "cloisonnement": "non-lancé"}}\n' \
  "$(printf '%s' "$1" | sha1sum | cut -c1-40)"
