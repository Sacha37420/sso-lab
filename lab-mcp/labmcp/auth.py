"""Authentification — qui appelle, et par quelle entrée ? (contrat I5)

Deux entrées, trois sortes de jeton :

| Entrée | Jeton accepté | Qui en sort |
|---|---|---|
| MCP `/mcp` | jeton Keycloak `azp = lab-mcp` | un dev INITIALISÉ (`.devs`), sinon refus |
| MCP `/mcp` | jeton d'espace de travail (`labws_…`) | le dev de l'espace, LIMITÉ au projet ouvert |
| web `/mcp/api/…` | jeton Keycloak `azp = lab-admin` | tout compte de lab-admin — chaque route décide ensuite |

Un jeton Keycloak passe toujours : signature par le realm `ssolab` (JWKS),
expiration, émetteur, `typ == Bearer`, puis `azp` EXACT pour l'entrée visée. Un
jeton `lab-admin` présenté à l'entrée MCP est refusé, et inversement : les deux
entrées n'ont pas la même population (l'entrée web doit laisser passer un compte
pas encore initialisé, pour `me` et `me/init`).

POURQUOI `azp` ET PAS `aud` : Keycloak ne place pas le client dans `aud` sans
mapper dédié, et le realm expose `admin-cli` en client public avec password
grant. Sans contrôle de `azp`, tout compte du realm piloterait Docker par ici.

POURQUOI `typ == Bearer` : un jeton d'IDENTITÉ porte le même `azp` et la même
signature que le jeton d'accès.

Le superutilisateur est une clé de configuration (`LAB_SUPERUSER`), jamais un
groupe. Rien ici n'est configurable : ni l'émetteur, ni les clés, ni les deux
`azp`. Il n'existe aucun mode « identité forcée ».
"""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import Callable

import jwt
from jwt import PyJWKClient

from .config import Config
from .errors import LabError
from .registry import Registry, valid_uid

WEB_CLIENT_ID = "lab-admin"
DEV_GROUP = "developers"
WS_TOKEN_PREFIX = "labws_"


@dataclass(frozen=True)
class Caller:
    username: str                 # preferred_username, tel que Keycloak le donne
    uid: str | None               # = username s'il a la forme d'I1, sinon None
    entrance: str                 # "mcp" | "web"
    is_superuser: bool = False
    in_developers: bool = False   # d'après le claim `groups` du jeton
    initialized: bool = False     # ∈ .devs
    scope_app: str | None = None  # jeton d'espace : seul projet sur lequel il agit
    email: str = ""               # claim `email` : seule adresse vers laquelle part un email d'essai SMTP
    # Jeton Keycloak de l'appelant : ne sert qu'à demander SON jeton GitHub à
    # oauth-hub. Vide pour un jeton d'espace. Jamais dans repr() ni dans un journal.
    token: str = field(default="", repr=False, compare=False)

    @property
    def eligible(self) -> bool:
        return self.uid is not None and self.in_developers

    @property
    def label(self) -> str:
        return (self.uid or self.username or "?") + (f"@ws:{self.scope_app}" if self.scope_app else "")


class Authenticator:
    def __init__(self, cfg: Config, registry: Registry,
                 ws_lookup: Callable[[str], tuple[str, str] | None]) -> None:
        self.cfg = cfg
        self.registry = registry
        self._ws_lookup = ws_lookup
        # Cache des CLÉS du realm seulement — jamais d'une décision d'accès.
        self._jwks = PyJWKClient(cfg.jwks_url, cache_keys=True, lifespan=600, timeout=10)

    def authenticate(self, authorization: str, entrance: str) -> Caller:
        if not authorization.lower().startswith("bearer "):
            raise LabError("unauthorized", "Jeton requis (en-tête Authorization: Bearer).")
        token = authorization[7:].strip()

        if token.startswith(WS_TOKEN_PREFIX):
            if entrance != "mcp":
                raise LabError("forbidden", "Un jeton d'espace de travail ne vaut que pour l'entrée MCP.")
            found = self._ws_lookup(token)
            if not found:
                raise LabError("unauthorized", "Jeton d'espace de travail inconnu ou révoqué (espace fermé ?).")
            uid, app = found
            if not self.registry.is_dev(uid):
                raise LabError("forbidden", f"Le compte '{uid}' n'est plus un développeur inscrit.")
            # Jamais superutilisateur par un jeton d'espace : il est limité à UN projet.
            return Caller(username=uid, uid=uid, entrance="mcp", in_developers=True,
                          initialized=True, scope_app=app)

        try:
            key = self._jwks.get_signing_key_from_jwt(token)
            claims = jwt.decode(
                token, key.key, algorithms=["RS256"], issuer=self.cfg.issuer,
                options={"verify_exp": True, "verify_aud": False, "require": ["exp", "iss"]},
            )
        except jwt.PyJWTError as exc:
            raise LabError("unauthorized", f"Jeton invalide : {exc}") from exc
        except Exception as exc:  # JWKS injoignable, etc.
            raise LabError("unauthorized", f"Jeton non vérifiable : {type(exc).__name__}") from exc

        if claims.get("typ") != "Bearer":
            raise LabError("unauthorized", "Jeton invalide : un jeton d'accès est attendu.")
        expected = self.cfg.client_id if entrance == "mcp" else WEB_CLIENT_ID
        azp = claims.get("azp")
        if azp != expected:
            raise LabError("forbidden",
                           f"Jeton émis pour le client '{azp}' : cette entrée n'accepte que '{expected}'.")

        username = str(claims.get("preferred_username") or "")
        uid = username if valid_uid(username) else None
        groups = claims.get("groups") or []
        caller = Caller(
            username=username, uid=uid, entrance=entrance,
            is_superuser=bool(uid) and self.registry.is_superuser(uid),
            in_developers=isinstance(groups, list) and DEV_GROUP in groups,
            initialized=bool(uid) and self.registry.is_dev(uid),
            email=str(claims.get("email") or ""),
            token=token,
        )
        if entrance == "mcp" and not caller.initialized:
            # L'entrée MCP n'initialise personne : cela se fait à la première
            # connexion à lab-admin (POST /mcp/api/me/init).
            raise LabError(
                "forbidden",
                f"Le compte '{username}' n'est pas un développeur inscrit du lab "
                "(l'inscription se fait à la première connexion à lab-admin).",
            )
        return caller
