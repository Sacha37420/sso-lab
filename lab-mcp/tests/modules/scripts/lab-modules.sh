#!/usr/bin/env bash
# ENREGISTREUR (tests/modules/) : note l'appel puis exécute le VRAI scripts/lab-modules.sh, copié à côté
# sous le nom lab-modules.real.sh. Les arguments seulement : stdin (réglages) n'est jamais relevé.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
echo "lab-modules.sh $*" >> "$ROOT/.trace/calls.log"
exec bash "$ROOT/scripts/lab-modules.real.sh" "$@"
