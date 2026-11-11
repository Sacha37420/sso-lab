#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# auto.sh — relectures de nuit du lab par Claude Code, sans intervention humaine.
# Contrat chantiers/nuit-auto/CONTRAT.md v1 (I7). Mode d'emploi : automatisation/README.md.
#
#   bash automatisation/bin/auto.sh lancer [--date AAAA-MM-JJ] [--tache T] [--essai]
#   bash automatisation/bin/auto.sh rattraper       # 5 h 10 : reprend si statut ≠ fini,
#                                                   # lance la tâche de la nuit si aucun passage
#   bash automatisation/bin/auto.sh verifier        # 0 = rien ne peut attendre l'utilisateur
#   bash automatisation/bin/auto.sh etat [--json]
#   bash automatisation/bin/auto.sh planifier [--retirer] [--check]
#
# Codes : 0 = passage fini (ou rien à faire) ; 1 = passage non fini / point bloquant ;
#         2 = usage ; 75 = un autre passage tient le verrou du moteur au-delà du délai.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
# shellcheck source=../lib/commun.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/commun.sh"
# shellcheck source=../lib/passage.sh
source "$AUTO_LIB/passage.sh"

usage() { sed -n '2,15p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2; exit 2; }

verrou_moteur() {
  mkdir -p "$AUTO_STATE"; chmod 700 "$AUTO_STATE"
  exec 8>> "$AUTO_STATE/auto.lock"
  flock -w "$AUTO_LOCK_TIMEOUT" 8 || { echo "✗ un autre passage tient le verrou du moteur depuis plus de ${AUTO_LOCK_TIMEOUT} s" >&2; exit 75; }
}

tache_du_jour() {  # tache_du_jour <date> → « tache<TAB>spec » ; code 3 = aucune tâche ce jour
  py calendrier "$AUTO_CALENDRIER" "$(date -d "$1" +%u)"
}

fin_epoch() {
  if [[ -n "${AUTO_FIN_EPOCH:-}" ]]; then echo "$AUTO_FIN_EPOCH"; else py fin "$1"; fi
}

# Dossiers de travail des passages finis, ou de plus de 7 jours : supprimés.
purger_travail() {
  local d id s
  [[ -d "$AUTO_WORK/travail" ]] || return 0
  for d in "$AUTO_WORK/travail"/*/; do
    [[ -d "$d" ]] || continue; id="$(basename "$d")"
    s="$(py etat-get "$AUTO_RUNS/$id/etat.json" statut 2>/dev/null)"
    if [[ "$s" == fini || -n "$(find "$d" -maxdepth 0 -mtime +7 2>/dev/null)" ]]; then supprimer_travail "$d"; fi
  done
}

finir() {  # écrit l'état final ; code de sortie du passage
  local s="$STATUT_FINAL" d="$DETAIL_FINAL"
  if [[ "$s" == fini ]]; then
    local npr=0; [[ -s "$RUN_DIR/pr-faites" ]] && npr="$(wc -l < "$RUN_DIR/pr-faites")"
    d="passage fini : $npr PR$( [[ -s "$RUN_DIR/sans-pr" ]] && echo ", $(wc -l < "$RUN_DIR/sans-pr") cible(s) en rapport seul")${d:+ — $d}"
    [[ "$ESSAI" == 1 ]] && d="essai fini (ni push, ni PR, ni email)"
  fi
  etat statut="$s" fin=maintenant detail="$d"
  log "■ passage $RUN_ID : $s — $d"
  [[ "$s" == fini ]]
}

# Enchaînement complet ou repris d'un passage (le dossier est ouvert, les cibles connues).
derouler() {  # derouler principale|reprise|apres
  local depart="$1"
  if [[ "$depart" != apres ]] && ! temoin claude-fini; then
    if ! claude_phases "$depart"; then
      noter "$([[ "$CLAUDE_STATUT" == limite ]] && echo limite || echo echec)" "$CLAUDE_DETAIL"
      return 1
    fi
  fi
  apres_claude
}

preparer_secrets_et_garde() {
  secrets_preparer
  trap 'secrets_nettoyer; x 30 docker rm -f "${CNAME:-auto-none}" > /dev/null 2>&1; x 30 docker network rm "${NET:-auto-none}" > /dev/null 2>&1' EXIT
}

# ── lancer ────────────────────────────────────────────────────────────────────
cmd_lancer() {
  local date="" tache="" essai=0 spec ligne
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --date)  [[ "${2:-}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] && date -d "$2" > /dev/null 2>&1 || usage; date="$2"; shift ;;
      --tache) [[ "${2:-}" =~ ^[a-z][a-z0-9-]{0,30}$ ]] || usage; tache="$2"; shift ;;
      --essai) essai=1 ;;
      --rattrapage) RATTRAPAGE=1 ;;
      *) usage ;;
    esac
    shift
  done
  [[ -n "$date" ]] || date="$(date +%F)"
  if [[ -n "$tache" ]]; then
    spec="$(py tache-cibles "$AUTO_CALENDRIER" "$tache")" || { echo "✗ tâche « $tache » absente du calendrier" >&2; exit 2; }
  else
    ligne="$(tache_du_jour "$date")"; case $? in 0) ;; 3) echo "aucune tâche le $date"; exit 0 ;; *) exit 2 ;; esac
    tache="${ligne%%$'\t'*}"; spec="${ligne#*$'\t'}"
  fi
  verrou_moteur
  preparer_secrets_et_garde
  [[ "$essai" == 1 ]] || purger_travail
  local id="$date-$tache"; [[ "$essai" == 1 ]] && id+="-essai"
  if [[ "$essai" == 1 ]]; then
    rm -rf -- "$AUTO_RUNS/$id"; supprimer_travail "$AUTO_WORK/travail/$id"
  elif [[ -f "$AUTO_RUNS/$id/etat.json" && "${RATTRAPAGE:-0}" != 1 ]]; then
    echo "✗ le passage $id existe déjà (statut $(py etat-get "$AUTO_RUNS/$id/etat.json" statut)) — « auto.sh rattraper » le reprend" >&2
    exit 1
  fi
  passage_ouvrir "$date" "$tache" "$essai"
  FIN_EPOCH="$(fin_epoch "$([[ "${RATTRAPAGE:-0}" == 1 ]] && echo "$AUTO_FIN_RATTRAPAGE" || echo "$AUTO_FIN")")"
  etat tache="$tache" date="$date" phase=principale statut=en_cours debut=maintenant fin= session_id= \
       detail="$([[ "${RATTRAPAGE:-0}" == 1 ]] && echo 'rattrapage d'"'"'un passage manquant' || echo 'passage lancé')"
  log "▶ passage $RUN_ID — cibles « $spec » — fin à $(date -d "@$FIN_EPOCH" '+%F %H:%M')$([[ "$essai" == 1 ]] && echo ' — ESSAI')"
  if ! cibles_choisir "$spec" > "$RUN_DIR/cibles.demandees"; then noter echec "aucune app dans la rotation"; finir; exit 1; fi
  if ! cibles_preparer < "$RUN_DIR/cibles.demandees"; then noter echec "aucune cible n'a pu être clonée"; finir; exit 1; fi
  contexte_preparer
  derouler principale
  finir; local rc=$?
  [[ "$STATUT_FINAL" == fini || "${RATTRAPAGE:-0}" == 1 ]] && email_envoyer
  exit $rc
}

# ── rattraper ─────────────────────────────────────────────────────────────────
cmd_rattraper() {
  [[ $# -eq 0 ]] || usage
  local date ligne tache id statut
  date="${AUTO_DATE:-$(date +%F)}"    # AUTO_DATE : essais seulement
  ligne="$(tache_du_jour "$date")"; case $? in 0) ;; 3) echo "aucune tâche le $date"; exit 0 ;; *) exit 2 ;; esac
  tache="${ligne%%$'\t'*}"; id="$date-$tache"
  if [[ ! -f "$AUTO_RUNS/$id/etat.json" ]]; then
    mkdir -p "$AUTO_RUNS/$id"
    py etat "$AUTO_RUNS/$id/etat.json" tache="$tache" date="$date" statut=manque detail="aucun passage à 0 h : rattrapage"
    RATTRAPAGE=1 cmd_lancer --date "$date" --rattrapage
  fi
  verrou_moteur
  statut="$(py etat-get "$AUTO_RUNS/$id/etat.json" statut)"
  if [[ "$statut" == manque && ! -f "$AUTO_RUNS/$id/cibles" ]]; then
    RATTRAPAGE=1 cmd_lancer --date "$date" --rattrapage
  fi
  if [[ "$statut" == fini ]]; then echo "passage $id déjà fini — rien à rattraper"; exit 0; fi
  preparer_secrets_et_garde
  passage_ouvrir "$date" "$tache" 0
  FIN_EPOCH="$(fin_epoch "$AUTO_FIN_RATTRAPAGE")"
  log "▶ rattrapage de $RUN_ID (statut $statut) — fin à $(date -d "@$FIN_EPOCH" '+%F %H:%M')"
  if [[ ! -s "$RUN_DIR/cibles" ]]; then
    # Rien n'avait pu être préparé : on reprend du début, avec les cibles déjà choisies si on les a.
    local spec="${ligne#*$'\t'}"
    if [[ -s "$RUN_DIR/cibles.demandees" ]]; then cp "$RUN_DIR/cibles.demandees" "$AUTO_PRIV/dem"
    else cibles_choisir "$spec" > "$AUTO_PRIV/dem" || { noter echec "aucune app dans la rotation"; finir; email_envoyer; exit 1; }; fi
    cp "$AUTO_PRIV/dem" "$RUN_DIR/cibles.demandees"
    cibles_preparer < "$RUN_DIR/cibles.demandees" || { noter echec "aucune cible n'a pu être clonée"; finir; email_envoyer; exit 1; }
    etat statut=en_cours detail="rattrapage : passage repris du début"
    contexte_preparer
    derouler principale
  else
    local c manque=0
    for c in $(cibles_noms); do [[ -d "$TRAVAIL/work/$c/.git" && -d "$TRAVAIL/propre/$c/.git" ]] || manque=1; done
    if (( manque )); then
      noter echec "dossiers de travail du passage disparus — rattrapage impossible"
    elif [[ "$statut" == refuse ]] || ! temoin claude-fini; then
      # Correctif rejeté par le moteur : la session reprend pour le corriger (sans rejouer la suite).
      if [[ "$statut" == refuse ]]; then rm -f "$RUN_DIR/claude-fini"; echo refus > "$RUN_DIR/phase-interrompue"; fi
      etat statut=en_cours phase=reprise detail="rattrapage : reprise de la session"
      derouler reprise
    else
      etat statut=en_cours detail="rattrapage : contrôles et publication"
      derouler apres
    fi
  fi
  finir; local rc=$?
  email_envoyer
  exit $rc
}

# ── etat ──────────────────────────────────────────────────────────────────────
cmd_etat() {
  case "${1:-}" in
    "") py etat-liste "$AUTO_RUNS" ;;
    --json) py etat-liste "$AUTO_RUNS" --json ;;
    *) usage ;;
  esac
}

case "${1:-}" in
  lancer)    shift; cmd_lancer "$@" ;;
  rattraper) shift; cmd_rattraper "$@" ;;
  verifier)  shift; source "$AUTO_LIB/verifier.sh"; cmd_verifier "$@" ;;
  etat)      shift; cmd_etat "$@" ;;
  planifier) shift; source "$AUTO_LIB/planifier.sh"; cmd_planifier "$@" ;;
  -h|--help) usage ;;
  *) usage ;;
esac
