#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# dev-enroll.sh — inscrit un développeur dans le cadriciel.
# Contrat « multi-dev » v5, interfaces I1/I2.
#
# Usage :
#   bash scripts/dev-enroll.sh <uid> [--gis]
#   bash scripts/dev-enroll.sh --check <uid>               (lecture seule : rien n'est inscrit)
#   bash scripts/dev-enroll.sh --remove <uid> [--drop-db]
#
# Inscrire un dev = une ligne .devs et sa base dev_<uid>. Il n'y a PAS de compte
# Unix par développeur (contrat v5, I3) : il travaille dans un espace de
# travail en conteneur, ouvert par le moteur. Le compte LDAP préexiste
# (scripts/add-user.sh) : <uid> est à la fois le uid LDAP et le
# preferred_username Keycloak.
#
# CONDITION D'ENTRÉE (contrat v4, I1) : le compte doit exister dans Keycloak et
# être membre du groupe LDAP `developers` — c'est ce groupe qui lui ouvre
# lab-admin et le serveur MCP. Vérifié par l'API Admin Keycloak ; refus sinon
# (compte introuvable = refus aussi ; Keycloak injoignable = refus : on
# n'inscrit pas « faute de pouvoir vérifier »). `.devs` reste seul à définir
# « inscrit » : être dans `developers` sans y figurer ne donne aucune fonction.
#
# --check    fait ce seul contrôle et sort (0 = inscriptible, 1 = refus). N'écrit rien.
# --no-ldap-check   saute ce contrôle. RÉSERVÉ AUX TESTS du cadriciel (dev fictif
#            sans compte dans l'annuaire) — jamais pour inscrire une personne.
# --gis      provisionne aussi gis_<uid> sur dev-postgis (apps SIG).
# --remove   retire la ligne .devs ; refuse s'il reste des apps au dev dans
#            .owners. --drop-db supprime en plus ses bases et son rôle
#            (irréversible).
#
# Écrit .devs sous le verrou de déploiement.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/registry.sh
source "$SCRIPT_DIR/lib/registry.sh"
# shellcheck source=lib/lock.sh
source "$SCRIPT_DIR/lib/lock.sh"
ROOT="$(registry_root)"
DEVS="$ROOT/.devs"

die() { echo "✘ dev-enroll : $*" >&2; exit 1; }

REMOVE=false; GIS=false; DROP_DB=false; CHECK_ONLY=false; LDAP_CHECK=true; DEV_UID=""
REQUIRED_GROUP="developers"
for a in "$@"; do
  case "$a" in
    --remove)  REMOVE=true ;;
    --gis)     GIS=true ;;
    --drop-db) DROP_DB=true ;;
    --check)   CHECK_ONLY=true ;;
    --no-ldap-check) LDAP_CHECK=false ;;
    -h|--help) sed -n '/^# Usage :/,/^#$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*)        die "option inconnue : $a" ;;
    *)         [[ -z "$DEV_UID" ]] && DEV_UID="$a" || die "argument en trop : $a" ;;
  esac
done
registry_valid_uid "$DEV_UID" || die "uid invalide : '${DEV_UID}' (attendu : ^[a-z][a-z0-9]{1,30}\$)"

# Contrôle d'appartenance au groupe `developers` (lecture seule côté Keycloak).
check_developer() {
  # shellcheck source=lib/kcadmin.sh
  source "$SCRIPT_DIR/lib/kcadmin.sh"
  local groups rc=0
  groups="$(kc_user_groups "$DEV_UID")" || rc=$?
  case $rc in
    0) ;;
    3) echo "✘ dev-enroll : aucun compte « ${DEV_UID} » dans Keycloak (realm ssolab) — le créer d'abord : bash scripts/add-user.sh (groupe ${REQUIRED_GROUP})" >&2; return 1 ;;
    *) echo "✘ dev-enroll : appartenance de « ${DEV_UID} » au groupe ${REQUIRED_GROUP} NON vérifiable (Keycloak injoignable ou erreur d'API) — inscription refusée" >&2; return 1 ;;
  esac
  if ! grep -qxF -- "$REQUIRED_GROUP" <<< "$groups"; then
    echo "✘ dev-enroll : « ${DEV_UID} » n'est pas membre du groupe LDAP ${REQUIRED_GROUP} (ses groupes : $(tr '\n' ' ' <<< "${groups:-aucun}")) — l'y ajouter d'abord (sso-lab/ldap/init.ldif ou phpLDAPadmin), puis relancer" >&2
    return 1
  fi
  echo "  ✔ « ${DEV_UID} » existe dans Keycloak et est membre de ${REQUIRED_GROUP}"
}

if $CHECK_ONLY; then
  check_developer; exit $?
fi

lab_lock_acquire "dev-enroll.sh $DEV_UID"

if $REMOVE; then
  if [[ -f "$ROOT/.owners" ]] && grep -qE "^[^:#]+:${DEV_UID}\$" "$ROOT/.owners"; then
    die "« ${DEV_UID} » possède encore des apps : $(grep -E "^[^:#]+:${DEV_UID}\$" "$ROOT/.owners" | cut -d: -f1 | tr '\n' ' ')— les retirer d'abord (scripts/app-remove.sh)"
  fi
  if [[ -f "$DEVS" ]] && grep -qxF -- "$DEV_UID" "$DEVS"; then
    grep -vxF -- "$DEV_UID" "$DEVS" > "$DEVS.tmp" || true
    mv "$DEVS.tmp" "$DEVS"
    [[ -s "$DEVS" ]] || rm -f "$DEVS"
    echo "  ✔ « ${DEV_UID} » retiré de .devs"
  else
    echo "  → « ${DEV_UID} » n'était pas dans .devs"
  fi
  if $DROP_DB; then
    bash "$SCRIPT_DIR/dev-db.sh" drop "$DEV_UID" --yes
  else
    echo "  → bases conservées (bash scripts/dev-db.sh drop ${DEV_UID} --yes pour les supprimer)"
  fi
  exit 0
fi

# ── Inscription ───────────────────────────────────────────────────────────────
# Avant toute écriture (base, .devs) : la condition d'entrée.
if $LDAP_CHECK; then
  check_developer || exit 1
else
  echo "  ⚠ contrôle du groupe ${REQUIRED_GROUP} SAUTÉ (--no-ldap-check) — réservé aux tests du cadriciel" >&2
fi
# La base d'abord : si le provisionnement échoue, le dev n'est pas inscrit.
if $GIS; then bash "$SCRIPT_DIR/dev-db.sh" ensure "$DEV_UID" --gis
else          bash "$SCRIPT_DIR/dev-db.sh" ensure "$DEV_UID"; fi

if [[ -f "$DEVS" ]] && grep -qxF -- "$DEV_UID" "$DEVS"; then
  echo "  → « ${DEV_UID} » déjà inscrit dans .devs"
else
  echo "$DEV_UID" >> "$DEVS"
  echo "  ✔ « ${DEV_UID} » inscrit dans .devs"
fi
