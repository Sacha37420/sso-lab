"""Graine de création d'un projet (chantier « app-builder-lab », contrat v1, I2).

`POST /projects` et l'outil MCP `create_app` acceptent un champ facultatif

    "seed": {"lots_md": "## Lot 2 — …", "cahier_des_charges_md": "# Cahier des charges — …"}

Avec lui, après `new-app.sh` et avant `app-register.sh` (donc dans le premier
commit), la chaîne de création :
  1. garde de `FEUILLE_DE_ROUTE.md` tout ce qui précède la première ligne
     commençant par « ## Lot 2 — » (en-tête, « Commande de test », Lot 1 du
     gabarit) et remplace le reste par `lots_md` ;
  2. écrit `CAHIER_DES_CHARGES.md` à la racine du projet.

CE MODULE NE FAIT QUE DEUX CHOSES — dire si une graine est recevable
(`validate`), et l'écrire dans un dossier de projet (`apply`). Il n'importe rien
du moteur : il est joué tel quel par le serveur (refus immédiat, avant toute
création) ET par la chaîne (revalidation sous le verrou, puis écriture).

Ce qui tient la sûreté, à ne pas assouplir :
  • les deux noms de fichier sont des CONSTANTES. Aucun chemin ne vient de
    l'appelant ; ni l'un ni l'autre n'est suivi s'il est un lien symbolique ;
  • dans `lots_md`, TOUTE ligne commençant par « # » est un titre de lot au
    statut « à faire ». Une graine ne peut donc pas poser un titre « ## Commande
    de test » (la commande que le lab exécute vient du gabarit, jamais d'une
    graine), ni un lot déjà « livré », ni un titre de premier niveau ;
  • les lignes se coupent sur « \\n » SEUL, comme le font `grep` et `awk` dans
    `validate-app.sh` et `app-test.sh` — jamais `str.splitlines()`, qui coupe
    aussi sur douze autres séparateurs et verrait des lignes que les scripts du
    lab ne voient pas (ou l'inverse) ;
  • aucune raison de refus ne cite le contenu de la graine : seulement le champ,
    un numéro de ligne, un nombre.
"""
from __future__ import annotations

import os
import re

ROADMAP_FILE = "FEUILLE_DE_ROUTE.md"
CAHIER_FILE = "CAHIER_DES_CHARGES.md"
KEYS = ("lots_md", "cahier_des_charges_md")
MAX_CHARS = {"lots_md": 100_000, "cahier_des_charges_md": 200_000}
MAX_LOTS = 40
FIRST_LOT = 2
CUT_PREFIX = "## Lot 2 — "   # première ligne remplacée dans la feuille de route du gabarit
MAX_REASONS = 20

# [[:space:]] de POSIX, moins « \n » (séparateur de ligne) et « \r » (interdit plus haut).
_SPACE = " \t\v\f"
# ^## Lot ([0-9]+) — .+·[[:space:]]*statut : à faire[[:space:]]*$   (I2), appliquée ligne à ligne.
_TITLE = re.compile(rf"## Lot ([0-9]+) — [^\n]+·[{_SPACE}]*statut : à faire[{_SPACE}]*")
# L'expression de scripts/validate-app.sh (porte « feuille-de-route ») : le résultat doit la passer.
_ANY_LOT = re.compile(rf"## Lot [0-9]+ — [^\n]+·[{_SPACE}]*statut : (à faire|en cours|livré)[{_SPACE}]*")


class SeedError(Exception):
    """L'écriture de la graine est impossible (gabarit modifié, fichier inattendu). Message sans contenu."""


def validate(seed: object) -> list[str]:
    """Raisons de refus d'une graine (liste vide = recevable). Ne lève jamais."""
    if not isinstance(seed, dict):
        return ["seed : un objet {\"lots_md\", \"cahier_des_charges_md\"} est attendu"]
    reasons: list[str] = []
    unknown = [k for k in seed if k not in KEYS]
    if unknown:
        reasons.append(f"seed : {len(unknown)} clé(s) non admise(s) — seules « lots_md » et "
                       "« cahier_des_charges_md » le sont")
    usable: dict[str, str] = {}
    for key in KEYS:
        if key not in seed:
            reasons.append(f"seed.{key} : champ manquant")
            continue
        value = seed[key]
        if not isinstance(value, str) or not value:
            reasons.append(f"seed.{key} : une chaîne non vide est attendue")
            continue
        ok = True
        if len(value) > MAX_CHARS[key]:
            reasons.append(f"seed.{key} : {len(value)} caractères, {MAX_CHARS[key]} au plus")
            ok = False
        if "\x00" in value:
            reasons.append(f"seed.{key} : octet nul interdit")
            ok = False
        if "\r" in value:
            reasons.append(f"seed.{key} : retour chariot (\\r) interdit — fins de ligne « \\n » seulement")
            ok = False
        try:
            value.encode("utf-8")
        except UnicodeEncodeError:
            reasons.append(f"seed.{key} : texte non encodable en UTF-8 (demi-codet isolé)")
            ok = False
        if ok:
            usable[key] = value
    if "lots_md" in usable:
        reasons.extend(_lots_reasons(usable["lots_md"]))
    return reasons


def _lots_reasons(lots_md: str) -> list[str]:
    reasons: list[str] = []
    more = 0

    def add(text: str) -> None:
        nonlocal more
        if len(reasons) < MAX_REASONS:
            reasons.append(text)
        else:
            more += 1

    lots = 0
    first_seen = False
    expected = FIRST_LOT
    for number, line in enumerate(lots_md.split("\n"), start=1):
        is_title = line.startswith("#")
        if not first_seen and line.strip(_SPACE):
            first_seen = True
            if not is_title:
                add(f"seed.lots_md, ligne {number} : la première ligne non vide doit être un titre de lot "
                    f"« ## Lot {FIRST_LOT} — <titre>   ·   statut : à faire »")
        if not is_title:
            continue
        found = _TITLE.fullmatch(line)
        if not found:
            add(f"seed.lots_md, ligne {number} : une ligne commençant par « # » doit être un titre de lot "
                "« ## Lot <N> — <titre>   ·   statut : à faire » (aucun autre titre, aucun autre statut)")
            continue
        lots += 1
        # Comparaison de texte, pas int() : un numéro de 100 000 chiffres ne doit rien coûter.
        if (found.group(1).lstrip("0") or "0") != str(expected):
            add(f"seed.lots_md, ligne {number} : le lot attendu ici est le Lot {expected} "
                f"(numéros qui se suivent à partir de {FIRST_LOT})")
        expected += 1
    if lots == 0:
        add("seed.lots_md : aucun lot — au moins un titre « ## Lot 2 — <titre>   ·   statut : à faire »")
    if lots > MAX_LOTS:
        add(f"seed.lots_md : {lots} lots, {MAX_LOTS} au plus")
    if more:
        reasons.append(f"seed.lots_md : … et {more} autre(s) défaut(s)")
    return reasons


def count_lots(lots_md: str) -> int:
    return sum(1 for line in lots_md.split("\n") if _TITLE.fullmatch(line))


def merge_roadmap(current: str, lots_md: str) -> str:
    """La feuille de route du gabarit, ses lots métier remplacés par ceux de la graine."""
    lines = current.split("\n")
    for index, line in enumerate(lines):
        if line.startswith(CUT_PREFIX):
            head = "\n".join(lines[:index])
            merged = (head + "\n" if index else "") + lots_md
            break
    else:
        raise SeedError(f"{ROADMAP_FILE} du projet scaffoldé n'a aucune ligne commençant par « {CUT_PREFIX}» : "
                        "le gabarit a changé, la graine ne peut pas y être posée")
    if not any(_ANY_LOT.fullmatch(line) for line in merged.split("\n")):
        raise SeedError(f"{ROADMAP_FILE} obtenu ne passerait pas la porte « feuille-de-route » de validate-app.sh")
    return merged


def _write(path: str, text: str, *, must_exist: bool) -> None:
    """Écrit un fichier ordinaire, sans jamais suivre un lien symbolique."""
    flags = os.O_WRONLY | os.O_TRUNC | os.O_NOFOLLOW | getattr(os, "O_CLOEXEC", 0)
    if not must_exist:
        flags |= os.O_CREAT
    fd = os.open(path, flags, 0o644)
    with os.fdopen(fd, "w", encoding="utf-8", newline="") as fh:
        fh.write(text)


def apply(app_dir: str, seed: dict) -> dict:
    """Pose la graine dans le dossier d'un projet qui vient d'être scaffoldé.

    Rend `{"lots": N}`. Lève `SeedError` (message sans contenu de la graine) si la
    graine n'est pas recevable ou si le dossier n'a pas la forme attendue. La
    feuille de route n'est réécrite que si tout le reste est possible.
    """
    if validate(seed):
        raise SeedError("graine non recevable")
    if os.path.islink(app_dir) or not os.path.isdir(app_dir):
        raise SeedError("dossier du projet introuvable après le scaffold")
    roadmap = os.path.join(app_dir, ROADMAP_FILE)
    cahier = os.path.join(app_dir, CAHIER_FILE)
    if os.path.islink(roadmap) or not os.path.isfile(roadmap):
        raise SeedError(f"{ROADMAP_FILE} absent du projet scaffoldé (ou lien symbolique)")
    if os.path.islink(cahier) or (os.path.exists(cahier) and not os.path.isfile(cahier)):
        raise SeedError(f"{CAHIER_FILE} existe déjà dans le projet scaffoldé et n'est pas un fichier ordinaire")
    try:
        with open(roadmap, encoding="utf-8", newline="") as fh:
            current = fh.read()
    except (OSError, UnicodeDecodeError) as exc:
        raise SeedError(f"{ROADMAP_FILE} illisible ({type(exc).__name__})") from None
    merged = merge_roadmap(current, seed["lots_md"])
    try:
        _write(cahier, seed["cahier_des_charges_md"], must_exist=False)
        _write(roadmap, merged, must_exist=True)
    except OSError as exc:
        raise SeedError(f"écriture impossible ({type(exc).__name__}, errno {exc.errno})") from None
    return {"lots": count_lots(seed["lots_md"])}
