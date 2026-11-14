#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# tests/modules/run.sh — modules du lab par le moteur (chantier « modules », contrat v1, I4).
#
#   bash lab-mcp/tests/modules/run.sh            tous les essais, puis la comparaison avant/après
#   bash lab-mcp/tests/modules/run.sh tests      tests/test_modules.py seul
#   bash lab-mcp/tests/modules/run.sh compare    des DÉPLOIEMENTS seuls (succès, portes, refus, build et
#                                                tests rouges), joués avec le moteur d'avant (commit
#                                                MODULES_BASELINE) et le moteur courant : même réponse,
#                                                mêmes étapes, même journal, même résultat, mêmes scripts
#
# NE TOUCHE À RIEN DU LAB : ni `lab-mcp` en service, ni une app, ni un registre, ni une base. Ne
# construit aucune image : le moteur d'essai est l'image du moteur déjà présente (LAB_MCP_IMAGE, défaut
# « lab-mcp-lab-mcp:latest ») avec labmcp/ et tests/ du DOSSIER DE TRAVAIL montés par-dessus, en lecture
# seule. Conteneurs jetables `zz-modules-*`, `--network none`, sans socket Docker, sans port publié, sans
# label `caddy`. Du dépôt, seul `scripts/` est monté, en lecture seule, et COPIÉ dans une racine factice
# créée DANS le conteneur (cinq scripts y sont remplacés par des doubles : tests/modules/scripts/).
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MCP="$(cd "$HERE/../.." && pwd)"
DEV="$(cd "$MCP/.." && pwd)"
ENGINE_IMAGE="${LAB_MCP_IMAGE:-lab-mcp-lab-mcp:latest}"
BASELINE="${MODULES_BASELINE:-b28471c}"   # dernier commit du moteur SANS les modules
P="zz-modules-mcp"
WHAT="${1:-all}"

docker image inspect "$ENGINE_IMAGE" > /dev/null 2>&1 || { echo "image absente : $ENGINE_IMAGE (cet essai n'en construit aucune)" >&2; exit 2; }
WORK="$(mktemp -d)"
cleanup() { docker rm -f "$P-tests" "$P-avant" "$P-apres" > /dev/null 2>&1; rm -rf "$WORK"; }
trap cleanup EXIT
status=0

engine() {  # engine <nom> <dossier labmcp> <arguments de test_modules.py…>
  local name="$1" code="$2"; shift 2
  docker run --rm --name "$name" --network none --cap-drop ALL --security-opt no-new-privileges \
    --user "$(id -u):$(id -g)" -e HOME=/tmp \
    -v "$code:/app/labmcp:ro" -v "$MCP/tests:/tests:ro" -v "$DEV/scripts:/lab-scripts:ro" \
    -v "$WORK:/out" "$ENGINE_IMAGE" python -u -W ignore::ResourceWarning /tests/test_modules.py "$@"
}

if [[ "$WHAT" == all || "$WHAT" == tests ]]; then
  echo "════ Modules — tests/test_modules.py ════"
  engine "$P-tests" "$MCP/labmcp" || status=1
fi

if [[ "$WHAT" == all || "$WHAT" == compare ]]; then
  echo "════ Déploiements : moteur de $BASELINE contre moteur courant ════"
  mkdir -p "$WORK/avant"
  if git -C "$DEV" archive "$BASELINE" lab-mcp/labmcp 2> /dev/null | tar -x -C "$WORK/avant" \
     && [[ -f "$WORK/avant/lab-mcp/labmcp/chain.py" ]] && ! grep -q "def deploy_steps" "$WORK/avant/lab-mcp/labmcp/chain.py"; then
    engine "$P-avant" "$WORK/avant/lab-mcp/labmcp" --trace /out/avant.json || status=1
    engine "$P-apres" "$MCP/labmcp" --trace /out/apres.json || status=1
    if [[ -s "$WORK/avant.json" ]] && diff -u "$WORK/avant.json" "$WORK/apres.json"; then
      echo "IDENTIQUE — $(wc -l < "$WORK/apres.json") lignes de trace (6 déploiements : réponse, étapes, journal, résultat, scripts lancés, arguments de la chaîne)"
    else
      echo "DIFFÉRENT — un déploiement ne suit plus le même chemin"; status=1
    fi
  else
    echo "commit $BASELINE introuvable (ou il porte déjà deploy_steps) : comparaison impossible — MODULES_BASELINE=<commit>" >&2; status=1
  fi
fi
exit "$status"
