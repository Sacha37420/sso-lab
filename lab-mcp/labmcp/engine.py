"""Le moteur — TOUTES les fonctions du lab multi-dev, une seule fois (contrat I5).

Les deux entrées (outils MCP de `mcp_entry.py`, routes de `web.py`) n'ont aucune
logique : elles lisent leurs arguments et appellent `Engine.call(op, appelant, …)`.
Ce qui est rendu, ce qui est refusé et ce qui est journalisé se décide ici, donc
à l'identique des deux côtés.

Chaque opération est une méthode `op_<nom>(self, c: Caller, …)` qui rend un objet
JSON ou lève `LabError` (format d'erreur unique, errors.py).

Règles d'autorisation, appliquées par `_app` à toute opération prenant un projet :
le projet doit exister ET appartenir à l'appelant, sauf pour le superutilisateur.
« Inconnu » et « à un autre » donnent la même erreur (`not_found`) : on ne peut
pas énumérer les projets des autres. Un jeton d'espace de travail vaut son dev,
limité au projet ouvert et aux opérations de `WS_OPS`.
"""
from __future__ import annotations

import asyncio
import contextlib
import dataclasses
import hashlib
import hmac
import json
import logging
import os
import re
import secrets
import sys
import tempfile
import time
from typing import Any

import anyio
import httpx

from . import procs, sqlconsole
from .auth import Authenticator, Caller
from .config import Config
from .errors import LabError
from .github import Github, GithubError, parse_repo_url
from .jobs import Job, JobManager, QueueFull
from .oauthhub import HubError, OAuthHub
from .registry import Registry, valid_app, valid_uid
from .access import Access
from .firewall import Firewall
from .pgadmin import PgAdminManager
from .workspaces import WorkspaceManager

audit_log = logging.getLogger("lab-mcp.audit")
log = logging.getLogger("lab-mcp")

NAME_RE = re.compile(r"^[a-z][a-z0-9-]{1,38}[a-z0-9]$")
SHA_RE = re.compile(r"^[0-9a-f]{7,40}$")
KEY_RE = re.compile(r"^[A-Z][A-Z0-9_]{0,63}$")
SERVICE_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,62}$")
GROUP_RE = re.compile(r"^[A-Za-z0-9_-]{1,64}$")
JOB_RE = re.compile(r"^[0-9a-f]{16}$")
APP_TYPES = {"django": "3", "django-angular": "4", "angular": "5"}
MAX_LOG_LINES = 4000

# Ce qu'un jeton d'espace de travail peut appeler (I5) — sur SON projet seulement.
# (v8) `sql` en fait partie : c'est le projet du dev, l'IA qui y travaille doit pouvoir lire sa base —
# même exécution que pour lui (rôle dev_<uid> du propriétaire, schéma du projet).
WS_OPS = frozenset({"me", "project", "logs", "env_list", "env_set", "env_unset", "deploy", "run_tests", "job", "sql"})

# Écart avec GitHub (I5 v8) : cache en mémoire, rafraîchi en arrière-plan.
REMOTE_MAX_AGE = 300      # au plus un rafraîchissement automatique toutes les 5 minutes par projet
REMOTE_MIN_FORCED = 20    # plancher entre deux rafraîchissements DEMANDÉS (?refresh=1, déploiement, webhook)
REMOTE_CONCURRENCY = 2    # jamais plus de deux `app-remote.sh` à la fois : la liste ne doit rien ralentir


def audit(who: str, op: str, app: str, result: str, detail: str = "", via: str = "") -> None:
    """Qui, quoi, quel projet, résultat. Jamais de valeur de variable, de requête SQL ni de jeton."""
    audit_log.info(json.dumps({
        "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "audit": True, "user": who, "via": via, "op": op, "app": app,
        "result": result, "detail": detail[:300],
    }, ensure_ascii=False))


class Engine:
    def __init__(self, cfg: Config) -> None:
        self.cfg = cfg
        self.registry = Registry(cfg.root)
        self.hub = OAuthHub(cfg)
        self.jobs = JobManager()
        self.access = Access(secure_cookies=cfg.public_origin.startswith("https://"))
        self.firewall = Firewall(cfg)
        self.ws = WorkspaceManager(cfg, self.access, self.firewall)
        self.pg = PgAdminManager(cfg, self.access, self.firewall)
        self.authn = Authenticator(cfg, self.registry, self.ws.lookup_token)
        self._remote: dict[str, dict] = {}          # app → {reachable, head, deployed, behind, checked_at}
        self._remote_asked: dict[str, float] = {}   # app → dernier rafraîchissement lancé
        self._remote_tasks: set[asyncio.Task] = set()
        self._remote_gate: asyncio.Semaphore | None = None

        def job_done(job: Job) -> None:
            audit(job.owner, f"job:{job.kind}", job.app, "ok" if job.state == "succeeded" else "error",
                  f"job {job.id} {job.state} étape={job.result.get('step', '')} sha={job.result.get('sha', '')}")
            if job.kind == "deploy":
                # Ce qui tourne vient peut-être de changer : l'écart avec GitHub est à relire.
                self._remote_refresh(job.app, force=True)

        self.jobs.on_done = job_done
        self.ws.on_idle_close = lambda uid: audit("(moteur)", "workspace_idle_close", "", "ok", f"espace de {uid}")
        self.pg.on_idle_close = lambda uid: audit("(moteur)", "pgadmin_idle_close", "", "ok", f"pgAdmin de {uid}")

    async def startup(self) -> None:
        """Au démarrage du moteur : pare-feu des ponts d'espace, puis fermeture des espaces et
        pgAdmin d'une vie précédente (leurs jetons et sessions, gardés en mémoire, sont morts)."""
        try:
            await self.firewall.ensure(force=True)
            audit("(moteur)", "firewall", "", "ok", f"règles « {self.cfg.ws_bridge_prefix}+ » en place")
        except LabError as exc:
            # Le moteur démarre quand même (tout le reste fonctionne) ; aucune ouverture d'espace
            # ne passera tant que les règles ne peuvent pas être posées.
            audit("(moteur)", "firewall", "", "error", exc.detail)
        await self.ws.reconcile()
        await self.pg.reconcile()

    # ═════════════════════════════════════════════════════════════════════════
    # Point d'entrée unique des deux entrées
    # ═════════════════════════════════════════════════════════════════════════
    async def call(self, op: str, c: Caller, **kw: Any) -> Any:
        app = str(kw.get("app") or kw.get("name") or "")[:64]
        try:
            if c.scope_app is not None and op not in WS_OPS:
                raise LabError("forbidden",
                               "Un jeton d'espace de travail ne permet que d'agir sur le projet ouvert "
                               "(état, journaux, variables, base, déploiement, tests).")
            result = await getattr(self, "op_" + op)(c, **kw)
        except LabError as exc:
            audit(c.label, op, app, "refused" if exc.refused else "error", f"{exc.code} : {exc.detail}", c.entrance)
            raise
        except HubError as exc:
            err = self._hub_error(exc)
            audit(c.label, op, app, "refused" if err.refused else "error", err.code, c.entrance)
            raise err from None
        except GithubError as exc:
            audit(c.label, op, app, "error", f"github : {exc}", c.entrance)
            raise LabError("upstream", str(exc), service="github") from None
        except Exception as exc:
            # Message générique : un détail d'exception interne n'a rien à faire chez l'appelant.
            audit(c.label, op, app, "error", f"interne:{type(exc).__name__}", c.entrance)
            log.exception("erreur interne dans %s", op)
            raise LabError("failed", f"Erreur interne du moteur ({type(exc).__name__}).") from None
        audit(c.label, op, app, "ok", via=c.entrance)
        return result

    @staticmethod
    def _hub_error(exc: HubError) -> LabError:
        if exc.kind == "not_linked":
            return LabError("github_not_linked", str(exc), connect_url=exc.connect_url)
        if exc.kind == "scope":
            return LabError("github_scope", str(exc), connect_url=exc.connect_url or None)
        return LabError("upstream", str(exc), service="oauth-hub")

    # ── gardes ──────────────────────────────────────────────────────────────
    def _dev(self, c: Caller) -> str:
        """L'appelant doit être un dev initialisé ; rend son uid."""
        if not c.uid or not (c.in_developers or c.initialized):
            raise LabError("forbidden", "Réservé aux développeurs du lab (membres du groupe « developers »).")
        if not c.initialized:
            raise LabError("not_initialized",
                           "Votre espace de développeur n'est pas encore initialisé (POST /mcp/api/me/init).")
        return c.uid

    def _app(self, c: Caller, app: Any) -> str:
        self._dev(c)
        ok = (valid_app(app) and self.registry.app_exists(app)
              and (c.is_superuser or self.registry.app_owner(app) == c.uid)
              and (c.scope_app is None or c.scope_app == app))
        if not ok:
            raise LabError("not_found", f"Le projet « {str(app)[:64]} » est inconnu ou ne vous appartient pas.")
        return app

    def _as(self, c: Caller, as_uid: str | None) -> str:
        """`?as=<uid>` — réservé au superutilisateur."""
        uid = self._dev(c)
        if not as_uid or as_uid == uid:
            return uid
        if not c.is_superuser:
            raise LabError("forbidden", "« as » est réservé au superutilisateur.")
        if not valid_uid(as_uid) or not self.registry.is_dev(as_uid):
            raise LabError("not_found", f"Développeur « {str(as_uid)[:40]} » inconnu.")
        return as_uid

    def _need_token(self, c: Caller) -> str:
        if not c.token:
            raise LabError("forbidden", "Cette action demande votre connexion personnelle, pas un jeton d'espace de travail.")
        return c.token

    # ── scripts d'I4 ────────────────────────────────────────────────────────
    async def _script(self, name: str, args: list[str], *, stdin: bytes | None = None,
                      timeout: float = 120) -> tuple[int, str, str]:
        if not os.path.isfile(os.path.join(self.cfg.scripts, name)):
            raise LabError("unavailable", f"scripts/{name} n'est pas installé sur ce lab.")
        code, out, err = await procs.run(
            procs.script(self.cfg, name) + args, procs.base_env(self.cfg, self.cfg.quick_lock_timeout),
            cwd=self.cfg.root, stdin=stdin, timeout=timeout)
        if code == procs.LOCK_BUSY:
            raise LabError("busy", "Un déploiement ou une création est en cours sur le lab (verrou occupé) — "
                                   "réessayez dans quelques minutes.")
        return code, out, err

    @staticmethod
    def _last(text: str, n: int = 6) -> str:
        return " | ".join(ln.strip() for ln in text.strip().splitlines()[-n:] if ln.strip())

    async def _status(self, app: str) -> dict:
        code, out, err = await self._script("app-status.sh", [app])
        if code != 0:
            raise LabError("failed", f"app-status.sh a rendu {code} : {self._last(err)}")
        try:
            data = json.loads(out)
        except ValueError:
            raise LabError("failed", "app-status.sh a rendu une sortie illisible.") from None
        return data if isinstance(data, dict) else {}

    # ── écart avec GitHub (I5 v8) ───────────────────────────────────────────
    async def _remote_raw(self, app: str) -> dict | None:
        """`scripts/app-remote.sh <app>` (I4 v8) : une ligne JSON, délai borné, ne prend pas le verrou."""
        if not os.path.isfile(os.path.join(self.cfg.scripts, "app-remote.sh")):
            return None
        code, out, _ = await procs.run(
            procs.script(self.cfg, "app-remote.sh") + [app],
            procs.base_env(self.cfg, self.cfg.quick_lock_timeout), cwd=self.cfg.root, timeout=25)
        if code != 0:
            return None
        try:
            data = json.loads(out.strip().splitlines()[-1])
        except (ValueError, IndexError):
            return None
        return data if isinstance(data, dict) else None

    def _remote_refresh(self, app: str, force: bool = False) -> None:
        """Planifie un rafraîchissement EN ARRIÈRE-PLAN — jamais attendu par une requête."""
        now = time.time()
        asked = self._remote_asked.get(app, 0.0)
        if now - asked < (REMOTE_MIN_FORCED if force else REMOTE_MAX_AGE):
            return
        try:
            parse_repo_url(self.registry.repo_url(app))
        except GithubError:
            return                      # pas d'origine GitHub : rien à demander (« no_repo »)
        self._remote_asked[app] = now
        if self._remote_gate is None:
            self._remote_gate = asyncio.Semaphore(REMOTE_CONCURRENCY)

        async def work() -> None:
            assert self._remote_gate is not None
            async with self._remote_gate:
                try:
                    data = await self._remote_raw(app)
                except Exception:
                    data = None
            if data is None:
                return                  # script absent ou en échec : on garde ce qui était connu
            behind = data.get("behind")
            self._remote[app] = {
                "reachable": bool(data.get("reachable")),
                "head": data.get("head") if isinstance(data.get("head"), str) else None,
                "behind": behind if isinstance(behind, int) and not isinstance(behind, bool) else None,
                "checked_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            }

        task = asyncio.get_running_loop().create_task(work(), name=f"lab-remote-{app}")
        self._remote_tasks.add(task)
        task.add_done_callback(self._remote_tasks.discard)

    def _github_field(self, app: str, item: dict) -> dict:
        """Le champ `github` d'un projet (forme exacte d'I5 v8), depuis le cache — aucun appel ici."""
        out = {"status": "unknown", "head": None, "behind": None, "checked_at": None}
        try:
            parse_repo_url(item.get("repo_url") or "")
        except GithubError:
            out["status"] = "no_repo"
            return out
        cached = self._remote.get(app)
        if cached is None:
            return out                  # pas encore vérifié : « unknown », checked_at null
        out["checked_at"] = cached["checked_at"]
        if not cached["reachable"]:
            out["status"] = "unreachable"
            return out
        out["head"] = cached["head"]
        if cached["behind"] is not None:
            out["behind"] = cached["behind"]
            out["status"] = "up_to_date" if cached["behind"] == 0 else "behind"
        elif item.get("deployed") is None and item.get("state") in ("never_deployed", "stopped"):
            out["status"] = "not_deployed"   # rien en service
        # sinon : en service, mais la version déployée est inconnue (ou plus dans l'historique)
        return out

    # ── jobs ────────────────────────────────────────────────────────────────
    def _submit(self, kind: str, app: str, launched_by: str, work) -> dict:
        active = self.jobs.active_for(app)
        if active:
            raise LabError("job_exists", f"Un job est déjà en file ou en cours pour « {app} ».", job_id=active.id)
        try:
            job = self.jobs.submit(kind, app, launched_by, work)
        except QueueFull:
            raise LabError("queue_full", "Trop de jobs en attente sur le lab — réessayez plus tard.") from None
        return {"job_id": job.id, "kind": kind, "app": app, "state": job.state, "jobs_ahead": self.jobs.position(job)}

    def _chain(self, chain_args: list[str], token: str = ""):
        """Travail d'un job : un enchaînement lancé PAR lab-lock.sh (chain.py)."""
        cfg = self.cfg

        async def work(job: Job) -> dict:
            fd, result_path = tempfile.mkstemp(prefix="lab-mcp-", suffix=".json")
            os.close(fd)
            os.unlink(result_path)
            env = procs.base_env(cfg, cfg.job_lock_timeout)
            env.update({
                "LAB_ROOT": cfg.root,
                "PYTHONPATH": os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                "LAB_MCP_RESULT_FILE": result_path,
                "GITHUB_API_URL": cfg.github_api, "GITHUB_WEB_URL": cfg.github_web,
                "LAB_HOOK_BASE": f"{cfg.public_url}/api/hooks/github",
            })
            if token:
                env["LAB_GIT_TOKEN"] = token
            argv = procs.script(cfg, "lab-lock.sh") + [sys.executable, "-m", "labmcp.chain", *chain_args]
            code, _, err = await procs.run(argv, env, cwd=cfg.root, timeout=3 * 3600, on_line=job.add_line)
            result: dict = {}
            try:
                with open(result_path, encoding="utf-8") as fh:
                    result = json.load(fh)
            except (OSError, ValueError):
                pass
            finally:
                with contextlib.suppress(OSError):
                    os.unlink(result_path)
            if not result:
                if code == procs.LOCK_BUSY:
                    result = {"ok": False, "step": "lock",
                              "error": f"verrou de déploiement toujours occupé après {cfg.job_lock_timeout} s — "
                                       "rien n'a été lancé, recommencez plus tard"}
                else:
                    result = {"ok": False, "step": "interne",
                              "error": f"l'enchaînement s'est arrêté sans résultat (code {code}) {err}".strip()}
            result["exit_code"] = code
            return result

        return work

    # ═════════════════════════════════════════════════════════════════════════
    # Identité, initialisation
    # ═════════════════════════════════════════════════════════════════════════
    async def op_me(self, c: Caller, as_uid: str | None = None) -> dict:
        if as_uid and as_uid != c.uid:
            uid = self._as(c, as_uid)
            subject = dataclasses.replace(c, username=uid, uid=uid, is_superuser=self.registry.is_superuser(uid),
                                          in_developers=True, initialized=True, token="")
        else:
            subject = c
        reason = None
        if subject.uid is None:
            reason = "invalid_uid"
        elif not (subject.in_developers or subject.initialized):
            reason = "not_in_developers"
        out: dict = {
            "username": subject.username, "uid": subject.uid, "is_superuser": subject.is_superuser,
            "eligible": reason is None, "ineligible_reason": reason, "initialized": subject.initialized,
            "github_linked": None, "github": None, "database": None,
            "mcp_url": self.cfg.public_url, "oauth_hub_url": f"{self.cfg.public_origin}/oauth-hub/",
            "workspace": None,
            "pgadmin": {"open": bool(subject.uid) and self.pg.is_open(subject.uid)},
            "scope_app": c.scope_app, "viewed_as": subject.uid if subject is not c else None,
            "remaining": [],
        }
        if reason is None and not subject.initialized:
            out["remaining"].append({"step": "init", "detail": "Initialisation à lancer (POST /mcp/api/me/init)."})
        if subject.initialized and subject.uid:
            out["database"] = {"host": "postgres", "name": f"dev_{subject.uid}", "user": f"dev_{subject.uid}"}
            ws = self.ws.get(subject.uid)
            out["workspace"] = ws.view() if ws else {"open": False}
        if reason is None and subject.token:
            try:
                gh = await self.hub.status(subject.token)
                out["github_linked"] = gh["linked"]
                out["github"] = {"account": gh["account"], "scope": gh["scope"], "connect_url": gh["connect_url"]}
                if not gh["linked"]:
                    out["remaining"].append({
                        "step": "link_github", "url": gh["connect_url"] or out["oauth_hub_url"],
                        "detail": "Reliez votre compte GitHub dans oauth-hub (obligatoire pour créer un projet, "
                                  "ouvrir un ticket et ouvrir l'éditeur)."})
            except HubError as exc:
                # L'état est INCONNU — pas « non relié ».
                out["github"] = {"error": str(exc)}
        return out

    async def op_me_init(self, c: Caller) -> dict:
        """Tout ce qui ne demande pas le dev : inscription, base, dossiers. Idempotente, synchrone."""
        if c.uid is None:
            raise LabError("forbidden",
                           f"L'identifiant « {c.username} » n'a pas la forme d'un compte de développeur "
                           "(minuscules et chiffres, commençant par une lettre) — rien n'a été créé.")
        if not c.in_developers:
            raise LabError("forbidden", "Votre compte n'est pas membre du groupe « developers » — rien n'a été créé.")
        uid = c.uid
        steps: list[dict] = []
        if self.registry.is_dev(uid):
            steps.append({"name": "enroll", "done": True, "detail": "déjà inscrit"})
        else:
            # Contrôle qui fait foi (annuaire, pas le jeton), en lecture seule d'abord :
            # un refus ne doit rien avoir créé.
            code, out, err = await self._script("dev-enroll.sh", ["--check", uid], timeout=60)
            if code != 0:
                raise LabError("forbidden", "Inscription refusée — rien n'a été créé : " + (self._last(err or out, 3) or f"code {code}"))
            code, out, err = await self._script("dev-enroll.sh", [uid], timeout=300)
            if code != 0 or not self.registry.is_dev(uid):
                raise LabError("failed", "dev-enroll.sh a échoué : " + (self._last(err or out, 4) or f"code {code}"))
            steps.append({"name": "enroll", "done": True, "detail": f"inscrit ; base dev_{uid} provisionnée"})
        try:
            os.makedirs(self.ws.home(uid), mode=0o700, exist_ok=True)
            os.chmod(os.path.join(self.cfg.work_dir, uid), 0o700)
            steps.append({"name": "workdir", "done": True, "detail": "dossier de travail et maison prêts"})
        except OSError as exc:
            raise LabError("unavailable", f"Dossier de travail inaccessible ({self.cfg.work_dir}) : {exc.strerror}") from None
        me = await self.op_me(dataclasses.replace(c, initialized=True, is_superuser=self.registry.is_superuser(uid)))
        me["steps"] = steps
        return me

    # ── ma base : mot de passe, pgAdmin (I9) ─────────────────────────────────
    def _self_initialized(self, c: Caller) -> str:
        """Routes « soi-même » d'I9 : dev initialisé, avec sa connexion personnelle. 403 sinon (I9)."""
        if not c.uid or not c.initialized or not c.token:
            raise LabError("not_initialized", "Réservé à un développeur initialisé du lab, pour lui-même.", http=403)
        return c.uid

    def _role_passwords(self, uid: str) -> tuple[str, str]:
        return (sqlconsole._password(self.cfg.root, f"DEV_PG_PASSWORD__{uid}"),
                sqlconsole._password(self.cfg.root, f"DEV_GIS_PASSWORD__{uid}"))

    async def op_database_password(self, c: Caller) -> dict:
        """Le mot de passe de SA base. Jamais celui d'un autre (pas de `as`), jamais journalisé."""
        uid = self._self_initialized(c)
        password, gis_password = self._role_passwords(uid)
        if not password:
            raise LabError("unavailable", f"Aucun mot de passe enregistré pour le rôle dev_{uid} (infra/dev-roles.env).")
        return {
            "database": {"host": "postgres", "name": f"dev_{uid}", "user": f"dev_{uid}"},
            "gis": {"host": "postgis", "name": f"gis_{uid}", "user": f"dev_{uid}"} if gis_password else None,
            "password": password,
            "gis_password": gis_password or None,
        }

    async def _pg_locked(self) -> bool:
        """PostgreSQL exige-t-il un mot de passe de tous depuis les réseaux Docker ?
        Lu par la commande du lab ; code 0 = verrouillé, tout autre code = non (ou illisible)."""
        code, _, _ = await self._script("dev-db.sh", ["hba-status"], timeout=30)
        return code == 0

    async def op_pgadmin_open(self, c: Caller) -> dict:
        uid = self._self_initialized(c)
        if not await self._pg_locked():
            raise LabError(
                "pg_trust_enabled",
                "pgAdmin par développeur indisponible : PostgreSQL accepte encore le rôle d'administration "
                "sans mot de passe depuis les réseaux du lab. À ouvrir une fois ce réglage retiré par "
                "l'administrateur.")
        _, gis_password = self._role_passwords(uid)
        servers = [{"name": f"Ma base ({uid})", "host": "postgres", "port": 5432,
                    "database": f"dev_{uid}", "user": f"dev_{uid}"}]
        if gis_password:
            # 5433 : port du relais vers l'instance PostGIS (préenregistré, le dev n'a rien à saisir).
            servers.append({"name": f"Ma base SIG ({uid})", "host": "postgis", "port": 5433,
                            "database": f"gis_{uid}", "user": f"dev_{uid}"})
        ticket = await self.pg.open(uid, servers)
        return {"url": f"{self.cfg.public_origin}/pg/{uid}/?ticket={ticket}",
                "servers": [{"name": s["name"], "host": s["host"], "database": s["database"], "user": s["user"]}
                            for s in servers]}

    async def op_pgadmin_close(self, c: Caller) -> dict:
        uid = self._self_initialized(c)
        return {"closed": await self.pg.close(uid)}

    async def op_groups(self, c: Caller) -> dict:
        """Groupes qu'un dev peut choisir pour cloisonner un projet : nom + libellé, rien d'autre."""
        self._dev(c)
        return {"groups": [{"name": g, "label": g.replace("_", " ").replace("-", " ").capitalize()}
                           for g in self.registry.lab_groups()]}

    async def op_devs(self, c: Caller) -> dict:
        self._dev(c)
        if not c.is_superuser:
            raise LabError("forbidden", "Réservé au superutilisateur.")
        devs = []
        for uid in self.registry.devs():
            ws = self.ws.get(uid)
            devs.append({"uid": uid, "is_superuser": self.registry.is_superuser(uid),
                         "projects": len(self.registry.apps_of(uid)),
                         "workspace": ws.view() if ws else {"open": False}})
        return {"devs": devs}

    # ═════════════════════════════════════════════════════════════════════════
    # Projets
    # ═════════════════════════════════════════════════════════════════════════
    def _item(self, app: str, status: dict) -> dict:
        owner = self.registry.app_owner(app)
        back, front = self.registry.ports().get(app, ("", ""))
        services = status.get("services") or []
        running = sum(1 for s in services if s.get("state") == "running")
        deployed = None
        if status.get("sha"):
            deployed = {"sha": status.get("sha"), "at": status.get("at"), "tests": status.get("tests")}
        if services and running == len(services):
            state = "running"
        elif running:
            state = "partial"
        else:
            state = "stopped" if (services or deployed) else "never_deployed"
        ws = self.ws.get(owner)
        origin = self.cfg.public_origin
        item = {
            "name": app, "owner": owner, "repo_url": self.registry.repo_url(app) or None,
            # Chemins de la convention du lab (/<app>/ et /<app>-api/) : exacts pour tout projet créé
            # par le moteur ; une app historique peut servir un autre chemin.
            "urls": {"app": f"{origin}/{app}/" if (front or back) else None,
                     "api": f"{origin}/{app}-api/" if (back and front) else None},
            "ports": {"backend": int(back) if back.isdigit() else None,
                      "frontend": int(front) if front.isdigit() else None},
            "state": state, "deployed": deployed,
            "workspace": {"open": bool(ws and ws.app == app)},
        }
        item["github"] = self._github_field(app, item)
        return item

    async def op_projects(self, c: Caller, as_uid: str | None = None, refresh: bool = False) -> dict:
        uid = self._as(c, as_uid)
        if c.is_superuser and not as_uid:
            names = self.registry.all_apps()
        else:
            names = self.registry.apps_of(uid)
        gate = asyncio.Semaphore(4)

        async def one(app: str) -> dict:
            async with gate:
                try:
                    return self._item(app, await self._status(app))
                except LabError:
                    item = self._item(app, {})
                    item["state"] = "unknown"
                    return item

        projects = await asyncio.gather(*(one(a) for a in names))
        # Écart avec GitHub : on rend ce qui est connu, et on planifie (sans attendre) la mise à jour
        # de ce qui a plus de 5 minutes — ou de tout, sur demande (?refresh=1).
        for name in names:
            self._remote_refresh(name, force=bool(refresh))
        return {"projects": list(projects), "count": len(projects)}

    async def op_project(self, c: Caller, app: str, refresh: bool = False) -> dict:
        self._app(c, app)
        status = await self._status(app)
        item = self._item(app, status)
        self._remote_refresh(app, force=bool(refresh))
        where = sqlconsole.target(self.cfg, self.registry, app)
        auto = self._auto_read(app)
        item.update({
            "services": status.get("services") or [],
            # null pour une app historique, encore dans la base partagée (pas de console SQL).
            "database": ({"host": where["host"], "name": where["name"], "user": where["user"],
                          "schema": where["schema"]} if where["per_dev"] else None),
            "auto_deploy": {"enabled": bool(auto.get("enabled")), "available": bool(auto.get("secret"))},
            "mcp_url": self.cfg.public_url,
        })
        return item

    async def op_check_name(self, c: Caller, name: str) -> dict:
        self._dev(c)
        if not isinstance(name, str) or len(name) > 64 or "\n" in name or name.startswith("-") or not name:
            return {"ok": False, "reasons": ["règle 1 : nom invalide"]}
        code, out, err = await self._script("check-app-name.sh", [name])
        if code == 0:
            return {"ok": True, "reasons": []}
        if code == 1:
            return {"ok": False, "reasons": [ln for ln in out.splitlines() if ln.strip()]}
        raise LabError("failed", f"check-app-name.sh a rendu {code} : {self._last(err)}")

    async def op_create_project(self, c: Caller, name: str, type: str, required_groups: list,
                                visibility: str = "private") -> dict:
        uid = self._dev(c)
        token_kc = self._need_token(c)
        if not isinstance(name, str) or not NAME_RE.fullmatch(name) or "--" in name:
            raise LabError("invalid", "Nom invalide : 3 à 40 caractères, minuscules, chiffres et tirets.")
        if type not in APP_TYPES:
            raise LabError("invalid", "type : « django », « django-angular » ou « angular ».")
        if visibility not in ("private", "public"):
            raise LabError("invalid", "visibility : « private » ou « public ».")
        if (not isinstance(required_groups, list) or not required_groups or len(required_groups) > 10
                or not all(isinstance(g, str) and GROUP_RE.fullmatch(g) for g in required_groups)):
            raise LabError("invalid", "required_groups : au moins un groupe du lab (liste de noms) — un projet "
                                      "sans groupe requis serait ouvert à tout compte du realm.")
        known = self.registry.lab_groups()
        unknown = [g for g in required_groups if known and g not in known]
        if unknown:
            raise LabError("invalid", "Groupe(s) inconnu(s) du lab.", reasons=[f"groupe inconnu : {g}" for g in unknown])
        # Réponse immédiate si le nom est refusé (le contrôle qui fait foi est refait sous le verrou).
        check = await self.op_check_name(c, name)
        if not check["ok"]:
            raise LabError("name_refused", f"Le nom « {name} » est refusé.", reasons=check["reasons"])
        token = await self.hub.github_token(token_kc, need_repo_scope=True)
        return self._submit("create", name, uid, self._chain(
            ["create", uid, name, APP_TYPES[type], visibility, ",".join(required_groups)], token))

    # ── déploiement ─────────────────────────────────────────────────────────
    async def op_deploy(self, c: Caller, app: str, sha: str = "") -> dict:
        self._app(c, app)
        if not isinstance(sha, str) or (sha and not SHA_RE.fullmatch(sha)):
            raise LabError("invalid", "sha : 7 à 40 caractères hexadécimaux (pas de nom de branche ni de tag).")
        # Aucun jeton GitHub (v5) : app-sync.sh lit la clé de déploiement du projet.
        return self._submit("deploy", app, c.uid or "?", self._chain(["deploy", app] + ([sha] if sha else [])))

    async def op_commits(self, c: Caller, app: str) -> dict:
        self._app(c, app)
        owner, repo = parse_repo_url(self.registry.repo_url(app))
        token = await self.hub.github_token(self._need_token(c), need_repo_scope=False)
        status = await self._status(app)
        deployed = status.get("sha") or ""

        def fetch() -> tuple[str, list[dict]]:
            with Github(self.cfg.github_api, token) as gh:
                branch = gh.default_branch(owner, repo)
                return branch, gh.commits(owner, repo, branch)

        branch, commits = await anyio.to_thread.run_sync(fetch)
        for commit in commits:
            commit["deployed"] = bool(deployed) and commit["sha"] == deployed
        return {"app": app, "repository": f"{owner}/{repo}", "branch": branch, "commits": commits}

    async def op_job(self, c: Caller, job_id: str, tail: int = 200) -> dict:
        uid = self._dev(c)
        job = self.jobs.get(job_id) if isinstance(job_id, str) and JOB_RE.fullmatch(job_id) else None
        allowed = job is not None and (
            c.is_superuser or job.owner == uid
            or (self.registry.app_exists(job.app) and self.registry.app_owner(job.app) == uid))
        if job is None or not allowed or (c.scope_app is not None and job.app != c.scope_app):
            raise LabError("not_found", "Job inconnu (ou lancé par un autre développeur, ou perdu au redémarrage du moteur).")
        try:
            tail = max(0, min(int(tail), 1000))
        except (TypeError, ValueError):
            raise LabError("invalid", "tail : entier de 0 à 1000.") from None
        view = job.view(tail)
        view["jobs_ahead"] = self.jobs.position(job) if job.state == "queued" else 0
        return view

    # ── observation ─────────────────────────────────────────────────────────
    async def op_logs(self, c: Caller, app: str, service: str = "", tail: int = 200) -> dict:
        self._app(c, app)
        if not isinstance(service, str) or (service and not SERVICE_RE.fullmatch(service)):
            raise LabError("invalid", "service : nom de service Compose invalide.")
        try:
            tail = int(tail)
        except (TypeError, ValueError):
            tail = 0
        if not 1 <= tail <= 2000:
            raise LabError("invalid", "tail : entier de 1 à 2000.")
        args = [app] + ([service] if service else []) + ["--tail", str(tail)]
        code, out, err = await self._script("app-logs.sh", args, timeout=60)
        if code != 0:
            raise LabError("failed", self._last(err) or f"app-logs.sh a rendu {code}")
        lines = out.splitlines()
        truncated = len(lines) > MAX_LOG_LINES
        return {"app": app, "service": service or None, "tail": tail,
                "lines": lines[-MAX_LOG_LINES:], "truncated": truncated}

    # ── variables d'environnement ───────────────────────────────────────────
    @staticmethod
    def _key(key: Any) -> str:
        if not isinstance(key, str) or not KEY_RE.fullmatch(key):
            raise LabError("invalid", "Clé invalide : majuscules, chiffres et « _ », commençant par une lettre (64 max).")
        return key

    async def op_env_list(self, c: Caller, app: str) -> dict:
        self._app(c, app)
        code, out, err = await self._script("app-env.sh", ["list", app])
        if code != 0:
            raise LabError("failed", f"app-env.sh list a rendu {code} : {self._last(err)}")
        variables = []
        for line in out.splitlines():
            key, sep, value = line.partition("=")
            if sep:
                managed = value == "******** #géré"
                variables.append({"key": key, "managed": managed, "value": None if managed else value})
        return {"app": app, "variables": variables}

    async def op_env_set(self, c: Caller, app: str, key: str, value: str) -> dict:
        self._app(c, app)
        self._key(key)
        if not isinstance(value, str) or "\n" in value or "\r" in value or "\x00" in value or len(value) > 4096:
            raise LabError("invalid", "La valeur doit tenir sur une seule ligne (4096 caractères maximum).")
        # Valeur sur stdin, jamais en argument : une ligne de commande se lit par `ps`.
        code, _, err = await self._script("app-env.sh", ["set", app, key], stdin=value.encode("utf-8"))
        if code == 1:
            raise LabError("invalid", self._last(err, 2) or "app-env.sh a refusé cette clé.")
        if code != 0:
            raise LabError("failed", f"app-env.sh set a rendu {code} : {self._last(err)}")
        return {"app": app, "key": key, "set": True, "effective": "next_deploy"}

    async def op_env_unset(self, c: Caller, app: str, key: str) -> dict:
        self._app(c, app)
        self._key(key)
        code, _, err = await self._script("app-env.sh", ["unset", app, key])
        if code == 1:
            raise LabError("invalid", self._last(err, 2) or "app-env.sh a refusé cette clé.")
        if code != 0:
            raise LabError("failed", f"app-env.sh unset a rendu {code} : {self._last(err)}")
        return {"app": app, "key": key, "unset": True, "effective": "next_deploy"}

    # ── console SQL ─────────────────────────────────────────────────────────
    async def op_sql(self, c: Caller, app: str, query: str) -> dict:
        self._app(c, app)
        return await anyio.to_thread.run_sync(sqlconsole.run, self.cfg, self.registry, app, query)

    # ── tests ───────────────────────────────────────────────────────────────
    async def op_run_tests(self, c: Caller, app: str) -> dict:
        self._app(c, app)
        cfg = self.cfg

        async def work(job: Job) -> dict:
            job.add_line(f"══ [lab-mcp] étape « cloisonnement » — test de cloisonnement de {app} (lab-runner, navigateur réel)")
            for _ in range(60):   # le runner ne fait qu'un test à la fois sur tout le lab
                try:
                    async with httpx.AsyncClient(timeout=httpx.Timeout(1200, connect=10)) as client:
                        resp = await client.post(f"{cfg.runner_url}/run", json={"app": app})
                except httpx.HTTPError as exc:
                    return {"ok": False, "step": "cloisonnement", "error": f"lab-runner injoignable ({type(exc).__name__})"}
                if resp.status_code != 409:
                    break
                job.add_line("   … un autre test est en cours sur le lab, attente")
                await asyncio.sleep(10)
            else:
                return {"ok": False, "step": "cloisonnement", "error": "lab-runner occupé depuis 10 minutes"}
            try:
                data = resp.json()
            except ValueError:
                data = None
            if resp.status_code != 200 or not isinstance(data, list):
                detail = data.get("error", "") if isinstance(data, dict) else ""
                return {"ok": False, "step": "cloisonnement",
                        "error": f"lab-runner : HTTP {resp.status_code} {str(detail)[:500]}"}
            if not data:
                # Le runner répond [] sans erreur pour une app sans spec : relayé tel quel,
                # ce serait indiscernable d'un succès.
                summary = (f"AUCUN TEST TROUVÉ pour « {app} » — ce n'est PAS un succès : le cloisonnement de ce "
                           "projet n'est vérifié par rien (frontend/e2e/cloisonnement.spec.ts absent).")
                job.add_line("   ✗ " + summary)
                return {"ok": False, "step": "cloisonnement", "found": False, "all_passed": False,
                        "summary": summary, "tests": [], "error": summary}
            tests = [{"title": t.get("title"), "status": t.get("status"),
                      "message": str(t.get("message") or "")[:4000], "duration_ms": t.get("durationMs")}
                     for t in data]
            passed = sum(1 for t in tests if t["status"] == "PASSED")
            for t in tests:
                job.add_line(f"   {'✓' if t['status'] == 'PASSED' else '✗'} {t['title']} — {t['status']}")
            summary = f"{passed}/{len(tests)} test(s) réussi(s)"
            out = {"ok": passed == len(tests), "step": "cloisonnement", "found": True,
                   "all_passed": passed == len(tests), "summary": summary, "tests": tests}
            if not out["ok"]:
                out["error"] = summary
            return out

        return self._submit("tests", app, c.uid or "?", work)

    # ── tickets ─────────────────────────────────────────────────────────────
    async def op_open_ticket(self, c: Caller, title: str, body: str, scope: str = "app", app: str = "") -> dict:
        uid = self._dev(c)
        if scope not in ("app", "lab"):
            raise LabError("invalid", "scope : « app » ou « lab ».")
        if not isinstance(title, str) or not title.strip() or len(title) > 256 or "\n" in title:
            raise LabError("invalid", "title : une ligne non vide, 256 caractères maximum.")
        if not isinstance(body, str) or len(body) > 60000:
            raise LabError("invalid", "body : 60 000 caractères maximum.")
        if scope == "app" or app:
            self._app(c, app)
        if scope == "app":
            try:
                owner, repo = parse_repo_url(self.registry.repo_url(app))
            except GithubError as exc:
                raise LabError("invalid", str(exc)) from None
        else:
            owner, repo = self.cfg.lab_repo.split("/", 1)
        token = await self.hub.github_token(self._need_token(c), need_repo_scope=False)
        footer = f"\n\n---\nOuvert via le lab par `{uid}`" + (f" — projet `{app}`" if app else "")

        def create() -> dict:
            with Github(self.cfg.github_api, token) as gh:
                return gh.create_issue(owner, repo, title.strip(), body + footer)

        issue = await anyio.to_thread.run_sync(create)
        return {"repository": f"{owner}/{repo}", "number": issue["number"], "url": issue["url"]}

    # ═════════════════════════════════════════════════════════════════════════
    # Déploiement automatique (webhook GitHub signé, par projet)
    # ═════════════════════════════════════════════════════════════════════════
    def _auto_path(self, app: str) -> str:
        return os.path.join(self.registry.state_dir(), "auto-deploy", app + ".json")

    def _auto_read(self, app: str) -> dict:
        try:
            with open(self._auto_path(app), encoding="utf-8") as fh:
                data = json.load(fh)
            return data if isinstance(data, dict) else {}
        except (OSError, ValueError):
            return {}

    def _auto_write(self, app: str, data: dict) -> None:
        path = self._auto_path(app)
        os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
        fd = os.open(path + ".tmp", os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(data, fh)
        os.replace(path + ".tmp", path)

    async def op_auto_deploy(self, c: Caller, app: str, enabled: bool) -> dict:
        self._app(c, app)
        if not isinstance(enabled, bool):
            raise LabError("invalid", "enabled : true ou false.")
        auto = self._auto_read(app)
        if enabled and not auto.get("secret"):
            # Projet créé sans webhook : on le crée maintenant, avec le compte GitHub de l'appelant.
            try:
                owner, repo = parse_repo_url(self.registry.repo_url(app))
            except GithubError as exc:
                raise LabError("invalid", str(exc)) from None
            token = await self.hub.github_token(self._need_token(c), need_repo_scope=True)
            secret = secrets.token_hex(32)

            def create() -> int:
                with Github(self.cfg.github_api, token) as gh:
                    return gh.create_hook(owner, repo, f"{self.cfg.public_url}/api/hooks/github/{app}", secret)

            auto = {"secret": secret, "hook_id": await anyio.to_thread.run_sync(create)}
        auto["enabled"] = enabled
        self._auto_write(app, auto)
        return {"app": app, "enabled": enabled, "available": bool(auto.get("secret"))}

    async def hook(self, app: str, event: str, signature: str, body: bytes) -> dict:
        """Webhook GitHub. Aucune identité Keycloak : ce qui authentifie est la signature HMAC du projet."""
        auto = self._auto_read(app) if valid_app(app) and self.registry.app_exists(app) else {}
        secret = str(auto.get("secret") or "")
        expected = "sha256=" + hmac.new(secret.encode(), body, hashlib.sha256).hexdigest()
        if not secret or not hmac.compare_digest(expected, signature or ""):
            audit("github-webhook", "hook", str(app)[:64], "refused", "signature absente ou invalide", "web")
            raise LabError("forbidden", "Signature du webhook invalide.")
        ignored = None
        if event == "ping":
            ignored = "ping"
        elif event != "push":
            ignored = "event"
        elif not auto.get("enabled"):
            ignored = "disabled"
        else:
            try:
                payload = json.loads(body)
            except ValueError:
                raise LabError("invalid", "Corps du webhook illisible.") from None
            branch = str((payload.get("repository") or {}).get("default_branch") or "")
            # Seule la tête de la branche par défaut se déploie ; le SHA du webhook n'est PAS
            # repris : app-sync.sh redemande la tête à origin.
            if payload.get("deleted") or not branch or payload.get("ref") != f"refs/heads/{branch}":
                ignored = "branch"
        if event == "push":
            # GitHub vient de bouger : l'écart est à relire, que le déploiement automatique soit actif ou non.
            self._remote_refresh(app, force=True)
        if ignored:
            audit("github-webhook", "hook", app, "ok", f"ignoré : {ignored}", "web")
            return {"ok": True, "deployed": False, "ignored": ignored}
        try:
            job = self._submit("deploy", app, "auto-deploy", self._chain(["deploy", app]))
        except LabError as exc:
            audit("github-webhook", "hook", app, "ok", f"ignoré : {exc.code}", "web")
            return {"ok": True, "deployed": False, "ignored": exc.code}
        audit("github-webhook", "hook", app, "ok", f"job {job['job_id']}", "web")
        return {"ok": True, "deployed": True, "job_id": job["job_id"]}

    # ═════════════════════════════════════════════════════════════════════════
    # Espaces de travail
    # ═════════════════════════════════════════════════════════════════════════
    async def op_workspace_open(self, c: Caller, app: str) -> dict:
        viewer = self._dev(c)
        self._app(c, app)
        token_kc = self._need_token(c)
        owner = self.registry.app_owner(app)
        current = self.ws.get(owner)
        gh_token = ""
        author = None
        if not (current and current.app == app):
            if viewer == owner:
                # GH_TOKEN = le jeton GitHub DU DEV. Quand le superutilisateur ouvre l'espace d'un
                # autre, aucun jeton n'y est injecté : le sien n'a rien à faire dans la maison d'un autre.
                gh_token = await self.hub.github_token(token_kc, need_repo_scope=False)
                # Auteur des commits : le même que pour le premier commit d'un projet (chain.py).
                def identity() -> tuple[str, str] | None:
                    try:
                        with Github(self.cfg.github_api, gh_token) as gh:
                            me = gh.user()
                    except GithubError:
                        return None
                    name = re.sub(r"[\r\n<>]", " ", str(me["name"]))[:100].strip()
                    return (name or me["login"], f"{me['id']}+{me['login']}@users.noreply.github.com")
                author = await anyio.to_thread.run_sync(identity)
            code, out, err = await self._script("work-clone.sh", [owner, app], timeout=300)
            if code != 0:
                raise LabError("failed", "work-clone.sh a échoué : " + (self._last(err or out, 4) or f"code {code}"))
        return await self.ws.open(owner, app, viewer, gh_token, author)

    async def op_workspace_close(self, c: Caller, app: str) -> dict:
        self._app(c, app)
        owner = self.registry.app_owner(app)
        current = self.ws.get(owner)
        if current and current.app == app:
            return {"app": app, "closed": await self.ws.close(owner)}
        return {"app": app, "closed": False}

    def ws_authorize(self, kind: str, target: str, forwarded_uri: str, cookie: str) -> tuple[str, dict]:
        """Décision de la passerelle pour UNE requête vers `/ws/<uid>/` ou `/pg/<uid>/`."""
        if kind not in ("ws", "pg") or not valid_uid(target):
            return "deny", {"reason": "service inconnu"}
        manager = self.ws if kind == "ws" else self.pg
        return manager.authorize(
            target, forwarded_uri, cookie,
            lambda viewer, owner: self.registry.is_dev(viewer) and (viewer == owner or self.registry.is_superuser(viewer)))
