#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# reset_url.sh — Propage les adresses réseau depuis bbox.env vers tous les
#                fichiers .env des projets du workspace.
#
# Sources de vérité :
#   bbox.env  → SERVER_URL_LAN, SERVER_URL_WAN
#   .env      → DOMAIN, ACME_EMAIL  (racine du workspace)
#
# En mode HTTP  (DOMAIN=CHANGE_ME) : URLs basées sur l'IP WAN + ports directs.
# En mode HTTPS (DOMAIN configuré) : URLs basées sur les sous-domaines Caddy.
#
# Usage :
#   1. Éditer bbox.env → renseigner SERVER_URL_WAN (IP publique WAN)
#   2. Optionnel : éditer .env → renseigner DOMAIN et ACME_EMAIL
#   3. ./reset_url.sh
#   4. Redémarrer les stacks concernées (voir instructions en fin de script)
#
# Idempotent : peut être relancé sans risque.
# Ne crée pas de nouvelles clés — met uniquement à jour les clés existantes.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# ── Lecture d'une valeur dans un fichier .env ──────────────────────────────
_env_val() {
  local file="$1" key="$2" default="${3:-}"
  local val
  val=$(grep -E "^${key}[[:space:]]*=" "$file" 2>/dev/null \
        | tail -1 | cut -d'=' -f2- | sed 's/[[:space:]]*#.*//' \
        | tr -d "\"'" | xargs 2>/dev/null || true)
  echo "${val:-$default}"
}

# ── Mise à jour d'une clé existante dans un .env (no-op si absente) ───────
upsert_env() {
  local file="$1" key="$2" val="$3"
  [[ -f "$file" ]] || return 0
  if grep -qE "^${key}[[:space:]]*=" "$file"; then
    case "$key" in
      *PASSWORD*|*SECRET*)
        # Un secret ne passe pas par la ligne de commande de sed (lisible par
        # `ps`) : il entre dans awk par l'environnement. Même résultat que le
        # sed ci-dessous, octet pour octet — y compris l'absence éventuelle de
        # saut de ligne final, et l'inode du fichier (cat >, pas mv).
        local _tmp _nl=true
        [[ -s "$file" && -n "$(tail -c1 "$file")" ]] && _nl=false
        _tmp="$(umask 077; mktemp)"
        _UPSERT_VAL="$val" awk -v key="$key" '
          BEGIN { val = ENVIRON["_UPSERT_VAL"] }
          $0 ~ ("^" key "[[:space:]]*=") { print key "=" val; next }
          { print }' "$file" > "$_tmp"
        if $_nl; then cat "$_tmp" > "$file"; else printf '%s' "$(cat "$_tmp")" > "$file"; fi
        rm -f "$_tmp"
        ;;
      *)
        sed -i "s|^${key}[[:space:]]*=.*|${key}=${val}|" "$file"
        ;;
    esac
    # Un mot de passe ne s'affiche jamais : le journal de setup2.sh est relayé
    # tel quel à qui a lancé le déploiement (serveur MCP), et ce script parcourt
    # les .env de TOUTES les apps, pas seulement de la sienne.
    case "$key" in
      *PASSWORD*|*SECRET*) printf "    ✓ %-30s → %s\n" "${key}" "(masqué)" ;;
      *)                   printf "    ✓ %-30s → %s\n" "${key}" "${val}" ;;
    esac
  fi
}

# ── Lecture des sources ────────────────────────────────────────────────────
BBOX_ENV="$SCRIPT_DIR/bbox.env"
ROOT_ENV="$SCRIPT_DIR/.env"

[[ -f "$BBOX_ENV" ]] || { echo "❌  bbox.env introuvable dans $SCRIPT_DIR" >&2; exit 1; }

SERVER_URL_LAN="$(_env_val "$BBOX_ENV" SERVER_URL_LAN)"
SERVER_URL_WAN="$(_env_val "$BBOX_ENV" SERVER_URL_WAN)"

# PORT_KEYCLOAK  : sso-lab/.env  (source de vérité — c'est là que Keycloak est défini)
# HPORT_POSTGRES : infra/.env    (port interne Postgres)
# DB_PASSWORD    : infra/.env    (POSTGRES_PASSWORD — mot de passe partagé du rôle
#                                 devuser ; source de vérité unique pour tout le lab)
# POSTGIS_PASSWORD : infra/.env  (POSTGIS_PASSWORD — mot de passe de la seconde
#                                 instance PostgreSQL/PostGIS, dédiée aux apps SIG.
#                                 Clé DISTINCTE de DB_PASSWORD : upsert_env ne
#                                 touche que les .env qui déclarent déjà
#                                 POSTGIS_PASSWORD, donc aucune collision avec
#                                 les apps sur l'instance 'postgres' partagée.
PORT_KEYCLOAK="$(_env_val    "$SCRIPT_DIR/sso-lab/.env" PORT_KEYCLOAK  "8080")"
HPORT_POSTGRES="$(_env_val   "$SCRIPT_DIR/infra/.env"   HPORT_POSTGRES "5432")"
DB_PASSWORD="$(_env_val      "$SCRIPT_DIR/infra/.env"   POSTGRES_PASSWORD)"
POSTGIS_PASSWORD="$(_env_val "$SCRIPT_DIR/infra/.env"   POSTGIS_PASSWORD)"

REALM="ssolab"

# ── Registre des apps et des développeurs (contrat multi-dev, I1/I2) ──────────
# Sert à une seule chose ici : savoir à QUI appartient une app, pour ne lui
# propager que le mot de passe du rôle PostgreSQL de son propriétaire.
# shellcheck source=lib/registry.sh
source "$SCRIPT_DIR/scripts/lib/registry.sh"

# ── Lecture du domaine HTTPS ──────────────────────────────────────────────
DOMAIN="CHANGE_ME"
ACME_EMAIL="CHANGE_ME"
if [[ -f "$ROOT_ENV" ]]; then
  DOMAIN="$(_env_val "$ROOT_ENV" DOMAIN "CHANGE_ME")"
  ACME_EMAIL="$(_env_val "$ROOT_ENV" ACME_EMAIL "CHANGE_ME")"
fi

# ── Chemin hôte du dépôt vu par le démon Docker ────────────────────────────
# Par défaut : $SCRIPT_DIR (correct si ce script tourne sur la même machine que
# le démon Docker). À renseigner dans .env UNIQUEMENT si ce dépôt est édité
# depuis un conteneur (ex. code-server) séparé du démon Docker — voir le
# commentaire de HOST_DEV_ROOT dans .env.example. Consommé par les services qui
# montent tout le dépôt en lecture seule (lab-admin, runner/) : ils déclarent
# déjà HOST_DEV_ROOT dans leur .env, donc upsert_env (no-op si absente) ne
# touche que ceux-là.
HOST_DEV_ROOT="$(_env_val "$ROOT_ENV" HOST_DEV_ROOT "")"
[[ -z "$HOST_DEV_ROOT" ]] && HOST_DEV_ROOT="$SCRIPT_DIR"

# ── Superutilisateur et dossier d'état (contrat multi-dev, I1/I3) ─────────────
# LAB_SUPERUSER : défaut « sacha ». LAB_STATE_DIR : défaut <dépôt>/.lab-state,
# exprimé dans le chemin que VOIT LE DÉMON DOCKER (HOST_DEV_ROOT) — c'est un
# chemin que des services montent en volume, même piège que /mnt/dev.
LAB_SUPERUSER_VAL="$(registry_superuser)"
LAB_STATE_DIR_VAL="$(_env_val "$ROOT_ENV" LAB_STATE_DIR "")"
[[ -z "$LAB_STATE_DIR_VAL" ]] && LAB_STATE_DIR_VAL="${HOST_DEV_ROOT}/.lab-state"
# LAB_WORK_DIR (I3, v5) : clones de travail des développeurs, HORS du dépôt.
# Défaut : « lab-work » à côté du dépôt (/home/sacha/lab-work).
LAB_WORK_DIR_VAL="$(_env_val "$ROOT_ENV" LAB_WORK_DIR "")"
[[ -z "$LAB_WORK_DIR_VAL" ]] && LAB_WORK_DIR_VAL="$(dirname "$HOST_DEV_ROOT")/lab-work"

# ── Validation de SERVER_URL_WAN ─────────────────────────────────────────
if [[ -z "$SERVER_URL_WAN" ]]; then
  echo "❌  SERVER_URL_WAN manquant dans bbox.env" >&2; exit 1
fi
if [[ "$SERVER_URL_WAN" == *"CHANGE_ME"* ]]; then
  echo "❌  SERVER_URL_WAN non configuré dans bbox.env (contient encore CHANGE_ME)" >&2
  echo "    Exemple : SERVER_URL_WAN=http://203.0.113.42" >&2
  echo "" >&2
  echo "    Astuce : connaître son IP WAN courante :" >&2
  echo "      curl -s https://api.ipify.org" >&2
  exit 1
fi

# Format : doit commencer par http:// ou https://
if [[ ! "$SERVER_URL_WAN" =~ ^https?://[^/]+ ]]; then
  echo "❌  SERVER_URL_WAN format invalide : '$SERVER_URL_WAN'" >&2
  echo "    Attendu : http://203.0.113.42  ou  https://mon-domaine.example.com" >&2
  exit 1
fi

# Extraction de l'host (sans schéma ni slash final)
_wan_host="${SERVER_URL_WAN#http://}"
_wan_host="${_wan_host#https://}"
_wan_host="${_wan_host%%/*}"
_wan_host="${_wan_host%%:*}"   # retire le port éventuel

# ── Vérification des IPs (LAN + WAN) ────────────────────────────────────
echo "=== Validation des adresses réseau ==="
WARNINGS=0

# ── LAN : détection via la table de routage ───────────────────────────────
_lan_host="${SERVER_URL_LAN#http://}"
_lan_host="${_lan_host#https://}"
_lan_host="${_lan_host%%/*}"
_lan_host="${_lan_host%%:*}"

DETECTED_LAN_IP=""
DETECTED_LAN_IP=$(ip route get 8.8.8.8 2>/dev/null \
  | awk '/src/ { for(i=1;i<=NF;i++) if($i=="src") { print $(i+1); exit } }' \
  || true)
if [[ -n "$DETECTED_LAN_IP" ]]; then
  printf "  IP LAN détectée  : %s\n" "$DETECTED_LAN_IP"
  printf "  IP LAN configurée: %s\n" "$_lan_host"
  if [[ "$DETECTED_LAN_IP" == "$_lan_host" ]]; then
    echo "  ✅  IP LAN correcte."
  else
    echo "  ⚠️  AVERTISSEMENT : l'IP LAN configurée ($_lan_host) ne correspond pas"
    echo "      à l'IP LAN actuelle ($DETECTED_LAN_IP)."
    echo "      Mettez à jour SERVER_URL_LAN dans bbox.env puis relancez reset_url.sh."
    WARNINGS=$(( WARNINGS + 1 ))
  fi
else
  echo "  ⚠️  Impossible de détecter l'IP LAN (ip route indisponible ?)"
  WARNINGS=$(( WARNINGS + 1 ))
fi
echo ""

# ── WAN : détection via api.ipify.org ────────────────────────────────────
DETECTED_WAN_IP=""
if DETECTED_WAN_IP=$(curl -sf --max-time 5 https://api.ipify.org 2>/dev/null); then
  printf "  IP WAN détectée  : %s\n" "$DETECTED_WAN_IP"
  printf "  IP WAN configurée: %s\n" "$_wan_host"
  if [[ "$DETECTED_WAN_IP" == "$_wan_host" ]]; then
    echo "  ✅  IP WAN correcte."
  else
    echo "  ⚠️  AVERTISSEMENT : l'IP configurée ($_wan_host) ne correspond pas"
    echo "      à l'IP WAN actuelle ($DETECTED_WAN_IP)."
    echo "      Causes possibles : DDNS non mis à jour, VPN actif, double NAT."
    WARNINGS=$(( WARNINGS + 1 ))
  fi
else
  echo "  ⚠️  Impossible de joindre api.ipify.org (pas d'accès internet ?)"
  WARNINGS=$(( WARNINGS + 1 ))
fi

# ── Vérification que le port Keycloak est joignable depuis le WAN ─────────
KC_WAN_CHECK="${SERVER_URL_WAN}:${PORT_KEYCLOAK}/realms/${REALM:-ssolab}"
printf "\n  Test accès Keycloak WAN : %s\n" "$KC_WAN_CHECK"
HTTP_CODE=$(curl -sf --max-time 8 -o /dev/null -w "%{http_code}" "$KC_WAN_CHECK" 2>/dev/null || echo "000")
if [[ "$HTTP_CODE" =~ ^[23] ]]; then
  echo "  ✅  Keycloak répond (HTTP $HTTP_CODE) — port-forwarding OK."
elif [[ "$HTTP_CODE" == "000" ]]; then
  echo "  ⚠️  AVERTISSEMENT : Keycloak injoignable sur ${_wan_host}:${PORT_KEYCLOAK}"
  echo "      Vérifier : port-forwarding Bbox (${PORT_KEYCLOAK} → 192.168.1.50:${PORT_KEYCLOAK})"
  echo "               + Keycloak en cours d'exécution"
  echo "               + hairpin NAT supporté par la box"
  WARNINGS=$(( WARNINGS + 1 ))
else
  echo "  ⚠️  Keycloak répond HTTP $HTTP_CODE (inattendu) sur $KC_WAN_CHECK"
  WARNINGS=$(( WARNINGS + 1 ))
fi

if [[ $WARNINGS -gt 0 ]]; then
  echo ""
  echo "  ⚠️  $WARNINGS avertissement(s) — la propagation va quand même continuer."
  echo "      Corriger les problèmes réseau avant de redémarrer les stacks."
fi
echo ""

# ── Variables dérivées ────────────────────────────────────────────────────
KC_URL="${SERVER_URL_WAN}:${PORT_KEYCLOAK}"          # IP WAN directe (toujours)

# En mode HTTPS, les URLs publiques Keycloak passent par Caddy (sous-domaine auth.)
if [[ "$DOMAIN" != "CHANGE_ME" && -n "$DOMAIN" ]]; then
  KC_PUBLIC_URL="https://${DOMAIN}/auth"
  KC_ISSUER_URI="https://${DOMAIN}/auth/realms/${REALM}"
  KC_HOSTNAME_URL="https://${DOMAIN}/auth"
  URL_MODE="HTTPS — domaine : ${DOMAIN} (Caddy path /auth)"
else
  KC_PUBLIC_URL="${KC_URL}"
  KC_ISSUER_URI="${KC_URL}/realms/${REALM}"
  KC_HOSTNAME_URL="${KC_URL}"
  URL_MODE="HTTP — IP directe (DOMAIN non configuré)"
fi

echo "=== reset_url ==="
echo "  MODE              : ${URL_MODE}"
echo "  LAN               : ${SERVER_URL_LAN}"
echo "  WAN               : ${SERVER_URL_WAN}"
echo "  Keycloak direct   : ${KC_URL}"
echo "  Keycloak public   : ${KC_PUBLIC_URL}"
echo "  Keycloak issuer   : ${KC_ISSUER_URI}"
echo "  PORT_KEYCLOAK     : ${PORT_KEYCLOAK}"
echo "  HPORT_POSTGRES    : ${HPORT_POSTGRES}"
echo "  HOST_DEV_ROOT     : ${HOST_DEV_ROOT}"
echo ""

# ── Parcours de tous les .env des sous-projets ────────────────────────────
STACKS_TO_RESTART=()

while IFS= read -r envfile; do
  # Exclure bbox.env, les .env.example et les fichiers hors sous-dossiers
  [[ "$(basename "$envfile")" == "bbox.env"    ]] && continue
  [[ "$(basename "$envfile")" == *.example     ]] && continue
  [[ "$(basename "$envfile")" == "ports.env"   ]] && continue

  rel="${envfile#"$SCRIPT_DIR"/}"
  dir="$(dirname "$rel")"

  # Snapshot avant modif pour détecter si quelque chose a changé
  before=$(md5sum "$envfile" 2>/dev/null | cut -d' ' -f1)

  upsert_env "$envfile" SERVER_URL_LAN       "$SERVER_URL_LAN"
  upsert_env "$envfile" SERVER_URL_WAN       "$SERVER_URL_WAN"
  upsert_env "$envfile" KEYCLOAK_PUBLIC_URL  "$KC_PUBLIC_URL"
  upsert_env "$envfile" KEYCLOAK_URL         "$KC_URL"
  upsert_env "$envfile" KEYCLOAK_ISSUER_URI  "$KC_ISSUER_URI"
  upsert_env "$envfile" KEYCLOAK_HOSTNAME_URL "$KC_HOSTNAME_URL"
  upsert_env "$envfile" PORT_KEYCLOAK        "$PORT_KEYCLOAK"
  upsert_env "$envfile" HPORT_POSTGRES       "$HPORT_POSTGRES"
  upsert_env "$envfile" HPORT_DB             "$HPORT_POSTGRES"   # alias spring-app
  # ── Mot de passe PostgreSQL ────────────────────────────────────────────────
  # Deux régimes, départagés par le DB_USER que déclare le .env :
  #
  #  • DB_USER=dev_<uid> (base par développeur, contrat multi-dev I2) : on ne
  #    propage QUE le mot de passe du rôle de ce développeur
  #    (DEV_PG_PASSWORD__<uid> → DB_PASSWORD, DEV_GIS_PASSWORD__<uid> →
  #    POSTGIS_PASSWORD), et seulement si l'app lui appartient bien. Le mot de
  #    passe des rôles d'administration devuser/gisuser n'entre plus jamais
  #    dans ce .env. Une app qui déclarerait le rôle d'un AUTRE développeur ne
  #    reçoit rien : écrire DB_USER=dev_x dans son .env ne doit pas suffire à
  #    obtenir le mot de passe de x.
  #
  #  • tout autre DB_USER (devuser, gisuser — apps pas encore basculées — ou
  #    pas de DB_USER du tout) : comportement historique inchangé. upsert_env
  #    est un no-op si la clé est absente, donc infra/.env et sso-lab/.env
  #    (sans DB_PASSWORD) ne sont pas touchés. Vide ⇒ on ne propage pas (évite
  #    d'effacer une valeur).
  _db_user="$(_env_val "$envfile" DB_USER)"
  if [[ "$_db_user" =~ ^dev_([a-z][a-z0-9]{1,30})$ ]]; then
    _db_uid="${BASH_REMATCH[1]}"
    if [[ "$(registry_app_owner "$(basename "$dir")" 2>/dev/null || true)" == "$_db_uid" ]]; then
      # Source : infra/dev-roles.env (contrat v3) — jamais infra/.env, qui est
      # l'env_file de dev-postgres et dev-pgadmin.
      _dev_pg_pw="$(_env_val  "$SCRIPT_DIR/infra/dev-roles.env" "DEV_PG_PASSWORD__${_db_uid}")"
      _dev_gis_pw="$(_env_val "$SCRIPT_DIR/infra/dev-roles.env" "DEV_GIS_PASSWORD__${_db_uid}")"
      [[ -n "$_dev_pg_pw"  ]] && upsert_env "$envfile" DB_PASSWORD      "$_dev_pg_pw"
      [[ -n "$_dev_gis_pw" ]] && upsert_env "$envfile" POSTGIS_PASSWORD "$_dev_gis_pw"
    else
      echo "    ⚠ $rel déclare DB_USER=${_db_user} mais l'app n'appartient pas à « ${_db_uid} » — aucun mot de passe propagé." >&2
    fi
  elif [[ "$_db_user" == "lab" ]]; then
    #  • DB_USER=lab (base du CADRICIEL, contrat multi-dev v8) : rôle non
    #    superutilisateur des services du cadriciel, base `lab`. Son mot de passe
    #    (LAB_PG_PASSWORD, infra/dev-roles.env) n'est propagé qu'aux services
    #    nommés ici — une app qui écrirait DB_USER=lab dans son .env ne l'obtient pas.
    case "$(basename "$dir")" in
      lab-admin|storage|oauth-hub|app-builder)
        _lab_pg_pw="$(_env_val "$SCRIPT_DIR/infra/dev-roles.env" "LAB_PG_PASSWORD")"
        [[ -n "$_lab_pg_pw" ]] && upsert_env "$envfile" DB_PASSWORD "$_lab_pg_pw" ;;
      *) echo "    ⚠ $rel déclare DB_USER=lab mais n'est pas un service du cadriciel — aucun mot de passe propagé." >&2 ;;
    esac
  else
    [[ -n "$DB_PASSWORD" ]] && upsert_env "$envfile" DB_PASSWORD "$DB_PASSWORD"
    # Mot de passe de l'instance PostGIS (apps SIG uniquement) : clé distincte de
    # DB_PASSWORD, donc no-op sur tous les .env qui ne la déclarent pas déjà.
    [[ -n "$POSTGIS_PASSWORD" ]] && upsert_env "$envfile" POSTGIS_PASSWORD "$POSTGIS_PASSWORD"
  fi
  upsert_env "$envfile" DOMAIN               "$DOMAIN"
  upsert_env "$envfile" ACME_EMAIL           "$ACME_EMAIL"
  upsert_env "$envfile" HOST_DEV_ROOT        "$HOST_DEV_ROOT"
  # Contrat multi-dev (I1/I3) : superutilisateur et dossier d'état (clés SSH,
  # verrou de déploiement), pour les services qui les déclarent dans leur .env
  # (lab-admin, lab-mcp). No-op partout ailleurs.
  upsert_env "$envfile" LAB_SUPERUSER        "$LAB_SUPERUSER_VAL"
  upsert_env "$envfile" LAB_STATE_DIR        "$LAB_STATE_DIR_VAL"
  upsert_env "$envfile" LAB_WORK_DIR         "$LAB_WORK_DIR_VAL"

  after=$(md5sum "$envfile" 2>/dev/null | cut -d' ' -f1)

  if [[ "$before" != "$after" ]]; then
    echo "▶ $rel  (modifié)"
    STACKS_TO_RESTART+=("$dir")
  fi

done < <( { find "$SCRIPT_DIR" -maxdepth 2 \( -name ".env" -o -name "sso-lab.env" \)
             # apps de deploiement/ (contrat v5) : un niveau plus bas
             find "$SCRIPT_DIR/deploiement" -mindepth 2 -maxdepth 2 -name ".env" 2>/dev/null; } | sort)

echo ""
echo "✅  Terminé."

if [[ ${#STACKS_TO_RESTART[@]} -gt 0 ]]; then
  echo ""
  echo "Des fichiers .env ont été modifiés. Pour appliquer les changements :"
  echo ""
  echo "  bash recompose_docker.sh --force"
fi
