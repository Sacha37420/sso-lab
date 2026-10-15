#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# app-preview.sh — l'ESSAI d'un développeur : son dossier de travail (non
# commité compris), construit et servi à une adresse qui n'est qu'à lui.
# Chantier « essai-dev », contrat v1, interface I1.
#
# Usage :
#   bash scripts/lab-lock.sh bash scripts/app-preview.sh up     <uid> <app>
#   bash scripts/lab-lock.sh bash scripts/app-preview.sh down   <uid>
#   bash                          scripts/app-preview.sh status <uid>
#
#   Adresse : https://<DOMAIN>/dev-<uid>/   et   https://<DOMAIN>/dev-<uid>-api/
#   Projet Compose, client Keycloak, préfixe des conteneurs : dev-<uid>
#   Schéma : <slug de l'app>__essai, dans la base de l'app
#   État   : <LAB_STATE_DIR>/preview/<uid>/  (state.json, builds/<id>/)
#
# Codes : 0 réussi · 1 échec ou refus · 2 usage (dont : `up`/`down` lancés sans
# le verrou de déploiement). Le script ne PREND PAS le verrou : il vérifie
# seulement qu'un ancêtre le tient (lab-lock.sh, ou app-remove.sh).
# stdout : des lignes pour le journal du job — jamais un secret, jamais le
# contenu d'un .env — puis une DERNIÈRE ligne `RESULTAT=<JSON sur une ligne>`.
#
# POURQUOI CE SCRIPT EST DÉLICAT : il construit et démarre, pour le compte d'un
# développeur qui n'a pas Docker, du code que personne n'a relu ni testé, et
# qui n'est même pas commité. Ce qui tient :
#
#   • la COPIE des sources est lue comme une donnée hostile. git ne lit jamais
#     le .git du développeur (sa configuration peut lancer une commande :
#     core.fsmonitor, hooks…) : un dépôt vide, à nous, reçoit une copie du seul
#     fichier d'index, et sert à lister. Chaque fichier est ensuite ouvert sans
#     suivre de lien, composant par composant (scripts/lib/preview.py) ;
#   • la RÉÉCRITURE porte sur le modèle Compose RÉSOLU (ancres YAML, `extends`,
#     `include` aplatis par `docker compose config`), pas sur le texte : la
#     section `ports:` est retirée d'où qu'elle vienne. Elle est entière ou
#     refusée ;
#   • c'est le fichier RÉÉCRIT qui passe ensuite le contrôle de sûreté complet
#     (scripts/lib/validate_compose.py, le même que le déploiement réel), comme
#     une app nommée dev-<uid> et sans aucun port permis — pour TOUT
#     propriétaire, superutilisateur compris ;
#   • `docker compose` tourne dans un environnement reparti de zéro : rien de
#     ce que porte le processus appelant ne peut être interpolé dans le fichier
#     d'un développeur ;
#   • une fois l'essai démarré, RIEN n'est relu dans son dossier (un conteneur
#     peut y écrire par un montage) : `down` et `status` ne connaissent que le
#     nom du projet et state.json, qui est hors de portée de tout montage ;
#   • l'app EN SERVICE n'est jamais touchée : autre projet Compose, autres
#     noms d'images, autre schéma, autre client Keycloak, aucune écriture dans
#     deploiement/<app> ni dans le dossier de travail.
#
# Un échec avant l'étape `client` laisse l'essai précédent intact : le nouveau
# est préparé dans un dossier à lui (builds/<id>), et rien de l'ancien n'est
# arrêté ni modifié avant.
#
# Réglages (tous facultatifs) : LAB_PREVIEW_BUILD_TIMEOUT (s, défaut 1800),
# LAB_PREVIEW_START_WAIT (s, défaut 60), LAB_PREVIEW_MEM / _CPUS / _PIDS
# (plafonds par conteneur : 1g, 1, 512), LAB_PREVIEW_MAX_BYTES / _MAX_FILES.
# LAB_PREVIEW_KEEP_FAILED=1 garde le dossier d'un essai refusé (dépannage, tests).
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/registry.sh
source "$SCRIPT_DIR/lib/registry.sh"
ROOT="$(registry_root)"
PY=(python3 -B "$SCRIPT_DIR/lib/preview.py")
COMPOSE_NAME=".lab-essai.compose.json"

say()  { printf '%s\n' "$*"; }
note() { printf '  %s\n' "$*"; }
_strip() { sed -u -e 's/\x1b\[[0-9;?]*[A-Za-z]//g' -e 's/^/  /'; }

usage() {
  cat >&2 <<'EOF'
Usage :
  bash scripts/lab-lock.sh bash scripts/app-preview.sh up     <uid> <app>
  bash scripts/lab-lock.sh bash scripts/app-preview.sh down   <uid>
  bash                          scripts/app-preview.sh status <uid>
EOF
  echo 'RESULTAT={"ok":false,"step":"arguments","error":"usage : app-preview.sh up <uid> <app> | down <uid> | status <uid>","reasons":[]}'
  exit 2
}

# fail <step> <message> [fichier de raisons, une par ligne]
fail() {
  local step="$1" msg="$2" file="${3:-}" reasons='[]'
  if [[ -n "$file" && -s "$file" ]]; then
    reasons="$(jq -Rcn '[inputs | select(length > 0)] | .[:60]' < "$file" 2>/dev/null || echo '[]')"
    sed 's/^/    /' "$file" | head -60
  fi
  say "✗ essai — étape « $step » : $msg"
  jq -cn --arg s "$step" --arg e "$msg" --argjson r "$reasons" \
     '"RESULTAT=" + ({ok: false, step: $s, error: $e, reasons: $r} | tojson)' -r
  exit 1
}

# ── Le verrou de déploiement est-il tenu (par un ancêtre) ? ───────────────────
# Même lecture que scripts/lib/lock.sh : on ne croit pas LAB_LOCK_HELD sur
# parole, on tente un flock non bloquant — s'il réussit, personne ne tenait le
# verrou, et on le rend aussitôt (ce script ne le prend jamais).
lock_is_held() {
  local path fd
  path="$(registry_state_dir)/deploy.lock"
  [[ -e "$path" ]] || return 1
  exec {fd}>>"$path" || return 1
  if flock -n "$fd"; then
    flock -u "$fd"; exec {fd}>&-
    return 1
  fi
  exec {fd}>&-
  return 0
}

# ── Docker, environnement reparti de zéro ─────────────────────────────────────
CLEAN=(env -i "PATH=$PATH" "HOME=${HOME:-/tmp}" "LANG=C.UTF-8")
[[ -n "${DOCKER_HOST:-}" ]]   && CLEAN+=("DOCKER_HOST=$DOCKER_HOST")
[[ -n "${DOCKER_CONFIG:-}" ]] && CLEAN+=("DOCKER_CONFIG=$DOCKER_CONFIG")

# « service<TAB>état » de chaque conteneur du projet → tableau JSON (I1).
# $1 : services attendus (tableau JSON) — un service sans conteneur est « exited ».
services_json() {
  docker ps -a --filter "label=com.docker.compose.project=${NAME}" \
      --format '{{.Label "com.docker.compose.service"}}\t{{.State}}\t{{.Status}}' 2>/dev/null \
  | jq -Rcn --argjson expected "${1:-[]}" '
      [inputs | split("\t") | select(length >= 2 and .[0] != "")
        | {service: .[0], st: .[1], status: (.[2] // "")}
        | {service,
           state: (if .st == "running" then
                     (if (.status | test("\\(unhealthy\\)")) then "unhealthy"
                      elif (.status | test("health: starting")) then "starting"
                      else "running" end)
                   elif (.st == "created" or .st == "restarting") then "starting"
                   else "exited" end)}] as $seen
      | $seen + [$expected[] | select(. as $e | ($seen | map(.service) | index($e)) | not)
                 | {service: ., state: "exited"}]
      | sort_by(.service)'
}

has_containers() {
  [[ -n "$(docker ps -aq --filter "label=com.docker.compose.project=${NAME}" 2>/dev/null)" ]]
}

# Suppression d'un dossier d'essai : un conteneur a pu y laisser des fichiers
# de root (montage `./backend:/app`) — un conteneur jetable les retire alors.
remove_dir() {
  local dir="$1"
  [[ -n "$dir" && -d "$dir" && "$dir" == "$PV"/builds/* ]] || return 0
  rm -rf -- "$dir" 2>/dev/null && return 0
  # Une image déjà présente sur l'hôte (aucun téléchargement) ; alpine:3 à défaut.
  local img helper="alpine:3"
  for img in alpine:3 postgres:16-alpine nginx:alpine redis:7-alpine; do
    docker image inspect "$img" > /dev/null 2>&1 && { helper="$img"; break; }
  done
  docker run --rm --network none --entrypoint sh -v "$dir:/target" "$helper" \
    -c 'rm -rf /target/* /target/.[!.]* /target/..?* 2>/dev/null; true' > /dev/null 2>&1 || true
  rm -rf -- "$dir" 2>/dev/null || note "⚠ $dir n'a pas pu être entièrement supprimé (fichiers d'un autre utilisateur)"
}

# Retire conteneurs, réseaux, volumes et images du projet dev-<uid>. Ne lit
# AUCUN fichier du dossier de l'essai : le nom du projet suffit à Compose.
project_down() {
  local ids
  ( cd "$1" && "${CLEAN[@]}" docker compose -p "$NAME" down --volumes --remove-orphans 2>&1 ) | _strip || true
  ids="$(docker ps -aq --filter "label=com.docker.compose.project=${NAME}" 2>/dev/null || true)"
  # shellcheck disable=SC2086
  [[ -z "$ids" ]] || docker rm -f $ids > /dev/null 2>&1 || true
  ids="$(docker volume ls -q --filter "label=com.docker.compose.project=${NAME}" 2>/dev/null || true)"
  # shellcheck disable=SC2086
  [[ -z "$ids" ]] || docker volume rm $ids > /dev/null 2>&1 || true
}

project_images_rm() {
  local img
  # Un uid n'a pas de tiret : « dev-<uid>-* » ne peut désigner les images d'aucun autre essai.
  while IFS= read -r img; do
    [[ "$img" =~ ^${NAME}-[a-zA-Z0-9_.-]+(:[A-Za-z0-9_.-]+)?$ ]] || continue
    docker image rm "$img" > /dev/null 2>&1 || true
  done < <(docker image ls --filter "reference=${NAME}-*" --format '{{.Repository}}:{{.Tag}}' 2>/dev/null || true)
}

# ── Arguments ─────────────────────────────────────────────────────────────────
CMD="${1:-}"
case "$CMD" in
  up)          [[ $# -eq 3 ]] || usage ;;
  down|status) [[ $# -eq 2 ]] || usage ;;
  *)           usage ;;
esac
DEV_UID="$2"; APP="${3:-}"

for _c in docker jq python3 git flock; do
  command -v "$_c" > /dev/null || { say "✗ commande requise absente : $_c"; echo 'RESULTAT={"ok":false,"step":"arguments","error":"outil manquant sur l'"'"'hôte","reasons":[]}'; exit 1; }
done

if ! registry_valid_uid "$DEV_UID"; then
  if [[ "$CMD" == "up" ]]; then fail arguments "uid invalide (forme attendue : ^[a-z][a-z0-9]{1,30}\$)"; fi
  say "✗ uid invalide"; usage
fi
NAME="dev-${DEV_UID}"
PV="$(registry_state_dir)/preview/${DEV_UID}"
STATE="$PV/state.json"

state_get() { [[ -s "$STATE" ]] && jq -r "$1 // empty" "$STATE" 2>/dev/null || true; }

# ══════════════════════════════════════════════════════════════════════════════
# status — lecture seule, sans verrou
# ══════════════════════════════════════════════════════════════════════════════
if [[ "$CMD" == "status" ]]; then
  ABSENT="$(jq -cn --arg u "$DEV_UID" '{uid: $u, state: "absent", app: null, url: null, api_url: null, groups: [], built_at: null, services: []}')"
  if [[ ! -s "$STATE" ]] || ! jq -e '.app | type == "string"' "$STATE" > /dev/null 2>&1 || ! has_containers; then
    echo "RESULTAT=$ABSENT"; exit 0
  fi
  SVC="$(services_json "$(jq -c '.services // []' "$STATE")")"
  jq -c --argjson svc "$SVC" --arg u "$DEV_UID" '
      ($svc | map(.state)) as $s
      | {uid: $u,
         state: (if ($s | length) == 0 then "absent"
                 elif ($s | all(. == "running")) then "running"
                 elif ($s | all(. == "exited")) then "stopped"
                 else "degraded" end),
         app, url, api_url, groups, built_at, services: $svc}
      | "RESULTAT=" + tojson' -r "$STATE"
  exit 0
fi

# `up` et `down` : jamais sans le verrou de déploiement.
if ! lock_is_held; then
  say "✗ app-preview.sh $CMD doit être lancé sous le verrou : bash scripts/lab-lock.sh bash scripts/app-preview.sh $CMD …"
  echo 'RESULTAT={"ok":false,"step":"arguments","error":"lancé sans le verrou de déploiement (scripts/lab-lock.sh)","reasons":[]}'
  exit 2
fi

TMP="$(umask 077; mktemp -d)" || { say "✗ dossier temporaire impossible"; exit 1; }
NEW=""
cleanup() {
  [[ -n "$NEW" && -d "$NEW" && "${LAB_PREVIEW_KEEP_FAILED:-}" != "1" ]] && remove_dir "$NEW"
  rm -rf -- "$TMP" 2>/dev/null || true
}
trap cleanup EXIT

# ══════════════════════════════════════════════════════════════════════════════
# down
# ══════════════════════════════════════════════════════════════════════════════
if [[ "$CMD" == "down" ]]; then
  STOPPED=false
  if has_containers; then
    STOPPED=true
    say "▶ essai $NAME — arrêt"
    project_down "$TMP"
    if has_containers; then
      fail down "des conteneurs de l'essai n'ont pas pu être retirés"
    fi
  fi
  project_images_rm
  rm -f -- "$STATE" 2>/dev/null || true
  if [[ -d "$PV/builds" ]]; then
    for _d in "$PV"/builds/*/; do [[ -d "$_d" ]] && remove_dir "${_d%/}"; done
  fi
  $STOPPED && say "✓ essai $NAME arrêté (le schéma d'essai et le client Keycloak sont gardés)" \
           || say "· essai $NAME : rien à arrêter"
  jq -cn --arg u "$DEV_UID" --argjson s "$STOPPED" '"RESULTAT=" + ({ok: true, uid: $u, stopped: $s} | tojson)' -r
  exit 0
fi

# ══════════════════════════════════════════════════════════════════════════════
# up
# ══════════════════════════════════════════════════════════════════════════════
say "▶ essai $NAME — projet « $APP »"

# ── arguments ─────────────────────────────────────────────────────────────────
[[ "$APP" =~ ^[a-z][a-z0-9-]{1,38}[a-z0-9]$ ]] || fail arguments "nom d'app invalide"
APP_DIR="$(registry_app_dir "$APP")" || fail arguments "nom d'app invalide"
[[ -d "$APP_DIR" && ! -L "$APP_DIR" && -f "$APP_DIR/docker-compose.yml" ]] \
  || fail arguments "projet inconnu : « $APP »"
OWNER="$(registry_app_owner "$APP")"
[[ "$OWNER" == "$DEV_UID" ]] \
  || fail arguments "« $APP » n'appartient pas à « $DEV_UID » — l'essai d'un projet se construit à l'adresse de son propriétaire"
IS_SU=0; registry_is_superuser "$OWNER" && IS_SU=1

DOMAIN_VAL="$(registry_root_env DOMAIN)"
[[ -n "$DOMAIN_VAL" && "$DOMAIN_VAL" != "CHANGE_ME" ]] \
  || fail arguments "le lab n'a pas de domaine (DOMAIN) — pas d'essai en HTTP local : un essai ne publie aucun port"
[[ "$DOMAIN_VAL" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] || fail arguments "DOMAIN du lab inattendu"

WORK_ROOT="${LAB_WORK_DIR:-}"
[[ -n "$WORK_ROOT" ]] || WORK_ROOT="$(registry_root_env LAB_WORK_DIR)"
[[ -n "$WORK_ROOT" ]] || WORK_ROOT="$(dirname "$ROOT")/lab-work"
[[ "$WORK_ROOT" == /* && "$WORK_ROOT" != *..* ]] || fail arguments "LAB_WORK_DIR doit être un chemin absolu"
WORK="$WORK_ROOT/$DEV_UID/$APP"
[[ -d "$WORK" && ! -L "$WORK" && ! -L "$WORK_ROOT/$DEV_UID" ]] \
  || fail arguments "aucun dossier de travail pour « $APP » — ouvrir d'abord son espace de travail"

# Chemin Caddy et groupes requis de l'app : écrits par le cadriciel dans le
# dossier de SERVICE (.keycloak-client-opts), jamais lus dans le dossier de travail.
CADDY_PATH="$APP"; GROUPS_CSV=""
OPTS_FILE="$APP_DIR/.keycloak-client-opts"
if [[ -f "$OPTS_FILE" && ! -L "$OPTS_FILE" ]]; then
  _opts=()
  while IFS= read -r _l || [[ -n "$_l" ]]; do
    [[ -z "$_l" || "$_l" == \#* ]] && continue
    # shellcheck disable=SC2206
    _opts+=( $_l )
  done < "$OPTS_FILE"
  _i=0
  while (( _i < ${#_opts[@]} )); do
    case "${_opts[$_i]}" in
      --caddy-path|--caddy-subdomain) CADDY_PATH="${_opts[$((_i + 1))]:-}"; _i=$((_i + 1)) ;;
      --require-group)                GROUPS_CSV="${_opts[$((_i + 1))]:-}"; _i=$((_i + 1)) ;;
    esac
    _i=$((_i + 1))
  done
fi
[[ "$CADDY_PATH" =~ ^[a-z0-9][a-z0-9-]{0,62}$ ]] || fail arguments "chemin Caddy de l'app illisible (.keycloak-client-opts)"
[[ -z "$GROUPS_CSV" || "$GROUPS_CSV" =~ ^[A-Za-z0-9_-]+(,[A-Za-z0-9_-]+)*$ ]] \
  || fail arguments "groupes requis de l'app illisibles (.keycloak-client-opts)"
GROUPS_JSON="$(jq -cn --arg g "$GROUPS_CSV" '$g | split(",") | map(select(length > 0)) | unique')"
SLUG="${APP//-/_}"

PREV_APP="$(state_get .app)"
PREV_GROUPS="$(state_get '.groups | tojson')"
PREV_DIR="$(state_get .dir)"
note "adresse : https://${DOMAIN_VAL}/${NAME}/ — groupes requis : ${GROUPS_CSV:-aucun (tout compte du realm)}"
[[ -z "$PREV_APP" ]] || note "essai précédent : « $PREV_APP » (remplacé seulement si celui-ci démarre)"

mkdir -p "$PV/builds" && chmod 700 "$(registry_state_dir)/preview" "$PV" "$PV/builds" 2>/dev/null \
  || fail arguments "dossier d'état de l'essai impossible à créer"
NEW="$PV/builds/$(date +%Y%m%d-%H%M%S)-$$"
mkdir -m 700 "$NEW" || fail arguments "dossier d'état de l'essai impossible à créer"

# Valeur d'une clé dans un fichier KEY=valeur (comme _env_val de reset_url.sh) ;
# vide si absent. Sert aux adresses du lab que l'essai recalcule (étape env).
_kv() { [[ -f "$1" && ! -L "$1" ]] || return 0
        sed -n "s/^$2=//p" "$1" 2>/dev/null | tail -1 | sed -e 's/[[:space:]]*#.*$//' -e 's/^["'"'"']//' -e 's/["'"'"']$//'; }
# Realm : le même que reset_url.sh (REALM="ssolab", écrit en dur là-bas aussi).

# ── source ────────────────────────────────────────────────────────────────────
say "══ source — copie du dossier de travail (non commité compris)"
# Un dépôt git VIDE, à nous : aucune configuration du développeur n'est lue.
# Son index (une donnée, pas un programme) y est copié pour que la liste soit
# exactement celle de `git ls-files -co --exclude-standard` chez lui.
GITENV=(env -i "PATH=$PATH" "HOME=$TMP" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
        GIT_TERMINAL_PROMPT=0 GIT_OPTIONAL_LOCKS=0 "GIT_CEILING_DIRECTORIES=$TMP")
GITOPTS=(-c core.fsmonitor=false -c core.untrackedCache=false -c core.hooksPath=/dev/null
         -c core.excludesFile=/dev/null -c core.quotePath=false -c core.sparseCheckout=false
         -c index.sparse=false -c core.splitIndex=false -c safe.directory=*)
"${GITENV[@]}" git init -q --bare "$TMP/git" > /dev/null 2>&1 || fail source "préparation de la liste des fichiers impossible"
_idx="$WORK/.git/index"
if [[ -f "$_idx" && ! -L "$_idx" && ! -L "$WORK/.git" && "$(stat -c %s "$_idx" 2>/dev/null || echo 0)" -le 67108864 ]]; then
  cp --no-dereference -- "$_idx" "$TMP/git/index" 2>/dev/null || true
fi
list_files() {
  "${GITENV[@]}" git --git-dir="$TMP/git" --work-tree="$WORK" "${GITOPTS[@]}" \
    ls-files -c -o --exclude-standard -z > "$TMP/list" 2> "$TMP/git.err"
}
if ! list_files; then
  # Index illisible par un dépôt neuf (index partagé, format inattendu…) :
  # sans index, la liste est « tout ce que .gitignore n'écarte pas ».
  rm -f "$TMP/git/index"
  list_files || fail source "liste des fichiers du dossier de travail impossible"
  note "index git illisible — liste établie d'après les .gitignore seulement"
fi
if ! "${PY[@]}" copy "$WORK" "$NEW" "$TMP/list" > "$TMP/reasons" 2> "$TMP/copy.msg"; then
  fail source "le dossier de travail ne peut pas être copié tel quel" "$TMP/reasons"
fi
note "$(cat "$TMP/copy.msg" 2>/dev/null)"
[[ -f "$NEW/docker-compose.yml" ]] || fail source "docker-compose.yml absent du dossier de travail"

# ── rewrite ───────────────────────────────────────────────────────────────────
say "══ rewrite — /${CADDY_PATH} → /${NAME}, noms de conteneurs, aucun port publié"
# Modèle RÉSOLU mais NON interpolé : les ${VAR} restent des ${VAR} (aucune
# valeur de .env n'est figée dans le fichier), les ancres/extends/include sont
# aplatis. L'environnement est vide : rien de l'appelant n'y entre.
if ! "${CLEAN[@]}" docker compose -p "$NAME" --project-directory "$NEW" -f "$NEW/docker-compose.yml" \
       --profile '*' config --format json --no-interpolate --no-env-resolution \
       > "$TMP/model.json" 2> "$TMP/err"; then
  grep -v 'level=warning' "$TMP/err" | tail -1 | cut -c1-300 | sed 's/^/[rewrite] docker-compose.yml illisible : /' > "$TMP/reasons"
  fail rewrite "docker-compose.yml illisible" "$TMP/reasons"
fi
if ! LABP_APP="$APP" "${PY[@]}" rewrite "$TMP/model.json" "$NEW" "$NAME" "$CADDY_PATH" "$TMP/rewrite.json" > "$TMP/reasons" 2>&1; then
  fail rewrite "le projet s'écarte de la forme du gabarit : la réécriture n'est pas faite à moitié, elle est refusée" "$TMP/reasons"
fi
HAS_FRONT="$(jq -r '.has_front' "$TMP/rewrite.json")"; HAS_API="$(jq -r '.has_api' "$TMP/rewrite.json")"
SERVICES_JSON="$(jq -c '.services' "$TMP/rewrite.json")"
note "services : $(jq -r '.services | join(", ")' "$TMP/rewrite.json") ; fichiers réécrits : $(jq -r '(.files + ["docker-compose.yml"]) | join(", ")' "$TMP/rewrite.json")"

# Le .env de l'essai est CALCULÉ ici (dans un fichier temporaire en 600) parce
# que le contrôle de sûreté doit juger le modèle tel qu'il sera exécuté, donc
# interpolé avec ces valeurs-là. Il n'est posé dans l'état qu'à l'étape `env`.
ENV_ERR=""
if [[ ! -f "$APP_DIR/.env" || -L "$APP_DIR/.env" ]]; then
  ENV_ERR="le projet n'a pas de .env de service (jamais déployé ?)"
elif ! LABP_NAME="$NAME" LABP_SLUG="$SLUG" LABP_DOMAIN="$DOMAIN_VAL" LABP_OWNER="$OWNER" LABP_SUPERUSER="$IS_SU" \
       LABP_GROUPS="$GROUPS_CSV" LABP_REALM="ssolab" LABP_SERVER_URL_LAN="$(_kv "$ROOT/bbox.env" SERVER_URL_LAN)" \
       LABP_SERVER_URL_WAN="$(_kv "$ROOT/bbox.env" SERVER_URL_WAN)" LABP_PORT_KEYCLOAK="$(_kv "$ROOT/sso-lab/.env" PORT_KEYCLOAK)" \
       "${PY[@]}" env "$APP_DIR/.env" "$TMP/env" "$TMP/env.json" > "$TMP/env.reasons" 2>&1; then
  ENV_ERR="le .env de l'essai ne peut pas être établi"
fi
[[ -z "$ENV_ERR" ]] || fail env "$ENV_ERR" "$TMP/env.reasons"

# ── validate ──────────────────────────────────────────────────────────────────
say "══ validate — contrôle de sûreté de la copie réécrite, comme une app nommée $NAME"
dc() { "${CLEAN[@]}" docker compose -p "$NAME" --project-directory "$NEW" -f "$NEW/$COMPOSE_NAME" --env-file "$1" "${@:2}"; }
if ! dc "$TMP/env" --profile '*' config --format json --no-env-resolution > "$TMP/resolved.json" 2> "$TMP/err"; then
  grep -v 'level=warning' "$TMP/err" | tail -1 | cut -c1-300 | "${PY[@]}" redact "$TMP/env" \
    | sed 's/^/[compose] modèle invalide : /' > "$TMP/reasons"
  fail validate "le dépôt est refusé par le contrôle de sûreté" "$TMP/reasons"
fi
# Noms déjà portés dans le lab — MÊME liste que scripts/validate-app.sh
# (conteneurs des autres projets, services de l'infrastructure, autres apps).
{
  docker ps -a --format '{{.Names}}\t{{.Label "com.docker.compose.project"}}\t{{.Label "com.docker.compose.service"}}' 2>/dev/null \
    | awk -F'\t' -v app="$NAME" '$2 != app { print $1; if ($2 == "infra" || $2 == "sso-lab" || $2 == "runner") print $3 }'
  printf '%s\n' postgres postgis pgadmin keycloak openldap ldap phpldapadmin caddy code-server oauth2-proxy lab-runner
  registry_all_apps || true
} | sort -u > "$TMP/reserved"
# Ports permis : AUCUN (4ᵉ argument vide). Dossier de l'app : la copie.
python3 -B "$SCRIPT_DIR/lib/validate_compose.py" "$NAME" "$NEW" "$DOMAIN_VAL" "" "$TMP/reserved" \
  < "$TMP/resolved.json" > "$TMP/reasons" 2> "$TMP/err"
_rc=$?
if [[ $_rc -eq 1 ]]; then
  fail validate "le dépôt est refusé par le contrôle de sûreté" "$TMP/reasons"
elif [[ $_rc -ne 0 ]]; then
  fail validate "analyse du modèle Compose impossible (code $_rc)"
fi
# Ceinture : après réécriture ET contrôle, aucun service ne publie de port et
# tous portent le nom de l'essai. Si l'un des deux a un trou, on s'arrête ici.
if ! jq -e --arg n "$NAME" '
      .name == $n and ([.services[] | (.ports // []) | length] | add) == 0
      and ([.services | to_entries[] | .value.container_name == ($n + "-" + .key)] | all)' "$TMP/resolved.json" > /dev/null 2>&1; then
  fail validate "le modèle réécrit publie un port ou ne porte pas le nom de l'essai (anomalie de la réécriture)"
fi
note "accepté : aucun port publié, chemins /${NAME} et /${NAME}-api seulement"

# ── env ───────────────────────────────────────────────────────────────────────
say "══ env — .env de l'essai (mode 600, dans l'état ; jamais affiché)"
[[ ! -L "$NEW/.env" ]] || fail env "le dossier de l'essai porte un lien nommé .env"
install -m 600 "$TMP/env" "$NEW/.env" || fail env "écriture du .env de l'essai impossible"
DB_NAME="$(jq -r '.database // empty' "$TMP/env.json")"; DB_SCHEMA="$(jq -r '.schema // empty' "$TMP/env.json")"
DB_HOST="$(jq -r '.db_host // empty' "$TMP/env.json")";  DB_USER="$(jq -r '.db_user // empty' "$TMP/env.json")"
note "clés retirées : $(jq -r '(.dropped | if length == 0 then "aucune" else join(", ") end)' "$TMP/env.json")"
note "client ${NAME}, SCRIPT_NAME=/${NAME}-api, schéma ${DB_SCHEMA:-— (app sans base)}"
REDACT=("${PY[@]}" redact "$NEW/.env")

# ── schema ────────────────────────────────────────────────────────────────────
if [[ -n "$DB_SCHEMA" ]]; then
  say "══ schema — ${DB_SCHEMA} dans ${DB_NAME}"
  [[ "$DB_SCHEMA" =~ ^[a-z_][a-z0-9_]*$ && "$DB_NAME" =~ ^[a-z_][a-z0-9_]*$ && "$DB_USER" =~ ^[a-z_][a-z0-9_]*$ ]] \
    || fail schema "nom de base, de rôle ou de schéma inattendu"
  _infra() { grep -E "^$1=" "$ROOT/infra/.env" 2>/dev/null | tail -1 | cut -d= -f2- || true; }
  if [[ "$DB_HOST" == "postgis" ]]; then
    PG_C="${GIS_CONTAINER:-dev-postgis}"; PG_ADMIN="$(_infra POSTGIS_USER)"; PG_ADMIN="${PG_ADMIN:-gisuser}"
  else
    PG_C="${PG_CONTAINER:-dev-postgres}"; PG_ADMIN="$(_infra POSTGRES_USER)"; PG_ADMIN="${PG_ADMIN:-devuser}"
  fi
  [[ "$(docker inspect -f '{{.State.Running}}' "$PG_C" 2>/dev/null || true)" == "true" ]] \
    || fail schema "l'instance PostgreSQL « $PG_C » ne tourne pas"
  [[ "$(docker exec "$PG_C" psql -X -U "$PG_ADMIN" -d postgres -tAc \
        "SELECT 1 FROM pg_database WHERE datname = '${DB_NAME}'" < /dev/null 2>/dev/null || true)" == "1" ]] \
    || fail schema "la base « $DB_NAME » n'existe pas sur $PG_C"
  if [[ "$(docker exec "$PG_C" psql -X -U "$PG_ADMIN" -d "$DB_NAME" -tAc \
        "SELECT 1 FROM pg_namespace WHERE nspname = '${DB_SCHEMA}'" < /dev/null 2>/dev/null || true)" == "1" ]]; then
    note "schéma déjà présent (il survit d'un essai à l'autre)"
  elif docker exec "$PG_C" psql -X -U "$PG_ADMIN" -d "$DB_NAME" -v ON_ERROR_STOP=1 -q \
         -c "CREATE SCHEMA IF NOT EXISTS \"${DB_SCHEMA}\" AUTHORIZATION \"${DB_USER}\";" < /dev/null > /dev/null 2>&1; then
    note "schéma créé, propriétaire ${DB_USER} — vide : ce ne sont pas les données de l'app"
  else
    fail schema "création du schéma « $DB_SCHEMA » impossible dans $DB_NAME"
  fi
else
  say "══ schema — app sans base : rien à créer"
fi

# ── build ─────────────────────────────────────────────────────────────────────
say "══ build — images ${NAME}-<service> (l'app en service n'est pas touchée ; pas de tests)"
BUILD_TIMEOUT="${LAB_PREVIEW_BUILD_TIMEOUT:-1800}"; [[ "$BUILD_TIMEOUT" =~ ^[0-9]+$ ]] || BUILD_TIMEOUT=1800
timeout --signal=TERM --kill-after=30 "$BUILD_TIMEOUT" \
  "${CLEAN[@]}" docker compose --progress plain -p "$NAME" --project-directory "$NEW" -f "$NEW/$COMPOSE_NAME" \
    --env-file "$NEW/.env" build 2>&1 | "${REDACT[@]}" | _strip
_rc=${PIPESTATUS[0]}
if [[ $_rc -ne 0 ]]; then
  if [[ $_rc -eq 124 || $_rc -eq 137 ]]; then fail build "build interrompu après ${BUILD_TIMEOUT}s"; fi
  fail build "le build a échoué (voir le journal ci-dessus) — l'essai précédent, s'il y en a un, tourne toujours"
fi

# ── client ────────────────────────────────────────────────────────────────────
say "══ client — client Keycloak ${NAME}, groupes requis : ${GROUPS_CSV:-aucun}"
# Si les groupes changent, l'essai précédent est arrêté AVANT de toucher au
# client : sinon, entre ici et le démarrage, les membres des nouveaux groupes
# passeraient la porte du navigateur vers l'essai d'une autre app.
if has_containers && [[ "$PREV_GROUPS" != "$GROUPS_JSON" ]]; then
  note "les groupes requis changent — arrêt de l'essai précédent avant la mise à jour du client"
  ( cd "$TMP" && "${CLEAN[@]}" docker compose -p "$NAME" stop 2>&1 ) | _strip || true
fi
CLIENT_ARGS=("$NAME" --public --no-env --no-wan --no-rotate --caddy-path "$NAME" --exact-groups)
[[ -z "$GROUPS_CSV" ]] || CLIENT_ARGS+=(--require-group "$GROUPS_CSV")
LAB_JOURNAL_REDACT=1 bash "$SCRIPT_DIR/create-app-client.sh" "${CLIENT_ARGS[@]}" < /dev/null 2>&1 \
  | grep -vE '^[[:space:]]*$' | "${REDACT[@]}" | _strip
if [[ ${PIPESTATUS[0]} -ne 0 ]]; then
  fail client "le client Keycloak ${NAME} n'a pas pu être mis à jour avec exactement les groupes de l'app"
fi

# ── up ────────────────────────────────────────────────────────────────────────
say "══ up — démarrage"
BUILT_AT="$(date -Iseconds)"
URL="null"; API_URL="null"
[[ "$HAS_FRONT" == "true" ]] && URL="\"https://${DOMAIN_VAL}/${NAME}/\""
[[ "$HAS_API" == "true" ]]   && API_URL="\"https://${DOMAIN_VAL}/${NAME}-api/\""
STATE_JSON="$(jq -cn --arg u "$DEV_UID" --arg a "$APP" --argjson url "$URL" --argjson api "$API_URL" \
     --argjson g "$GROUPS_JSON" --arg db "$DB_NAME" --arg sc "$DB_SCHEMA" --arg at "$BUILT_AT" \
     --argjson svc "$SERVICES_JSON" --arg dir "$NEW" \
     '{uid: $u, app: $a, url: $url, api_url: $api, groups: $g,
       database: (if $db == "" then null else $db end), schema: (if $sc == "" then null else $sc end),
       built_at: $at, services: $svc, dir: $dir}')"
# L'état est écrit AVANT le démarrage : à partir d'ici l'adresse montre ce
# projet, même si un service ne démarre pas (`status` dira « degraded »).
printf '%s\n' "$STATE_JSON" > "$STATE.tmp.$$" && chmod 600 "$STATE.tmp.$$" && mv -f "$STATE.tmp.$$" "$STATE" \
  || fail up "état de l'essai impossible à écrire"
BUILD_DIR="$NEW"; NEW=""   # ce dossier est désormais celui de l'essai en service : plus de nettoyage en sortie

if [[ -n "$PREV_APP" && "$PREV_APP" != "$APP" ]]; then
  note "l'adresse montrait « $PREV_APP » — ses conteneurs et volumes d'essai sont retirés"
  project_down "$TMP"
fi
"${CLEAN[@]}" docker compose -p "$NAME" --project-directory "$BUILD_DIR" -f "$BUILD_DIR/$COMPOSE_NAME" \
    --env-file "$BUILD_DIR/.env" up -d --no-build --remove-orphans 2>&1 | "${REDACT[@]}" | _strip
if [[ ${PIPESTATUS[0]} -ne 0 ]]; then
  fail up "docker compose up a échoué (voir le journal ci-dessus)"
fi

# Laisser aux services le temps de tomber : un backend qui échoue à migrer
# s'arrête quelques secondes après avoir « démarré ».
WAIT="${LAB_PREVIEW_START_WAIT:-60}"; [[ "$WAIT" =~ ^[0-9]+$ ]] || WAIT=60
_min=$((SECONDS + 10)); _max=$((SECONDS + WAIT))
while :; do
  SVC="$(services_json "$SERVICES_JSON")"
  if jq -e 'any(.[]; .state == "starting")' <<< "$SVC" > /dev/null; then
    (( SECONDS < _max )) || break
  elif (( SECONDS >= _min )); then
    break
  fi
  sleep 2
done

# Les anciens dossiers d'essai ne servent plus à aucun conteneur.
for _d in "$PV"/builds/*/; do
  _d="${_d%/}"
  [[ -d "$_d" && "$_d" != "$BUILD_DIR" ]] && remove_dir "$_d"
done
docker image prune -f > /dev/null 2>&1 || true

: > "$TMP/reasons"
while IFS=$'\t' read -r _cid _svc _state; do
  [[ -n "$_cid" && "$_state" != "running" ]] || continue
  _code="$(docker inspect -f '{{.State.ExitCode}}' "$_cid" 2>/dev/null || echo '?')"
  [[ "$_state" == "exited" && "$_code" == "0" ]] && continue   # tâche d'initialisation terminée normalement
  echo "[up] service « $_svc » : $_state (code $_code)" >> "$TMP/reasons"
  say "  ── dernières lignes du journal de « $_svc » :"
  docker logs --tail 25 "$_cid" 2>&1 | "${REDACT[@]}" | cut -c1-400 | sed 's/^/     /'
done < <(docker ps -a --filter "label=com.docker.compose.project=${NAME}" \
           --format '{{.ID}}\t{{.Label "com.docker.compose.service"}}\t{{.State}}' 2>/dev/null)
if jq -e 'any(.[]; .state == "unhealthy" or .state == "starting")' <<< "$SVC" > /dev/null; then
  jq -r '.[] | select(.state == "unhealthy" or .state == "starting") | "[up] service « " + .service + " » : " + .state' <<< "$SVC" >> "$TMP/reasons"
fi
if [[ -s "$TMP/reasons" ]]; then
  sort -u -o "$TMP/reasons" "$TMP/reasons"
  fail up "l'essai est construit mais au moins un service ne tourne pas" "$TMP/reasons"
fi

say "✓ essai $NAME en service$([[ "$URL" != "null" ]] && echo " : https://${DOMAIN_VAL}/${NAME}/")"
jq -c --argjson svc "$SVC" '"RESULTAT=" + ({ok: true, uid, app, url, api_url, groups, database, schema, built_at, services: $svc} | tojson)' -r <<< "$STATE_JSON"
exit 0
