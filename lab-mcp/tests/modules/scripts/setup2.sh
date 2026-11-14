#!/usr/bin/env bash
# DOUBLE DE TEST de scripts/setup2.sh (tests/modules/). Relève son environnement (.trace/env-setup2-<app>),
# attend tant que .trace/hold-<app> existe, échoue au build (.trace/fail-build-<app>) ou aux tests
# backend (.trace/fail-tests-<app>) ; sinon « démarre » l'app : une ligne de plus dans LAB_MODULES_PS.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
echo "setup2.sh $*" >> "$ROOT/.trace/calls.log"
env > "$ROOT/.trace/env-setup2-$1"
for _ in $(seq 1 600); do [[ -f "$ROOT/.trace/hold-$1" ]] || break; sleep 0.1; done
echo "  → build de $1 (double)"
if [[ -f "$ROOT/.trace/fail-build-$1" ]]; then echo "ERROR : $1 — build en échec (double)"; exit 1; fi
if [[ -f "$ROOT/.trace/fail-tests-$1" ]]; then echo "ERROR : $1 — tests backend ROUGES (double)"; exit 1; fi
[[ -n "${LAB_MODULES_PS:-}" ]] && printf '%s\trunning\n' "$1" >> "$LAB_MODULES_PS"
echo "  ✓ $1 en service (double)"
exit 0
