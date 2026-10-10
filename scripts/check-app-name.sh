#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# check-app-name.sh — règles de nommage d'une NOUVELLE application.
# Contrat « multi-dev » v2, interface I1.
#
# Usage :
#   bash scripts/check-app-name.sh <nom>
#
# Sortie : code 0 = accepté (rien sur stdout) ;
#          code 1 = refusé, UNE RAISON PAR LIGNE sur stdout ;
#          code 2 = erreur d'usage.
#
# POURQUOI CES RÈGLES : le nom d'une app porte à la fois son chemin Caddy
# (/<nom>, /<nom>-api), son client Keycloak (<nom>, <nom>-admin), son schéma
# SQL, le préfixe de ses conteneurs et son dossier. Il est donc GLOBALEMENT
# unique, et deux noms « presque pareils » se marchent dessus :
#   • « foo-api »   capterait le chemin backend de « foo » ;
#   • « foo-admin » capterait son compte de service ;
#   • « foo-x »     partagerait le préfixe de ses conteneurs.
#
# Appelé par new-app.sh pour TOUT créateur, superutilisateur compris. Lecture
# seule : ne prend pas le verrou lui-même — c'est l'appelant (new-app.sh) qui
# fait le contrôle ET l'écriture de .ports/.owners sous le verrou.
#
# Les 7 règles sont TOUTES évaluées (pas d'arrêt à la première) : l'appelant
# affiche d'un coup tout ce qui cloche. La 8ᵉ vérification du contrat (« le
# dépôt GitHub <login>/<nom> existe déjà ») dépend du compte GitHub de
# l'appelant : elle appartient au serveur MCP, pas à ce script.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/registry.sh
source "$SCRIPT_DIR/lib/registry.sh"
ROOT="$(registry_root)"

[[ $# -eq 1 ]] || { echo "Usage : bash scripts/check-app-name.sh <nom>" >&2; exit 2; }
NAME="$1"

REASONS=()
refuse() { REASONS+=("$*"); }

# ── Règle 1 — forme ───────────────────────────────────────────────────────────
# Si la forme est fausse, on s'arrête là : les règles suivantes injectent le nom
# dans des motifs et des URL, il doit être sain avant d'aller plus loin.
if [[ ! "$NAME" =~ ^[a-z][a-z0-9-]{1,38}[a-z0-9]$ ]]; then
  echo "règle 1 : « ${NAME} » ne respecte pas ^[a-z][a-z0-9-]{1,38}[a-z0-9]\$ (3 à 40 caractères, minuscules, chiffres et tirets, commence par une lettre, ne finit pas par un tiret)"
  exit 1
fi
if [[ "$NAME" == *--* ]]; then
  echo "règle 1 : « ${NAME} » contient « -- »"
  exit 1
fi

# ── Noms existants (règles 2 et 3) ────────────────────────────────────────────
# Quatre sources, parce qu'aucune n'est complète seule : .ports contient des
# services annexes sans dossier (robot-lab-engine), un dossier peut exister sans
# ligne .ports (app jamais déployée, infra/, scripts/…), .gitmodules nomme des
# sous-modules pas forcément clonés.
declare -A EXISTING=()   # nom → source
_add_existing() { [[ -n "$1" && -z "${EXISTING[$1]:-}" ]] && EXISTING["$1"]="$2"; return 0; }

if [[ -f "$ROOT/.ports" ]]; then
  while IFS=: read -r _n _; do
    [[ -z "$_n" || "$_n" == \#* ]] && continue
    _add_existing "$_n" ".ports"
  done < "$ROOT/.ports"
fi
if [[ -f "$ROOT/.owners" ]]; then
  while IFS=: read -r _n _; do
    [[ -z "$_n" || "$_n" == \#* ]] && continue
    _add_existing "$_n" ".owners"
  done < "$ROOT/.owners"
fi
if [[ -f "$ROOT/.gitmodules" ]]; then
  while IFS= read -r _n; do
    _n="${_n#deploiement/}"   # sous-module de deploiement/ : le nom est le dernier composant
    _add_existing "$_n" ".gitmodules"
  done < <(sed -n -e 's/^[[:space:]]*path[[:space:]]*=[[:space:]]*//p' \
                  -e 's/^\[submodule "\(.*\)"\][[:space:]]*$/\1/p' "$ROOT/.gitmodules" | sed 's/[[:space:]]*$//')
fi
# Dossiers de $ROOT, cachés compris (.claude, .lab-state… ne peuvent de toute
# façon pas entrer en collision avec un nom qui commence par une lettre).
while IFS= read -r _d; do
  _add_existing "$(basename "$_d")" "dossier de la racine"
done < <(find "$ROOT" -mindepth 1 -maxdepth 1 -type d 2>/dev/null; find "$ROOT/deploiement" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)

# ── Règle 2 — déjà pris ───────────────────────────────────────────────────────
if [[ -n "${EXISTING[$NAME]:-}" ]]; then
  refuse "règle 2 : « ${NAME} » existe déjà (${EXISTING[$NAME]})"
fi
# Un fichier (pas un dossier) de ce nom à la racine bloquerait aussi le mkdir.
if [[ -e "$ROOT/$NAME" && ! -d "$ROOT/$NAME" ]]; then
  refuse "règle 2 : un fichier « ${NAME} » existe déjà à la racine du dépôt"
fi

# ── Règle 3 — préfixe ou extension d'un nom existant ──────────────────────────
for _e in "${!EXISTING[@]}"; do
  [[ "$_e" == "$NAME" ]] && continue
  if [[ "$NAME" == "$_e"-* ]]; then
    refuse "règle 3 : « ${NAME} » prolonge le nom existant « ${_e} » (${EXISTING[$_e]}) — il partagerait le préfixe de ses conteneurs et de ses chemins"
  elif [[ "$_e" == "$NAME"-* ]]; then
    refuse "règle 3 : « ${NAME} » est le préfixe du nom existant « ${_e} » (${EXISTING[$_e]})"
  fi
done

# ── Règle 4 — suffixes réservés ───────────────────────────────────────────────
if [[ "$NAME" == *-api ]]; then
  refuse "règle 4 : le suffixe « -api » est réservé au chemin backend (/<app>-api)"
fi
if [[ "$NAME" == *-admin ]]; then
  refuse "règle 4 : le suffixe « -admin » est réservé au client Keycloak compagnon (<app>-admin)"
fi

# ── Règle 5 — liste réservée ──────────────────────────────────────────────────
# Dossiers et services du cadriciel, puis clients intégrés du realm Keycloak.
RESERVED=(
  infra sso-lab scripts runner host chantiers lab-mcp mcp code keycloak auth
  deploiement workspace ws lab-work
  realms pgadmin phpldapadmin caddy edge-router postgres postgis
  admin-cli account account-console broker realm-management security-admin-console
)
for _r in "${RESERVED[@]}"; do
  if [[ "$NAME" == "$_r" ]]; then
    refuse "règle 5 : « ${NAME} » est un nom réservé (dossier/service du cadriciel ou client intégré du realm)"
    break
  fi
done

# ── Règle 6 — chemin Caddy réellement servi ───────────────────────────────────
# Le chemin servi peut DIFFÉRER du nom de dossier (analyse-lora sert /lora et
# /lora-api) : comparer les noms ne suffit pas, il faut lire les labels.
# Sources : labels `caddy…handle[_path]` de tous les docker-compose.yml de la
# racine (apps, sso-lab, infra, runner…) et directives du Caddyfile statique.
# Une variable `${VAR:-défaut}` est résolue depuis le .env du dossier, sinon par
# son défaut ; une variable non résoluble est ignorée (rien à comparer).
declare -A SERVED=()   # premier segment de chemin → dossier qui le sert
_add_served() {
  local raw="$1" src="$2" envf="$3" seg var def val
  # Résolution des ${VAR} / ${VAR:-défaut}
  while [[ "$raw" =~ \$\{([A-Za-z_][A-Za-z0-9_]*)(:?-([^}]*))?\} ]]; do
    var="${BASH_REMATCH[1]}"; def="${BASH_REMATCH[3]:-}"; val=""
    if [[ -f "$envf" ]]; then
      val="$(grep -E "^${var}=" "$envf" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d "\"'" || true)"
    fi
    raw="${raw/"${BASH_REMATCH[0]}"/${val:-$def}}"
  done
  # Une valeur de matcher peut lister plusieurs chemins séparés par des espaces.
  for seg in $raw; do
    [[ "$seg" == /* ]] || continue
    seg="${seg#/}"; seg="${seg%%/*}"; seg="${seg%%\**}"
    [[ -n "$seg" && -z "${SERVED[$seg]:-}" ]] && SERVED["$seg"]="$src"
  done
  return 0
}
while IFS= read -r _compose; do
  _dir="$(dirname "$_compose")"; _src="$(basename "$_dir")"
  while IFS= read -r _val; do
    _add_served "$_val" "$_src" "$_dir/.env"
  done < <(sed -n -E 's/^[[:space:]]*-?[[:space:]]*"?caddy(\.[0-9]+_|\.)(handle|handle_path|route|redir)(_[0-9]+)?"?[[:space:]]*[:=][[:space:]]*//p' "$_compose" \
           | sed -e 's/[[:space:]]*#.*$//' -e 's/^["'"'"']//' -e 's/["'"'"'][[:space:]]*$//')
done < <(registry_dirs_with docker-compose.yml | sed 's|$|/docker-compose.yml|')
if [[ -f "$ROOT/sso-lab/caddy/Caddyfile" ]]; then
  while IFS= read -r _val; do
    _add_served "$_val" "sso-lab/caddy/Caddyfile" "$ROOT/sso-lab/.env"
  done < <(sed -n -E 's/^[[:space:]]*(handle|handle_path|route|redir|reverse_proxy)[[:space:]]+(\/[^[:space:]{]*).*/\2/p' "$ROOT/sso-lab/caddy/Caddyfile")
fi
for _s in "${!SERVED[@]}"; do
  # Le propre chemin d'une app qui porterait déjà ce nom relève de la règle 2.
  if [[ "$_s" == "$NAME" || "$_s" == "$NAME-api" ]]; then
    refuse "règle 6 : le chemin Caddy /${_s} est déjà servi (par ${SERVED[$_s]})"
  elif [[ "$_s" == "$NAME"-* ]]; then
    refuse "règle 6 : le chemin Caddy /${_s}, déjà servi (par ${SERVED[$_s]}), porte le préfixe « ${NAME}- »"
  elif [[ "$NAME" == "$_s"-* ]]; then
    refuse "règle 6 : « ${NAME} » prolonge le chemin Caddy /${_s} déjà servi (par ${SERVED[$_s]})"
  fi
done

# ── Règle 7 — client Keycloak <nom> ou <nom>-admin déjà présent dans le realm ──
# Un client peut exister sans dossier (client natif créé avec --no-env, app
# supprimée dont le client est resté…). Si Keycloak est injoignable, la règle
# n'est PAS vérifiable : on refuse — accepter « faute de mieux » un nom dont le
# client existe peut-être reviendrait à rendre la règle facultative.
_kc_check() {
  local sso_env="$ROOT/sso-lab/.env" admin_user admin_pass kc_port kc_url token realm="ssolab" cid found
  command -v curl >/dev/null && command -v jq >/dev/null \
    || { refuse "règle 7 : non vérifiable — curl et jq sont requis"; return; }
  [[ -f "$sso_env" ]] || { refuse "règle 7 : non vérifiable — sso-lab/.env introuvable"; return; }
  _v() { grep -E "^$1=" "$sso_env" 2>/dev/null | head -1 | cut -d= -f2- | sed -e 's/[[:space:]]*#.*//' -e "s/^['\"]//" -e "s/['\"]\$//"; }
  admin_user="$(_v KEYCLOAK_ADMIN)";  admin_user="${admin_user:-admin}"
  admin_pass="$(_v KEYCLOAK_ADMIN_PASSWORD)"
  kc_port="$(_v PORT_KEYCLOAK)";      kc_port="${kc_port:-8080}"
  [[ -n "$admin_pass" ]] || { refuse "règle 7 : non vérifiable — KEYCLOAK_ADMIN_PASSWORD vide dans sso-lab/.env"; return; }
  if [[ -f /.dockerenv ]]; then kc_url="http://keycloak:${kc_port}"; else kc_url="http://localhost:${kc_port}"; fi

  # Le mot de passe passe par un descripteur de fichier, jamais par la ligne de
  # commande de curl : sur un hôte multi-comptes, argv est lisible par `ps`.
  token="$(curl -sf --max-time 15 \
             --data-urlencode "client_id=admin-cli" \
             --data-urlencode "grant_type=password" \
             --data-urlencode "username=${admin_user}" \
             --data-urlencode "password@/dev/fd/3" \
             "${kc_url}/realms/master/protocol/openid-connect/token" 3< <(printf '%s' "$admin_pass") 2>/dev/null \
           | jq -r '.access_token // empty' 2>/dev/null || true)"
  [[ -n "$token" ]] || { refuse "règle 7 : non vérifiable — Keycloak injoignable ou authentification admin refusée (${kc_url})"; return; }

  for cid in "$NAME" "$NAME-admin"; do
    # Le jeton passe lui aussi par un fichier de configuration lu sur un fd.
    found="$(curl -sf --max-time 15 -K /dev/fd/3 \
               "${kc_url}/admin/realms/${realm}/clients?clientId=${cid}" \
               3< <(printf 'header = "Authorization: Bearer %s"\n' "$token") 2>/dev/null \
             | jq -r 'if type == "array" then length else "erreur" end' 2>/dev/null || true)"
    case "$found" in
      0) ;;
      ''|erreur) refuse "règle 7 : non vérifiable — la recherche du client « ${cid} » dans le realm a échoué" ;;
      *) refuse "règle 7 : le client Keycloak « ${cid} » existe déjà dans le realm ${realm}" ;;
    esac
  done
}
_kc_check

if [[ ${#REASONS[@]} -gt 0 ]]; then
  printf '%s\n' "${REASONS[@]}" | sort -u
  exit 1
fi
exit 0
