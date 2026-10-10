"""Assemblage : un moteur, deux entrées, une authentification devant les deux.

    /mcp             entrée MCP   (mcp_entry.py)   jeton Keycloak azp=lab-mcp, ou jeton d'espace de travail
    /mcp/api/…       entrée web   (web.py)         jeton Keycloak azp=lab-admin

`AuthMiddleware` (ASGI pur) établit l'appelant AVANT que la requête n'atteigne
le SDK MCP ou une route ; les deux entrées le relisent dans la requête.
"""
from __future__ import annotations

from typing import Any

import anyio
from starlette.responses import JSONResponse
from starlette.routing import Route

from . import mcp_entry, web
from .config import Config
from .engine import Engine, audit
from .errors import LabError

SCOPES = ["openid", "profile", "email"]


class AuthMiddleware:
    def __init__(self, app: Any, engine: Engine, cfg: Config) -> None:
        self.app = app
        self.engine = engine
        self.cfg = cfg

    async def __call__(self, scope: dict, receive: Any, send: Any) -> None:
        if scope["type"] != "http" or web.is_open_path(scope["path"]):
            await self.app(scope, receive, send)
            return
        entrance = "web" if scope["path"].startswith("/mcp/api/") else "mcp"
        authorization = ""
        for key, value in scope.get("headers", []):
            if key == b"authorization":
                authorization = value.decode("latin-1")
        try:
            # La première vérification va chercher les clés du realm (HTTP bloquant).
            caller = await anyio.to_thread.run_sync(self.engine.authn.authenticate, authorization, entrance)
        except LabError as exc:
            headers = {}
            if exc.status == 401 and entrance == "mcp":
                # RFC 9728 : où trouver les métadonnées de la ressource, donc Keycloak.
                headers["WWW-Authenticate"] = (
                    'Bearer realm="lab-mcp", '
                    f'resource_metadata="{self.cfg.public_url}/.well-known/oauth-protected-resource", '
                    f'scope="{" ".join(SCOPES)}"')
            if authorization:
                audit("?", "(authentification)", "", "refused", exc.detail, entrance)
            await JSONResponse(exc.body(), status_code=exc.status, headers=headers)(scope, receive, send)
            return
        scope["lab.caller"] = caller
        await self.app(scope, receive, send)


def build(cfg: Config) -> Any:
    engine = Engine(cfg)
    mcp = mcp_entry.build(cfg, engine)

    async def resource_metadata(_request: Any) -> JSONResponse:
        # Le client `lab-mcp` est PRÉ-ENREGISTRÉ : aucun enregistrement dynamique n'est offert.
        return JSONResponse({
            "resource": cfg.public_url, "authorization_servers": [cfg.issuer],
            "scopes_supported": SCOPES, "bearer_methods_supported": ["header"], "resource_name": "lab-mcp",
        })

    app = mcp.streamable_http_app()
    app.router.routes.extend(web.routes(engine) + [
        Route("/mcp/.well-known/oauth-protected-resource", resource_metadata, methods=["GET"]),
        Route("/.well-known/oauth-protected-resource/mcp", resource_metadata, methods=["GET"]),
        Route("/.well-known/oauth-protected-resource", resource_metadata, methods=["GET"]),
    ])
    wrapped = AuthMiddleware(app, engine, cfg)
    wrapped.engine = engine  # pour les tests
    return wrapped
