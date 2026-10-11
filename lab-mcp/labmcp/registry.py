"""Registre des développeurs et des apps — lecture seule (contrat I1).

Miroir de `scripts/lib/registry.sh`, pour un consommateur hors shell : les trois
fichiers `.devs`, `.owners`, `.ports` sont RELUS À CHAQUE APPEL. Aucun cache :
retirer un dev de `.devs` doit le couper à la requête suivante, pas au prochain
redémarrage du conteneur.

Toute règle ci-dessous existe dans registry.sh ; si l'une des deux
implémentations bouge, l'autre doit suivre (les scripts font foi).
"""
from __future__ import annotations

import os
import re

UID_RE = re.compile(r"^[a-z][a-z0-9]{1,30}$")
# Nom utilisable comme dossier de $ROOT (registry_valid_app) : ne peut pas
# sortir de la racine (« .. », « / »).
APP_RE = re.compile(r"^[a-z0-9][a-z0-9_-]{0,62}$")


def valid_uid(uid: object) -> bool:
    return isinstance(uid, str) and UID_RE.fullmatch(uid) is not None


def valid_app(app: object) -> bool:
    return isinstance(app, str) and APP_RE.fullmatch(app) is not None


class Registry:
    def __init__(self, root: str) -> None:
        self.root = root

    # ── fichiers ────────────────────────────────────────────────────────────
    def _lines(self, name: str) -> list[str]:
        try:
            with open(os.path.join(self.root, name), encoding="utf-8") as fh:
                raw = fh.read().splitlines()
        except FileNotFoundError:
            return []
        return [ln for ln in raw if ln.strip() and not ln.lstrip().startswith("#")]

    def _root_env(self, key: str) -> str:
        """Dernière occurrence de `key` dans le .env racine (comme registry_root_env)."""
        value = ""
        try:
            with open(os.path.join(self.root, ".env"), encoding="utf-8") as fh:
                for line in fh:
                    m = re.match(rf"^{re.escape(key)}\s*=(.*)$", line.rstrip("\n"))
                    if m:
                        v = re.sub(r"\s*#.*$", "", m.group(1)).strip()
                        value = v.strip("'\"")
        except FileNotFoundError:
            pass
        return value

    # ── développeurs ────────────────────────────────────────────────────────
    def superuser(self) -> str:
        # Même priorité que registry.sh : environnement > .env racine > « sacha ».
        return os.environ.get("LAB_SUPERUSER", "").strip() or self._root_env("LAB_SUPERUSER") or "sacha"

    def is_superuser(self, uid: str) -> bool:
        return bool(uid) and uid == self.superuser()

    def is_dev(self, uid: str) -> bool:
        """Être dans `.devs` est la SEULE définition de « développeur inscrit »."""
        if not valid_uid(uid):
            return False
        return uid in self._lines(".devs")  # égalité de ligne entière, comme grep -xF

    # ── apps ────────────────────────────────────────────────────────────────
    def ports(self) -> dict[str, tuple[str, str]]:
        out: dict[str, tuple[str, str]] = {}
        for line in self._lines(".ports"):
            parts = line.split(":")
            if valid_app(parts[0]):
                out[parts[0]] = (parts[1] if len(parts) > 1 else "", parts[2] if len(parts) > 2 else "")
        return out

    def app_dir(self, app: str) -> str:
        """`$ROOT/deploiement/<app>` s'il existe, sinon `$ROOT/<app>` (transition v5, I1)."""
        deployed = os.path.join(self.root, "deploiement", app)
        return deployed if os.path.isdir(deployed) else os.path.join(self.root, app)

    def in_deploiement(self, app: str) -> bool:
        return os.path.isdir(os.path.join(self.root, "deploiement", app))

    def state_dir(self) -> str:
        # Même priorité que registry_state_dir : environnement > .env racine > <racine>/.lab-state
        return (os.environ.get("LAB_STATE_DIR", "").strip() or self._root_env("LAB_STATE_DIR")
                or os.path.join(self.root, ".lab-state"))

    def all_apps(self) -> list[str]:
        """Entrées de `.ports` dont le dossier porte un docker-compose.yml."""
        return sorted(
            app for app in self.ports()
            if os.path.isfile(os.path.join(self.app_dir(app), "docker-compose.yml"))
        )

    def devs(self) -> list[str]:
        return [u for u in self._lines(".devs") if valid_uid(u)]

    def app_env(self, app: str, key: str) -> str:
        """Une clé du `.env` déployé de l'app (lecture seule — sert à savoir sur
        quelle instance PostgreSQL et dans quel schéma vit le projet)."""
        value = ""
        try:
            with open(os.path.join(self.app_dir(app), ".env"), encoding="utf-8") as fh:
                for line in fh:
                    if line.startswith(key + "="):
                        value = line[len(key) + 1:].strip().strip("'\"")
        except OSError:
            pass
        return value

    def showcase(self) -> dict[str, str]:
        """Vitrine publique : `.app-descriptions`, une ligne NON commentée par app —
        `dossier | Nom affiché | Description | [lien]`. Rend {dossier: description}."""
        out: dict[str, str] = {}
        for line in self._lines(".app-descriptions"):
            parts = [p.strip() for p in line.split("|")]
            if valid_app(parts[0]):
                out[parts[0]] = parts[2] if len(parts) > 2 else ""
        return out

    def has_spec(self, app: str) -> bool:
        return os.path.isfile(os.path.join(self.app_dir(app), "frontend", "e2e", "cloisonnement.spec.ts"))

    def lab_groups(self) -> list[str]:
        """Noms des groupes du lab, lus dans sso-lab/ldap/init.ldif (aucun
        identifiant d'administration utilisé, rien d'autre de l'annuaire)."""
        names: list[str] = []
        try:
            with open(os.path.join(self.root, "sso-lab", "ldap", "init.ldif"), encoding="utf-8") as fh:
                for line in fh:
                    m = re.match(r"^dn:\s*cn=([A-Za-z0-9_-]+),ou=groups,", line)
                    if m and m.group(1) not in names:
                        names.append(m.group(1))
        except OSError:
            pass
        return names

    def app_exists(self, app: str) -> bool:
        return valid_app(app) and app in self.all_apps()

    def has_owner_line(self, app: str) -> bool:
        return any(line.split(":")[0] == app for line in self._lines(".owners"))

    def app_owner(self, app: str) -> str:
        """Ligne `<app>:<uid>` de `.owners`, sinon le superutilisateur.

        Une app inconnue, ou dont la ligne porte un uid malformé, appartient au
        superutilisateur : c'est le défaut sûr, un contrôle « propriétaire ==
        appelant » refuse alors tout dev.
        """
        owner = ""
        for line in self._lines(".owners"):
            parts = line.split(":")
            if parts[0] == app and len(parts) > 1:
                owner = parts[1]
        return owner if valid_uid(owner) else self.superuser()

    def apps_of(self, uid: str) -> list[str]:
        return [app for app in self.all_apps() if self.app_owner(app) == uid]

    def repo_url(self, app: str) -> str:
        """URL `origin` de l'app, lue dans `.gitmodules` (écrit par app-register.sh).

        Lecture de fichier, pas d'appel à git : le serveur ne compose jamais de
        commande git lui-même (contrat I4).
        """
        section = False
        try:
            with open(os.path.join(self.root, ".gitmodules"), encoding="utf-8") as fh:
                for line in fh:
                    head = re.match(r'^\s*\[submodule "(.*)"\]\s*$', line)
                    if head:
                        # v5 : un projet né dans deploiement/ y est inscrit sous ce chemin.
                        section = head.group(1) in (app, f"deploiement/{app}")
                        continue
                    if section:
                        m = re.match(r"^\s*url\s*=\s*(\S+)\s*$", line)
                        if m:
                            return m.group(1)
        except FileNotFoundError:
            pass
        return ""
