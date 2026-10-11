#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# dev-db.sh — PostgreSQL par développeur. Contrat « multi-dev » v2, interface I2.
#
#   Rôle   dev_<uid>   LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE (même nom sur les deux instances)
#   Base   dev_<uid>   sur dev-postgres, propriétaire dev_<uid>
#   Base   gis_<uid>   sur dev-postgis, à la demande (--gis), extension postgis posée ici
#   Schéma <app_slug>  un par app, propriétaire dev_<uid> (créé par ensure-schemas.sh)
#
# Source de vérité des mots de passe : infra/dev-roles.env (mode 600, gitignoré
# par « *.env »), clés DEV_PG_PASSWORD__<uid> (dev-postgres) et
# DEV_GIS_PASSWORD__<uid> (dev-postgis). reset_url.sh les propage vers les .env
# des apps DU PROPRIÉTAIRE seulement.
# JAMAIS infra/.env (contrat v3) : c'est l'`env_file` de dev-postgres et de
# dev-pgadmin — toute clé qu'on y écrit est injectée dans ces deux conteneurs et
# les fait recréer au prochain `docker compose up` d'infra. Ce script ne fait
# qu'y LIRE le nom des rôles d'administration (POSTGRES_USER / POSTGIS_USER).
#
# Usage :
#   bash scripts/dev-db.sh ensure <uid> [--gis]     provisionnement idempotent
#   bash scripts/dev-db.sh ensure-lab                    rôle et base `lab` du cadriciel (LAB_PG_PASSWORD)
#   bash scripts/dev-db.sh status lab|<uid> [--gis]      lecture seule : ce qui existe (code 0 = complet)
#   bash scripts/dev-db.sh rotate lab|<uid>              rotation à chaud du mot de passe du rôle
#   bash scripts/dev-db.sh ensure-all               rejoue `ensure` pour tout ce que dev-roles.env
#                                                   déclare (après recréation d'un volume)
#   bash scripts/dev-db.sh exists <uid> [--gis]     code 0 si la base existe, 1 sinon
#   bash scripts/dev-db.sh drop <uid> --yes         supprime bases + rôle + clés (refuse s'il
#                                                   reste une app du dev dans .owners)
#   bash scripts/dev-db.sh lockdown-connect [--apply]   ┐ PHASE 3 — jamais appelés par un autre
#   bash scripts/dev-db.sh lockdown-hba     [--apply]   ┘ script. Sans --apply : affichent seulement.
#   bash scripts/dev-db.sh hba-status                    lecture seule : trust|locked par instance (code 0 = verrouillé)
#
# COMMENT L'ISOLATION TIENT (et ce qui ne la tient PAS) :
#   • « chacun ne voit que ses projets » = un rôle non-superutilisateur qui ne
#     peut se CONNECTER qu'à sa propre base. PostgreSQL donne par défaut le droit
#     CONNECT à PUBLIC sur toute base : c'est `REVOKE … FROM PUBLIC` qui ferme la
#     porte, base par base. `ensure` le pose sur les bases qu'il crée ;
#     `lockdown-connect` le pose sur les bases historiques (devdb, gisdb,
#     postgres) — séparément, parce que ça touche des bases en service.
#   • pg_hba.conf : une instance initialisée aujourd'hui n'a AUCUNE ligne
#     `trust` réseau (les anciens infra/init*/01_pg_hba_trust.sh ont été
#     retirés du dépôt) — un conteneur de dev-net doit présenter un mot de
#     passe. `lockdown-hba` ne sert plus qu'à une instance née avant ce
#     retrait ; `hba-status` dit où en est chacune.
#
# Les scripts parlent à PostgreSQL par `docker exec` (socket local du
# conteneur), avec le rôle d'administration de l'instance (POSTGRES_USER /
# POSTGIS_USER de infra/.env). Le SQL passe par l'entrée standard, jamais par
# la ligne de commande : il contient des mots de passe, et argv est lisible par
# `ps` pour tout compte de l'hôte.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/registry.sh
source "$SCRIPT_DIR/lib/registry.sh"
ROOT="$(registry_root)"
INFRA_ENV="$ROOT/infra/.env"             # lecture seule (rôles d'administration)
ROLES_ENV="$ROOT/infra/dev-roles.env"    # mots de passe des rôles dev_<uid>

PG_CONTAINER="${PG_CONTAINER:-dev-postgres}"
GIS_CONTAINER="${GIS_CONTAINER:-dev-postgis}"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; RED='\033[0;31m'; NC='\033[0m'
ok()   { echo -e "  ${GREEN}✔ $*${NC}"; }
warn() { echo -e "  ${YELLOW}⚠ $*${NC}" >&2; }
info() { echo -e "  ${CYAN}→ $*${NC}"; }
die()  { echo -e "${RED}✘ $*${NC}" >&2; exit 1; }

usage() {
  sed -n '/^# Usage :/,/^#$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit 2
}

_infra_val() {
  [[ -f "$INFRA_ENV" ]] || return 0
  grep -E "^$1=" "$INFRA_ENV" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

# ── infra/dev-roles.env ───────────────────────────────────────────────────────
_roles_val() {
  [[ -f "$ROLES_ENV" ]] || return 0
  grep -E "^$1=" "$ROLES_ENV" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

# Réécriture atomique, toujours en 600. Les valeurs ne passent jamais par la
# ligne de commande d'un sous-processus (sed/grep les montreraient dans `ps`) :
# tout est fait par des commandes internes de bash.
_roles_rewrite() {  # $1 = clé à poser ou retirer, $2 = valeur (absente ⇒ retrait)
  local key="$1" tmp line found=false
  tmp="$(umask 077; mktemp "$ROLES_ENV.XXXXXX")" || die "écriture impossible dans $(dirname "$ROLES_ENV")"
  {
    if [[ -f "$ROLES_ENV" ]]; then
      while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" == "$key="* ]]; then
          if [[ $# -ge 2 ]] && ! $found; then printf '%s=%s\n' "$key" "$2"; fi
          found=true
        else
          printf '%s\n' "$line"
        fi
      done < "$ROLES_ENV"
    else
      printf '%s\n' "# Mots de passe des rôles PostgreSQL dev_<uid> — généré par scripts/dev-db.sh." \
                    "# Ne pas éditer à la main ; ne jamais référencer comme env_file d'un service."
    fi
    if [[ $# -ge 2 ]] && ! $found; then printf '%s=%s\n' "$key" "$2"; fi
  } > "$tmp"
  chmod 600 "$tmp"
  mv "$tmp" "$ROLES_ENV"
}
_roles_set()   { _roles_rewrite "$1" "$2"; }
_roles_unset() { [[ -f "$ROLES_ENV" ]] || return 0; _roles_rewrite "$1"; }

# Garde-fou v3 : une clé DEV_* dans infra/.env (reliquat d'une version
# antérieure, ou ajout à la main) serait injectée dans dev-postgres/dev-pgadmin.
# On refuse de travailler tant qu'elle y est, plutôt que de l'ignorer.
_assert_infra_env_clean() {
  if [[ -f "$INFRA_ENV" ]] && grep -qE '^DEV_(PG|GIS)_PASSWORD__' "$INFRA_ENV"; then
    die "infra/.env contient des clés DEV_*_PASSWORD__ : elles doivent vivre dans infra/dev-roles.env (les y déplacer, puis les retirer de infra/.env)."
  fi
}

# Sortie capturée puis cherchée (pas de tube vers `grep -q` sous pipefail : un
# SIGPIPE côté docker ferait passer un conteneur démarré pour arrêté).
_container_up() { local up; up="$(docker ps --format '{{.Names}}')"; grep -qx "$1" <<< "$up"; }

# Rôle d'administration et base de maintenance d'une instance.
_admin_user() {
  local u
  if [[ "$1" == "$GIS_CONTAINER" ]]; then u="$(_infra_val POSTGIS_USER)"; echo "${u:-gisuser}"
  else u="$(_infra_val POSTGRES_USER)"; echo "${u:-devuser}"; fi
}

# psql d'administration : SQL sur stdin, base en 2ᵉ argument.
_psql() {
  local container="$1" db="$2"; shift 2
  docker exec -i "$container" psql -X -U "$(_admin_user "$container")" -d "$db" -v ON_ERROR_STOP=1 -q "$@"
}
_scalar() {  # _scalar <container> <db> <requête sans donnée sensible>
  # Pas de `-i` : appelée dans des boucles `while read`, elle avalerait leur entrée.
  docker exec "$1" psql -X -U "$(_admin_user "$1")" -d "$2" -v ON_ERROR_STOP=1 -tA -c "$3" < /dev/null
}

_gen_password() { LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 40 || true; }

# ── ensure d'UN rôle + UNE base sur UNE instance ──────────────────────────────
# $1 container · $2 rôle · $3 nom de base · $4 clé dev-roles.env du mot de passe · $5 « postgis » ou « »
#
# IDEMPOTENT ET SANS ÉCRITURE INUTILE : sur une instance où tout est déjà en
# place, cette fonction ne lance AUCUNE instruction de modification — elle lit,
# constate et le dit. Elle n'écrit que ce qui manque :
#   • rôle absent            → CREATE ROLE avec le mot de passe de dev-roles.env ;
#   • attributs dangereux    → ALTER ROLE (sans toucher au mot de passe) ;
#   • base absente           → CREATE DATABASE ;
#   • propriétaire différent, ou CONNECT encore accordé à PUBLIC → corrigé.
# Le mot de passe d'un rôle EXISTANT n'est réaligné que si sa clé vient d'être
# générée (elle manquait dans dev-roles.env) ou sur demande explicite
# (LAB_DB_REALIGN=1, posé par rotate-db-password.sh).
_ensure_on() {
  local container="$1" role="$2" db="$3" key="$4" ext="${5:-}"
  local pw role_attrs db_owner public_connect key_new=false

  _container_up "$container" || die "Conteneur '$container' non démarré — provisionnement impossible (bash scripts/recompose_docker.sh --app infra)."
  [[ "$role" =~ ^[a-z_][a-z0-9_]*$ && "$db" =~ ^[a-z_][a-z0-9_]*$ ]] || die "nom de rôle ou de base invalide"

  pw="$(_roles_val "$key")"
  if [[ -z "$pw" ]]; then
    pw="$(_gen_password)"
    [[ ${#pw} -eq 40 ]] || die "Génération du mot de passe échouée."
    _roles_set "$key" "$pw"
    key_new=true
    info "$key généré dans infra/dev-roles.env"
  fi
  # Purement alphanumérique : aucune apostrophe à échapper dans le littéral SQL.
  [[ "$pw" =~ ^[A-Za-z0-9]{16,}$ ]] || die "$key (infra/dev-roles.env) doit être alphanumérique, 16 caractères minimum."

  # « login super createdb createrole replication bypassrls », p. ex. « t f f f f f »
  role_attrs="$(_scalar "$container" postgres "SELECT concat_ws(' ', rolcanlogin, rolsuper, rolcreatedb, rolcreaterole, rolreplication, rolbypassrls) FROM pg_roles WHERE rolname = '${role}'")"
  if [[ -z "$role_attrs" ]]; then
    _psql "$container" postgres <<SQL
CREATE ROLE "${role}" WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS PASSWORD '${pw}';
SQL
    ok "rôle ${role} créé sur ${container}"
  else
    if [[ "$role_attrs" != "t f f f f f" ]]; then
      _psql "$container" postgres <<SQL
ALTER ROLE "${role}" WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
SQL
      ok "rôle ${role} : attributs corrigés sur ${container} (étaient : ${role_attrs})"
    fi
    if $key_new || [[ "${LAB_DB_REALIGN:-}" == "1" ]]; then
      _psql "$container" postgres <<SQL
ALTER ROLE "${role}" WITH PASSWORD '${pw}';
SQL
      ok "rôle ${role} : mot de passe aligné sur dev-roles.env (${container})"
    else
      info "rôle ${role} déjà présent sur ${container} — rien à changer"
    fi
  fi

  db_owner="$(_scalar "$container" postgres "SELECT datdba::regrole::text FROM pg_database WHERE datname = '${db}'")"
  if [[ -z "$db_owner" ]]; then
    # CREATE DATABASE ne peut pas tourner dans une transaction : commande seule.
    _psql "$container" postgres <<SQL
CREATE DATABASE "${db}" OWNER "${role}";
SQL
    ok "base ${db} créée sur ${container} (propriétaire ${role})"
    db_owner="$role"
  elif [[ "$db_owner" != "$role" ]]; then
    _psql "$container" postgres <<SQL
ALTER DATABASE "${db}" OWNER TO "${role}";
SQL
    ok "base ${db} : propriétaire corrigé (${db_owner} → ${role})"
  else
    info "base ${db} déjà présente sur ${container}"
  fi

  # C'est CE REVOKE qui fait qu'un autre rôle ne peut pas se connecter à la
  # base. Posé seulement si PUBLIC a encore CONNECT (ACL vide = droits par
  # défaut = PUBLIC connecté). Le propriétaire garde ses droits.
  public_connect="$(_scalar "$container" postgres "SELECT (datacl IS NULL OR EXISTS (SELECT 1 FROM aclexplode(datacl) a WHERE a.grantee = 0 AND a.privilege_type = 'CONNECT')) FROM pg_database WHERE datname = '${db}'")"
  if [[ "$public_connect" == "t" ]]; then
    _psql "$container" postgres <<SQL
REVOKE ALL ON DATABASE "${db}" FROM PUBLIC;
GRANT ALL ON DATABASE "${db}" TO "${role}";
SQL
    ok "base ${db} : CONNECT retiré à PUBLIC"
  fi

  if [[ "$ext" == "postgis" ]]; then
    # Posée ICI par le rôle d'administration : CREATE EXTENSION postgis exige un
    # superutilisateur, que dev_<uid> n'est pas. Un `CREATE EXTENSION IF NOT
    # EXISTS postgis` lancé ensuite par une migration Django est alors un no-op
    # qui ne demande aucun privilège.
    if [[ "$(_scalar "$container" "$db" "SELECT 1 FROM pg_extension WHERE extname = 'postgis'")" != "1" ]]; then
      _psql "$container" "$db" <<SQL
CREATE EXTENSION IF NOT EXISTS postgis;
SQL
      ok "extension postgis posée dans ${db}"
    fi
  fi
}

cmd_ensure() {
  local uid="" gis=false a
  for a in "$@"; do
    case "$a" in
      --gis) gis=true ;;
      -*)    die "Option inconnue : $a" ;;
      *)     [[ -z "$uid" ]] && uid="$a" || die "Argument en trop : $a" ;;
    esac
  done
  registry_valid_uid "$uid" || die "uid invalide : '${uid}' (attendu : ^[a-z][a-z0-9]{1,30}\$)"
  [[ -f "$INFRA_ENV" ]] || die "$INFRA_ENV introuvable."
  _assert_infra_env_clean

  echo "── PostgreSQL de « ${uid} »"
  _ensure_on "$PG_CONTAINER" "dev_${uid}" "dev_${uid}" "DEV_PG_PASSWORD__${uid}"
  if $gis; then
    _ensure_on "$GIS_CONTAINER" "dev_${uid}" "gis_${uid}" "DEV_GIS_PASSWORD__${uid}" postgis
  fi
  ok "dev_${uid} prêt$($gis && echo " (+ gis_${uid})")"
}

# Base du CADRICIEL (contrat multi-dev v8) : rôle `lab`, non superutilisateur,
# base `lab` sur dev-postgres, mot de passe LAB_PG_PASSWORD dans dev-roles.env.
# C'est là que vivent les services du cadriciel restés à la racine (lab-admin,
# storage, oauth-hub, app-builder) ; reset_url.sh ne propage ce mot de passe
# qu'à eux. Même logique que `ensure` : ne change rien à ce qui est en place.
cmd_ensure_lab() {
  [[ $# -eq 0 ]] || die "ensure-lab ne prend pas d'argument"
  [[ -f "$INFRA_ENV" ]] || die "$INFRA_ENV introuvable."
  _assert_infra_env_clean
  echo "── PostgreSQL du cadriciel (base lab)"
  _ensure_on "$PG_CONTAINER" "lab" "lab" "LAB_PG_PASSWORD"
  ok "lab prêt"
}

# Rotation À CHAUD du mot de passe d'un rôle applicatif : `lab`, ou dev_<uid>
# (sur chaque instance où le rôle existe). L'ordre protège de la
# désynchronisation : ALTER ROLE d'abord, écriture de dev-roles.env seulement si
# la base l'a accepté. La propagation vers les .env des apps reste à
# reset_url.sh, et les backends doivent être redémarrés pour la prendre.
#   bash scripts/dev-db.sh rotate lab
#   bash scripts/dev-db.sh rotate <uid>
cmd_rotate() {
  local who="${1:-}" role container key new did=0
  [[ $# -eq 1 && -n "$who" ]] || die "rotate : « lab » ou un uid attendu"
  if [[ "$who" == "lab" ]]; then role="lab"
  else registry_valid_uid "$who" || die "uid invalide : '${who}'"; role="dev_${who}"; fi
  _assert_infra_env_clean
  for container in "$PG_CONTAINER" "$GIS_CONTAINER"; do
    if [[ "$who" == "lab" ]]; then
      [[ "$container" == "$PG_CONTAINER" ]] || continue
      key="LAB_PG_PASSWORD"
    elif [[ "$container" == "$GIS_CONTAINER" ]]; then key="DEV_GIS_PASSWORD__${who}"
    else key="DEV_PG_PASSWORD__${who}"; fi
    _container_up "$container" || { warn "$container non démarré — ${role} non roté sur cette instance"; continue; }
    [[ "$(_scalar "$container" postgres "SELECT 1 FROM pg_roles WHERE rolname = '${role}'")" == "1" ]] || continue
    new="$(_gen_password)"; [[ ${#new} -eq 40 ]] || die "Génération du mot de passe échouée."
    if _psql "$container" postgres <<SQL
ALTER ROLE "${role}" WITH PASSWORD '${new}';
SQL
    then
      _roles_set "$key" "$new"
      ok "${role} : mot de passe roté sur ${container} (${key})"
      did=$((did + 1))
    else
      die "${role} : ALTER ROLE refusé sur ${container} — ${key} laissé intact, ancien mot de passe toujours valide"
    fi
  done
  [[ $did -gt 0 ]] || die "rôle ${role} introuvable sur les instances démarrées — rien n'a été roté"
}

# Lecture seule : dit ce qui existe, n'écrit rien (ni en base, ni dans
# dev-roles.env). Code 0 = tout ce qui est attendu est en place.
#   bash scripts/dev-db.sh status lab            rôle + base lab
#   bash scripts/dev-db.sh status <uid> [--gis]  rôle + base(s) du développeur
cmd_status() {
  local who="" gis=false a missing=0
  for a in "$@"; do case "$a" in --gis) gis=true ;; -*) die "Option inconnue : $a" ;; *) who="$a" ;; esac; done
  [[ -n "$who" ]] || die "status : « lab » ou un uid attendu"
  local role db key
  _one() {  # _one <container> <rôle> <base> <clé>
    local c="$1" r="$2" d="$3" k="$4" attrs owner pub
    _container_up "$c" || { echo "  ✘ ${c} : conteneur arrêté"; missing=$((missing + 1)); return; }
    attrs="$(_scalar "$c" postgres "SELECT concat_ws(' ', rolcanlogin, rolsuper, rolcreatedb, rolcreaterole, rolreplication, rolbypassrls) FROM pg_roles WHERE rolname = '${r}'")"
    owner="$(_scalar "$c" postgres "SELECT datdba::regrole::text FROM pg_database WHERE datname = '${d}'")"
    pub="$(_scalar "$c" postgres "SELECT (datacl IS NULL OR EXISTS (SELECT 1 FROM aclexplode(datacl) a WHERE a.grantee = 0 AND a.privilege_type = 'CONNECT')) FROM pg_database WHERE datname = '${d}'")"
    if [[ "$attrs" == "t f f f f f" ]]; then echo "  ✔ rôle ${r} (${c}) : présent, non superutilisateur"
    elif [[ -z "$attrs" ]]; then echo "  ✘ rôle ${r} absent de ${c}"; missing=$((missing + 1))
    else echo "  ✘ rôle ${r} (${c}) : attributs inattendus (${attrs})"; missing=$((missing + 1)); fi
    if [[ "$owner" == "$r" ]]; then echo "  ✔ base ${d} (${c}) : présente, propriétaire ${r}"
    elif [[ -z "$owner" ]]; then echo "  ✘ base ${d} absente de ${c}"; missing=$((missing + 1))
    else echo "  ✘ base ${d} (${c}) : propriétaire ${owner}, attendu ${r}"; missing=$((missing + 1)); fi
    if [[ -n "$owner" && "$pub" == "t" ]]; then echo "  ✘ base ${d} (${c}) : CONNECT encore accordé à PUBLIC"; missing=$((missing + 1)); fi
    if [[ -n "$(_roles_val "$k")" ]]; then echo "  ✔ ${k} présent dans infra/dev-roles.env"
    else echo "  ✘ ${k} absent de infra/dev-roles.env"; missing=$((missing + 1)); fi
  }
  if [[ "$who" == "lab" ]]; then
    _one "$PG_CONTAINER" lab lab LAB_PG_PASSWORD
  else
    registry_valid_uid "$who" || die "uid invalide : '${who}'"
    _one "$PG_CONTAINER" "dev_${who}" "dev_${who}" "DEV_PG_PASSWORD__${who}"
    $gis && _one "$GIS_CONTAINER" "dev_${who}" "gis_${who}" "DEV_GIS_PASSWORD__${who}"
  fi
  return $(( missing > 0 ? 1 : 0 ))
}

# Rejoue le provisionnement de tout ce que dev-roles.env déclare : la base du
# cadriciel (LAB_PG_PASSWORD) et chaque développeur (DEV_PG_PASSWORD__<uid>).
# Sert après la recréation d'un volume PostgreSQL (infra/init*/ ne crée plus
# aucun schéma ni rôle applicatif) — appelé par setup2.sh en mode « tout le
# lab ». Sur une instance déjà en place, ne change rien.
cmd_ensure_all() {
  [[ -f "$ROLES_ENV" ]] || { info "infra/dev-roles.env absent — aucune base déclarée"; return 0; }
  local uid n=0 line
  if [[ -n "$(_roles_val LAB_PG_PASSWORD)" ]]; then
    cmd_ensure_lab; n=$((n + 1))
  fi
  while IFS= read -r uid; do
    [[ -n "$uid" ]] || continue
    if [[ -n "$(_roles_val "DEV_GIS_PASSWORD__${uid}")" ]]; then
      cmd_ensure "$uid" --gis
    else
      cmd_ensure "$uid"
    fi
    n=$((n + 1))
  done < <(while IFS= read -r line; do
             [[ "$line" =~ ^DEV_PG_PASSWORD__([a-z][a-z0-9]{1,30})= ]] && printf '%s\n' "${BASH_REMATCH[1]}"
           done < "$ROLES_ENV" | sort -u)
  [[ $n -eq 0 ]] && info "aucune base déclarée dans infra/dev-roles.env"
  return 0
}

cmd_exists() {
  local uid="" gis=false a
  for a in "$@"; do
    case "$a" in --gis) gis=true ;; -*) die "Option inconnue : $a" ;; *) uid="$a" ;; esac
  done
  registry_valid_uid "$uid" || die "uid invalide : '${uid}'"
  local container="$PG_CONTAINER" db="dev_${uid}"
  $gis && { container="$GIS_CONTAINER"; db="gis_${uid}"; }
  _container_up "$container" || exit 1
  [[ "$(_scalar "$container" postgres "SELECT 1 FROM pg_database WHERE datname = '${db}'" 2>/dev/null || true)" == "1" ]]
}

cmd_drop() {
  local uid="" yes=false a
  for a in "$@"; do
    case "$a" in --yes|-y) yes=true ;; -*) die "Option inconnue : $a" ;; *) uid="$a" ;; esac
  done
  registry_valid_uid "$uid" || die "uid invalide : '${uid}'"
  $yes || die "drop détruit les bases dev_${uid} / gis_${uid} et tout ce qu'elles contiennent : ajouter --yes."

  # Garde-fou : on ne retire pas la base sous une app encore enregistrée.
  if [[ -f "$ROOT/.owners" ]] && grep -qE "^[^:#]+:${uid}\$" "$ROOT/.owners"; then
    die "des apps appartiennent encore à « ${uid} » dans .owners — les retirer d'abord (scripts/app-remove.sh)."
  fi

  local container db role="dev_${uid}"
  for container in "$PG_CONTAINER" "$GIS_CONTAINER"; do
    _container_up "$container" || { warn "$container non démarré — ignoré"; continue; }
    if [[ "$container" == "$GIS_CONTAINER" ]]; then db="gis_${uid}"; else db="dev_${uid}"; fi
    if [[ "$(_scalar "$container" postgres "SELECT 1 FROM pg_database WHERE datname = '${db}'")" == "1" ]]; then
      _psql "$container" postgres <<SQL
DROP DATABASE "${db}" WITH (FORCE);
SQL
      ok "base ${db} supprimée (${container})"
    fi
    if [[ "$(_scalar "$container" postgres "SELECT 1 FROM pg_roles WHERE rolname = '${role}'")" == "1" ]]; then
      _psql "$container" postgres <<SQL
DROP ROLE "${role}";
SQL
      ok "rôle ${role} supprimé (${container})"
    fi
  done
  _roles_unset "DEV_PG_PASSWORD__${uid}"
  _roles_unset "DEV_GIS_PASSWORD__${uid}"
  ok "clés DEV_PG_PASSWORD__${uid} / DEV_GIS_PASSWORD__${uid} retirées de infra/dev-roles.env"
}

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 3 — verrouillage des bases historiques. JAMAIS appelé automatiquement.
# ══════════════════════════════════════════════════════════════════════════════

# REVOKE CONNECT … FROM PUBLIC sur toutes les bases qui l'ont encore (devdb,
# gisdb, postgres, mais aussi template1 / template_postgis : un rôle de dev
# pourrait sinon s'y connecter et y lire le catalogue de l'instance). Les superutilisateurs (devuser, gisuser) ne sont pas
# concernés par les droits. Tout rôle non-superutilisateur qui se connectait
# grâce à PUBLIC reçoit d'abord un GRANT explicite sur les bases où il a
# réellement des droits d'usage — sinon `carto_reader` (pg_featureserv de
# carto-lab) perdrait gisdb au passage.
cmd_lockdown_connect() {
  local apply=false a
  for a in "$@"; do case "$a" in --apply) apply=true ;; *) die "Option inconnue : $a" ;; esac; done

  local container db role sql
  for container in "$PG_CONTAINER" "$GIS_CONTAINER"; do
    _container_up "$container" || { warn "$container non démarré — ignoré"; continue; }
    echo "── ${container}"
    sql=""
    while IFS= read -r db; do
      [[ -n "$db" ]] || continue
      # Rôles non-superutilisateurs, hors dev_*, à qui l'usage d'un schéma de
      # cette base a été accordé NOMMÉMENT (pas via PUBLIC) : ils y travaillent
      # réellement, et dépendent aujourd'hui du CONNECT public.
      while IFS= read -r role; do
        [[ -n "$role" ]] || continue
        sql+="GRANT CONNECT ON DATABASE \"${db}\" TO \"${role}\";"$'\n'
      done < <(docker exec "$container" psql -X -U "$(_admin_user "$container")" -d "$db" -tA -c "
          SELECT DISTINCT r.rolname
          FROM pg_roles r
          JOIN pg_namespace n ON n.nspname !~ '^(pg_|information_schema)'
          CROSS JOIN LATERAL aclexplode(n.nspacl) a
          WHERE r.rolcanlogin AND NOT r.rolsuper
            AND r.rolname !~ '^(pg_|dev_)'
            AND a.grantee = r.oid AND a.privilege_type = 'USAGE'" < /dev/null 2>/dev/null || true)
      sql+="REVOKE CONNECT ON DATABASE \"${db}\" FROM PUBLIC;"$'\n'
    done < <(_scalar "$container" postgres "
        SELECT datname FROM pg_database
        WHERE datallowconn
          AND (datacl IS NULL
               OR EXISTS (SELECT 1 FROM aclexplode(datacl) a
                          WHERE a.grantee = 0 AND a.privilege_type = 'CONNECT'))
        ORDER BY 1")
    if [[ -z "$sql" ]]; then
      info "aucune base n'accorde plus CONNECT à PUBLIC"
      continue
    fi
    printf '%s' "$sql" | sed 's/^/    /'
    if $apply; then
      printf '%s' "$sql" | _psql "$container" postgres
      ok "appliqué sur ${container}"
    fi
  done
  $apply || echo -e "\n  (simulation — relancer avec --apply pour exécuter)"
}

# Retire les lignes `trust` RÉSEAU de pg_hba.conf (celles que
# infra/init*/01_pg_hba_trust.sh ont insérées) et recharge la configuration.
# Les lignes `local` / 127.0.0.1 / ::1 restent : c'est par elles que passent
# `docker exec … psql` (tous les scripts) et le healthcheck. Après ça, un
# conteneur de dev-net doit présenter un mot de passe, quel que soit son rôle.
#
# ⚠ À ne lancer qu'après avoir vérifié que plus aucune app ne compte sur le
#   trust : chaque .env doit porter un mot de passe à jour (reset_url.sh), et
#   pgAdmin doit avoir son mot de passe enregistré. Sauvegarde : pg_hba.conf.bak-<date>.
#
# ⚠ Les fichiers infra/init/01_pg_hba_trust.sh et infra/init-postgis/01_pg_hba_trust.sh
#   réinséreraient ces lignes à la prochaine initialisation d'un volume vierge :
#   les supprimer du dépôt (et retirer le montage du second dans
#   infra/docker-compose.yml) fait partie de la même étape.
cmd_lockdown_hba() {
  local apply=false a
  for a in "$@"; do case "$a" in --apply) apply=true ;; *) die "Option inconnue : $a" ;; esac; done

  local container hba lines stamp
  stamp="$(date +%Y%m%d-%H%M%S)"
  for container in "$PG_CONTAINER" "$GIS_CONTAINER"; do
    _container_up "$container" || { warn "$container non démarré — ignoré"; continue; }
    echo "── ${container}"
    hba="$(_scalar "$container" postgres "SHOW hba_file")"
    # Ligne `host…` dont la méthode est trust et l'adresse n'est pas la boucle locale.
    lines="$(docker exec "$container" awk '
        $1 ~ /^host/ && $NF == "trust" && $0 !~ /127\.0\.0\.1\/32/ && $0 !~ /::1\/128/ { print }' "$hba")"
    if [[ -z "$lines" ]]; then
      info "aucune ligne trust réseau dans ${hba}"
      continue
    fi
    echo "  Lignes à retirer de ${hba} :"
    printf '%s\n' "$lines" | sed 's/^/    /'
    if $apply; then
      # Le filtre tourne DANS le conteneur (le fichier appartient à postgres),
      # script passé sur stdin et chemins passés par l'environnement : aucun
      # emboîtement de guillemets. `cat >` et non `mv` : conserve l'inode, le
      # propriétaire et le mode du fichier d'origine.
      docker exec -i -e HBA="$hba" -e STAMP="$stamp" "$container" sh -s <<'INNER'
set -eu
cp -p "$HBA" "$HBA.bak-$STAMP"
awk '!($1 ~ /^host/ && $NF == "trust" && $0 !~ /127\.0\.0\.1\/32/ && $0 !~ /::1\/128/) { print }' \
  "$HBA.bak-$STAMP" > "$HBA.new"
cat "$HBA.new" > "$HBA"
rm -f "$HBA.new"
INNER
      _scalar "$container" postgres "SELECT pg_reload_conf()" >/dev/null
      ok "retirées, configuration rechargée (sauvegarde : ${hba}.bak-${stamp})"
    fi
  done
  $apply || echo -e "\n  (simulation — relancer avec --apply pour exécuter)"
}

# Lecture seule : dit si pg_hba.conf accepte encore une connexion RÉSEAU sans mot
# de passe. Une ligne par instance démarrée (« <conteneur> trust|locked »), code 0
# si toutes sont verrouillées, 1 si l'une garde une ligne trust réseau, 2 si une
# instance n'a pas pu être lue. Consommé par le moteur (lab-mcp) avant d'ouvrir un
# pgAdmin de développeur (contrat multi-dev, I9).
cmd_hba_status() {
  local container hba n rc=0
  for container in "$PG_CONTAINER" "$GIS_CONTAINER"; do
    _container_up "$container" || { echo "$container absent"; rc=2; continue; }
    hba="$(_scalar "$container" postgres "SHOW hba_file")" || { echo "$container illisible"; rc=2; continue; }
    n="$(docker exec "$container" awk '
        $1 ~ /^host/ && $NF == "trust" && $0 !~ /127\.0\.0\.1\/32/ && $0 !~ /::1\/128/ { n++ } END { print n+0 }' "$hba")" \
      || { echo "$container illisible"; rc=2; continue; }
    if [[ "$n" == "0" ]]; then echo "$container locked"; else echo "$container trust"; [[ $rc -eq 2 ]] || rc=1; fi
  done
  return $rc
}

[[ $# -ge 1 ]] || usage
CMD="$1"; shift
case "$CMD" in
  ensure)            cmd_ensure "$@" ;;
  ensure-all)        cmd_ensure_all "$@" ;;
  ensure-lab)        cmd_ensure_lab "$@" ;;
  status)            cmd_status "$@" ;;
  rotate)            cmd_rotate "$@" ;;
  exists)            cmd_exists "$@" ;;
  drop)              cmd_drop "$@" ;;
  lockdown-connect)  cmd_lockdown_connect "$@" ;;
  lockdown-hba)      cmd_lockdown_hba "$@" ;;
  hba-status)        cmd_hba_status "$@" ;;
  -h|--help)         usage ;;
  *)                 die "Commande inconnue : $CMD" ;;
esac
