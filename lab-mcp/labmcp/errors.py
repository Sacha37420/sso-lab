"""Erreurs du moteur — UN format, pour les deux entrées (API.md, « Erreurs »).

    {"error": "<code>", "detail": "<phrase pour l'utilisateur>", …champs propres au code}

Entrée web : ce corps, avec le statut HTTP ci-dessous. Entrée MCP : le même
objet, en JSON, comme texte de l'erreur d'outil. Les codes sont stables et faits
pour être testés ; `detail` est fait pour être affiché et peut être reformulé.
"""
from __future__ import annotations

# code → statut HTTP
STATUS = {
    "unauthorized": 401,       # jeton absent, invalide, expiré
    "forbidden": 403,          # jeton valide mais pas pour cette entrée / ce compte / cette action
    "not_initialized": 409,    # compte éligible, initialisation (me/init) pas encore faite
    "not_found": 404,          # projet, job… inconnu OU qui n'appartient pas à l'appelant (indistinct)
    "invalid": 400,            # argument refusé ; `reasons` quand il y en a plusieurs
    "name_refused": 400,       # check-app-name.sh ; `reasons` = une ligne « règle N : … » par règle
    "github_not_linked": 409,  # `connect_url`
    "github_scope": 409,       # liaison GitHub sans la portée « repo » ; `connect_url`
    "busy": 423,               # verrou de déploiement occupé (code 75 d'I4) — réessayer
    "job_exists": 409,         # un job est déjà en file ou en cours pour ce projet ; `job_id`
    "queue_full": 429,
    "workspace_limit": 429,    # LAB_WS_MAX espaces ouverts ; `open`, `max`
    "sql_error": 400,          # message de PostgreSQL ; `sqlstate`
    "sql_timeout": 400,
    "upstream": 502,           # oauth-hub, GitHub, lab-runner injoignable ou en refus ; `service`
    "unavailable": 503,        # une pièce du lab manque (script, image, fichier d'état) ; dit laquelle
    "failed": 500,             # l'opération était recevable et a échoué ; `detail` dit où
}


class LabError(Exception):
    def __init__(self, code: str, detail: str, **extra: object) -> None:
        super().__init__(detail)
        assert code in STATUS, code
        self.code = code
        self.detail = detail
        self.extra = {k: v for k, v in extra.items() if v is not None}

    @property
    def status(self) -> int:
        return STATUS[self.code]

    def body(self) -> dict:
        return {"error": self.code, "detail": self.detail, **self.extra}

    # Résultat d'audit : un refus n'est pas une panne.
    @property
    def refused(self) -> bool:
        return self.code not in ("upstream", "unavailable", "failed")
