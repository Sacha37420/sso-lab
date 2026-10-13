"""Adresse d'essai d'un développeur — ce que le moteur LIT de `scripts/app-preview.sh`
(chantier « essai-dev », contrat v1 : il consomme I1, il produit I2).

LE MOTEUR N'A AUCUNE LOGIQUE D'ESSAI : ni réécriture, ni base, ni Keycloak, ni Docker. Tout cela
est dans le script. Ce module ne fait que deux choses :

  • lire la DERNIÈRE ligne de sa sortie, `RESULTAT=<objet JSON sur une ligne>`, et refuser tout ce
    qui n'a pas la forme écrite au contrat ou ne parle pas du développeur et du projet demandés ;
  • calculer le terme (`expires_at` = `built_at` + LAB_PREVIEW_TTL_H heures).

Rien de ce que rend le script ne décide d'un DROIT : qui peut agir sur quel projet est décidé
avant, par le registre (`Engine._app`). Ce qui est lu ici ne sert qu'à afficher, et à démonter.

Une sortie absente, illisible ou incohérente lève `Incoherent` : l'appelant en fait un échec net
(job `failed`, ou erreur `failed`) — jamais un succès, jamais un état inventé.
"""
from __future__ import annotations

import datetime
import json
import re
from typing import Any

from .registry import valid_app

PREFIX = "RESULTAT="
STATES = ("absent", "running", "degraded", "stopped")
SERVICE_STATES = ("running", "starting", "exited", "unhealthy")
STEP_RE = re.compile(r"^[a-z][a-z0-9_]{0,31}$")
_SERVICE_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,62}$")
_GROUP_RE = re.compile(r"^[A-Za-z0-9_-]{1,64}$")
CLOCK_SLACK_S = 300      # une date de construction plus loin que cela dans le futur n'en est pas une
MAX_REASONS = 100

ABSENT = {"state": "absent", "app": None, "url": None, "api_url": None, "groups": [], "built_at": None,
          "services": []}


class Incoherent(Exception):
    """La sortie du script n'a pas la forme du contrat, ou ne parle pas de ce qui a été demandé."""


def last_line(text: str) -> str:
    """Dernière ligne non vide d'une sortie."""
    for line in reversed(text.splitlines()):
        if line.strip():
            return line.strip()
    return ""


def parse(line: str) -> dict:
    """`RESULTAT=<objet JSON>` → l'objet. La ligne doit être la DERNIÈRE de la sortie (I1)."""
    if not line.startswith(PREFIX):
        raise Incoherent("dernière ligne « RESULTAT= » absente")
    try:
        obj = json.loads(line[len(PREFIX):])
    except ValueError:
        raise Incoherent("ligne « RESULTAT= » illisible") from None
    if not isinstance(obj, dict):
        raise Incoherent("ligne « RESULTAT= » : un objet JSON est attendu")
    return obj


def _url(value: Any, name: str) -> str | None:
    if value is None:
        return None
    if not isinstance(value, str) or not value.startswith("https://") or len(value) > 300 or \
            any(ch.isspace() for ch in value):
        raise Incoherent(f"« {name} » inattendu")
    return value


def status(obj: dict, uid: str) -> dict:
    """Résultat de `status <uid>` (I1), contrôlé et réduit aux champs du contrat."""
    if obj.get("uid") != uid:
        raise Incoherent("le résultat ne parle pas du développeur demandé")
    state = obj.get("state")
    if state not in STATES:
        raise Incoherent("« state » inattendu")
    if state == "absent":
        return dict(ABSENT, groups=[], services=[])
    app = obj.get("app")
    if not valid_app(app):
        raise Incoherent("« app » inattendu")
    groups = obj.get("groups")
    if not isinstance(groups, list) or len(groups) > 50 or \
            not all(isinstance(g, str) and _GROUP_RE.fullmatch(g) for g in groups):
        raise Incoherent("« groups » inattendu")
    services = obj.get("services")
    if not isinstance(services, list) or len(services) > 50:
        raise Incoherent("« services » inattendu")
    out_services = []
    for item in services:
        if (not isinstance(item, dict) or not isinstance(item.get("service"), str)
                or not _SERVICE_RE.fullmatch(item["service"]) or item.get("state") not in SERVICE_STATES):
            raise Incoherent("« services » inattendu")
        out_services.append({"service": item["service"], "state": item["state"]})
    built_at = obj.get("built_at")
    if built_at is not None and (not isinstance(built_at, str) or len(built_at) > 64):
        raise Incoherent("« built_at » inattendu")
    return {"state": state, "app": app, "url": _url(obj.get("url"), "url"),
            "api_url": _url(obj.get("api_url"), "api_url"), "groups": list(groups), "built_at": built_at,
            "services": out_services}


def built(built_at: Any) -> datetime.datetime | None:
    """Date de construction, ou None si elle est illisible. Une date SANS décalage horaire est
    illisible : le moteur et l'hôte n'ont pas forcément le même fuseau, elle désignerait deux
    instants."""
    if not isinstance(built_at, str):
        return None
    try:
        when = datetime.datetime.fromisoformat(built_at)
    except ValueError:
        return None
    return when if when.tzinfo is not None else None


def view(st: dict, app: str, ttl_h: float) -> dict:
    """L'objet « essai » d'I2, pour le projet `app` : l'état d'I1, plus `current` et `expires_at`."""
    when = built(st["built_at"]) if st["state"] != "absent" else None
    expires = None
    if when is not None:
        try:
            expires = (when + datetime.timedelta(hours=ttl_h)).isoformat()
        except OverflowError:
            expires = None
    return {"state": st["state"], "current": st["state"] != "absent" and st["app"] == app, "app": st["app"],
            "url": st["url"], "api_url": st["api_url"], "groups": st["groups"], "built_at": st["built_at"],
            "expires_at": expires, "services": st["services"]}


def due(st: dict, now: float, ttl_h: float) -> str | None:
    """Pourquoi cet essai est à démonter d'après sa date, ou None. Une date illisible ou dans le
    futur vaut « échu » : un essai dont on ne sait pas l'âge ne doit pas vivre indéfiniment."""
    if st["state"] == "absent":
        return None
    when = built(st["built_at"])
    if when is None:
        return "date de construction illisible"
    ts = when.timestamp()
    if ts > now + CLOCK_SLACK_S:
        return "date de construction dans le futur"
    if now >= ts + ttl_h * 3600:
        return f"terme échu ({ttl_h:g} h après sa construction)"
    return None


def up(obj: dict, uid: str, app: str, code: int) -> dict | None:
    """Résultat de `up <uid> <app>` : None s'il dit un succès COHÉRENT (code 0, même développeur,
    même projet), sinon le résultat d'échec du job, dans la forme d'I2."""
    ok = obj.get("ok")
    if ok is True:
        if code != 0:
            raise Incoherent(f"succès annoncé avec le code de sortie {code}")
        if obj.get("uid") != uid or obj.get("app") != app:
            raise Incoherent("le résultat ne parle pas du développeur et du projet demandés")
        return None
    if ok is not False:
        raise Incoherent("« ok » inattendu")
    step = obj.get("step")
    if not isinstance(step, str) or not STEP_RE.fullmatch(step):
        raise Incoherent("échec sans étape lisible")
    error = obj.get("error")
    reasons = obj.get("reasons")
    return {"ok": False, "step": step,
            "error": error[:1000] if isinstance(error, str) and error.strip() else "app-preview.sh a échoué",
            "reasons": [r[:1000] for r in reasons if isinstance(r, str)][:MAX_REASONS]
            if isinstance(reasons, list) else []}


def down(obj: dict, uid: str, code: int) -> bool:
    """Résultat de `down <uid>` : y avait-il quelque chose à arrêter ?"""
    if code != 0 or obj.get("ok") is not True or obj.get("uid") != uid or not isinstance(obj.get("stopped"), bool):
        raise Incoherent(f"résultat inattendu (code {code})")
    return obj["stopped"]
