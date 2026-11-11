#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# lab-doctor.sh — bilan de santé du lab, en LECTURE SEULE. Ne crée, ne modifie,
#                 ne démarre et n'arrête rien (to_do_global.md, T2 « doctor »).
#
# Usage :
#   bash scripts/lab-doctor.sh            bilan complet
#   bash scripts/lab-doctor.sh --check    identique (le script ne fait jamais rien d'autre)
#   bash scripts/lab-doctor.sh --quick    sans install.sh --check (le plus long, ≈ 1 min)
#
# Code de sortie : 0 = aucun problème ; 1 = au moins un problème (✘) ; 2 = usage.
# Les avertissements (!) ne changent pas le code de sortie.
#
# Contrôles :
#    1. install.sh --check : l'installation est-elle complète ?
#    2. pg_hba.conf verrouillé (dev-db.sh hba-status) ;
#    3. partages de groupe de storage (storage-shares.sh --check) ;
#    4. dernière sauvegarde : RAPPORT.txt « ✓ Sauvegarde complète » de moins de 26 h,
#       et la sauvegarde planifiée (backup-cron.sh --check) ;
#    5. Keycloak : aucun client ACTIF avec une URI de retour « * », les clients
#       publics actifs en PKCE S256, scope nonce-keycloak-js-22 par défaut ;
#    6. ports publiés : tout port de l'hôte lié à 127.0.0.1, sauf edge-router (80/443)
#       et lab-media (8189) ;
#    7. conteneurs : redémarrages en boucle, santé « unhealthy », conteneurs arrêtés,
#       conteneurs sans nom de service (lancés à la main par « docker run » ou
#       « compose run » et jamais retirés) ;
#    8. cloisonnement : dernier verdict du moteur par app (<LAB_STATE_DIR>/tests/) ;
#    9. disque (alerte au-delà de 85 %) et cache de construction Docker.
# Aucun secret n'est affiché : les sorties des scripts appelés sont résumées.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/registry.sh
source "$SCRIPT_DIR/lib/registry.sh"
ROOT="$(registry_root)"
cd "$ROOT" || exit 1

QUICK=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --check) ;;
    --quick) QUICK=true ;;
    -h|--help) sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Option inconnue : $1 (voir --help)" >&2; exit 2 ;;
  esac
  shift
done

B='\033[1m'; G='\033[0;32m'; Y='\033[1;33m'; R='\033[0;31m'; C='\033[0;36m'; N='\033[0m'
PROBLEMS=0; WARNINGS=0
section() { echo -e "\n${B}${C}── $*${N}"; }
ok()   { echo -e "  ${G}✔${N} $*"; }
warn() { echo -e "  ${Y}!${N} $*"; WARNINGS=$((WARNINGS + 1)); }
bad()  { echo -e "  ${R}✘${N} $*"; PROBLEMS=$((PROBLEMS + 1)); }
strip() { sed 's/\x1b\[[0-9;]*m//g'; }

docker info > /dev/null 2>&1 || { bad "le démon Docker ne répond pas à $(id -un)"; exit 1; }

# ── 1 ────────────────────────────────────────────────────────────────────────
section "1. Installation (install.sh --check)"
if $QUICK; then warn "sauté (--quick)"
else
  out="$(bash "$SCRIPT_DIR/install.sh" --check 2>&1 | strip)"
  if grep -q "Rien à faire" <<< "$out"; then ok "installation complète"
  else
    while IFS= read -r l; do bad "install.sh ferait : ${l#*• }"; done < <(sed -n '/action(s) que/,/point(s) qui restent/p' <<< "$out" | grep '•')
    while IFS= read -r l; do bad "à la main : ${l#*• }"; done < <(sed -n '/point(s) qui restent/,$p' <<< "$out" | grep '•')
  fi
fi

# ── 2 ────────────────────────────────────────────────────────────────────────
section "2. PostgreSQL : aucune connexion réseau sans mot de passe"
if out="$(bash "$SCRIPT_DIR/dev-db.sh" hba-status 2>&1)"; then ok "$(tr '\n' ' ' <<< "$out")"
else bad "pg_hba.conf : $(tr '\n' ' ' <<< "$out") (CLAUDE.md, « Base de données »)"; fi

# ── 3 ────────────────────────────────────────────────────────────────────────
section "3. Partages de groupe de storage"
if bash "$SCRIPT_DIR/storage-shares.sh" --check > /dev/null 2>&1; then ok "tous présents"
else bad "partages manquants ou différents (bash scripts/storage-shares.sh --check)"; fi
section "3 bis. oauth-hub et tâches de nuit"
# Fiche GitHub d'oauth-hub : sans client_id + secret, ni création de projet ni éditeur.
# (fait aussi par install.sh --check, sauté en --quick)
_oh="$(docker exec oauth-hub-backend python manage.py provider_credentials status github 2>/dev/null)"; _rc=$?
case "$_rc" in
  0) ok "oauth-hub : fiche GitHub complète" ;;
  3) bad "oauth-hub : fiche GitHub sans identifiants (bash scripts/install.sh les demande à la fin)" ;;
  4) bad "oauth-hub : fiche GitHub absente" ;;
  *) warn "oauth-hub : état de la fiche GitHub illisible (conteneur arrêté, ou image antérieure à provider_credentials)" ;;
esac

# Tâches de nuit (automatisation/, chantier nuit-auto I6)
_auto="$(registry_state_dir 2>/dev/null)/auto/runs"
if crontab -l 2>/dev/null | grep -q 'automatisation/bin/auto.sh'; then
  _er="$(ls -1d "$_auto"/*/ 2>/dev/null | sort | tail -1)"
  if [[ -z "$_er" ]]; then warn "tâches de nuit planifiées, aucun passage enregistré"
  else
    _st="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d.get("statut","?"), d.get("date","?"), d.get("tache","?"))' "$_er/etat.json" 2>/dev/null)"
    _age_d=$(( ( $(date +%s) - $(stat -c %Y "$_er") ) / 86400 ))
    case "${_st%% *}" in
      fini) (( _age_d <= 2 )) && ok "tâches de nuit : dernier passage fini (${_st#* })" || bad "tâches de nuit : aucun passage depuis ${_age_d} jours" ;;
      *) bad "tâches de nuit : dernier passage « ${_st:-illisible} » (bash automatisation/bin/auto.sh etat)" ;;
    esac
  fi
fi

# ── 4 ────────────────────────────────────────────────────────────────────────
section "4. Sauvegarde"
_bdir="$(registry_root_env LAB_BACKUP_DIR)"; _bdir="${_bdir:-$HOME/sauvegardes/lab}"; _bdir="${_bdir/#\~/$HOME}"
_last="$(find "$_bdir" -mindepth 2 -maxdepth 2 -name RAPPORT.txt -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1)"
if [[ -z "$_last" ]]; then bad "aucun RAPPORT.txt dans $_bdir : aucune sauvegarde locale"
else
  _age_h=$(( ( $(date +%s) - ${_last%%.*} ) / 3600 )); _rep="${_last#* }"
  if ! grep -q "✓ Sauvegarde complète" "$_rep"; then bad "dernière sauvegarde en défaut : $_rep"
  elif (( _age_h > 26 )); then bad "dernière sauvegarde complète vieille de ${_age_h} h ($_rep)"
  else ok "dernière sauvegarde complète il y a ${_age_h} h ($(basename "$(dirname "$_rep")"))"; fi
  grep -q "déposé et vérifié" "$_rep" 2>/dev/null || warn "pas de copie NAS vérifiée dans $_rep"
fi
if bash "$SCRIPT_DIR/backup-cron.sh" --check > /dev/null 2>&1; then ok "sauvegarde planifiée (crontab)"
else bad "sauvegarde non planifiée ou copie NAS incomplète (bash scripts/backup-cron.sh --check)"; fi
grep -qE '^[[:space:]]*seal\(\)[[:space:]]*\{[[:space:]]*:?[[:space:]]*;?[[:space:]]*\}' "$SCRIPT_DIR/backup.sh" 2>/dev/null \
  && warn "les sauvegardes ne sont pas chiffrées (seal() vide dans backup.sh — to_do_global.md T5)"

# ── 5 ────────────────────────────────────────────────────────────────────────
section "5. Keycloak"
# shellcheck source=lib/kcadmin.sh
source "$SCRIPT_DIR/lib/kcadmin.sh"
if kc_admin_login > /dev/null 2>&1 && clients="$(kc_admin_get "/clients?max=500")"; then
  # Les clients intégrés du realm (account, security-admin-console…) ont des URI relatives : ignorées.
  _joker="$(jq -r '.[] | select(.enabled and any(.redirectUris[]?; . == "*" or test("^[a-z]+://[^/]*\\*")))
                   | .clientId' <<< "$clients" | tr '\n' ' ')"
  [[ -z "$_joker" ]] && ok "aucun client actif avec un joker en URI de retour" || bad "joker en URI de retour : $_joker"
  _nopkce="$(jq -r '.[] | select(.enabled and .publicClient and .standardFlowEnabled and (.clientId | test("^(account|account-console|security-admin-console|admin-cli)$") | not)
                     and (.attributes["pkce.code.challenge.method"] // "") != "S256") | .clientId' <<< "$clients" | tr '\n' ' ')"
  [[ -z "$_nopkce" ]] && ok "clients publics actifs : tous en PKCE S256" || warn "clients publics sans PKCE exigé : $_nopkce"
  _off="$(jq -r '.[] | select(.enabled | not) | .clientId' <<< "$clients" | tr '\n' ' ')"
  [[ -n "$_off" ]] && warn "clients désactivés (à décider : réactiver ou supprimer) : $_off"
  if kc_admin_get "/default-default-client-scopes" 2>/dev/null | jq -e 'any(.[]; .name == "nonce-keycloak-js-22")' > /dev/null; then
    ok "scope nonce-keycloak-js-22 par défaut du realm"
  else bad "scope nonce-keycloak-js-22 absent : boucle de connexion dans les apps (bash scripts/keycloak-nonce-compat.sh)"; fi
else
  bad "API d'administration de Keycloak injoignable (Keycloak arrêté, ou identifiants de sso-lab/.env refusés)"
fi

# ── 6 ────────────────────────────────────────────────────────────────────────
section "6. Ports publiés sur l'hôte"
# Un conteneur d'un AUTRE cadriciel de l'hôte (dossier Compose hors de ce dépôt, ex. ~/dev2)
# est signalé en avertissement : ce n'est pas à ce lab de le corriger.
_open="$(docker ps -q | xargs -r docker inspect | jq -r --arg root "$ROOT" '.[] | (.Name | ltrimstr("/")) as $n
          | (.Config.Labels["com.docker.compose.project.working_dir"] // "") as $wd
          | (if ($wd | startswith($root + "/")) or $wd == $root or $wd == "" then "ici" else "ailleurs" end) as $where
          | (.HostConfig.PortBindings // {}) | to_entries[] | .value[]
          | select((.HostIp // "") != "127.0.0.1" and (.HostIp // "") != "::1")
          | "\($where) \($n) \(.HostIp // "")::\(.HostPort)"' \
        | awk '!($2 == "edge-router" && ($3 ~ /:(80|443)$/)) && !($2 == "lab-media" && $3 ~ /:8189$/)' | sort -u)"
if [[ -z "$(grep '^ici ' <<< "$_open")" ]]; then ok "ce lab : tout est lié à 127.0.0.1 (hors edge-router 80/443 et lab-media 8189)"
else while IFS= read -r l; do bad "port ouvert sur toutes les interfaces : ${l#ici }"; done < <(grep '^ici ' <<< "$_open"); fi
while IFS= read -r l; do [[ -n "$l" ]] && warn "autre cadriciel de l'hôte, port ouvert sur toutes les interfaces : ${l#ailleurs }"; done < <(grep '^ailleurs ' <<< "$_open")

# ── 7 ────────────────────────────────────────────────────────────────────────
section "7. Conteneurs"
_all="$(docker ps -aq | xargs -r docker inspect)"
_loop="$(jq -r '.[] | select(.RestartCount > 3) | "\(.Name|ltrimstr("/")) (\(.RestartCount) redémarrages)"' <<< "$_all")"
_unh="$(jq -r '.[] | select(.State.Health.Status? == "unhealthy") | .Name | ltrimstr("/")' <<< "$_all")"
_stop="$(jq -r '.[] | select(.State.Status != "running") | "\(.Name|ltrimstr("/")) (\(.State.Status))"' <<< "$_all")"
# Un conteneur de service Compose porte le nom de son container_name ou <projet>-<service>-<n> ;
# un nom « adjectif_nom » est celui que Docker donne à un « docker run » sans --name.
_orph="$(jq -r '.[] | (.Name|ltrimstr("/")) as $n | select($n | test("^[a-z]+_[a-z]+$"))
         | "\($n) (image \(.Config.Image), depuis \(.State.StartedAt[0:10]))"' <<< "$_all")"
[[ -z "$_loop" ]] && ok "aucun redémarrage en boucle" || while IFS= read -r l; do bad "redémarre : $l"; done <<< "$_loop"
[[ -z "$_unh" ]]  && ok "aucun conteneur « unhealthy »" || while IFS= read -r l; do bad "unhealthy : $l"; done <<< "$_unh"
[[ -z "$_stop" ]] && ok "aucun conteneur arrêté" || while IFS= read -r l; do warn "arrêté : $l"; done <<< "$_stop"
[[ -z "$_orph" ]] && ok "aucun conteneur lancé à la main et oublié" || while IFS= read -r l; do warn "conteneur sans nom de service, probablement un essai oublié : $l"; done <<< "$_orph"

# ── 8 ────────────────────────────────────────────────────────────────────────
section "8. Cloisonnement (derniers verdicts du moteur)"
_tests="$(registry_state_dir)/tests"
if [[ ! -d "$_tests" ]]; then warn "aucun verdict ($_tests absent) : lancer « Tout tester » dans lab-admin"
else
  _ko=""; _n=0
  for f in "$_tests"/*.json; do
    [[ -f "$f" ]] || continue; _n=$((_n + 1))
    v="$(jq -r '.verdict // .status // .result // empty' "$f" 2>/dev/null)"
    [[ "$v" == "ok" ]] || _ko+="$(basename "$f" .json)=${v:-?} "
  done
  if [[ -z "$_ko" ]]; then ok "$_n app(s), toutes « ok »"; else warn "$_n app(s) ; pas « ok » : $_ko"; fi
fi

# ── 9 ────────────────────────────────────────────────────────────────────────
section "9. Disque et Docker"
_pct="$(df --output=pcent "$ROOT" | tail -1 | tr -dc '0-9')"
(( _pct > 85 )) && bad "disque plein à ${_pct} %" || ok "disque : ${_pct} % utilisés"
_cache="$(docker system df --format '{{.Type}} {{.Reclaimable}}' 2>/dev/null | awk '$1 == "Build" { $1 = ""; $2 = ""; sub(/^ +/, ""); print }')"
[[ -n "$_cache" ]] && ok "cache de construction récupérable : ${_cache}"
_rb="$(docker images --format '{{.Repository}}' | grep -c '^rollback/' || true)"
(( _rb > 0 )) && warn "${_rb} image(s) rollback/* gardées (to_do_global.md T8)"

echo ""
if (( PROBLEMS == 0 )); then echo -e "${G}${B}Aucun problème${N} (${WARNINGS} avertissement(s))."; exit 0; fi
echo -e "${R}${B}${PROBLEMS} problème(s)${N}, ${WARNINGS} avertissement(s)."; exit 1
