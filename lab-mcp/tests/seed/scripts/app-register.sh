#!/usr/bin/env bash
# DOUBLE DE TEST de scripts/app-register.sh (tests/seed/) : premier commit de TOUT le dossier (comme
# le vrai : `git add -A`), sans push ni sous-module. stdout = le SHA, dernière ligne (contrat I4).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TRACE="$ROOT/.trace"
APP="$1"
{ printf 'app-register.sh'; printf ' %q' "$@"; printf '\n'; } >> "$TRACE/calls.log"
ps -eo args > "$TRACE/ps-register-$APP.txt"
env | grep -v '^LAB_GIT_TOKEN=' > "$TRACE/env-register-$APP.txt"
cd "$ROOT/deploiement/$APP"
{
  git init -q -b main
  git add -A
  git -c "user.name=${LAB_GIT_AUTHOR_NAME:-test}" -c "user.email=${LAB_GIT_AUTHOR_EMAIL:-test@lab.test}" \
      commit -q -m "feat: initial scaffold"
} >&2
git rev-parse HEAD
