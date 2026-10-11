#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# app-smtp.sh — pose (ou retire) un profil SMTP dans le .env d'une app.
# Contrat « multi-dev » v9, interface I10 (« Injection »).
#
# Usage :
#   bash scripts/app-smtp.sh <app> set   < profil.json      (JSON sur STDIN, jamais en argument)
#   bash scripts/app-smtp.sh <app> clear
#
#   set   lit sur stdin UNE valeur JSON
#           {"id","host","port","security","username","password","from_email"}
#         et pose dans le .env de l'app, atomiquement :
#           EMAIL_HOST  EMAIL_PORT  EMAIL_HOST_USER  EMAIL_HOST_PASSWORD
#           EMAIL_USE_TLS (security = starttls)  EMAIL_USE_SSL (security = ssl)
#           DEFAULT_FROM_EMAIL   et le marqueur   LAB_SMTP_PROFILE=<id>
#   clear retire le marqueur et VIDE ces sept clés (elles restent déclarées, vides).
#
# Code : 0 = écrit ; 1 = refus (entrée invalide, app inconnue…) ; 2 = usage.
# Rien de secret n'est jamais écrit sur stdout ni stderr : les messages nomment
# le champ fautif, pas sa valeur.
#
# POURQUOI DES VARIABLES ET PAS UN SERVICE : l'app parle elle-même à son
# fournisseur SMTP avec les réglages standard de Django — `send_mail(...)`,
# aucun code propre au lab. Le changement prend effet au prochain déploiement,
# ou tout de suite par `scripts/app-restart.sh <app>`.
#
# TANT QUE LE MARQUEUR EST POSÉ, ces sept clés sont gérées par le cadriciel :
# app-env.sh les masque et refuse de les écrire.
#
# ── Comment une valeur arrive INTACTE dans le processus Django ────────────────
# Le .env est lu par `docker compose` (env_file), qui a ses propres règles :
# sans guillemets, « # » précédé d'un espace ouvre un commentaire et « $VAR »
# est remplacé ; entre guillemets doubles, « $ » est remplacé et « \ » échappe.
# Un mot de passe SMTP contient souvent ces caractères. Encodage retenu, vérifié
# par un aller-retour réel (écriture ici → lecture dans le conteneur) :
#   • valeur faite de [A-Za-z0-9@._+:/=-]        → écrite telle quelle ;
#   • sinon, sans apostrophe                      → 'valeur'  (littéral pur pour compose) ;
#   • avec une apostrophe                         → "valeur" où \ " et $ sont
#                                                   précédés d'un \ .
# Sont REFUSÉS dans toute valeur : retour à la ligne et caractères de contrôle
# (ils casseraient le format « CLÉ=valeur ») ; et, dans username et password,
# tout caractère non ASCII (smtplib ne sait pas les transmettre).
# Limite connue : le troisième cas n'est relu correctement que par docker
# compose. python-decouple, s'il lisait le FICHIER .env lui-même, ne décoderait
# pas les « \ » ; dans un conteneur il lit l'environnement, posé par compose.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/registry.sh
source "$SCRIPT_DIR/lib/registry.sh"
# shellcheck source=lib/lock.sh
source "$SCRIPT_DIR/lib/lock.sh"

SMTP_KEYS=(EMAIL_HOST EMAIL_PORT EMAIL_HOST_USER EMAIL_HOST_PASSWORD EMAIL_USE_TLS EMAIL_USE_SSL DEFAULT_FROM_EMAIL)
MARKER="LAB_SMTP_PROFILE"

usage() { echo "Usage : bash scripts/app-smtp.sh <app> set|clear   (set : profil JSON sur stdin)" >&2; exit 2; }
die()   { echo "✗ app-smtp : $*" >&2; exit 1; }

[[ $# -eq 2 ]] || usage
APP="$1"; CMD="$2"
[[ "$CMD" == "set" || "$CMD" == "clear" ]] || usage
[[ "$APP" =~ ^[a-z][a-z0-9-]{1,38}[a-z0-9]$ ]] || die "nom d'app invalide"
APP_DIR="$(registry_app_dir "$APP")" || die "nom d'app invalide"
[[ -f "$APP_DIR/docker-compose.yml" ]] || die "app inconnue : '$APP'"
ENV_FILE="$APP_DIR/.env"
[[ -f "$ENV_FILE" && ! -L "$ENV_FILE" ]] || die "$APP n'a pas de .env (ou c'est un lien symbolique)"

# Encode une valeur pour une ligne « CLÉ=valeur » du .env (voir l'en-tête).
encode() {
  local v="$1"
  if [[ "$v" =~ ^[A-Za-z0-9@._+:/=-]*$ ]]; then
    printf '%s' "$v"
  elif [[ "$v" != *"'"* ]]; then
    printf "'%s'" "$v"
  else
    v="${v//\\/\\\\}"; v="${v//\"/\\\"}"; v="${v//\$/\\\$}"
    printf '"%s"' "$v"
  fi
}

declare -A VAL=()
PROFILE_ID=""

if [[ "$CMD" == "set" ]]; then
  command -v jq > /dev/null || die "jq est requis"
  # Lecture bornée de stdin ; rien de ce contenu ne passe par une ligne de commande.
  JSON="$(head -c 16385)"
  (( ${#JSON} <= 16384 )) || die "profil trop volumineux"
  [[ -n "$JSON" ]] || die "profil attendu sur stdin (JSON)"

  # Forme : un objet, chaînes ou nombre, AUCUN caractère de contrôle (un retour
  # à la ligne dans une valeur casserait le .env).
  jq -e 'def propre: explode | all(.[]; . >= 32 and . != 127 and . != 133 and . != 8232 and . != 8233);
         type == "object"
         and ([.id, .host, .security, .username, .password, .from_email] | all(.[]; . == null or type == "string"))
         and (.port | type == "number" or type == "string")
         and ([.id, .host, .security, .username, .password, .from_email, (.port | tostring)]
              | all(.[]; . == null or propre))' \
     > /dev/null 2>&1 <<< "$JSON" \
    || die "profil invalide : objet JSON attendu, champs en chaînes (port en nombre), sans retour à la ligne ni caractère de contrôle"

  field() { jq -r --arg k "$1" '.[$k] // "" | tostring' <<< "$JSON"; }
  PROFILE_ID="$(field id)"; HOST="$(field host)"; PORT="$(field port)"; SECURITY="$(field security)"
  USERNAME="$(field username)"; PASSWORD="$(field password)"; FROM_EMAIL="$(field from_email)"

  [[ "$PROFILE_ID" =~ ^[a-z0-9][a-z0-9_-]{0,39}$ ]] || die "champ id invalide (attendu : ^[a-z0-9][a-z0-9_-]{0,39}\$)"
  [[ ${#HOST} -le 253 && "$HOST" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ && "$HOST" != *..* ]] \
    || die "champ host invalide (nom d'hôte ou adresse, sans schéma ni port)"
  [[ "$PORT" =~ ^[0-9]{1,5}$ ]] && (( 10#$PORT >= 1 && 10#$PORT <= 65535 )) || die "champ port invalide (1 à 65535)"
  PORT="$((10#$PORT))"
  case "$SECURITY" in
    starttls) USE_TLS=True;  USE_SSL=False ;;
    ssl)      USE_TLS=False; USE_SSL=True ;;
    none)     USE_TLS=False; USE_SSL=False
              # Jamais d'identifiants en clair sur le réseau.
              [[ -z "$USERNAME" && -z "$PASSWORD" ]] || die "security « none » n'est accepté que sans username ni mot de passe" ;;
    *)        die "champ security invalide (starttls, ssl ou none)" ;;
  esac
  # ASCII seulement pour les identifiants : smtplib (donc Django) encode le nom
  # d'utilisateur et le mot de passe en ASCII au moment de s'authentifier, et
  # lève UnicodeEncodeError sur un « é ». Autant refuser ici, avec un message
  # lisible, que laisser l'app échouer à son premier envoi.
  LC_ALL=C
  [[ "$USERNAME" =~ ^[\ -~]*$ ]] || die "champ username : caractères ASCII imprimables seulement (un accent ne passe pas l'authentification SMTP de Python)"
  [[ "$PASSWORD" =~ ^[\ -~]*$ ]] || die "champ password : caractères ASCII imprimables seulement (un accent ne passe pas l'authentification SMTP de Python)"
  (( ${#USERNAME} <= 320 ))  || die "champ username trop long"
  (( ${#PASSWORD} <= 1024 )) || die "champ password trop long"
  [[ ${#FROM_EMAIL} -le 320 && "$FROM_EMAIL" =~ ^[^[:space:]\<\>@\"\',\;]+@[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] \
    || die "champ from_email invalide (une adresse, sans nom d'affichage)"

  VAL[EMAIL_HOST]="$HOST"; VAL[EMAIL_PORT]="$PORT"
  VAL[EMAIL_HOST_USER]="$USERNAME"; VAL[EMAIL_HOST_PASSWORD]="$PASSWORD"
  VAL[EMAIL_USE_TLS]="$USE_TLS"; VAL[EMAIL_USE_SSL]="$USE_SSL"
  VAL[DEFAULT_FROM_EMAIL]="$FROM_EMAIL"
else
  for k in "${SMTP_KEYS[@]}"; do VAL[$k]=""; done
fi

lab_lock_acquire "app-smtp.sh $CMD $APP" || exit $?

# ── Réécriture atomique, mode du fichier conservé ─────────────────────────────
# Toutes les lignes existantes sont gardées telles quelles, SAUF celles des sept
# clés et du marqueur, remplacées par un bloc unique en fin de fichier.
TMP="$(umask 077; mktemp "$APP_DIR/.env.XXXXXX")" || die "écriture impossible dans le dossier de l'app"
trap '[[ -f "$TMP" ]] && unlink "$TMP"' EXIT
is_ours() {
  local k
  [[ "$1" == "$MARKER" ]] && return 0
  for k in "${SMTP_KEYS[@]}"; do [[ "$1" == "$k" ]] && return 0; done
  return 1
}
{
  last_blank=false
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*= ]] && is_ours "${BASH_REMATCH[1]}"; then
      continue
    fi
    # L'en-tête du bloc (celui de new-app.sh comme le nôtre) est réécrit plus bas.
    [[ "$line" == "# ── Email (SMTP)"* ]] && continue
    printf '%s\n' "$line"
    [[ -z "$line" ]] && last_blank=true || last_blank=false
  done < "$ENV_FILE"
  $last_blank || printf '\n'
  if [[ "$CMD" == "set" ]]; then
    printf '%s\n' "# ── Email (SMTP) — posé par scripts/app-smtp.sh, ne pas éditer à la main ──"
    printf '%s=%s\n' "$MARKER" "$PROFILE_ID"
  else
    printf '%s\n' "# ── Email (SMTP) ─────────────────────────────────────────────────"
  fi
  for k in "${SMTP_KEYS[@]}"; do
    printf '%s=%s\n' "$k" "$(encode "${VAL[$k]}")"
  done
} > "$TMP" || die "écriture impossible"
chmod --reference="$ENV_FILE" "$TMP" || die "mode du .env non reproductible"
mv "$TMP" "$ENV_FILE" || die "remplacement du .env impossible"

if [[ "$CMD" == "set" ]]; then
  echo "✓ profil SMTP « $PROFILE_ID » posé dans le .env de $APP (prise en compte : app-restart.sh, ou prochain déploiement)" >&2
else
  echo "✓ profil SMTP retiré du .env de $APP (prise en compte : app-restart.sh, ou prochain déploiement)" >&2
fi
