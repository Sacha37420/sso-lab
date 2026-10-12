"""Entrée web — l'interface lab-admin, donc un humain sans IA.

AUCUNE LOGIQUE ICI : chaque route lit ses arguments (chemin, requête, corps JSON)
et appelle l'opération du moteur (`Engine.call`), la même que l'outil MCP
correspondant. Formes des réponses et des erreurs : API.md.

Trois routes n'ont pas d'appelant Keycloak et ne passent donc pas par
`Engine.call` : le webhook GitHub (signature HMAC du projet), le contrôle
d'accès des espaces (cookie de session, appelé par la passerelle), la santé.
"""
from __future__ import annotations

import json
from typing import Any

from starlette.requests import Request
from starlette.responses import JSONResponse, Response
from starlette.routing import Route

from .auth import Caller
from .engine import Engine
from .errors import LabError

MAX_BODY = 256 * 1024


def error_response(exc: LabError) -> JSONResponse:
    return JSONResponse(exc.body(), status_code=exc.status)


def routes(engine: Engine) -> list[Route]:
    async def body(request: Request) -> dict:
        raw = await request.body()
        if len(raw) > MAX_BODY:
            raise LabError("invalid", "Corps de requête trop volumineux.")
        if not raw:
            return {}
        try:
            data = json.loads(raw)
        except ValueError:
            raise LabError("invalid", "Corps JSON illisible.") from None
        if not isinstance(data, dict):
            raise LabError("invalid", "Un objet JSON est attendu.")
        return data

    def need(data: dict, *keys: str) -> list[Any]:
        missing = [k for k in keys if k not in data]
        if missing:
            raise LabError("invalid", "Champ(s) manquant(s).", reasons=[f"champ manquant : {k}" for k in missing])
        return [data[k] for k in keys]

    def endpoint(fn):
        async def handler(request: Request) -> Response:
            caller = request.scope.get("lab.caller")
            try:
                if not isinstance(caller, Caller):
                    raise LabError("unauthorized", "Jeton requis.")
                return JSONResponse(await fn(request, caller))
            except LabError as exc:
                return error_response(exc)
        return handler

    P = "/mcp/api"
    call = engine.call
    q = lambda r, k, d=None: r.query_params.get(k, d)  # noqa: E731
    app = lambda r: r.path_params["app"]               # noqa: E731

    async def me(r, c): return await call("me", c, as_uid=q(r, "as"))
    async def me_init(r, c): return await call("me_init", c)
    async def smtp_list(r, c): return await call("smtp_list", c, as_uid=q(r, "as"))
    async def smtp_update(r, c): return await call("smtp_update", c, profile_id=r.path_params["pid"], data=await body(r))
    async def smtp_delete(r, c): return await call("smtp_delete", c, profile_id=r.path_params["pid"])
    async def smtp_test(r, c): return await call("smtp_test", c, profile_id=r.path_params["pid"])

    async def project_smtp(r, c):
        d = await body(r)
        (profile,) = need(d, "profile")
        return await call("project_smtp", c, app=app(r), profile=profile, apply=d.get("apply", "next_deploy"))

    async def smtp_create(request: Request) -> Response:
        """Seule route qui rend 201 (I10)."""
        caller = request.scope.get("lab.caller")
        try:
            if not isinstance(caller, Caller):
                raise LabError("unauthorized", "Jeton requis.")
            return JSONResponse(await call("smtp_create", caller, data=await body(request)), status_code=201)
        except LabError as exc:
            return error_response(exc)

    async def pg_open(r, c): return await call("pgadmin_open", c)
    async def pg_close(r, c): return await call("pgadmin_close", c)
    async def groups(r, c): return await call("groups", c)
    async def devs(r, c): return await call("devs", c)
    flag = lambda r, k: q(r, k, "") in ("1", "true")   # noqa: E731
    async def projects(r, c): return await call("projects", c, as_uid=q(r, "as"), refresh=flag(r, "refresh"))

    async def create(r, c):
        d = await body(r)
        name, typ, groups_ = need(d, "name", "type", "required_groups")
        return await call("create_project", c, name=name, type=typ, required_groups=groups_,
                          visibility=d.get("visibility", "private"))

    async def check_name(r, c):
        (name,) = need(await body(r), "name")
        return await call("check_name", c, name=name)

    async def project(r, c): return await call("project", c, app=app(r), refresh=flag(r, "refresh"))
    async def deploy(r, c): return await call("deploy", c, app=app(r), sha=(await body(r)).get("sha") or "")
    async def commits(r, c): return await call("commits", c, app=app(r))
    async def logs(r, c): return await call("logs", c, app=app(r), service=q(r, "service", ""), tail=q(r, "tail", 200))
    async def env_list(r, c): return await call("env_list", c, app=app(r))

    async def env_set(r, c):
        (value,) = need(await body(r), "value")
        return await call("env_set", c, app=app(r), key=r.path_params["key"], value=value)

    async def env_unset(r, c): return await call("env_unset", c, app=app(r), key=r.path_params["key"])
    async def run_all(r, c): return await call("run_all_tests", c)

    async def env_get(request: Request) -> Response:
        """Valeur d'une variable : comme le mot de passe de la base, jamais mise en cache."""
        caller = request.scope.get("lab.caller")
        headers = {"Cache-Control": "no-store", "Pragma": "no-cache"}
        try:
            if not isinstance(caller, Caller):
                raise LabError("unauthorized", "Jeton requis.")
            return JSONResponse(await call("env_get", caller, app=request.path_params["app"],
                                           key=request.path_params["key"]), headers=headers)
        except LabError as exc:
            return JSONResponse(exc.body(), status_code=exc.status, headers=headers)

    async def sql(r, c):
        (query,) = need(await body(r), "query")
        return await call("sql", c, app=app(r), query=query)

    async def tests(r, c): return await call("run_tests", c, app=app(r))

    async def tickets(r, c):
        d = await body(r)
        title, text = need(d, "title", "body")
        return await call("open_ticket", c, title=title, body=text, scope=d.get("scope", "app"), app=app(r))

    async def auto_deploy(r, c):
        (enabled,) = need(await body(r), "enabled")
        return await call("auto_deploy", c, app=app(r), enabled=enabled)

    async def ws_open(r, c): return await call("workspace_open", c, app=app(r), target=(await body(r)).get("target"))
    async def ws_close(r, c): return await call("workspace_close", c, app=app(r))
    async def job(r, c): return await call("job", c, job_id=r.path_params["job_id"], tail=q(r, "tail", 200))

    async def db_password(request: Request) -> Response:
        """Le seul secret que l'API rende : jamais mis en cache, ni par le navigateur ni par un relais."""
        caller = request.scope.get("lab.caller")
        headers = {"Cache-Control": "no-store", "Pragma": "no-cache"}
        try:
            if not isinstance(caller, Caller):
                raise LabError("unauthorized", "Jeton requis.")
            if request.query_params.get("as"):
                raise LabError("forbidden", "Le mot de passe d'une base ne se lit que par son propriétaire.")
            return JSONResponse(await call("database_password", caller), headers=headers)
        except LabError as exc:
            return JSONResponse(exc.body(), status_code=exc.status, headers=headers)

    # ── sans appelant Keycloak ──────────────────────────────────────────────
    async def hook(request: Request) -> Response:
        raw = await request.body()
        if len(raw) > 5 * 1024 * 1024:
            return error_response(LabError("invalid", "Corps trop volumineux."))
        try:
            return JSONResponse(await engine.hook(
                request.path_params["app"], request.headers.get("x-github-event", ""),
                request.headers.get("x-hub-signature-256", ""), raw))
        except LabError as exc:
            return error_response(exc)

    async def ws_auth(request: Request) -> Response:
        """Appelé par la passerelle des espaces, pour CHAQUE requête (WebSocket compris).
        200 = laisser passer ; 302 = ticket échangé contre un cookie ; 401 = refus."""
        decision, info = engine.ws_authorize(
            request.headers.get("x-lab-ws-kind", "ws"),
            request.headers.get("x-lab-ws-uid", ""), request.headers.get("x-forwarded-uri", ""),
            request.headers.get("cookie", ""))
        if decision == "ok":
            return Response(status_code=200)
        if decision == "redirect":
            return Response(status_code=302, headers={"Location": info["location"], "Set-Cookie": info["set_cookie"],
                                                      "Cache-Control": "no-store"})
        return JSONResponse({"error": "unauthorized",
                             "detail": "Service fermé ou session expirée — rouvrez-le depuis lab-admin.",
                             "reason": info.get("reason")}, status_code=401, headers={"Cache-Control": "no-store"})

    async def healthz(_request: Request) -> Response:
        return JSONResponse({"ok": True})

    R = lambda path, fn, method: Route(P + path, endpoint(fn), methods=[method])  # noqa: E731
    return [
        R("/me", me, "GET"), R("/me/init", me_init, "POST"),
        Route(P + "/me/database-password", db_password, methods=["GET"]),
        R("/me/pgadmin", pg_open, "POST"), R("/me/pgadmin", pg_close, "DELETE"),
        R("/me/smtp", smtp_list, "GET"), Route(P + "/me/smtp", smtp_create, methods=["POST"]),
        R("/me/smtp/{pid}", smtp_update, "PUT"), R("/me/smtp/{pid}", smtp_delete, "DELETE"),
        R("/me/smtp/{pid}/test", smtp_test, "POST"),
        R("/projects/{app}/smtp", project_smtp, "PUT"),
        R("/groups", groups, "GET"), R("/devs", devs, "GET"),
        R("/projects", projects, "GET"), R("/projects", create, "POST"),
        R("/projects/check-name", check_name, "POST"),
        R("/projects/{app}", project, "GET"),
        R("/projects/{app}/deploy", deploy, "POST"),
        R("/projects/{app}/commits", commits, "GET"),
        R("/projects/{app}/logs", logs, "GET"),
        R("/projects/{app}/env", env_list, "GET"),
        Route(P + "/projects/{app}/env/{key}", env_get, methods=["GET"]),
        R("/projects/{app}/env/{key}", env_set, "PUT"), R("/projects/{app}/env/{key}", env_unset, "DELETE"),
        R("/tests/run-all", run_all, "POST"),
        R("/projects/{app}/sql", sql, "POST"),
        R("/projects/{app}/tests", tests, "POST"),
        R("/projects/{app}/tickets", tickets, "POST"),
        R("/projects/{app}/auto-deploy", auto_deploy, "PUT"),
        R("/projects/{app}/workspace", ws_open, "POST"), R("/projects/{app}/workspace", ws_close, "DELETE"),
        R("/jobs/{job_id}", job, "GET"),
        Route(P + "/hooks/github/{app}", hook, methods=["POST"]),
        Route(P + "/ws-auth", ws_auth, methods=["GET"]),
        Route("/mcp/healthz", healthz, methods=["GET"]),
    ]


# Chemins servis sans jeton Keycloak (chacun a son propre contrôle, ou n'en demande pas).
def is_open_path(path: str) -> bool:
    return (path in ("/mcp/healthz", "/mcp/api/ws-auth", "/mcp/.well-known/oauth-protected-resource",
                     "/.well-known/oauth-protected-resource", "/.well-known/oauth-protected-resource/mcp")
            or path.startswith("/mcp/api/hooks/github/"))
