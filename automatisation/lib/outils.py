#!/usr/bin/env python3
"""Outils internes du moteur de nuit (automatisation/bin/auto.sh) — bibliothèque standard seule.

Contrat chantiers/nuit-auto/CONTRAT.md v1 (I2, I4, I5, I6, I7). Chaque sous-commande est
appelée par les scripts bash du moteur, toujours sous `timeout` et l'entrée standard sur
/dev/null (sauf `scrub`, qui filtre son entrée). Aucune sous-commande n'écrit un secret sur
stdout ou stderr : les jetons arrivent par l'environnement (AUTO_GH_TOKEN, SMTP_PASSWORD) et
n'en sortent pas.

Lecture d'un fichier écrit par Claude (/sortie, correctif) : toujours par `lire_sur()` —
O_NOFOLLOW, fichier ordinaire, taille bornée. Un lien symbolique posé dans /sortie vers un
fichier de l'hôte (un .env…) ne doit jamais être suivi : son contenu partirait dans une PR
publique.
"""
from __future__ import annotations

import base64
import datetime as dt
import fnmatch
import json
import os
import re
import secrets
import stat
import string
import sys
import urllib.error
import urllib.request
import uuid

# ─── utilitaires ────────────────────────────────────────────────────────────────

def die(msg: str, code: int = 1) -> None:
    print(f"outils : {msg}", file=sys.stderr)
    sys.exit(code)


def lire_sur(path: str, maxbytes: int) -> bytes:
    """Lit un fichier ordinaire sans suivre de lien, taille bornée. Lève OSError/ValueError."""
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | getattr(os, "O_NOCTTY", 0))
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode):
            raise ValueError("pas un fichier ordinaire")
        if st.st_size > maxbytes:
            raise ValueError(f"trop gros ({st.st_size} octets > {maxbytes})")
        chunks, total = [], 0
        while True:
            b = os.read(fd, 65536)
            if not b:
                break
            total += len(b)
            if total > maxbytes:
                raise ValueError("trop gros")
            chunks.append(b)
        return b"".join(chunks)
    finally:
        os.close(fd)


def ecrire_atomique(path: str, data: str, mode: int = 0o600) -> None:
    tmp = f"{path}.tmp{os.getpid()}"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, mode)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(data)
    os.replace(tmp, path)


def maintenant() -> str:
    return dt.datetime.now().astimezone().isoformat(timespec="seconds")


# ─── I2 : calendrier ───────────────────────────────────────────────────────────

TACHE_RE = re.compile(r"^[a-z][a-z0-9-]{0,30}$")
CIBLE_RE = re.compile(r"^(_racine|[a-z0-9][a-z0-9_-]{0,62})$")


def lire_calendrier(path: str) -> dict[int, tuple[str, str]]:
    try:
        texte = lire_sur(path, 64 * 1024).decode("utf-8")
    except (OSError, ValueError, UnicodeDecodeError) as e:
        raise ValueError(f"calendrier illisible ({path}) : {e}")
    jours: dict[int, tuple[str, str]] = {}
    for n, ligne in enumerate(texte.splitlines(), 1):
        ligne = ligne.strip()
        if not ligne or ligne.startswith("#"):
            continue
        champs = ligne.split()
        if len(champs) != 3:
            raise ValueError(f"ligne {n} : trois champs attendus (jour tache cibles)")
        jour, tache, cibles = champs
        if not re.fullmatch(r"[1-7]", jour):
            raise ValueError(f"ligne {n} : jour ISO 1 à 7 attendu, lu « {jour} »")
        if not TACHE_RE.fullmatch(tache) or tache.startswith("_"):
            raise ValueError(f"ligne {n} : nom de tâche invalide « {tache} »")
        m = re.fullmatch(r"rotation:([1-9][0-9]?)", cibles)
        if not m:
            for c in cibles.split(","):
                if not CIBLE_RE.fullmatch(c):
                    raise ValueError(f"ligne {n} : cible invalide « {c} »")
        if int(jour) in jours:
            raise ValueError(f"ligne {n} : jour {jour} déjà défini")
        jours[int(jour)] = (tache, cibles)
    return jours


def cmd_calendrier(args: list[str]) -> None:
    """calendrier <fichier> <jour ISO> → « tache<TAB>cibles », code 3 si aucun passage ce jour."""
    path, jour = args
    try:
        jours = lire_calendrier(path)
    except ValueError as e:
        die(str(e), 2)
    if int(jour) not in jours:
        sys.exit(3)
    t, c = jours[int(jour)]
    print(f"{t}\t{c}")


def cmd_calendrier_taches(args: list[str]) -> None:
    """calendrier-taches <fichier> → une ligne « jour tache cibles » par jour ; code 2 si mal formé."""
    try:
        jours = lire_calendrier(args[0])
    except ValueError as e:
        die(str(e), 2)
    for j in sorted(jours):
        print(f"{j}\t{jours[j][0]}\t{jours[j][1]}")


def cmd_tache_cibles(args: list[str]) -> None:
    """tache-cibles <fichier> <tache> → la spécification de cibles de cette tâche (premier jour)."""
    try:
        jours = lire_calendrier(args[0])
    except ValueError as e:
        die(str(e), 2)
    for j in sorted(jours):
        if jours[j][0] == args[1]:
            print(jours[j][1])
            return
    sys.exit(3)


# ─── I6 : etat.json ────────────────────────────────────────────────────────────

ETAT_CHAMPS = ("tache", "date", "phase", "statut", "session_id", "debut", "fin", "pr", "detail")
PHASES = {"principale", "suite", "correction", "reprise"}
STATUTS = {"en_cours", "fini", "limite", "echec", "refuse", "manque"}


def cmd_etat(args: list[str]) -> None:
    """etat <fichier> [k=v]… [pr+=url] [debut=maintenant] [fin=maintenant] — fusion atomique."""
    path, sets = args[0], args[1:]
    etat = {"tache": "", "date": "", "phase": "principale", "statut": "en_cours",
            "session_id": "", "debut": "", "fin": "", "pr": [], "detail": ""}
    if os.path.exists(path):
        try:
            etat.update(json.loads(lire_sur(path, 1 << 20)))
        except (OSError, ValueError):
            pass
    for s in sets:
        if s.startswith("pr+="):
            url = s[4:]
            if url and url not in etat["pr"]:
                etat["pr"].append(url)
            continue
        k, _, v = s.partition("=")
        if k not in ETAT_CHAMPS or k == "pr":
            die(f"champ d'état inconnu : {k}", 2)
        if v == "maintenant" and k in ("debut", "fin"):
            v = maintenant()
        if k == "phase" and v not in PHASES:
            die(f"phase invalide : {v}", 2)
        if k == "statut" and v not in STATUTS:
            die(f"statut invalide : {v}", 2)
        if k == "detail":
            v = " ".join(v.split())[:300]
        etat[k] = v
    ecrire_atomique(path, json.dumps({k: etat[k] for k in ETAT_CHAMPS}, ensure_ascii=False) + "\n")


def cmd_etat_get(args: list[str]) -> None:
    """etat-get <fichier> <champ> → valeur (vide si absente)."""
    try:
        e = json.loads(lire_sur(args[0], 1 << 20))
    except (OSError, ValueError):
        return
    v = e.get(args[1], "")
    print("\n".join(v) if isinstance(v, list) else v)


def cmd_etat_liste(args: list[str]) -> None:
    """etat-liste <dossier runs> [--json] [n]."""
    runs = args[0]
    as_json = "--json" in args
    n = next((int(a) for a in args[1:] if a.isdigit()), 14)
    items = []
    if os.path.isdir(runs):
        for d in sorted(os.listdir(runs), reverse=True):
            p = os.path.join(runs, d, "etat.json")
            if os.path.isfile(p):
                try:
                    e = json.loads(lire_sur(p, 1 << 20))
                    e["passage"] = d
                    items.append(e)
                except (OSError, ValueError):
                    continue
            if len(items) >= n:
                break
    if as_json:
        print(json.dumps(items, ensure_ascii=False, indent=2))
        return
    if not items:
        print("Aucun passage enregistré.")
        return
    for e in items:
        pr = len(e.get("pr") or [])
        print(f"{e['passage']:<34} {e.get('statut',''):<9} phase={e.get('phase',''):<11} "
              f"PR={pr}  {e.get('detail','')}")
        for u in e.get("pr") or []:
            print(f"{'':<36}{u}")


# ─── résultat de Claude (sortie --output-format json) ──────────────────────────

LIMITE_RE = re.compile(r"limit|quota|rate|usage|credit|overloaded|capacit", re.I)


def cmd_claude_resultat(args: list[str]) -> None:
    """claude-resultat <stdout json> <code de sortie> <essai 0|1>
    → « statut<TAB>session_id<TAB>détail » ; statut ∈ ok|limite|echec."""
    path, rc, essai = args[0], int(args[1]), args[2] == "1"
    try:
        texte = lire_sur(path, 32 << 20).decode("utf-8", "replace")
    except (OSError, ValueError):
        texte = ""
    obj = None
    for ligne in reversed(texte.strip().splitlines()):
        ligne = ligne.strip()
        if ligne.startswith("{"):
            try:
                cand = json.loads(ligne)
            except ValueError:
                continue
            if isinstance(cand, dict) and cand.get("type") == "result":
                obj = cand
                break
    if obj is None:
        try:
            cand = json.loads(texte)
            if isinstance(cand, list):
                cand = next((c for c in reversed(cand) if isinstance(c, dict) and c.get("type") == "result"), None)
            if isinstance(cand, dict):
                obj = cand
        except ValueError:
            pass
    if rc in (124, 137):
        sid = (obj or {}).get("session_id", "")
        print(f"limite\t{sid}\tdélai atteint : session arrêtée par le moteur")
        return
    if obj is None:
        print(f"echec\t\tsortie de claude illisible (code {rc})")
        return
    sid = str(obj.get("session_id", ""))
    sub = str(obj.get("subtype", ""))
    res = " ".join(str(obj.get("result", "")).split())[:160]
    if not obj.get("is_error") and sub in ("", "success"):
        print(f"ok\t{sid}\tsession terminée ({obj.get('num_turns', '?')} tours)")
    elif sub == "error_max_turns" and essai:
        print(f"ok\t{sid}\tessai : nombre de tours maximal atteint")
    elif sub == "error_max_turns":
        print(f"limite\t{sid}\tnombre de tours maximal atteint")
    else:
        print(f"limite\t{sid}\tsession interrompue : {res or sub or 'is_error'}")


# ─── I4 : resume.json ──────────────────────────────────────────────────────────

GRAVITES = ("critique", "haute", "moyenne", "basse")


def valider_resume(obj) -> list[str]:
    err = []
    if not isinstance(obj, dict):
        return ["pas un objet JSON"]
    attendus = {"version", "statut", "charge", "titre_pr", "constats", "tests_ajoutes"}
    if set(obj) - attendus:
        err.append("champs inconnus : " + ", ".join(sorted(set(obj) - attendus)))
    if obj.get("version") != 1:
        err.append("version ≠ 1")
    if obj.get("statut") not in ("fini", "partiel"):
        err.append("statut invalide")
    if obj.get("charge") not in ("faible", "normale", "forte"):
        err.append("charge invalide")
    t = obj.get("titre_pr")
    if not isinstance(t, str) or not t.strip() or len(t) > 72 or "\n" in t or "\r" in t:
        err.append("titre_pr invalide (une ligne, 1 à 72 caractères)")
    c = obj.get("constats")
    if not isinstance(c, list):
        err.append("constats n'est pas une liste")
    else:
        for i, x in enumerate(c):
            if not isinstance(x, dict) or set(x) != {"gravite", "cible", "titre", "fichier", "corrige"}:
                err.append(f"constat {i} : champs attendus gravite, cible, titre, fichier, corrige")
                continue
            if x["gravite"] not in GRAVITES:
                err.append(f"constat {i} : gravité invalide")
            for k in ("cible", "titre", "fichier"):
                if not isinstance(x[k], str) or not x[k] or "\n" in x[k]:
                    err.append(f"constat {i} : {k} invalide")
            if not isinstance(x["corrige"], bool):
                err.append(f"constat {i} : corrige n'est pas un booléen")
    ta = obj.get("tests_ajoutes")
    if not isinstance(ta, int) or isinstance(ta, bool) or ta < 0:
        err.append("tests_ajoutes invalide")
    return err


def charger_resume(path: str) -> tuple[dict | None, list[str]]:
    try:
        obj = json.loads(lire_sur(path, 1 << 20).decode("utf-8"))
    except FileNotFoundError:
        return None, ["resume.json absent"]
    except (OSError, ValueError) as e:
        return None, [f"resume.json illisible : {e}"]
    err = valider_resume(obj)
    return (obj if not err else None), err


def cmd_resume(args: list[str]) -> None:
    """resume <fichier> <champ> → charge | titre_pr | statut | valide (code 0/1, raison sur stderr)."""
    obj, err = charger_resume(args[0])
    champ = args[1]
    if champ == "valide":
        if err:
            print("; ".join(err)[:300])
            sys.exit(1)
        return
    if obj is None:
        sys.exit(1)
    print(obj.get(champ, ""))


def cmd_resume_brouillon(args: list[str]) -> None:
    """resume-brouillon <fichier> <cible> → code 0 si un constat critique NON corrigé concerne
    cette cible (ou une cible inconnue de la mission), 1 sinon."""
    obj, _ = charger_resume(args[0])
    cible, connues = args[1], set(args[2:])
    if obj is None:
        sys.exit(1)
    for c in obj["constats"]:
        if c["gravite"] == "critique" and not c["corrige"] and (c["cible"] == cible or c["cible"] not in connues):
            sys.exit(0)
    sys.exit(1)


# ─── secrets : collecte, filtrage, détection ───────────────────────────────────

SECRET_KEY_RE = re.compile(r"(PASSWORD|PASSWD|SECRET|TOKEN)|(^|_)(KEY|KEYS|PW|PWD)($|_)|[A-Z]KEY$")
TOKEN_PATTERNS = [
    re.compile(r"sk-ant-[A-Za-z0-9_\-]{10,}"),
    re.compile(r"github_pat_[A-Za-z0-9_]{20,}"),
    re.compile(r"gh[pousr]_[A-Za-z0-9]{30,}"),
    re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----"),
]
IPV4_RE = re.compile(r"(?<![\d.])((?:25[0-5]|2[0-4]\d|1?\d?\d)(?:\.(?:25[0-5]|2[0-4]\d|1?\d?\d)){3})(?![\d.])")
IP_GARDEES = {"127.0.0.1", "0.0.0.0", "255.255.255.255"}


def cle_secrete(cle: str) -> bool:
    """Nom de variable qui porte un secret (I5 : *PASSWORD*|*SECRET*|*KEY*|*TOKEN*).
    « KEY » est pris comme MOT du nom (séparé par _), pas comme sous-chaîne : KEYCLOAK_URL
    ou KEYCLOAK_REQUIRED_GROUPS ne sont pas des secrets, et les rendre aléatoires casserait
    les tests de cloisonnement de toute app. KEYCLOAK_CLIENT_SECRET reste couvert par SECRET."""
    return bool(SECRET_KEY_RE.search(cle.upper()))


def lire_env(path: str) -> list[tuple[str, str]]:
    out = []
    try:
        texte = lire_sur(path, 1 << 20).decode("utf-8", "replace")
    except (OSError, ValueError):
        return out
    for ligne in texte.splitlines():
        m = re.match(r"^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=(.*)$", ligne)
        if not m:
            continue
        v = m.group(2).strip()
        if len(v) >= 2 and v[0] == v[-1] and v[0] in "'\"":
            v = v[1:-1]
        out.append((m.group(1), v))
    return out


def cmd_secrets_collecter(args: list[str]) -> None:
    """secrets-collecter <sortie> <fichier>… — valeurs à ne jamais publier : celles des clés
    secrètes des .env (≥ 8 caractères), toute adresse IPv4 qui y figure (hors boucle locale),
    et le contenu des fichiers de jetons passés après « -- ». Fichier de sortie en 600."""
    out, rest = args[0], args[1:]
    jetons = []
    if "--" in rest:
        i = rest.index("--")
        rest, jetons = rest[:i], rest[i + 1:]
    vals: set[str] = set()
    for f in rest:
        for k, v in lire_env(f):
            if cle_secrete(k) and len(v) >= 8:
                vals.add(v)
            for ip in IPV4_RE.findall(v):
                if ip not in IP_GARDEES and not ip.startswith("127."):
                    vals.add(ip)
    for f in jetons:
        try:
            v = lire_sur(f, 64 * 1024).decode("utf-8", "replace").strip()
        except (OSError, ValueError):
            continue
        if len(v) >= 8:
            vals.add(v)
    ecrire_atomique(out, "".join(json.dumps(v) + "\n" for v in sorted(vals, key=len, reverse=True)))


def charger_secrets(path: str) -> list[str]:
    try:
        return [json.loads(l) for l in lire_sur(path, 16 << 20).decode().splitlines() if l.strip()]
    except (OSError, ValueError):
        return []


def filtrer(texte: str, secrets_: list[str]) -> tuple[str, int]:
    n = 0
    for s in secrets_:
        if s and s in texte:
            n += texte.count(s)
            texte = texte.replace(s, "[retiré]")
    for p in TOKEN_PATTERNS:
        texte, k = p.subn("[retiré]", texte)
        n += k
    return texte, n


def cmd_scrub(args: list[str]) -> None:
    """scrub <fichier de secrets> : filtre stdin → stdout (journal, sorties de commandes)."""
    sec = charger_secrets(args[0])
    data = sys.stdin.buffer.read(64 << 20).decode("utf-8", "replace")
    data = re.sub(r"\x1b\[[0-9;?]*[A-Za-z]", "", data)
    sys.stdout.write(filtrer(data, sec)[0])


def cmd_contient_secret(args: list[str]) -> None:
    """contient-secret <fichier de secrets> <fichier> → code 0 (et nombre) si un secret y figure."""
    sec = charger_secrets(args[0])
    try:
        data = lire_sur(args[1], 64 << 20).decode("utf-8", "replace")
    except (OSError, ValueError) as e:
        print(f"illisible : {e}")
        sys.exit(0)
    _, n = filtrer(data, sec)
    if n:
        print(n)
        sys.exit(0)
    sys.exit(1)


def cmd_rapport(args: list[str]) -> None:
    """rapport <entrée /sortie/rapport.md> <sortie> <secrets> — lecture sûre, filtrage des
    secrets et des adresses IPv4 (hors boucle locale), 60 000 caractères au plus.
    Code 1 si le rapport est absent ou illisible. Affiche le nombre d'éléments retirés."""
    src, dst, secf = args
    try:
        texte = lire_sur(src, 4 << 20).decode("utf-8", "replace")
    except (OSError, ValueError) as e:
        print(f"rapport illisible : {e}", file=sys.stderr)
        sys.exit(1)
    texte, n = filtrer(texte, charger_secrets(secf))

    def ip(m):
        return m.group(0) if (m.group(1) in IP_GARDEES or m.group(1).startswith("127.")) else "[adresse]"
    texte = IPV4_RE.sub(ip, texte)
    if len(texte) > 60000:
        texte = texte[:59800] + "\n\n…(rapport tronqué à 60 000 caractères par le moteur)\n"
    ecrire_atomique(dst, texte, 0o644)
    print(n)


def cmd_env_assaini(args: list[str]) -> None:
    """env-assaini <.env de service> <sortie> [CLE=VALEUR]… — .env pour les tests (I5.3) :
    valeurs des clés secrètes remplacées par de l'aléa de même forme, clés d'email écartées
    (comme app-test.sh), guillemets retirés (docker --env-file ne les comprend pas), puis
    les surcharges passées en argument (base jetable). Fichier en 600."""
    src, dst, extra = args[0], args[1], args[2:]
    lignes = []
    for k, v in lire_env(src):
        if re.fullmatch(r"EMAIL_[A-Z_]+|DEFAULT_FROM_EMAIL|LAB_SMTP_PROFILE", k):
            continue
        if "\n" in v:
            continue
        if cle_secrete(k) and v:
            v = alea_meme_forme(v)
        lignes.append(f"{k}={v}")
    for e in extra:
        if "=" in e and "\n" not in e:
            lignes.append(e)
    ecrire_atomique(dst, "\n".join(lignes) + "\n")


def alea_meme_forme(v: str) -> str:
    if re.fullmatch(r"[A-Za-z0-9_-]{43}=", v):          # clé Fernet
        return base64.urlsafe_b64encode(os.urandom(32)).decode()
    if re.fullmatch(r"[0-9a-f]+", v):
        return secrets.token_hex((len(v) + 1) // 2)[:len(v)]
    alph = string.ascii_letters + string.digits
    return "".join(secrets.choice(alph) for _ in range(max(len(v), 16)))


# ─── I3 : chemins refusés dans un correctif ────────────────────────────────────

def cmd_chemins(args: list[str]) -> None:
    """chemins <racine 0|1> <diff --raw -z> <arbre exporté> → une ligne « chemin — raison » par
    chemin refusé ; code 1 s'il y en a, 0 sinon. Rien d'autre sur stdout."""
    racine, raw_path, arbre = args[0] == "1", args[1], args[2]
    try:
        raw = lire_sur(raw_path, 64 << 20).split(b"\0")
    except (OSError, ValueError) as e:
        print(f"(diff) — illisible : {e}")
        sys.exit(1)
    entrees = []
    i = 0
    while i < len(raw):
        meta = raw[i].decode("utf-8", "surrogateescape")
        if not meta.startswith(":"):
            i += 1
            continue
        champs = meta[1:].split()
        statut = champs[4] if len(champs) > 4 else ""
        n = 2 if statut[:1] in ("R", "C") else 1
        for p in raw[i + 1:i + 1 + n]:
            entrees.append((champs[0], champs[1], p.decode("utf-8", "surrogateescape")))
        i += 1 + n
    refus = []
    for old, new, chemin in entrees:
        r = raison_refus(chemin, old, new, racine, arbre)
        if r:
            refus.append(f"{chemin} — {r}")
    if refus:
        print("\n".join(sorted(set(refus))))
        sys.exit(1)


def raison_refus(chemin: str, old: str, new: str, racine: bool, arbre: str) -> str:
    parts = chemin.split("/")
    base = parts[-1]
    low = [p.lower() for p in parts]
    if any(ord(ch) < 32 for ch in chemin):
        return "caractère de contrôle dans le nom"
    if "120000" in (old, new):
        return "lien symbolique"
    if "160000" in (old, new):
        return "sous-module (gitlink)"
    if ".github" in low:
        return ".github/**"
    for j, p in enumerate(parts):
        if p.startswith(".env") and not (p == ".env.example" and j == len(parts) - 1):
            return "**/.env* (sauf .env.example)"
        if p.startswith(".keycloak-"):
            return ".keycloak-*"
    if base.lower().startswith("dockerfile"):
        return "**/Dockerfile*"
    if fnmatch.fnmatch(base.lower(), "docker-compose*.yml") or fnmatch.fnmatch(base.lower(), "docker-compose*.yaml"):
        return "**/docker-compose*.yml"
    if fnmatch.fnmatch(base.lower(), "nginx*.conf"):
        return "**/nginx*.conf"
    if base == "nginx-entrypoint.sh":
        return "**/nginx-entrypoint.sh"
    if base == ".gitmodules":
        return ".gitmodules"
    if racine:
        if parts[0] in ("sso-lab", "infra", ".claude"):
            return f"{parts[0]}/** (dépôt racine)"
        if chemin == "CLAUDE.md":
            return "CLAUDE.md (dépôt racine)"
        if parts[0].startswith("~"):
            return "chemin ~-relatif (dépôt racine)"
    p = os.path.join(arbre, chemin)
    try:
        st = os.lstat(p)
        if stat.S_ISLNK(st.st_mode):
            return "lien symbolique"
        if stat.S_ISREG(st.st_mode) and st.st_size > 1024 * 1024:
            return f"fichier de plus de 1 Mo ({st.st_size} octets)"
    except FileNotFoundError:
        pass   # suppression
    return ""


# ─── tests.txt (phase correction) ──────────────────────────────────────────────

def cmd_tests_txt(args: list[str]) -> None:
    """tests-txt <sortie> <secrets> <cible=fichier>… — sortie des tests rouges pour Claude :
    séquences ANSI retirées, secrets filtrés, chaque cible tronquée à 15 000 caractères (la FIN
    est gardée : c'est là que Django résume les échecs), 45 000 au total."""
    out, secf, items = args[0], args[1], args[2:]
    sec = charger_secrets(secf)
    budget = 45000 // max(1, len(items))
    blocs = []
    for it in items:
        cible, _, f = it.partition("=")
        try:
            t = lire_sur(f, 64 << 20).decode("utf-8", "replace")
        except (OSError, ValueError):
            t = "(sortie illisible)"
        t = re.sub(r"\x1b\[[0-9;?]*[A-Za-z]", "", t)
        t = filtrer(t, sec)[0]
        lim = min(15000, budget)
        if len(t) > lim:
            t = f"…({len(t) - lim} caractères coupés au début)…\n" + t[-lim:]
        blocs.append(f"===== {cible} =====\n{t.rstrip()}\n")
    ecrire_atomique(out, "\n".join(blocs), 0o644)


# ─── GitHub (API REST, jeton par l'environnement) ──────────────────────────────

def gh_requete(api: str, methode: str, chemin: str, corps=None, timeout: float = 30):
    jeton = os.environ.get("AUTO_GH_TOKEN", "")
    if not jeton:
        raise RuntimeError("jeton GitHub absent de l'environnement")
    data = json.dumps(corps).encode() if corps is not None else None
    req = urllib.request.Request(api.rstrip("/") + chemin, data=data, method=methode, headers={
        "Authorization": f"Bearer {jeton}", "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28", "User-Agent": "lab-nuit-auto",
        **({"Content-Type": "application/json"} if data else {})})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, dict(r.headers), json.loads(r.read() or b"null")
    except urllib.error.HTTPError as e:
        try:
            b = json.loads(e.read() or b"null")
        except ValueError:
            b = None
        return e.code, dict(e.headers), b


def cmd_pr(args: list[str]) -> None:
    """pr <api> <propriétaire/dépôt> <branche> <base> <titre> <fichier corps> <brouillon 0|1>
    → URL de la PR sur stdout ; code 1 et message (sans jeton) sur stderr sinon."""
    api, repo, head, base, titre, corps_f, draft = args
    corps = lire_sur(corps_f, 1 << 20).decode("utf-8", "replace")[:65000]
    try:
        code, _, b = gh_requete(api, "POST", f"/repos/{repo}/pulls",
                                {"title": titre[:256], "head": head, "base": base, "body": corps,
                                 "draft": draft == "1", "maintainer_can_modify": False})
    except (OSError, RuntimeError) as e:
        die(f"PR impossible : {type(e).__name__}")
    if code == 201 and isinstance(b, dict) and b.get("html_url"):
        print(b["html_url"])
        return
    msg = (b or {}).get("message", "") if isinstance(b, dict) else ""
    errs = (b or {}).get("errors", []) if isinstance(b, dict) else []
    det = "; ".join(str(e.get("message", e)) if isinstance(e, dict) else str(e) for e in errs)[:200]
    die(f"PR refusée par GitHub (HTTP {code}) : {msg[:120]} {det}".strip())


def cmd_gh_verifier(args: list[str]) -> None:
    """gh-verifier <api> [propriétaire/dépôt]… — jeton valide, à portée fine, sans delete_repo,
    chaque dépôt lisible. Une ligne « ok|ko<TAB>message » par contrôle ; code 1 si un ko."""
    api, repos = args[0], args[1:]
    ko = False
    jeton = os.environ.get("AUTO_GH_TOKEN", "")

    def ligne(ok, m):
        nonlocal ko
        ko |= not ok
        print(f"{'ok' if ok else 'ko'}\t{m}")
    if not jeton.startswith("github_pat_"):
        ligne(False, "le jeton n'est pas un jeton à portée fine (github_pat_…) — un jeton classique porte des portées globales")
    try:
        code, h, b = gh_requete(api, "GET", "/user", timeout=20)
    except (OSError, RuntimeError) as e:
        ligne(False, f"API GitHub injoignable ({type(e).__name__})")
        sys.exit(1)
    if code != 200:
        ligne(False, f"jeton refusé par GitHub (HTTP {code})")
        sys.exit(1)
    ligne(True, f"jeton valide (compte {(b or {}).get('login', '?')})")
    scopes = {s.strip() for s in (h.get("X-OAuth-Scopes") or h.get("x-oauth-scopes") or "").split(",") if s.strip()}
    if "delete_repo" in scopes:
        ligne(False, "le jeton porte la portée delete_repo — refusé")
    else:
        ligne(True, "pas de portée delete_repo")
    for r in repos:
        try:
            code, _, _ = gh_requete(api, "GET", f"/repos/{r}", timeout=20)
        except (OSError, RuntimeError) as e:
            code = type(e).__name__
        ligne(code == 200, f"dépôt {r} " + ("accessible" if code == 200 else f"inaccessible ({code})"))
    sys.exit(1 if ko else 0)


# ─── email ─────────────────────────────────────────────────────────────────────

def cmd_email(args: list[str]) -> None:
    """email <sujet> <fichier corps> — SMTP_* et ALERT_TO dans l'environnement (jamais en
    argument). AUTO_EMAIL_DIR (essais) : le message est écrit dans ce dossier au lieu d'être
    envoyé. Code 1 si non envoyé."""
    import smtplib
    import ssl
    from email.message import EmailMessage
    sujet, corps_f = args
    corps = lire_sur(corps_f, 2 << 20).decode("utf-8", "replace")
    e = os.environ.get
    m = EmailMessage()
    m["From"] = e("SMTP_FROM") or "lab@localhost"
    m["To"] = e("ALERT_TO") or e("SMTP_FROM") or "lab@localhost"
    m["Subject"] = sujet[:200]
    m.set_content(corps)
    d = e("AUTO_EMAIL_DIR")
    if d:
        p = os.path.join(d, f"{dt.datetime.now():%Y%m%d-%H%M%S}-{os.getpid()}.eml")
        ecrire_atomique(p, m.as_string(), 0o600)
        return
    h, u, pw = e("SMTP_HOST", ""), e("SMTP_USER", ""), e("SMTP_PASSWORD", "")
    if not (h and u and pw and e("SMTP_FROM")):
        die("SMTP incomplet dans sso-lab/.env")
    s = smtp_connexion(h)
    s.login(u, pw)
    s.send_message(m)
    s.quit()


def smtp_connexion(h: str):
    import smtplib
    import ssl
    e = os.environ.get
    port = int(e("SMTP_PORT") or 587)
    if (e("SMTP_SSL") or "").lower() == "true":
        return smtplib.SMTP_SSL(h, port, context=ssl.create_default_context(), timeout=30)
    s = smtplib.SMTP(h, port, timeout=30)
    if (e("SMTP_STARTTLS") or "true").lower() != "false":
        s.starttls(context=ssl.create_default_context())
    return s


def cmd_smtp_verifier(_args: list[str]) -> None:
    """smtp-verifier — connexion et authentification, sans rien envoyer. Code 1 sinon."""
    e = os.environ.get
    d = e("AUTO_EMAIL_DIR")
    if d:
        if os.path.isdir(d) and os.access(d, os.W_OK):
            print(f"emails écrits dans un dossier (AUTO_EMAIL_DIR, essai)")
            return
        die("AUTO_EMAIL_DIR n'est pas un dossier inscriptible")
    h, u, pw, f = e("SMTP_HOST", ""), e("SMTP_USER", ""), e("SMTP_PASSWORD", ""), e("SMTP_FROM", "")
    manque = [k for k, v in (("SMTP_HOST", h), ("SMTP_USER", u), ("SMTP_PASSWORD", pw), ("SMTP_FROM", f)) if not v]
    if manque:
        die("clés absentes de sso-lab/.env : " + ", ".join(manque))
    try:
        s = smtp_connexion(h)
        s.login(u, pw)
        s.quit()
    except Exception as ex:  # noqa: BLE001 — le message d'une exception SMTP ne porte pas le mot de passe
        die(f"connexion SMTP impossible : {type(ex).__name__}")
    print(f"authentification SMTP réussie ({h})")


# ─── divers ────────────────────────────────────────────────────────────────────

def cmd_uuid(_args: list[str]) -> None:
    print(uuid.uuid4())


def cmd_fin(args: list[str]) -> None:
    """fin <HH:MM> → epoch de la prochaine occurrence de cette heure (strictement après maintenant)."""
    h, m = (int(x) for x in args[0].split(":"))
    now = dt.datetime.now().astimezone()
    t = now.replace(hour=h, minute=m, second=0, microsecond=0)
    if t <= now:
        t += dt.timedelta(days=1)
    print(int(t.timestamp()))


def cmd_json_champ(args: list[str]) -> None:
    """json-champ <fichier> <champ> → valeur d'un champ de premier niveau (lecture sûre)."""
    try:
        o = json.loads(lire_sur(args[0], 1 << 20))
    except (OSError, ValueError):
        sys.exit(1)
    v = o.get(args[1], "") if isinstance(o, dict) else ""
    print(v)


def cmd_lien_github(args: list[str]) -> None:
    """lien-github <url> → « propriétaire/dépôt » d'une URL GitHub https ou ssh ; code 1 sinon."""
    m = re.fullmatch(r"(?:https://github\.com/|git@github\.com:|ssh://git@github\.com/)"
                     r"([A-Za-z0-9-]{1,39})/([A-Za-z0-9._-]{1,100}?)(?:\.git)?/?", args[0].strip())
    if not m or ".." in m.group(2):
        sys.exit(1)
    print(f"{m.group(1)}/{m.group(2)}")


# ─── contrôle statique : un timeout sur chaque commande externe (I7) ───────────

EXTERNES = {"docker", "git", "python", "python3", "npm", "npx", "curl", "wget", "gh", "crontab", "claude", "bash", "sh", "ssh"}
SEP_RE = re.compile(r"(?:;|&&|\|\||\||\$\(|<\(|`|\{|\bthen\b|\bdo\b|\belse\b|\bexec\b|!)")
ASSIGN_RE = re.compile(r"^(?:[A-Za-z_][A-Za-z0-9_]*=(?:\"[^\"]*\"|'[^']*'|\S*)\s+)+")


def cmd_lint_timeout(args: list[str]) -> None:
    """lint-timeout <fichier>… — une ligne « fichier:ligne : commande » par commande externe
    lancée sans passer par x/gx/py/timeout. Rien sur stdout = conforme."""
    for f in args:
        try:
            lignes = open(f, encoding="utf-8").read().splitlines()
        except OSError as e:
            print(f"{f} : illisible ({e})")
            continue
        logiques, debut, acc = [], 0, ""
        for n, l in enumerate(lignes, 1):     # lignes continuées (« \\ » final) jointes
            if not acc:
                debut = n
            if l.rstrip().endswith("\\") and not l.strip().startswith("#"):
                acc += l.rstrip()[:-1] + " "
                continue
            logiques.append((debut, acc + l))
            acc = ""
        for n, l in logiques:
            t = l.strip()
            if not t or t.startswith("#") or "# x-ok" in l:
                continue
            if f.endswith(".py"):
                if re.search(r"\b(subprocess|os\.system|os\.popen|os\.exec)\b[.(]", t):
                    print(f"{f}:{n} : lancement de processus depuis Python")
                if re.search(r"\b(urlopen|SMTP|SMTP_SSL)\(", t) and "timeout=" not in t:
                    print(f"{f}:{n} : appel réseau sans timeout=")
                continue
            t = re.sub(r"'[^']*'", "''", t)          # rien ne s'exécute entre apostrophes
            for seg in SEP_RE.split(t):
                seg = ASSIGN_RE.sub("", seg.strip())
                mot = seg.split()[0] if seg.split() else ""
                if mot in EXTERNES:
                    print(f"{f}:{n} : {mot} sans timeout")


COMMANDES = {
    "calendrier": cmd_calendrier, "calendrier-taches": cmd_calendrier_taches, "tache-cibles": cmd_tache_cibles,
    "etat": cmd_etat, "etat-get": cmd_etat_get, "etat-liste": cmd_etat_liste,
    "claude-resultat": cmd_claude_resultat, "resume": cmd_resume, "resume-brouillon": cmd_resume_brouillon,
    "secrets-collecter": cmd_secrets_collecter, "scrub": cmd_scrub, "contient-secret": cmd_contient_secret,
    "rapport": cmd_rapport, "env-assaini": cmd_env_assaini, "chemins": cmd_chemins, "tests-txt": cmd_tests_txt,
    "pr": cmd_pr, "gh-verifier": cmd_gh_verifier, "email": cmd_email, "smtp-verifier": cmd_smtp_verifier,
    "uuid": cmd_uuid, "lint-timeout": cmd_lint_timeout, "fin": cmd_fin, "json-champ": cmd_json_champ, "lien-github": cmd_lien_github,
}

if __name__ == "__main__":
    if len(sys.argv) < 2 or sys.argv[1] not in COMMANDES:
        die("usage : outils.py <" + "|".join(COMMANDES) + "> …", 2)
    COMMANDES[sys.argv[1]](sys.argv[2:])
