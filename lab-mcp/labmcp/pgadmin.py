"""pgAdmin par développeur (contrat I9).

`pg-<uid>` : l'image pgAdmin en mode « poste de travail » (aucun écran de
connexion), derrière la passerelle et le même contrôle qu'un espace de travail
(ticket → cookie lié à `/pg/<uid>/`, vérifié à chaque requête).

RÉSEAU (question ouverte du §8, tranchée par essai) — `pg-<uid>` est sur UN
réseau, le sien, créé `--internal` : ni Internet, ni hôte, ni `dev-net`, ni
`sso-net`. Deux conteneurs du moteur y sont connectés à l'ouverture :
  • la passerelle (pour qu'il soit joint) ;
  • `lab-pg-relay`, un relais TCP qui ne sait faire qu'une chose — porter
    `postgres:5432` vers l'instance PostgreSQL et `postgis:5433` vers l'instance
    PostGIS. pgAdmin ne voit donc de `dev-net` QUE deux ports PostgreSQL, et
    aucune app de `dev-net` ne peut joindre un pgAdmin (qui n'a pas de mot de passe).

CE QUE pgAdmin NE REÇOIT PAS : `infra/.env`, `devuser`/`gisuser`, un `.pgpass`,
le mot de passe du dev. Les serveurs sont préenregistrés SANS mot de passe et
l'enregistrement est désactivé (ALLOW_SAVE_PASSWORD=False) ; ses données sont en
mémoire (tmpfs) : rien ne survit à la fermeture.

GARDE-FOU : tant que PostgreSQL accepte `devuser` sans mot de passe depuis les
réseaux Docker (`dev-db.sh hba-status` ≠ 0), taper « devuser » dans pgAdmin
donnerait le rôle superutilisateur. Le moteur refuse alors d'ouvrir.
"""
from __future__ import annotations

import asyncio
import json
import os
import secrets
import time
from dataclasses import dataclass, field

import httpx

from . import procs
from .access import TICKET_TTL, Access, digest
from .config import Config
from .errors import LabError


@dataclass
class PgAdmin:
    uid: str
    probe_cookie: str = field(repr=False)
    opened_at: float = field(default_factory=time.time)
    last_activity: float = field(default_factory=time.time)


class PgAdminManager:
    def __init__(self, cfg: Config, access: Access, firewall) -> None:
        self.cfg = cfg
        self.access = access
        self.firewall = firewall
        self._open: dict[str, PgAdmin] = {}
        self._lock = asyncio.Lock()
        self._reaper: asyncio.Task | None = None
        self.on_idle_close = lambda uid: None

    def container(self, uid: str) -> str:
        return f"{self.cfg.pg_prefix}{uid}"

    def network(self, uid: str) -> str:
        return f"{self.cfg.pg_prefix}net-{uid}"

    def is_open(self, uid: str) -> bool:
        return uid in self._open

    async def _docker(self, *args: str, env: dict[str, str] | None = None, timeout: float = 60) -> tuple[int, str, str]:
        base = {"PATH": "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
                "HOME": os.environ.get("HOME", "/home/lab")}
        if env:
            base.update(env)
        return await procs.run(["docker", *args], base, cwd="/", timeout=timeout)

    async def _remove(self, uid: str) -> None:
        name, net = self.container(uid), self.network(uid)
        await self._docker("rm", "-f", name)
        for peer in (self.cfg.ws_gateway, self.cfg.pg_relay):
            await self._docker("network", "disconnect", "-f", net, peer)
        await self._docker("network", "rm", net)

    async def reconcile(self) -> None:
        """Au démarrage : ferme les pgAdmin d'une vie précédente du moteur (leurs sessions sont mortes)."""
        label = f"label=lab.pg={self.cfg.pg_prefix}"
        _, out, _ = await self._docker("ps", "-a", "--filter", label, "--format", "{{.Names}}")
        for name in out.split():
            if name.startswith(self.cfg.pg_prefix):
                await self._docker("rm", "-f", name)
        _, out, _ = await self._docker("network", "ls", "--filter", label, "--format", "{{.Name}}")
        for net in out.split():
            if net.startswith(self.cfg.pg_prefix + "net-"):
                for peer in (self.cfg.ws_gateway, self.cfg.pg_relay):
                    await self._docker("network", "disconnect", "-f", net, peer)
                await self._docker("network", "rm", net)

    async def open(self, uid: str, servers: list[dict]) -> str:
        """Ouvre (ou rejoint) le pgAdmin de `uid` ; rend un ticket."""
        async with self._lock:
            if uid not in self._open:
                if len(self._open) >= self.cfg.pg_max:
                    raise LabError(
                        "pgadmin_limit",
                        f"{len(self._open)} pgAdmin sont déjà ouverts sur le lab (maximum {self.cfg.pg_max}). "
                        f"Réessayez quand l'un d'eux sera fermé (arrêt automatique après "
                        f"{self.cfg.ws_idle_min:g} min sans activité).",
                        open=len(self._open), max=self.cfg.pg_max)
                await self._start(uid, servers)
            self._start_reaper()
            return self.access.ticket("pg", uid, uid)

    async def _start(self, uid: str, servers: list[dict]) -> None:
        cfg = self.cfg
        name, net = self.container(uid), self.network(uid)
        # Définition des serveurs — aucun secret : hôte, port, base, rôle.
        conf_dir = os.path.join(cfg.work_dir, uid, ".pgadmin")
        try:
            os.makedirs(conf_dir, mode=0o755, exist_ok=True)
            path = os.path.join(conf_dir, "servers.json")
            with open(path, "w", encoding="utf-8") as fh:
                json.dump({"Servers": {str(i + 1): {
                    "Name": s["name"], "Group": "Lab", "Host": s["host"], "Port": s["port"],
                    "MaintenanceDB": s["database"], "Username": s["user"], "SSLMode": "prefer",
                    "DBRestriction": s["database"],
                } for i, s in enumerate(servers)}}, fh, ensure_ascii=False)
            os.chmod(path, 0o644)
        except OSError as exc:
            raise LabError("unavailable", f"Dossier de travail inaccessible ({cfg.work_dir}) : {exc.strerror}") from None

        await self.firewall.ensure()
        await self._remove(uid)
        bridge = cfg.ws_bridge_prefix + "p" + digest(net)[:10]
        code, _, err = await self._docker(
            "network", "create", "--internal", "--label", f"lab.pg={cfg.pg_prefix}",
            "-o", f"com.docker.network.bridge.name={bridge}", net)
        if code != 0:
            raise LabError("failed", f"Création du réseau de pgAdmin impossible : {err.strip()[-200:]}")
        args = [
            "run", "-d", "--name", name, "--hostname", name, "--restart", "no",
            "--label", f"lab.pg={cfg.pg_prefix}", "--network", net,
            # Mesuré sur dpage/pgadmin4:8 : le Python de l'image porte une capacité de FICHIER
            # (cap_net_bind_service) ; sans elle dans l'ensemble du conteneur, il ne se lance pas
            # (« Operation not permitted »), même sur un port non privilégié. C'est la seule gardée.
            "--cap-drop", "ALL", "--cap-add", "NET_BIND_SERVICE", "--security-opt", "no-new-privileges",
            "--memory", cfg.pg_memory, "--memory-swap", cfg.pg_memory, "--cpus", "1", "--pids-limit", "256",
            # Données de pgAdmin en mémoire : préférences et connexions ne survivent pas à la fermeture.
            "--tmpfs", "/var/lib/pgadmin:uid=5050,gid=0,mode=0700", "--tmpfs", "/tmp",
            "-v", f"{path}:/pgadmin4/servers.json:ro",
            "-e", "SCRIPT_NAME=" + Access.path("pg", uid).rstrip("/"),
            "-e", "PGADMIN_LISTEN_PORT=8080",                  # port non privilégié : aucune capacité requise
            "-e", "PGADMIN_CONFIG_SERVER_MODE=False",          # poste de travail : pas d'écran de connexion
            "-e", "PGADMIN_CONFIG_MASTER_PASSWORD_REQUIRED=False",
            "-e", "PGADMIN_CONFIG_ALLOW_SAVE_PASSWORD=False",  # le mot de passe de la base n'est jamais enregistré
            "-e", "PGADMIN_CONFIG_ALLOW_SAVE_TUNNEL_PASSWORD=False",
            "-e", "PGADMIN_CONFIG_ENABLE_PSQL=False",
            "-e", "PGADMIN_CONFIG_UPGRADE_CHECK_ENABLED=False",
            "-e", "PGADMIN_DISABLE_POSTFIX=1",
            "-e", "PGADMIN_DEFAULT_EMAIL=dev@example.com",      # exigée par l'image (forme validée), jamais utilisée
            "-e", "PGADMIN_DEFAULT_PASSWORD",                  # exigé par l'image, jamais utilisé ; aléatoire
            cfg.pg_image,
        ]
        code, _, err = await self._docker(*args, env={"PGADMIN_DEFAULT_PASSWORD": secrets.token_urlsafe(24)}, timeout=120)
        if code != 0:
            await self._remove(uid)
            raise LabError("failed", f"Démarrage de pgAdmin impossible : {err.strip()[-300:]}")
        code, _, err = await self._docker("network", "connect", "--alias", "postgres", "--alias", "postgis",
                                          net, cfg.pg_relay)
        if code == 0:
            code, _, err = await self._docker("network", "connect", net, cfg.ws_gateway)
        if code != 0:
            await self._remove(uid)
            raise LabError("unavailable", f"Relais PostgreSQL ou passerelle injoignable : {err.strip()[-200:]}")
        pg = PgAdmin(uid=uid, probe_cookie=self.access.engine_session("pg", uid))
        self._open[uid] = pg
        # pgAdmin met 35 à 45 s à initialiser sa base interne (mesuré).
        deadline = time.time() + 150
        while time.time() < deadline:
            r = await self._probe(pg, "misc/ping")
            if r is not None and r.status_code == 200:
                return
            await asyncio.sleep(1)
        self._open.pop(uid, None)
        self.access.drop("pg", uid)
        await self._remove(uid)
        raise LabError("failed", "pgAdmin n'a pas démarré dans le délai imparti.")

    async def _probe(self, pg: PgAdmin, path: str) -> httpx.Response | None:
        try:
            async with httpx.AsyncClient(timeout=4) as client:
                return await client.get(f"{self.cfg.ws_gateway_url}/pg/{pg.uid}/{path}",
                                        headers={"Cookie": f"{Access.cookie_name('pg', pg.uid)}={pg.probe_cookie}"})
        except httpx.HTTPError:
            return None

    async def close(self, uid: str) -> bool:
        async with self._lock:
            return await self._close_locked(uid)

    async def _close_locked(self, uid: str) -> bool:
        was = self._open.pop(uid, None)
        self.access.drop("pg", uid)
        await self._remove(uid)
        return was is not None

    def authorize(self, target: str, forwarded_uri: str, cookie_header: str, allowed) -> tuple[str, dict]:
        pg = self._open.get(target)
        if pg is None:
            return "deny", {"reason": "pgAdmin fermé"}

        def touch() -> None:
            pg.last_activity = time.time()

        return self.access.authorize("pg", target, forwarded_uri, cookie_header, allowed, touch)

    def _start_reaper(self) -> None:
        if self._reaper is None or self._reaper.done():
            self._reaper = asyncio.create_task(self._reap(), name="lab-pg-reaper")

    async def _reap(self) -> None:
        # Inactivité = plus aucune requête du dev par la passerelle (un onglet pgAdmin ouvert
        # interroge son serveur en continu : onglet ouvert = actif).
        while self._open:
            await asyncio.sleep(min(30, max(2, self.cfg.ws_idle_min * 60 / 4)))
            limit = self.cfg.ws_idle_min * 60
            for uid, pg in list(self._open.items()):
                if time.time() - pg.last_activity > limit:
                    async with self._lock:
                        if self._open.get(uid) is pg and time.time() - pg.last_activity > limit:
                            await self._close_locked(uid)
                            self.on_idle_close(uid)


__all__ = ["PgAdminManager", "TICKET_TTL"]
