#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# work-clone.sh — crée le clone de TRAVAIL d'un projet (ne le met jamais à jour).
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
#   • clone présent → RIEN n'est touché, et AUCUNE commande git n'y est
#     lancée : le développeur écrit son `.git/config`, git l'exécuterait avec
#     les droits du moteur (voir la fin du script). Il fait son `git pull`.
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

# ── Clone déjà là : on n'y lance PLUS RIEN ────────────────────────────────────
# Ce dossier est écrit par le développeur depuis son espace, `.git/config`
# compris. Y lancer git d'ici — même un `git status` — exécute ce que ce fichier
# désigne (core.fsmonitor, filtres smudge/clean, hooks, core.sshCommand…) avec
# les droits de l'appelant : le moteur, qui tient le socket Docker. L'ancienne
# mise à jour en avance rapide (status, fetch avec la clé de déploiement, merge)
# donnait donc à tout développeur un accès root à l'hôte, et la clé de
# déploiement en prime (constaté par le chantier « essai-dev », 2026-10-13).
# Le développeur met son clone à jour lui-même (`git pull`, avec son jeton) ;
# ce script ne fait plus que le créer. Ne jamais réintroduire ici une commande
# git dans un clone existant, quelle que soit la liste d'options « sûres ».
if [[ -L "$CLONE" || ! -d "$CLONE" || -L "$CLONE/.git" || ! -d "$CLONE/.git" ]]; then
  die "$CLONE existe mais n'est pas un dépôt git — rien n'a été touché"
fi
log "· $CLONE existe — laissé tel quel (le développeur le met à jour lui-même : git pull)"
echo "$CLONE"
