# shellcheck shell=bash
# ─────────────────────────────────────────────────────────────────────────────
# scripts/lib/registry.sh — registre des développeurs et des apps (à SOURCER).
#
# Contrat « multi-dev » v2, interface I1. Trois fichiers à la racine du dépôt,
# tous gitignorés (ils associent des personnes à leurs projets, le dépôt parent
# est public) :
#
#   .devs     une ligne par développeur inscrit :   <uid>
#   .owners   une ligne par app :                   <app>:<uid>
#   .ports    inchangé :                            <app>:<port_backend>:<port_frontend>
#
# Règles structurantes :
#   • (v5) Toute app déployée vit dans $ROOT/deploiement/<app>, sous-module du
#     dépôt parent, quel que soit son propriétaire. Pendant la transition, une
#     app historique reste dans $ROOT/<app> jusqu'à sa bascule (app-relocate.sh) :
#     registry_app_dir rend deploiement/<app> s'il existe, sinon $ROOT/<app>.
#     Les nouvelles apps naissent dans deploiement/ (registry_deploy_dir).
#   • Une app absente de .owners appartient au superutilisateur : un clone neuf
#     du dépôt reste fonctionnel sans aucun de ces fichiers.
#   • Le superutilisateur est une CLÉ DE CONFIGURATION (LAB_SUPERUSER, .env
#     racine, défaut « sacha ») — jamais déduit d'un groupe LDAP : e2e_member
#     est membre de `admins` et de `developers`.
#   • Être dans .devs est la SEULE définition de « développeur inscrit ».
#
# Fonctions publiques (I1) :
#   registry_app_owner <app>      → uid du propriétaire (superutilisateur par défaut)
#   registry_app_dir <app>        → chemin absolu du dossier de l'app
#   registry_apps_of <uid>        → une app par ligne
#   registry_is_dev <uid>         → code 0/1
#   registry_is_superuser <uid>   → code 0/1
#
# Fonctions annexes (même fichier pour qu'il n'y ait qu'un seul endroit qui
# sache lire ces formats) :
#   registry_root · registry_superuser · registry_state_dir ·
#   registry_valid_uid · registry_valid_app · registry_app_ports ·
#   registry_all_apps · registry_root_env
#
# Ce fichier ne fait AUCUN `set -e`/`set -u` : il est sourcé par des scripts
# aux réglages différents (set -euo, set -uo…), il doit se comporter pareil
# partout. Toutes les fonctions sont donc écrites pour être sûres sous `set -eu`.
# ─────────────────────────────────────────────────────────────────────────────

# Racine du dépôt = parent de scripts/ (ce fichier vit dans scripts/lib/).
_REGISTRY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

registry_root() { printf '%s\n' "$_REGISTRY_ROOT"; }

# Lecture d'une clé du .env racine (dernière occurrence, commentaire de fin de
# ligne et guillemets retirés). Vide si absente.
registry_root_env() {
  local key="$1" file="$_REGISTRY_ROOT/.env" val=""
  if [[ -f "$file" ]]; then
    val="$(grep -E "^${key}[[:space:]]*=" "$file" 2>/dev/null | tail -1 | cut -d= -f2- \
           | sed -e 's/[[:space:]]*#.*$//' -e "s/^[[:space:]]*['\"]\{0,1\}//" -e "s/['\"]\{0,1\}[[:space:]]*$//" || true)"
  fi
  printf '%s\n' "$val"
}

# Superutilisateur : variable d'environnement > .env racine > « sacha ».
registry_superuser() {
  local su="${LAB_SUPERUSER:-}"
  [[ -n "$su" ]] || su="$(registry_root_env LAB_SUPERUSER)"
  printf '%s\n' "${su:-sacha}"
}

# Dossier d'état local (verrou de déploiement, clés de déploiement, SHA
# déployés — I4), gitignoré.
registry_state_dir() {
  local d="${LAB_STATE_DIR:-}"
  [[ -n "$d" ]] || d="$(registry_root_env LAB_STATE_DIR)"
  printf '%s\n' "${d:-$_REGISTRY_ROOT/.lab-state}"
}

# <uid> : identique au uid LDAP, au preferred_username Keycloak et au nom du
# compte Unix — aucune table de correspondance (I1).
registry_valid_uid() { [[ "${1:-}" =~ ^[a-z][a-z0-9]{1,30}$ ]]; }

# Nom utilisable comme dossier de $ROOT. Volontairement plus large que la règle
# de nommage des NOUVELLES apps (check-app-name.sh) : les scripts existants
# passent aussi « infra », « sso-lab », « runner » par ici. Ce garde-fou ne
# sert qu'à une chose : qu'aucun nom ne puisse sortir de $ROOT (« .. », « / »).
registry_valid_app() { [[ "${1:-}" =~ ^[a-z0-9][a-z0-9_-]{0,62}$ ]]; }

# Dossier commun des apps déployées (v5), et sous-dossier d'une app qui y naît.
registry_deploy_root() { printf '%s/deploiement\n' "$_REGISTRY_ROOT"; }
registry_deploy_dir() {
  registry_valid_app "${1:-}" || return 1
  printf '%s/deploiement/%s\n' "$_REGISTRY_ROOT" "$1"
}

# Chemin du dossier d'une app : $ROOT/deploiement/<app> s'il existe, sinon
# $ROOT/<app> (app historique pas encore déménagée, ou dossier du cadriciel :
# infra, sso-lab, runner…). N'exige PAS que le dossier existe ; échoue (code 1,
# rien sur stdout) sur un nom qui pourrait sortir de $ROOT.
registry_app_dir() {
  local app="${1:-}"
  registry_valid_app "$app" || return 1
  if [[ -d "$_REGISTRY_ROOT/deploiement/$app" ]]; then
    printf '%s\n' "$_REGISTRY_ROOT/deploiement/$app"
  else
    printf '%s\n' "$_REGISTRY_ROOT/$app"
  fi
}

# Chemin d'une app RELATIF à $ROOT (« deploiement/<app> » ou « <app> ») : c'est
# sous cette forme que git, .gitmodules et le .gitignore du parent la nomment.
registry_app_relpath() {
  local dir; dir="$(registry_app_dir "${1:-}")" || return 1
  printf '%s\n' "${dir#"$_REGISTRY_ROOT"/}"
}

# Tous les dossiers qui portent un fichier donné (docker-compose.yml, .env…),
# aux DEUX emplacements : $ROOT/<x>/ et $ROOT/deploiement/<x>/. C'est par ici
# que passent les scripts qui parcouraient « $ROOT/*/ » : sans ça, une app née
# dans deploiement/ serait invisible du déploiement « tout le lab », de
# reset_url.sh, de ensure-schemas.sh… Triés par nom de dossier.
#   registry_dirs_with docker-compose.yml   → un chemin de DOSSIER par ligne
registry_dirs_with() {
  local file="$1" d
  for d in "$_REGISTRY_ROOT"/*/ "$_REGISTRY_ROOT"/deploiement/*/; do
    d="${d%/}"
    [[ -f "$d/$file" ]] || continue
    case "$d" in "$_REGISTRY_ROOT/_templates"|"$_REGISTRY_ROOT/deploiement") continue ;; esac
    printf '%s\n' "$d"
  done | sort -u
  return 0
}

# Propriétaire d'une app : ligne « <app>:<uid> » de .owners, sinon le
# superutilisateur. Une app INCONNUE appartient donc au superutilisateur — c'est
# le défaut sûr : un contrôle « propriétaire == appelant » refuse tout dev.
registry_app_owner() {
  local app="${1:-}" owner=""
  registry_valid_app "$app" || return 1
  if [[ -f "$_REGISTRY_ROOT/.owners" ]]; then
    owner="$(awk -F: -v a="$app" '$0 !~ /^[[:space:]]*(#|$)/ && $1 == a { o = $2 } END { if (o != "") print o }' \
             "$_REGISTRY_ROOT/.owners" 2>/dev/null || true)"
  fi
  # Une ligne .owners dont l'uid est malformé ne donne de droits à personne.
  if [[ -n "$owner" ]] && registry_valid_uid "$owner"; then
    printf '%s\n' "$owner"
  else
    registry_superuser
  fi
}

# Vrai si l'app a une ligne explicite dans .owners.
registry_has_owner_line() {
  local app="${1:-}"
  [[ -f "$_REGISTRY_ROOT/.owners" ]] || return 1
  awk -F: -v a="$app" '$0 !~ /^[[:space:]]*(#|$)/ && $1 == a { f = 1 } END { exit f ? 0 : 1 }' "$_REGISTRY_ROOT/.owners"
}

# Ports d'une app : « <backend> <frontend> » (champs vides possibles).
# Code 1 si l'app est absente de .ports.
registry_app_ports() {
  local app="${1:-}"
  [[ -f "$_REGISTRY_ROOT/.ports" ]] || return 1
  awk -F: -v a="$app" '$0 !~ /^[[:space:]]*(#|$)/ && $1 == a { print $2 " " $3; f = 1 } END { exit f ? 0 : 1 }' \
    "$_REGISTRY_ROOT/.ports" | tail -1
  return "${PIPESTATUS[0]}"
}

# Toutes les apps : une entrée de .ports dont le dossier contient un
# docker-compose.yml (même définition que lab-admin et le runner — cf.
# CLAUDE.md, « Vitrine publique vs outils d'administration »). Les entrées
# d'infrastructure (__keycloak__…) et les services annexes sans dossier
# (robot-lab-engine…) sont donc exclus d'office.
registry_all_apps() {
  [[ -f "$_REGISTRY_ROOT/.ports" ]] || return 0
  local app
  while IFS=: read -r app _; do
    [[ -z "$app" || "$app" == \#* ]] && continue
    registry_valid_app "$app" || continue
    [[ -f "$(registry_app_dir "$app")/docker-compose.yml" ]] && printf '%s\n' "$app"
  done < "$_REGISTRY_ROOT/.ports" | sort -u
  return 0
}

# Apps d'un développeur. Pour le superutilisateur : toutes celles qui n'ont pas
# d'autre propriétaire (donc aussi celles sans ligne .owners).
registry_apps_of() {
  local uid="${1:-}" app
  registry_valid_uid "$uid" || return 1
  while IFS= read -r app; do
    [[ "$(registry_app_owner "$app")" == "$uid" ]] && printf '%s\n' "$app"
  done < <(registry_all_apps)
  return 0
}

registry_is_dev() {
  local uid="${1:-}"
  registry_valid_uid "$uid" || return 1
  [[ -f "$_REGISTRY_ROOT/.devs" ]] || return 1
  grep -qxF -- "$uid" "$_REGISTRY_ROOT/.devs"
}

registry_is_superuser() {
  local uid="${1:-}"
  [[ -n "$uid" && "$uid" == "$(registry_superuser)" ]]
}

# ── Déploiement enregistré ────────────────────────────────────────────────────
# « Le commit qui TOURNE » n'est pas « le commit extrait dans le dossier de
# l'app » : après un app-sync.sh suivi d'un déploiement refusé ou raté, l'arbre
# porte un commit qui n'a jamais été déployé. Le déploiement est donc ENREGISTRÉ
# au moment où il réussit (setup_unit.sh), dans
#     <LAB_STATE_DIR>/deployed/<app>.json
#     {"sha": "<40 hex>|null", "at": "<ISO 8601>",
#      "tests": {"backend": "<résultat>", "cloisonnement": "<résultat>"}}
# Résultats : "ok" · "ko" · "absent" (aucun test trouvé) · "non-lancé".
# C'est ce fichier que rend app-status.sh.
_registry_deployed_file() { printf '%s/deployed/%s.json\n' "$(registry_state_dir)" "$1"; }

# registry_record_deployed <app> <backend> <cloisonnement>
# À appeler après un déploiement réussi (puis de nouveau quand le test de
# cloisonnement a rendu son verdict : le SHA et la date d'origine sont gardés
# si l'on passe « - » comme résultat backend).
registry_record_deployed() {
  local app="${1:-}" backend="${2:-non-lancé}" cloison="${3:-non-lancé}" dir file sha="null" at tmp
  dir="$(registry_app_dir "$app")" || return 1
  file="$(_registry_deployed_file "$app")"
  command -v jq > /dev/null || return 1
  mkdir -p "$(dirname "$file")" || return 1
  tmp="$(mktemp "$file.XXXXXX")" || return 1
  if [[ "$backend" == "-" && -f "$file" ]]; then
    # Mise à jour du seul verdict de cloisonnement.
    jq -c --arg c "$cloison" '.tests.cloisonnement = $c' "$file" > "$tmp" && mv "$tmp" "$file"
    return $?
  fi
  [[ "$backend" == "-" ]] && backend="non-lancé"
  if [[ "$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null || true)" == "$dir" ]]; then
    sha="$(git -C "$dir" rev-parse HEAD 2>/dev/null || true)"
    [[ "$sha" =~ ^[0-9a-f]{40}$ ]] && sha="\"$sha\"" || sha="null"
  fi
  at="$(date -Iseconds)"
  jq -n -c --argjson sha "$sha" --arg at "$at" --arg b "$backend" --arg c "$cloison" \
     '{sha: $sha, at: $at, tests: {backend: $b, cloisonnement: $c}}' > "$tmp" && mv "$tmp" "$file"
}

# Contenu JSON du dernier déploiement réussi ; code 1 (rien) s'il n'y en a pas.
registry_deployed_json() {
  local file
  registry_valid_app "${1:-}" || return 1
  file="$(_registry_deployed_file "$1")"
  [[ -s "$file" ]] && jq -c . "$file" 2>/dev/null
}

registry_forget_deployed() {
  local file; file="$(_registry_deployed_file "${1:-}")"
  if [[ -f "$file" ]]; then unlink "$file" 2>/dev/null || true; fi
  # ancien format (v4) : un fichier sans extension
  if [[ -f "${file%.json}" ]]; then unlink "${file%.json}" 2>/dev/null || true; fi
  return 0
}
