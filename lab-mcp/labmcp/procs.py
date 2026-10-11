"""Exécution des commandes d'exploitation (contrat I4).

Règles tenues ici, à ne pas assouplir :

  • le serveur n'exécute QUE des scripts de `$ROOT/scripts` (liste fermée
    ci-dessous) — jamais un `docker` ni un `git` composé par lui ;
  • toujours une LISTE d'arguments (`exec`), jamais de shell : une valeur venue
    de l'appelant ne peut pas devenir de la syntaxe ;
  • environnement REPARTI DE ZÉRO pour chaque commande. `docker compose`
    interpole `${VAR}` depuis l'environnement du processus : tout ce que le
    serveur laisserait traîner (un jeton, par exemple) serait lisible par le
    `docker-compose.yml` d'un développeur. Le jeton GitHub n'est donc passé
    qu'aux deux scripts qui parlent à GitHub (app-sync.sh, app-register.sh).
"""
from __future__ import annotations

import asyncio
import os
import re
from typing import Awaitable, Callable

from .config import Config

# Les seules commandes que ce serveur lance (I4).
ALLOWED_SCRIPTS = frozenset({
    "lab-lock.sh", "check-app-name.sh", "new-app.sh", "app-register.sh", "app-sync.sh",
    "validate-app.sh", "setup2.sh", "app-status.sh", "app-logs.sh", "app-env.sh",
    "app-remove.sh",
    # v5 : inscription à la première connexion, clone de travail d'un espace
    "dev-enroll.sh", "work-clone.sh",
    # v7 : état de pg_hba (lecture seule : sous-commande hba-status uniquement)
    "dev-db.sh",
    # v8 : où en est GitHub par rapport à ce qui tourne (lecture seule, sans verrou)
    "app-remote.sh",
})

LOCK_BUSY = 75  # code rendu par les scripts quand le verrou de déploiement est occupé

_ANSI = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]")


def strip_ansi(text: str) -> str:
    return _ANSI.sub("", text)


def base_env(cfg: Config, lock_timeout: int) -> dict[str, str]:
    env = {
        "PATH": "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
        "HOME": os.environ.get("HOME", "/home/lab"),
        "LANG": "C.UTF-8",
        "LAB_LOCK_TIMEOUT": str(lock_timeout),
    }
    # Mêmes surcharges que celles que registry.sh sait lire : si le conteneur en
    # reçoit une, les scripts doivent voir la même (sinon serveur et scripts ne
    # seraient pas d'accord sur le superutilisateur ou sur le verrou).
    for key in ("LAB_SUPERUSER", "LAB_STATE_DIR", "LAB_WORK_DIR"):
        if os.environ.get(key):
            env[key] = os.environ[key]
    # LAB_GIT_ALLOW_FILE : origin en file:// — TESTS UNIQUEMENT. Le serveur ne le
    # pose jamais lui-même ; il ne fait que le transmettre quand le conteneur de
    # test l'a reçu explicitement (docker-compose.yml ne le définit pas).
    if cfg.allow_file_origin:
        env["LAB_GIT_ALLOW_FILE"] = "1"
    return env


def script(cfg: Config, name: str) -> list[str]:
    if name not in ALLOWED_SCRIPTS:
        raise ValueError(f"commande hors contrat : {name}")
    return ["bash", os.path.join(cfg.scripts, name)]


async def run(
    argv: list[str],
    env: dict[str, str],
    *,
    cwd: str,
    stdin: bytes | None = None,
    timeout: float = 120,
    on_line: Callable[[str], Awaitable[None] | None] | None = None,
    merge_stderr: bool = False,
) -> tuple[int, str, str]:
    """Lance une commande ; rend (code, stdout, stderr), séquences ANSI retirées.

    `on_line` reçoit chaque ligne de stdout au fil de l'eau (journal d'un job) ;
    dans ce cas stderr est fusionné dans stdout.
    """
    streaming = on_line is not None
    proc = await asyncio.create_subprocess_exec(
        *argv,
        cwd=cwd,
        env=env,
        stdin=asyncio.subprocess.PIPE if stdin is not None else asyncio.subprocess.DEVNULL,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.STDOUT if (streaming or merge_stderr) else asyncio.subprocess.PIPE,
        start_new_session=True,  # un Ctrl-C/arrêt du serveur ne tue pas un build en cours de route
    )

    async def _pump() -> tuple[str, str]:
        if not streaming:
            out, err = await proc.communicate(stdin)
            return out.decode("utf-8", "replace"), (err or b"").decode("utf-8", "replace")
        if stdin is not None and proc.stdin is not None:
            proc.stdin.write(stdin)
            await proc.stdin.drain()
            proc.stdin.close()
        assert proc.stdout is not None
        while True:
            try:
                raw = await proc.stdout.readline()
            except ValueError:  # ligne plus longue que le tampon : on la saute
                continue
            if not raw:
                break
            res = on_line(strip_ansi(raw.decode("utf-8", "replace").rstrip("\r\n")))
            if asyncio.iscoroutine(res):
                await res
        await proc.wait()
        return "", ""

    try:
        out, err = await asyncio.wait_for(_pump(), timeout=timeout)
    except asyncio.TimeoutError:
        try:
            os.killpg(proc.pid, 15)
        except ProcessLookupError:
            pass
        await proc.wait()
        return 124, "", f"délai dépassé ({int(timeout)} s)"
    return proc.returncode if proc.returncode is not None else 1, strip_ansi(out), strip_ansi(err)
