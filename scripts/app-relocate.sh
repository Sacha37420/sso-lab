#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# app-relocate.sh — déménage UNE app de $ROOT/<app> vers $ROOT/deploiement/<app>.
# Contrat « multi-dev » v5, interface I1.
#
# Usage :
#   bash scripts/app-relocate.sh <app> --yes
#
# Ce que fait le script, sous le verrou de déploiement :
#   • `git mv <app> deploiement/<app>` dans le dépôt parent : le lien de
#     sous-module et le `path` de .gitmodules suivent ; le dossier est RENOMMÉ
#     (mêmes inodes), donc tout ce qu'il contient suit aussi, fichiers ignorés
#     compris (.env, .keycloak-client-opts, node_modules, .heavy-build.sha256) ;
#   • rien n'est commité : .gitmodules et le déplacement restent indexés, le
#     commit du dépôt parent reste à la main du superutilisateur.
# Une app qui n'est pas (encore) un sous-module est simplement déplacée.
#
# Ce que le script NE fait PAS, et qu'il faut savoir avant de le lancer sur une
# app en service — il le rappelle à la fin :
#   • il ne touche à AUCUN conteneur. Ceux qui tournent continuent : un bind
#     mount suit l'inode, pas le chemin, donc un `./backend:/app` déjà monté
#     reste valide après le renommage. Mais leur étiquette
#     com.docker.compose.project.working_dir nomme encore l'ancien chemin ;
#   • le NOM DE PROJET Compose ne change pas (c'est le nom du dossier, <app>,
#     aux deux emplacements) : volumes nommés (<app>_<volume>), réseaux et noms
#     de conteneurs sont conservés, et le prochain `docker compose up` depuis le
#     nouveau chemin reprend le même projet. Il RECRÉE en revanche tout
#     conteneur qui a un bind mount à chemin relatif (./…) ou un `build:` — le
#     chemin absolu résolu a changé —, d'où une coupure le temps du
#     redéploiement ;
#   • il ne corrige pas un chemin ABSOLU écrit en dur dans un compose ou un
#     .env de l'app (${HOST_DEV_ROOT}/<app>/…) : il les signale.
#
# À ne lancer sur une app existante qu'au moment de sa bascule (phase 3),
# suivie d'un `setup2.sh <app> --yes`.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/registry.sh
source "$SCRIPT_DIR/lib/registry.sh"
# shellcheck source=lib/lock.sh
source "$SCRIPT_DIR/lib/lock.sh"
ROOT="$(registry_root)"

log() { echo "$*" >&2; }
die() { echo "✗ app-relocate : $*" >&2; exit 1; }

APP=""; YES=false
for a in "$@"; do
  case "$a" in
    --yes|-y) YES=true ;;
    -*)       die "option inconnue : $a" ;;
    *)        [[ -z "$APP" ]] && APP="$a" || die "argument en trop : $a" ;;
  esac
done
[[ -n "$APP" ]] || { echo "Usage : bash scripts/app-relocate.sh <app> --yes" >&2; exit 2; }
# Nom d'APP au sens strict : ce script ne déplace jamais un dossier du cadriciel.
[[ "$APP" =~ ^[a-z][a-z0-9-]{1,38}[a-z0-9]$ ]] || die "nom d'app invalide : '$APP'"
case "$APP" in
  infra|sso-lab|scripts|runner|chantiers|lab-mcp|lab-admin|workspace|deploiement)
    die "'$APP' est un dossier du cadriciel : il reste à la racine" ;;
esac

SRC="$ROOT/$APP"
DST="$ROOT/deploiement/$APP"
[[ -d "$DST" ]] && die "'$APP' est déjà dans deploiement/ — rien à faire"
[[ -d "$SRC" && ! -L "$SRC" ]] || die "dossier $SRC introuvable"
[[ -f "$SRC/docker-compose.yml" ]] || die "$APP/docker-compose.yml introuvable — ce n'est pas une app"
$YES || die "déplacement de '$APP' vers deploiement/ (index du dépôt parent modifié) : ajouter --yes"

lab_lock_acquire "app-relocate.sh $APP" || exit $?

mkdir -p "$ROOT/deploiement" || die "impossible de créer deploiement/"

if git -C "$ROOT" ls-files --error-unmatch -- "$APP" > /dev/null 2>&1; then
  # Sous-module (ou dossier suivi) : git déplace le dossier, le lien et le
  # `path` de .gitmodules en une fois.
  git -C "$ROOT" mv -- "$APP" "deploiement/$APP" >&2 \
    || die "git mv a échoué — rien n'a été déplacé"
  log "✓ git mv $APP → deploiement/$APP (indexé, non commité)"
else
  mv -- "$SRC" "$DST" || die "déplacement impossible"
  log "✓ $APP déplacé vers deploiement/$APP (le dossier n'était pas suivi par le dépôt parent)"
fi

# Le .gitignore du parent pouvait ignorer « <app>/ » (app jamais enregistrée).
if [[ -f "$ROOT/.gitignore" ]] && grep -qxF "$APP/" "$ROOT/.gitignore"; then
  sed -i "s|^${APP}/\$|deploiement/${APP}/|" "$ROOT/.gitignore"
  log "✓ .gitignore : « $APP/ » → « deploiement/$APP/ »"
fi

# ── Ce qu'il reste à faire, dit explicitement ─────────────────────────────────
[[ "$(registry_app_dir "$APP")" == "$DST" ]] || die "après déplacement, registry_app_dir ne rend pas $DST"
_running="$(docker ps --filter "label=com.docker.compose.project=${APP}" --format '{{.Names}}' 2>/dev/null | tr '\n' ' ')"
# Chemin ABSOLU de l'ancien emplacement écrit en dur (${HOST_DEV_ROOT}/<app> ou
# le chemin réel du dépôt) — pas un simple « /<app>/ » de label Caddy.
_abs="$(grep -lF -e "HOST_DEV_ROOT}/${APP}" -e "HOST_DEV_ROOT/${APP}" -e "${ROOT}/${APP}/" -e "${ROOT}/${APP}\"" \
          "$DST/docker-compose.yml" "$DST/.env" 2>/dev/null | tr '\n' ' ')"
log ""
log "À faire ensuite :"
if [[ -n "$_running" ]]; then
  log "  • conteneurs en service (non touchés) : $_running"
  log "    ils tournent encore sur l'ancien chemin ; redéployer pour les aligner :"
  log "      bash scripts/setup2.sh $APP --yes"
else
  log "  • aucun conteneur en service pour '$APP' : déployer quand voulu (bash scripts/setup2.sh $APP --yes)"
fi
[[ -n "$_abs" ]] && log "  • chemin de l'app peut-être écrit en dur dans : $_abs— à relire avant de redéployer"
log "  • dépôt parent : commit à faire à la main (git status montre le renommage et .gitmodules)"
log "  • lab-admin et le runner lisent /mnt/dev/<app> : tant qu'ils ne connaissent pas deploiement/,"
log "    cette app disparaît de leurs listes et son test de cloisonnement répond []."
echo "$DST"
