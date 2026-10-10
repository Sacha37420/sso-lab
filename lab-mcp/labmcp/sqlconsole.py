"""Console SQL — sur la base DU PROPRIÉTAIRE du projet, avec SON rôle (contrat I5).

Ce qui borne une requête, ce sont les droits PostgreSQL du rôle `dev_<uid>`
(NOSUPERUSER, propriétaire de sa seule base) — pas un filtrage du texte, qui se
contourne toujours. Le moteur ne se connecte donc JAMAIS en `devuser`/`gisuser` :
il ouvre une connexion réseau comme le ferait l'app, avec le mot de passe du
rôle lu dans `infra/dev-roles.env` (I2).

Garde-fous d'exploitation, pas de sécurité : délai (`statement_timeout`),
nombre de lignes, taille d'une cellule, une seule instruction par appel.
"""
from __future__ import annotations

import datetime
import decimal
import os
import re

import psycopg

from .config import Config
from .errors import LabError
from .registry import Registry, valid_uid

MAX_QUERY = 100_000
MAX_CELL = 10_000
SCHEMA_RE = re.compile(r"^[a-z_][a-z0-9_]{0,62}$")


def _password(root: str, key: str) -> str:
    try:
        with open(os.path.join(root, "infra", "dev-roles.env"), encoding="utf-8") as fh:
            for line in fh:
                if line.startswith(key + "="):
                    return line[len(key) + 1:].rstrip("\n").strip("'\"")
    except OSError:
        pass
    return ""


def target(cfg: Config, registry: Registry, app: str) -> dict:
    """Où vit le projet : instance, base, rôle, schéma. Jamais de mot de passe ici."""
    owner = registry.app_owner(app)
    gis = registry.app_env(app, "DB_HOST") == "postgis"
    schema = registry.app_env(app, "DB_SCHEMA")
    if not SCHEMA_RE.fullmatch(schema or ""):
        schema = app.replace("-", "_")
    name = f"{'gis' if gis else 'dev'}_{owner}"
    # Une app historique vit encore dans la base partagée (DB_NAME=devdb) : elle n'a pas de base
    # par développeur tant qu'elle n'a pas été basculée, et la console ne s'y ouvre pas.
    per_dev = registry.app_env(app, "DB_NAME") == name and registry.app_env(app, "DB_USER") == f"dev_{owner}"
    return {"host": "postgis" if gis else "postgres", "name": name, "user": f"dev_{owner}",
            "schema": schema, "per_dev": per_dev}


def _cell(value: object) -> object:
    if value is None or isinstance(value, (bool, int, float)):
        return value
    if isinstance(value, decimal.Decimal):
        return str(value)
    if isinstance(value, (datetime.datetime, datetime.date, datetime.time)):
        return value.isoformat()
    if isinstance(value, (bytes, memoryview)):
        raw = bytes(value)
        return "\\x" + raw[:MAX_CELL // 2].hex() + ("…" if len(raw) > MAX_CELL // 2 else "")
    if isinstance(value, (list, dict)):
        return value
    text = str(value)
    return text if len(text) <= MAX_CELL else text[:MAX_CELL] + "…"


def run(cfg: Config, registry: Registry, app: str, query: str) -> dict:
    """Bloquant (à lancer dans un fil). L'appelant a déjà vérifié la propriété de `app`."""
    if not isinstance(query, str) or not query.strip():
        raise LabError("invalid", "Requête vide.")
    if len(query) > MAX_QUERY or "\x00" in query:
        raise LabError("invalid", f"Requête trop longue ({MAX_QUERY} caractères maximum).")
    owner = registry.app_owner(app)
    if not valid_uid(owner):
        raise LabError("failed", "Propriétaire du projet illisible.")
    where = target(cfg, registry, app)
    gis = where["host"] == "postgis"
    if not where["per_dev"]:
        raise LabError("unavailable", "Ce projet n'a pas de base par développeur (app historique, encore dans la "
                                      "base partagée) : la console SQL ne s'y ouvre pas.")
    password = _password(cfg.root, f"DEV_{'GIS' if gis else 'PG'}_PASSWORD__{owner}")
    if not password:
        raise LabError("unavailable",
                       f"Aucun rôle {where['user']} provisionné sur l'instance « {where['host']} » "
                       "(infra/dev-roles.env) — ce projet n'a pas de base par développeur.")
    timeout_ms = cfg.sql_timeout_s * 1000
    try:
        conn = psycopg.connect(
            host=where["host"], port=5432, dbname=where["name"], user=where["user"], password=password,
            connect_timeout=5, autocommit=True, application_name="lab-console-sql",
            options=f"-c statement_timeout={timeout_ms} -c lock_timeout={timeout_ms} "
                    f"-c idle_in_transaction_session_timeout={timeout_ms} "
                    f"-c search_path={where['schema']},public",
        )
    except psycopg.Error as exc:
        raise LabError("upstream", f"Connexion à la base {where['name']} impossible : {str(exc).strip()[:300]}",
                       service="postgres") from None
    try:
        with conn, conn.cursor() as cur:
            try:
                cur.execute(query.encode("utf-8"))
                columns: list[str] = []
                rows: list[list] = []
                truncated = False
                if cur.description is not None:
                    columns = [d.name for d in cur.description]
                    fetched = cur.fetchmany(cfg.sql_max_rows + 1)
                    truncated = len(fetched) > cfg.sql_max_rows
                    rows = [[_cell(v) for v in row] for row in fetched[:cfg.sql_max_rows]]
                return {"columns": columns, "rows": rows, "truncated": truncated,
                        "row_count": len(rows) if columns else max(cur.rowcount, 0),
                        "status": cur.statusmessage or "",
                        "database": where["name"], "role": where["user"], "schema": where["schema"]}
            except psycopg.errors.QueryCanceled:
                raise LabError("sql_timeout",
                               f"Requête interrompue : délai de {cfg.sql_timeout_s} s dépassé.") from None
            except psycopg.Error as exc:
                diag = getattr(exc, "diag", None)
                message = (getattr(diag, "message_primary", None) or str(exc)).strip()
                raise LabError("sql_error", message[:1000], sqlstate=getattr(exc, "sqlstate", None)) from None
    finally:
        conn.close()
