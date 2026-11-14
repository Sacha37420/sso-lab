#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# install.sh — étapes d'installation PROPRES à __APP_NAME__, jouées par le lab.
#
#   bash install.sh           fait ce qui manque (idempotent : relancé, il ne refait rien)
#   bash install.sh --check   ne modifie RIEN, dit ce qui manque (code 1 s'il manque quelque chose)
#
# Joué par le lab à chaque déploiement, AVANT le build, dans le dossier du projet, avec un
# environnement vide (seulement PATH, HOME, LANG, LAB_ROOT, LAB_MODULE, LAB_MODULE_DIR) et le
# délai `install.timeout_s` de lab-module.json. Code ≠ 0 ⇒ rien n'est construit ni arrêté.
#
# Règles (CLAUDE.md du projet, « Module ») :
#   • ce qui peut aller dans l'image Docker va dans le Dockerfile, pas ici ;
#   • jamais de sudo ni d'apt : un outil système manquant se DÉCLARE dans
#     lab-module.json (requires.system) — le lab le signale ;
#   • aucun secret écrit ici : un réglage se déclare dans lab-module.json (settings),
#     le lab le demande et l'écrit dans .env ;
#   • ne modifie aucun fichier suivi par git : n'écris que dans des dossiers ignorés.
# Équivalent Windows (poste d'un développeur, jamais joué par le lab) : install.bat.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail
CHECK=false
case "${1:-}" in
  "") ;;
  --check) CHECK=true ;;
  *) echo "usage : bash install.sh [--check]" >&2; exit 2 ;;
esac
missing=0

# ── Exemple : un dossier de données, ignoré par git ──────────────────────────
# if [[ ! -d data/cache ]]; then
#   if $CHECK; then echo "manque : data/cache"; missing=1
#   else mkdir -p data/cache; echo "créé : data/cache"; fi
# fi

[[ $missing -eq 0 ]] && echo "rien à faire"
exit "$missing"
