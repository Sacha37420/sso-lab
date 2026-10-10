#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# work-clone.sh — crée ou met à jour le clone de TRAVAIL d'un projet.
# Contrat « multi-dev » v5, interfaces I3/I4.
#
# Usage :
#   [LAB_GIT_TOKEN=…] bash scripts/work-clone.sh <uid> <app>
#
#   Clone :  <LAB_WORK_DIR>/<uid>/<app>     (LAB_WORK_DIR : .env racine ; défaut :
#            « lab-work » à côté du dépôt, soit /home/sacha/lab-work)
#
# Sortie : le chemin du clone, SEUL sur stdout ; messages sur stderr.
# Code   : 0 = le clone existe et est utilisable ; ≠ 0 sinon.
#
# À QUOI IL SERT : c'est le dossier que l'espace de travail du développeur
# monte en /work/<app> (I3). Il est HORS du dépôt du lab : personne n'édite
# deploiement/<app>, qui n'est que ce que le moteur synchronise et déploie.
# Le dev y travaille, pousse sur GitHub, et le moteur déploie le commit poussé.
#
# IDEMPOTENT, ET PRUDENT :
#   • clone absent  → créé depuis l'origin du projet, sur sa branche par défaut ;
#   • clone présent, SANS modification (ni fichier modifié, ni fichier non
#     suivi, ni commit local en avance) → mis à jour en avance rapide ;
#   • clone présent AVEC la moindre modification → RIEN n'est touché, pas même
#     un fetch : c'est le travail en cours de quelqu'un.
#
# Identifiants pour lire le dépôt, dans cet ordre : la clé de déploiement du
# projet (<LAB_STATE_DIR>/deploy-keys/<app>), sinon LAB_GIT_TOKEN, sinon rien
# (dépôt public). Aucun n'est écrit dans le clone : son `origin` est l'URL
# https sans identifiant — c'est avec SON jeton (GH_TOKEN, fourni à l'espace de
# travail) que le dev pousse.
#
# <uid> doit être le propriétaire de l'app, ou le superutilisateur.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/registry.sh
source "$SCRIPT_DIR/lib/registry.sh"
# shellcheck source=lib/git.sh
source "$SCRIPT_DIR/lib/git.sh"
ROOT="$(registry_root)"

log() { echo "$*" >&2; }
die() { echo "✗ work-clone : $*" >&2; exit 1; }

[[ $# -eq 2 ]] || { echo "Usage : bash scripts/work-clone.sh <uid> <app>" >&2; exit 2; }
DEV_UID="$1"; APP="$2"

registry_valid_uid "$DEV_UID" || die "uid invalide : '$DEV_UID'"
[[ "$APP" =~ ^[a-z][a-z0-9-]{1,38}[a-z0-9]$ ]] || die "nom d'app invalide : '$APP'"
APP_DIR="$(registry_app_dir "$APP")" || die "nom d'app invalide : '$APP'"
[[ -e "$APP_DIR/.git" ]] || die "'$APP' n'est pas un projet enregistré (pas de dépôt git dans $(registry_app_relpath "$APP"))"

OWNER="$(registry_app_owner "$APP")"
if [[ "$OWNER" != "$DEV_UID" ]] && ! registry_is_superuser "$DEV_UID"; then
  die "'$APP' n'appartient pas à « $DEV_UID »"
fi
if ! registry_is_superuser "$DEV_UID" && ! registry_is_dev "$DEV_UID"; then
  die "« $DEV_UID » n'est pas un développeur inscrit (.devs)"
fi

WORK_ROOT="${LAB_WORK_DIR:-}"
[[ -n "$WORK_ROOT" ]] || WORK_ROOT="$(registry_root_env LAB_WORK_DIR)"
[[ -n "$WORK_ROOT" ]] || WORK_ROOT="$(dirname "$ROOT")/lab-work"
[[ "$WORK_ROOT" == /* && "$WORK_ROOT" != *..* ]] || die "LAB_WORK_DIR doit être un chemin absolu sans « .. » : '$WORK_ROOT'"
# Le clone de travail ne doit JAMAIS être dans le dépôt du lab : l'espace de
# travail le monte en écriture.
case "$WORK_ROOT/" in "$ROOT"/*) die "LAB_WORK_DIR ($WORK_ROOT) est dans le dépôt du lab — refus" ;; esac

DEV_DIR="$WORK_ROOT/$DEV_UID"
CLONE="$DEV_DIR/$APP"

URL="$(git -C "$APP_DIR" remote get-url origin 2>/dev/null || true)"
[[ -n "$URL" ]] || die "'$APP' n'a pas de remote origin"
lab_git_valid_url "$URL" || die "URL d'origin inattendue pour '$APP'"

# Transport de lecture.
DEPLOY_KEY="$(lab_git_deploy_key "$APP" || true)"
FETCH_URL="$URL"
if [[ -n "$DEPLOY_KEY" ]]; then
  FETCH_URL="$(lab_git_ssh_url "$URL")" || die "URL d'origin non traduisible en URL SSH"
  gitnet() { local d="$1"; shift; lab_git_key "$d" "$DEPLOY_KEY" "$@"; }
else
  gitnet() { local d="$1"; shift; lab_git "isolé" "$d" "$@"; }
fi
REFSPEC='+refs/heads/*:refs/remotes/origin/*'

# 700 : le dossier d'un dev n'est lisible que du compte qui fait tourner le lab.
mkdir -p "$DEV_DIR" && chmod 700 "$WORK_ROOT" "$DEV_DIR" 2>/dev/null || die "impossible de créer $DEV_DIR"

if [[ ! -e "$CLONE" ]]; then
  # ── Création ────────────────────────────────────────────────────────────────
  # init + fetch plutôt que `git clone <url ssh>` : l'origin enregistré doit
  # être l'URL https, pas celle du transport de lecture.
  log "▶ création du clone de travail $CLONE"
  mkdir -p "$CLONE" || die "impossible de créer $CLONE"
  _fail() { log "$1"; mv "$CLONE" "$CLONE.echec.$$" 2>/dev/null; die "clone non créé (reste éventuel : $CLONE.echec.$$)"; }
  git -C "$CLONE" init -q -b main                    || _fail "git init a échoué"
  git -C "$CLONE" remote add origin "$URL"           || _fail "remote add a échoué"
  gitnet "$CLONE" fetch -q --no-tags "$FETCH_URL" "$REFSPEC" >&2 \
    || _fail "lecture du dépôt impossible (clé de déploiement, jeton, ou dépôt injoignable)"
  _branch="$(gitnet "$CLONE" ls-remote --symref "$FETCH_URL" HEAD 2>/dev/null \
             | sed -n 's|^ref: refs/heads/\([^[:space:]]*\)[[:space:]]*HEAD$|\1|p' | head -1)"
  [[ -n "$_branch" ]] || _branch="main"
  git -C "$CLONE" rev-parse --verify -q "refs/remotes/origin/${_branch}" > /dev/null \
    || _fail "branche par défaut '${_branch}' introuvable (dépôt vide ?)"
  git -C "$CLONE" symbolic-ref refs/remotes/origin/HEAD "refs/remotes/origin/${_branch}" 2>/dev/null || true
  git -C "$CLONE" -c advice.detachedHead=false checkout -q -B "$_branch" --track "origin/${_branch}" >&2 \
    || _fail "checkout de '${_branch}' a échoué"
  log "✓ clone créé sur la branche ${_branch} ($(git -C "$CLONE" rev-parse --short HEAD))"
  echo "$CLONE"
  exit 0
fi

# ── Mise à jour ───────────────────────────────────────────────────────────────
[[ "$(git -C "$CLONE" rev-parse --show-toplevel 2>/dev/null || true)" == "$CLONE" ]] \
  || die "$CLONE existe mais n'est pas un dépôt git — rien n'a été touché"

# La moindre modification ⇒ on ne touche à rien.
if [[ -n "$(git -C "$CLONE" status --porcelain 2>/dev/null)" ]]; then
  log "· $CLONE a des modifications en cours — laissé tel quel (ni fetch, ni fusion)"
  echo "$CLONE"; exit 0
fi
_cur="$(git -C "$CLONE" symbolic-ref -q --short HEAD || true)"
if [[ -z "$_cur" ]]; then
  log "· $CLONE est sur un commit détaché — laissé tel quel"
  echo "$CLONE"; exit 0
fi
if [[ -n "$(git -C "$CLONE" rev-list --max-count=1 "refs/remotes/origin/${_cur}..HEAD" 2>/dev/null)" ]]; then
  log "· $CLONE a des commits locaux non poussés sur ${_cur} — laissé tel quel"
  echo "$CLONE"; exit 0
fi

if ! gitnet "$CLONE" fetch -q --no-tags "$FETCH_URL" "$REFSPEC" >&2; then
  log "⚠ lecture du dépôt impossible — clone laissé en l'état ($(git -C "$CLONE" rev-parse --short HEAD))"
  echo "$CLONE"; exit 0
fi
if git -C "$CLONE" rev-parse --verify -q "refs/remotes/origin/${_cur}" > /dev/null; then
  if git -C "$CLONE" merge -q --ff-only "refs/remotes/origin/${_cur}" >&2; then
    log "✓ clone à jour sur ${_cur} ($(git -C "$CLONE" rev-parse --short HEAD))"
  else
    log "· avance rapide impossible sur ${_cur} — clone laissé tel quel"
  fi
else
  log "· la branche ${_cur} n'existe pas sur origin — clone laissé tel quel"
fi
echo "$CLONE"
