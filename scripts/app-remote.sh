#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# app-remote.sh — dit où en est GitHub par rapport à ce qui tourne.
# Contrat « multi-dev » v8, interface I4 (« Ajout v8 »).
#
# Usage :
#   bash scripts/app-remote.sh <app>
#
# Sortie : UNE ligne JSON sur stdout, rien d'autre (les messages vont sur stderr) :
#   {"reachable": true, "branch": "main", "head": "<sha>", "deployed": "<sha>"|null, "behind": <entier>|null}
#
#   reachable  le dépôt distant a répondu ;
#   branch     branche par défaut d'origin ;
#   head       SHA de sa tête ;
#   deployed   SHA du dernier déploiement réussi (<LAB_STATE_DIR>/deployed/<app>.json), ou null ;
#   behind     nombre de commits de cette branche ABSENTS de la version déployée ;
#              0 = à jour ; null si rien n'est déployé, si le SHA déployé est
#              inconnu (app historique jamais redéployée par le nouveau chemin),
#              ou s'il n'est plus dans l'historique de la branche.
#
# Code : 0, y compris quand le dépôt est injoignable ou que l'app n'a pas
# d'origin utilisable — {"reachable": false, …null} : ce n'est pas une erreur du
# lab. 1 = app inconnue ; 2 = erreur d'usage (rien sur stdout dans ces deux cas).
#
# CE QUE CE SCRIPT NE FAIT JAMAIS : écrire dans le dépôt de l'app. Ni l'arbre de
# travail, ni HEAD, ni l'index, ni la configuration, ni même ses refs ou ses
# objets. Il n'y fait que LIRE (URL d'origin, objets déjà présents). Tout ce
# qu'il récupère va dans un dépôt « bare » TEMPORAIRE, qui emprunte les objets
# de l'app en lecture seule (objects/info/alternates) et est supprimé en sortie.
# Conséquences voulues :
#   • aucun verrou git n'est pris dans le dépôt de l'app : un app-sync.sh qui
#     tourne en même temps ne gêne pas et n'est pas gêné ;
#   • le verrou de déploiement n'est pas pris non plus ;
#   • ce qui est déployé n'est pas touché.
#
# Identifiants : la clé de déploiement du dépôt si elle existe
# (<LAB_STATE_DIR>/deploy-keys/<app>), sinon AUCUN (dépôt public). Jamais de
# jeton. Délai borné : 15 secondes en tout (LAB_REMOTE_TIMEOUT pour les tests).
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/registry.sh
source "$SCRIPT_DIR/lib/registry.sh"
# shellcheck source=lib/git.sh
source "$SCRIPT_DIR/lib/git.sh"

log() { echo "app-remote : $*" >&2; }

[[ $# -eq 1 ]] || { echo "Usage : bash scripts/app-remote.sh <app>" >&2; exit 2; }
APP="$1"
APP_DIR="$(registry_app_dir "$APP")" || { log "nom d'app invalide : '$APP'"; exit 1; }
[[ -d "$APP_DIR" ]] || { log "app inconnue : '$APP'"; exit 1; }

BUDGET="${LAB_REMOTE_TIMEOUT:-15}"; [[ "$BUDGET" =~ ^[0-9]+$ && "$BUDGET" -ge 2 ]] || BUDGET=15
START=$SECONDS
remaining() { local r=$(( BUDGET - (SECONDS - START) )); (( r < 1 )) && r=1; echo "$r"; }

# ── SHA déployé (lecture d'un fichier d'état, jamais du dépôt) ────────────────
DEPLOYED="null"
if _d="$(registry_deployed_json "$APP")"; then
  _s="$(jq -r '.sha // empty' <<< "$_d" 2>/dev/null || true)"
  [[ "$_s" =~ ^[0-9a-f]{40}$ ]] && DEPLOYED="\"$_s\""
fi

emit() {  # emit <reachable> <branch|""> <head|""> <behind|null>
  jq -n -c --argjson r "$1" --arg b "$2" --arg h "$3" --argjson d "$DEPLOYED" --argjson n "$4" \
    '{reachable: $r,
      branch:   (if $b == "" then null else $b end),
      head:     (if $h == "" then null else $h end),
      deployed: (if $r then $d else null end),
      behind:   $n}'
}
unreachable() { log "$1"; emit false "" "" null; exit 0; }

# ── Dépôt temporaire ──────────────────────────────────────────────────────────
TMP="$(mktemp -d "${TMPDIR:-/tmp}/app-remote.XXXXXX")" || { log "dossier temporaire impossible"; emit false "" "" null; exit 0; }
cleanup() { [[ -n "${TMP:-}" && -d "$TMP" && "$TMP" == */app-remote.* ]] && rm -rf -- "$TMP"; }
trap cleanup EXIT

# ── Origin : LU dans le dépôt de l'app, rien n'y est écrit ────────────────────
# --no-optional-locks : même la lecture ne rafraîchit pas l'index.
ro() { GIT_OPTIONAL_LOCKS=0 git --no-optional-locks -C "$APP_DIR" "$@"; }
[[ "$(ro rev-parse --show-toplevel 2>/dev/null || true)" == "$APP_DIR" ]] \
  || unreachable "$APP n'est pas un dépôt git"
URL="$(ro remote get-url origin 2>/dev/null || true)"
[[ -n "$URL" ]] || unreachable "$APP n'a pas de remote origin"
lab_git_valid_url "$URL" || unreachable "l'origin de $APP n'est pas une URL https utilisable"
OBJECTS="$(ro rev-parse --git-path objects 2>/dev/null || true)"
[[ "$OBJECTS" == /* ]] || OBJECTS="$APP_DIR/$OBJECTS"

# Transport : clé de déploiement si elle existe, sinon anonyme. Jamais de jeton
# (LAB_GIT_TOKEN est ignoré d'office : on le retire de l'environnement).
unset LAB_GIT_TOKEN
DEPLOY_KEY="$(lab_git_deploy_key "$APP" || true)"
FETCH_URL="$URL"
if [[ -n "$DEPLOY_KEY" ]]; then
  FETCH_URL="$(lab_git_ssh_url "$URL")" || unreachable "URL d'origin non traduisible en URL SSH"
  net() { timeout --kill-after=2 "$(remaining)" bash -c 'source "$1/lib/registry.sh"; source "$1/lib/git.sh"; shift; lab_git_key "$@"' _ "$SCRIPT_DIR" "$TMP/repo.git" "$DEPLOY_KEY" "$@"; }
else
  net() { timeout --kill-after=2 "$(remaining)" bash -c 'source "$1/lib/registry.sh"; source "$1/lib/git.sh"; shift; lab_git "isolé" "$@"' _ "$SCRIPT_DIR" "$TMP/repo.git" "$@"; }
fi

git init -q --bare "$TMP/repo.git" 2>/dev/null || unreachable "dépôt temporaire impossible"
# Emprunt en lecture seule des objets déjà présents dans le dépôt de l'app :
# seuls les commits qui lui manquent sont téléchargés.
[[ -d "$OBJECTS" ]] && printf '%s\n' "$OBJECTS" > "$TMP/repo.git/objects/info/alternates"

# ── 1. Branche par défaut et tête (aucun objet téléchargé) ────────────────────
LS="$(net ls-remote --symref "$FETCH_URL" HEAD 2>/dev/null)" || unreachable "dépôt distant injoignable ($APP)"
BRANCH="$(sed -n 's|^ref: refs/heads/\([^[:space:]]*\)[[:space:]]*HEAD$|\1|p' <<< "$LS" | head -1)"
HEAD_SHA="$(awk '$2 == "HEAD" && $1 ~ /^[0-9a-f]{40}$/ { print $1; exit }' <<< "$LS")"
[[ -n "$BRANCH" && -n "$HEAD_SHA" ]] || unreachable "dépôt distant vide ou sans branche par défaut ($APP)"

# ── 2. Écart avec la version déployée ─────────────────────────────────────────
BEHIND="null"
if [[ "$DEPLOYED" != "null" ]]; then
  DEP="${DEPLOYED//\"/}"
  g() { GIT_OPTIONAL_LOCKS=0 git -C "$TMP/repo.git" "$@"; }
  if [[ "$DEP" == "$HEAD_SHA" ]]; then
    BEHIND=0
  else
    # Il faut l'historique de la tête pour compter. S'il n'arrive pas dans le
    # temps imparti, on rend ce qu'on sait (head) et behind reste null.
    if ! g cat-file -e "${HEAD_SHA}^{commit}" 2>/dev/null; then
      net fetch -q --no-tags --no-recurse-submodules "$FETCH_URL" \
          "+refs/heads/${BRANCH}:refs/remote-check/${BRANCH}" > /dev/null 2>&1 \
        || log "historique de ${BRANCH} non récupéré dans le délai — behind inconnu"
    fi
    if g cat-file -e "${HEAD_SHA}^{commit}" 2>/dev/null && g cat-file -e "${DEP}^{commit}" 2>/dev/null \
       && g merge-base --is-ancestor "$DEP" "$HEAD_SHA" 2>/dev/null; then
      _n="$(g rev-list --count "${DEP}..${HEAD_SHA}" 2>/dev/null || true)"
      [[ "$_n" =~ ^[0-9]+$ ]] && BEHIND="$_n"
    else
      log "le SHA déployé (${DEP:0:12}) n'est pas dans l'historique de ${BRANCH} — behind inconnu"
    fi
  fi
fi

emit true "$BRANCH" "$HEAD_SHA" "$BEHIND"
