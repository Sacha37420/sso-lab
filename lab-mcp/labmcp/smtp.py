"""Profils SMTP par développeur (contrat I10).

Un dev définit ses comptes SMTP une fois ; il en rattache un à un projet ; le lab
pose alors les variables standard de Django dans l'app (scripts/app-smtp.sh).
Le moteur n'envoie AUCUN email pour le compte d'une app : sa seule émission est
l'email d'essai d'un profil, vers l'adresse du compte de l'appelant.

LE MOT DE PASSE EST EN ÉCRITURE SEULE. Il entre par le corps d'une requête, vit
dans `<LAB_STATE_DIR>/smtp/<uid>.json` (600, écrit atomiquement) et n'en sort que
par deux chemins : le stdin d'`app-smtp.sh`, et la commande AUTH de l'essai. Il
n'est dans aucune réponse (`public()` ne le connaît pas), aucun journal, aucune
ligne de commande. Les erreurs de `smtplib` ne sont JAMAIS relayées telles
quelles : `_failure()` n'en retient que le code et le texte rendus par le
serveur, puis `_scrub()` y efface toute trace du secret, en clair ou encodé.

L'ESSAI NE SORT QUE VERS INTERNET : le moteur est sur sso-net et dev-net ; sans
ce contrôle, « tester un profil » dont l'hôte serait `keycloak` ou `postgres`
ferait de lui une sonde du réseau interne. L'hôte est résolu une fois, refusé
s'il désigne une adresse privée, et la connexion va à CETTE adresse.
"""
from __future__ import annotations

import base64
import ipaddress
import json
import os
import re
import secrets
import smtplib
import socket
import ssl
import time
from email.message import EmailMessage
from email.utils import formatdate, make_msgid

from .errors import LabError
from .registry import valid_uid

MAX_PROFILES = 10
TEST_INTERVAL_S = 30
TEST_DEADLINE_S = 20
SECURITIES = ("starttls", "ssl", "none")
ID_RE = re.compile(r"^[a-f0-9]{8}$")
HOST_RE = re.compile(r"^(?=.{1,253}$)[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$")
EMAIL_RE = re.compile(r"^[^\s<>@\"',;]{1,64}@[A-Za-z0-9]([A-Za-z0-9.-]{0,251}[A-Za-z0-9])?$")
FIELDS = ("label", "host", "port", "security", "username", "password", "from_email")


def public(pid: str, p: dict, projects: list[str]) -> dict:
    """Forme rendue par l'API — construite champ par champ : le mot de passe n'y est pas."""
    return {"id": pid, "label": p["label"], "host": p["host"], "port": p["port"], "security": p["security"],
            "username": p["username"], "from_email": p["from_email"],
            "has_password": bool(p.get("password")), "projects": projects}


def _clean(value: object, name: str, maxlen: int, allow_empty: bool = False) -> str:
    if not isinstance(value, str) or len(value) > maxlen or any(ord(ch) < 32 or ord(ch) == 127 for ch in value):
        raise LabError("invalid", f"{name} : texte sur une ligne, {maxlen} caractères maximum.")
    if not allow_empty and not value.strip():
        raise LabError("invalid", f"{name} : obligatoire.")
    return value


def validate(data: dict, base: dict | None = None) -> dict:
    """Profil complet et valide à partir de `data` (champs fournis) et de `base` (profil existant).
    Aucun message d'erreur ne reprend une valeur fournie."""
    unknown = [k for k in data if k not in FIELDS]
    if unknown:
        raise LabError("invalid", "Champ(s) inconnu(s).", reasons=[f"champ inconnu : {str(k)[:40]}" for k in unknown])
    p = dict(base or {})
    missing = [k for k in ("label", "host", "port", "security", "from_email") if k not in data and k not in p]
    if missing:
        raise LabError("invalid", "Champ(s) manquant(s).", reasons=[f"champ manquant : {k}" for k in missing])
    if "label" in data:
        p["label"] = _clean(data["label"], "label", 60).strip()
    if "host" in data:
        host = _clean(data["host"], "host", 253).strip().rstrip(".")
        if not HOST_RE.fullmatch(host):
            raise LabError("invalid", "host : nom d'hôte ou adresse IPv4 attendu.")
        p["host"] = host.lower()
    if "port" in data:
        port = data["port"]
        if isinstance(port, bool) or not isinstance(port, int) or not 1 <= port <= 65535:
            raise LabError("invalid", "port : entier de 1 à 65535.")
        p["port"] = port
    if "security" in data:
        if data["security"] not in SECURITIES:
            raise LabError("invalid", "security : « starttls », « ssl » ou « none ».")
        p["security"] = data["security"]
    # ASCII imprimable seulement pour les identifiants : smtplib (ici comme dans Django) les encode
    # en ASCII et lèverait UnicodeEncodeError sur un accent ; app-smtp.sh les refuse aussi.
    for name, limit in (("username", 254), ("password", 1024)):
        if name in data:
            value = _clean(data[name], name, limit, allow_empty=True)
            if any(not 32 <= ord(ch) <= 126 for ch in value):
                raise LabError("invalid", f"{name} : caractères ASCII imprimables seulement (pas d'accent ni de "
                                          "caractère spécial hors ASCII).")
            p[name] = value
    if "from_email" in data:
        sender = _clean(data["from_email"], "from_email", 320).strip()
        if not EMAIL_RE.fullmatch(sender):
            raise LabError("invalid", "from_email : adresse email attendue.")
        p["from_email"] = sender
    p.setdefault("username", "")
    p.setdefault("password", "")
    p.pop("rev", None)                      # le compteur de version n'est pas un champ du profil
    if p["security"] == "none" and (p["username"] or p["password"]):
        raise LabError("invalid", "security « none » n'est accepté que sans identifiant ni mot de passe : "
                                  "jamais d'identifiants en clair sur le réseau.")
    if p["password"] and not p["username"]:
        raise LabError("invalid", "username : obligatoire quand un mot de passe est donné.")
    return p


class Store:
    """`<LAB_STATE_DIR>/smtp/<uid>.json` — {"profiles": {<id>: {…, "password"}}}, mode 600."""

    def __init__(self, state_dir) -> None:
        self._state_dir = state_dir     # fonction : le dossier d'état se relit comme le registre

    def _path(self, uid: str) -> str:
        if not valid_uid(uid):
            raise LabError("invalid", "uid invalide.")
        return os.path.join(self._state_dir(), "smtp", uid + ".json")

    def read(self, uid: str) -> dict:
        """{"profiles": {<id>: profil}, "applied": {<app>: {"profile", "rev", "written_at", "applied_at"}}}.

        `rev` d'un profil : compteur incrémenté à chaque modification — c'est lui, et rien de dérivé
        du secret, qui dit si un projet tourne avec une ancienne version du profil.
        """
        try:
            with open(self._path(uid), encoding="utf-8") as fh:
                data = json.load(fh)
        except FileNotFoundError:
            data = {}
        except (OSError, ValueError):
            # Le contenu n'est jamais cité : il porte des secrets.
            raise LabError("failed", "Profils SMTP illisibles sur le lab.") from None
        profiles = data.get("profiles") if isinstance(data, dict) else None
        applied = data.get("applied") if isinstance(data, dict) else None
        return {
            "profiles": {k: v for k, v in profiles.items() if ID_RE.fullmatch(k) and isinstance(v, dict)}
            if isinstance(profiles, dict) else {},
            "applied": {k: v for k, v in applied.items() if isinstance(v, dict)} if isinstance(applied, dict) else {},
        }

    def load(self, uid: str) -> dict[str, dict]:
        return self.read(uid)["profiles"]

    def write(self, uid: str, doc: dict) -> None:
        path = self._path(uid)
        os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
        tmp = f"{path}.{secrets.token_hex(4)}.tmp"
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as fh:
                json.dump({"profiles": doc.get("profiles") or {}, "applied": doc.get("applied") or {}},
                          fh, ensure_ascii=False)
            os.replace(tmp, path)
        except OSError:
            try:
                os.unlink(tmp)
            except OSError:
                pass
            raise LabError("failed", "Écriture des profils SMTP impossible sur le lab.") from None

    @staticmethod
    def new_id(existing: dict) -> str:
        while True:
            pid = secrets.token_hex(4)
            if pid not in existing:
                return pid


# ─────────────────────────────────────────────────────────────────────────────
# Email d'essai
# ─────────────────────────────────────────────────────────────────────────────
def _public_address(host: str, port: int) -> str:
    """Résout l'hôte UNE fois et rend une adresse publique, ou refuse."""
    try:
        infos = socket.getaddrinfo(host, port, type=socket.SOCK_STREAM)
    except OSError:
        raise LabError("smtp_error", f"Hôte SMTP introuvable : {host}") from None
    for family, _, _, _, sockaddr in sorted(infos, key=lambda i: i[0] != socket.AF_INET):
        ip = ipaddress.ip_address(sockaddr[0])
        if _address_allowed(ip):
            return sockaddr[0]
    raise LabError("invalid", "Cet hôte désigne une adresse interne : l'email d'essai ne part que vers un "
                              "serveur SMTP joignable par Internet.")


def _address_allowed(ip) -> bool:
    return ip.is_global and not ip.is_multicast


def _scrub(text: str, profile: dict) -> str:
    """Efface du texte toute forme du secret : en clair, et telle qu'elle voyage dans AUTH."""
    pw, user = profile.get("password") or "", profile.get("username") or ""
    if pw:
        forms = {pw, base64.b64encode(pw.encode()).decode(),
                 base64.b64encode(f"\0{user}\0{pw}".encode()).decode()}
        for form in sorted(forms, key=len, reverse=True):
            if form and len(form) >= 4:
                text = text.replace(form, "***")
    text = re.sub(r"(?i)\bAUTH\s+(PLAIN|LOGIN|CRAM-MD5|XOAUTH2)\s+\S+", r"AUTH \1 ***", text)
    return re.sub(r"\s+", " ", text).strip()[:400]


def _failure(exc: BaseException, profile: dict, stage: str) -> LabError:
    """De l'exception, on ne garde QUE ce que le serveur a répondu (code + texte), jamais son repr."""
    def said(code: object, msg: object) -> str:
        text = msg.decode("utf-8", "replace") if isinstance(msg, (bytes, bytearray)) else str(msg)
        return f"{code} {text}"

    if isinstance(exc, smtplib.SMTPAuthenticationError):
        detail = "authentification refusée par le serveur : " + said(exc.smtp_code, exc.smtp_error)
    elif isinstance(exc, smtplib.SMTPRecipientsRefused):
        code, msg = next(iter(exc.recipients.values()), (0, b""))
        detail = "destinataire refusé par le serveur : " + said(code, msg)
    elif isinstance(exc, smtplib.SMTPSenderRefused):
        detail = "expéditeur (from_email) refusé par le serveur : " + said(exc.smtp_code, exc.smtp_error)
    elif isinstance(exc, smtplib.SMTPResponseException):
        detail = f"refus du serveur ({stage}) : " + said(exc.smtp_code, exc.smtp_error)
    elif isinstance(exc, smtplib.SMTPNotSupportedError):
        detail = f"le serveur ne propose pas ce qui est demandé ({stage}) — vérifiez « security » et le port"
    elif isinstance(exc, smtplib.SMTPServerDisconnected):
        detail = f"le serveur a fermé la connexion ({stage}) — vérifiez « security » et le port"
    elif isinstance(exc, ssl.SSLCertVerificationError):
        detail = "certificat du serveur refusé : " + str(exc.verify_message or "non vérifiable")
    elif isinstance(exc, ssl.SSLError):
        detail = f"échec de la négociation TLS ({stage}) — vérifiez « security » et le port"
    elif isinstance(exc, (socket.timeout, TimeoutError)):
        detail = f"délai dépassé ({stage}) : le serveur ne répond pas"
    elif isinstance(exc, ConnectionRefusedError):
        detail = "connexion refusée par l'hôte sur ce port"
    elif isinstance(exc, OSError):
        detail = f"connexion impossible ({stage}) : {exc.strerror or type(exc).__name__}"
    else:
        detail = f"échec de l'envoi ({stage}) : {type(exc).__name__}"
    return LabError("smtp_error", _scrub(detail, profile))


def send_test(profile: dict, to: str, label: str, domain: str) -> None:
    """Bloquant (à lancer dans un fil). Envoie UN message à `to` avec ce profil, ou lève `smtp_error`."""
    host, port, security = profile["host"], profile["port"], profile["security"]
    address = _public_address(host, port)
    deadline = time.monotonic() + TEST_DEADLINE_S

    def left() -> float:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError()
        return min(remaining, 10.0)

    class _Pinned:
        """La connexion va à l'adresse déjà contrôlée ; le NOM reste celui du profil pour le certificat."""
        def _get_socket(self, _host, port_, timeout):            # noqa: ANN001
            sock = socket.create_connection((address, port_), timeout)
            if isinstance(self, smtplib.SMTP_SSL):
                sock = self.context.wrap_socket(sock, server_hostname=host)
            return sock

    class Plain(_Pinned, smtplib.SMTP):
        pass

    class Tls(_Pinned, smtplib.SMTP_SSL):
        pass

    context = ssl.create_default_context()
    message = EmailMessage()
    message["From"] = profile["from_email"]
    message["To"] = to
    message["Subject"] = f"Essai du profil SMTP « {label} » — lab"
    message["Date"] = formatdate(localtime=False)
    message["Message-ID"] = make_msgid(domain=domain)
    message.set_content(
        f"Ceci est l'email d'essai du profil SMTP « {label} » ({host}:{port}, {security}).\n"
        "Il a été demandé depuis lab-admin et n'est envoyé qu'à l'adresse de votre compte du lab.\n"
        "Si vous le lisez, ce profil fonctionne.\n")

    stage = "connexion"
    client = None
    try:
        client = (Tls(host, port, timeout=left(), context=context) if security == "ssl"
                  else Plain(host, port, timeout=left()))
        stage = "présentation (EHLO)"
        client.ehlo()
        if security == "starttls":
            stage = "STARTTLS"
            client.sock.settimeout(left())
            client.starttls(context=context)
            client.ehlo()
        if profile.get("username"):
            stage = "authentification"
            client.sock.settimeout(left())
            client.login(profile["username"], profile.get("password") or "")
        stage = "envoi"
        client.sock.settimeout(left())
        client.send_message(message, from_addr=profile["from_email"], to_addrs=[to])
    except LabError:
        raise
    except BaseException as exc:                         # rien de smtplib ne remonte tel quel
        raise _failure(exc, profile, stage) from None
    finally:
        if client is not None:
            try:
                client.close()
            except Exception:
                pass
