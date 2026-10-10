"""Configuration du serveur, lue une fois dans l'environnement.

Rien ici n'est un secret : le serveur n'en détient aucun au repos. Les deux
seuls secrets qu'il manipule sont le jeton Keycloak de l'appelant (présenté à
chaque requête) et son jeton GitHub (demandé à oauth-hub à chaque opération),
tous deux gardés en mémoire le temps de l'opération.
"""
from __future__ import annotations

import os
from dataclasses import dataclass


def _env(key: str, default: str = "") -> str:
    return os.environ.get(key, default).strip()


@dataclass(frozen=True)
class Config:
    # Racine du dépôt, montée AU MÊME CHEMIN que sur l'hôte (contrat I5) : les
    # scripts lancent `docker compose` et `docker run -v` avec ce chemin, que le
    # démon de l'hôte doit pouvoir résoudre tel quel.
    root: str
    domain: str
    public_url: str          # URL publique de la ressource MCP (…/mcp)
    issuer: str              # claim `iss` attendu
    jwks_url: str            # clés du realm, jointes par le réseau interne
    client_id: str           # seul `azp` accepté à l'entrée MCP ; l'entrée web n'accepte que « lab-admin » (auth.py)
    oauth_hub_url: str       # API d'oauth-hub, par le réseau interne
    github_api: str
    github_web: str          # base des URL de clone (https://github.com)
    runner_url: str
    lab_repo: str            # dépôt des tickets `scope: lab`
    quick_lock_timeout: int  # attente du verrou pour un appel synchrone
    job_lock_timeout: int    # attente du verrou pour un job (déploiement, création)
    allow_file_origin: bool  # TESTS UNIQUEMENT — voir README
    # ── espaces de travail (I3) ──
    work_dir: str            # LAB_WORK_DIR : clones de travail et maisons, HORS du dépôt
    ws_image: str
    ws_gateway: str          # nom du conteneur passerelle (lab-ws-gateway)
    ws_gateway_url: str
    ws_prefix: str           # « ws- » ; les essais utilisent « ws-test- »
    public_origin: str       # https://<DOMAIN>
    ws_max: int
    ws_idle_min: float
    ws_memory: str
    ws_cpus: str
    ws_pids: int
    ws_public_via_host: bool # DOMAIN résolu vers l'hôte dans l'espace (indépendant du NAT en épingle)
    # ── console SQL ──
    sql_timeout_s: int
    sql_max_rows: int
    host: str
    port: int

    @property
    def scripts(self) -> str:
        return os.path.join(self.root, "scripts")


def load() -> Config:
    root = _env("LAB_ROOT")
    if not root or not os.path.isabs(root):
        raise SystemExit("LAB_ROOT doit être le chemin absolu du dépôt (= HOST_DEV_ROOT).")
    if not os.path.isfile(os.path.join(root, "scripts", "lab-lock.sh")):
        raise SystemExit(
            f"{root}/scripts/lab-lock.sh introuvable : le dépôt n'est pas monté à ce chemin."
        )
    domain = _env("DOMAIN")
    if not domain or domain == "CHANGE_ME":
        raise SystemExit("DOMAIN doit être renseigné (le serveur MCP n'est servi qu'en HTTPS).")
    realm_public = f"https://{domain}/auth/realms/ssolab"
    return Config(
        root=root.rstrip("/"),
        domain=domain,
        public_url=_env("LAB_MCP_PUBLIC_URL", f"https://{domain}/mcp").rstrip("/"),
        # Émetteur et clés du realm : DÉDUITS, jamais lus dans l'environnement.
        # C'est l'ancre de confiance du serveur — une variable qui permettrait de
        # la déplacer serait un « mode identité forcée ». Le conteneur joint
        # Keycloak par sso-net (port interne 8080, sans le préfixe /auth que
        # Caddy retire) ; l'émetteur attendu est l'URL publique du realm.
        issuer=realm_public,
        jwks_url="http://keycloak:8080/realms/ssolab/protocol/openid-connect/certs",
        client_id="lab-mcp",  # seul `azp` accepté à l'entrée MCP — constant, pas configurable
        oauth_hub_url=_env("OAUTH_HUB_INTERNAL_URL", "http://oauth-hub-backend:8000").rstrip("/"),
        github_api=_env("GITHUB_API_URL", "https://api.github.com").rstrip("/"),
        github_web=_env("GITHUB_WEB_URL", "https://github.com").rstrip("/"),
        runner_url=_env("LAB_RUNNER_URL", "http://lab-runner:4300").rstrip("/"),
        lab_repo=_env("LAB_TICKET_REPO", "Sacha37420/sso-lab"),
        quick_lock_timeout=int(_env("LAB_MCP_QUICK_LOCK_TIMEOUT", "20")),
        job_lock_timeout=int(_env("LAB_MCP_JOB_LOCK_TIMEOUT", "900")),
        allow_file_origin=_env("LAB_GIT_ALLOW_FILE") == "1",
        work_dir=_env("LAB_WORK_DIR", os.path.join(os.path.dirname(root.rstrip("/")), "lab-work")).rstrip("/"),
        ws_image=_env("LAB_WS_IMAGE", "lab-workspace:latest"),
        ws_gateway=_env("LAB_WS_GATEWAY", "lab-ws-gateway"),
        ws_gateway_url=_env("LAB_WS_GATEWAY_URL", "http://lab-ws-gateway:8080").rstrip("/"),
        ws_prefix=_env("LAB_WS_PREFIX", "ws-"),
        public_origin=_env("LAB_MCP_PUBLIC_URL", f"https://{domain}/mcp").rstrip("/").rsplit("/mcp", 1)[0],
        ws_max=int(_env("LAB_WS_MAX", "3")),
        ws_idle_min=float(_env("LAB_WS_IDLE_MIN", "30")),
        ws_memory=_env("LAB_WS_MEMORY", "2g"),
        ws_cpus=_env("LAB_WS_CPUS", "1"),
        ws_pids=int(_env("LAB_WS_PIDS", "512")),
        ws_public_via_host=_env("LAB_WS_PUBLIC_VIA_HOST", "1") == "1",
        sql_timeout_s=int(_env("LAB_SQL_TIMEOUT_S", "10")),
        sql_max_rows=int(_env("LAB_SQL_MAX_ROWS", "500")),
        host=_env("LAB_MCP_HOST", "0.0.0.0"),
        port=int(_env("LAB_MCP_PORT", "8000")),
    )
