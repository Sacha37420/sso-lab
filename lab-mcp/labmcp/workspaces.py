"""Espaces de travail — cycle de vie et contrôle d'accès (contrat I3).

Un espace = un conteneur `ws-<uid>` sur SON réseau `ws-net-<uid>`, ouvert sur UN
projet. Ce module est le seul endroit du moteur qui lance `docker` lui-même
(le contrat confie la création des conteneurs et réseaux d'espaces au moteur) :
toujours en liste d'arguments, avec des noms dérivés d'un uid et d'un nom d'app
déjà validés — jamais d'une chaîne libre de l'appelant.

ACHEMINEMENT (décision du §8, éprouvée en réel) : le Caddy du lab ne route que
vers sso-net, où un espace ne doit jamais être. Une passerelle (`lab-ws-gateway`,
gateway/Caddyfile) a un pied sur sso-net et un pied sur le réseau de chaque
espace ouvert — c'est le moteur qui l'y connecte ici, et l'en retire. Deux
espaces n'ont aucun réseau commun.

ACCÈS : `lab-admin` obtient un TICKET (usage unique, 60 s), que la première
requête échange contre un COOKIE lié à (personne, espace visé) et limité au
chemin `/ws/<uid>/`. La passerelle interroge `authorize()` à CHAQUE requête,
demande d'« upgrade » WebSocket comprise.

Tout l'état est en mémoire, et seuls des condensats (SHA-256) des jetons,
tickets et cookies sont gardés. Un redémarrage du moteur invalide donc tous les
jetons d'espace : `reconcile()` ferme alors les espaces restés ouverts plutôt
que de laisser tourner des conteneurs dont le jeton ne vaut plus rien.
"""
from __future__ import annotations

import asyncio
import hashlib
import os
import secrets
import time
from dataclasses import dataclass, field
from urllib.parse import urlencode

import httpx

from . import procs
from .access import TICKET_TTL, Access, digest as _h
from .auth import WS_TOKEN_PREFIX
from .config import Config
from .errors import LabError

HEARTBEAT = ".local/share/code-server/heartbeat"  # touché par code-server tant qu'une fenêtre est connectée


@dataclass
class Workspace:
    uid: str
    app: str
    token_hash: str
    opened_by: str
    with_github: bool
    with_git_identity: bool = False
    probe_cookie: str = field(default="", repr=False)   # session interne du moteur (sonde de santé)
    opened_at: float = field(default_factory=time.time)
    last_activity: float = field(default_factory=time.time)

    def view(self) -> dict:
        return {"open": True, "app": self.app, "opened_by": self.opened_by,
                "opened_at": _iso(self.opened_at), "last_activity": _iso(self.last_activity),
                "github_token": self.with_github, "git_identity": self.with_git_identity}


def _iso(ts: float) -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(ts))


class WorkspaceManager:
    def __init__(self, cfg: Config, access: Access, firewall) -> None:
        self.cfg = cfg
        self.access = access
        self.firewall = firewall
        self._ws: dict[str, Workspace] = {}
        self._lock = asyncio.Lock()
        self._reaper: asyncio.Task | None = None
        self._reconciled = False

    # ── noms ────────────────────────────────────────────────────────────────
    def container(self, uid: str) -> str:
        return f"{self.cfg.ws_prefix}{uid}"

    def network(self, uid: str) -> str:
        return f"{self.cfg.ws_prefix}net-{uid}"

    def home(self, uid: str) -> str:
        return os.path.join(self.cfg.work_dir, uid, ".home")

    def clone(self, uid: str, app: str) -> str:
        return os.path.join(self.cfg.work_dir, uid, app)

    def url(self, uid: str) -> str:
        return f"{self.cfg.public_origin}/ws/{uid}/"

    # ── lecture ─────────────────────────────────────────────────────────────
    def get(self, uid: str) -> Workspace | None:
        return self._ws.get(uid)

    def count(self) -> int:
        return len(self._ws)

    def lookup_token(self, token: str) -> tuple[str, str] | None:
        if not token.startswith(WS_TOKEN_PREFIX):
            return None
        digest = _h(token)
        for ws in self._ws.values():
            if secrets.compare_digest(ws.token_hash, digest):
                return ws.uid, ws.app
        return None

    # ── docker ──────────────────────────────────────────────────────────────
    async def _docker(self, *args: str, env: dict[str, str] | None = None, timeout: float = 60) -> tuple[int, str, str]:
        base = {"PATH": "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
                "HOME": os.environ.get("HOME", "/home/lab")}
        if env:
            base.update(env)
        return await procs.run(["docker", *args], base, cwd="/", timeout=timeout)

    async def _remove(self, uid: str) -> None:
        name, net = self.container(uid), self.network(uid)
        await self._docker("rm", "-f", name)
        await self._docker("network", "disconnect", "-f", net, self.cfg.ws_gateway)
        await self._docker("network", "rm", net)

    async def reconcile(self) -> None:
        """Au démarrage : ferme les espaces d'une vie précédente du moteur."""
        if self._reconciled:
            return
        self._reconciled = True
        label = f"label=lab.ws={self.cfg.ws_prefix}"
        _, out, _ = await self._docker("ps", "-a", "--filter", label, "--format", "{{.Names}}")
        for name in out.split():
            if name.startswith(self.cfg.ws_prefix) and name not in (self.container(u) for u in self._ws):
                await self._docker("rm", "-f", name)
        _, out, _ = await self._docker("network", "ls", "--filter", label, "--format", "{{.Name}}")
        for net in out.split():
            uid = net[len(self.cfg.ws_prefix) + 4:]
            if net.startswith(self.cfg.ws_prefix + "net-") and uid not in self._ws:
                await self._docker("network", "disconnect", "-f", net, self.cfg.ws_gateway)
                await self._docker("network", "rm", net)

    # ── cycle de vie ────────────────────────────────────────────────────────
    async def open(self, owner: str, app: str, viewer: str, gh_token: str,
                   author: tuple[str, str] | None = None) -> dict:
        """Ouvre (ou rejoint) l'espace de `owner` sur `app` ; rend l'URL à ticket."""
        async with self._lock:
            await self.reconcile()
            current = self._ws.get(owner)
            if current and current.app != app:
                # « Ouvrir un autre projet ferme le précédent. »
                await self._close_locked(owner)
                current = None
            reused = current is not None
            if not current:
                if len(self._ws) >= self.cfg.ws_max:
                    raise LabError(
                        "workspace_limit",
                        f"{len(self._ws)} espaces de travail sont déjà ouverts sur le lab (maximum "
                        f"{self.cfg.ws_max}). Réessayez quand l'un d'eux sera fermé (arrêt automatique après "
                        f"{self.cfg.ws_idle_min:g} min sans activité).",
                        open=len(self._ws), max=self.cfg.ws_max,
                    )
                current = await self._start(owner, app, viewer, gh_token, author)
            ticket = self.access.ticket("ws", viewer, owner)
            self._start_reaper()
            return {"url": f"{self.url(owner)}?{urlencode({'ticket': ticket})}", "uid": owner, "app": app,
                    "reused": reused, "ticket_expires_in": TICKET_TTL, "workspace": current.view()}

    async def _start(self, owner: str, app: str, viewer: str, gh_token: str,
                     author: tuple[str, str] | None) -> Workspace:
        cfg = self.cfg
        clone, home = self.clone(owner, app), self.home(owner)
        if not os.path.isdir(clone):
            raise LabError("unavailable", f"Clone de travail absent pour « {app} » (work-clone.sh n'a rien produit).")
        os.makedirs(home, mode=0o700, exist_ok=True)
        name, net = self.container(owner), self.network(owner)
        token = WS_TOKEN_PREFIX + secrets.token_urlsafe(32)   # 256 bits

        # Pare-feu des ponts d'espace (I3 v7) : vérifié AVANT chaque ouverture. S'il ne peut pas
        # être posé, l'espace n'est pas ouvert — il joindrait les ports de l'hôte.
        await self.firewall.ensure()
        await self._remove(owner)  # reste éventuel d'une ouverture interrompue
        bridge = cfg.ws_bridge_prefix + "w" + _h(net)[:10]     # nom d'interface ≤ 15 caractères
        code, _, err = await self._docker("network", "create", "--label", f"lab.ws={cfg.ws_prefix}",
                                          "-o", f"com.docker.network.bridge.name={bridge}", net)
        if code != 0:
            raise LabError("failed", f"Création du réseau de l'espace impossible : {err.strip()[-200:]}")
        args = [
            "run", "-d", "--name", name, "--hostname", name, "--restart", "no",
            "--label", f"lab.ws={cfg.ws_prefix}", "--label", f"lab.ws.app={app}",
            "--network", net,
            # Enfermement (I3) : ni socket Docker, ni privilège, ni capacité.
            "--cap-drop", "ALL", "--security-opt", "no-new-privileges",
            "--memory", cfg.ws_memory, "--memory-swap", cfg.ws_memory,
            "--cpus", cfg.ws_cpus, "--pids-limit", str(cfg.ws_pids),
            # Deux montages, et rien d'autre : le projet et la maison du dev.
            "-v", f"{clone}:/work/{app}", "-v", f"{home}:/home/coder",
            # Valeurs lues dans l'environnement du client docker : jamais sur
            # sa ligne de commande (lisible par `ps`), jamais sur disque.
            "-e", "LAB_MCP_URL", "-e", "LAB_MCP_TOKEN", "-e", "LAB_APP", "-e", "LAB_UID", "-e", "GH_TOKEN",
        ]
        if author:
            # Auteur des commits (I7) : le compte GitHub du propriétaire, connu en même temps que
            # son jeton. Sans jeton, pas d'identité : rien n'est inventé.
            args += ["-e", "LAB_GIT_AUTHOR_NAME", "-e", "LAB_GIT_AUTHOR_EMAIL"]
        if cfg.ws_public_via_host:
            # L'URL publique du lab, jointe par l'hôte (edge-router) : ne dépend
            # pas du NAT en épingle de la box.
            args += ["--add-host", f"{cfg.domain}:host-gateway"]
        args.append(cfg.ws_image)
        env = {"LAB_MCP_URL": cfg.public_url, "LAB_MCP_TOKEN": token, "LAB_APP": app, "LAB_UID": owner,
               "GH_TOKEN": gh_token}
        if author:
            env["LAB_GIT_AUTHOR_NAME"], env["LAB_GIT_AUTHOR_EMAIL"] = author
        code, _, err = await self._docker(*args, env=env, timeout=120)
        if code != 0:
            await self._remove(owner)
            raise LabError("failed", f"Démarrage de l'espace impossible : {err.strip()[-300:]}")
        code, _, err = await self._docker("network", "connect", net, cfg.ws_gateway)
        if code != 0:
            await self._remove(owner)
            raise LabError("unavailable", f"Passerelle des espaces ({cfg.ws_gateway}) injoignable : {err.strip()[-200:]}")
        ws = Workspace(uid=owner, app=app, token_hash=_h(token), opened_by=viewer, with_github=bool(gh_token),
                       with_git_identity=bool(author),
                       # Session interne : le moteur n'est sur aucun réseau d'espace, il sonde
                       # l'éditeur PAR la passerelle. Elle ne compte jamais comme une activité du dev.
                       probe_cookie=self.access.engine_session("ws", owner))
        self._ws[owner] = ws
        await self._wait_ready(ws)
        return ws

    async def _probe(self, ws: Workspace, path: str, timeout: float = 3) -> httpx.Response | None:
        try:
            async with httpx.AsyncClient(timeout=timeout) as client:
                return await client.get(f"{self.cfg.ws_gateway_url}/ws/{ws.uid}/{path}",
                                        headers={"Cookie": f"{Access.cookie_name('ws', ws.uid)}={ws.probe_cookie}"})
        except httpx.HTTPError:
            return None

    async def _wait_ready(self, ws: Workspace, timeout: float = 25) -> bool:
        """Attend que l'éditeur réponde derrière la passerelle (sinon la première page du dev
        serait une erreur 502)."""
        deadline = time.time() + timeout
        while time.time() < deadline:
            r = await self._probe(ws, "healthz")
            if r is not None and r.status_code < 500:
                return True
            await asyncio.sleep(0.7)
        return False

    async def close(self, uid: str) -> bool:
        async with self._lock:
            return await self._close_locked(uid)

    async def _close_locked(self, uid: str) -> bool:
        ws = self._ws.pop(uid, None)
        self.access.drop("ws", uid)
        await self._remove(uid)
        return ws is not None

    # ── contrôle d'accès, à chaque requête ──────────────────────────────────
    def authorize(self, target: str, forwarded_uri: str, cookie_header: str, allowed) -> tuple[str, dict]:
        ws = self._ws.get(target)
        if ws is None:
            return "deny", {"reason": "espace fermé"}

        def touch() -> None:
            ws.last_activity = time.time()

        return self.access.authorize("ws", target, forwarded_uri, cookie_header, allowed, touch)

    # ── arrêt après inactivité ──────────────────────────────────────────────
    async def _activity(self, ws: Workspace) -> float:
        """Dernier signe de vie : dernière requête du dev passée par la passerelle, ou dernier
        battement de code-server (`GET /healthz` → `lastHeartbeat`, en ms). Le battement continue
        tant qu'une fenêtre de l'éditeur est connectée, même sans nouvelle requête HTTP — c'est lui
        qui évite de fermer un espace où quelqu'un tape. `/healthz` ne fait pas battre le cœur, et
        la passerelle ne garde aucune connexion ouverte vers l'éditeur (keepalive off) : sonder ne
        prolonge donc pas la vie d'un espace."""
        last = ws.last_activity
        r = await self._probe(ws, "healthz")
        try:
            beat = float(r.json().get("lastHeartbeat") or 0) / 1000 if r is not None and r.status_code == 200 else 0
        except (ValueError, TypeError, AttributeError):
            beat = 0
        if not beat:
            try:  # repli : le même battement, écrit par code-server dans la maison
                beat = os.stat(os.path.join(self.home(ws.uid), HEARTBEAT)).st_mtime
            except OSError:
                beat = 0
        return max(last, beat)

    def _start_reaper(self) -> None:
        if self._reaper is None or self._reaper.done():
            self._reaper = asyncio.create_task(self._reap(), name="lab-ws-reaper")

    async def _reap(self) -> None:
        while self._ws:
            await asyncio.sleep(min(30, max(2, self.cfg.ws_idle_min * 60 / 4)))
            now = time.time()
            self.access.purge()
            try:   # les règles ont pu être vidées par un tiers : reposées ici (au plus toutes les 2 min)
                await self.firewall.ensure()
            except Exception:
                pass
            limit = self.cfg.ws_idle_min * 60
            for uid, ws in list(self._ws.items()):
                if now - await self._activity(ws) <= limit:
                    continue
                async with self._lock:
                    if self._ws.get(uid) is ws and time.time() - await self._activity(ws) > limit:
                        await self._close_locked(uid)
                        self.on_idle_close(uid)

    def on_idle_close(self, uid: str) -> None:  # remplacé par le moteur (audit)
        pass
