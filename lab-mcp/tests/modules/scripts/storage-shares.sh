#!/usr/bin/env bash
# DOUBLE DE TEST de scripts/storage-shares.sh (tests/modules/) : échoue si .trace/fail-shares existe.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
echo "storage-shares.sh $*" >> "$ROOT/.trace/calls.log"
if [[ -f "$ROOT/.trace/fail-shares" ]]; then echo "✗ storage-backend n'est pas démarré (double)" >&2; exit 1; fi
echo "  ✔ partages présents (double)"
