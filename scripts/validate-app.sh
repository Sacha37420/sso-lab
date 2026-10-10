#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# validate-app.sh — contrôle de sûreté du contenu du dépôt d'une app.
# Contrat « multi-dev » v2, interface I4.
#
# Usage :
#   bash scripts/validate-app.sh <app> [--compose-file <fichier>]
#
# Sortie : code 0 = accepté (avertissements éventuels sur stderr) ;
#          code 1 = refusé, UNE RAISON PAR LIGNE sur stdout, chacune préfixée
#                   d'un code stable entre crochets ([privileged], [bind]…) ;
#          code 2 = erreur d'usage.
#
# POURQUOI : le compte hôte d'un développeur n'a pas accès à Docker, mais son
# dépôt est déployé POUR lui par setup2.sh. Sans ce contrôle, un
# docker-compose.yml libre vaut un accès root à l'hôte. C'est ce script — pas
# l'absence du groupe `docker` — qui tient la promesse « sans Docker ».
# setup2.sh/setup_unit.sh l'appellent pour toute app dont le propriétaire n'est
# pas le superutilisateur ; un refus ⇒ rien n'est lancé.
#
# Toutes les règles sont évaluées (pas d'arrêt au premier refus). Ce qui est
# contrôlé :
#   1. le dépôt : arbre de travail identique à un commit présent sur origin,
#      .env et .keycloak-client-opts non suivis par git, aucun lien symbolique
#      suivi qui sorte du dossier ;
#   2. les fichiers du cadriciel : .keycloak-client-opts (présent, écrit par
#      new-app.sh, --require-group obligatoire), .keycloak-service-account-roles
#      (vide ou absent), .env (base et rôle du propriétaire, pas de COMPOSE_*) ;
#   3. le modèle Compose résolu (scripts/lib/validate_compose.py, liste blanche).
#
# PORTES DE QUALITÉ (contrat v5, I4/I8) — refus, pas avertissement :
#   [feuille-de-route]  FEUILLE_DE_ROUTE.md absent, ou sans aucun lot au format
#                       « ## Lot <N> — <titre>   ·   statut : à faire | en cours | livré » ;
#   [cloisonnement]     l'app a un frontend (dossier frontend/) mais pas de
#                       frontend/e2e/cloisonnement.spec.ts.
#
# --quality-only : n'évalue QUE ces portes (pas le contrôle de sûreté du dépôt
#   ni du Compose). Pour une app du SUPERUTILISATEUR créée après le chantier :
#   il a Docker, le contrôle de sûreté ne le concerne pas, mais les règles de
#   développement s'appliquent à tous.
#
# --compose-file <fichier> : contrôle CE fichier comme s'il était le
#   docker-compose.yml de l'app (même dossier de projet). Sert aux tests du
#   cadriciel (un compose par cas interdit) ; setup2.sh ne le passe jamais.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/registry.sh
source "$SCRIPT_DIR/lib/registry.sh"
# shellcheck source=lib/git.sh
source "$SCRIPT_DIR/lib/git.sh"
ROOT="$(registry_root)"

APP=""; COMPOSE_OVERRIDE=""; QUALITY_ONLY=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --compose-file) [[ $# -gt 1 ]] || { echo "--compose-file requiert un chemin" >&2; exit 2; }; COMPOSE_OVERRIDE="$2"; shift ;;
    --quality-only) QUALITY_ONLY=true ;;
    -*) echo "Option inconnue : $1" >&2; exit 2 ;;
    *)  [[ -z "$APP" ]] && APP="$1" || { echo "Argument en trop : $1" >&2; exit 2; } ;;
  esac
  shift
done
[[ -n "$APP" ]] || { echo "Usage : bash scripts/validate-app.sh <app> [--compose-file <fichier>]" >&2; exit 2; }

REASONS=()
refuse() { REASONS+=("[$1] $2"); }
warn()   { echo "avertissement : $*" >&2; }
finish() {
  if [[ ${#REASONS[@]} -gt 0 ]]; then
    printf '%s\n' "${REASONS[@]}" | sort -u
    exit 1
  fi
  exit 0
}

APP_DIR="$(registry_app_dir "$APP")" || { echo "[app] nom d'app invalide : '$APP'"; exit 1; }
[[ -d "$APP_DIR" && ! -L "$APP_DIR" ]] || { echo "[app] dossier $APP introuvable"; exit 1; }

OWNER="$(registry_app_owner "$APP")"
SUPERUSER="$(registry_superuser)"
COMPOSE="$APP_DIR/docker-compose.yml"
[[ -n "$COMPOSE_OVERRIDE" ]] && COMPOSE="$COMPOSE_OVERRIDE"
if [[ ! -f "$COMPOSE" || -L "$COMPOSE" ]]; then
  echo "[compose] $(basename "$COMPOSE") absent, ou lien symbolique"; exit 1
fi
# ── Portes de qualité (I8) ────────────────────────────────────────────────────
quality_gates() {
  local fdr="$APP_DIR/FEUILLE_DE_ROUTE.md"
  if [[ ! -f "$fdr" || -L "$fdr" ]]; then
    refuse feuille-de-route "FEUILLE_DE_ROUTE.md absent à la racine du dépôt — toute app a sa feuille de route (gabarit : _templates/regles/)"
  elif ! grep -qE '^## Lot [0-9]+ — .+·[[:space:]]*statut : (à faire|en cours|livré)[[:space:]]*$' "$fdr"; then
    refuse feuille-de-route "FEUILLE_DE_ROUTE.md ne contient aucun lot au format « ## Lot <N> — <titre>   ·   statut : à faire | en cours | livré »"
  fi
  if [[ -d "$APP_DIR/frontend" && ! -f "$APP_DIR/frontend/e2e/cloisonnement.spec.ts" ]]; then
    refuse cloisonnement "frontend/e2e/cloisonnement.spec.ts absent — une app avec frontend a son test de cloisonnement (à copier de _templates/django-angular/frontend/e2e/)"
  fi
}
if $QUALITY_ONLY; then
  quality_gates
  finish
fi

_env_val() { grep -E "^$1=" "$APP_DIR/.env" 2>/dev/null | tail -1 | cut -d= -f2- | sed -e 's/[[:space:]]*#.*$//' -e "s/^['\"]//" -e "s/['\"]\$//" || true; }

# ── 1. Le dépôt ───────────────────────────────────────────────────────────────
g() { lab_git "isolé" "$APP_DIR" "$@"; }
if [[ "$(g rev-parse --show-toplevel 2>/dev/null || true)" != "$APP_DIR" ]]; then
  refuse git "$APP n'est pas un dépôt git — seul un commit poussé sur origin est déployable (app-register.sh puis app-sync.sh)"
else
  # .env et .keycloak-client-opts : écrits par le cadriciel, jamais par un push.
  _tracked="$(g ls-files -- .env .keycloak-client-opts 2>/dev/null)"
  while IFS= read -r _f; do
    [[ -n "$_f" ]] && refuse tracked "$_f est suivi par git — il appartient au cadriciel (git rm --cached $_f)"
  done <<< "$_tracked"

  # « On ne déploie qu'un commit présent sur origin » : HEAD doit être joignable
  # depuis une branche d'origin, et l'arbre ne doit pas s'en écarter. Contrôle
  # local (pas de fetch ici) : app-sync.sh vient de mettre les refs à jour.
  _head="$(g rev-parse HEAD 2>/dev/null || true)"
  if [[ -z "$_head" ]]; then
    refuse git "le dépôt n'a aucun commit"
  elif [[ -z "$(g for-each-ref --contains "$_head" --count=1 --format='%(refname)' refs/remotes/origin 2>/dev/null)" ]]; then
    refuse git "le commit extrait (${_head:0:12}) n'est présent sur aucune branche d'origin — lancer app-sync.sh"
  fi
  # --compose-file : l'arbre n'est pas ce qu'on contrôle, on ne le juge pas.
  if [[ -z "$COMPOSE_OVERRIDE" && -n "$(g status --porcelain --untracked-files=no 2>/dev/null)" ]]; then
    refuse git "l'arbre de travail a été modifié par rapport au commit extrait — lancer app-sync.sh"
  fi

  # Liens symboliques suivis : `build: ./backend` où backend → ../sso-lab
  # enverrait le dossier d'une autre app (et son .env) dans le contexte de build.
  while IFS= read -r _link; do
    [[ -n "$_link" ]] || continue
    _target="$(readlink -- "$APP_DIR/$_link" 2>/dev/null || true)"
    _real="$(realpath -m -- "$APP_DIR/$(dirname "$_link")/$_target" 2>/dev/null || true)"
    if [[ "$_target" == /* || -z "$_real" || ( "$_real" != "$APP_DIR" && "$_real" != "$APP_DIR"/* ) ]]; then
      refuse symlink "lien symbolique « $_link » → « $_target » : sort du dossier de l'app"
    fi
  done < <(g ls-files -s 2>/dev/null | awk '$1 == "120000" { sub(/^[^\t]*\t/, ""); print }')
fi

# ── 2. Fichiers du cadriciel ──────────────────────────────────────────────────
# .ports : la ligne de l'app donne les SEULS ports qu'elle peut publier.
PORTS_CSV=""
if _ports="$(registry_app_ports "$APP")"; then
  PORTS_CSV="$(echo "$_ports" | tr -s ' ' ',' | sed 's/^,//; s/,$//')"
else
  refuse ports "'$APP' n'a pas de ligne dans .ports"
fi

# .keycloak-client-opts : ignoré par le .gitignore scaffoldé, il n'existe que
# dans $ROOT/<app>, écrit par new-app.sh. On le contrôle là où il est. Chaque
# option y est vérifiée, parce que le fichier est passé tel quel en arguments à
# create-app-client.sh.
OPTS_FILE="$APP_DIR/.keycloak-client-opts"
if [[ ! -f "$OPTS_FILE" || -L "$OPTS_FILE" ]]; then
  refuse require-group ".keycloak-client-opts absent — sans --require-group l'app accepterait tout compte du realm"
else
  _opts=()
  while IFS= read -r _l || [[ -n "$_l" ]]; do
    [[ -z "$_l" || "$_l" == \#* ]] && continue
    # shellcheck disable=SC2206
    _opts+=( $_l )
  done < "$OPTS_FILE"
  _has_group=false; _i=0
  while (( _i < ${#_opts[@]} )); do
    _o="${_opts[$_i]}"; _v="${_opts[$((_i + 1))]:-}"
    case "$_o" in
      --public) ;;
      --port)
        [[ ",$PORTS_CSV," == *",$_v,"* ]] || refuse client-opts ".keycloak-client-opts : --port $_v n'est pas un port de la ligne .ports de l'app"
        _i=$((_i + 1)) ;;
      --caddy-path)
        [[ "$_v" == "$APP" ]] || refuse client-opts ".keycloak-client-opts : --caddy-path $_v ≠ $APP"
        _i=$((_i + 1)) ;;
      --require-group)
        if [[ "$_v" =~ ^[A-Za-z0-9_-]+(,[A-Za-z0-9_-]+)*$ ]]; then _has_group=true
        else refuse require-group ".keycloak-client-opts : --require-group sans groupe valide"; fi
        _i=$((_i + 1)) ;;
      *) refuse client-opts ".keycloak-client-opts : option « $_o » non autorisée pour l'app d'un développeur" ;;
    esac
    _i=$((_i + 1))
  done
  $_has_group || refuse require-group ".keycloak-client-opts ne contient pas --require-group <groupe> — l'app accepterait tout compte du realm"
fi

# .keycloak-service-account-roles : chaque ligne est un rôle realm-management
# donné au compte de service de l'app — donc l'administration du realm. Vide
# (compte de service sans rôle, pour appeler storage) reste permis.
SA_FILE="$APP_DIR/.keycloak-service-account-roles"
if [[ -L "$SA_FILE" ]]; then
  refuse service-account ".keycloak-service-account-roles est un lien symbolique"
elif [[ -e "$SA_FILE" ]] && grep -q '[^[:space:]]' "$SA_FILE" 2>/dev/null; then
  refuse service-account ".keycloak-service-account-roles n'est pas vide — il donnerait des rôles realm-management (administration du realm)"
fi

# .env : écrit par new-app.sh / create-app-client.sh / reset_url.sh, et par
# app-env.sh pour les seules clés libres.
ENV_FILE="$APP_DIR/.env"
if [[ ! -f "$ENV_FILE" || -L "$ENV_FILE" ]]; then
  refuse env ".env absent (ou lien symbolique) dans $APP/"
else
  if grep -qE '^(COMPOSE_|DOCKER_)[A-Z_]*=' "$ENV_FILE"; then
    refuse env ".env contient une clé COMPOSE_*/DOCKER_* (elle changerait le projet ou le fichier Compose utilisé)"
  fi
  _cid="$(_env_val KEYCLOAK_CLIENT_ID)"
  [[ -z "$_cid" || "$_cid" == "$APP" ]] || refuse env ".env : KEYCLOAK_CLIENT_ID=$_cid ≠ $APP"
  # Base par développeur (I2) : l'app d'un dev ne désigne que SA base, SON rôle.
  if [[ "$OWNER" != "$SUPERUSER" ]] && grep -qE '^DB_(NAME|USER|HOST)=' "$ENV_FILE"; then
    _h="$(_env_val DB_HOST)"; _n="$(_env_val DB_NAME)"; _u="$(_env_val DB_USER)"
    case "$_h" in
      postgres) _want="dev_${OWNER}" ;;
      postgis)  _want="gis_${OWNER}" ;;
      *)        _want=""; refuse env ".env : DB_HOST=$_h (attendu : postgres ou postgis)" ;;
    esac
    [[ -z "$_want" || "$_n" == "$_want" ]] || refuse env ".env : DB_NAME=$_n au lieu de $_want (base du propriétaire « $OWNER »)"
    [[ "$_u" == "dev_${OWNER}" ]]        || refuse env ".env : DB_USER=$_u au lieu de dev_${OWNER}"
  fi
fi

# ── 3. Modèle Compose résolu ──────────────────────────────────────────────────
# `docker compose config` ne lance rien : il lit, interpole et normalise.
#   --no-env-resolution : garde les chemins `env_file` (à contrôler) et évite que
#                         les valeurs des .env traversent ce script ;
#   --profile '*'       : les services sous profil sont contrôlés aussi.
_tmp="$(mktemp -d)"; trap 'rm -rf "$_tmp"' EXIT
# Le domaine du lab, tel que le .env racine le déclare (source de vérité de
# reset_url.sh). Il est IMPOSÉ à l'interpolation (une variable d'environnement
# prime sur le .env de l'app) : DOMAIN est une clé gérée, que reset_url.sh
# réécrit de toute façon juste avant le déploiement — une app fraîchement
# scaffoldée porte encore DOMAIN=CHANGE_ME, et c'est la valeur du déploiement
# qu'il faut juger, pas celle-là.
DOMAIN_VAL="$(registry_root_env DOMAIN)"; DOMAIN_VAL="${DOMAIN_VAL:-CHANGE_ME}"

if ! DOMAIN="$DOMAIN_VAL" docker compose --project-directory "$APP_DIR" -f "$COMPOSE" --profile '*' \
       config --format json --no-env-resolution > "$_tmp/model.json" 2> "$_tmp/err"; then
  refuse compose "docker-compose.yml invalide : $(grep -v 'level=warning' "$_tmp/err" | tail -1)"
  finish
fi

# Noms déjà portés dans le lab : conteneurs des AUTRES projets Compose, services
# et conteneurs de l'infrastructure, autres apps.
{
  docker ps -a --format '{{.Names}}\t{{.Label "com.docker.compose.project"}}\t{{.Label "com.docker.compose.service"}}' 2>/dev/null \
    | awk -F'\t' -v app="$APP" '$2 != app { print $1; if ($2 == "infra" || $2 == "sso-lab" || $2 == "runner") print $3 }'
  printf '%s\n' postgres postgis pgadmin keycloak openldap ldap phpldapadmin caddy code-server oauth2-proxy lab-runner
  registry_all_apps | grep -vxF -- "$APP" || true
} | sort -u > "$_tmp/reserved"

_py_out="$(python3 -B "$SCRIPT_DIR/lib/validate_compose.py" "$APP" "$APP_DIR" "$DOMAIN_VAL" "$PORTS_CSV" "$_tmp/reserved" < "$_tmp/model.json")"
_py_rc=$?
if [[ $_py_rc -eq 1 ]]; then
  while IFS= read -r _l; do [[ -n "$_l" ]] && REASONS+=("$_l"); done <<< "$_py_out"
elif [[ $_py_rc -ne 0 ]]; then
  refuse compose "analyse du modèle Compose impossible (code $_py_rc)"
fi

# ── Portes de qualité ─────────────────────────────────────────────────────────
quality_gates
if [[ ! -d "$APP_DIR/frontend" ]]; then
  warn "pas de dossier frontend/ : aucun test de cloisonnement automatisé pour cette app (le runner ne connaît que frontend/e2e/cloisonnement.spec.ts)."
fi

finish
