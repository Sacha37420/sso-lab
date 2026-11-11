# shellcheck shell=bash
# ─────────────────────────────────────────────────────────────────────────────
# automatisation/lib/verifier.sh — `auto.sh verifier` (contrat nuit-auto v1, I7).
# Contrôle chaque point qui pourrait faire attendre l'utilisateur, ou faire échouer la nuit
# en silence, et dit LEQUEL échoue. Ne modifie rien, sauf : le pare-feu des ponts est posé
# (idempotent, comme le moteur lab-mcp le fait avant chaque ouverture d'espace) et un appel
# minimal est fait à Claude et à GitHub.
# Code : 0 = rien ne peut attendre l'utilisateur ; 1 = au moins un point bloquant.
# ─────────────────────────────────────────────────────────────────────────────

V_KO=(); V_PRIV=""
v_ok()   { printf '  ✔ [%s] %s\n' "$1" "$2"; }
v_ko()   { printf '  ✘ [%s] %s\n' "$1" "$2"; V_KO+=("$1"); }
v_info() { printf '  ! [%s] %s\n' "$1" "$2"; }

v_jetons() {
  local f m ok=1 dm
  dm="$(stat -c %a "$AUTO_STATE" 2>/dev/null)"
  [[ "$dm" == 700 ]] || { v_ko jetons "$AUTO_STATE : mode ${dm:-absent}, 700 attendu"; ok=0; }
  for f in "$AUTO_TOKEN_CLAUDE" "$AUTO_TOKEN_GITHUB"; do
    if [[ ! -f "$f" || -L "$f" ]]; then v_ko jetons "$(basename "$f") absent ($f) — geste humain, voir README"; ok=0; continue; fi
    m="$(stat -c %a "$f")"
    [[ "$m" == 600 ]] || { v_ko jetons "$(basename "$f") en mode $m, 600 attendu (chmod 600 $f)"; ok=0; }
    [[ "$(stat -c %u "$f")" == "$(id -u)" ]] || { v_ko jetons "$(basename "$f") n'appartient pas à $(id -un)"; ok=0; }
    [[ -n "$(tr -d '[:space:]' < "$f")" ]] || { v_ko jetons "$(basename "$f") vide"; ok=0; }
  done
  (( ok )) && v_ok jetons "claude-token et github-token présents, 600 ; dossier d'état en 700"
}

v_image() {
  if ! x 20 docker image inspect "$AUTO_IMAGE" > /dev/null 2>&1; then v_ko image "$AUTO_IMAGE absente (bash scripts/workspace-image.sh)"; return; fi
  local ver
  ver="$(x 60 docker run --rm --network none --cap-drop ALL --user 1000:1000 --entrypoint claude "$AUTO_IMAGE" --version 2>/dev/null | head -1)"
  [[ -n "$ver" ]] && v_ok image "$AUTO_IMAGE — claude $ver" || v_ko image "claude ne répond pas dans $AUTO_IMAGE"
}

v_pare_feu() {
  local n
  if ! pare_feu_cmd apply > "$V_PRIV/fw.txt" 2>&1; then v_ko pare-feu "règles « lab-ws:$AUTO_BRIDGE_PREFIX » non posées : $(tail -1 "$V_PRIV/fw.txt")"; return; fi
  n="$(pare_feu_cmd show 2>/dev/null | grep -cE -- "--comment \"?lab-ws:${AUTO_BRIDGE_PREFIX}\"?( |\$)")"
  [[ "$n" == 10 ]] && v_ok pare-feu "10 règles « -i ${AUTO_BRIDGE_PREFIX}+ » en place (INPUT, DOCKER-USER)" \
                   || v_ko pare-feu "$n règle(s) « lab-ws:$AUTO_BRIDGE_PREFIX » au lieu de 10"
}

v_claude() {
  [[ -s "$AUTO_TOKEN_CLAUDE" ]] || { v_ko claude "pas de jeton : appel impossible"; return; }
  local net="auto-net-verifier-$$" rc res
  reseau_creer "$net" || { v_ko claude "réseau de vérification non créé"; return; }
  CLAUDE_CODE_OAUTH_TOKEN="$(< "$AUTO_TOKEN_CLAUDE")" \
  x 180 docker run --rm --init --name "auto-verifier-$$" --network "$net" --cap-drop ALL --security-opt no-new-privileges \
    --memory 1g --pids-limit 256 --user 1000:1000 -w /tmp -e CLAUDE_CODE_OAUTH_TOKEN -e HOME=/tmp \
    --entrypoint claude "$AUTO_IMAGE" -p --output-format json --max-turns 1 --model "$AUTO_MODEL" \
    "Réponds uniquement par le mot OK." > "$V_PRIV/claude.json" 2> "$V_PRIV/claude.err"
  rc=$?
  x 30 docker rm -f "auto-verifier-$$" > /dev/null 2>&1; reseau_retirer "$net"
  res="$(py claude-resultat "$V_PRIV/claude.json" "$rc" 0)"
  if [[ "${res%%$'\t'*}" == ok ]]; then v_ok claude "claude du conteneur authentifié (modèle $AUTO_MODEL)"
  else v_ko claude "appel minimal en échec : $(cut -f3 <<< "$res" | head -c 160)"; fi
}

v_github() {
  [[ -s "$AUTO_TOKEN_GITHUB" ]] || { v_ko github "pas de jeton : contrôle impossible"; return; }
  local repos=() c spec
  while IFS=$'\t' read -r _ _ spec; do
    [[ "$spec" == rotation:* ]] && continue
    for c in ${spec//,/ }; do repos+=("$(cible_depot "$c" 2>/dev/null || echo "?$c")"); done
  done < <(py calendrier-taches "$AUTO_CALENDRIER" 2>/dev/null)
  while IFS= read -r c; do repos+=("$(cible_depot "$c")"); done < <(rotation_liste)
  mapfile -t repos < <(printf '%s\n' "${repos[@]}" | grep -v '^?' | sort -u)
  if AUTO_GH_TOKEN="$(< "$AUTO_TOKEN_GITHUB")" py gh-verifier "$AUTO_GITHUB_API" "${repos[@]}" > "$V_PRIV/gh.txt" 2>&1; then
    v_ok github "jeton valide, à portée fine, sans delete_repo ; ${#repos[@]} dépôt(s) accessible(s)"
  else
    while IFS=$'\t' read -r e m; do [[ "$e" == ko ]] && v_ko github "$m"; done < "$V_PRIV/gh.txt"
    grep -q $'^ko\t' "$V_PRIV/gh.txt" || v_ko github "$(tail -1 "$V_PRIV/gh.txt")"
  fi
}

v_environnement() {
  local s gp ghp
  s="$(x 5 readlink /proc/self/fd/0)"; gp="$(x 5 printenv GIT_TERMINAL_PROMPT)"; ghp="$(x 5 printenv GH_PROMPT_DISABLED)"
  [[ "$s" == /dev/null ]] && v_ok stdin "entrée standard des commandes : /dev/null" || v_ko stdin "entrée standard des commandes : ${s:-?}"
  [[ "$gp" == 0 && "$ghp" == 1 ]] && v_ok invites "GIT_TERMINAL_PROMPT=0, GH_PROMPT_DISABLED=1" \
    || v_ko invites "GIT_TERMINAL_PROMPT=${gp:-∅} GH_PROMPT_DISABLED=${ghp:-∅}"
}

v_timeouts() {
  local out
  out="$(py lint-timeout "$AUTO_DIR/bin"/*.sh "$AUTO_LIB"/*.sh "$AUTO_LIB"/*.py 2>&1)"
  [[ -z "$out" ]] && v_ok timeouts "chaque commande externe du moteur passe par timeout (x, gx, py)" \
    || { v_ko timeouts "commande(s) sans timeout :"; sed 's/^/        /' <<< "$out"; }
}

v_verrou() {
  local rc lt="$AUTO_LOCK_TIMEOUT"
  [[ "$lt" =~ ^[0-9]+$ ]] && (( lt > 0 && lt <= 7200 )) || { v_ko verrou "AUTO_LOCK_TIMEOUT=$lt : attente non bornée (1 à 7200 s)"; return; }
  [[ -f "$LAB_ROOT/scripts/lab-lock.sh" ]] || { v_ko verrou "scripts/lab-lock.sh absent"; return; }
  LAB_LOCK_TIMEOUT=1 x 15 bash "$LAB_ROOT/scripts/lab-lock.sh" true > /dev/null 2>&1; rc=$?
  case $rc in
    0)  v_ok verrou "verrou de déploiement libre ; attente bornée à ${lt} s puis « echec »" ;;
    75) v_info verrou "verrou de déploiement occupé en ce moment (un passage attendrait ${lt} s puis « echec »)" ;;
    *)  v_ko verrou "lab-lock.sh rend le code $rc" ;;
  esac
}

v_disque() {
  local d go ok=1 dr
  dr="$(x 20 docker info -f '{{.DockerRootDir}}' 2>/dev/null)"
  for d in "$AUTO_WORK" "$AUTO_STATE" ${dr:+"$dr"}; do
    local p="$d"; while [[ ! -e "$p" ]]; do p="$(dirname "$p")"; done
    go="$(df -Pk -- "$p" 2>/dev/null | awk 'NR==2 { printf "%d", $4 / 1048576 }')"
    [[ -n "$go" ]] || continue
    (( go >= AUTO_DISQUE_MIN_GO )) || { v_ko disque "$d : $go Go libres (< ${AUTO_DISQUE_MIN_GO} Go)"; ok=0; }
  done
  (( ok )) && v_ok disque "au moins ${AUTO_DISQUE_MIN_GO} Go libres (travail, état, Docker)"
}

v_smtp() {
  local msg
  if msg="$( (
        for k in SMTP_HOST SMTP_PORT SMTP_USER SMTP_PASSWORD SMTP_FROM SMTP_SSL SMTP_STARTTLS; do
          export "$k=$(grep -E "^$k=" "$AUTO_SMTP_ENV" 2>/dev/null | tail -1 | cut -d= -f2-)"
        done
        export AUTO_EMAIL_DIR="${AUTO_EMAIL_DIR:-}"
        py smtp-verifier ) 2>&1)"; then
    v_ok smtp "$msg ; destinataire : $( [[ -n "$(registry_root_env LAB_BACKUP_EMAIL)" ]] && echo LAB_BACKUP_EMAIL || echo SMTP_FROM)"
  else
    v_ko smtp "${msg#outils : }"
  fi
}

v_prompts() {
  local t ok=1 f
  if ! py calendrier-taches "$AUTO_CALENDRIER" > "$V_PRIV/cal.txt" 2> "$V_PRIV/cal.err"; then
    v_ko prompts "calendrier illisible : $(cat "$V_PRIV/cal.err")"; return
  fi
  for f in _commun.md _correction.md _reprise.md; do
    [[ -f "$AUTO_DIR_PROMPTS/$f" ]] || { v_ko prompts "prompts/$f absent"; ok=0; }
  done
  while IFS=$'\t' read -r _ t _; do
    [[ -f "$AUTO_DIR_PROMPTS/$t.md" ]] || { v_ko prompts "prompts/$t.md absent (tâche du calendrier)"; ok=0; }
  done < "$V_PRIV/cal.txt"
  [[ -f "$AUTO_SCHEMA" ]] || { v_ko prompts "schema-resume.json absent"; ok=0; }
  (( ok )) && v_ok prompts "calendrier ($(wc -l < "$V_PRIV/cal.txt") jours) et prompts de chaque tâche présents"
}

v_cibles() {
  local spec c ok=1 n
  while IFS=$'\t' read -r _ _ spec; do
    if [[ "$spec" == rotation:* ]]; then continue; fi
    for c in ${spec//,/ }; do cible_depot "$c" > /dev/null 2>&1 || { v_ko cibles "cible $c : dépôt GitHub introuvable"; ok=0; }; done
  done < "$V_PRIV/cal.txt"
  n="$(rotation_liste | wc -l)"
  (( n > 0 )) || { v_ko cibles "rotation vide (aucune app du superutilisateur avec un dépôt GitHub)"; ok=0; }
  (( ok )) && v_ok cibles "cibles fixes résolues ; rotation : $n app(s)"
}

v_planification() {
  source "$AUTO_LIB/planifier.sh"
  local cur; cur="$(cron_lire)"
  if grep -qF "$AUTO_DIR/bin/auto.sh lancer" <<< "$cur" && grep -qF "$AUTO_DIR/bin/auto.sh rattraper" <<< "$cur"; then
    v_ok planification "crontab : lancer à 0 h, rattraper à 5 h 10"
  else
    v_info planification "pas encore planifié : bash automatisation/bin/auto.sh planifier"
  fi
}

cmd_verifier() {
  [[ $# -eq 0 ]] || usage
  V_PRIV="$(mktemp -d "${TMPDIR:-/tmp}/lab-auto-v.XXXXXX")"; trap 'rm -rf -- "$V_PRIV"' EXIT
  echo "Relectures de nuit — vérification ($(date '+%F %T'))"
  v_jetons; v_prompts; v_cibles; v_image; v_pare_feu; v_claude; v_github
  v_environnement; v_timeouts; v_verrou; v_disque; v_smtp; v_planification
  echo
  if (( ${#V_KO[@]} == 0 )); then echo "Rien ne peut attendre l'utilisateur."; return 0; fi
  local u; u="$(printf '%s\n' "${V_KO[@]}" | sort -u)"
  echo "$(wc -l <<< "$u") point(s) bloquant(s) : $(paste -sd, - <<< "$u" | sed 's/,/, /g')"
  return 1
}
