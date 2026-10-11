"""Entrée MCP — une IA (Claude Code, Mistral Vibe, autre client).

AUCUNE LOGIQUE ICI : chaque outil lit ses arguments et appelle l'opération du
moteur du même nom que la route web correspondante (`Engine.call`). Résultat et
erreur sont ceux du moteur, à l'identique de l'entrée web : le résultat est
l'objet JSON rendu par l'opération, l'erreur est le même objet
`{"error", "detail", …}` en JSON dans le texte de l'erreur d'outil.
"""
from __future__ import annotations

import json
from typing import Any, Literal

from mcp.server.fastmcp import Context, FastMCP
from mcp.server.transport_security import TransportSecuritySettings

from .auth import Caller
from .config import Config
from .engine import WS_OPS, Engine
from .errors import LabError

# Outil MCP → opération du moteur. Sert à n'ANNONCER à un jeton d'espace que ce qu'il peut appeler.
TOOL_OPS = {
    "whoami": "me", "list_apps": "projects", "check_name": "check_name", "create_app": "create_project",
    "deploy": "deploy", "job_status": "job", "status": "project", "logs": "logs",
    "env_list": "env_list", "env_get": "env_get", "env_set": "env_set", "env_unset": "env_unset", "sql": "sql",
    "run_tests": "run_tests", "open_ticket": "open_ticket", "smtp_status": "smtp_status",
}


class LabMCP(FastMCP):
    """FastMCP dont `tools/list` dépend de l'appelant : un jeton d'espace de travail ne se voit
    annoncer que les outils qu'il peut appeler (les autres lui seraient refusés de toute façon)."""

    async def list_tools(self):  # type: ignore[override]
        tools = await super().list_tools()
        try:
            request = self.get_context().request_context.request
            caller = getattr(request, "scope", {}).get("lab.caller")
        except Exception:
            caller = None
        if isinstance(caller, Caller) and caller.scope_app is not None:
            tools = [t for t in tools if TOOL_OPS.get(t.name) in WS_OPS]
        return tools


class ToolError(Exception):
    """Porte l'erreur du moteur telle quelle (JSON) jusqu'au client MCP."""


def _caller(ctx: Context) -> Caller:
    request = ctx.request_context.request
    caller = getattr(request, "scope", {}).get("lab.caller") if request is not None else None
    if not isinstance(caller, Caller):
        raise ToolError(json.dumps({"error": "unauthorized", "detail": "Identité de l'appelant introuvable."},
                                   ensure_ascii=False))
    return caller


def build(cfg: Config, engine: Engine) -> FastMCP:
    mcp = LabMCP(
        "lab-mcp",
        instructions=(
            "Exploitation des projets d'un développeur sur le lab : créer un projet (dépôt GitHub + sous-module), "
            "déployer un commit poussé sur GitHub, lire l'état et les journaux, régler les variables "
            "d'environnement, interroger sa base, lancer le test de cloisonnement, ouvrir un ticket. Un "
            "développeur n'agit que sur ses propres projets. `deploy`, `create_app` et `run_tests` sont "
            "asynchrones : ils rendent un `job_id` à suivre avec `job_status` jusqu'à `terminal: true`. Seul un "
            "commit présent sur GitHub est déployable. Une erreur est un objet JSON {error, detail}."
        ),
        stateless_http=True, json_response=True, streamable_http_path="/mcp",
        host=cfg.host, port=cfg.port,
        # Derrière Caddy, l'en-tête Host est le domaine du lab ; la protection du SDK contre le
        # « DNS rebinding » vise un serveur local sans authentification — ici chaque requête
        # porte un jeton vérifié.
        transport_security=TransportSecuritySettings(enable_dns_rebinding_protection=False),
    )

    async def call(ctx: Context, op: str, **kw: Any) -> Any:
        try:
            return await engine.call(op, _caller(ctx), **kw)
        except LabError as exc:
            raise ToolError(json.dumps(exc.body(), ensure_ascii=False)) from None

    @mcp.tool()
    async def whoami(ctx: Context) -> dict:
        """Qui suis-je sur le lab, mon compte GitHub est-il relié, que me reste-t-il à faire ?"""
        return await call(ctx, "me")

    @mcp.tool()
    async def list_apps(ctx: Context) -> dict:
        """Mes projets, avec leur état et la version déployée (tous ceux du lab pour le superutilisateur)."""
        return await call(ctx, "projects")

    @mcp.tool()
    async def check_name(name: str, ctx: Context) -> dict:
        """Vérifie qu'un nom de projet est acceptable. Rend `ok` et une raison par règle violée."""
        return await call(ctx, "check_name", name=name)

    @mcp.tool()
    async def create_app(name: str, type: Literal["django", "django-angular", "angular"],
                         required_groups: list[str], ctx: Context,
                         visibility: Literal["private", "public"] = "private") -> dict:
        """Crée un projet : dépôt GitHub sous VOTRE compte, scaffold, premier commit poussé, clé de déploiement.

        `required_groups` : groupe(s) du lab autorisés à utiliser l'app (obligatoire).
        Asynchrone → `job_id`. En cas d'échec, tout ce qui a été créé est défait.
        """
        return await call(ctx, "create_project", name=name, type=type,
                          required_groups=required_groups, visibility=visibility)

    @mcp.tool()
    async def deploy(app: str, ctx: Context, sha: str = "") -> dict:
        """Déploie un projet à partir d'un commit PRÉSENT SUR GITHUB (vide = tête de la branche par défaut).

        Asynchrone → `job_id`. Le résultat nomme le commit déployé et le résultat des tests.
        """
        return await call(ctx, "deploy", app=app, sha=sha)

    @mcp.tool()
    async def job_status(job_id: str, ctx: Context, tail: int = 200) -> dict:
        """État d'un job. À rappeler jusqu'à `terminal: true` ; `result` porte alors l'issue."""
        return await call(ctx, "job", job_id=job_id, tail=tail)

    @mcp.tool()
    async def status(app: str, ctx: Context) -> dict:
        """Détail d'un projet : état des conteneurs, version déployée, tests, écart avec GitHub, base, déploiement automatique."""
        return await call(ctx, "project", app=app)

    @mcp.tool()
    async def logs(app: str, ctx: Context, service: str = "", tail: int = 200) -> dict:
        """Journaux des conteneurs d'un projet (`tail` : 1 à 2000 lignes par conteneur)."""
        return await call(ctx, "logs", app=app, service=service, tail=tail)

    @mcp.tool()
    async def env_list(app: str, ctx: Context) -> dict:
        """Noms des variables du `.env` déployé (`managed`, `has_value`) — jamais leurs valeurs : voir `env_get`."""
        return await call(ctx, "env_list", app=app)

    @mcp.tool()
    async def env_get(app: str, key: str, ctx: Context) -> dict:
        """Valeur d'UNE variable non gérée du projet (son propriétaire seulement). `env_list` ne rend que les noms."""
        return await call(ctx, "env_get", app=app, key=key)

    @mcp.tool()
    async def env_set(app: str, key: str, value: str, ctx: Context) -> dict:
        """Règle une variable propre au projet (prise en compte au prochain déploiement)."""
        return await call(ctx, "env_set", app=app, key=key, value=value)

    @mcp.tool()
    async def env_unset(app: str, key: str, ctx: Context) -> dict:
        """Retire une variable propre au projet (prise en compte au prochain déploiement)."""
        return await call(ctx, "env_unset", app=app, key=key)

    @mcp.tool()
    async def sql(app: str, query: str, ctx: Context) -> dict:
        """Exécute UNE requête SQL dans la base du projet, avec le rôle de son propriétaire (délai et lignes plafonnés)."""
        return await call(ctx, "sql", app=app, query=query)

    @mcp.tool()
    async def run_tests(app: str, ctx: Context) -> dict:
        """Lance le test de cloisonnement (navigateur réel). Asynchrone → `job_id`.

        `found: false` dans le résultat signifie AUCUN TEST TROUVÉ — jamais « tout va bien ».
        """
        return await call(ctx, "run_tests", app=app)

    @mcp.tool()
    async def open_ticket(title: str, body: str, ctx: Context,
                          scope: Literal["app", "lab"] = "app", app: str = "") -> dict:
        """Ouvre un ticket GitHub en votre nom : dépôt du projet (`scope: "app"`) ou du lab (`scope: "lab"`)."""
        return await call(ctx, "open_ticket", title=title, body=body, scope=scope, app=app)

    @mcp.tool()
    async def smtp_status(app: str, ctx: Context) -> dict:
        """Quel profil SMTP est rattaché au projet ? Rend son identifiant et son libellé — aucun secret.

        Les profils SMTP se créent et se rattachent dans lab-admin, jamais ici. Pour envoyer un email
        depuis le backend : `send_mail(...)` de Django, sans rien régler dans le dépôt.
        """
        return await call(ctx, "smtp_status", app=app)

    return mcp
