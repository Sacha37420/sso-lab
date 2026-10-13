#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# app-remove.sh — défait TOUT ce que new-app.sh / app-register.sh / setup2.sh
#                 ont créé pour une app. Irréversible.
#
# Usage :
#   bash scripts/app-remove.sh <app> --yes [--superuser-app]
#
# POURQUOI CE SCRIPT EXISTE : le contrat multi-dev (I5) demande, quand la
# création d'une app échoue en route, un « retour en arrière complet (dossier,
# lignes de registre, schéma…) ». Le serveur MCP n'a le droit de composer ni
# `docker` ni `git` ni SQL lui-même : il lui faut une commande. C'est aussi
# celle qu'on lance pour retirer l'app d'un développeur qui s'en va.
#
# Retire, dans cet ordre (chaque étape tolère que la précédente n'ait rien
# trouvé — le script sert justement à nettoyer un état partiel) :
#   1. conteneurs, volumes et images du projet Compose ;
#   2. dans Keycloak : clients <app> et <app>-admin, rôle <app>-access, flows
#      require-<app>… ;
#   3. le schéma PostgreSQL de l'app — UNIQUEMENT s'il vit dans la base de son
#      propriétaire (dev_<uid>/gis_<uid>) ; un schéma de devdb/gisdb n'est jamais
#      supprimé par ce script (il affiche la commande) ;
#      et le schéma d'essai <slug>__essai, cherché par son nom dans les seules
#      bases du propriétaire ; l'essai du propriétaire (adresse dev-<uid>) est
#      démonté d'abord s'il montre cette app (étape 1) ;
#   4. dans le dépôt parent : lien de sous-module (index), section .gitmodules,
#      configuration et dossier .git/modules, ligne « <app>/ » du .gitignore ;
#   5. le dossier $ROOT/<app> ;
#   6. les lignes .ports et .owners (en dernier : la ligne .owners est ce qui
#      autorise ce script à agir, une reprise après échec doit rester possible).
# Ne supprime PAS le dépôt distant (GitHub) : c'est celui du développeur.
#
# GARDE-FOU : sans --superuser-app, refuse toute app qui n'a pas de ligne dans
# .owners — c'est-à-dire toutes les apps historiques du lab. Une faute de
# frappe ne doit pas pouvoir supprimer `storage`.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/registry.sh
source "$SCRIPT_DIR/lib/registry.sh"
# shellcheck source=lib/lock.sh
source "$SCRIPT_DIR/lib/lock.sh"
ROOT="$(registry_root)"

log()  { echo "$*" >&2; }
die()  { echo "✗ app-remove : $*" >&2; exit 1; }

APP=""; YES=false; ALLOW_SU=false
for a in "$@"; do
  case "$a" in
    --yes|-y)        YES=true ;;
    --superuser-app) ALLOW_SU=true ;;
    -*)              die "option inconnue : $a" ;;
    *)               [[ -z "$APP" ]] && APP="$a" || die "argument en trop : $a" ;;
  esac
done
[[ -n "$APP" ]] || { echo "Usage : bash scripts/app-remove.sh <app> --yes [--superuser-app]" >&2; exit 2; }
# Nom d'APP au sens strict (pas « infra », pas « sso-lab ») : ce script ne doit
# jamais pouvoir viser un dossier du cadriciel.
[[ "$APP" =~ ^[a-z][a-z0-9-]{1,38}[a-z0-9]$ ]] || die "nom d'app invalide : '$APP'"
case "$APP" in
  infra|sso-lab|scripts|runner|host|chantiers|lab-mcp) die "'$APP' est un dossier du cadriciel" ;;
esac
APP_DIR="$(registry_app_dir "$APP")" || die "nom d'app invalide : '$APP'"
$YES || die "suppression irréversible de '$APP' (conteneurs, client Keycloak, schéma, dossier) : ajouter --yes"

if ! registry_has_owner_line "$APP" && ! $ALLOW_SU; then
  die "'$APP' n'a pas de ligne dans .owners (app du superutilisateur) — refus sans --superuser-app"
fi
OWNER="$(registry_app_owner "$APP")"
REL="$(registry_app_relpath "$APP")"

lab_lock_acquire "app-remove.sh $APP" || exit $?

# ── 1. Docker ─────────────────────────────────────────────────────────────────
log "▶ 1/6 conteneurs, volumes, images"
if [[ -f "$APP_DIR/docker-compose.yml" ]]; then
  docker compose --project-directory "$APP_DIR" -f "$APP_DIR/docker-compose.yml" \
    down --volumes --remove-orphans --rmi local 2>&1 | sed 's/^/    /' >&2 || true
fi
# Filet : tout conteneur encore étiqueté de ce projet (compose illisible…).
_left="$(docker ps -aq --filter "label=com.docker.compose.project=${APP}" 2>/dev/null || true)"
if [[ -n "$_left" ]]; then
  # shellcheck disable=SC2086
  docker rm -f $_left > /dev/null 2>&1 || true
fi

# L'essai du propriétaire (chantier « essai-dev », I1) : s'il montre CETTE app,
# il est démonté — ses conteneurs servent le code d'un projet qui disparaît.
# S'il montre un autre projet, on n'y touche pas. Le verrou est déjà tenu par
# ce script : app-preview.sh le constate et ne le reprend pas.
_PV_STATE="$(registry_state_dir)/preview/${OWNER}/state.json"
if [[ -s "$_PV_STATE" && "$(jq -r '.app // empty' "$_PV_STATE" 2>/dev/null || true)" == "$APP" ]]; then
  log "    l'adresse d'essai dev-${OWNER} montre '$APP' : démontage"
  bash "$SCRIPT_DIR/app-preview.sh" down "$OWNER" 2>&1 | grep -v '^RESULTAT=' | sed 's/^/    /' >&2 \
    || log "    ⚠ l'essai dev-${OWNER} n'a pas pu être démonté — à faire : bash scripts/lab-lock.sh bash scripts/app-preview.sh down ${OWNER}"
fi

# ── 2. Keycloak ───────────────────────────────────────────────────────────────
log "▶ 2/6 Keycloak"
_kc_cleanup() {
  local sso_env="$ROOT/sso-lab/.env" admin_user admin_pass kc_port kc_url token realm="ssolab"
  [[ -f "$sso_env" ]] || { log "    ⚠ sso-lab/.env introuvable — Keycloak non nettoyé"; return; }
  _v() { grep -E "^$1=" "$sso_env" 2>/dev/null | head -1 | cut -d= -f2- | sed -e 's/[[:space:]]*#.*//' -e "s/^['\"]//" -e "s/['\"]\$//"; }
  admin_user="$(_v KEYCLOAK_ADMIN)"; admin_user="${admin_user:-admin}"
  admin_pass="$(_v KEYCLOAK_ADMIN_PASSWORD)"
  kc_port="$(_v PORT_KEYCLOAK)"; kc_port="${kc_port:-8080}"
  if [[ -f /.dockerenv ]]; then kc_url="http://keycloak:${kc_port}"; else kc_url="http://localhost:${kc_port}"; fi
  token="$(curl -sf --max-time 15 \
             --data-urlencode "client_id=admin-cli" --data-urlencode "grant_type=password" \
             --data-urlencode "username=${admin_user}" --data-urlencode "password@/dev/fd/3" \
             "${kc_url}/realms/master/protocol/openid-connect/token" 3< <(printf '%s' "$admin_pass") 2>/dev/null \
           | jq -r '.access_token // empty' 2>/dev/null || true)"
  [[ -n "$token" ]] || { log "    ⚠ Keycloak injoignable — clients/rôle/flows de '$APP' NON supprimés"; return; }
  # Le jeton passe par un fichier de configuration lu sur un descripteur, pas par argv.
  _kc() { local method="$1" path="$2"; curl -s -o /dev/null -w '%{http_code}' --max-time 20 -X "$method" -K /dev/fd/3 \
            "${kc_url}/admin/realms/${realm}${path}" 3< <(printf 'header = "Authorization: Bearer %s"\n' "$token"); }
  _kc_get() { curl -sf --max-time 20 -K /dev/fd/3 "${kc_url}/admin/realms/${realm}$1" \
                3< <(printf 'header = "Authorization: Bearer %s"\n' "$token"); }

  local cid uuid code
  for cid in "$APP" "$APP-admin"; do
    uuid="$(_kc_get "/clients?clientId=${cid}" | jq -r '.[0].id // empty' 2>/dev/null || true)"
    if [[ -n "$uuid" ]]; then
      code="$(_kc DELETE "/clients/${uuid}")"
      log "    client ${cid} supprimé (HTTP ${code})"
    fi
  done
  code="$(_kc DELETE "/roles/${APP}-access")"
  [[ "$code" == "204" ]] && log "    rôle ${APP}-access supprimé"
  # Flows : le flow de tête d'abord (le client qui le référençait n'existe
  # plus), puis ses sous-flows s'ils lui ont survécu.
  local fid alias
  for _pass in 1 2; do
    while IFS=$'\t' read -r fid alias; do
      [[ -n "$fid" ]] || continue
      code="$(_kc DELETE "/authentication/flows/${fid}")"
      [[ "$code" == "204" ]] && log "    flow ${alias} supprimé"
    done < <(_kc_get "/authentication/flows" 2>/dev/null \
             | jq -r --arg a "require-${APP}" '.[] | select(.alias == $a or (.alias | startswith($a + "-"))) | [.id, .alias] | @tsv' 2>/dev/null || true)
  done
}
_kc_cleanup

# ── 3. Schéma PostgreSQL ──────────────────────────────────────────────────────
log "▶ 3/6 schéma PostgreSQL"
_infra_val() { grep -E "^$1=" "$ROOT/infra/.env" 2>/dev/null | tail -1 | cut -d= -f2- || true; }
if [[ -f "$APP_DIR/.env" ]]; then
  _schema="$(sed -n 's/^DB_SCHEMA=//p' "$APP_DIR/.env" | tail -1 | tr -d "\"'\r" | xargs || true)"
  _host="$(sed -n 's/^DB_HOST=//p'   "$APP_DIR/.env" | tail -1 | tr -d "\"'\r" | xargs || true)"
  _db="$(sed -n 's/^DB_NAME=//p'     "$APP_DIR/.env" | tail -1 | tr -d "\"'\r" | xargs || true)"
  if [[ -n "$_schema" && "$_schema" =~ ^[a-z_][a-z0-9_]*$ && "$_db" =~ ^[a-z_][a-z0-9_]*$ ]]; then
    if [[ "$_host" == "postgis" ]]; then
      _container="dev-postgis"; _admin="$(_infra_val POSTGIS_USER)"; _admin="${_admin:-gisuser}"; _own="gis_${OWNER}"
    else
      _container="dev-postgres"; _admin="$(_infra_val POSTGRES_USER)"; _admin="${_admin:-devuser}"; _own="dev_${OWNER}"
    fi
    if [[ "$_db" == "$_own" ]]; then
      if docker exec "$_container" psql -X -U "$_admin" -d "$_db" -v ON_ERROR_STOP=1 -q \
           -c "DROP SCHEMA IF EXISTS \"${_schema}\" CASCADE;" >&2 2>&1; then
        log "    schéma ${_schema} supprimé de ${_db} (${_container})"
      else
        log "    ⚠ suppression du schéma ${_schema} dans ${_db} impossible"
      fi
    else
      log "    ⚠ le schéma ${_schema} vit dans la base partagée ${_db} : NON supprimé. À la main, si voulu :"
      log "      docker exec ${_container} psql -U ${_admin} -d ${_db} -c 'DROP SCHEMA \"${_schema}\" CASCADE;'"
      log "      (et retirer sa ligne de infra/init*/00_schemas.sql)"
    fi
  fi
else
  # Pas de .env : création interrompue avant son écriture, ou dossier déjà
  # parti. Le nom du schéma se déduit du nom de l'app (my-app → my_app, la règle
  # de new-app.sh) ; on le cherche dans les SEULES bases du propriétaire —
  # jamais dans devdb/gisdb.
  _schema="${APP//-/_}"
  for _pair in "dev-postgres:dev_${OWNER}:$(_infra_val POSTGRES_USER):devuser" "dev-postgis:gis_${OWNER}:$(_infra_val POSTGIS_USER):gisuser"; do
    IFS=: read -r _container _db _admin _admin_default <<< "$_pair"
    _admin="${_admin:-$_admin_default}"
    [[ "$(docker exec "$_container" psql -X -U "$_admin" -d postgres -tAc \
          "SELECT 1 FROM pg_database WHERE datname = '${_db}'" 2>/dev/null || true)" == "1" ]] || continue
    if [[ "$(docker exec "$_container" psql -X -U "$_admin" -d "$_db" -tAc \
          "SELECT 1 FROM pg_namespace WHERE nspname = '${_schema}'" 2>/dev/null || true)" == "1" ]]; then
      docker exec "$_container" psql -X -U "$_admin" -d "$_db" -v ON_ERROR_STOP=1 -q \
        -c "DROP SCHEMA IF EXISTS \"${_schema}\" CASCADE;" > /dev/null 2>&1 \
        && log "    schéma ${_schema} supprimé de ${_db} (${_container}) — retrouvé par son nom, sans .env" \
        || log "    ⚠ suppression du schéma ${_schema} dans ${_db} impossible"
    fi
  done
  log "    (pas de .env — schéma cherché par son nom dans les bases de « ${OWNER} »)"
fi

# Schéma d'essai de l'app (<slug>__essai — chantier « essai-dev », I1). Son nom
# se déduit de celui de l'app, jamais du .env ; il n'est cherché que dans les
# bases du propriétaire, comme ci-dessus — jamais dans devdb/gisdb ni `lab`.
_essai="${APP//-/_}__essai"
for _pair in "dev-postgres:dev_${OWNER}:$(_infra_val POSTGRES_USER):devuser" "dev-postgis:gis_${OWNER}:$(_infra_val POSTGIS_USER):gisuser"; do
  IFS=: read -r _container _db _admin _admin_default <<< "$_pair"
  _admin="${_admin:-$_admin_default}"
  [[ "$(docker exec "$_container" psql -X -U "$_admin" -d postgres -tAc \
        "SELECT 1 FROM pg_database WHERE datname = '${_db}'" < /dev/null 2>/dev/null || true)" == "1" ]] || continue
  [[ "$(docker exec "$_container" psql -X -U "$_admin" -d "$_db" -tAc \
        "SELECT 1 FROM pg_namespace WHERE nspname = '${_essai}'" < /dev/null 2>/dev/null || true)" == "1" ]] || continue
  docker exec "$_container" psql -X -U "$_admin" -d "$_db" -v ON_ERROR_STOP=1 -q \
    -c "DROP SCHEMA IF EXISTS \"${_essai}\" CASCADE;" < /dev/null > /dev/null 2>&1 \
    && log "    schéma d'essai ${_essai} supprimé de ${_db} (${_container})" \
    || log "    ⚠ suppression du schéma d'essai ${_essai} dans ${_db} impossible"
done

# ── 4. Dépôt parent ───────────────────────────────────────────────────────────
log "▶ 4/6 dépôt parent (sous-module)"
if git -C "$ROOT" ls-files --error-unmatch -- "$REL" > /dev/null 2>&1; then
  # -f : après un app-sync.sh, le commit extrait diffère de celui qui est
  # indexé, et git refuse alors un simple `rm --cached`. --cached : l'index
  # seulement, le dossier est traité à l'étape 6.
  if git -C "$ROOT" rm -q -f --cached -- "$REL" >&2 2>&1; then
    log "    lien de sous-module retiré de l'index"
  else
    log "    ⚠ le lien de sous-module n'a PAS pu être retiré de l'index du dépôt parent"
  fi
fi
# La section de .gitmodules se retrouve par son CHEMIN, pas par son nom : une
# app déménagée par app-relocate.sh garde le nom de section « <app> » avec
# path = deploiement/<app>.
_SECTION=""
if [[ -f "$ROOT/.gitmodules" ]]; then
  _SECTION="$(git -C "$ROOT" config -f .gitmodules --get-regexp '^submodule\..*\.path$' 2>/dev/null \
              | awk -v p="$REL" '$2 == p { sub(/^submodule\./, "", $1); sub(/\.path$/, "", $1); print $1; exit }')"
fi
if [[ -n "$_SECTION" ]]; then
  git -C "$ROOT" config -f .gitmodules --remove-section "submodule.${_SECTION}" 2>/dev/null || true
  # Ré-indexer .gitmodules : s'il est redevenu identique à HEAD, l'index du
  # parent se retrouve exactement dans l'état d'avant l'enregistrement.
  git -C "$ROOT" add -- .gitmodules 2>/dev/null || true
  log "    section retirée de .gitmodules"
fi
for _sec in "$_SECTION" "$REL" "$APP"; do
  [[ -n "$_sec" ]] || continue
  git -C "$ROOT" config --remove-section "submodule.${_sec}" 2>/dev/null || true
  [[ -d "$ROOT/.git/modules/$_sec" ]] && rm -rf "$ROOT/.git/modules/$_sec"
done
if [[ -f "$ROOT/.gitignore" ]] && grep -qxF "$REL/" "$ROOT/.gitignore"; then
  grep -vxF "$REL/" "$ROOT/.gitignore" > "$ROOT/.gitignore.tmp" || true
  cat "$ROOT/.gitignore.tmp" > "$ROOT/.gitignore"; rm -f "$ROOT/.gitignore.tmp"
  log "    ligne « $REL/ » retirée du .gitignore"
fi

# ── 5. Dossier ────────────────────────────────────────────────────────────────
log "▶ 5/6 dossier"
if [[ -d "$APP_DIR" && ( "$APP_DIR" == "$ROOT/$APP" || "$APP_DIR" == "$ROOT/deploiement/$APP" ) ]]; then
  if ! rm -rf -- "$APP_DIR" 2>/dev/null; then
    # Fichiers créés par root dans un bind mount : un conteneur jetable les retire.
    docker run --rm -v "$APP_DIR:/target" alpine:3 sh -c 'rm -rf /target/* /target/.[!.]* 2>/dev/null; true' > /dev/null 2>&1 || true
    rm -rf -- "$APP_DIR" 2>/dev/null || log "    ⚠ $APP_DIR n'a pas pu être entièrement supprimé (fichiers d'un autre utilisateur ?)"
  fi
  [[ -d "$APP_DIR" ]] || log "    $APP_DIR supprimé"
fi

# ── 6. Registre ───────────────────────────────────────────────────────────────
# EN DERNIER : la ligne .owners est ce qui autorise ce script à agir sur l'app
# (garde-fou). Retirée plus tôt, un échec à une étape suivante laisserait un
# reste que seule l'option --superuser-app permettrait de reprendre.
log "▶ 6/6 registre (.ports, .owners)"
for _f in "$ROOT/.ports" "$ROOT/.owners"; do
  [[ -f "$_f" ]] || continue
  if grep -q "^${APP}:" "$_f"; then
    grep -v "^${APP}:" "$_f" > "$_f.tmp" || true
    cat "$_f.tmp" > "$_f"; rm -f "$_f.tmp"
    log "    ligne retirée de $(basename "$_f")"
  fi
done
[[ -f "$ROOT/.owners" && ! -s "$ROOT/.owners" ]] && rm -f "$ROOT/.owners"

registry_forget_deployed "$APP"
# Clé de déploiement du dépôt (contrat v5, I4) : elle ne sert plus à rien, et
# une clé privée ne doit pas survivre à l'app qu'elle ouvrait.
for _k in "$(registry_state_dir)/deploy-keys/$APP" "$(registry_state_dir)/deploy-keys/$APP.pub"; do
  if [[ -f "$_k" ]]; then unlink "$_k" && log "    clé de déploiement retirée ($(basename "$_k"))"; fi
done
# deploiement/ vide après le retrait de sa dernière app : on ne le laisse pas traîner.
rmdir "$ROOT/deploiement" 2>/dev/null || true
log "✓ '$APP' retirée. (Le dépôt distant n'est pas supprimé.)"
