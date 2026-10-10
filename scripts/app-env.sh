#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# app-env.sh — variables PROPRES AU DÉVELOPPEUR dans <app>/.env.
# Contrat « multi-dev » v2, interface I4.
#
# Usage :
#   bash scripts/app-env.sh list  <app>
#   bash scripts/app-env.sh set   <app> <CLÉ> [<VALEUR>]     (sans VALEUR : lue sur stdin)
#   bash scripts/app-env.sh unset <app> <CLÉ>
#
# `list` — une ligne par clé, dans l'ordre du fichier :
#     CLÉ=valeur                    clé libre (celle que le dev règle lui-même)
#     CLÉ=******** #géré            clé gérée par le cadriciel : MARQUÉE et MASQUÉE
#   Les commentaires et lignes vides du fichier ne sont pas rendus.
#
# `set` / `unset` — REFUSENT les clés gérées par le cadriciel (code 1, rien
# n'est écrit). Sont gérées :
#     DB_*  POSTGIS_*  KEYCLOAK_*  SECRET_KEY  DOMAIN  HOST_DEV_ROOT  LAB_*
#   + tout ce que reset_url.sh et create-app-client.sh propagent :
#     SERVER_URL_LAN  SERVER_URL_WAN  PORT_KEYCLOAK  HPORT_POSTGRES  HPORT_DB  ACME_EMAIL
#   + ce que new-app.sh fixe et que le reste du cadriciel relit :
#     PORT_BACKEND  PORT_FRONTEND  BACKEND_URL  FRONTEND_URL  SCRIPT_NAME
#   + ce qui changerait le projet Docker lui-même :
#     COMPOSE_*  DOCKER_*
#
# POURQUOI CE REFUS : le .env est la seule chose du déploiement qui ne vient pas
# du dépôt du développeur. DB_NAME/DB_USER décident de la base jointe,
# KEYCLOAK_REQUIRED_GROUPS du cloisonnement de l'API, COMPOSE_PROJECT_NAME du
# projet que `down --remove-orphans` nettoie. Les laisser écrire reviendrait à
# laisser l'app choisir à qui elle appartient.
#
# Passer une valeur secrète (clé d'API…) par stdin plutôt qu'en argument : la
# ligne de commande d'un processus est lisible par `ps` pour tout compte de
# l'hôte.
#     printf '%s' "$CLE_API" | bash scripts/app-env.sh set mon-app API_KEY
#
# Le .env reste gitignoré dans le dépôt de l'app ; la modification prend effet
# au prochain déploiement (setup2.sh). `set`/`unset` prennent le verrou de
# déploiement : le .env ne change pas sous un déploiement en cours.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/registry.sh
source "$SCRIPT_DIR/lib/registry.sh"
# shellcheck source=lib/lock.sh
source "$SCRIPT_DIR/lib/lock.sh"

usage() { sed -n '/^# Usage :/,/^#$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2; exit 2; }
die()   { echo "✗ app-env : $*" >&2; exit 1; }

# Vrai si la clé est gérée par le cadriciel.
is_managed() {
  case "$1" in
    DB_*|POSTGIS_*|KEYCLOAK_*|LAB_*|COMPOSE_*|DOCKER_*) return 0 ;;
    SECRET_KEY|DOMAIN|HOST_DEV_ROOT) return 0 ;;
    SERVER_URL_LAN|SERVER_URL_WAN|PORT_KEYCLOAK|HPORT_POSTGRES|HPORT_DB|ACME_EMAIL) return 0 ;;
    PORT_BACKEND|PORT_FRONTEND|BACKEND_URL|FRONTEND_URL|SCRIPT_NAME) return 0 ;;
  esac
  return 1
}

[[ $# -ge 2 ]] || usage
CMD="$1"; APP="$2"; shift 2

APP_DIR="$(registry_app_dir "$APP")" || die "nom d'app invalide : '$APP'"
[[ -f "$APP_DIR/docker-compose.yml" ]] || die "app inconnue : '$APP'"
ENV_FILE="$APP_DIR/.env"
[[ ! -L "$ENV_FILE" ]] || die "$APP/.env est un lien symbolique — refus"

check_key() {
  [[ "$1" =~ ^[A-Z][A-Z0-9_]{0,63}$ ]] || die "clé invalide : '$1' (attendu : ^[A-Z][A-Z0-9_]{0,63}\$)"
  if is_managed "$1"; then
    die "la clé $1 est gérée par le cadriciel — elle ne se modifie pas par ici"
  fi
}

# Réécriture atomique, mode du fichier conservé (600 par défaut : il porte des secrets).
write_env() {  # stdin = nouveau contenu
  local tmp
  tmp="$(mktemp "$APP_DIR/.env.XXXXXX")" || die "écriture impossible dans $APP/"
  cat > "$tmp"
  if [[ -f "$ENV_FILE" ]]; then chmod --reference="$ENV_FILE" "$tmp"; else chmod 600 "$tmp"; fi
  mv "$tmp" "$ENV_FILE"
}

case "$CMD" in
  list)
    [[ $# -eq 0 ]] || usage
    [[ -f "$ENV_FILE" ]] || exit 0
    while IFS= read -r line || [[ -n "$line" ]]; do
      [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] || continue
      if is_managed "${BASH_REMATCH[1]}"; then
        printf '%s=******** #géré\n' "${BASH_REMATCH[1]}"
      else
        printf '%s=%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
      fi
    done < "$ENV_FILE"
    ;;

  set)
    [[ $# -eq 1 || $# -eq 2 ]] || usage
    KEY="$1"
    check_key "$KEY"
    if [[ $# -eq 2 ]]; then
      VALUE="$2"
    else
      # Valeur sur stdin (cas des secrets). Un saut de ligne final est retiré.
      VALUE="$(cat; printf x)"; VALUE="${VALUE%x}"; VALUE="${VALUE%$'\n'}"
    fi
    [[ "$VALUE" != *$'\n'* && "$VALUE" != *$'\r'* ]] || die "la valeur doit tenir sur une seule ligne"
    (( ${#VALUE} <= 4096 )) || die "valeur trop longue (4096 caractères maximum)"

    lab_lock_acquire "app-env.sh set $APP" || exit $?
    {
      found=false
      if [[ -f "$ENV_FILE" ]]; then
        while IFS= read -r line || [[ -n "$line" ]]; do
          if [[ "$line" == "$KEY="* ]]; then
            $found || printf '%s=%s\n' "$KEY" "$VALUE"
            found=true
          else
            printf '%s\n' "$line"
          fi
        done < "$ENV_FILE"
      fi
      $found || printf '%s=%s\n' "$KEY" "$VALUE"
    } | write_env
    echo "✓ $KEY enregistrée dans $APP/.env (prise en compte au prochain déploiement)" >&2
    ;;

  unset)
    [[ $# -eq 1 ]] || usage
    KEY="$1"
    check_key "$KEY"
    [[ -f "$ENV_FILE" ]] || exit 0
    grep -q "^${KEY}=" "$ENV_FILE" || { echo "· $KEY absente de $APP/.env" >&2; exit 0; }
    lab_lock_acquire "app-env.sh unset $APP" || exit $?
    grep -v "^${KEY}=" "$ENV_FILE" | write_env
    echo "✓ $KEY retirée de $APP/.env (prise en compte au prochain déploiement)" >&2
    ;;

  *) usage ;;
esac
