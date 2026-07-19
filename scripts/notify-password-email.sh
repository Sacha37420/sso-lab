#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════════════
# notify-password-email.sh — Envoie par email un nouveau mot de passe LDAP à un
# utilisateur, via le SMTP déjà configuré pour Keycloak (sso-lab/.env).
#
# BEST-EFFORT PAR CONCEPTION : une adresse factice (@ssolab.local), un SMTP non
# configuré, ou un échec d'envoi n'est jamais fatal pour l'appelant — le mot de
# passe est de toute façon déjà écrit dans sso-lab/.env et affiché dans le
# terminal par le script appelant. Ce script ne fait qu'ajouter une notification,
# jamais la seule trace du nouveau mot de passe.
#
# Usage :
#   bash notify-password-email.sh <uid> <email> <nouveau-mot-de-passe>
# ══════════════════════════════════════════════════════════════════════════════
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SSO_ENV="$SCRIPT_DIR/sso-lab/.env"

UID_ARG="${1:-}"; EMAIL="${2:-}"; NEWPASS="${3:-}"
[[ -n "$UID_ARG" && -n "$EMAIL" && -n "$NEWPASS" ]] || {
  echo "Usage : bash notify-password-email.sh <uid> <email> <nouveau-mot-de-passe>" >&2; exit 1; }

env_val() { grep -E "^$1=" "$SSO_ENV" 2>/dev/null | head -1 | cut -d= -f2-; }

# Adresses factices utilisées pour les comptes sans email réel (voir README) :
# jamais délivrables, on ne tente même pas l'envoi.
if [[ "$EMAIL" == *"@ssolab.local" ]]; then
  echo "  ⏭️  ${UID_ARG} : adresse factice (${EMAIL}) — pas d'email, mot de passe affiché ci-dessus uniquement."
  exit 0
fi

SMTP_HOST="$(env_val SMTP_HOST)"
SMTP_PORT="$(env_val SMTP_PORT)"
SMTP_USER="$(env_val SMTP_USER)"
SMTP_PASSWORD="$(env_val SMTP_PASSWORD)"
SMTP_FROM="$(env_val SMTP_FROM)"
SMTP_FROM_DISPLAY="$(env_val SMTP_FROM_DISPLAY)"
SMTP_STARTTLS="$(env_val SMTP_STARTTLS)"
SMTP_SSL="$(env_val SMTP_SSL)"

# Même garde que create-app-client.sh : tant que SMTP_FROM est vide, le SMTP
# n'est pas considéré comme configuré.
if [[ -z "$SMTP_FROM" || -z "$SMTP_USER" || -z "$SMTP_PASSWORD" ]]; then
  echo "  ⏭️  ${UID_ARG} : SMTP non configuré (SMTP_FROM/SMTP_USER/SMTP_PASSWORD vide) — pas d'email."
  exit 0
fi

DOMAIN="$(env_val DOMAIN)"
if [[ -n "$DOMAIN" && "$DOMAIN" != "CHANGE_ME" ]]; then
  LOGIN_URL="https://${DOMAIN}/auth/realms/ssolab/account"
else
  WAN_HOST="$(env_val SERVER_URL_WAN | sed -E 's#^https?://##')"
  KC_PORT="$(env_val PORT_KEYCLOAK)"; KC_PORT="${KC_PORT:-8080}"
  LOGIN_URL="http://${WAN_HOST}:${KC_PORT}/realms/ssolab/account"
fi

if SMTP_HOST="$SMTP_HOST" SMTP_PORT="$SMTP_PORT" SMTP_USER="$SMTP_USER" SMTP_PASSWORD="$SMTP_PASSWORD" \
   SMTP_FROM="$SMTP_FROM" SMTP_FROM_DISPLAY="$SMTP_FROM_DISPLAY" SMTP_STARTTLS="$SMTP_STARTTLS" SMTP_SSL="$SMTP_SSL" \
   TO_EMAIL="$EMAIL" TO_UID="$UID_ARG" NEW_PASSWORD="$NEWPASS" LOGIN_URL="$LOGIN_URL" \
   python3 - >/dev/null 2>&1 <<'PY'
import os, smtplib, ssl
from email.mime.text import MIMEText
from email.utils import formataddr

host = os.environ["SMTP_HOST"]
port = int(os.environ.get("SMTP_PORT") or "587")
user = os.environ["SMTP_USER"]
password = os.environ["SMTP_PASSWORD"]
from_addr = os.environ["SMTP_FROM"]
from_display = os.environ.get("SMTP_FROM_DISPLAY") or "SSO Lab"
starttls = (os.environ.get("SMTP_STARTTLS") or "true").lower() == "true"
use_ssl = (os.environ.get("SMTP_SSL") or "false").lower() == "true"
to_email = os.environ["TO_EMAIL"]
uid = os.environ["TO_UID"]
new_password = os.environ["NEW_PASSWORD"]
login_url = os.environ["LOGIN_URL"]

body = (
    f"Bonjour {uid},\n\n"
    "Votre mot de passe du Lab SSO vient d'etre renouvele automatiquement.\n\n"
    f"Nouveau mot de passe : {new_password}\n\n"
    f"Connexion : {login_url}\n\n"
    "Si vous n'etes pas a l'origine de cette demande, contactez l'administrateur du lab.\n"
)
msg = MIMEText(body, "plain", "utf-8")
msg["Subject"] = "Votre mot de passe Lab SSO a ete renouvele"
msg["From"] = formataddr((from_display, from_addr))
msg["To"] = to_email

context = ssl.create_default_context()
if use_ssl:
    server = smtplib.SMTP_SSL(host, port, context=context, timeout=15)
else:
    server = smtplib.SMTP(host, port, timeout=15)
    if starttls:
        server.starttls(context=context)
try:
    server.login(user, password)
    server.sendmail(from_addr, [to_email], msg.as_string())
finally:
    server.quit()
PY
then
  echo "  ✉️  ${UID_ARG} : email envoyé à ${EMAIL}."
else
  echo "  ⚠️  ${UID_ARG} : échec d'envoi de l'email à ${EMAIL} (mot de passe déjà écrit dans sso-lab/.env)." >&2
fi
