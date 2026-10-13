"""File de jobs — déploiements et créations d'app (contrat I5, §8).

Forme retenue : une file EN MÉMOIRE, un seul travailleur.

  • Un seul job à la fois : le verrou de déploiement du lab l'impose de toute
    façon (2 vCPU). Faire attendre N processus sur `flock` n'apporterait rien ;
    la file garde l'ordre d'arrivée et laisse chaque job attendre le verrou
    seul (il peut encore être pris par un `setup2.sh` lancé à la main).
  • En mémoire : un job est un sous-processus de ce serveur. Si le conteneur
    redémarre, le job en cours meurt avec lui — un état persistant mentirait
    donc sur un job qui n'existe plus. L'état réel d'une app se lit toujours
    par `status`. L'historique (50 jobs) disparaît au redémarrage.
  • Le journal d'un job est borné (dernières lignes) : un build bavard ne doit
    pas faire enfler la mémoire du serveur.

Le jeton GitHub de l'appelant vit dans la fermeture `work` du job, de sa mise
en file à sa fin, puis est lâché (`job.work = None`). Il n'est jamais copié dans
l'objet Job, donc jamais rendu par `job_status`.
"""
from __future__ import annotations

import asyncio
import re
import secrets
import time
from collections import OrderedDict, deque
from dataclasses import dataclass, field
from typing import Awaitable, Callable

MAX_QUEUED = 8
MAX_HISTORY = 50
MAX_LOG_LINES = 3000
MAX_LINE_LEN = 2000
TERMINAL = ("succeeded", "failed")
_STEP = re.compile(r"\[lab-mcp\] étape « ([a-z0-9_]+) »")


@dataclass
class Job:
    id: str
    kind: str                 # deploy | create | tests | tests_all | preview
    app: str
    owner: str                # qui l'a lancé : un uid, ou « auto-deploy »
    state: str = "queued"     # queued | running | succeeded | failed  (les deux derniers sont terminaux)
    step: str = ""            # étape en cours, lue dans le journal
    created_at: float = field(default_factory=time.time)
    started_at: float | None = None
    ended_at: float | None = None
    result: dict = field(default_factory=dict)
    log: deque = field(default_factory=lambda: deque(maxlen=MAX_LOG_LINES))
    dropped: int = 0
    work: Callable[["Job"], Awaitable[dict]] | None = field(default=None, repr=False)

    def add_line(self, line: str) -> None:
        if len(self.log) == self.log.maxlen:
            self.dropped += 1
        self.log.append(line[:MAX_LINE_LEN])
        found = _STEP.search(line)
        if found:
            self.step = found.group(1)

    def view(self, tail: int) -> dict:
        """Forme publique d'un job (API.md, « Jobs ») — la même pour les deux entrées."""
        return {
            "job_id": self.id, "kind": self.kind, "app": self.app,
            "state": self.state, "terminal": self.state in TERMINAL,
            "step": (self.result.get("step") if self.state in TERMINAL else None) or self.step or None,
            "launched_by": self.owner,
            "created_at": _iso(self.created_at), "started_at": _iso(self.started_at),
            "ended_at": _iso(self.ended_at),
            "log_lines_total": len(self.log) + self.dropped,
            "log": list(self.log)[-tail:] if tail > 0 else [],
            "result": dict(self.result) if self.state in TERMINAL else None,
        }


def _iso(ts: float | None) -> str | None:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(ts)) if ts else None


class QueueFull(Exception):
    pass


class JobManager:
    def __init__(self) -> None:
        self._jobs: "OrderedDict[str, Job]" = OrderedDict()
        self._queue: asyncio.Queue[Job] = asyncio.Queue()
        self._worker: asyncio.Task | None = None
        self.on_done: Callable[[Job], None] | None = None

    def start(self) -> None:
        if self._worker is None or self._worker.done():
            self._worker = asyncio.create_task(self._run(), name="lab-mcp-jobs")

    async def stop(self) -> None:
        if self._worker:
            self._worker.cancel()

    def get(self, job_id: str) -> Job | None:
        return self._jobs.get(job_id)

    def active_for(self, app: str, preview: bool = False) -> Job | None:
        """Job en file ou en cours pour ce projet. Les jobs d'ESSAI (`preview`) forment une famille à
        part : un essai ne touche jamais à l'app en service, il ne bloque donc ni un déploiement ni
        un test du même projet, et inversement (la file les joue l'un après l'autre)."""
        for job in self._jobs.values():
            if job.app == app and job.state in ("queued", "running") and (job.kind == "preview") == preview:
                return job
        return None

    def active(self, kind: str) -> list[Job]:
        return [j for j in self._jobs.values() if j.kind == kind and j.state in ("queued", "running")]

    def submit(self, kind: str, app: str, owner: str,
               work: Callable[[Job], Awaitable[dict]]) -> Job:
        pending = [j for j in self._jobs.values() if j.state in ("queued", "running")]
        if len(pending) >= MAX_QUEUED:
            raise QueueFull()
        job = Job(id=secrets.token_hex(8), kind=kind, app=app, owner=owner, work=work)
        self._jobs[job.id] = job
        while len(self._jobs) > MAX_HISTORY:
            oldest = next(iter(self._jobs.values()))
            if oldest.state in ("queued", "running"):
                break
            self._jobs.popitem(last=False)
        self._queue.put_nowait(job)
        self.start()
        return job

    def position(self, job: Job) -> int:
        """Nombre de jobs devant celui-ci (0 = en cours ou prochain)."""
        ahead = 0
        for other in self._jobs.values():
            if other is job:
                break
            if other.state in ("queued", "running"):
                ahead += 1
        return ahead

    async def _run(self) -> None:
        while True:
            job = await self._queue.get()
            job.state = "running"
            job.started_at = time.time()
            try:
                assert job.work is not None
                job.result = await job.work(job)
                job.state = "succeeded" if job.result.get("ok") else "failed"
            except asyncio.CancelledError:
                job.state = "failed"
                job.result = {"ok": False, "error": "serveur arrêté pendant le job"}
                raise
            except Exception as exc:  # ne jamais tuer le travailleur
                job.state = "failed"
                job.result = {"ok": False, "error": f"erreur interne : {type(exc).__name__}"}
            finally:
                job.work = None       # lâche la fermeture, donc le jeton GitHub
                job.ended_at = time.time()
                if self.on_done:
                    try:
                        self.on_done(job)
                    except Exception:
                        pass
