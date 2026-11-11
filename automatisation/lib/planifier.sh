# shellcheck shell=bash
# ─────────────────────────────────────────────────────────────────────────────
# automatisation/lib/planifier.sh — `auto.sh planifier [--retirer] [--check]` (I7).
# Pose (ou retire) dans la crontab de l'utilisateur courant, et RIEN D'AUTRE :
#     # lab-auto : relectures de nuit (automatisation/bin/auto.sh) …
#     0 0 * * * /bin/bash <dépôt>/automatisation/bin/auto.sh lancer > /dev/null 2>&1
#     10 5 * * * /bin/bash <dépôt>/automatisation/bin/auto.sh rattraper > /dev/null 2>&1
# Nos lignes sont reconnues au chemin de CE auto.sh ; aucune autre ligne n'est touchée.
# --check : ne fait rien, dit ce qui serait fait (code 1 s'il reste quelque chose à faire).
# Essais : AUTO_CRONTAB_FILE=<fichier> remplace la crontab (lue et écrite à sa place).
# ─────────────────────────────────────────────────────────────────────────────

cron_lire() {
  if [[ -n "${AUTO_CRONTAB_FILE:-}" ]]; then cat "$AUTO_CRONTAB_FILE" 2>/dev/null; return 0; fi
  x 20 crontab -l 2>/dev/null; return 0
}
cron_ecrire() {  # cron_ecrire <fichier>
  if [[ -n "${AUTO_CRONTAB_FILE:-}" ]]; then cat "$1" > "$AUTO_CRONTAB_FILE"; return; fi
  x 20 crontab "$1"
}

cmd_planifier() {
  local retirer=0 check=0
  while [[ $# -gt 0 ]]; do
    case "$1" in --retirer) retirer=1 ;; --check) check=1 ;; *) usage ;; esac; shift
  done
  [[ -n "${AUTO_CRONTAB_FILE:-}" ]] || command -v crontab > /dev/null || { echo "✗ commande crontab absente" >&2; return 1; }
  local bin="$AUTO_DIR/bin/auto.sh" cur new tmp
  local l1="0 0 * * * /bin/bash $bin lancer > /dev/null 2>&1"
  local l2="10 5 * * * /bin/bash $bin rattraper > /dev/null 2>&1"
  local com="# lab-auto : relectures de nuit (automatisation/bin/auto.sh) — lancer 0 h, rattraper 5 h 10"
  cur="$(cron_lire)"
  # Ce qui n'est pas à nous, tel quel.
  local autres; autres="$(grep -vF -- "$bin" <<< "$cur" | grep -vxF -- "$com")"
  if (( retirer )); then new="$autres"; else new="${autres:+$autres$'\n'}$com"$'\n'"$l1"$'\n'"$l2"; fi
  new="$(sed '/./,$!d' <<< "$new")"   # pas de lignes vides en tête
  if [[ "$(sed '/^$/d' <<< "$cur")" == "$(sed '/^$/d' <<< "$new")" ]]; then
    echo "Crontab : rien à faire ($( (( retirer )) && echo 'relectures non planifiées' || echo 'relectures déjà planifiées'))."
    return 0
  fi
  if (( check )); then
    echo "Crontab — serait modifiée (rien n'est écrit) :"
    diff <(printf '%s\n' "$cur") <(printf '%s\n' "$new") | grep -E '^[<>]' | sed 's/^</  retirée :/; s/^>/  ajoutée :/'
    return 1
  fi
  tmp="$(mktemp "${TMPDIR:-/tmp}/lab-auto-cron.XXXXXX")"
  printf '%s\n' "$new" > "$tmp"
  if cron_ecrire "$tmp"; then
    rm -f "$tmp"
    (( retirer )) && echo "✓ relectures de nuit retirées de la crontab" || { echo "✓ planifié :"; echo "  $l1"; echo "  $l2"; }
  else
    rm -f "$tmp"; echo "✗ écriture de la crontab refusée" >&2; return 1
  fi
}
