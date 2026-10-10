#!/usr/bin/env bash
# Lancé DANS le terminal intégré de l'éditeur par tests/navigateur.js : prouve que les outils et
# les variables de l'espace y sont disponibles. N'écrit jamais la valeur d'un jeton.
out=/tmp/preuve-terminal.out
{
  echo "pwd=$PWD"
  echo "LAB_APP=${LAB_APP:-}"
  echo "LAB_UID=${LAB_UID:-}"
  echo "jeton_mcp=$([ -n "${LAB_MCP_TOKEN:-}" ] && echo present || echo absent)"
  echo "claude=$(claude --version 2>&1 | head -1)"
  echo "vibe=$(vibe --version 2>&1 | head -1)"
  d="$(mktemp -d)"; cd "$d" && git init -q . && git commit -q --allow-empty -m preuve \
    && echo "auteur=$(git log -1 --format='%an <%ae>')"
  echo "fin"
} > "$out.tmp" 2>&1
mv "$out.tmp" "$out"
