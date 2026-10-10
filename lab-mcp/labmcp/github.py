"""Appels à l'API GitHub, TOUJOURS avec le jeton de l'appelant.

Jamais le `gh` de l'hôte (il porte `delete_repo` sur tous les dépôts du
superutilisateur), jamais un jeton de service, jamais le jeton d'un autre :
chaque fonction reçoit le jeton en argument et ne le conserve pas.

Aucun message d'erreur produit ici ne contient le jeton : seuls le code HTTP et
le champ `message` de la réponse GitHub sont repris.
"""
from __future__ import annotations

import re

import httpx

# Nom de dépôt = nom d'app (I1) ; login GitHub : alphanumérique et tirets.
LOGIN_RE = re.compile(r"^[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})$")
REPO_RE = re.compile(r"^[A-Za-z0-9._-]{1,100}$")
GITHUB_URL_RE = re.compile(r"^https://github\.com/([A-Za-z0-9-]{1,39})/([A-Za-z0-9._-]{1,100}?)(?:\.git)?/?$")


class GithubError(Exception):
    def __init__(self, message: str, status: int = 0) -> None:
        super().__init__(message)
        self.status = status


def parse_repo_url(url: str) -> tuple[str, str]:
    m = GITHUB_URL_RE.fullmatch(url or "")
    if not m:
        raise GithubError("l'origine de cette app n'est pas un dépôt GitHub (https://github.com/<compte>/<dépôt>)")
    return m.group(1), m.group(2)


class Github:
    def __init__(self, api: str, token: str, timeout: float = 20) -> None:
        self._client = httpx.Client(
            base_url=api,
            timeout=timeout,
            headers={
                "Authorization": f"Bearer {token}",
                "Accept": "application/vnd.github+json",
                "X-GitHub-Api-Version": "2022-11-28",
                "User-Agent": "lab-mcp",
            },
        )

    def close(self) -> None:
        self._client.close()

    def __enter__(self) -> "Github":
        return self

    def __exit__(self, *exc: object) -> None:
        self.close()

    def _call(self, method: str, path: str, **kw: object) -> httpx.Response:
        try:
            return self._client.request(method, path, **kw)  # type: ignore[arg-type]
        except httpx.HTTPError as exc:
            raise GithubError(f"GitHub injoignable ({type(exc).__name__})") from exc

    @staticmethod
    def _msg(resp: httpx.Response) -> str:
        try:
            data = resp.json()
            msg = str(data.get("message", ""))
            errs = data.get("errors")
            if isinstance(errs, list) and errs:
                msg += " — " + "; ".join(str(e.get("message", e)) if isinstance(e, dict) else str(e) for e in errs[:3])
            return msg[:300]
        except Exception:
            return ""

    def user(self) -> dict:
        """Compte GitHub du porteur du jeton : {login, id, name}."""
        r = self._call("GET", "/user")
        if r.status_code == 401:
            raise GithubError("GitHub refuse le jeton (révoqué ?) — reliez à nouveau votre compte dans oauth-hub", 401)
        if r.status_code != 200:
            raise GithubError(f"GET /user : HTTP {r.status_code} {self._msg(r)}", r.status_code)
        data = r.json()
        login = str(data.get("login", ""))
        if not LOGIN_RE.fullmatch(login):
            raise GithubError("login GitHub inattendu dans la réponse de /user")
        return {"login": login, "id": data.get("id"), "name": data.get("name") or login}

    def repo_exists(self, owner: str, repo: str) -> bool:
        r = self._call("GET", f"/repos/{owner}/{repo}")
        if r.status_code == 200:
            return True
        if r.status_code == 404:
            return False
        raise GithubError(f"GET /repos/{owner}/{repo} : HTTP {r.status_code} {self._msg(r)}", r.status_code)

    def create_repo(self, name: str, private: bool) -> dict:
        """Crée un dépôt VIDE sous le compte du porteur du jeton."""
        r = self._call("POST", "/user/repos", json={
            "name": name, "private": private, "auto_init": False,
            "description": "Application du lab — créée par lab-mcp",
        })
        if r.status_code != 201:
            hint = ""
            if r.status_code in (403, 404):
                hint = " (le jeton n'a sans doute pas la portée « repo » : reliez à nouveau votre compte dans oauth-hub)"
            raise GithubError(f"création du dépôt refusée : HTTP {r.status_code} {self._msg(r)}{hint}", r.status_code)
        return r.json()

    def delete_repo(self, owner: str, repo: str) -> None:
        r = self._call("DELETE", f"/repos/{owner}/{repo}")
        if r.status_code not in (204, 404):
            raise GithubError(f"HTTP {r.status_code} {self._msg(r)}", r.status_code)

    def create_issue(self, owner: str, repo: str, title: str, body: str) -> dict:
        r = self._call("POST", f"/repos/{owner}/{repo}/issues", json={"title": title, "body": body})
        if r.status_code != 201:
            hint = ""
            if r.status_code in (403, 404):
                hint = " (dépôt introuvable avec votre compte, tickets désactivés, ou portée insuffisante)"
            elif r.status_code == 410:
                hint = " (les tickets sont désactivés sur ce dépôt)"
            raise GithubError(f"création du ticket refusée : HTTP {r.status_code} {self._msg(r)}{hint}", r.status_code)
        data = r.json()
        return {"number": data.get("number"), "url": data.get("html_url")}


# ── v5 : clé de déploiement, webhook, commits ────────────────────────────────
def _more(cls):  # petites méthodes ajoutées à Github sans alourdir la classe ci-dessus
    def add_deploy_key(self, owner: str, repo: str, public_key: str) -> int:
        """Dépose une clé de déploiement EN LECTURE SEULE sur le dépôt."""
        r = self._call("POST", f"/repos/{owner}/{repo}/keys",
                       json={"title": "lab — déploiement (lecture seule)", "key": public_key, "read_only": True})
        if r.status_code != 201:
            raise GithubError(f"dépôt de la clé de déploiement refusé : HTTP {r.status_code} {self._msg(r)}",
                              r.status_code)
        return int(r.json().get("id") or 0)

    def create_hook(self, owner: str, repo: str, url: str, secret: str) -> int:
        r = self._call("POST", f"/repos/{owner}/{repo}/hooks", json={
            "name": "web", "active": True, "events": ["push"],
            "config": {"url": url, "content_type": "json", "secret": secret, "insecure_ssl": "0"},
        })
        if r.status_code != 201:
            raise GithubError(f"création du webhook refusée : HTTP {r.status_code} {self._msg(r)}", r.status_code)
        return int(r.json().get("id") or 0)

    def default_branch(self, owner: str, repo: str) -> str:
        r = self._call("GET", f"/repos/{owner}/{repo}")
        if r.status_code != 200:
            raise GithubError(f"dépôt {owner}/{repo} illisible avec votre compte : HTTP {r.status_code} "
                              f"{self._msg(r)}", r.status_code)
        return str(r.json().get("default_branch") or "main")

    def commits(self, owner: str, repo: str, branch: str, count: int = 20) -> list[dict]:
        r = self._call("GET", f"/repos/{owner}/{repo}/commits", params={"sha": branch, "per_page": count})
        if r.status_code == 409:      # dépôt vide
            return []
        if r.status_code != 200:
            raise GithubError(f"commits de {owner}/{repo} illisibles : HTTP {r.status_code} {self._msg(r)}",
                              r.status_code)
        out = []
        for c in r.json()[:count]:
            commit = c.get("commit") or {}
            author = commit.get("author") or {}
            out.append({"sha": c.get("sha"),
                        "message": str(commit.get("message") or "").split("\n", 1)[0][:200],
                        "author": author.get("name") or "", "date": author.get("date") or ""})
        return out

    for fn in (add_deploy_key, create_hook, default_branch, commits):
        setattr(cls, fn.__name__, fn)


_more(Github)
