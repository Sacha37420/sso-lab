#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# DOUBLE DE TEST de scripts/new-app.sh (tests/seed/) — ne scaffolde ni Django ni Angular, ne touche
# ni Docker ni une base. Il garde du vrai script ce dont l'étape « seed » dépend :
#   • la lecture des réponses sur l'entrée standard, `--owner <uid>` ;
#   • le dossier `deploiement/<app>`, les lignes `.owners` et `.ports` ;
#   • le rendu des règles (FEUILLE_DE_ROUTE.md, CLAUDE.md, AGENTS.md) — les quatre lignes `sed`
#     ci-dessous sont celles du vrai script, et tests/test_seed.py vérifie qu'elles y sont encore.
# Il relève aussi ce qu'un processus voisin peut voir à cet instant (arguments et environnement de
# tous les processus) : c'est la preuve que le contenu d'une graine n'y passe pas.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail
DEV_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TRACE="$DEV_DIR/.trace"
[[ "${1:-}" == --owner && -n "${2:-}" ]] || { echo "double new-app.sh : --owner <uid> attendu" >&2; exit 2; }
OWNER="$2"
mapfile -t ANSWERS
APP_NAME="${ANSWERS[0]}"
APP_TYPE="${ANSWERS[1]}"
{ printf 'new-app.sh'; printf ' %q' "$@"; printf ' | stdin :'; printf ' [%s]' "${ANSWERS[@]}"; printf '\n'; } >> "$TRACE/calls.log"
ps -eo args > "$TRACE/ps-new-app-$APP_NAME.txt"
for e in /proc/[0-9]*/environ; do { tr '\0' '\n' < "$e"; } 2> /dev/null || true; done > "$TRACE/environ-new-app-$APP_NAME.txt"
env > "$TRACE/env-new-app-$APP_NAME.txt"
# Le fichier qui portait la graine doit déjà avoir disparu (la chaîne le supprime en le lisant).
(ls /tmp/lab-mcp-seed-* 2> /dev/null || true) > "$TRACE/seedfiles-new-app-$APP_NAME.txt"

APP_DIR="$DEV_DIR/deploiement/$APP_NAME"
mkdir -p "$APP_DIR/backend"
printf 'services: {}\n' > "$APP_DIR/docker-compose.yml"
printf '.env\n' > "$APP_DIR/.gitignore"
echo "$APP_NAME:$OWNER" >> "$DEV_DIR/.owners"
echo "$APP_NAME:18100:14100" >> "$DEV_DIR/.ports"

_RULES_TMPL="$DEV_DIR/_templates/regles"
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
echo "✓ (double) $APP_NAME scaffoldée dans deploiement/ pour $OWNER"
