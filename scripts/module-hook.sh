#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# module-hook.sh — joue le script d'installation d'un module (install.sh).
# Chantier « modules », contrat v1, I3.
#
# Usage :
#   bash scripts/module-hook.sh <module> [--check | --if-new]
#
# Ce qui est joué : <dossier du module>/install.sh, SEULEMENT s'il est déclaré
# par la description du module (`"install": {"script": "install.sh", …}`, voir
# modules/README.md). Un install.sh présent mais non déclaré n'est jamais joué.
#
# Appelé par setup_unit.sh avec --if-new, après les contrôles (validate-app.sh,
# portes de qualité) et AVANT tout nettoyage ou build : un échec ne coupe rien.
# --if-new (décision P1 du propriétaire, 2026-11-14) : le script n'est joué qu'à
# l'INSTALLATION — premier lancement du lab, ou module encore absent du serveur
# (aucun conteneur, démarré ou non). Une mise à jour (setup2.sh, redéploiement,
# « Réinstaller ») ne le rejoue pas. Appel direct sans option : joué.
#
# Garde-fous :
#   • app d'un DÉVELOPPEUR (propriétaire ≠ superutilisateur) : jamais joué
#     (décision P1 du 2026-11-14 : seules les apps du superutilisateur). Le
#     script tournerait avec les droits du lab — le groupe docker, donc root —
#     et APRÈS le contrôle de sûreté : il pourrait réécrire docker-compose.yml ou
#     .env une fois validés ;
#   • environnement repartant de zéro : PATH, HOME, LANG, LAB_ROOT, LAB_MODULE,
#     LAB_MODULE_DIR — rien de l'appelant (aucun jeton, aucun mot de passe) ;
#   • répertoire courant = dossier du module ; délai = install.timeout_s ;
#   • fichier régulier seulement (pas de lien symbolique).
#
# Sortie : la sortie du script, indentée. Codes : 0 = joué et réussi, ou rien
# à jouer ; 1 = échec (ou, en --check, quelque chose manque) ; 2 = usage.
# Première ligne d'état pour les lecteurs automatiques (lab-modules.sh show) :
#   LAB_HOOK_RESULT_FILE=<fichier> → y écrit « <code> » ou « skip <raison> »,
#   puis la sortie du script.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/registry.sh
source "$SCRIPT_DIR/lib/registry.sh"
ROOT="$(registry_root)"

APP="${1:-}"; MODE="${2:-}"
[[ -n "$APP" && ( -z "$MODE" || "$MODE" == "--check" || "$MODE" == "--if-new" ) && $# -le 2 ]] \
  || { echo "Usage : bash scripts/module-hook.sh <module> [--check | --if-new]" >&2; exit 2; }
DIR="$(registry_app_dir "$APP")" || { echo "nom de module invalide : '$APP'" >&2; exit 2; }
RESULT="${LAB_HOOK_RESULT_FILE:-}"

skip() {  # skip <raison> : rien n'est joué, ce n'est pas un échec
  [[ -n "$RESULT" ]] && printf 'skip %s\n' "$1" > "$RESULT"
  echo "  · $1"
  exit 0
}

decl="$(python3 -B "$SCRIPT_DIR/lib/modules.py" "$ROOT" hook "$APP" 2>/dev/null)"; decl_rc=$?
if [[ $decl_rc -ne 0 ]]; then
  [[ -n "$RESULT" ]] && printf '1\ndescription du module invalide\n' > "$RESULT"
  echo -e "\033[0;31m✗ ERROR : $APP — description du module invalide : script d'installation non joué (bash scripts/lab-modules.sh show $APP --json).\033[0m" >&2
  exit 1
fi
[[ -n "$decl" ]] || skip "aucun script d'installation déclaré"
read -r _script _timeout <<< "$decl"
[[ "$_script" == "install.sh" && "$_timeout" =~ ^[0-9]+$ ]] || skip "déclaration illisible"

if ! registry_is_superuser "$(registry_app_owner "$APP")"; then
  skip "script d'installation NON joué : app d'un développeur (règle v1 du lab — CLAUDE.md, « Modules »)"
fi
if [[ "$MODE" == "--if-new" ]]; then
  _state="$(python3 -B "$SCRIPT_DIR/lib/modules.py" "$ROOT" show "$APP" 2>/dev/null \
            | python3 -c 'import json,sys; print(json.load(sys.stdin)["state"])' 2>/dev/null)"
  case "$_state" in
    not_installed) ;;
    installed|stopped) skip "mise à jour : script d'installation non rejoué (seulement à l'installation d'un module absent du serveur)" ;;
    *) [[ -n "$RESULT" ]] && printf '1
état du module illisible
' > "$RESULT"
       echo -e "\033[0;31m✗ ERROR : $APP — état du module illisible (« ${_state:-?} ») : script d'installation non joué.\033[0m" >&2
       exit 1 ;;
  esac
  MODE=""
fi
HOOK="$DIR/install.sh"
if [[ ! -f "$HOOK" || -L "$HOOK" ]]; then
  [[ -n "$RESULT" ]] && printf '1\ninstall.sh déclaré mais absent\n' > "$RESULT"
  echo -e "\033[0;31m✗ ERROR : $APP — script d'installation déclaré mais absent (ou lien symbolique) : $HOOK\033[0m" >&2
  exit 1
fi

_args=(); [[ "$MODE" == "--check" ]] && _args=(--check)
_out="$(mktemp)"; trap 'rm -f "$_out"' EXIT
( cd "$DIR" && env -i PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    HOME="${HOME:-/tmp}" LANG="C.UTF-8" LAB_ROOT="$ROOT" LAB_MODULE="$APP" LAB_MODULE_DIR="$DIR" \
    timeout --kill-after=10 "$_timeout" bash "$HOOK" "${_args[@]}" ) 2>&1 < /dev/null \
  | tee "$_out" | sed -u 's/^/    /'
rc=${PIPESTATUS[0]}
if [[ -n "$RESULT" ]]; then { echo "$rc"; cat "$_out"; } > "$RESULT"; fi
if [[ $rc -eq 124 || $rc -eq 137 ]]; then
  echo -e "\033[0;31m✗ ERROR : $APP — script d'installation du module arrêté après ${_timeout} s (install.timeout_s).\033[0m" >&2
  exit 1
elif [[ $rc -ne 0 ]]; then
  if [[ "$MODE" == "--check" ]]; then
    echo "  ✘ install.sh --check : quelque chose manque (code $rc)"
  else
    echo -e "\033[0;31m✗ ERROR : $APP — script d'installation du module en échec (code $rc).\033[0m" >&2
  fi
  exit 1
fi
exit 0
