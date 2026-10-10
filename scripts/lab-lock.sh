#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# lab-lock.sh — exécute une commande sous le verrou de déploiement du lab.
#
# Usage :
#   bash scripts/lab-lock.sh <commande> [args…]
#
# Sert à enchaîner PLUSIEURS commandes d'exploitation sous un seul verrou
# (contrat multi-dev I4/I5 : la création d'une app enchaîne check-app-name →
# new-app → app-register « sous le verrou »). Chaque commande d'exploitation
# prend déjà le verrou seule ; lancée d'ici, elle constate qu'il est tenu par
# son ancêtre et ne le reprend pas (voir scripts/lib/lock.sh).
#
# Code de sortie : celui de la commande ; 75 si le verrou n'a pas pu être
# obtenu dans LAB_LOCK_TIMEOUT secondes (défaut 900) ; 2 sur erreur d'usage.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/registry.sh
source "$SCRIPT_DIR/lib/registry.sh"
# shellcheck source=lib/lock.sh
source "$SCRIPT_DIR/lib/lock.sh"

[[ $# -ge 1 ]] || { echo "Usage : bash scripts/lab-lock.sh <commande> [args…]" >&2; exit 2; }

lab_lock_acquire "lab-lock.sh : $1" || exit $?
# Pas de `exec` : le fd du verrou appartient à CE processus, qui doit donc
# survivre à la commande pour que le verrou tienne jusqu'au bout.
"$@"
