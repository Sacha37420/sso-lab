#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# app-register.sh — transforme le dossier scaffoldé d'une app en dépôt git,
#                   le pousse, et l'enregistre comme sous-module du dépôt parent.
# Contrat « multi-dev » v2, interface I4.
#
# Usage :
#   LAB_GIT_AUTHOR_NAME=… LAB_GIT_AUTHOR_EMAIL=… [LAB_GIT_TOKEN=…] \
#     bash scripts/app-register.sh <app> <url_clone>
#
# Enchaîne, sous le verrou de déploiement :
#   1. `git init` (branche main) dans $ROOT/<app> ;
#   2. premier commit — auteur ET committer = LAB_GIT_AUTHOR_NAME / _EMAIL ;
#   3. `git push -u origin main` vers <url_clone> ;
#   4. `git submodule add` dans le dépôt parent.
#
# Sortie : le SHA du premier commit sur stdout (tout le reste sur stderr).
# Code : 0 = fait ; ≠ 0 = échec (le message dit à quelle étape).
#
# RÈGLES GIT (non négociables, I4) :
#   • Le jeton arrive par LAB_GIT_TOKEN et n'est consommé que par GIT_ASKPASS
#     (scripts/lib/git.sh) : jamais dans .git/config, l'URL du remote, un
#     journal ou .owners. <url_clone> est donc une URL https SANS identifiants.
#   • .gitmodules et le lien de sous-module sont laissés INDEXÉS, NON COMMITÉS
#     dans le dépôt parent : les commits du parent restent à la main du
#     superutilisateur (`chore: bump …`).
#   • .env et .keycloak-client-opts ne partent jamais dans le dépôt de l'app
#     (le .gitignore scaffoldé les ignore ; c'est revérifié ici avant le commit).
#
# En cas d'échec après l'étape 1, le .git créé est retiré : la commande peut
# être relancée telle quelle. Un échec à l'étape 4 laisse le dépôt de l'app en
# place (il est déjà poussé) — `scripts/app-remove.sh <app> --yes` défait tout.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/registry.sh
source "$SCRIPT_DIR/lib/registry.sh"
# shellcheck source=lib/lock.sh
source "$SCRIPT_DIR/lib/lock.sh"
# shellcheck source=lib/git.sh
source "$SCRIPT_DIR/lib/git.sh"
ROOT="$(registry_root)"

log() { echo "$*" >&2; }
die() { echo "✗ app-register : $*" >&2; exit 1; }

[[ $# -eq 2 ]] || { echo "Usage : bash scripts/app-register.sh <app> <url_clone>" >&2; exit 2; }
APP="$1"; URL="$2"

APP_DIR="$(registry_app_dir "$APP")" || die "nom d'app invalide : '$APP'"
# Chemin relatif au dépôt parent (« deploiement/<app> » pour une app née après
# la v5) : c'est le chemin du sous-module, de .gitmodules et du .gitignore.
REL="$(registry_app_relpath "$APP")"
[[ -d "$APP_DIR" ]]                    || die "dossier $APP_DIR introuvable (lancer new-app.sh d'abord)"
[[ -f "$APP_DIR/docker-compose.yml" ]] || die "$APP/docker-compose.yml introuvable — ce n'est pas une app scaffoldée"
registry_app_ports "$APP" > /dev/null  || die "'$APP' absente de .ports"
lab_git_valid_url "$URL"               || die "URL de clone refusée : attendu https://hôte/chemin, sans identifiants (« user:jeton@ » interdit)"

NAME="${LAB_GIT_AUTHOR_NAME:-}"; EMAIL="${LAB_GIT_AUTHOR_EMAIL:-}"
[[ -n "$NAME" && -n "$EMAIL" ]] || die "LAB_GIT_AUTHOR_NAME et LAB_GIT_AUTHOR_EMAIL sont requis (auteur du premier commit)"
[[ "$NAME"  != *[$'\n\r<>']* ]]           || die "LAB_GIT_AUTHOR_NAME contient un caractère interdit"
[[ "$EMAIL" =~ ^[^[:space:]\<\>@]+@[^[:space:]\<\>@]+$ ]] || die "LAB_GIT_AUTHOR_EMAIL n'a pas la forme d'une adresse"

lab_lock_acquire "app-register.sh $APP" || exit $?

# ── Étape 0 — rien d'existant à écraser ───────────────────────────────────────
[[ ! -e "$APP_DIR/.git" ]] || die "étape 0 : $APP est déjà un dépôt git — rien n'a été modifié"
if git -C "$ROOT" ls-files --error-unmatch -- "$REL" > /dev/null 2>&1; then
  die "étape 0 : '$APP' est déjà suivi par le dépôt parent — rien n'a été modifié"
fi
if git -C "$ROOT" config -f .gitmodules --get "submodule.${REL}.url" > /dev/null 2>&1; then
  die "étape 0 : '$APP' figure déjà dans .gitmodules — rien n'a été modifié"
fi
# Le .gitignore scaffoldé est ce qui empêche .env de partir : sans lui on refuse.
grep -qxF '.env' "$APP_DIR/.gitignore" 2>/dev/null \
  || die "étape 0 : $APP/.gitignore n'ignore pas .env — refus de committer (secrets)"

# Toute opération sur le dépôt de l'app passe par un git ISOLÉ de la
# configuration de l'hôte (voir scripts/lib/git.sh) : ni l'identité ni les
# identifiants du superutilisateur n'y entrent.
g() { lab_git "isolé" "$APP_DIR" "$@"; }
_undo_init() { rm -rf "$APP_DIR/.git"; }

# ── Étape 1 — git init ────────────────────────────────────────────────────────
log "▶ étape 1/4 : git init ($APP)"
g init -q -b main || { _undo_init; die "étape 1 (git init) a échoué"; }
g add -A          || { _undo_init; die "étape 1 (git add) a échoué"; }

# Garde-fou indépendant du .gitignore : aucun fichier de secrets dans l'index.
_tracked_secret="$(g ls-files -- .env .keycloak-client-opts ':(glob)**/.env' 2>/dev/null | head -5)"
if [[ -n "$_tracked_secret" ]]; then
  _undo_init
  die "étape 1 : ces fichiers ne doivent jamais être suivis par git : $(echo "$_tracked_secret" | tr '\n' ' ')"
fi

# ── Étape 2 — premier commit ──────────────────────────────────────────────────
log "▶ étape 2/4 : premier commit (auteur : $NAME <$EMAIL>)"
GIT_AUTHOR_NAME="$NAME" GIT_AUTHOR_EMAIL="$EMAIL" GIT_COMMITTER_NAME="$NAME" GIT_COMMITTER_EMAIL="$EMAIL" \
  g commit -q -m "feat: initial scaffold" >&2 || { _undo_init; die "étape 2 (commit) a échoué"; }
SHA="$(g rev-parse HEAD)" || { _undo_init; die "étape 2 : SHA illisible"; }

# ── Étape 3 — push ────────────────────────────────────────────────────────────
log "▶ étape 3/4 : push vers $URL"
g remote add origin "$URL" || { _undo_init; die "étape 3 (remote add) a échoué"; }
if ! g push -q -u origin main >&2; then
  _undo_init
  die "étape 3 (git push) a échoué — dépôt distant inexistant, non vide, ou jeton (LAB_GIT_TOKEN) sans droit d'écriture"
fi
# origin/HEAD local : app-sync.sh s'en sert pour connaître la branche par défaut.
g remote set-head origin main > /dev/null 2>&1 || true

# ── Étape 4 — sous-module du dépôt parent ─────────────────────────────────────
log "▶ étape 4/4 : enregistrement comme sous-module de $(basename "$ROOT")"
# new-app.sh avait ajouté « <app>/ » au .gitignore du parent : un chemin ignoré
# ne peut pas devenir un sous-module.
if [[ -f "$ROOT/.gitignore" ]] && grep -qxF "$REL/" "$ROOT/.gitignore"; then
  grep -vxF "$REL/" "$ROOT/.gitignore" > "$ROOT/.gitignore.tmp" || true
  cat "$ROOT/.gitignore.tmp" > "$ROOT/.gitignore"; unlink "$ROOT/.gitignore.tmp"
fi
# Le dossier est déjà un dépôt : `submodule add` ne clone rien, il inscrit
# .gitmodules et le lien dans l'index. Aucun accès réseau, aucun identifiant.
_sub_protocol=()
[[ "${LAB_GIT_ALLOW_FILE:-}" == "1" ]] && _sub_protocol=(-c protocol.file.allow=always)
if ! git -C "$ROOT" "${_sub_protocol[@]+"${_sub_protocol[@]}"}" submodule --quiet add -- "$URL" "$REL" >&2; then
  die "étape 4 (git submodule add) a échoué — le dépôt de l'app est créé et poussé ; pour tout défaire : bash scripts/app-remove.sh $APP --yes"
fi

# « update = none » pour ce sous-module, dans le .gitmodules versionné : le dépôt
# d'un projet peut être PRIVÉ, et un sous-module inaccessible fait avorter
# `git clone --recurse-submodules` du dépôt parent pour TOUT le monde — aucun
# sous-module n'est alors extrait, pas même les publics (éprouvé, git 2.47).
# Avec « update = none », le clone récursif saute celui-ci et extrait les
# autres. Rien dans le lab ne dépend de `git submodule update` pour un projet :
# le moteur synchronise par app-sync.sh, dans le dépôt de l'app. Sur une
# machine neuve, c'est install.sh qui l'extrait (git -c
# submodule.<nom>.update=checkout submodule update --init <chemin>) et qui
# signale, sans s'arrêter, ceux auxquels il n'a pas accès.
git -C "$ROOT" config -f .gitmodules "submodule.${REL}.update" none \
  && git -C "$ROOT" add -- .gitmodules \
  || log "⚠ « update = none » n'a pas pu être posé dans .gitmodules pour $REL"

# Contrôle final : le jeton n'a fuité nulle part où il resterait.
if [[ -n "${LAB_GIT_TOKEN:-}" ]] && grep -rqF -- "$LAB_GIT_TOKEN" "$APP_DIR/.git/config" "$ROOT/.gitmodules" "$ROOT/.git/config" 2>/dev/null; then
  die "le jeton apparaît dans une configuration git — ANOMALIE, à corriger avant tout autre usage"
fi

log "✓ $APP enregistrée : commit $SHA poussé, .gitmodules et lien de sous-module indexés (non commités)."
echo "$SHA"
