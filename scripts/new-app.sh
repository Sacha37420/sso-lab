#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# new-app.sh — Initialise une nouvelle application dans dev/
#
# Types supportés :
#   1) Spring Boot seul
#   2) Spring Boot + Angular
#   3) Django seul
#   4) Django + Angular
#   5) Angular seul
#
# Prérequis : docker, curl, unzip, jq
# Usage     : bash new-app.sh [--owner <uid>]
#
# --owner <uid> (contrat multi-dev, I1/I2/I4) : l'app appartient au développeur
#   <uid> (inscrit dans .devs). Elle vit comme les autres dans $ROOT/<app>, mais
#   son schéma est créé dans la base de <uid> (dev_<uid>, ou gis_<uid> pour une
#   app SIG), son .env porte le rôle dev_<uid>, et une ligne « <app>:<uid> » est
#   écrite dans .owners. Sans --owner, l'app appartient au superutilisateur
#   (LAB_SUPERUSER) et aucune ligne .owners n'est écrite.
#
# Le nom est contrôlé par check-app-name.sh pour TOUT créateur ; le contrôle et
# l'écriture de .ports/.owners se font sous le verrou de déploiement
# (scripts/lib/lock.sh) : deux créations simultanées ne peuvent obtenir ni le
# même nom ni le même port.
#
# Entrée non interactive (inchangée) — une réponse par ligne :
#   nom, type [1-5], port backend, port frontend, scaffold [O/n], groupe(s), instance [1-2]
#   (ligne de port vide = port suggéré ; seules les lignes des questions
#   réellement posées pour le type choisi sont lues)
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

# ── Couleurs ──────────────────────────────────────────────────────────────────
BOLD='\033[1m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; RED='\033[0;31m'; CYAN='\033[0;36m'; NC='\033[0m'

step() { echo -e "\n${BOLD}${BLUE}▶ $*${NC}"; }
ok()   { echo -e "  ${GREEN}✔ $*${NC}"; }
warn() { echo -e "  ${YELLOW}⚠ $*${NC}"; }
err()  { echo -e "\n${RED}${BOLD}✘ Erreur : $*${NC}\n" >&2; exit 1; }
info() { echo -e "  ${CYAN}→ $*${NC}"; }

DEV_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/registry.sh
source "$DEV_DIR/scripts/lib/registry.sh"
# shellcheck source=lib/lock.sh
source "$DEV_DIR/scripts/lib/lock.sh"

# ── Options ───────────────────────────────────────────────────────────────────
OWNER=""
OWNER_EXPLICIT=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --owner)   [[ $# -gt 1 ]] || err "--owner requiert un uid"; OWNER="$2"; OWNER_EXPLICIT=true; shift ;;
    --owner=*) OWNER="${1#*=}"; OWNER_EXPLICIT=true ;;
    -h|--help) sed -n '2,32p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)         err "Argument inconnu : '$1' (usage : bash new-app.sh [--owner <uid>])" ;;
  esac
  shift
done
SUPERUSER="$(registry_superuser)"
[[ -n "$OWNER" ]] || OWNER="$SUPERUSER"
registry_valid_uid "$OWNER" || err "--owner : uid invalide '${OWNER}' (attendu : ^[a-z][a-z0-9]{1,30}\$)"
OWNER_IS_SUPERUSER=false
registry_is_superuser "$OWNER" && OWNER_IS_SUPERUSER=true
if ! $OWNER_IS_SUPERUSER && ! registry_is_dev "$OWNER"; then
  err "« ${OWNER} » n'est pas un développeur inscrit (.devs) — bash scripts/dev-enroll.sh ${OWNER}"
fi

INFRA_SCHEMAS="$DEV_DIR/infra/init/00_schemas.sql"
INFRA_SCHEMAS_POSTGIS="$DEV_DIR/infra/init-postgis/00_schemas.sql"
DOCKER_UID="$(id -u):$(id -g)"
PORTS_REGISTRY="$DEV_DIR/.ports"

# ── Initialisation du registre des ports ─────────────────────────────────────
# Créé au premier lancement avec les ports déjà réservés par l'infrastructure.
if [[ ! -f "$PORTS_REGISTRY" ]]; then
  cat > "$PORTS_REGISTRY" << 'PORTS_EOF'
# Registre des ports — géré automatiquement par new-app.sh
# Format : nom-app:port-backend:port-frontend  (vide si non applicable)
# ── Ports réservés par l'infrastructure ──────────────────────────────────────
__keycloak__:8080:
__phpldapadmin__:8081:
spring-app:8082:
PORTS_EOF
fi

# ── Gestion des ports ─────────────────────────────────────────────────────────

# Retourne tous les numéros de port déjà enregistrés
_registered_ports() {
  grep -v '^#\|^$' "$PORTS_REGISTRY" 2>/dev/null \
    | awk -F: '{print $2; print $3}' \
    | grep -E '^[0-9]+$' || true
}

# Retourne 0 si le port est actuellement actif sur la machine
port_in_use() {
  # La sortie de ss est CAPTURÉE puis cherchée, jamais passée par un tube à
  # `grep -q` : sous `set -o pipefail`, grep sort dès la première ligne trouvée,
  # ss reçoit SIGPIPE, le tube « échoue »… et le port en écoute est déclaré
  # LIBRE. Constaté : le port 8085, en écoute, a été attribué à une app.
  local listening
  listening="$(ss -tln 2>/dev/null || true)"
  grep -qE ":$1[[:space:]]" <<< "$listening" && return 0
  # `ss` ne voit que l'espace réseau où tourne CE script : lancé par le moteur
  # (conteneur lab-mcp), il ne voit aucun port de l'hôte. Constaté le 2026-10-11 :
  # 8085/4203, tenus par google-agenda (cadriciel dev2/, même démon Docker, registre
  # .ports distinct), ont été attribués à un projet, dont le premier déploiement a
  # échoué (« port is already allocated »). On interroge donc aussi le démon : ports
  # liés par TOUT conteneur, démarré ou non, des deux cadriciels.
  grep -qx "$1" <<< "$(_docker_bound_ports)"
}

# Ports d'hôte liés par un conteneur quelconque du démon (un par ligne). Mis en
# cache : next_port appelle port_in_use en boucle.
_DOCKER_BOUND_PORTS_CACHE=""; _DOCKER_BOUND_PORTS_DONE=false
_docker_bound_ports() {
  if ! $_DOCKER_BOUND_PORTS_DONE; then
    local ids
    ids="$(docker ps -aq 2>/dev/null || true)"
    if [[ -n "$ids" ]]; then
      # shellcheck disable=SC2086
      _DOCKER_BOUND_PORTS_CACHE="$(docker inspect --format \
        '{{range $p, $b := .HostConfig.PortBindings}}{{range $b}}{{println .HostPort}}{{end}}{{end}}' \
        $ids 2>/dev/null | grep -E '^[0-9]+$' | sort -u || true)"
    fi
    _DOCKER_BOUND_PORTS_DONE=true
  fi
  printf '%s\n' "$_DOCKER_BOUND_PORTS_CACHE"
}

# Retourne le premier port libre >= $1 (non dans le registre, non actif)
next_port() {
  local port="$1"
  local taken
  taken="$(_registered_ports)"
  while true; do
    if ! grep -qx "$port" <<< "$taken" && ! port_in_use "$port"; then
      echo "$port"; return
    fi
    (( port++ ))
  done
}

# Enregistre les ports dans le registre
register_ports() {
  local name="$1" bport="${2:-}" fport="${3:-}"
  echo "${name}:${bport}:${fport}" >> "$PORTS_REGISTRY"
  ok "Ports enregistrés dans .ports (backend: ${bport:-—}  frontend: ${fport:-—})"
}

# ──────────────────────────────────────────────────────────────────────────────
# SAISIE INTERACTIVE
# ──────────────────────────────────────────────────────────────────────────────
echo -e "\n${BOLD}╔════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║    Nouvelle application — dev/         ║${NC}"
echo -e "${BOLD}╚════════════════════════════════════════╝${NC}\n"

read -rp "Nom de l'application (ex: my-app) : " APP_NAME
[[ -z "$APP_NAME" ]] && err "Le nom ne peut pas être vide."
[[ ! "$APP_NAME" =~ ^[a-z][a-z0-9-]*$ ]] \
  && err "Nom invalide. Minuscules, chiffres et tirets uniquement (ex: my-app)."

# (v5) Toute nouvelle app naît dans $ROOT/deploiement/<app>. Le contrôle « ce
# nom existe déjà » (à la racine comme dans deploiement/) est fait par
# check-app-name.sh, sous verrou, plus bas.
APP_DIR="$(registry_deploy_dir "$APP_NAME")" || err "Nom invalide : '$APP_NAME'."
APP_REL="deploiement/$APP_NAME"
[[ -d "$DEV_DIR/$APP_NAME" ]] && err "Le dossier '$APP_NAME' existe déjà dans dev/."
[[ -d "$APP_DIR" ]] && err "Le dossier '$APP_NAME' existe déjà dans dev/."

DB_SCHEMA="${APP_NAME//-/_}"   # my-app → my_app  (nom de schéma SQL valide)

echo -e "\n  Type d'application :"
echo -e "    ${BOLD}1${NC}) Spring Boot seul"
echo -e "    ${BOLD}2${NC}) Spring Boot + Angular"
echo -e "    ${BOLD}3${NC}) Django seul"
echo -e "    ${BOLD}4${NC}) Django + Angular"
echo -e "    ${BOLD}5${NC}) Angular seul"
echo ""
read -rp "Choix [1-5] : " APP_TYPE
[[ ! "$APP_TYPE" =~ ^[1-5]$ ]] && err "Choix invalide."

BACKEND_PORT=""
ANGULAR_PORT=""

# Port laissé vide = port suggéré. On retient si le port a été CHOISI ou
# simplement accepté : la valeur suggérée ici n'est qu'indicative (calculée hors
# verrou), elle est recalculée sous le verrou plus bas ; un port choisi
# explicitement y est, lui, vérifié libre.
BACKEND_PORT_AUTO=false
ANGULAR_PORT_AUTO=false
if [[ "$APP_TYPE" =~ ^[1234]$ ]]; then
  _suggest_b=$(next_port 8083)
  read -rp "Port backend  [suggéré : ${_suggest_b}, Entrée pour confirmer] : " BACKEND_PORT
  [[ -z "$BACKEND_PORT" ]] && BACKEND_PORT_AUTO=true
  BACKEND_PORT="${BACKEND_PORT:-$_suggest_b}"
  [[ ! "$BACKEND_PORT" =~ ^[0-9]+$ ]] && err "Port invalide."
fi

if [[ "$APP_TYPE" =~ ^[245]$ ]]; then
  _suggest_f=$(next_port 4200)
  read -rp "Port frontend [suggéré : ${_suggest_f}, Entrée pour confirmer] : " ANGULAR_PORT
  [[ -z "$ANGULAR_PORT" ]] && ANGULAR_PORT_AUTO=true
  ANGULAR_PORT="${ANGULAR_PORT:-$_suggest_f}"
  [[ ! "$ANGULAR_PORT" =~ ^[0-9]+$ ]] && err "Port invalide."
fi

echo ""
read -rp "Scaffolder le projet (télécharge Django / Angular / Spring) ? [O/n] : " DO_SCAFFOLD
DO_SCAFFOLD="${DO_SCAFFOLD:-O}"

# ── Cloisonnement : groupe(s) autorisé(s) ─────────────────────────────────────
# Le lab est exposé sur Internet. Sans groupe requis, l'app accepte TOUT compte
# du realm — y compris un compte auto-inscrit par un inconnu. La question est
# posée en dernier pour ne pas décaler les réponses des appels non-interactifs
# existants (printf 'nom\n4\n8088\n4206\nO\n' | bash new-app.sh).
echo ""
echo "Groupe(s) Keycloak autorisé(s) à utiliser l'app (séparés par des virgules)."
echo "Ex: developers  |  famille,amis  |  admins"
# `|| true` : sous `set -e`, un read qui atteint EOF renvoie 1 et ferait avorter
# le script. Or cette question est la dernière : un appel non-interactif qui ne
# fournit pas de réponse (printf ... | bash new-app.sh) tomberait précisément ici.
read -rp "Groupe(s) requis [laisser vide = AUCUNE restriction] : " REQUIRE_GROUP || true
REQUIRE_GROUP="$(echo "${REQUIRE_GROUP:-}" | tr -d '[:space:]')"

# Construit le fragment d'options réutilisé plus bas dans les .keycloak-client-opts
KC_GROUP_OPT=""
if [[ -n "$REQUIRE_GROUP" ]]; then
  KC_GROUP_OPT=" --require-group ${REQUIRE_GROUP}"
else
  echo ""
  echo -e "\033[1;33m⚠ Aucun groupe requis : cette app sera accessible à TOUT compte du realm ssolab,\033[0m"
  echo -e "\033[1;33m  y compris à un inconnu qui se serait auto-inscrit. Le lab est exposé sur Internet.\033[0m"
  echo -e "\033[1;33m  Pour corriger plus tard : ajouter --require-group <groupe> dans\033[0m"
  echo -e "\033[1;33m  ${APP_NAME}/.keycloak-client-opts, puis relancer setup2.sh ${APP_NAME} --yes\033[0m"
fi

# ── Choix de l'instance PostgreSQL (posé en DERNIER, uniquement si l'app a une
#    base) : ne décale aucune des questions précédentes pour les appels
#    non-interactifs existants (printf '...\n' | new-app.sh — cf. CLAUDE.md),
#    qui n'en fournissant pas de réponse obtiennent "" → défaut "postgres".
DB_INSTANCE="postgres"
if [[ "$APP_TYPE" =~ ^[1234]$ ]]; then
  echo ""
  echo -e "  Instance PostgreSQL :"
  echo -e "    ${BOLD}1${NC}) postgres — base partagée devdb (défaut, un schéma par app)"
  echo -e "    ${BOLD}2${NC}) postgis  — base SIG gisdb (extension PostGIS ; apps géospatiales"
  echo -e "                  uniquement — imports de cartes, calculs géo, rasters…)"
  read -rp "Choix [1-2, défaut 1] : " _db_choice || true
  if [[ "${_db_choice:-}" == "2" ]]; then
    DB_INSTANCE="postgis"
  fi
fi

# ──────────────────────────────────────────────────────────────────────────────
# CONTRÔLES SOUS VERROU (contrat multi-dev I1/I4)
# ──────────────────────────────────────────────────────────────────────────────
# Tout ce qui suit lit puis écrit le registre (.ports, .owners) et crée le
# dossier : le verrou est pris ICI, après la saisie (on ne bloque pas le lab
# pendant qu'un humain réfléchit à un nom), et gardé jusqu'à la fin du script.
lab_lock_acquire "new-app.sh ${APP_NAME}" || exit $?

# ── Règles propres à une app de développeur ───────────────────────────────────
if ! $OWNER_IS_SUPERUSER; then
  # Les gabarits Spring n'écrivent pas de .keycloak-client-opts : l'app serait
  # refusée par validate-app.sh à son premier déploiement. Autant le dire ici.
  [[ "$APP_TYPE" =~ ^[345]$ ]] \
    || err "Types disponibles pour un développeur : 3 (Django), 4 (Django + Angular), 5 (Angular)."
  # Le lab est exposé sur Internet : une app sans groupe requis accepte tout
  # compte du realm. Toléré (avec avertissement) pour le superutilisateur, pas ici.
  [[ -n "$REQUIRE_GROUP" ]] \
    || err "Un groupe requis est obligatoire (cloisonnement) — ex. : developers"
fi
if [[ -n "$REQUIRE_GROUP" && ! "$REQUIRE_GROUP" =~ ^[A-Za-z0-9_-]+(,[A-Za-z0-9_-]+)*$ ]]; then
  err "Groupe(s) invalide(s) : '${REQUIRE_GROUP}' (noms séparés par des virgules, sans espace)"
fi

# ── Règles de nommage (pour TOUT créateur) ────────────────────────────────────
step "Contrôle du nom (check-app-name.sh)"
if ! _name_reasons="$(bash "$DEV_DIR/scripts/check-app-name.sh" "$APP_NAME")"; then
  echo "$_name_reasons" | sed 's/^/  ✘ /' >&2
  err "Le nom '${APP_NAME}' est refusé."
fi
ok "Nom '${APP_NAME}' accepté"

# ── Ports : recalcul (port suggéré) ou vérification (port choisi) ─────────────
_port_registered() { local reg; reg="$(_registered_ports)"; grep -qx "$1" <<< "$reg"; }
_check_port() {  # $1 = libellé, $2 = port choisi explicitement
  (( $2 >= 1024 && $2 <= 65535 )) || err "Port $1 hors plage (1024-65535) : $2"
  _port_registered "$2" && err "Port $1 $2 déjà enregistré dans .ports."
  port_in_use "$2"      && err "Port $1 $2 déjà en écoute sur cet hôte."
  return 0
}
if [[ -n "$BACKEND_PORT" ]]; then
  if $BACKEND_PORT_AUTO; then BACKEND_PORT="$(next_port 8083)"; else _check_port backend "$BACKEND_PORT"; fi
fi
if [[ -n "$ANGULAR_PORT" ]]; then
  if $ANGULAR_PORT_AUTO; then ANGULAR_PORT="$(next_port 4200)"; else _check_port frontend "$ANGULAR_PORT"; fi
fi
[[ -n "$BACKEND_PORT" && "$BACKEND_PORT" == "$ANGULAR_PORT" ]] && err "Ports backend et frontend identiques."

# ── Base de données cible (contrat multi-dev I2) ──────────────────────────────
# Mode « base par développeur » : dev_<uid> (ou gis_<uid>) avec le rôle
# dev_<uid>. C'est le mode de tout développeur, et celui du superutilisateur
# DÈS QUE sa base dédiée a été provisionnée (clé DEV_PG_PASSWORD__<uid> dans
# infra/dev-roles.env). Tant qu'elle ne l'est pas, le superutilisateur reste sur le mode
# historique (devdb/devuser, gisdb/gisuser) : rien ne change pour lui avant la
# bascule.
_infra_has_key() { grep -qE "^$1=" "$DEV_DIR/infra/dev-roles.env" 2>/dev/null; }
DB_MODE="legacy"
if [[ "$APP_TYPE" =~ ^[1234]$ ]]; then
  if ! $OWNER_IS_SUPERUSER; then
    DB_MODE="dev"
  elif [[ "$DB_INSTANCE" == "postgis" ]] && _infra_has_key "DEV_GIS_PASSWORD__${OWNER}"; then
    DB_MODE="dev"
  elif [[ "$DB_INSTANCE" != "postgis" ]] && _infra_has_key "DEV_PG_PASSWORD__${OWNER}"; then
    DB_MODE="dev"
  fi
fi
if [[ "$DB_MODE" == "dev" ]]; then
  step "Base de données de « ${OWNER} » (dev-db.sh ensure)"
  if [[ "$DB_INSTANCE" == "postgis" ]]; then
    bash "$DEV_DIR/scripts/dev-db.sh" ensure "$OWNER" --gis || err "Provisionnement de gis_${OWNER} impossible."
    ENV_DB_NAME="gis_${OWNER}"; ENV_DB_PASS_KEY="DEV_GIS_PASSWORD__${OWNER}"
  else
    bash "$DEV_DIR/scripts/dev-db.sh" ensure "$OWNER" || err "Provisionnement de dev_${OWNER} impossible."
    ENV_DB_NAME="dev_${OWNER}"; ENV_DB_PASS_KEY="DEV_PG_PASSWORD__${OWNER}"
  fi
  ENV_DB_USER="dev_${OWNER}"
elif [[ "$DB_INSTANCE" == "postgis" ]]; then
  ENV_DB_NAME="gisdb";  ENV_DB_USER="gisuser"; ENV_DB_PASS_KEY="POSTGIS_PASSWORD"
else
  ENV_DB_NAME="devdb";  ENV_DB_USER="devuser"; ENV_DB_PASS_KEY="POSTGRES_PASSWORD"
fi

# ──────────────────────────────────────────────────────────────────────────────
# FONCTIONS COMMUNES
# ──────────────────────────────────────────────────────────────────────────────

# Ajoute CREATE SCHEMA dans infra/init/00_schemas.sql (ou infra/init-postgis/00_schemas.sql
# si $2 = "postgis"), ET le crée dans la base déjà en cours d'exécution.
#
# 00_schemas.sql n'est joué qu'à l'initialisation du volume Postgres : pour une app
# créée alors que l'instance tourne déjà, le schéma n'existerait jamais. Django, dont
# le search_path est « <schema>,public », se rabattrait alors sur public et y créerait
# ses tables sans rien signaler (toutes les apps partagent l'app label « api », donc
# il croit ses migrations déjà appliquées).
add_schema() {
  local schema="$1" instance="${2:-postgres}"
  local schemas_file container db_user db_name

  # Base par développeur : le schéma est créé à chaud dans dev_<uid>/gis_<uid>
  # par ensure-schemas.sh (qui lit le .env tout juste écrit et le registre), et
  # il n'entre PAS dans infra/init*/00_schemas.sql — ces fichiers n'initialisent
  # que devdb/gisdb. Sur un volume vierge, c'est `dev-db.sh ensure-all` puis
  # ensure-schemas.sh (appelés par setup2.sh) qui le recréent.
  if [[ "$DB_MODE" == "dev" ]]; then
    bash "$DEV_DIR/scripts/ensure-schemas.sh" "$APP_NAME" \
      || err "Création du schéma '${schema}' dans ${ENV_DB_NAME} impossible."
    return 0
  fi
  if [[ "$instance" == "postgis" ]]; then
    schemas_file="$INFRA_SCHEMAS_POSTGIS"; container="dev-postgis"
    db_user="gisuser"; db_name="gisdb"
  else
    schemas_file="$INFRA_SCHEMAS"; container="${PG_CONTAINER:-dev-postgres}"
    db_user="devuser"; db_name="devdb"
  fi

  if grep -q "CREATE SCHEMA IF NOT EXISTS ${schema};" "$schemas_file" 2>/dev/null; then
    warn "Schéma '${schema}' déjà présent dans ${schemas_file#$DEV_DIR/}"
  else
    printf '\nCREATE SCHEMA IF NOT EXISTS %s;\n' "${schema}" >> "$schemas_file"
    ok "Schéma '${schema}' ajouté dans ${schemas_file#$DEV_DIR/}"
  fi

  # Sans effet si le container n'est pas démarré : le schéma viendra du fichier d'init.
  if grep -qx "$container" <<< "$(docker ps --format '{{.Names}}')"; then
    docker exec "$container" psql -U "$db_user" -d "$db_name" -q \
      -c "CREATE SCHEMA IF NOT EXISTS \"${schema}\" AUTHORIZATION ${db_user};" \
      && ok "Schéma '${schema}' créé dans la base en cours d'exécution (${container})" \
      || warn "Création du schéma '${schema}' à chaud impossible — lancez : bash ensure-schemas.sh"
  fi
}

# Rendu du contenu d'un .env — factorisé pour être appelé deux fois par
# write_env_files() : une fois avec des placeholders (→ .env.example, commité),
# une fois avec les vraies valeurs (→ .env, gitignored). Ne JAMAIS appeler ceci
# directement pour écrire .env.example avec de vraies valeurs — c'est exactement
# le bug corrigé ici (SECRET_KEY/DB_PASSWORD réels commités dans .env.example,
# cf. .debug/ — a fuité dans l'historique public de plusieurs apps).
# $1 = valeur DB_PASSWORD/POSTGIS_PASSWORD à écrire, $2 = valeur SECRET_KEY à écrire
_render_env_content() {
  local schema="$1" has_db="$2" client_id="$3" bport="$4" fport="$5" \
        framework="$6" script_name="$7" db_instance="$8" db_pass_val="$9" secret_val="${10}"
  echo "# ── Adresses ─────────────────────────────────────────────────────"
  [[ -n "$bport" ]] && echo "PORT_BACKEND=${bport}"
  [[ -n "$bport" ]] && echo "BACKEND_URL=http://localhost:${bport}"
  [[ -n "$fport" ]] && echo "PORT_FRONTEND=${fport}"
  [[ -n "$fport" ]] && echo "FRONTEND_URL=http://localhost:${fport}"
  echo ""
  if [[ "$has_db" == "true" && "$db_instance" == "postgis" ]]; then
    # Instance PostGIS partagée (infra/docker-compose.yml — service 'postgis',
    # dev-postgis) : PAS 'postgres' (pas l'extension PostGIS, image alpine).
    echo "# ── Base de données (instance PostGIS partagée — apps SIG) ───────"
    echo "DB_HOST=postgis"
    echo "DB_PORT=5432"
    echo "DB_NAME=${ENV_DB_NAME}"
    echo "DB_SCHEMA=${schema}"
    echo "DB_USER=${ENV_DB_USER}"
    # POSTGIS_PASSWORD (et non DB_PASSWORD) : clé distincte propagée par
    # reset_url.sh depuis infra/.env, pour ne jamais interférer avec le
    # DB_PASSWORD des apps sur l'instance 'postgres' partagée.
    echo "POSTGIS_PASSWORD=${db_pass_val}"
    echo ""
  elif [[ "$has_db" == "true" ]]; then
    echo "# ── Base de données ──────────────────────────────────────────────"
    echo "DB_HOST=postgres"
    echo "DB_PORT=5432"
    echo "DB_NAME=${ENV_DB_NAME}"
    echo "DB_SCHEMA=${schema}"
    echo "DB_USER=${ENV_DB_USER}"
    echo "DB_PASSWORD=${db_pass_val}"
    echo ""
  fi
  if [[ "$framework" == "django" ]]; then
    echo "# ── Django ───────────────────────────────────────────────────────"
    echo "SECRET_KEY=${secret_val}"
    echo "DEBUG=False"
    echo "ALLOWED_HOSTS=*"
    echo ""
    echo "# ── Reverse proxy (Caddy) ────────────────────────────────────────"
    echo "SCRIPT_NAME=${script_name}"
    echo ""
    # Email (contrat v9, I10) : déclarées VIDES. Le compte SMTP se rattache dans
    # lab-admin, qui les remplit par scripts/app-smtp.sh ; vides, Django affiche
    # les emails dans le journal du conteneur.
    echo "# ── Email (SMTP) ─────────────────────────────────────────────────"
    echo "EMAIL_HOST="
    echo "EMAIL_PORT="
    echo "EMAIL_HOST_USER="
    echo "EMAIL_HOST_PASSWORD="
    echo "EMAIL_USE_TLS="
    echo "EMAIL_USE_SSL="
    echo "DEFAULT_FROM_EMAIL="
    echo ""
  fi
  echo "# ── SSO Keycloak ─────────────────────────────────────────────────"
  echo "KEYCLOAK_CLIENT_ID=${client_id}"
  if [[ "$framework" != "django" ]]; then
    echo "KEYCLOAK_CLIENT_SECRET=<secret-depuis-keycloak>"
  fi
  echo "KEYCLOAK_ISSUER_URI=http://keycloak:8080/realms/ssolab"
  if [[ "$framework" == "django" && -n "$fport" ]]; then
    echo "# Client public (SPA Angular) — Keycloak → Clients → ${client_id} → Access type : Public"
    echo "# Valid redirect URIs : http://localhost:${fport}/*"
  elif [[ -n "$bport" && "$framework" != "django" ]]; then
    echo "# À configurer dans Keycloak → Clients → ${client_id} → Valid redirect URIs"
    echo "# KEYCLOAK_REDIRECT_URI=http://localhost:${bport}/login/oauth2/code/keycloak"
  elif [[ -n "$fport" ]]; then
    echo "# À configurer dans Keycloak → Clients → ${client_id} → Valid redirect URIs"
    echo "# KEYCLOAK_REDIRECT_URI=http://localhost:${fport}/*"
  fi
  echo ""
  echo "# ── URLs (propagées automatiquement par reset_url.sh) ────────────"
  echo "PORT_KEYCLOAK=8080"
  echo "SERVER_URL_LAN=http://192.168.1.X"
  echo "SERVER_URL_WAN=http://VOTRE_IP_WAN"
  echo "KEYCLOAK_URL=http://192.168.1.X:8080"
  echo "KEYCLOAK_PUBLIC_URL=http://VOTRE_IP_WAN:8080"
  echo ""
  echo "# ── HTTPS / Caddy ─────────────────────────────────────────────────────────────"
  echo "DOMAIN=CHANGE_ME"
}

# Crée .env.example (placeholders, commité) + .env (vraies valeurs, gitignored)
# dans $dir.
# $3 = "true" si l'app se connecte à la BDD, "false" sinon
# $5 = port backend (optionnel), $6 = port frontend (optionnel)
# $7 = framework : "django" | "spring" (défaut spring)
# $8 = script_name : préfixe de chemin Caddy (ex: /mon-app-api) pour SCRIPT_NAME Django
# $9 = instance DB : "postgres" (défaut, devdb) | "postgis" (gisdb, apps SIG)
write_env_files() {
  local dir="$1" schema="$2" has_db="$3" client_id="$4"
  local bport="${5:-}" fport="${6:-}" framework="${7:-spring}" script_name="${8:-}"
  local db_instance="${9:-postgres}"

  local _db_pass="" _secret=""
  if [[ "$has_db" == "true" ]]; then
    # Source de vérité du mot de passe partagé : infra/.env. On l'y lit plutôt
    # que de coder 'devpassword' en dur — sinon toute nouvelle app naîtrait avec
    # l'ancienne valeur, et reset_url.sh devrait la corriger. Au pire (infra/.env
    # absent au scaffold), reset_url.sh l'alignera au 1er setup2.
    # Mode « base par développeur » : c'est le mot de passe du rôle dev_<uid>
    # (DEV_PG_PASSWORD__<uid> / DEV_GIS_PASSWORD__<uid>), jamais celui du rôle
    # d'administration de l'instance.
    local _pass_var="$ENV_DB_PASS_KEY"
    # … lu dans infra/dev-roles.env pour un rôle dev_<uid> (contrat v3),
    # dans infra/.env pour les rôles historiques.
    local _pass_file="$DEV_DIR/infra/.env"
    [[ "$DB_MODE" == "dev" ]] && _pass_file="$DEV_DIR/infra/dev-roles.env"
    _db_pass="$(grep -E "^${_pass_var}=" "$_pass_file" 2>/dev/null | head -1 | cut -d= -f2-)"
    _db_pass="${_db_pass:-devpassword}"
  fi
  if [[ "$framework" == "django" ]]; then
    _secret="$(python3 -c 'import secrets; print(secrets.token_hex(32))' 2>/dev/null || echo 'change-this-in-production')"
  fi

  _render_env_content "$schema" "$has_db" "$client_id" "$bport" "$fport" \
    "$framework" "$script_name" "$db_instance" "CHANGE_ME" "CHANGE_ME" > "${dir}/.env.example"
  _render_env_content "$schema" "$has_db" "$client_id" "$bport" "$fport" \
    "$framework" "$script_name" "$db_instance" "$_db_pass" "$_secret" > "${dir}/.env"

  # Le .env porte des secrets (mot de passe de base, SECRET_KEY) : lisible du
  # seul propriétaire, sans dépendre du chmod final (qui passe par sudo).
  chmod 600 "${dir}/.env" 2>/dev/null || true
  ok ".env et .env.example créés"
}

# ──────────────────────────────────────────────────────────────────────────────
# GÉNÉRATEURS : DOCKERFILES
# ──────────────────────────────────────────────────────────────────────────────

dockerfile_spring() {
  cat > "$1/Dockerfile" << 'EOF'
# ── Stage 1 : compilation ──────────────────────────────────────────
FROM maven:3.9-eclipse-temurin-21 AS builder
WORKDIR /build
COPY pom.xml .
RUN mvn dependency:go-offline -q
COPY src ./src
RUN mvn package -DskipTests -q

# ── Stage 2 : image finale légère ─────────────────────────────────
FROM eclipse-temurin:21-jre-alpine
WORKDIR /app
COPY --from=builder /build/target/*.jar app.jar
EXPOSE 8080
ENTRYPOINT ["java", "-jar", "app.jar"]
EOF
  ok "Dockerfile Spring Boot"
}

dockerfile_django() {
  cat > "$1/Dockerfile" << 'EOF'
FROM python:3.12-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
EXPOSE 8000
# gunicorn et non runserver (serveur de développement). Réglages et raisons :
# gunicorn.conf.py (fourni par le gabarit).
CMD ["sh", "-c", "python manage.py migrate --no-input && exec gunicorn -c gunicorn.conf.py config.wsgi:application"]
EOF
  ok "Dockerfile Django"
}

dockerfile_angular() {
  local dir="$1" name="$2"
  cat > "${dir}/Dockerfile" << EOF
# ── Stage 1 : compilation ─────────────────────────────────
FROM node:20-alpine AS build
WORKDIR /app
COPY package*.json ./
RUN npm install --silent
COPY . .
RUN npm run build

# ── Stage 2 : servir avec nginx ──────────────────────────────
FROM nginx:alpine
COPY --from=build /app/dist/${name}/browser /usr/share/nginx/html
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY nginx-entrypoint.sh /docker-entrypoint.d/40-env-config.sh
RUN chmod +x /docker-entrypoint.d/40-env-config.sh
EXPOSE 80
EOF
  ok "Dockerfile Angular (nginx)"
}

requirements_django() {
  cat > "$1/requirements.txt" << 'EOF'
Django>=5.0,<6.0
psycopg2-binary>=2.9
python-decouple>=3.8
djangorestframework>=3.15
django-cors-headers>=4.3
PyJWT>=2.8
cryptography>=42.0
gunicorn>=23.0,<24.0
EOF
  ok "requirements.txt Django"
}

nginx_conf_angular() {
  local dir="$1" name="${2:-app}"
  cat > "${dir}/nginx.conf" << 'EOF'
server {
    listen 80;
    server_name _;
    root /usr/share/nginx/html;
    index index.html;

    location / {
        try_files $uri $uri/ /index.html;
        sub_filter '<base href="/">' '<base href="/__APP_PATH__/">';
        sub_filter_once on;
    }

    location = /assets/env.js {
        expires 0;
        add_header Cache-Control "no-cache, no-store, must-revalidate";
    }

    location ~* \.(js|css|woff2?|ttf|eot|svg|png|ico)$ {
        expires 7d;
        add_header Cache-Control "public, no-transform";
    }

    add_header X-Frame-Options SAMEORIGIN;
    add_header X-Content-Type-Options nosniff;
    add_header Referrer-Policy strict-origin-when-cross-origin;
}
EOF
  sed -i "s|__APP_PATH__|${name}|g" "${dir}/nginx.conf"
  ok "nginx.conf"
}

nginx_entrypoint_angular() {
  local dir="$1" has_backend="${2:-false}" app_name="${3:-}"
  {
    printf '#!/bin/sh\n'
    printf '# Généré par new-app.sh — injecte la configuration Keycloak dans env.js\n'
    printf 'set -e\n\n'
    printf 'ASSETS=/usr/share/nginx/html/assets\n'
    printf 'mkdir -p "$ASSETS"\n\n'
    printf 'if [ "${DOMAIN:-CHANGE_ME}" != "CHANGE_ME" ] && [ -n "${DOMAIN:-}" ]; then\n'
    printf '  cat > "$ASSETS/env.js" << JSEOF\n'
    printf 'window.__env = {\n'
    printf '  keycloakUrl:      "${KEYCLOAK_PUBLIC_URL:-http://localhost:8080}",\n'
    printf '  keycloakRealm:    "${KEYCLOAK_REALM:-ssolab}",\n'
    printf '  keycloakClientId: "${KEYCLOAK_CLIENT_ID}",\n'
    if [[ "$has_backend" == "true" ]]; then
      printf '  apiUrl:           "https://${DOMAIN}/%s",\n' "${app_name}-api"
    fi
    printf '  appUrl:           "https://${DOMAIN}/%s/"\n' "${app_name}"
    printf '};\n'
    printf 'JSEOF\n'
    printf 'else\n'
    printf '  cat > "$ASSETS/env.js" << JSEOF\n'
    printf 'window.__env = {\n'
    printf '  keycloakUrl:      "${KEYCLOAK_PUBLIC_URL:-http://localhost:8080}",\n'
    printf '  keycloakRealm:    "${KEYCLOAK_REALM:-ssolab}",\n'
    printf '  keycloakClientId: "${KEYCLOAK_CLIENT_ID}",\n'
    if [[ "$has_backend" == "true" ]]; then
      printf "  apiUrl:           window.location.protocol + '//' + window.location.hostname + ':\${PORT_BACKEND:-8000}',\n"
    fi
    printf "  appUrl:           window.location.protocol + '//' + window.location.hostname + ':\${PORT_FRONTEND:-4200}'\n"
    printf '};\n'
    printf 'JSEOF\n'
    printf 'fi\n\n'
    printf 'chmod 644 "$ASSETS/env.js"\n'
    printf 'echo "[nginx] env.js généré."\n'
  } > "${dir}/nginx-entrypoint.sh"
  chmod +x "${dir}/nginx-entrypoint.sh"
  ok "nginx-entrypoint.sh"
}

# ──────────────────────────────────────────────────────────────────────────────
# GÉNÉRATEURS : DOCKER-COMPOSE
# ──────────────────────────────────────────────────────────────────────────────

dc_spring_only() {
  local dir="$1" name="$2" port="$3"
  cat > "${dir}/docker-compose.yml" << EOF
version: "3.9"

networks:
  sso-net:
    external: true
    name: sso-lab_sso-net
  dev-net:
    external: true
    name: dev-net

services:
  ${name}:
    build: .
    # « <app>-app » et non « <app> » : tout conteneur d'une app porte le préfixe
    # « <app>- » (règle contrôlée par validate-app.sh, contrat multi-dev I4).
    container_name: ${name}-app
    restart: unless-stopped
    env_file: .env
    ports:
      - "${port}:8080"
    networks:
      - sso-net
      - dev-net
    labels:
      caddy: "\${DOMAIN}"
      caddy.handle_path: "/${name}/*"
      caddy.handle_path.reverse_proxy: "{{upstreams 8080}}"
EOF
  ok "docker-compose.yml"
}

dc_django_only() {
  local dir="$1" name="$2" port="$3"
  cat > "${dir}/docker-compose.yml" << EOF
version: "3.9"

networks:
  sso-net:
    external: true
    name: sso-lab_sso-net
  dev-net:
    external: true
    name: dev-net

services:
  ${name}:
    build: .
    # « <app>-app » et non « <app> » : tout conteneur d'une app porte le préfixe
    # « <app>- » (règle contrôlée par validate-app.sh, contrat multi-dev I4).
    container_name: ${name}-app
    restart: unless-stopped
    env_file: .env
    ports:
      - "${port}:8000"
    networks:
      - sso-net
      - dev-net
    labels:
      caddy: "\${DOMAIN}"
      caddy.handle_path: "/${name}/*"
      caddy.handle_path.reverse_proxy: "{{upstreams 8000}}"
EOF
  ok "docker-compose.yml"
}

dc_angular_only() {
  local dir="$1" name="$2" port="$3"
  cat > "${dir}/docker-compose.yml" << EOF
version: "3.9"

# Angular SPA servie par nginx.
# Les appels vers Keycloak et l'API sont effectués par le navigateur.

networks:
  sso-net:
    external: true
    name: sso-lab_sso-net

services:
  ${name}:
    build: .
    # « <app>-app » et non « <app> » : tout conteneur d'une app porte le préfixe
    # « <app>- » (règle contrôlée par validate-app.sh, contrat multi-dev I4).
    container_name: ${name}-app
    restart: unless-stopped
    # Uniquement les variables que lit nginx-entrypoint.sh pour écrire env.js —
    # aucune n'est secrète (env.js est servi au navigateur). Jamais « env_file: .env »
    # ici : il donnerait à ce conteneur nginx tous les secrets de l'app.
    environment:
      DOMAIN: \${DOMAIN:-}
      KEYCLOAK_CLIENT_ID: \${KEYCLOAK_CLIENT_ID:-}
      KEYCLOAK_PUBLIC_URL: \${KEYCLOAK_PUBLIC_URL:-}
      KEYCLOAK_REALM: \${KEYCLOAK_REALM:-}
      PORT_BACKEND: \${PORT_BACKEND:-}
      PORT_FRONTEND: \${PORT_FRONTEND:-}
    ports:
      - "${port}:80"
    networks:
      - sso-net
    labels:
      caddy: "\${DOMAIN}"
      caddy.handle_path: "/${name}/*"
      caddy.handle_path.reverse_proxy: "{{upstreams 80}}"
EOF
  ok "docker-compose.yml"
}

dc_spring_angular() {
  local dir="$1" name="$2" bport="$3" fport="$4"
  cat > "${dir}/docker-compose.yml" << EOF
version: "3.9"

networks:
  sso-net:
    external: true
    name: sso-lab_sso-net
  dev-net:
    external: true
    name: dev-net

services:

  backend:
    build: ./backend
    container_name: ${name}-backend
    restart: unless-stopped
    env_file: .env
    ports:
      - "${bport}:8080"
    networks:
      - sso-net
      - dev-net
    labels:
      caddy: "\${DOMAIN}"
      caddy.handle_path: "/${name}-api/*"
      caddy.handle_path.reverse_proxy: "{{upstreams 8080}}"

  frontend:
    build: ./frontend
    container_name: ${name}-frontend
    restart: unless-stopped
    # Uniquement les variables que lit nginx-entrypoint.sh pour écrire env.js —
    # aucune n'est secrète (env.js est servi au navigateur). Jamais « env_file: .env »
    # ici : il donnerait à ce conteneur nginx tous les secrets de l'app.
    environment:
      DOMAIN: \${DOMAIN:-}
      KEYCLOAK_CLIENT_ID: \${KEYCLOAK_CLIENT_ID:-}
      KEYCLOAK_PUBLIC_URL: \${KEYCLOAK_PUBLIC_URL:-}
      KEYCLOAK_REALM: \${KEYCLOAK_REALM:-}
      PORT_BACKEND: \${PORT_BACKEND:-}
      PORT_FRONTEND: \${PORT_FRONTEND:-}
    ports:
      - "${fport}:80"
    networks:
      - sso-net
    labels:
      caddy: "\${DOMAIN}"
      caddy.handle_path: "/${name}/*"
      caddy.handle_path.reverse_proxy: "{{upstreams 80}}"
EOF
  ok "docker-compose.yml (backend + frontend)"
}

dc_django_angular() {
  local dir="$1" name="$2" bport="$3" fport="$4"
  cat > "${dir}/docker-compose.yml" << EOF
version: "3.9"

networks:
  sso-net:
    external: true
    name: sso-lab_sso-net
  dev-net:
    external: true
    name: dev-net

services:

  backend:
    build: ./backend
    container_name: ${name}-backend
    restart: unless-stopped
    env_file: .env
    ports:
      - "${bport}:8000"
    networks:
      - sso-net
      - dev-net
    labels:
      caddy: "\${DOMAIN}"
      caddy.handle_path: "/${name}-api/*"
      caddy.handle_path.reverse_proxy: "{{upstreams 8000}}"

  frontend:
    build: ./frontend
    container_name: ${name}-frontend
    restart: unless-stopped
    # Uniquement les variables que lit nginx-entrypoint.sh pour écrire env.js —
    # aucune n'est secrète (env.js est servi au navigateur). Jamais « env_file: .env »
    # ici : il donnerait à ce conteneur nginx tous les secrets de l'app.
    environment:
      DOMAIN: \${DOMAIN:-}
      KEYCLOAK_CLIENT_ID: \${KEYCLOAK_CLIENT_ID:-}
      KEYCLOAK_PUBLIC_URL: \${KEYCLOAK_PUBLIC_URL:-}
      KEYCLOAK_REALM: \${KEYCLOAK_REALM:-}
      PORT_BACKEND: \${PORT_BACKEND:-}
      PORT_FRONTEND: \${PORT_FRONTEND:-}
    ports:
      - "${fport}:80"
    networks:
      - sso-net
    labels:
      caddy: "\${DOMAIN}"
      caddy.handle_path: "/${name}/*"
      caddy.handle_path.reverse_proxy: "{{upstreams 80}}"
EOF
  ok "docker-compose.yml (backend + frontend)"
}

# Un scaffold raté (réseau, Docker…) laisse un dossier sans manage.py ni
# angular.json : le script va au bout (le résumé reste utile pour reprendre à la
# main) mais se termine en ERREUR, pour qu'un appelant non interactif ne prenne
# pas cette coquille pour une app créée.
SCAFFOLD_FAILED=false

# ──────────────────────────────────────────────────────────────────────────────
# SCAFFOLDING : SPRING BOOT (via Spring Initializr)
# ──────────────────────────────────────────────────────────────────────────────
scaffold_spring() {
  local dir="$1" name="$2" schema="$3"
  step "Spring Boot — téléchargement via start.spring.io (connexion internet requise)..."

  local tmpdir
  tmpdir="$(mktemp -d)"

  if ! curl -sf "https://start.spring.io/starter.zip" \
      -d type=maven-project \
      -d language=java \
      -d bootVersion=3.2.5 \
      -d baseDir="${name}" \
      -d groupId=com.dev \
      -d artifactId="${name}" \
      -d name="${name}" \
      -d dependencies=web,security,oauth2-client,data-jpa,postgresql \
      -o "${tmpdir}/starter.zip"; then
    rm -rf "$tmpdir"
    warn "Échec de Spring Initializr — vérifier la connexion internet."
    info  "Créer manuellement sur https://start.spring.io"
    SCAFFOLD_FAILED=true
    return
  fi

  unzip -q "${tmpdir}/starter.zip" -d "${tmpdir}"
  cp -r "${tmpdir}/${name}/." "${dir}/"
  rm -rf "$tmpdir"

  # Remplacer application.properties par application.yml configuré
  rm -f "${dir}/src/main/resources/application.properties"
  cat > "${dir}/src/main/resources/application.yml" << EOF
server:
  port: 8080

spring:
  application:
    name: ${name}

  datasource:
    url: jdbc:postgresql://\${DB_HOST:postgres}:\${DB_PORT:5432}/\${DB_NAME:devdb}?currentSchema=\${DB_SCHEMA:${schema}}
    username: \${DB_USER:devuser}
    password: \${DB_PASSWORD:devpassword}
    driver-class-name: org.postgresql.Driver

  jpa:
    hibernate:
      ddl-auto: update
    properties:
      hibernate:
        default_schema: \${DB_SCHEMA:${schema}}
    show-sql: false

  security:
    oauth2:
      client:
        registration:
          keycloak:
            client-id: \${KEYCLOAK_CLIENT_ID:${name}}
            client-secret: \${KEYCLOAK_CLIENT_SECRET}
            scope: openid, profile, email
            authorization-grant-type: authorization_code
            redirect-uri: "{baseUrl}/login/oauth2/code/{registrationId}"
        provider:
          keycloak:
            issuer-uri: \${KEYCLOAK_ISSUER_URI:http://keycloak:8080/realms/ssolab}
            user-name-attribute: preferred_username

logging:
  level:
    org.springframework.security.oauth2: DEBUG
EOF
  ok "Projet Spring Boot scaffoldé + application.yml configuré"
}

# ──────────────────────────────────────────────────────────────────────────────
# SCAFFOLDING : DJANGO (via Docker)
# ──────────────────────────────────────────────────────────────────────────────
scaffold_django() {
  local dir="$1" name="$2" schema="$3" tmpl_name="${4:-django-angular/backend}"
  step "Django — scaffold via Docker (image python:3.12-slim)..."

  # Le démon Docker de ce lab est distant (filesystem séparé de l'hôte code-server) :
  # les bind mounts (-v) sont inertes, ils ne livrent aucun fichier. On génère dans un
  # conteneur jetable puis on récupère via `docker cp` (le seul pont hôte<->conteneur ici).
  local cname="scaffold-django-$$"
  docker rm -f "$cname" >/dev/null 2>&1 || true
  if ! docker run --name "$cname" \
      python:3.12-slim \
      sh -c "mkdir -p /app && cd /app && pip install django -q 2>/dev/null && django-admin startproject config ."; then
    docker rm -f "$cname" >/dev/null 2>&1 || true
    warn "Échec du scaffold Django."
    SCAFFOLD_FAILED=true
    return
  fi

  docker cp "${cname}:/app/." "${dir}/"
  docker rm -f "$cname" >/dev/null 2>&1 || true
  # sudo peut être indisponible sans TTY (ex. exécution non interactive) : les fichiers
  # copiés par `docker cp` appartiennent déjà à l'utilisateur courant dans la plupart des
  # environnements (rootless docker / remap userns) — ce chown est défensif, pas requis.
  # Cf. la même tolérance appliquée par le bloc de correction finale plus bas.
  if command -v sudo >/dev/null; then
    sudo chown -R "$(id -u):$(id -g)" "${dir}" 2>/dev/null || true
  fi

  ok "Projet Django scaffoldé (config/ + manage.py)"
  _configure_django_project "${dir}" "${name}" "${schema}" "${tmpl_name}"
}

# ──────────────────────────────────────────────────────────────────────────────
# SCAFFOLDING : ANGULAR (via Docker)
# ──────────────────────────────────────────────────────────────────────────────
scaffold_angular() {
  local dir="$1" name="$2" port="$3" bport="${4:-}" tmpl_name="${5:-django-angular/frontend}"
  step "Angular — scaffold via Docker (~2-3 min selon la connexion, télécharge les packages npm)..."

  # Le démon Docker de ce lab est distant (filesystem séparé de l'hôte code-server) :
  # les bind mounts (-v) sont inertes, ils ne livrent aucun fichier. On génère dans un
  # conteneur jetable puis on récupère via `docker cp` (le seul pont hôte<->conteneur ici).
  local cname="scaffold-angular-$$"
  docker rm -f "$cname" >/dev/null 2>&1 || true
  # Exécution en root (sans --user) — npm install -g nécessite root dans Alpine
  if ! docker run --name "$cname" \
      node:20-alpine \
      sh -c "npm install -g @angular/cli --silent 2>/dev/null \
             && mkdir -p /workspace \
             && ng new ${name} \
                  --directory /workspace/app \
                  --skip-git \
                  --style=scss \
                  --routing=true \
                  --skip-tests \
                  --no-ssr \
                  --defaults 2>/dev/null \
             && cd /workspace/app \
             && npm install keycloak-js@22.0.5 --save --silent 2>/dev/null"; then
    docker rm -f "$cname" >/dev/null 2>&1 || true
    warn "Échec du scaffold Angular."
    info  "Créer manuellement : ng new ${name}"
    SCAFFOLD_FAILED=true
    return
  fi

  docker cp "${cname}:/workspace/app/." "${dir}/"
  docker rm -f "$cname" >/dev/null 2>&1 || true
  # sudo peut être indisponible sans TTY (ex. exécution non interactive) : les fichiers
  # copiés par `docker cp` appartiennent déjà à l'utilisateur courant dans la plupart des
  # environnements (rootless docker / remap userns) — ce chown est défensif, pas requis.
  # Cf. la même tolérance appliquée par le bloc de correction finale plus bas.
  if command -v sudo >/dev/null; then
    sudo chown -R "$(id -u):$(id -g)" "${dir}" 2>/dev/null || true
  fi

  ok "Projet Angular scaffoldé (ng new + keycloak-js@22.0.5)"
  _apply_angular_template "${dir}" "${name}" "${bport}" "${port}" "${tmpl_name}"
}

# ──────────────────────────────────────────────────────────────────────────────
# CONFIGURATION POST-SCAFFOLD : DJANGO (template django-angular)
# ──────────────────────────────────────────────────────────────────────────────
_configure_django_project() {
  local dir="$1" name="$2" schema="$3" tmpl_name="${4:-django-angular/backend}"
  local tmpl="${DEV_DIR}/_templates/${tmpl_name}"

  if [[ ! -d "$tmpl" ]]; then
    warn "Template Django introuvable dans _templates/django-angular/backend/ — projet minimal conservé."
    return
  fi

  step "Application du template Django (modèles, migrations, Keycloak)..."

  # Calcul du titre (mon-app → Mon App)
  local title
  title="$(echo "${name}" | sed 's/-/ /g' | awk '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) substr($i,2); print}')"


  # Copie du template par-dessus le scaffold (remplace config/, ajoute api/)
  cp -r "${tmpl}/." "${dir}/"

  # Remplacement des placeholders dans tous les fichiers Python
  find "${dir}" -type f -name "*.py" | while IFS= read -r f; do
    sed -i \
      -e "s|__APP_NAME__|${name}|g" \
      -e "s|__APP_SLUG__|${schema}|g" \
      -e "s|__APP_TITLE__|${title}|g" \
      "${f}"
  done

  ok "Template Django appliqué — Departments + UserRecords + migrations d'exemple"
}

# ──────────────────────────────────────────────────────────────────────────────
# CONFIGURATION POST-SCAFFOLD : ANGULAR (template django-angular)
# ──────────────────────────────────────────────────────────────────────────────
_apply_angular_template() {
  local dir="$1" name="$2" bport="${3:-8000}" fport="$4" tmpl_name="${5:-django-angular/frontend}"
  local tmpl="${DEV_DIR}/_templates/${tmpl_name}"

  if [[ ! -d "$tmpl" ]]; then
    warn "Template Angular introuvable dans _templates/django-angular/frontend/ — projet minimal conservé."
    return
  fi

  step "Application du template Angular (Keycloak + composants d'exemple)..."

  # Nom de l'app sans suffixe -frontend (utilisé comme clientId Keycloak)
  local appname="${name%-frontend}"
  local title
  title="$(echo "${appname}" | sed 's/-/ /g' | awk '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) substr($i,2); print}')"

  # Copie des fichiers de template par-dessus le projet ng new
  cp -r "${tmpl}/." "${dir}/"

  # Remplacement des placeholders
  find "${dir}/src" -type f | while IFS= read -r f; do
    sed -i \
      -e "s|__APP_NAME__|${appname}|g" \
      -e "s|__APP_TITLE__|${title}|g" \
      -e "s|__BACKEND_PORT__|${bport}|g" \
      -e "s|__FRONTEND_PORT__|${fport}|g" \
      "${f}"
  done

  # Mise à jour de angular.json : ajout de src/assets comme répertoire de ressources
  python3 - "${dir}/angular.json" << 'PYEOF'
import json, sys
path = sys.argv[1]
try:
    with open(path) as f:
        d = json.load(f)
    proj = list(d['projects'].values())[0]
    opts = proj['architect']['build']['options']
    current = opts.get('assets', [])
    extra = {'glob': '**/*', 'input': 'src/assets', 'output': 'assets'}
    if extra not in current:
        opts['assets'] = current + [extra]
    with open(path, 'w') as f:
        json.dump(d, f, indent=2)
    print('  → angular.json mis à jour (src/assets ajouté)')
except Exception as e:
    print(f'  ⚠ angular.json non modifié : {e}', file=sys.stderr)
PYEOF

  ok "Template Angular appliqué → ${title} (Keycloak + Accueil + Profil)"
}

# ──────────────────────────────────────────────────────────────────────────────
# ORCHESTRATION PRINCIPALE
# ──────────────────────────────────────────────────────────────────────────────
# Création du dossier principal et correction des permissions
# ── Retour arrière en cas d'échec (app d'un propriétaire explicite) ───────────
# À partir d'ici le script crée des choses à plusieurs endroits (registre,
# dossier, schéma PostgreSQL, .gitignore). S'il sort en erreur avant la fin —
# scaffold raté, base injoignable, interruption — il DÉFAIT ce qu'il a fait :
# un appelant non interactif (serveur MCP) retrouve l'état d'avant, sans schéma
# ni ligne de registre orphelins. La ligne .owners est écrite EN PREMIER (juste
# en dessous) : c'est elle qui autorise app-remove.sh à agir.
# Sans --owner (usage historique, à la main), rien n'est défait
# automatiquement : le dossier incomplet reste, pour être repris.
CREATION_DONE=false
_rollback_on_failure() {
  local rc=$?
  trap - EXIT
  if [[ $rc -ne 0 ]] && ! $CREATION_DONE && $OWNER_EXPLICIT; then
    echo -e "\n${YELLOW}⚠ Création de '$APP_NAME' interrompue (code $rc) — retour arrière…${NC}" >&2
    bash "$DEV_DIR/scripts/app-remove.sh" "$APP_NAME" --yes >&2 \
      || echo -e "${RED}✘ Retour arrière incomplet — relancer : bash scripts/app-remove.sh $APP_NAME --yes${NC}" >&2
  fi
  exit $rc
}
# (v5) La ligne .owners est écrite pour TOUTE app créée ici, superutilisateur
# compris : c'est elle qui marque « app créée après le chantier multi-dev »,
# donc soumise aux portes de qualité d'I8 (feuille de route, tests avant mise
# en service). Les apps historiques, sans ligne, gardent leur déploiement.
sed -i "/^${APP_NAME}:/d" "$DEV_DIR/.owners" 2>/dev/null || true
echo "${APP_NAME}:${OWNER}" >> "$DEV_DIR/.owners"
$OWNER_EXPLICIT && trap _rollback_on_failure EXIT

mkdir -p "$(registry_deploy_root)"
mkdir -p "$APP_DIR"
step "Création de $APP_DIR"
# Propriétaire (contrat multi-dev I1) : une ligne « <app>:<uid> » dans .owners,
# écrite AVANT tout le reste — ensure-schemas.sh et reset_url.sh s'y réfèrent.
# Sans --owner, aucune ligne : l'app appartient au superutilisateur par défaut,
# exactement comme les apps existantes.
ok "Propriétaire enregistré dans .owners (${APP_NAME}:${OWNER})"
# Ajoute le dossier de l'app au .gitignore si absent
if ! grep -qxF "$APP_REL/" "$DEV_DIR/.gitignore"; then
  echo "$APP_REL/" >> "$DEV_DIR/.gitignore"
  ok "$APP_REL/ ajouté à .gitignore"
fi

# .gitignore PROPRE À L'APP (pas celui du dépôt parent ci-dessus) : indispensable
# avant `git init && git add .` à l'étape 2 du scaffold (README), sans quoi .env
# (vrais secrets : DB_PASSWORD, SECRET_KEY…) partirait sur le dépôt GitHub public.
cat > "${APP_DIR}/.gitignore" << 'EOF'
# ── Secrets / config locale ──────────────────────────────────────────────────
.env
.keycloak-client-opts

# ── Python / Django (racine si app Django seul, backend/ si Django+Angular) ───
__pycache__/
*.py[cod]
*.egg-info/
.venv/
venv/
db.sqlite3
# « /backend/media/ » et non « media/ » : un service media/ dans une app (ex. peripheriques/media,
# MediaMTX) doit rester versionné.
/backend/media/

# ── Angular / Node (racine si app Angular seul, frontend/ si +Angular) ────────
node_modules/
dist/
.angular/
frontend/node_modules/
frontend/dist/
frontend/.angular/

# ── Divers ───────────────────────────────────────────────────────────────────
*.log
.DS_Store
EOF
ok ".gitignore (propre à l'app)"

# ── Règles de développement (contrat v5, I8) ──────────────────────────────────
# Tout projet scaffoldé naît avec sa feuille de route et les consignes lues par
# les IA (CLAUDE.md pour Claude Code, AGENTS.md pour Mistral Vibe — même
# contenu). validate-app.sh refuse de déployer une app sans feuille de route au
# bon format : la présence du fichier n'est pas laissée à la bonne volonté.
_RULES_TMPL="$DEV_DIR/_templates/regles"
if [[ -d "$_RULES_TMPL" ]]; then
  case "$APP_TYPE" in
    3|4) _TEST_CMD="python manage.py test" ;;
    *)   _TEST_CMD="aucune" ;;   # pas de backend Django : app-test.sh n'a rien à lancer
  esac
  for _rf in FEUILLE_DE_ROUTE.md CLAUDE.md AGENTS.md; do
    sed -e "s|__APP_NAME__|${APP_NAME}|g" \
        -e "s|__TEST_COMMAND__|${_TEST_CMD}|g" \
        -e "s|__DATE__|$(date +%F)|g" \
        "$_RULES_TMPL/$_rf" > "$APP_DIR/$_rf"
  done
  ok "FEUILLE_DE_ROUTE.md, CLAUDE.md, AGENTS.md (règles de développement)"
else
  err "Gabarit des règles introuvable ($_RULES_TMPL) — une app sans feuille de route ne serait pas déployable."
fi

case "$APP_TYPE" in

  # ── 1) Spring Boot seul ──────────────────────────────────────────────────────
  1)
    dockerfile_spring  "$APP_DIR"
    dc_spring_only     "$APP_DIR" "$APP_NAME" "$BACKEND_PORT"
    write_env_files    "$APP_DIR" "$DB_SCHEMA" "true" "$APP_NAME" "$BACKEND_PORT" "" "" "" "$DB_INSTANCE"
    add_schema         "$DB_SCHEMA" "$DB_INSTANCE"
    register_ports     "$APP_NAME" "$BACKEND_PORT" ""
    [[ "$DO_SCAFFOLD" =~ ^[Oo]$ ]] && scaffold_spring "$APP_DIR" "$APP_NAME" "$DB_SCHEMA"
    ;;

  # ── 2) Spring Boot + Angular ─────────────────────────────────────────────────
  2)
    mkdir -p "$APP_DIR/backend" "$APP_DIR/frontend"
    dockerfile_spring        "$APP_DIR/backend"
    dockerfile_angular       "$APP_DIR/frontend" "${APP_NAME}-frontend"
    nginx_conf_angular       "$APP_DIR/frontend" "$APP_NAME"
    nginx_entrypoint_angular "$APP_DIR/frontend" "true" "$APP_NAME"
    dc_spring_angular        "$APP_DIR" "$APP_NAME" "$BACKEND_PORT" "$ANGULAR_PORT"
    write_env_files          "$APP_DIR" "$DB_SCHEMA" "true" "$APP_NAME" "$BACKEND_PORT" "$ANGULAR_PORT" "" "" "$DB_INSTANCE"
    add_schema               "$DB_SCHEMA" "$DB_INSTANCE"
    register_ports           "$APP_NAME" "$BACKEND_PORT" "$ANGULAR_PORT"
    if [[ "$DO_SCAFFOLD" =~ ^[Oo]$ ]]; then
      scaffold_spring  "$APP_DIR/backend"  "$APP_NAME"              "$DB_SCHEMA"
      if [[ -n "${SUDO_UID-}" ]]; then
        chown -R "${SUDO_UID}:${SUDO_GID:-$(id -g)}" "$APP_DIR/backend" 2>/dev/null || true
      else
        chown -R "$(id -u):$(id -g)" "$APP_DIR/backend" 2>/dev/null || true
      fi
      scaffold_angular "$APP_DIR/frontend" "${APP_NAME}-frontend"   "$ANGULAR_PORT" "$BACKEND_PORT"
      if [[ -n "${SUDO_UID-}" ]]; then
        chown -R "${SUDO_UID}:${SUDO_GID:-$(id -g)}" "$APP_DIR/frontend" 2>/dev/null || true
      else
        chown -R "$(id -u):$(id -g)" "$APP_DIR/frontend" 2>/dev/null || true
      fi
    fi
    ;;

  # ── 3) Django seul ───────────────────────────────────────────────────────────
  3)
    dockerfile_django   "$APP_DIR"
    requirements_django "$APP_DIR"
    dc_django_only      "$APP_DIR" "$APP_NAME" "$BACKEND_PORT"
    write_env_files     "$APP_DIR" "$DB_SCHEMA" "true" "$APP_NAME" "$BACKEND_PORT" "" "django" "/${APP_NAME}" "$DB_INSTANCE"
    add_schema          "$DB_SCHEMA" "$DB_INSTANCE"
    register_ports      "$APP_NAME" "$BACKEND_PORT" ""
    # Sans ce fichier, create-app-client.sh n'aurait aucun --require-group à appliquer
    # et KEYCLOAK_REQUIRED_GROUPS resterait vide : l'API accepterait tout compte du realm.
    printf -- '--port %s --caddy-path %s%s\n' "$BACKEND_PORT" "$APP_NAME" "$KC_GROUP_OPT" > "${APP_DIR}/.keycloak-client-opts"
    ok ".keycloak-client-opts créé (client Django, port ${BACKEND_PORT}, path /${APP_NAME}${KC_GROUP_OPT:+, groupe(s):${REQUIRE_GROUP}})"
    [[ "$DO_SCAFFOLD" =~ ^[Oo]$ ]] && scaffold_django "$APP_DIR" "$APP_NAME" "$DB_SCHEMA" "django-only"
    ;;

  # ── 4) Django + Angular ──────────────────────────────────────────────────────
  4)
    mkdir -p "$APP_DIR/backend" "$APP_DIR/frontend"
    dockerfile_django        "$APP_DIR/backend"
    requirements_django      "$APP_DIR/backend"
    dockerfile_angular       "$APP_DIR/frontend" "${APP_NAME}-frontend"
    nginx_conf_angular       "$APP_DIR/frontend" "$APP_NAME"
    nginx_entrypoint_angular "$APP_DIR/frontend" "true" "$APP_NAME"
    dc_django_angular        "$APP_DIR" "$APP_NAME" "$BACKEND_PORT" "$ANGULAR_PORT"
    write_env_files          "$APP_DIR" "$DB_SCHEMA" "true" "$APP_NAME" "$BACKEND_PORT" "$ANGULAR_PORT" "django" "/${APP_NAME}-api" "$DB_INSTANCE"
    add_schema               "$DB_SCHEMA" "$DB_INSTANCE"
    register_ports           "$APP_NAME" "$BACKEND_PORT" "$ANGULAR_PORT"
    printf -- '--public --port %s --caddy-path %s%s\n' "$ANGULAR_PORT" "$APP_NAME" "$KC_GROUP_OPT" > "${APP_DIR}/.keycloak-client-opts"
    ok ".keycloak-client-opts créé (client public Angular, port ${ANGULAR_PORT}, path /${APP_NAME}${KC_GROUP_OPT:+, groupe(s):${REQUIRE_GROUP}})"
    if [[ "$DO_SCAFFOLD" =~ ^[Oo]$ ]]; then
      scaffold_django  "$APP_DIR/backend"  "$APP_NAME"            "$DB_SCHEMA"
      chown -R "$(id -u):$(id -g)" "$APP_DIR/backend" 2>/dev/null || true
      scaffold_angular "$APP_DIR/frontend" "${APP_NAME}-frontend" "$ANGULAR_PORT" "$BACKEND_PORT"
      chown -R "$(id -u):$(id -g)" "$APP_DIR/frontend" 2>/dev/null || true
    fi
    ;;

  # ── 5) Angular seul ──────────────────────────────────────────────────────────
  5)
    dockerfile_angular       "$APP_DIR" "$APP_NAME"
    nginx_conf_angular       "$APP_DIR" "$APP_NAME"
    nginx_entrypoint_angular "$APP_DIR" "false" "$APP_NAME"
    dc_angular_only          "$APP_DIR" "$APP_NAME" "$ANGULAR_PORT"
    write_env_files          "$APP_DIR" "$DB_SCHEMA" "false" "$APP_NAME" "" "$ANGULAR_PORT"
    # Pas de schéma BDD : Angular est un frontend, il ne se connecte pas à PostgreSQL
    register_ports           "$APP_NAME" "" "$ANGULAR_PORT"
    printf -- '--public --port %s --caddy-path %s%s\n' "$ANGULAR_PORT" "$APP_NAME" "$KC_GROUP_OPT" > "${APP_DIR}/.keycloak-client-opts"
    ok ".keycloak-client-opts créé (client public Angular, port ${ANGULAR_PORT}, path /${APP_NAME}${KC_GROUP_OPT:+, groupe(s):${REQUIRE_GROUP}})"
    [[ "$DO_SCAFFOLD" =~ ^[Oo]$ ]] && scaffold_angular "$APP_DIR" "$APP_NAME" "$ANGULAR_PORT" "" "angular-only" && {
      if [[ -n "${SUDO_UID-}" ]]; then
        chown -R "${SUDO_UID}:${SUDO_GID:-$(id -g)}" "$APP_DIR" 2>/dev/null || true
      else
        chown -R "$(id -u):$(id -g)" "$APP_DIR" 2>/dev/null || true
      fi
    }
    ;;

esac

# ──────────────────────────────────────────────────────────────────────────────
# RÉSUMÉ
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${GREEN}════════════════════════════════════════${NC}"
echo -e "${BOLD}${GREEN}  '$APP_NAME' prête !${NC}"
echo -e "${BOLD}${GREEN}════════════════════════════════════════${NC}"
echo ""
echo -e "  ${BOLD}Dossier  ${NC}: $APP_DIR"
[[ -n "$BACKEND_PORT" ]] && echo -e "  ${BOLD}Backend  ${NC}: http://localhost:${BACKEND_PORT}"
[[ -n "$ANGULAR_PORT" ]] && echo -e "  ${BOLD}Frontend ${NC}: http://localhost:${ANGULAR_PORT}"
echo ""
echo -e "  ${YELLOW}${BOLD}Étapes suivantes :${NC}"
echo -e "  ${BOLD}1.${NC} Remplir ${CYAN}${APP_REL}/.env${NC} (DOMAIN, KEYCLOAK_CLIENT_SECRET…)"
if [[ "$APP_TYPE" =~ ^[45]$ ]]; then
  echo -e "  ${BOLD}2.${NC} Créer le client Keycloak automatiquement :"
  echo -e "     ${CYAN}bash create-app-client.sh ${APP_NAME} \$(cat ${APP_REL}/.keycloak-client-opts)${NC}"
else
  echo -e "  ${BOLD}2.${NC} Créer le client '${APP_NAME}' dans Keycloak"
  echo -e "     → ${CYAN}http://localhost:8080${NC} — realm ssolab — Clients — Create client"
  if [[ -n "$BACKEND_PORT" ]]; then
    echo -e "     Valid redirect URIs : ${CYAN}http://localhost:${BACKEND_PORT}/*${NC}"
  elif [[ -n "$ANGULAR_PORT" ]]; then
    echo -e "     Valid redirect URIs : ${CYAN}http://localhost:${ANGULAR_PORT}/*${NC}"
  fi
fi
if [[ "$APP_TYPE" != "5" && "$DB_MODE" == "dev" ]]; then
  echo -e "  ${BOLD}3.${NC} Schéma '${DB_SCHEMA}' créé dans ${CYAN}${ENV_DB_NAME}${NC} (rôle ${ENV_DB_USER})"
elif [[ "$APP_TYPE" != "5" ]]; then
  if [[ "$DB_INSTANCE" == "postgis" ]]; then
    echo -e "  ${BOLD}3.${NC} Si le container postgis tourne déjà (schéma absent du volume) :"
    echo -e "     ${CYAN}docker exec -it dev-postgis psql -U gisuser -d gisdb \\"
    echo -e "       -c \"CREATE SCHEMA IF NOT EXISTS ${DB_SCHEMA};\"${NC}"
  else
    echo -e "  ${BOLD}3.${NC} Si le container postgres tourne déjà (schéma absent du volume) :"
    echo -e "     ${CYAN}docker exec -it dev-postgres psql -U devuser -d devdb \\"
    echo -e "       -c \"CREATE SCHEMA IF NOT EXISTS ${DB_SCHEMA};\"${NC}"
  fi
fi
echo ""
echo -e "  ${BOLD}Lancer :${NC} ${CYAN}bash setup2.sh ${APP_NAME} --yes${NC}"
echo ""

# ──────────────────────────────────────────────────────────────────────────────
# CORRECTION DES PERMISSIONS FINALE (si root)
# ──────────────────────────────────────────────────────────────────────────────
echo -e "\n${YELLOW}Correction des permissions sur $APP_DIR...${NC}"
# Si le script est lancé via sudo, restaurer la propriété au user appelant
if [[ -n "${SUDO_UID-}" ]]; then
  OWNER_UID="$SUDO_UID"
  OWNER_GID="${SUDO_GID:-$(id -g)}"
  OWNER_USER="$(id -nu "$OWNER_UID")"
  OWNER_GROUP="$(id -ng "$OWNER_GID")"
else
  OWNER_USER="$(id -un)"
  OWNER_GROUP="$(id -gn)"
fi

# Exécuter chown/chmod : si nous sommes root (id -u == 0) pas besoin de sudo
if [[ $(id -u) -eq 0 ]]; then
  chown -R "${OWNER_USER}:${OWNER_GROUP}" "$APP_DIR" 2>/dev/null || true
  chmod -R u+rwx,go-rwx "$APP_DIR" 2>/dev/null || true
  echo -e "  ${GREEN}✔ Propriétaire et permissions définis (${OWNER_USER}:${OWNER_GROUP})${NC}"
elif command -v sudo >/dev/null; then
  sudo chown -R "${OWNER_USER}:${OWNER_GROUP}" "$APP_DIR" 2>/dev/null || true
  sudo chmod -R u+rwx,go-rwx "$APP_DIR" 2>/dev/null || true
  echo -e "  ${GREEN}✔ Propriétaire et permissions définis avec sudo (${OWNER_USER}:${OWNER_GROUP})${NC}"
else
  chown -R "${OWNER_USER}:${OWNER_GROUP}" "$APP_DIR" 2>/dev/null || true
  chmod -R u+rwx,go-rwx "$APP_DIR" 2>/dev/null || true
  echo -e "  ${YELLOW}✔ Propriétaire et permissions définis (sans sudo) (${OWNER_USER}:${OWNER_GROUP})${NC}"
fi

if $SCAFFOLD_FAILED; then
  echo -e "\n${RED}${BOLD}✘ Le scaffold a échoué : '$APP_NAME' est incomplète.${NC}" >&2
  $OWNER_EXPLICIT || echo -e "  Pour tout retirer : bash scripts/app-remove.sh ${APP_NAME} --yes --superuser-app" >&2
  exit 1
fi
CREATION_DONE=true
