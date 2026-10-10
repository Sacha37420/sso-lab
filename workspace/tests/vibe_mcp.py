"""Preuve côté Mistral Vibe, lancée avec l'interpréteur DE Vibe (verify.sh) :
lit ~/.vibe/config.toml, fait analyser l'entrée « lab » par le code de Vibe, lui fait calculer
ses en-têtes (c'est là que LAB_MCP_TOKEN est lu dans l'environnement) puis liste les outils du
serveur avec le client MCP de Vibe. Vibe n'a pas de commande `mcp list` hors session.

Affiche : `url=<url> entetes=<noms> outils=<noms>` ; code ≠ 0 si le serveur refuse.
"""
import asyncio
import pathlib
import sys
import tomllib

from vibe.core.config.mcp_servers import _parse_raw_mcp_server
from vibe.core.tools.mcp.tools import list_tools_http

brut = tomllib.loads((pathlib.Path.home() / ".vibe" / "config.toml").read_text())
serveur = next(_parse_raw_mcp_server(s) for s in brut.get("mcp_servers", []) if s.get("name") == "lab")
entetes = serveur.http_headers()
try:
    outils = asyncio.run(list_tools_http(serveur.url, headers=entetes, startup_timeout_sec=15))
except BaseException as exc:  # ExceptionGroup compris
    print(f"url={serveur.url} entetes={sorted(entetes)} ECHEC={type(exc).__name__}")
    sys.exit(1)
print(f"url={serveur.url} entetes={sorted(entetes)} outils={[o.name for o in outils]}")
