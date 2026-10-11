#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# install.sh — installe le lab sur une machine neuve, ou complète une
#              installation interrompue. UNE commande, REJOUABLE.
#
# Usage :
#   bash scripts/install.sh --check        ne fait RIEN : dit ce qui est en place,
#                                          ce que l'installation ferait, ce qui manque
#   bash scripts/install.sh [options]      installe ce qui manque, ne refait pas le reste
#
# Options (chacune a son équivalent en variable d'environnement) :
#   --lan-ip <ip>          IP LAN de la machine            (défaut : détectée)
#   --wan <ip|url>         IP ou URL publique              (défaut : détectée par api.ipify.org)
#   --domain <fqdn>        nom de domaine public (HTTPS par Caddy) — voir « DOMAINE » ci-dessous
#   --acme-email <email>   contact Let's Encrypt
#   --superuser <uid>      superutilisateur du lab         (défaut : celui du .env, sinon l'utilisateur courant)
#   --no-apps              s'arrêter après le cadriciel (storage, oauth-hub, lab-admin, lab-mcp)
#   --no-workspace-image   ne pas construire lab-workspace (≈ 8 min)
#   --until <n>            s'arrêter après l'étape n (1 à 12) — p. ex. --until 6 : tout ce qui
#                          précède le premier démarrage de conteneur
#   --yes                  ne pose aucune question
#
# PRINCIPE : chaque étape regarde d'abord l'état réel (fichier présent ? volume
# créé ? conteneur en service ? rôle en base ?) et ne fait que ce qui manque.
# Rien de ce qui existe n'est régénéré : un .env présent n'est jamais réécrit
# par cette commande (hors propagation habituelle de reset_url.sh), un secret
# déjà posé n'est jamais remplacé, un volume déjà initialisé garde ses mots de
# passe. On peut donc la relancer après un échec, ou sur un lab en service.
#
# Ce que l'installation NE PEUT PAS faire, et qu'elle rappelle à la fin :
#   • enregistrer une application OAuth chez GitHub et en saisir le secret dans
#     oauth-hub (sans elle : ni création de projet, ni ticket, ni éditeur) ;
#   • le SMTP de Keycloak (mot de passe d'application) ;
#   • le nom de domaine et sa mise à jour (DDNS), les ports 80/443 du routeur ;
#   • ~/edge-router/ (répartiteur 80/443, hors dépôt) : sans lui, Caddy n'est
#     pas joignable depuis l'extérieur — voir README, section 1.5.
#
# DOMAINE : la couche multi-dev (moteur lab-mcp, espaces de travail, lab-admin
# « Projets ») exige HTTPS, donc DOMAIN. Sans domaine, l'installation va au bout
# du lab « HTTP local » et dit que le moteur n'a pas été démarré.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/registry.sh
source "$SCRIPT_DIR/lib/registry.sh"
# shellcheck source=lib/lock.sh
source "$SCRIPT_DIR/lib/lock.sh"
ROOT="$(registry_root)"
cd "$ROOT" || exit 1

CHECK=false; YES=false; NO_APPS=false; NO_WS=false; UNTIL=12
LAN_IP="${LAB_LAN_IP:-}"; WAN="${LAB_WAN:-}"; DOMAIN_ARG="${LAB_DOMAIN:-}"; ACME_ARG="${LAB_ACME_EMAIL:-}"; SU_ARG="${LAB_SUPERUSER:-}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --check)              CHECK=true ;;
    --yes|-y)             YES=true ;;
    --no-apps)            NO_APPS=true ;;
    --no-workspace-image) NO_WS=true ;;
    --until)      UNTIL="${2:?}"; shift; [[ "$UNTIL" =~ ^([1-9]|1[0-2])$ ]] || { echo "--until : 1 à 12" >&2; exit 2; } ;;
    --lan-ip)     LAN_IP="${2:?}"; shift ;;
    --wan)        WAN="${2:?}"; shift ;;
    --domain)     DOMAIN_ARG="${2:?}"; shift ;;
    --acme-email) ACME_ARG="${2:?}"; shift ;;
    --superuser)  SU_ARG="${2:?}"; shift ;;
    -h|--help)    sed -n '2,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Option inconnue : $1 (voir --help)" >&2; exit 2 ;;
  esac
  shift
done

# ── Affichage et comptes ──────────────────────────────────────────────────────
B='\033[1m'; G='\033[0;32m'; Y='\033[1;33m'; R='\033[0;31m'; C='\033[0;36m'; N='\033[0m'
N_TODO=0; N_GAP=0
TODOS=(); GAPS=()
STEP_NO=0
# Annonce une étape ; s'arrête proprement avant elle si --until est dépassé.
step()  {
  STEP_NO=$((STEP_NO + 1))
  if (( STEP_NO > UNTIL )); then
    echo -e "\n${C}Arrêt demandé après l'étape ${UNTIL} (--until). Relancer sans --until pour la suite.${N}"
    exit 0
  fi
  echo -e "\n${B}${C}══ $*${N}"
}
ok()    { echo -e "  ${G}✔${N} $*"; }
note()  { echo -e "  ${C}·${N} $*"; }
# À faire PAR L'INSTALLATION (en --check : listé ; sinon : annoncé puis fait).
todo()  { N_TODO=$((N_TODO + 1)); TODOS+=("$*"); if $CHECK; then echo -e "  ${Y}→ à faire :${N} $*"; else echo -e "  ${Y}→${N} $*"; fi; }
# Hors de portée de l'installation : geste humain ou décision.
gap()   { N_GAP=$((N_GAP + 1)); GAPS+=("$*"); echo -e "  ${R}✘ manque :${N} $*"; }
fail()  { echo -e "\n${R}${B}✗ ERROR install : $*${N}" >&2; echo "  Corriger, puis relancer : bash scripts/install.sh (elle reprend où elle s'est arrêtée)." >&2; exit 1; }
# Exécute une commande d'installation ; en --check, ne fait rien.
run()   { $CHECK && return 0; "$@"; }

envget() {  # envget <fichier> <clé> → valeur (guillemets retirés), vide si absente
  [[ -f "$1" ]] || return 0
  grep -E "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2- | sed -e 's/[[:space:]]*#.*$//' -e "s/^['\"]//" -e "s/['\"]\$//" || true
}
# Pose CLÉ=valeur dans un fichier (remplace la ligne, ou l'ajoute). Valeurs non secrètes seulement.
envset() {
  local file="$1" key="$2" val="$3" tmp line found=false
  tmp="$(umask 077; mktemp "$file.XXXXXX")"
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" == "$key="* ]]; then $found || printf '%s=%s\n' "$key" "$val"; found=true
    else printf '%s\n' "$line"; fi
  done < "$file" > "$tmp"
  $found || printf '%s=%s\n' "$key" "$val" >> "$tmp"
  chmod --reference="$file" "$tmp"; mv "$tmp" "$file"
}
is_placeholder() { [[ -z "$1" || "$1" == *CHANGE_ME* || "$1" == *VOTRE_IP_WAN* || "$1" == *192.168.1.X* ]]; }
running() { docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null | grep -q true; }
has_volume() { docker volume inspect "$1" > /dev/null 2>&1; }
unit_running() {  # au moins un conteneur en service pour ce projet Compose
  [[ -n "$(docker ps -q --filter "label=com.docker.compose.project=$1" 2>/dev/null)" ]]
}

$CHECK && echo -e "${B}install.sh --check${N} — lecture seule : rien n'est créé, modifié ni démarré."
$CHECK || lab_lock_acquire "install.sh" || exit $?

# ══════════════════════════════════════════════════════════════════════════════
step "1/12  Prérequis"
MISSING=()
for c in docker git jq curl openssl python3 flock ss ip awk sed; do
  command -v "$c" > /dev/null 2>&1 || MISSING+=("$c")
done
docker compose version > /dev/null 2>&1 || MISSING+=("docker-compose-plugin")
if [[ ${#MISSING[@]} -gt 0 ]]; then
  gap "commandes absentes : ${MISSING[*]} (Debian : apt install docker.io docker-compose-plugin git jq curl openssl python3 util-linux iproute2)"
  $CHECK || fail "prérequis manquants"
else
  ok "docker, docker compose, git, jq, curl, openssl, python3, flock, ss, ip"
fi
if docker info > /dev/null 2>&1; then ok "le démon Docker répond à $(id -un)"
else
  gap "$(id -un) ne peut pas parler à Docker (sudo usermod -aG docker $(id -un), puis se reconnecter)"
  $CHECK || fail "Docker inaccessible"
fi

# ══════════════════════════════════════════════════════════════════════════════
step "2/12  Sous-modules"
# Un sous-module non extrait = un dossier vide = une app sans docker-compose.yml,
# donc invisible. On tente de l'extraire ; un dépôt inaccessible (projet privé
# d'un autre) est signalé et l'installation continue sans lui.
if [[ -f .gitmodules ]]; then
  while IFS= read -r _path; do
    [[ -n "$_path" ]] || continue
    if [[ -n "$(ls -A "$_path" 2>/dev/null)" ]]; then continue; fi
    if $CHECK; then todo "extraire le sous-module $_path (git submodule update --init)"; continue; fi
    todo "extraction du sous-module $_path"
    # -c …update=checkout : un sous-module marqué « update = none » (projet de
    # dev, voir app-register.sh) n'est extrait que sur demande explicite — ici.
    _name="$(git config -f .gitmodules --get-regexp '^submodule\..*\.path$' | awk -v p="$_path" '$2 == p { sub(/^submodule\./, "", $1); sub(/\.path$/, "", $1); print $1; exit }')"
    if ! git -c "submodule.${_name}.update=checkout" submodule update --init -- "$_path" > /dev/null 2>&1; then
      gap "sous-module $_path inaccessible (dépôt privé ?) — ignoré : l'app correspondante ne sera pas installée"
    fi
  done < <(git config -f .gitmodules --get-regexp '^submodule\..*\.path$' 2>/dev/null | awk '{print $2}')
fi
[[ $N_TODO -eq 0 ]] && ok "tous les sous-modules déclarés sont extraits"

# ══════════════════════════════════════════════════════════════════════════════
step "3/12  Configuration de la machine (.env, bbox.env)"
for pair in ".env.example:.env" "bbox.env.example:bbox.env"; do
  _src="${pair%%:*}"; _dst="${pair##*:}"
  if [[ -f "$_dst" ]]; then ok "$_dst présent"
  elif [[ -f "$_src" ]]; then todo "créer $_dst depuis $_src"; run cp "$_src" "$_dst"; run chmod 600 "$_dst"
  else gap "$_src introuvable"; fi
done
if ! $CHECK || [[ -f .env ]]; then
  # Superutilisateur
  SU="$(envget .env LAB_SUPERUSER)"
  if [[ -n "$SU_ARG" && "$SU_ARG" != "$SU" ]]; then
    registry_valid_uid "$SU_ARG" || fail "--superuser : uid invalide"
    if [[ -n "$SU" && -f .devs ]]; then fail "LAB_SUPERUSER vaut déjà « $SU » sur ce lab installé : on n'en change pas par ici"; fi
    todo "LAB_SUPERUSER=$SU_ARG dans .env"; run envset .env LAB_SUPERUSER "$SU_ARG"; SU="$SU_ARG"
  fi
  if [[ -z "$SU" ]]; then SU="$(id -un)"; todo "LAB_SUPERUSER=$SU dans .env (utilisateur courant)"; run envset .env LAB_SUPERUSER "$SU"; fi
  registry_valid_uid "$SU" || gap "LAB_SUPERUSER « $SU » ne respecte pas ^[a-z][a-z0-9]{1,30}\$ — il doit être l'uid d'un compte de l'annuaire"
  export LAB_SUPERUSER="$SU"
  ok "superutilisateur du lab : $SU"

  # Adresses
  CUR_LAN="$(envget bbox.env SERVER_URL_LAN)"; CUR_WAN="$(envget bbox.env SERVER_URL_WAN)"
  if is_placeholder "$CUR_LAN" || [[ -n "$LAN_IP" ]]; then
    [[ -n "$LAN_IP" ]] || LAN_IP="$(ip route get 8.8.8.8 2>/dev/null | awk '/src/ { for (i = 1; i <= NF; i++) if ($i == "src") { print $(i + 1); exit } }')"
    if [[ -n "$LAN_IP" ]]; then
      [[ "$CUR_LAN" == "http://$LAN_IP" ]] || { todo "SERVER_URL_LAN=http://$LAN_IP dans bbox.env"; run envset bbox.env SERVER_URL_LAN "http://$LAN_IP"; }
    else gap "IP LAN indétectable — relancer avec --lan-ip <ip>"; fi
  else ok "SERVER_URL_LAN = $CUR_LAN"; fi
  if is_placeholder "$CUR_WAN" || [[ -n "$WAN" ]]; then
    [[ -n "$WAN" ]] || WAN="$(curl -sf --max-time 5 https://api.ipify.org 2>/dev/null || true)"
    if [[ -n "$WAN" ]]; then
      [[ "$WAN" == http* ]] || WAN="http://$WAN"
      [[ "$CUR_WAN" == "$WAN" ]] || { todo "SERVER_URL_WAN=$WAN dans bbox.env"; run envset bbox.env SERVER_URL_WAN "$WAN"; }
    else gap "IP WAN indétectable (pas d'accès à api.ipify.org) — relancer avec --wan <ip> ; reset_url.sh refuse de tourner sans elle"; fi
  else ok "SERVER_URL_WAN = $CUR_WAN"; fi

  # Domaine
  DOMAIN_CUR="$(envget .env DOMAIN)"
  if [[ -n "$DOMAIN_ARG" && "$DOMAIN_ARG" != "$DOMAIN_CUR" ]]; then
    todo "DOMAIN=$DOMAIN_ARG dans .env"; run envset .env DOMAIN "$DOMAIN_ARG"; DOMAIN_CUR="$DOMAIN_ARG"
  fi
  if [[ -n "$ACME_ARG" && "$ACME_ARG" != "$(envget .env ACME_EMAIL)" ]]; then
    todo "ACME_EMAIL dans .env"; run envset .env ACME_EMAIL "$ACME_ARG"
  fi
  if is_placeholder "$DOMAIN_CUR"; then
    HAS_DOMAIN=false
    gap "DOMAIN n'est pas renseigné : lab en HTTP local seulement. Le moteur (lab-mcp) et les espaces de travail exigent HTTPS — relancer avec --domain <fqdn> --acme-email <adresse> une fois le nom de domaine pointé sur cette machine"
  else
    HAS_DOMAIN=true; ok "domaine public : $DOMAIN_CUR"
    is_placeholder "$(envget .env ACME_EMAIL)" && [[ -z "$ACME_ARG" ]] && gap "ACME_EMAIL n'est pas renseigné dans .env (contact Let's Encrypt) — --acme-email <adresse>"
  fi
else
  SU="${SU_ARG:-$(id -un)}"; HAS_DOMAIN=false
fi

# ══════════════════════════════════════════════════════════════════════════════
step "4/12  Fichiers .env de chaque unité, annuaire, registre"
# Toute unité qui a un .env.example et pas de .env en reçoit un — aux DEUX
# emplacements (racine et deploiement/). Un .env manquant fait échouer
# `docker compose` (env_file introuvable) ou, pire, laisse create-app-client.sh
# en fabriquer un partiel, sans base ni SECRET_KEY.
#
# Un .env FRAÎCHEMENT créé (et lui seul) est ajusté :
#   • base : les gabarits des sous-modules disent encore devdb/devuser. Une
#     unité de la racine (service du cadriciel) reçoit la base `lab` ; une app
#     de deploiement/ la base de son propriétaire (dev_<uid>, ou gis_<uid> si
#     elle est sur l'instance PostGIS). Le mot de passe sera propagé par
#     reset_url.sh ;
#   • secrets : toute clé *KEY*/*SECRET*/*PASSWORD* encore à CHANGE_ME reçoit
#     une valeur aléatoire — sauf celles que d'autres scripts posent (base,
#     Keycloak, coffre d'oauth-hub) ;
#   • oauth-hub : la liste de confiance de départ inclut le moteur et lab-admin ;
#   • lab-mcp : identités de CET hôte (id -u, id -g, GID du groupe docker).
LAB_SERVICES=" lab-admin storage oauth-hub app-builder "
fresh_env() {  # fresh_env <dossier de l'unité>
  local dir="$1" unit env owner host key val tmp line
  unit="$(basename "$dir")"; env="$dir/.env"
  cp "$dir/.env.example" "$env" && chmod 600 "$env" || return 1
  # Base
  if grep -qE '^DB_NAME=' "$env"; then
    host="$(envget "$env" DB_HOST)"
    if [[ "$dir" == "$ROOT/deploiement/"* ]]; then
      owner="$(registry_app_owner "$unit")"
      if [[ "$host" == "postgis" ]]; then envset "$env" DB_NAME "gis_${owner}"; else envset "$env" DB_NAME "dev_${owner}"; fi
      envset "$env" DB_USER "dev_${owner}"
    elif [[ "$LAB_SERVICES" == *" $unit "* ]]; then
      envset "$env" DB_NAME lab; envset "$env" DB_USER lab
    fi
  fi
  # Secrets à CHANGE_ME (réécriture sans passer la valeur à une commande externe)
  tmp="$(umask 077; mktemp "$env.XXXXXX")"
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ ^([A-Z][A-Z0-9_]*)=CHANGE_ME[[:space:]]*$ ]]; then
      key="${BASH_REMATCH[1]}"
      case "$key" in
        DB_PASSWORD|POSTGIS_PASSWORD|KEYCLOAK_*|OAUTH_HUB_ENCRYPTION_KEY|CODE_SERVER_*|LDAP_*|POSTGRES_PASSWORD|PGADMIN_*|BBOX_*|SMTP_*) ;;
        *KEY*|*SECRET*|*PASSWORD*)
          val="$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 50 || true)"
          line="${key}=${val}" ;;
      esac
    fi
    printf '%s\n' "$line"
  done < "$env" > "$tmp"
  chmod 600 "$tmp"; mv "$tmp" "$env"
  case "$unit" in
    oauth-hub) grep -qE '^KEYCLOAK_TRUSTED_CLIENTS=' "$env" && envset "$env" KEYCLOAK_TRUSTED_CLIENTS "oauth-hub,lab-mcp,lab-admin" ;;
    lab-mcp)   envset "$env" LAB_UID "$(id -u)"; envset "$env" LAB_GID "$(id -g)"
               envset "$env" DOCKER_GID "$(getent group docker | cut -d: -f3)" ;;
    infra)     envset "$env" PGADMIN_DEFAULT_PASSWORD "$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 32 || true)" ;;
  esac
}
_before=$N_TODO
while IFS= read -r _ex; do
  _dir="$(dirname "$_ex")"
  [[ -f "$_dir/.env" ]] && continue
  todo "créer ${_dir#"$ROOT"/}/.env depuis son gabarit (base, secrets et identités ajustés)"
  run fresh_env "$_dir" || fail "création de ${_dir#"$ROOT"/}/.env impossible"
done < <(for d in "$ROOT"/*/ "$ROOT"/deploiement/*/; do d="${d%/}"; [[ -f "$d/.env.example" && "$(basename "$d")" != "_templates" ]] && echo "$d/.env.example"; done)
[[ $N_TODO -eq $_before ]] && ok "chaque unité qui a un gabarit a son .env"

# Unités déployables SANS gabarit et sans .env : rien à copier, à signaler.
while IFS= read -r _dir; do
  [[ -f "$_dir/.env" || -f "$_dir/.env.example" ]] || gap "${_dir#"$ROOT"/} a un docker-compose.yml mais ni .env ni .env.example"
done < <(registry_dirs_with docker-compose.yml)

# lab-mcp/.env existant : ses identités sont-elles celles de cet hôte ?
if [[ -f lab-mcp/.env ]]; then
  _want_gid="$(getent group docker | cut -d: -f3)"
  if [[ "$(envget lab-mcp/.env DOCKER_GID)" != "$_want_gid" || "$(envget lab-mcp/.env LAB_UID)" != "$(id -u)" ]]; then
    gap "lab-mcp/.env : LAB_UID/DOCKER_GID ($(envget lab-mcp/.env LAB_UID)/$(envget lab-mcp/.env DOCKER_GID)) ne sont pas ceux de cet hôte ($(id -u)/${_want_gid}) — à corriger à la main (l'installation ne réécrit pas un .env existant)"
  else ok "lab-mcp/.env : identités de cet hôte"; fi
fi

# Secrets restés au gabarit dans un .env EXISTANT : on les nomme, on ne les change pas.
_left=""
while IFS= read -r _dir; do
  _k="$(grep -E '^[A-Z][A-Z0-9_]*(KEY|SECRET|PASSWORD)[A-Z0-9_]*=CHANGE_ME[[:space:]]*$' "$_dir/.env" 2>/dev/null | cut -d= -f1 | tr '\n' ' ')"
  [[ -n "$_k" ]] && _left+="${_dir#"$ROOT"/} : ${_k}; "
done < <(registry_dirs_with .env)
if [[ -n "$_left" ]]; then
  if has_volume sso-lab_keycloak-data; then gap "secrets encore à CHANGE_ME dans des .env existants — ${_left}"
  else note "secrets encore à CHANGE_ME (seront générés à l'étape 5 ou écrits au déploiement) — ${_left}"; fi
fi

# Annuaire
LDIF="sso-lab/ldap/init.ldif"
if [[ -d "$LDIF" ]]; then gap "$LDIF est un DOSSIER (créé par Docker faute de fichier) : le supprimer (sudo rmdir) puis relancer"
elif [[ -f "$LDIF" ]]; then ok "$LDIF présent"
else todo "créer $LDIF depuis son gabarit (mots de passe générés à l'étape 5)"; run cp "$LDIF.example" "$LDIF"; run chmod 600 "$LDIF"; fi

# Registre des ports : non versionné, et monté par lab-admin — s'il manque,
# Docker crée un DOSSIER .ports à sa place, et plus aucune app n'est visible.
rebuild_ports() {
  local out="$1" dir unit b f k v
  {
    echo "__keycloak__:$(envget sso-lab/.env PORT_KEYCLOAK):"
    echo "__phpldapadmin__:$(envget sso-lab/.env PORT_PHPLDAPADMIN):"
    echo "__pgadmin__:$(envget infra/.env PORT_PGADMIN):"
    while IFS= read -r dir; do
      unit="$(basename "$dir")"
      case "$unit" in sso-lab|infra|runner) continue ;; esac
      b="$(envget "$dir/.env" PORT_BACKEND)"; f="$(envget "$dir/.env" PORT_FRONTEND)"
      echo "${unit}:${b}:${f}"
      # Services annexes publiés (PORT_ENGINE, PORT_RELAY…) : une ligne chacun.
      while IFS='=' read -r k v; do
        case "$k" in PORT_BACKEND|PORT_FRONTEND|PORT_KEYCLOAK|PORT_HTTP|PORT_HTTPS|"") continue ;; esac
        [[ "$v" =~ ^[0-9]+$ ]] && echo "${unit}-$(tr 'A-Z_' 'a-z-' <<< "${k#PORT_}"):${v}:"
      done < <(grep -E '^PORT_[A-Z_]+=[0-9]+' "$dir/.env" 2>/dev/null)
    done < <(registry_dirs_with docker-compose.yml)
  } > "$out"
}
if [[ -d .ports ]]; then gap ".ports est un DOSSIER (créé par Docker faute de fichier) : le supprimer (sudo rmdir .ports) puis relancer"
elif [[ -f .ports ]]; then
  _absent=""
  while IFS= read -r _dir; do
    _u="$(basename "$_dir")"; case "$_u" in sso-lab|infra|runner) continue ;; esac
    grep -q "^${_u}:" .ports || _absent+="$_u "
  done < <(registry_dirs_with docker-compose.yml)
  if [[ -n "$_absent" ]]; then todo "ajouter à .ports les unités absentes : $_absent"
    if ! $CHECK; then rebuild_ports "$ROOT/.ports.reconstruit"; for _u in $_absent; do grep "^${_u}[:-]" .ports.reconstruit >> .ports; done; unlink .ports.reconstruit; fi
  else ok ".ports présent, toutes les unités y figurent"; fi
else
  todo "reconstruire .ports depuis les .env des unités"
  run rebuild_ports "$ROOT/.ports"
fi

STATE_DIR="$(registry_state_dir)"
WORK_DIR="$(envget .env LAB_WORK_DIR)"; [[ -n "$WORK_DIR" ]] || WORK_DIR="$(dirname "$ROOT")/lab-work"
for _d in "$STATE_DIR" "$WORK_DIR"; do
  if [[ -d "$_d" ]]; then
    [[ -w "$_d" ]] && ok "$_d présent" || gap "$_d existe mais n'est pas inscriptible par $(id -un) (créé par Docker en root ? sudo chown $(id -un) $_d)"
  else todo "créer $_d"; run mkdir -p "$_d"; run chmod 700 "$_d"; fi
done

# ══════════════════════════════════════════════════════════════════════════════
step "5/12  Secrets de premier passage"
# init-secrets.sh génère des mots de passe qui ne valent que pour des volumes
# NEUFS (LDAP, Keycloak et PostgreSQL gardent les leurs dans leur volume). On ne
# l'appelle donc que si le realm n'a jamais été initialisé ; il décide ensuite,
# clé par clé et volume par volume, de ce qu'il a le droit d'écrire.
_ldif_placeholder=false
[[ -f "$LDIF" ]] && grep -q '^userPassword: CHANGE_ME' "$LDIF" && _ldif_placeholder=true
if has_volume sso-lab_keycloak-data; then
  ok "sso-lab déjà initialisé (volume sso-lab_keycloak-data) : aucun secret n'est régénéré"
elif [[ -f sso-lab/.env ]] && ! is_placeholder "$(envget sso-lab/.env KEYCLOAK_ADMIN_PASSWORD)" && ! $_ldif_placeholder; then
  # Installation interrompue après cette étape : les secrets sont déjà posés.
  # On ne les régénère pas — relancer ne doit rien changer.
  ok "secrets de premier passage déjà générés (aucun volume encore créé) : conservés"
else
  _args=(--yes); has_volume sso-lab_ldap-data || _args+=(--init-ldif-password)
  todo "générer les secrets de premier passage (init-secrets.sh ${_args[*]}) : LDAP, Keycloak, PostgreSQL, coffre oauth-hub, un mot de passe par compte de l'annuaire"
  if ! $CHECK; then
    bash "$SCRIPT_DIR/init-secrets.sh" "${_args[@]}" > "$STATE_DIR/install-secrets.log" 2>&1 \
      || fail "init-secrets.sh a échoué (voir $STATE_DIR/install-secrets.log)"
    chmod 600 "$STATE_DIR/install-secrets.log" sso-lab/.env infra/.env "$LDIF" 2>/dev/null || true
    [[ -f oauth-hub/.env ]] && chmod 600 oauth-hub/.env
    ok "secrets générés (détail : $STATE_DIR/install-secrets.log — ne contient aucune valeur)"
  fi
fi
for _pair in "infra/.env:POSTGRES_PASSWORD" "infra/.env:POSTGIS_PASSWORD" "sso-lab/.env:KEYCLOAK_ADMIN_PASSWORD" "sso-lab/.env:LDAP_ADMIN_PASSWORD"; do
  _f="${_pair%%:*}"; _k="${_pair##*:}"
  [[ -f "$_f" ]] || continue
  is_placeholder "$(envget "$_f" "$_k")" && { $CHECK && ! has_volume sso-lab_keycloak-data && continue; gap "$_k vaut encore le gabarit dans $_f"; }
done
if [[ -f "$LDIF" ]] && grep -q '^userPassword: CHANGE_ME' "$LDIF"; then
  if has_volume sso-lab_ldap-data; then gap "$LDIF porte encore des mots de passe CHANGE_ME alors que l'annuaire est initialisé (bash scripts/rotate-ldap-user-passwords.sh --yes)"
  elif $CHECK; then :; else gap "$LDIF porte encore des mots de passe CHANGE_ME après init-secrets.sh"; fi
fi

# ══════════════════════════════════════════════════════════════════════════════
step "6/12  Réseau et propagation des adresses"
if docker network inspect edge-net > /dev/null 2>&1; then ok "réseau edge-net présent"
else todo "créer le réseau Docker edge-net (sso-lab le déclare externe : sans lui Compose ne démarre rien)"; run docker network create edge-net > /dev/null; fi
EDGE_ROUTER_TODO=false
if [[ -d "$HOME/edge-router" ]]; then ok "répartiteur ~/edge-router/ présent"
else todo "poser le répartiteur 80/443 dans ~/edge-router/ depuis le gabarit edge-router.example/ (Caddy ne publie plus ces ports lui-même)"; EDGE_ROUTER_TODO=true; fi
if ! $CHECK; then
  bash "$SCRIPT_DIR/reset_url.sh" > "$STATE_DIR/install-reset-url.log" 2>&1 \
    || fail "reset_url.sh a échoué — $(tail -3 "$STATE_DIR/install-reset-url.log" | tr '\n' ' ')"
  ok "adresses propagées dans les .env (reset_url.sh)"
fi
# Après reset_url.sh : le domaine est alors dans sso-lab/.env. Ne touche jamais à un
# ~/edge-router/ existant (il est commun à tous les cadriciels de la machine).
if $EDGE_ROUTER_TODO && ! $CHECK; then
  bash "$SCRIPT_DIR/edge-router-install.sh" > "$STATE_DIR/install-edge-router.log" 2>&1 \
    || fail "edge-router-install.sh a échoué — $(tail -3 "$STATE_DIR/install-edge-router.log" | tr '\n' ' ')"
  ok "répartiteur : $(tail -1 "$STATE_DIR/install-edge-router.log")"
fi

# ══════════════════════════════════════════════════════════════════════════════
step "7/12  Identité : sso-lab (Keycloak, LDAP, Caddy)"
# shellcheck source=lib/kcprobe.sh
source "$SCRIPT_DIR/lib/kcprobe.sh"
KC_PORT="$(envget sso-lab/.env PORT_KEYCLOAK)"; KC_PORT="${KC_PORT:-8080}"
if [[ "$(kc_probe_sso_state "$KC_PORT")" == "up" ]]; then ok "Keycloak répond"
else
  todo "démarrer sso-lab et attendre Keycloak"
  if ! $CHECK; then
    bash "$SCRIPT_DIR/recompose_docker.sh" --app sso-lab || fail "sso-lab n'a pas démarré (voir le message de Compose ci-dessus)"
    for _i in $(seq 1 100); do [[ "$(kc_probe_sso_state "$KC_PORT")" == "up" ]] && break; sleep 3; done
    [[ "$(kc_probe_sso_state "$KC_PORT")" == "up" ]] || fail "Keycloak ne répond pas après 300 s (docker logs keycloak)"
    sleep 20   # laisse Keycloak finir son initialisation
    ok "Keycloak répond"
  fi
fi
# Realm, fédération LDAP, clients de code-server et de pgAdmin.
kc_client_exists() {
  # shellcheck source=lib/kcadmin.sh
  source "$SCRIPT_DIR/lib/kcadmin.sh"
  [[ "$(kc_admin_login 2>/dev/null && kc_admin_get "/clients?clientId=$1" 2>/dev/null | jq 'length' 2>/dev/null)" == "1" ]]
}
if [[ "$(kc_probe_sso_state "$KC_PORT")" == "up" ]]; then
  if kc_client_exists code-server; then ok "client Keycloak code-server présent"
  else todo "créer le realm, la fédération LDAP et le client code-server (sso-lab/setup-code-server-auth.sh)"
       run bash "$ROOT/sso-lab/setup-code-server-auth.sh" || fail "setup-code-server-auth.sh a échoué"; fi
  if kc_client_exists infra; then ok "client Keycloak de pgAdmin (infra) présent"
  else todo "créer le client Keycloak de pgAdmin (create-app-client.sh infra) — son secret est écrit dans infra/.env"
       run bash "$SCRIPT_DIR/create-app-client.sh" infra --port "$(envget infra/.env PORT_PGADMIN)" --redirect-path /oauth2/authorize > /dev/null \
         || fail "création du client pgAdmin impossible"; fi
else
  $CHECK && todo "puis : realm, fédération LDAP, clients code-server et pgAdmin"
fi

# ══════════════════════════════════════════════════════════════════════════════
step "8/12  Bases de données : infra, base du cadriciel, base du superutilisateur"
if running dev-postgres && running dev-postgis; then ok "dev-postgres et dev-postgis en service"
else
  todo "démarrer infra (PostgreSQL, PostGIS, pgAdmin)"
  if ! $CHECK; then
    bash "$SCRIPT_DIR/recompose_docker.sh" --app infra || fail "l'infra n'a pas démarré (infra/.env complet ?)"
    for _i in $(seq 1 60); do docker exec dev-postgres pg_isready -q 2>/dev/null && docker exec dev-postgis pg_isready -q 2>/dev/null && break; sleep 2; done
    docker exec dev-postgres pg_isready -q 2>/dev/null || fail "dev-postgres ne répond pas (docker logs dev-postgres)"
    sleep 3
  fi
fi
if running dev-postgres; then
  if bash "$SCRIPT_DIR/dev-db.sh" status lab > /dev/null 2>&1; then ok "rôle et base lab en place"
  else todo "créer le rôle et la base lab (dev-db.sh ensure-lab)"; run bash "$SCRIPT_DIR/dev-db.sh" ensure-lab || fail "dev-db.sh ensure-lab a échoué"; fi
  if bash "$SCRIPT_DIR/dev-db.sh" status "$SU" --gis > /dev/null 2>&1; then ok "bases dev_${SU} et gis_${SU} en place"
  else todo "créer les bases du superutilisateur (dev-db.sh ensure $SU --gis)"; run bash "$SCRIPT_DIR/dev-db.sh" ensure "$SU" --gis || fail "dev-db.sh ensure $SU a échoué"; fi
  if registry_is_dev "$SU"; then ok "$SU inscrit dans .devs"
  else todo "inscrire $SU dans .devs"; $CHECK || { echo "$SU" >> .devs; }; fi
  if ! $CHECK; then
    bash "$SCRIPT_DIR/reset_url.sh" >> "$STATE_DIR/install-reset-url.log" 2>&1 || fail "reset_url.sh (propagation des mots de passe de base) a échoué"
  fi
  # CONNECT fermé à PUBLIC sur les bases d'administration (devdb, gisdb, postgres, template1…).
  _open="$(bash "$SCRIPT_DIR/dev-db.sh" lockdown-connect 2>/dev/null | grep -c 'REVOKE CONNECT' || true)"
  if [[ "$_open" == "0" ]]; then ok "CONNECT fermé à PUBLIC sur toutes les bases"
  else todo "fermer CONNECT à PUBLIC sur $_open base(s) (dev-db.sh lockdown-connect --apply)"
       run bash "$SCRIPT_DIR/dev-db.sh" lockdown-connect --apply > /dev/null || fail "lockdown-connect a échoué"; fi
  if bash "$SCRIPT_DIR/dev-db.sh" hba-status > /dev/null 2>&1; then ok "pg_hba.conf : aucun trust réseau"
  else gap "pg_hba.conf accorde encore un trust réseau (bash scripts/dev-db.sh hba-status ; lockdown-hba --apply, en connaissance de cause)"; fi
else
  $CHECK && todo "puis : rôle et base lab, bases de $SU, CONNECT fermé à PUBLIC"
fi

# ══════════════════════════════════════════════════════════════════════════════
step "9/12  Runner de tests"
if running lab-runner; then ok "lab-runner en service"
else todo "démarrer le runner E2E"; run bash "$SCRIPT_DIR/recompose_docker.sh" --app runner > /dev/null 2>&1 \
       || { $CHECK || gap "lab-runner n'a pas démarré (best-effort : les tests de cloisonnement ne tourneront pas)"; }; fi

# ══════════════════════════════════════════════════════════════════════════════
step "10/12  Cadriciel, puis applications"
# Dans l'ordre de leurs dépendances. Une unité qui a déjà un conteneur en
# service n'est PAS redéployée : l'installation complète, elle ne met pas à jour
# (pour cela : bash scripts/setup2.sh <app> --yes).
deploy_unit() {
  local unit="$1"
  [[ -f "$(registry_app_dir "$unit")/docker-compose.yml" ]] || return 0
  if unit_running "$unit"; then ok "$unit en service"; return 0; fi
  if [[ "$unit" == "lab-mcp" ]] && ! $HAS_DOMAIN; then gap "lab-mcp non démarré : il exige DOMAIN (HTTPS)"; return 0; fi
  todo "déployer $unit (setup_unit.sh)"
  $CHECK && return 0
  if bash "$SCRIPT_DIR/setup_unit.sh" "$unit" --yes > "$STATE_DIR/install-$unit.log" 2>&1; then
    ok "$unit déployée"
  else
    gap "$unit : déploiement en échec (journal : $STATE_DIR/install-$unit.log) — $(grep -a 'ERROR' "$STATE_DIR/install-$unit.log" | tail -1 | sed 's/\x1b\[[0-9;]*m//g' | cut -c1-160)"
  fi
}
for _u in storage oauth-hub lab-admin lab-mcp; do deploy_unit "$_u"; done
if $NO_APPS; then note "--no-apps : les applications ne sont pas déployées"
else
  # Ordre de scripts/app-priorities.conf, puis alphabétique.
  while IFS= read -r _u; do
    case "$_u" in sso-lab|infra|runner|storage|oauth-hub|lab-admin|lab-mcp) continue ;; esac
    [[ -e "$(registry_app_dir "$_u" 2>/dev/null || echo "$_u")/.no-autodeploy" || -e "$_u/.no-autodeploy" ]] && { note "$_u ignorée (.no-autodeploy)"; continue; }
    deploy_unit "$_u"
  done < <(while IFS= read -r _dir; do
             _n="$(basename "$_dir")"
             _p="$(awk -F: -v a="$_n" '$1 == a { print $2; exit }' "$SCRIPT_DIR/app-priorities.conf" 2>/dev/null)"
             printf '%s|%s\n' "${_p:-50}" "$_n"
           done < <(registry_dirs_with docker-compose.yml) | sort -t'|' -k1,1n -k2,2 | cut -d'|' -f2)
fi

# ══════════════════════════════════════════════════════════════════════════════
step "11/12  Image des espaces de travail, partages de fichiers, pages générées"
if $NO_WS; then note "--no-workspace-image : lab-workspace n'est pas construite"
elif bash "$SCRIPT_DIR/workspace-image.sh" check > /dev/null 2>&1; then ok "image lab-workspace:latest présente"
elif [[ ! -f workspace/Dockerfile ]]; then gap "workspace/Dockerfile absent : image lab-workspace non construisible"
else todo "construire lab-workspace:latest (≈ 8 min)"; run bash "$SCRIPT_DIR/workspace-image.sh" build > "$STATE_DIR/install-workspace.log" 2>&1 \
       || { $CHECK || gap "construction de lab-workspace en échec (journal : $STATE_DIR/install-workspace.log)"; }; fi
if running storage-backend; then
  if bash "$SCRIPT_DIR/storage-shares.sh" --check > /dev/null 2>&1; then ok "partages de groupe de storage en place"
  else todo "créer les partages de groupe de storage (storage-shares.sh)"; run bash "$SCRIPT_DIR/storage-shares.sh" > /dev/null || { $CHECK || gap "partages de storage : création en échec (bash scripts/storage-shares.sh)"; }; fi
else
  $CHECK && todo "puis : partages de groupe de storage"
fi
if ! $CHECK; then
  bash "$SCRIPT_DIR/get-ports-list.sh" > /dev/null 2>&1 || true
  bash "$SCRIPT_DIR/complete_404.sh" > /dev/null 2>&1 || true
  ok "ports.env et page 404 régénérés"
fi

# ══════════════════════════════════════════════════════════════════════════════
step "12/12  Bilan"
if docker info > /dev/null 2>&1; then
  while IFS= read -r _dir; do
    _u="$(basename "$_dir")"
    _c="$(docker ps -a --filter "label=com.docker.compose.project=$_u" --format '{{.State}}' 2>/dev/null | sort | uniq -c | awk '{printf "%s %s  ", $1, $2}')"
    printf '  %-34s %s\n' "$_u" "${_c:-aucun conteneur}"
  done < <(registry_dirs_with docker-compose.yml)
fi
# Confiance d'oauth-hub : sans le moteur et lab-admin dans sa liste, ni création
# de projet, ni ticket, ni éditeur. La liste vit en base (page « Apps
# autorisées ») ; la graine n'est lue qu'à la première migration.
if running dev-postgres && running oauth-hub-backend; then
  _tc="$(docker exec dev-postgres psql -X -U "$(envget infra/.env POSTGRES_USER)" -d lab -tAc "SELECT string_agg(client_id, ',' ORDER BY client_id) FROM oauth_hub.trusted_clients WHERE enabled" 2>/dev/null || true)"
  for _c in lab-mcp lab-admin; do
    [[ ",$_tc," == *",$_c,"* ]] || gap "oauth-hub n'autorise pas le client « $_c » (page « Apps autorisées » d'oauth-hub)"
  done
  _pv="$(docker exec dev-postgres psql -X -U "$(envget infra/.env POSTGRES_USER)" -d lab -tAc "SELECT count(*) FROM oauth_hub.providers WHERE slug = 'github'" 2>/dev/null || true)"
  [[ "$_pv" == "1" ]] || gap "oauth-hub n'a pas de fiche « github » : enregistrer une application OAuth chez GitHub (URI de rappel : https://<DOMAIN>/oauth-hub-api/api/callback/github/ — pas à pas dans oauth-hub/README.md ; portée read:user repo) et saisir son client_id/client_secret dans oauth-hub"
fi
[[ -n "$(envget sso-lab/.env SMTP_FROM)" ]] || gap "SMTP de Keycloak non configuré (sso-lab/.env : SMTP_FROM, SMTP_USER, SMTP_PASSWORD) : pas de « mot de passe oublié », pas d'email de mot de passe aux comptes"

echo ""
if $CHECK; then
  if [[ $N_TODO -eq 0 && $N_GAP -eq 0 ]]; then
    echo -e "${G}${B}Rien à faire : l'installation est complète.${N}"
  else
    [[ $N_TODO -gt 0 ]] && { echo -e "${Y}${B}$N_TODO action(s) que « bash scripts/install.sh » ferait :${N}"; printf '  • %s\n' "${TODOS[@]}"; }
    [[ $N_GAP -gt 0 ]]  && { echo -e "${R}${B}$N_GAP point(s) qui restent à la main :${N}"; printf '  • %s\n' "${GAPS[@]}"; }
  fi
  [[ $N_TODO -eq 0 && $N_GAP -eq 0 ]]; exit $?
fi
if [[ $N_GAP -eq 0 ]]; then echo -e "${G}${B}Installation terminée.${N}"
else echo -e "${Y}${B}Installation terminée, $N_GAP point(s) restent à la main :${N}"; printf '  • %s\n' "${GAPS[@]}"; fi
cat <<EOF

Gestes qui restent humains, dans tous les cas :
  • oauth-hub : fiche GitHub (application OAuth à enregistrer chez GitHub, portée read:user repo),
    et, au besoin, GitLab / Google.
  • SMTP de Keycloak : mot de passe d'application dans sso-lab/.env, puis
    bash scripts/create-app-client.sh <une app>  (réapplique les réglages du realm).
  • Nom de domaine + DDNS chez le fournisseur ; ports 80 et 443 du routeur vers cette machine.
  • Mots de passe des comptes : sso-lab/.env (clés <UID>_PASSWORD), à transmettre à chacun.
  • Sauvegardes : rien n'est planifié par ce dépôt.
Vérifier à tout moment : bash scripts/install.sh --check
EOF
[[ $N_GAP -eq 0 ]]
