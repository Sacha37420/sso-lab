"""Pare-feu des ponts d'espace (I3 v7) — pose et vérification des règles.

Le moteur n'a ni le réseau de l'hôte ni NET_ADMIN, et ne doit pas les avoir : il
lance un conteneur JETABLE de sa propre image, en réseau hôte, avec la seule
capacité NET_ADMIN, qui exécute `lab-ws-firewall apply <préfixe>` et rien
d'autre (firewall/lab-ws-firewall.sh — tout ce qui se pose y est écrit et
commenté). Idempotent : appelé au démarrage du moteur et avant chaque ouverture
d'espace ou de pgAdmin.

ÉCHEC = REFUS : si les règles ne peuvent pas être posées, rien ne s'ouvre.

AU REDÉMARRAGE DE L'HÔTE : les règles iptables ne survivent pas, les espaces non
plus (`--restart no`). Le moteur (`restart: unless-stopped`) les repose à son
démarrage, et de toute façon avant la première ouverture. Si quelqu'un vide les
chaînes pendant qu'un espace tourne, elles sont reposées au plus tard deux
minutes après (ronde d'inactivité) ou à l'ouverture suivante.
"""
from __future__ import annotations

import os
import re
import socket
import time

from . import procs
from .config import Config
from .errors import LabError

RECHECK_S = 120
PREFIX_RE = re.compile(r"^lw[a-z]{1,5}$")


class Firewall:
    def __init__(self, cfg: Config) -> None:
        self.cfg = cfg
        self._ok_at = 0.0
        self._image = ""

    async def _docker(self, *args: str, timeout: float = 60) -> tuple[int, str, str]:
        env = {"PATH": "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
               "HOME": os.environ.get("HOME", "/home/lab")}
        return await procs.run(["docker", *args], env, cwd="/", timeout=timeout)

    async def _self_image(self) -> str:
        """L'image de CE conteneur : c'est elle qui porte lab-ws-firewall."""
        if not self._image:
            code, out, _ = await self._docker("inspect", "--format", "{{.Image}}", socket.gethostname())
            if code != 0 or not out.strip().startswith("sha256:"):
                raise LabError("unavailable", "Image du moteur introuvable : pare-feu des espaces non posé.")
            self._image = out.strip()
        return self._image

    async def ensure(self, force: bool = False) -> None:
        if not force and time.time() - self._ok_at < RECHECK_S:
            return
        prefix = self.cfg.ws_bridge_prefix
        if not PREFIX_RE.fullmatch(prefix):
            raise LabError("unavailable", "Préfixe de pont d'espace invalide : pare-feu non posé.")
        code, out, err = await self._docker(
            "run", "--rm", "--network", "host", "--user", "0", "--read-only",
            "--cap-drop", "ALL", "--cap-add", "NET_ADMIN", "--security-opt", "no-new-privileges",
            await self._self_image(), "lab-ws-firewall", "apply", prefix)
        if code != 0:
            self._ok_at = 0.0
            raise LabError("unavailable",
                           "Le pare-feu des espaces de travail n'a pas pu être posé — rien n'est ouvert : "
                           + (err or out).strip()[-200:])
        self._ok_at = time.time()
