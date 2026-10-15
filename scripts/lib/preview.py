#!/usr/bin/env python3
"""Travail sur les DONNÉES d'un essai — appelé par scripts/app-preview.sh.

Chantier « essai-dev », contrat v1, interface I1. Bibliothèque standard
seulement (le conteneur du moteur n'a pas PyYAML, et n'a pas à l'avoir).

Tout ce qui entre ici vient d'un développeur qui n'a pas Docker et dont le
dossier de travail n'a été relu par personne : noms de fichiers, contenu du
docker-compose.yml, contenu des fichiers. Rien n'y est cru sur parole.

Sous-commandes :

  copy <dossier de travail> <destination> <liste>
      Copie les fichiers nommés dans <liste> (noms séparés par NUL, relatifs au
      dossier de travail — la sortie de `git ls-files -z`). Chaque composant de
      chemin est ouvert sans suivre de lien ; un lien symbolique, un fichier
      spécial ou un nom qui sort du dossier refuse TOUTE la copie.

  rewrite <modèle.json> <dossier> <dev-uid> <chemin Caddy de l'app> <info.json>
      <modèle.json> est le modèle Compose RÉSOLU, non interpolé
      (`docker compose config --no-interpolate`) : ancres YAML, `extends` et
      `include` y sont déjà aplatis. La réécriture porte donc sur ce que Docker
      exécuterait, jamais sur le texte du fichier. Écrit
      <dossier>/.lab-essai.compose.json et réécrit nginx.conf /
      nginx-entrypoint.sh du frontend. ENTIÈRE OU REFUSÉE : toutes les raisons
      sont réunies d'abord, rien n'est écrit s'il y en a une.

  env <.env de service> <sortie> <info.json>   (paramètres : variables LABP_*)
      Fabrique le .env de l'essai à partir de celui de l'app en service.

  redact <.env>
      Filtre stdin → stdout : masque les valeurs secrètes de ce .env.

Code : 0 = fait ; 1 = refusé (une raison par ligne sur stdout) ; 2 = usage.
"""
import json
import os
import re
import secrets
import stat
import sys

COMPOSE_NAME = ".lab-essai.compose.json"

# Jamais copiés, à quelque profondeur que ce soit (contrat I1, étape `source`).
# Le dernier est le fichier que l'essai écrit lui-même : un dépôt ne le fournit pas.
NEVER_COPIED = {".env", ".keycloak-client-opts", ".keycloak-service-account-roles", COMPOSE_NAME}

MAX_BYTES = int(os.environ.get("LAB_PREVIEW_MAX_BYTES", str(200 * 1024 * 1024)))
MAX_FILES = int(os.environ.get("LAB_PREVIEW_MAX_FILES", "20000"))

# Plafonds posés sur chaque conteneur d'un essai (question ouverte du contrat,
# tranchée ici) : un essai est du code non relu, sans tests, sur 2 vCPU / 16 Go.
LIMIT_MEM = os.environ.get("LAB_PREVIEW_MEM", "1g")
LIMIT_CPUS = float(os.environ.get("LAB_PREVIEW_CPUS", "1"))
LIMIT_PIDS = int(os.environ.get("LAB_PREVIEW_PIDS", "512"))

# « KEY » seulement comme mot entier : KEYCLOAK_URL ou KEYCLOAK_CLIENT_ID ne sont pas des secrets.
SECRET_KEY_RE = re.compile(r"(SECRET|PASSWORD|PASSWD|TOKEN|CREDENTIAL|(^|_)KEY(_|$))", re.I)


def shown(text, limit=120):
    """Un nom venu du dépôt, rendu affichable sur UNE ligne du journal."""
    text = "".join(ch if ch.isprintable() else "?" for ch in str(text))
    return text if len(text) <= limit else text[: limit - 1] + "…"


def finish(reasons):
    for line in sorted(set(reasons)):
        print(line)
    return 1 if reasons else 0


# ── copy ─────────────────────────────────────────────────────────────────────
def cmd_copy(work, dest, list_file):
    reasons = []
    with open(list_file, "rb") as fh:
        raw = fh.read()
    names = [n for n in raw.split(b"\0") if n]

    try:
        root_fd = os.open(work, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    except OSError as exc:
        print(f"[source] dossier de travail illisible : {exc.strerror}")
        return 1

    plan = []          # (composants, taille annoncée)
    total = 0
    skipped = 0
    seen = set()
    for raw_name in names:
        try:
            name = raw_name.decode("utf-8")
        except UnicodeDecodeError:
            reasons.append(f"[source] nom de fichier qui n'est pas de l'UTF-8 : {shown(raw_name)}")
            continue
        # Un dépôt imbriqué est listé par git comme « dossier/ » : on ne descend pas.
        absolute = name.startswith("/")
        name = name.rstrip("/")
        parts = name.split("/")
        if absolute or any(p in ("", ".", "..") for p in parts):
            reasons.append(f"[source] nom de fichier refusé (sort du dossier) : {shown(name)}")
            continue
        if ".git" in parts or parts[-1] in NEVER_COPIED:
            skipped += 1
            continue
        if name in seen:
            continue
        seen.add(name)
        # Chaque composant est ouvert sans suivre de lien : `a/b` où `a` est un
        # lien vers /home/…/sso-lab ne doit pas faire lire b de l'autre côté.
        fd = root_fd
        opened = []
        verdict = None
        try:
            for comp in parts[:-1]:
                try:
                    nxt = os.open(comp, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
                except OSError:
                    st = _lstat(comp, fd)
                    if st is None:
                        verdict = "absent"
                    elif stat.S_ISLNK(st.st_mode):
                        verdict = "lien"
                    else:
                        verdict = "special"
                    break
                opened.append(nxt)
                fd = nxt
            if verdict is None:
                st = _lstat(parts[-1], fd)
                if st is None:
                    verdict = "absent"          # suivi par git, supprimé du dossier
                elif stat.S_ISLNK(st.st_mode):
                    verdict = "lien"
                elif stat.S_ISDIR(st.st_mode):
                    verdict = "dossier"         # dépôt imbriqué : git ne liste que son nom
                elif not stat.S_ISREG(st.st_mode):
                    verdict = "special"
                else:
                    total += st.st_size
                    plan.append((parts, st.st_size))
        finally:
            for o in opened:
                os.close(o)
        if verdict == "lien":
            reasons.append(f"[source] lien symbolique refusé : {shown(name)} — un essai ne suit aucun lien")
        elif verdict == "special":
            reasons.append(f"[source] fichier spécial refusé (ni fichier ni dossier) : {shown(name)}")
        elif verdict in ("absent", "dossier"):
            skipped += 1
        if len(reasons) > 50:
            break

    if len(plan) > MAX_FILES:
        reasons.append(f"[source] {len(plan)} fichiers — plafond d'un essai : {MAX_FILES} "
                       "(un dossier de dépendances ou de build manque-t-il dans .gitignore ?)")
    if total > MAX_BYTES:
        reasons.append(f"[source] {total // (1024 * 1024)} Mo — plafond d'un essai : {MAX_BYTES // (1024 * 1024)} Mo")
    if not plan and not reasons:
        reasons.append("[source] aucun fichier à copier (dossier de travail vide ?)")
    if reasons:
        os.close(root_fd)
        return finish(reasons[:60])

    copied = 0
    written = 0
    os.makedirs(dest, mode=0o700, exist_ok=True)
    dest_fd = os.open(dest, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        for parts, _size in plan:
            src_fd, dst_dir = root_fd, dest_fd
            opened = []
            try:
                for comp in parts[:-1]:
                    src_fd = os.open(comp, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=src_fd)
                    opened.append(src_fd)
                    try:
                        os.mkdir(comp, 0o755, dir_fd=dst_dir)
                    except FileExistsError:
                        pass
                    dst_dir = os.open(comp, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=dst_dir)
                    opened.append(dst_dir)
                # O_NONBLOCK : un tube nommé posé entre le contrôle et la copie
                # ne doit pas bloquer le moteur ; fstat tranche ensuite.
                in_fd = os.open(parts[-1], os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=src_fd)
                opened.append(in_fd)
                st = os.fstat(in_fd)
                if not stat.S_ISREG(st.st_mode):
                    raise OSError("n'est plus un fichier ordinaire")
                mode = 0o755 if st.st_mode & 0o111 else 0o644
                out_fd = os.open(parts[-1], os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, mode, dir_fd=dst_dir)
                opened.append(out_fd)
                while True:
                    chunk = os.read(in_fd, 1 << 20)
                    if not chunk:
                        break
                    written += len(chunk)
                    # Le fichier a pu grossir depuis le contrôle : le plafond
                    # vaut pour ce qui est réellement écrit.
                    if written > MAX_BYTES:
                        raise OSError(f"plafond de {MAX_BYTES // (1024 * 1024)} Mo dépassé pendant la copie")
                    os.write(out_fd, chunk)
                copied += 1
            except OSError as exc:
                reasons.append(f"[source] copie impossible de {shown('/'.join(parts))} : "
                               f"{exc.strerror or exc} (modifié pendant la copie, ou lien symbolique)")
                break
            finally:
                for o in reversed(opened):
                    os.close(o)
    finally:
        os.close(dest_fd)
        os.close(root_fd)
    if reasons:
        return finish(reasons)
    print(f"{copied} fichier(s), {written // 1024} Ko copiés ; {skipped} écarté(s) "
          "(.env, .keycloak-*, .git, fichiers supprimés)", file=sys.stderr)
    return 0


def _lstat(name, dir_fd):
    try:
        return os.stat(name, dir_fd=dir_fd, follow_symlinks=False)
    except OSError:
        return None


# ── rewrite ──────────────────────────────────────────────────────────────────
BLOCK_RE = re.compile(r"^caddy\.(?:\d+_)?(?:handle|handle_path)(?:_\d+)?$")


def inside(path, root):
    real = os.path.realpath(path)
    root = os.path.realpath(root)
    return real == root or real.startswith(root + os.sep)


def cmd_rewrite(model_file, build_dir, name, caddy_path, info_file):
    reasons = []
    with open(model_file, encoding="utf-8") as fh:
        model = json.load(fh)
    app = os.environ.get("LABP_APP", "")

    services = model.get("services") or {}
    if not isinstance(services, dict) or not services:
        print("[rewrite] docker-compose.yml : aucun service déclaré")
        return 1

    path_re = re.compile(r"^/%s(-api)?((?:/.*)?)$" % re.escape(caddy_path))
    has_front = has_api = False
    front_contexts = []

    def new_path(value, where, key):
        nonlocal has_front, has_api
        m = path_re.match(value)
        if not m:
            reasons.append(f"[rewrite] {where} : étiquette `{shown(key)}: {shown(value)}` — un essai ne sait "
                           f"déplacer que /{caddy_path} et /{caddy_path}-api (les chemins de l'app)")
            return value, None
        if m.group(1):
            has_api = True
        else:
            has_front = True
        return f"/{name}{m.group(1) or ''}{m.group(2)}", ("api" if m.group(1) else "front")

    for sname, svc in services.items():
        if not isinstance(svc, dict):
            reasons.append(f"[rewrite] service `{shown(sname)}` : définition illisible")
            continue
        if not re.fullmatch(r"[a-zA-Z0-9][a-zA-Z0-9_.-]*", str(sname)):
            reasons.append(f"[rewrite] service `{shown(sname)}` : nom de service inattendu")
            continue
        where = f"service `{sname}`"

        # Aucun port publié : la section disparaît, d'où qu'elle vienne (le
        # modèle est résolu — une ancre YAML ou un `extends` sont déjà aplatis).
        svc.pop("ports", None)
        svc["container_name"] = f"{name}-{sname}"
        if "hostname" in svc:
            svc["hostname"] = f"{name}-{sname}"

        build = svc.get("build")
        if isinstance(build, str):
            build = {"context": build}
            svc["build"] = build
        if build:
            # L'image d'un service construit porte le nom par défaut de Compose,
            # « dev-<uid>-<service> ». Garder `image: <app>-backend` ferait
            # reconstruire, par l'essai, l'image de l'app EN SERVICE.
            svc.pop("image", None)
            if isinstance(build, dict):
                build.pop("tags", None)

        # Plafonds de ressources (voir en tête) et pas de redémarrage en boucle.
        for key in ("deploy", "mem_reservation", "memswap_limit", "cpu_shares", "cpu_quota",
                    "cpu_period", "scale", "oom_score_adj"):
            svc.pop(key, None)
        svc["mem_limit"] = LIMIT_MEM
        svc["cpus"] = LIMIT_CPUS
        svc["pids_limit"] = LIMIT_PIDS
        svc["restart"] = "no"

        labels = svc.get("labels")
        if labels is None:
            labels = {}
        if isinstance(labels, list):
            as_dict = {}
            for item in labels:
                item = str(item)
                k, _, v = item.partition("=")
                as_dict[k] = v
            labels = as_dict
        if not isinstance(labels, dict):
            reasons.append(f"[rewrite] {where} : étiquettes illisibles")
            continue
        kinds = set()
        for lkey in list(labels):
            if BLOCK_RE.match(str(lkey)):
                value = "" if labels[lkey] is None else str(labels[lkey])
                labels[lkey], kind = new_path(value, where, lkey)
                if kind:
                    kinds.add(kind)
        if labels:
            svc["labels"] = labels
        if "front" in kinds:
            ctx = build.get("context") if isinstance(build, dict) else None
            if not ctx:
                reasons.append(f"[rewrite] {where} : sert /{caddy_path} sans être construit par le projet — un essai "
                               "ne sait réécrire que le frontend du gabarit (nginx.conf, nginx-entrypoint.sh)")
            elif not inside(str(ctx), build_dir):
                reasons.append(f"[rewrite] {where} : contexte de build hors du dossier du projet")
            else:
                front_contexts.append((sname, str(ctx)))

    # Volumes et réseaux nommés explicitement « <app>-… » : l'essai a les siens.
    # Garder le nom ferait monter, par l'essai, les données de l'app en service.
    for section in ("volumes", "networks"):
        for key, item in (model.get(section) or {}).items():
            if not isinstance(item, dict) or item.get("external"):
                continue
            real = item.get("name")
            if real is None or str(real).startswith((name + "_", name + "-")):
                continue
            real = str(real)
            for prefix in ([app] if app else []) + [caddy_path]:
                if real.startswith((prefix + "_", prefix + "-")):
                    item["name"] = name + real[len(prefix):]
                    break
            else:
                reasons.append(f"[rewrite] {section} `{shown(key)}` : nom imposé « {shown(real)} » — un essai ne sait "
                               f"renommer qu'un nom commençant par « {app or caddy_path}- » ou « {app or caddy_path}_ »")

    model["name"] = name
    for key in [k for k in model if k.startswith("x-") or k == "version"]:
        model.pop(key)

    # ── Fichiers du frontend (remplacement textuel BORNÉ) ───────────────────────
    token_re = re.compile(r"(?<![A-Za-z0-9_.-])/%s(-api)?(?![A-Za-z0-9_-])" % re.escape(caddy_path))
    edits = {}
    for sname, ctx in front_contexts:
        rel = os.path.relpath(ctx, build_dir)
        for fname, needs in (
            ("nginx.conf", [f'<base href="/{name}/">']),
            ("nginx-entrypoint.sh", [f"/{name}/"] + ([f"/{name}-api"] if has_api else [])),
        ):
            path = os.path.join(ctx, fname)
            label = os.path.join(rel, fname)
            if os.path.islink(path) or not os.path.isfile(path):
                reasons.append(f"[rewrite] {label} absent — le frontend de `{sname}` n'a pas la forme du gabarit, "
                               "un essai ne sait pas lui donner son adresse")
                continue
            try:
                with open(path, encoding="utf-8") as fh:
                    text = fh.read()
            except (OSError, UnicodeDecodeError):
                reasons.append(f"[rewrite] {label} illisible (texte UTF-8 attendu)")
                continue
            new_text, count = token_re.subn(lambda m: f"/{name}{m.group(1) or ''}", text)
            missing = [n for n in needs if n not in new_text]
            if missing or not count:
                reasons.append(f"[rewrite] {label} : « /{caddy_path}/ »"
                               + (f" et « /{caddy_path}-api »" if fname.endswith(".sh") and has_api else "")
                               + " n'y figurent pas comme dans le gabarit (introuvable après réécriture : "
                               + ", ".join(missing or ["le chemin de l'app"]) + ")")
                continue
            edits[path] = new_text

    if reasons:
        return finish(reasons)

    for path, text in edits.items():
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(text)
    out = os.path.join(build_dir, COMPOSE_NAME)
    if os.path.lexists(out):
        os.unlink(out)
    fd = os.open(out, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        json.dump(model, fh, ensure_ascii=False, indent=1)
    with open(info_file, "w", encoding="utf-8") as fh:
        json.dump({"has_front": has_front, "has_api": has_api, "services": sorted(services),
                   "files": sorted(os.path.relpath(p, build_dir) for p in edits)}, fh)
    return 0


# ── env ──────────────────────────────────────────────────────────────────────
ENV_LINE_RE = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)=(.*)$")
# Retirés du .env d'un essai (contrat I1, étape `env`) :
#   • le compte de service de l'app (KEYCLOAK_ADMIN_CLIENT_* — écrit par
#     create-app-client.sh) et le secret de son client s'il est confidentiel :
#     un essai n'écrit pas dans les fichiers réels de l'app ni n'administre le realm ;
#   • tout ce qui envoie un email (les sept clés de app-smtp.sh, son marqueur,
#     et les autres EMAIL_*) ;
#   • ce qui changerait le projet ou le fichier Compose (COMPOSE_*, DOCKER_*).
ENV_DROP_RE = re.compile(
    r"^(EMAIL_[A-Z0-9_]*|DEFAULT_FROM_EMAIL|LAB_SMTP_PROFILE|KEYCLOAK_ADMIN_CLIENT_ID|"
    r"KEYCLOAK_ADMIN_CLIENT_SECRET|KEYCLOAK_CLIENT_SECRET|COMPOSE_[A-Z0-9_]*|DOCKER_[A-Z0-9_]*|HOST_DEV_ROOT)$")
IDENT_RE = re.compile(r"^[a-z_][a-z0-9_]*$")


def env_value(raw):
    raw = re.sub(r"\s+#.*$", "", raw.strip())
    if len(raw) >= 2 and raw[0] == raw[-1] and raw[0] in "'\"":
        raw = raw[1:-1]
    return raw


def cmd_env(service_env, out_file, info_file):
    p = {k[5:].lower(): v for k, v in os.environ.items() if k.startswith("LABP_")}
    name, slug, domain = p["name"], p["slug"], p["domain"]
    owner, superuser = p["owner"], p.get("superuser") == "1"
    reasons = []
    order, values = [], {}
    try:
        with open(service_env, encoding="utf-8", errors="replace") as fh:
            for line in fh:
                m = ENV_LINE_RE.match(line.rstrip("\r\n"))
                if not m:
                    continue
                if m.group(1) not in values:
                    order.append(m.group(1))
                values[m.group(1)] = m.group(2)
    except OSError as exc:
        print(f"[env] .env de service de l'app illisible : {exc.strerror}")
        return 1

    dropped = [k for k in order if ENV_DROP_RE.match(k)]
    for k in dropped:
        values.pop(k)
    order = [k for k in order if k in values]

    info = {"database": None, "schema": None, "db_host": None, "db_user": None, "dropped": dropped}
    if env_value(values.get("DB_SCHEMA", "")):
        host = env_value(values.get("DB_HOST", ""))
        db = env_value(values.get("DB_NAME", ""))
        user = env_value(values.get("DB_USER", ""))
        if host not in ("postgres", "postgis"):
            reasons.append(f"[env] DB_HOST={shown(host)} dans le .env de l'app (attendu : postgres ou postgis)")
        if not IDENT_RE.match(db) or not IDENT_RE.match(user):
            reasons.append("[env] DB_NAME/DB_USER du .env de l'app ne sont pas des identifiants simples")
        elif db in ("devdb", "gisdb", "postgres"):
            reasons.append(f"[env] la base « {db} » est une base d'administration — un essai n'y écrit pas")
        elif not superuser:
            want = ("gis_" if host == "postgis" else "dev_") + owner
            if db != want or user != "dev_" + owner:
                reasons.append(f"[env] le .env de l'app désigne {db}/{user} au lieu de {want}/dev_{owner} "
                               f"(base et rôle du propriétaire « {owner} »)")
        info.update(database=db, schema=f"{slug}__essai", db_host=host, db_user=user)
    if reasons:
        return finish(reasons)

    forced = {
        "DOMAIN": domain,
        "KEYCLOAK_CLIENT_ID": name,
        "KEYCLOAK_REQUIRED_GROUPS": p.get("groups", ""),
        "SCRIPT_NAME": f"/{name}-api",
        "SECRET_KEY": secrets.token_urlsafe(50),
        # Des ORIGINES, sans chemin : le gabarit en fait ses origines CORS, et
        # django-cors-headers refuse de démarrer sur une origine à chemin.
        # Derrière Caddy, l'interface et l'API de l'essai ont la même origine.
        "BACKEND_URL": f"https://{domain}",
        "FRONTEND_URL": f"https://{domain}",
    }
    # Adresses du lab : recalculées ici comme reset_url.sh les calcule au
    # déploiement, jamais reprises du .env de service. Un projet jamais déployé
    # garde dans ce .env les valeurs fictives du gabarit (KEYCLOAK_PUBLIC_URL=
    # http://VOTRE_IP_WAN:8080, DOMAIN=CHANGE_ME…) : la redirection de connexion
    # de l'essai partait vers elles (constaté sur test-video, 2026-10-14).
    realm = p.get("realm") or "ssolab"
    forced.update({
        "KEYCLOAK_REALM": realm,
        "KEYCLOAK_PUBLIC_URL": f"https://{domain}/auth",
        "KEYCLOAK_ISSUER_URI": f"https://{domain}/auth/realms/{realm}",
    })
    if "KEYCLOAK_HOSTNAME_URL" in values:
        forced["KEYCLOAK_HOSTNAME_URL"] = f"https://{domain}/auth"
    for key, val in (("SERVER_URL_LAN", p.get("server_url_lan", "")), ("SERVER_URL_WAN", p.get("server_url_wan", "")),
                     ("PORT_KEYCLOAK", p.get("port_keycloak", ""))):
        if val:
            forced[key] = val
    if p.get("server_url_wan") and p.get("port_keycloak"):
        forced["KEYCLOAK_URL"] = f"{p['server_url_wan']}:{p['port_keycloak']}"
    if info["schema"]:
        forced["DB_SCHEMA"] = info["schema"]
    # Une API qui tient une liste blanche de clients (storage…) : l'essai
    # n'accepte que les jetons de SON client.
    if "KEYCLOAK_TRUSTED_CLIENTS" in values:
        forced["KEYCLOAK_TRUSTED_CLIENTS"] = name
    for k in forced:
        if k not in values:
            order.append(k)
    values.update(forced)
    # Adresses d'appoint (origines CORS du gabarit) restées fictives faute de
    # bbox.env : retirées plutôt que servies — le gabarit s'en passe.
    placeholder = re.compile(r"CHANGE_ME|VOTRE_|192\.168\.1\.X")
    for k in ("SERVER_URL_LAN", "SERVER_URL_WAN", "KEYCLOAK_URL"):
        if k in values and k not in forced and placeholder.search(env_value(values[k])):
            values.pop(k)
            order.remove(k)
            info["dropped"].append(k)
    # Ceinture : plus aucune valeur fictive du gabarit dans ce qui dit où est le lab.
    leftover = [k for k in order
                if re.match(r"^(KEYCLOAK_[A-Z_]*|DOMAIN|SERVER_URL_[A-Z]+|BACKEND_URL|FRONTEND_URL)$", k)
                and placeholder.search(env_value(values[k]))]
    if leftover:
        return finish([f"[env] {k} garde une valeur fictive du gabarit — le lab n'est pas configuré (bbox.env, .env racine)"
                       for k in leftover])

    if os.path.lexists(out_file):
        os.unlink(out_file)
    fd = os.open(out_file, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        fh.write(f"# .env de l'essai {name} — écrit par scripts/app-preview.sh, jamais à la main.\n")
        for k in order:
            fh.write(f"{k}={values[k]}\n")
    with open(info_file, "w", encoding="utf-8") as fh:
        json.dump(info, fh)
    return 0


# ── redact ───────────────────────────────────────────────────────────────────
def cmd_redact(env_file):
    needles = []
    try:
        with open(env_file, encoding="utf-8", errors="replace") as fh:
            for line in fh:
                m = ENV_LINE_RE.match(line.rstrip("\r\n"))
                if m and SECRET_KEY_RE.search(m.group(1)):
                    for v in {m.group(2).strip(), env_value(m.group(2))}:
                        if len(v) >= 8:
                            needles.append(v)
    except OSError:
        pass
    needles.sort(key=len, reverse=True)
    for raw in sys.stdin.buffer:
        line = raw.decode("utf-8", errors="replace")
        for n in needles:
            if n in line:
                line = line.replace(n, "(masqué)")
        sys.stdout.write(line)
        sys.stdout.flush()
    return 0


def main(argv):
    table = {"copy": (cmd_copy, 3), "rewrite": (cmd_rewrite, 5), "env": (cmd_env, 3), "redact": (cmd_redact, 1)}
    if len(argv) < 2 or argv[1] not in table or len(argv) - 2 != table[argv[1]][1]:
        print(__doc__, file=sys.stderr)
        return 2
    return table[argv[1]][0](*argv[2:])


if __name__ == "__main__":
    sys.exit(main(sys.argv))
