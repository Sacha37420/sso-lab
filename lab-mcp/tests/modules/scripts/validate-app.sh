#!/usr/bin/env bash
# DOUBLE DE TEST de scripts/validate-app.sh (tests/modules/) : refuse si .trace/fail-validate-<app> existe.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
echo "validate-app.sh $*" >> "$ROOT/.trace/calls.log"
if [[ -f "$ROOT/.trace/fail-validate-$1" ]]; then echo "[privileged] service backend : privileged refusé (double)"; exit 1; fi
exit 0
