#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════════════
# rotate-app-secret.sh — Régénère le SECRET_KEY Django d'UNE application.
#
# Le SECRET_KEY signe les sessions, cookies signés, tokens CSRF et jetons de
# réinitialisation de mot de passe. S'il fuite (ex: .env poussé sur un dépôt
# public), un attaquant peut forger ces éléments : il DOIT être régénéré, et
# l'ancienne valeur devient alors sans valeur.
#
# Effet de bord assumé : régénérer le SECRET_KEY invalide les sessions en cours
# de CETTE app — les utilisateurs connectés devront se reconnecter. Rien d'autre.
#
# Idempotent au sens « sûr à rejouer » : chaque exécution pose une NOUVELLE clé.
# Ce n'est donc pas à lancer à chaque déploiement (cela déconnecterait les
# utilisateurs à chaque fois) — c'est pourquoi setup2.sh ne l'appelle que sous
# le drapeau --rotate-secrets.
#
# Usage :
#   bash rotate-app-secret.sh <app>
# ══════════════════════════════════════════════════════════════════════════════
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

APP="${1:-}"
[[ -n "$APP" ]] || { echo "Usage : bash rotate-app-secret.sh <app>" >&2; exit 1; }

ENV_FILE="$SCRIPT_DIR/$APP/.env"
[[ -f "$ENV_FILE" ]] || { echo "✗ $ENV_FILE introuvable." >&2; exit 1; }

# Pas de clé SECRET_KEY dans ce .env (app non-Django : Angular seul, Spring…) :
# rien à faire, ce n'est pas une erreur.
if ! grep -qE '^SECRET_KEY=' "$ENV_FILE"; then
  echo "⏭️  $APP : pas de SECRET_KEY dans son .env — ignoré."
  exit 0
fi

# 64 hex = 256 bits d'entropie, identique à ce que new-app.sh génère au scaffold.
NEW=$(python3 -c 'import secrets; print(secrets.token_hex(32))' 2>/dev/null) \
  || { echo "✗ python3 indisponible pour générer le secret." >&2; exit 1; }

# Remplacement ancré et sans interprétation du remplacement (| comme séparateur,
# la valeur est hex donc sans caractère spécial).
sed -i "s|^SECRET_KEY=.*|SECRET_KEY=${NEW}|" "$ENV_FILE"

echo "✓ $APP : SECRET_KEY régénéré (les sessions en cours de cette app seront invalidées)."
