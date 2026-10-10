#!/usr/bin/env python3
"""Pose les règles du lab dans un fichier d'instructions (CLAUDE.md, AGENTS.md).

Usage : bloc_regles.py <fichier cible> <fichier source des règles>

Les règles sont écrites dans un BLOC BALISÉ. Ce qui est hors du bloc appartient
au dev et n'est jamais modifié : il peut ajouter ses propres consignes avant ou
après. Le bloc, lui, est remplacé à chaque ouverture de l'espace — le modifier
à la main ne sert à rien.

Idempotent : si le contenu obtenu est identique à l'existant, rien n'est écrit.
Sortie : « écrit » ou « inchangé » sur stdout, code 0 ; code 1 sur erreur.
"""
from __future__ import annotations

import os
import sys
import tempfile
from pathlib import Path

DEBUT = "<!-- LAB:REGLES:DEBUT — bloc géré par le lab, réécrit à chaque ouverture de l'espace : ne pas modifier -->"
FIN = "<!-- LAB:REGLES:FIN -->"


def composer(existant: str, regles: str) -> str:
    bloc = f"{DEBUT}\n{regles.strip()}\n{FIN}\n"
    i = existant.find(DEBUT.split(" — ")[0])  # tolère une ancienne formulation de la balise
    j = existant.find(FIN)
    if i != -1 and j != -1 and j > i:
        fin_ligne = existant.find("\n", j)
        apres = "" if fin_ligne == -1 else existant[fin_ligne + 1 :]
        return existant[:i] + bloc + apres
    if existant.strip():
        # Fichier du dev sans bloc : les règles du lab passent devant, son texte est conservé.
        return bloc + "\n" + existant
    return bloc


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__, file=sys.stderr)
        return 1
    cible, source = Path(sys.argv[1]), Path(sys.argv[2])
    regles = source.read_text(encoding="utf-8")
    try:
        existant = cible.read_text(encoding="utf-8")
    except FileNotFoundError:
        existant = ""
    nouveau = composer(existant, regles)
    if nouveau == existant:
        print("inchangé")
        return 0
    cible.parent.mkdir(parents=True, exist_ok=True)
    # Écriture atomique : jamais de fichier d'instructions à moitié écrit.
    fd, tmp = tempfile.mkstemp(dir=cible.parent, prefix=f".{cible.name}.")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(nouveau)
        os.chmod(tmp, 0o644)
        os.replace(tmp, cible)
    except BaseException:
        Path(tmp).unlink(missing_ok=True)
        raise
    print("écrit")
    return 0


if __name__ == "__main__":
    sys.exit(main())
