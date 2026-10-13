#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# tests/seed/run.sh — graine de création d'un projet (chantier « app-builder-lab », I2).
#
#   bash lab-mcp/tests/seed/run.sh             tous les essais, puis la comparaison avant/après
#   bash lab-mcp/tests/seed/run.sh tests       tests/test_seed.py seul (≈ 20 s)
#   bash lab-mcp/tests/seed/run.sh compare     une création SANS graine, jouée avec le moteur d'avant
#                                              (commit SEED_BASELINE) et le moteur courant : mêmes
#                                              étapes, même journal, mêmes scripts, même premier commit
#
# NE TOUCHE À RIEN DU LAB : ni `lab-mcp` en service, ni un projet, ni `.owners`/`.ports`/`.devs`, ni
# GitHub, ni une base. Ne construit aucune image : le moteur d'essai est l'image du moteur déjà
# présente (LAB_MCP_IMAGE, défaut « lab-mcp-lab-mcp:latest ») avec labmcp/ et tests/ du DOSSIER DE
# TRAVAIL montés par-dessus, en lecture seule. Conteneurs jetables `zz-seed-mcp-*`, `--network none`,
# sans socket Docker, sans port publié, sans label `caddy`. Du dépôt, seuls `scripts/` et
# `_templates/regles/` sont montés, en lecture seule : la racine du lab vue par le moteur d'essai est
# un dossier factice créé DANS le conteneur.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MCP="$(cd "$HERE/../.." && pwd)"
DEV="$(cd "$MCP/.." && pwd)"
ENGINE_IMAGE="${LAB_MCP_IMAGE:-lab-mcp-lab-mcp:latest}"
BASELINE="${SEED_BASELINE:-6c94887}"      # dernier commit du moteur SANS graine
P="zz-seed-mcp"
WHAT="${1:-all}"

docker image inspect "$ENGINE_IMAGE" > /dev/null 2>&1 || { echo "image absente : $ENGINE_IMAGE (cet essai n'en construit aucune)" >&2; exit 2; }
WORK="$(mktemp -d)"
cleanup() { docker rm -f "$P-tests" "$P-avant" "$P-apres" > /dev/null 2>&1; rm -rf "$WORK"; }
trap cleanup EXIT
status=0

engine() {  # engine <nom> <dossier labmcp> <arguments de test_seed.py…>
  local name="$1" code="$2"; shift 2
  docker run --rm --name "$name" --network none --cap-drop ALL --security-opt no-new-privileges \
    --user "$(id -u):$(id -g)" -e HOME=/tmp \
    -v "$code:/app/labmcp:ro" -v "$MCP/tests:/tests:ro" \
    -v "$DEV/scripts:/lab-scripts:ro" -v "$DEV/_templates/regles:/lab-regles:ro" \
    -v "$WORK:/out" "$ENGINE_IMAGE" python -u /tests/test_seed.py "$@"
}

if [[ "$WHAT" == all || "$WHAT" == tests ]]; then
  echo "════ Graine de création — tests/test_seed.py ════"
  engine "$P-tests" "$MCP/labmcp" || status=1
fi

if [[ "$WHAT" == all || "$WHAT" == compare ]]; then
  echo "════ Création SANS graine : moteur du commit $BASELINE contre moteur courant ════"
  mkdir -p "$WORK/avant"
  if git -C "$DEV" archive "$BASELINE" lab-mcp/labmcp 2> /dev/null | tar -x -C "$WORK/avant" \
     && [[ -f "$WORK/avant/lab-mcp/labmcp/chain.py" && ! -f "$WORK/avant/lab-mcp/labmcp/seed.py" ]]; then
    engine "$P-avant" "$WORK/avant/lab-mcp/labmcp" --trace /out/avant.json || status=1
    engine "$P-apres" "$MCP/labmcp" --trace /out/apres.json || status=1
    if [[ -s "$WORK/avant.json" ]] && diff -u "$WORK/avant.json" "$WORK/apres.json"; then
      echo "IDENTIQUE — $(wc -l < "$WORK/apres.json") lignes de trace (réponse, étapes, journal, résultat, arguments de la chaîne, scripts lancés, requêtes GitHub, premier commit, feuille de route)"
    else
      echo "DIFFÉRENT — une création sans graine ne suit plus le même chemin"; status=1
    fi
  else
    echo "commit $BASELINE introuvable (ou il porte déjà seed.py) : comparaison impossible" >&2; status=1
  fi
fi
exit "$status"
