"""Point d'entrée : `python -m labmcp`."""
from __future__ import annotations

import asyncio
import logging
import sys

import uvicorn

from . import config
from .server import build


def main() -> None:
    logging.basicConfig(level=logging.INFO, stream=sys.stdout, format="%(message)s")
    # httpx journalise chaque URL appelée : inutile et bavard (jamais de jeton
    # dans une URL ici, mais autant ne rien écrire qui n'est pas voulu).
    logging.getLogger("httpx").setLevel(logging.WARNING)
    cfg = config.load()
    log = logging.getLogger("lab-mcp")
    log.info("lab-mcp — dépôt %s — ressource %s — émetteur %s", cfg.root, cfg.public_url, cfg.issuer)
    if cfg.allow_file_origin:
        log.warning(
            "⚠ LAB_GIT_ALLOW_FILE=1 : origines git en file:// acceptées — MODE TEST, "
            "jamais en service (docker-compose.yml ne le définit pas)."
        )
    app = build(cfg)
    # Avant d'écouter : pare-feu des ponts d'espace, espaces et pgAdmin orphelins fermés.
    asyncio.run(app.engine.startup())
    uvicorn.run(app, host=cfg.host, port=cfg.port, log_level="warning", access_log=False)


if __name__ == "__main__":
    main()
