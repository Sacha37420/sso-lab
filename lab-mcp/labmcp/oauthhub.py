"""Client d'oauth-hub : le jeton GitHub DE L'APPELANT, et rien d'autre.

Interface consommée (oauth-hub/README.md, « Contrat d'interface ») :

    GET /api/providers/github/token/    Authorization: Bearer <jeton Keycloak de l'appelant>
        200 {access_token, token_type, scope, expires_at}
        409 {detail, provider, connect_url}          compte non relié
        403                                          `azp` absent des « Apps autorisées »
    GET /api/providers/github/status/   → {configured, connected, scope, account_label, connect_url}

Le jeton Keycloak présenté est celui que l'appelant vient de présenter au
serveur MCP (`azp = lab-mcp`) : oauth-hub rend donc le jeton GitHub de CETTE
personne. Il n'existe aucun repli : pas de compte relié ⇒ erreur qui dit où le
relier. Le jeton rendu n'est ni mis en cache ni écrit : il est redemandé à
chaque opération.
"""
from __future__ import annotations

import re

import httpx

from .config import Config


class HubError(Exception):
    """`kind` : not_linked | untrusted | scope | unavailable."""

    def __init__(self, kind: str, message: str, connect_url: str = "") -> None:
        super().__init__(message)
        self.kind = kind
        self.connect_url = connect_url


def _scopes(raw: str) -> set[str]:
    return {s for s in re.split(r"[,\s]+", raw or "") if s}


def _detail(resp: httpx.Response) -> str:
    try:
        return str(resp.json().get("detail", ""))[:400]
    except Exception:
        return ""


class OAuthHub:
    def __init__(self, cfg: Config) -> None:
        self.cfg = cfg

    async def _get(self, path: str, kc_token: str) -> httpx.Response:
        try:
            async with httpx.AsyncClient(timeout=15) as client:
                return await client.get(
                    f"{self.cfg.oauth_hub_url}{path}",
                    headers={"Authorization": f"Bearer {kc_token}"},
                )
        except httpx.HTTPError as exc:
            raise HubError("unavailable", f"oauth-hub injoignable ({type(exc).__name__})") from exc

    def _refused(self, resp: httpx.Response) -> HubError:
        if resp.status_code in (401, 403):
            return HubError(
                "untrusted",
                "oauth-hub refuse la demande : " + (_detail(resp) or f"HTTP {resp.status_code}"),
            )
        return HubError("unavailable", f"oauth-hub : HTTP {resp.status_code} {_detail(resp)}")

    async def status(self, kc_token: str) -> dict:
        """État de la liaison GitHub, sans faire transiter de jeton."""
        resp = await self._get("/api/providers/github/status/", kc_token)
        if resp.status_code != 200:
            raise self._refused(resp)
        data = resp.json()
        return {
            "linked": bool(data.get("connected")),
            "account": data.get("account_label") or "",
            "scope": data.get("scope") or "",
            "connect_url": data.get("connect_url") or "",
        }

    async def github_token(self, kc_token: str, need_repo_scope: bool = True) -> str:
        resp = await self._get("/api/providers/github/token/", kc_token)
        if resp.status_code == 409:
            body = {}
            try:
                body = resp.json()
            except Exception:
                pass
            url = str(body.get("connect_url") or f"https://{self.cfg.domain}/oauth-hub/")
            raise HubError(
                "not_linked",
                "Compte GitHub non relié (ou liaison expirée). Reliez-le dans oauth-hub, puis "
                f"recommencez : {url}",
                url,
            )
        if resp.status_code != 200:
            raise self._refused(resp)
        data = resp.json()
        token = data.get("access_token")
        if not isinstance(token, str) or not token or "\n" in token or "\r" in token:
            raise HubError("unavailable", "oauth-hub a rendu une réponse sans jeton exploitable")
        if need_repo_scope and "repo" not in _scopes(str(data.get("scope") or "")):
            raise HubError(
                "scope",
                "Votre liaison GitHub n'accorde pas la portée « repo » (obtenue : "
                f"« {data.get('scope') or 'aucune'} »). Déliez puis reliez votre compte dans oauth-hub : "
                f"https://{self.cfg.domain}/oauth-hub/",
            )
        return token
