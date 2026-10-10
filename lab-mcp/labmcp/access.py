"""Tickets et sessions des services par personne derrière la passerelle (I3, I9).

Deux sortes de service : « ws » (espace de travail, `/ws/<uid>/`) et « pg »
(pgAdmin, `/pg/<uid>/`). Même mécanique pour les deux :

  • lab-admin obtient du moteur un TICKET — usage unique, 60 s — dans l'URL ;
  • la première requête l'échange contre un COOKIE lié à (personne, sorte,
    service visé) et limité au chemin du service ;
  • la passerelle redemande `authorize()` à CHAQUE requête, WebSocket compris.

Un ticket ou un cookie d'une sorte ne vaut rien pour l'autre, ni pour le service
d'un autre. Seuls des condensats (SHA-256) sont gardés, en mémoire.
"""
from __future__ import annotations

import hashlib
import secrets
import time
from typing import Callable
from urllib.parse import parse_qsl, urlencode, urlsplit

TICKET_TTL = 60
SESSION_TTL = 12 * 3600
ENGINE = "(moteur)"       # session interne : sonde de santé, ne compte jamais comme une activité
KINDS = ("ws", "pg")


def digest(value: str) -> str:
    return hashlib.sha256(value.encode()).hexdigest()


class Access:
    def __init__(self, secure_cookies: bool) -> None:
        self.secure = secure_cookies
        self._tickets: dict[str, tuple[str, str, str, float]] = {}   # condensat → (personne, sorte, visé, échéance)
        self._sessions: dict[str, tuple[str, str, str, float]] = {}

    @staticmethod
    def cookie_name(kind: str, uid: str) -> str:
        return f"lab_{kind}_{uid}"

    @staticmethod
    def path(kind: str, uid: str) -> str:
        return f"/{kind}/{uid}/"

    def ticket(self, kind: str, viewer: str, target: str) -> str:
        value = secrets.token_urlsafe(32)
        self._tickets[digest(value)] = (viewer, kind, target, time.time() + TICKET_TTL)
        return value

    def engine_session(self, kind: str, target: str) -> str:
        value = secrets.token_urlsafe(32)
        self._sessions[digest(value)] = (ENGINE, kind, target, time.time() + 10 * 365 * 86400)
        return value

    def drop(self, kind: str, target: str) -> None:
        for store in (self._tickets, self._sessions):
            for key in [k for k, v in store.items() if v[1] == kind and v[2] == target]:
                store.pop(key, None)

    def purge(self) -> None:
        now = time.time()
        for store in (self._tickets, self._sessions):
            for key in [k for k, v in store.items() if v[3] < now]:
                store.pop(key, None)

    def authorize(self, kind: str, target: str, forwarded_uri: str, cookie_header: str,
                  allowed: Callable[[str, str], bool], touch: Callable[[], None]) -> tuple[str, dict]:
        """Décision pour UNE requête : ("ok", {}), ("redirect", {location, set_cookie}) ou ("deny", {reason}).

        `allowed(personne, visé)` redit à chaque requête si cette personne a encore le droit
        d'entrer ; `touch()` note une activité du dev.
        """
        now = time.time()
        parts = urlsplit(forwarded_uri or "")
        query = parse_qsl(parts.query, keep_blank_values=True)
        ticket = next((v for k, v in query if k == "ticket"), "")
        if ticket:
            entry = self._tickets.pop(digest(ticket), None)       # usage unique : retiré avant tout contrôle
            if entry and entry[1] == kind and entry[2] == target and entry[3] >= now and allowed(entry[0], target):
                cookie = secrets.token_urlsafe(32)
                self._sessions[digest(cookie)] = (entry[0], kind, target, now + SESSION_TTL)
                touch()
                rest = urlencode([(k, v) for k, v in query if k != "ticket"])
                path = self.path(kind, target)
                return "redirect", {
                    "location": path + (f"?{rest}" if rest else ""),
                    "set_cookie": (f"{self.cookie_name(kind, target)}={cookie}; Path={path}; HttpOnly; "
                                   f"SameSite=Lax; Max-Age={SESSION_TTL}" + ("; Secure" if self.secure else "")),
                }
            return "deny", {"reason": "ticket invalide, expiré ou déjà utilisé"}

        name = self.cookie_name(kind, target) + "="
        for piece in (cookie_header or "").split(";"):
            piece = piece.strip()
            if piece.startswith(name):
                entry = self._sessions.get(digest(piece[len(name):]))
                if entry and entry[1] == kind and entry[2] == target and entry[3] >= now and (
                        entry[0] == ENGINE or allowed(entry[0], target)):
                    if entry[0] != ENGINE:
                        touch()
                    return "ok", {}
        return "deny", {"reason": "session absente ou expirée"}
