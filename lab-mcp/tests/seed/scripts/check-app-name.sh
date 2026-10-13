#!/usr/bin/env bash
# DOUBLE DE TEST de scripts/check-app-name.sh (tests/seed/) : « lora » est refusé, tout le reste passe.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
echo "check-app-name.sh $*" >> "$ROOT/.trace/calls.log"
if [[ "${1:-}" == lora ]]; then echo "règle 4 : « lora » est le préfixe d'une app existante"; exit 1; fi
exit 0
