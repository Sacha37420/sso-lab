#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# backup-cron.sh — planifie la sauvegarde nocturne (scripts/backup.sh) dans la
#                  crontab de l'utilisateur courant. REJOUABLE.
#
# Usage :
#   bash scripts/backup-cron.sh --check    ne fait RIEN : dit si la sauvegarde est
#                                          planifiée et ce qui manque pour la copie NAS
#   bash scripts/backup-cron.sh            pose la ligne si elle manque (rien sinon)
#   bash scripts/backup-cron.sh --hour 4   autre heure (défaut : 3 h)
#
# Code de sortie : 0 = planifiée (et, en --check, rien à faire) ; 1 = quelque
# chose manque ou a échoué ; 2 = erreur d'usage.
#
# POURQUOI : install.sh ne planifiait pas la sauvegarde ; c'était un geste à la
# main (README §1.2), facile à oublier sur une machine neuve.
#
# Ce que fait le script :
#   • cherche dans la crontab une ligne qui lance CE backup.sh ; s'il y en a une,
#     il ne la change pas (même à une autre heure) ;
#   • sinon, ajoute en fin de crontab un commentaire et la ligne
#       0 <heure> * * * /bin/bash <dépôt>/scripts/backup.sh > /dev/null 2>&1
#   • vérifie (sans rien écrire) les prérequis de la copie NAS : LAB_BACKUP_NAS et
#     LAB_BACKUP_NAS_USER dans le .env racine, ~/.lab-backup-nas en mode 600.
#     Sans eux, backup.sh ne fait que la copie locale et le signale chaque nuit.
# N'affiche jamais un mot de passe. Ne touche à aucune autre ligne de la crontab.
#
# Essai sans toucher à la vraie crontab : LAB_CRONTAB_FILE=<fichier> remplace
# la crontab par ce fichier (lu et écrit à sa place).
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/registry.sh
source "$SCRIPT_DIR/lib/registry.sh"
ROOT="$(registry_root)"

CHECK=false; HOUR=3
while [[ $# -gt 0 ]]; do
  case "$1" in
    --check) CHECK=true ;;
    --hour)  [[ $# -gt 1 && "$2" =~ ^([0-9]|1[0-9]|2[0-3])$ ]] || { echo "--hour : 0 à 23" >&2; exit 2; }; HOUR="$2"; shift ;;
    -h|--help) sed -n '2,31p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Option inconnue : $1 (voir --help)" >&2; exit 2 ;;
  esac
  shift
done

G='\033[0;32m'; Y='\033[1;33m'; R='\033[0;31m'; N='\033[0m'
ok()   { echo -e "  ${G}✔${N} $*"; }
todo() { echo -e "  ${Y}→${N} $*"; }
bad()  { echo -e "  ${R}✘${N} $*"; PROBLEMS=$((PROBLEMS + 1)); }
PROBLEMS=0

BACKUP="$ROOT/scripts/backup.sh"
[[ -f "$BACKUP" ]] || { echo "scripts/backup.sh introuvable dans $ROOT" >&2; exit 1; }
LINE="0 ${HOUR} * * * /bin/bash ${BACKUP} > /dev/null 2>&1"

cron_read() {
  if [[ -n "${LAB_CRONTAB_FILE:-}" ]]; then cat "$LAB_CRONTAB_FILE" 2>/dev/null || true
  else crontab -l 2>/dev/null || true; fi
}
cron_write() {  # lit la nouvelle crontab sur l'entrée standard
  if [[ -n "${LAB_CRONTAB_FILE:-}" ]]; then cat > "$LAB_CRONTAB_FILE"
  else crontab -; fi
}

echo "Sauvegarde nocturne — $( $CHECK && echo 'vérification (rien n'"'"'est modifié)' || echo 'planification')"

# ── 1. La ligne de crontab ───────────────────────────────────────────────────
if [[ -z "${LAB_CRONTAB_FILE:-}" ]] && ! command -v crontab > /dev/null 2>&1; then
  bad "commande crontab absente (Debian : apt install cron)"
else
  current="$(cron_read)"
  existing="$(grep -vE '^[[:space:]]*#' <<< "$current" | grep -F "$BACKUP" || true)"
  if [[ -n "$existing" ]]; then
    ok "déjà planifiée : ${existing}"
  elif $CHECK; then
    todo "à faire : ajouter « ${LINE} » à la crontab de $(id -un)"
    PROBLEMS=$((PROBLEMS + 1))
  else
    if { [[ -n "$current" ]] && printf '%s\n' "$current"
         printf '%s\n' "# Sauvegarde du lab (bases, annuaire, storage, configuration) — voir scripts/backup.sh" "$LINE"; } | cron_write; then
      ok "planifiée : ${LINE}"
    else
      bad "écriture de la crontab refusée"
    fi
  fi
fi

# ── 2. Prérequis de la copie NAS (lecture seule) ─────────────────────────────
envget() { grep -E "^$1=" "$ROOT/.env" 2>/dev/null | tail -1 | cut -d= -f2- | sed -e 's/[[:space:]]*#.*$//' -e "s/^['\"]//" -e "s/['\"]\$//" || true; }
NAS="$(envget LAB_BACKUP_NAS)"; NAS_USER="$(envget LAB_BACKUP_NAS_USER)"
if [[ -z "$NAS" ]]; then
  todo "copie NAS non configurée (LAB_BACKUP_NAS vide dans .env) : seule la copie locale sera faite"
else
  ok "NAS : ${NAS}"
  [[ -n "$NAS_USER" ]] && ok "compte NAS : ${NAS_USER}" || bad "LAB_BACKUP_NAS_USER vide dans .env"
  PW="$HOME/.lab-backup-nas"
  if [[ ! -f "$PW" ]]; then bad "$PW absent (mot de passe du compte NAS, une ligne, mode 600)"
  elif [[ "$(stat -c '%a' "$PW")" != "600" ]]; then bad "$PW en mode $(stat -c '%a' "$PW") : chmod 600 $PW"
  else ok "$PW présent, mode 600"; fi
fi
command -v docker > /dev/null 2>&1 && ! docker image inspect lab-backup:latest > /dev/null 2>&1 \
  && todo "image lab-backup absente : backup.sh la construira à son premier passage (scripts/backup/Dockerfile)"

echo ""
if [[ $PROBLEMS -eq 0 ]]; then echo -e "${G}Rien à faire.${N}"; exit 0; fi
echo -e "${Y}${PROBLEMS} point(s) à régler.${N}"; exit 1
