# shellcheck shell=bash
# ─────────────────────────────────────────────────────────────────────────────
# scripts/lib/git.sh — git « isolé » pour les dépôts d'apps (à SOURCER, après
# registry.sh). Contrat multi-dev v2, I4 (règles Git).
#
# POURQUOI NE PAS APPELER git TOUT NU : le git de l'hôte est celui du
# superutilisateur. Sa configuration globale porte un assistant d'identifiants
# (`gh auth git-credential`) dont le jeton a les portées `repo` ET
# `delete_repo` sur tous ses dépôts. Un `git push`/`fetch` lancé au nom d'un
# autre développeur ne doit JAMAIS pouvoir s'en servir, ni y enregistrer le
# jeton de ce développeur. D'où, pour toute opération réseau sur le dépôt d'une
# app :
#   • GIT_CONFIG_GLOBAL=/dev/null + GIT_CONFIG_NOSYSTEM=1 : aucune configuration
#     de l'hôte (identité, assistants d'identifiants, réécritures d'URL) ;
#   • credential.helper vide : rien n'est lu ni stocké ;
#   • GIT_ASKPASS = lib/git-askpass.sh : le jeton vient de LAB_GIT_TOKEN, à la
#     demande, et ne touche jamais le disque ni la ligne de commande ;
#   • GIT_TERMINAL_PROMPT=0 : sans jeton, l'opération échoue au lieu d'attendre
#     une saisie que personne ne fera ;
#   • core.hooksPath=/dev/null : aucun hook ne s'exécute ;
#   • GIT_ALLOW_PROTOCOL=https : un dépôt ne peut pas faire sortir git par un
#     autre transport (ssh avec les clés de l'hôte, ext::, file://…).
#
# Exception voulue : une app du SUPERUTILISATEUR, quand aucun LAB_GIT_TOKEN
# n'est fourni, garde la configuration de l'hôte — c'est lui qui lance la
# commande dans son shell, avec ses propres identifiants, comme aujourd'hui.
#
# LAB_GIT_ALLOW_FILE=1 autorise en plus le transport file:// (dépôt « bare »
# local) : réservé aux tests du cadriciel, jamais positionné par le MCP.
# ─────────────────────────────────────────────────────────────────────────────

_LAB_GIT_ASKPASS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/git-askpass.sh"

# URL de clone acceptable : https sans identifiants embarqués (un jeton dans
# l'URL finirait dans .git/config et dans .gitmodules, qui est public).
lab_git_valid_url() {
  local url="${1:-}"
  if [[ "$url" =~ ^https://[A-Za-z0-9][A-Za-z0-9.-]*(:[0-9]+)?/[A-Za-z0-9._~/-]+$ && "$url" != *..* ]]; then
    return 0
  fi
  if [[ "${LAB_GIT_ALLOW_FILE:-}" == "1" && "$url" =~ ^file:///[A-Za-z0-9._/-]+$ && "$url" != *..* ]]; then
    return 0
  fi
  return 1
}

# lab_git <isolé|hôte> <dossier> <args git…>
lab_git() {
  local mode="$1" dir="$2"; shift 2
  local protocols="https"
  [[ "${LAB_GIT_ALLOW_FILE:-}" == "1" ]] && protocols="https:file"
  if [[ "$mode" == "hôte" ]]; then
    GIT_TERMINAL_PROMPT=0 git -C "$dir" "$@"
    return $?
  fi
  [[ -x "$_LAB_GIT_ASKPASS" ]] || { echo "✗ $_LAB_GIT_ASKPASS absent ou non exécutable" >&2; return 1; }
  GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0 \
  GIT_ASKPASS="$_LAB_GIT_ASKPASS" SSH_ASKPASS="" GIT_ALLOW_PROTOCOL="$protocols" \
    git -C "$dir" \
      -c credential.helper= -c core.hooksPath=/dev/null -c core.fsmonitor=false \
      -c "protocol.file.allow=$([[ "$protocols" == *file* ]] && echo always || echo never)" \
      -c advice.detachedHead=false \
      "$@"
}

# Mode à utiliser pour les opérations réseau sur le dépôt d'une app.
lab_git_mode_for() {
  local app="$1"
  if [[ -z "${LAB_GIT_TOKEN:-}" ]] && registry_is_superuser "$(registry_app_owner "$app")"; then
    echo "hôte"
  else
    echo "isolé"
  fi
}

# ── Clé de déploiement par dépôt (contrat v5, I4) ─────────────────────────────
# <LAB_STATE_DIR>/deploy-keys/<app> : clé SSH PRIVÉE (600), déposée par le
# moteur à la création du projet ; sa moitié publique est enregistrée sur le
# dépôt GitHub EN LECTURE SEULE. Quand elle existe, le lab récupère le dépôt
# par SSH avec elle : un déploiement ne demande plus le jeton GitHub de
# personne (bouton de lab-admin, MCP depuis un espace de travail, déploiement
# automatique fonctionnent pareil).
#
# L'URL d'origin reste l'URL https enregistrée (celle de .gitmodules, publique
# et sans identifiant) ; l'URL SSH en est DÉDUITE au moment du fetch et n'est
# écrite nulle part.
#
# ssh est lancé sans rien de l'hôte : ni ~/.ssh/config, ni agent, ni autre clé
# que celle-ci (IdentitiesOnly). Les clés d'hôte connues vivent dans
# <LAB_STATE_DIR>/known_hosts ; un hôte jamais vu est accepté à sa première
# connexion (accept-new), un hôte dont la clé CHANGE est refusé.

lab_git_deploy_key() {  # imprime le chemin de la clé si elle existe ; code 1 sinon
  local key; key="$(registry_state_dir)/deploy-keys/${1:-}"
  [[ -f "$key" && ! -L "$key" ]] || return 1
  printf '%s\n' "$key"
}

# https://hôte/chemin(.git)  →  ssh://git@hôte/chemin(.git)
# LAB_GIT_DEPLOY_URL (tests du cadriciel uniquement, jamais posée par le
# moteur) impose l'URL SSH — pour un dépôt servi par un sshd local jetable.
lab_git_ssh_url() {
  local url="${1:-}"
  if [[ -n "${LAB_GIT_DEPLOY_URL:-}" ]]; then
    [[ "$LAB_GIT_DEPLOY_URL" =~ ^ssh://[A-Za-z0-9._-]+@[A-Za-z0-9.-]+(:[0-9]+)?/[A-Za-z0-9._~/-]+$ ]] || return 1
    printf '%s\n' "$LAB_GIT_DEPLOY_URL"; return 0
  fi
  [[ "$url" =~ ^https://([A-Za-z0-9][A-Za-z0-9.-]*)(:[0-9]+)?/([A-Za-z0-9._~/-]+)$ ]] || return 1
  printf 'ssh://git@%s/%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[3]}"
}

# lab_git_key <dossier> <clé> <args git…> : git isolé, transport SSH avec CETTE clé.
lab_git_key() {
  local dir="$1" key="$2"; shift 2
  local kh; kh="$(registry_state_dir)/known_hosts"
  command -v ssh > /dev/null || { echo "✗ ssh introuvable — requis pour une clé de déploiement" >&2; return 1; }
  # ssh refuse une clé lisible par d'autres ; autant le dire nous-mêmes.
  if [[ "$(stat -c %a "$key" 2>/dev/null)" != "600" && "$(stat -c %a "$key" 2>/dev/null)" != "400" ]]; then
    echo "✗ clé de déploiement $key : mode $(stat -c %a "$key" 2>/dev/null) — 600 attendu" >&2; return 1
  fi
  GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0 \
  GIT_ASKPASS=/bin/false SSH_ASKPASS="" GIT_ALLOW_PROTOCOL="ssh" \
  GIT_SSH_COMMAND="ssh -F /dev/null -i '$key' -o IdentitiesOnly=yes -o IdentityAgent=none -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile='$kh' -o GlobalKnownHostsFile=/dev/null -o ConnectTimeout=20" \
    git -C "$dir" \
      -c credential.helper= -c core.hooksPath=/dev/null -c core.fsmonitor=false \
      -c advice.detachedHead=false \
      "$@"
}
