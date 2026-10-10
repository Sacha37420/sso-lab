#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# app-sync.sh — aligne $ROOT/<app> sur un commit PRÉSENT SUR origin.
# Contrat « multi-dev » v2, interface I4.
#
# Usage :
#   [LAB_GIT_TOKEN=…] bash scripts/app-sync.sh <app> [<sha>]
#
#   Identifiants, dans cet ordre : la clé de déploiement du dépôt si
#   <LAB_STATE_DIR>/deploy-keys/<app> existe (SSH, lecture seule — aucun jeton
#   n'est alors nécessaire) ; sinon LAB_GIT_TOKEN ; sinon rien (dépôt public).
#
#   `git fetch origin`, puis checkout DÉTACHÉ du commit demandé.
#   Sans <sha> : la tête de la branche par défaut d'origin.
#
# Sortie : le SHA complet (40 hex) du commit déployable, SEUL sur stdout.
#          Tous les messages vont sur stderr.
# Code   : 0 = l'arbre de travail est exactement ce commit ; ≠ 0 = rien n'est
#          garanti déployable (et, sauf mention contraire, rien n'a été modifié).
#
# LA RÈGLE QUE CE SCRIPT TIENT (I4) : « On ne déploie qu'un commit présent sur
# origin. Il n'y a aucun chemin qui déploie un arbre de travail modifié à la
# main. » Concrètement :
#   • un <sha> qui n'est joignable depuis AUCUNE branche d'origin est refusé —
#     y compris s'il existe dans le dépôt local (commit fait à la main dans
#     $ROOT/<app>, jamais poussé) ;
#   • pour une app de développeur, l'arbre est ensuite FORCÉ sur ce commit :
#     toute modification locale de fichier suivi et tout fichier non suivi non
#     ignoré sont supprimés (les fichiers ignorés — .env, .keycloak-client-opts,
#     node_modules — sont conservés) ;
#   • pour une app du SUPERUTILISATEUR, qui développe directement dans
#     $ROOT/<app>, rien n'est jamais écrasé : si l'arbre a des modifications, le
#     script refuse et le dit.
#
# CE QUE LE COMMIT NE PEUT PAS FAIRE : un commit qui SUIT un des fichiers
# réservés au cadriciel (.env, .keycloak-client-opts) est refusé AVANT le
# checkout. Ces fichiers sont ignorés par le .gitignore scaffoldé, mais git
# écrase sans prévenir un fichier ignoré quand le commit qu'on extrait en
# contient un du même nom : un simple `git add -f .keycloak-client-opts` côté
# développeur remplacerait les groupes requis décidés à la création de l'app.
# Même refus pour un chemin SOUS ces noms (« .env/x ») : il transformerait le
# fichier en dossier.
# Le refus doit donc venir avant que l'arbre soit touché, pas après.
#
# Ne touche jamais à l'index du dépôt parent (le lien de sous-module y apparaît
# simplement « modifié » : le commit `chore: bump …` reste au superutilisateur).
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/registry.sh
source "$SCRIPT_DIR/lib/registry.sh"
# shellcheck source=lib/lock.sh
source "$SCRIPT_DIR/lib/lock.sh"
# shellcheck source=lib/git.sh
source "$SCRIPT_DIR/lib/git.sh"

log() { echo "$*" >&2; }
die() { echo "✗ app-sync : $*" >&2; exit 1; }

[[ $# -ge 1 && $# -le 2 ]] || { echo "Usage : bash scripts/app-sync.sh <app> [<sha>]" >&2; exit 2; }
APP="$1"; WANT="${2:-}"

APP_DIR="$(registry_app_dir "$APP")" || die "nom d'app invalide : '$APP'"
[[ -e "$APP_DIR/.git" ]] || die "$APP n'est pas un dépôt git (lancer app-register.sh d'abord)"
if [[ -n "$WANT" && ! "$WANT" =~ ^[0-9a-f]{7,40}$ ]]; then
  die "SHA invalide : '$WANT' (7 à 40 caractères hexadécimaux — pas de nom de branche ni de tag)"
fi

OWNER="$(registry_app_owner "$APP")"
OWNER_IS_SUPERUSER=false
registry_is_superuser "$OWNER" && OWNER_IS_SUPERUSER=true

lab_lock_acquire "app-sync.sh $APP" || exit $?

MODE="$(lab_git_mode_for "$APP")"
g() { lab_git "$MODE" "$APP_DIR" "$@"; }

# Le dépôt doit être CE dossier, pas un parent : sans ce contrôle, un <app>/.git
# cassé ferait opérer git sur le dépôt parent (remontée automatique).
_top="$(g rev-parse --show-toplevel 2>/dev/null || true)"
[[ "$_top" == "$APP_DIR" ]] || die "$APP_DIR n'est pas la racine d'un dépôt git valide"

URL="$(g remote get-url origin 2>/dev/null || true)"
[[ -n "$URL" ]] || die "$APP n'a pas de remote 'origin'"

# ── Superutilisateur : on n'écrase jamais son travail en cours ────────────────
if $OWNER_IS_SUPERUSER; then
  if [[ -n "$(g status --porcelain --untracked-files=no 2>/dev/null)" ]]; then
    die "$APP a des modifications non commitées et appartient au superutilisateur — rien n'a été touché (committer/pousser, ou déployer directement avec setup2.sh)"
  fi
fi

# ── fetch ─────────────────────────────────────────────────────────────────────
# Refspec explicite : seules les BRANCHES d'origin comptent comme « présent sur
# origin » (un tag ou une ref de PR ne rend pas un commit déployable), et
# --prune retire celles qui ont disparu du dépôt distant.
#
# (v5) Clé de déploiement : si <LAB_STATE_DIR>/deploy-keys/<app> existe, le
# dépôt est récupéré par SSH avec elle — aucun jeton GitHub n'est demandé à
# personne. Sinon : LAB_GIT_TOKEN, ou anonyme pour un dépôt public.
DEPLOY_KEY="$(lab_git_deploy_key "$APP" || true)"
SSH_URL=""
if [[ -n "$DEPLOY_KEY" ]]; then
  SSH_URL="$(lab_git_ssh_url "$URL")" || die "clé de déploiement présente, mais l'URL d'origin ($URL) ne se traduit pas en URL SSH"
  mkdir -p "$(registry_state_dir)" 2>/dev/null || true
  log "▶ fetch par clé de déploiement ($APP)"
  if ! lab_git_key "$APP_DIR" "$DEPLOY_KEY" fetch -q --prune --no-tags --no-recurse-submodules \
         "$SSH_URL" '+refs/heads/*:refs/remotes/origin/*' >&2; then
    die "git fetch par clé de déploiement a échoué — clé non enregistrée sur le dépôt, dépôt injoignable, ou clé d'hôte changée"
  fi
else
  log "▶ fetch origin ($APP)"
  if ! g fetch -q --prune --no-tags --no-recurse-submodules origin '+refs/heads/*:refs/remotes/origin/*' >&2; then
    die "git fetch a échoué — dépôt distant injoignable, ou jeton (LAB_GIT_TOKEN) absent/sans droit de lecture"
  fi
fi

# ── Commit visé ───────────────────────────────────────────────────────────────
if [[ -z "$WANT" ]]; then
  # Branche par défaut d'origin, redemandée au dépôt distant (elle peut changer).
  if [[ -n "$DEPLOY_KEY" ]]; then
    # `remote set-head` interrogerait origin par https : on demande la branche
    # par défaut au dépôt par le même transport que le fetch.
    _head_ref="$(lab_git_key "$APP_DIR" "$DEPLOY_KEY" ls-remote --symref "$SSH_URL" HEAD 2>/dev/null \
                 | sed -n 's|^ref: refs/heads/\([^[:space:]]*\)[[:space:]]*HEAD$|\1|p' | head -1)"
    if [[ -n "$_head_ref" ]]; then
      g symbolic-ref refs/remotes/origin/HEAD "refs/remotes/origin/${_head_ref}" 2>/dev/null || true
    fi
  else
    g remote set-head origin --auto > /dev/null 2>&1 || true
  fi
  SHA="$(g rev-parse --verify -q 'refs/remotes/origin/HEAD^{commit}' 2>/dev/null || true)"
  [[ -n "$SHA" ]] || SHA="$(g rev-parse --verify -q 'refs/remotes/origin/main^{commit}' 2>/dev/null || true)"
  [[ -n "$SHA" ]] || die "impossible de déterminer la tête de la branche par défaut d'origin (dépôt distant vide ?)"
else
  SHA="$(g rev-parse --verify -q "${WANT}^{commit}" 2>/dev/null || true)"
  [[ -n "$SHA" ]] || die "commit $WANT absent d'origin — le pousser d'abord (git push)"
  # Présent dans la base d'objets locale ne veut pas dire présent sur origin :
  # il doit être joignable depuis au moins une branche distante.
  if [[ -z "$(g for-each-ref --contains "$SHA" --count=1 --format='%(refname)' refs/remotes/origin 2>/dev/null)" ]]; then
    die "commit $WANT absent d'origin (il n'existe que localement) — le pousser d'abord (git push)"
  fi
fi
[[ "$SHA" =~ ^[0-9a-f]{40}$ ]] || die "SHA résolu inattendu : '$SHA'"

# ── Fichiers réservés au cadriciel : refus AVANT de toucher l'arbre ───────────
_reserved="$(g ls-tree -r --name-only "$SHA" 2>/dev/null \
             | grep -E '^(\.env|\.keycloak-client-opts)(/|$)' | head -5 || true)"
if [[ -n "$_reserved" ]]; then
  die "le commit ${SHA:0:12} suit $(echo "$_reserved" | tr '\n' ' ')— ces fichiers appartiennent au cadriciel et ne doivent pas être dans le dépôt (git rm --cached, puis pousser). Rien n'a été touché."
fi

# ── Checkout détaché ──────────────────────────────────────────────────────────
log "▶ checkout détaché de ${SHA:0:12}"
if $OWNER_IS_SUPERUSER; then
  # Arbre propre (vérifié plus haut) : un checkout simple suffit, et il échoue
  # de lui-même plutôt que d'écraser un fichier non suivi.
  g checkout -q --detach "$SHA" >&2 || die "git checkout a échoué — rien n'est garanti déployable"
else
  g checkout -q -f --detach "$SHA" >&2 || die "git checkout a échoué — rien n'est garanti déployable"
  g reset -q --hard "$SHA" >&2          || die "git reset a échoué — rien n'est garanti déployable"
  # -d : dossiers non suivis ; pas de -x : les fichiers IGNORÉS restent (.env,
  # .keycloak-client-opts, node_modules…).
  g clean -q -fd >&2                    || die "git clean a échoué — rien n'est garanti déployable"
fi

# ── Preuve : l'arbre EST ce commit ────────────────────────────────────────────
[[ "$(g rev-parse HEAD 2>/dev/null)" == "$SHA" ]] || die "HEAD ne vaut pas $SHA après checkout"
if [[ -n "$(g status --porcelain --untracked-files=no 2>/dev/null)" ]]; then
  die "l'arbre de travail diffère encore du commit ${SHA:0:12} après checkout"
fi

log "✓ $APP est sur ${SHA} (présent sur origin)."
echo "$SHA"
