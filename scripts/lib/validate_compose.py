#!/usr/bin/env python3
"""Contrôle de sûreté du modèle Compose d'une app — appelé par validate-app.sh.

Contrat « multi-dev » v2, interface I4. Lit sur stdin le modèle RÉSOLU produit
par `docker compose config --format json --no-env-resolution` (interpolation,
`extends`, `include` et chemins déjà résolus : on contrôle ce que Docker
exécuterait réellement, pas le texte du fichier), et écrit une raison de refus
par ligne, préfixée d'un code stable entre crochets.

Pourquoi ce contrôle existe : le compte hôte d'un développeur n'a pas accès à
Docker, mais son dépôt est déployé pour lui. Un docker-compose.yml libre est un
accès root à l'hôte (privileged, montage de docker.sock ou de /), au réseau des
autres apps, au reverse proxy et à l'identité des autres services. C'est ce
contrôle — pas l'absence du groupe `docker` — qui tient la promesse.

Principe : LISTE BLANCHE. Une clé de service, de volume ou de réseau inconnue
de ce fichier est refusée ; on ajoute une clé ici après avoir décidé qu'elle est
sûre, jamais l'inverse. Une nouvelle option dangereuse de Compose est donc
refusée par défaut le jour où elle apparaît.

Usage : validate_compose.py <app> <dossier_app> <domaine> <ports_csv> <noms_reserves_fichier>
Code  : 0 = rien à redire ; 1 = au moins un refus ; 2 = entrée illisible.
"""
import json
import os
import re
import sys

SHARED_NETWORKS = {"dev-net", "sso-lab_sso-net"}

# Clés de service acceptées telles quelles (aucun pouvoir sur l'hôte).
SERVICE_KEYS_FREE = {
    "image", "restart", "command", "entrypoint", "working_dir", "user",
    "environment", "expose", "depends_on", "healthcheck", "tmpfs", "init",
    "tty", "stdin_open", "stop_grace_period", "stop_signal", "read_only",
    "mem_limit", "mem_reservation", "memswap_limit", "cpus", "cpu_shares",
    "cpu_quota", "cpu_period", "pids_limit", "shm_size", "ulimits", "profiles",
    "pull_policy", "platform", "attach", "scale", "extra_hosts", "annotations",
    "oom_score_adj",
}
# Clés acceptées MAIS contrôlées plus bas.
SERVICE_KEYS_CHECKED = {
    "build", "container_name", "hostname", "env_file", "ports", "networks",
    "labels", "volumes", "logging", "deploy", "secrets", "configs",
    # Présentes dans la liste pour produire un refus au message précis :
    "privileged", "cap_add", "cap_drop", "devices", "device_cgroup_rules",
    "network_mode", "pid", "ipc",
}

# Sous-directives Caddy autorisées à l'intérieur d'un bloc handle/handle_path.
CADDY_SUBDIRECTIVES = {"reverse_proxy", "encode", "header", "request_body", "rewrite", "uri"}

reasons = []


def refuse(code, msg):
    reasons.append(f"[{code}] {msg}")


def inside(path, root):
    """Vrai si `path` (résolu, liens symboliques compris) est dans `root`."""
    real = os.path.realpath(path)
    root = os.path.realpath(root)
    return real == root or real.startswith(root + os.sep)


def main():
    if len(sys.argv) != 6:
        print(__doc__, file=sys.stderr)
        return 2
    app, app_dir, domain, ports_csv, reserved_file = sys.argv[1:6]
    allowed_ports = {p for p in ports_csv.split(",") if p}
    try:
        with open(reserved_file, encoding="utf-8") as fh:
            reserved_names = {line.strip() for line in fh if line.strip()}
    except OSError:
        reserved_names = set()
    try:
        model = json.load(sys.stdin)
    except json.JSONDecodeError as exc:
        print(f"[compose] modèle Compose illisible : {exc}", file=sys.stderr)
        return 2

    # ── Nom du projet ────────────────────────────────────────────────────────
    # `name:` (ou COMPOSE_PROJECT_NAME) égal à celui d'une autre app ferait de
    # ses conteneurs des « orphelins » de ce projet : `down --remove-orphans
    # --volumes` (clean2.sh) les détruirait, volumes compris.
    if model.get("name") != app:
        refuse("name", f"le projet Compose s'appelle « {model.get('name')} » au lieu de « {app} » "
                       "(clé `name:` ou COMPOSE_PROJECT_NAME interdites)")

    for key in model:
        if key not in {"name", "services", "networks", "volumes", "secrets", "configs"} and not key.startswith("x-"):
            refuse("top-level", f"clé de premier niveau non autorisée : `{key}`")

    # ── Réseaux ──────────────────────────────────────────────────────────────
    networks = model.get("networks") or {}
    net_real = {}      # clé Compose → nom réel
    net_shared = set()  # clés Compose des réseaux partagés du lab
    for key, net in networks.items():
        net = net or {}
        real = net.get("name") or f"{app}_{key}"
        net_real[key] = real
        for k in net:
            if k not in {"name", "external", "ipam", "driver", "internal", "labels", "attachable", "enable_ipv6"}:
                refuse("network", f"réseau `{key}` : option `{k}` non autorisée")
        if net.get("external"):
            if real in SHARED_NETWORKS:
                net_shared.add(key)
            else:
                refuse("network", f"réseau externe « {real} » non autorisé (seuls dev-net et sso-net "
                                  "— nom réel sso-lab_sso-net — peuvent être rejoints)")
            continue
        if real in SHARED_NETWORKS:
            refuse("network", f"réseau `{key}` : « {real} » doit être déclaré `external: true`")
            continue
        # Réseau interne au projet : son nom réel doit porter le préfixe du
        # projet, sinon il désigne (ou usurpe) le réseau de quelqu'un d'autre.
        if not (real.startswith(app + "_") or real.startswith(app + "-")):
            refuse("network", f"réseau interne `{key}` : nom « {real} » hors du projet (préfixe « {app}_ » attendu)")
        if net.get("driver") not in (None, "", "bridge"):
            refuse("network", f"réseau `{key}` : pilote « {net.get('driver')} » non autorisé (bridge uniquement)")
        ipam = net.get("ipam") or {}
        if ipam.get("config") or ipam.get("driver") not in (None, "", "default"):
            refuse("network", f"réseau `{key}` : plan d'adressage (ipam) imposé non autorisé")

    # ── Volumes nommés ───────────────────────────────────────────────────────
    volumes = model.get("volumes") or {}
    for key, vol in volumes.items():
        vol = vol or {}
        real = vol.get("name") or f"{app}_{key}"
        if vol.get("external"):
            refuse("volume", f"volume externe « {real} » non autorisé — il désigne un volume que ce projet "
                             "ne possède pas (données d'une autre app, d'infra ou de sso-lab)")
            continue
        if not (real.startswith(app + "_") or real.startswith(app + "-")):
            refuse("volume", f"volume `{key}` : nom « {real} » hors du projet (préfixe « {app}_ » attendu)")
        # driver_opts {type: none, o: bind, device: /chemin} est un bind mount
        # déguisé en volume nommé.
        if vol.get("driver") not in (None, "", "local") or vol.get("driver_opts"):
            refuse("volume", f"volume `{key}` : `driver`/`driver_opts` non autorisés (bind mount déguisé)")
        for k in vol:
            if k not in {"name", "external", "driver", "driver_opts", "labels"}:
                refuse("volume", f"volume `{key}` : option `{k}` non autorisée")

    # ── secrets / configs de premier niveau ──────────────────────────────────
    for section in ("secrets", "configs"):
        for key, item in (model.get(section) or {}).items():
            item = item or {}
            if item.get("external"):
                refuse(section, f"{section} `{key}` externe non autorisé")
            if "file" in item and not inside(item["file"], app_dir):
                refuse(section, f"{section} `{key}` : fichier hors du dossier de l'app ({item['file']})")
            for k in item:
                if k not in {"name", "file", "environment", "content", "external"}:
                    refuse(section, f"{section} `{key}` : option `{k}` non autorisée")

    # ── Services ─────────────────────────────────────────────────────────────
    services = model.get("services") or {}
    if not services:
        refuse("compose", "aucun service déclaré")

    path_re = re.compile(r"^/(?:%s|%s-api)(?:/\S*)?$" % (re.escape(app), re.escape(app)))
    block_re = re.compile(r"^caddy\.(?:\d+_)?(?:handle|handle_path)(?:_\d+)?$")
    upstream_re = re.compile(r"^\{\{\s*upstreams(?:\s+(?:https?\s+)?\d{1,5})?\s*\}\}$")

    for sname, svc in services.items():
        svc = svc or {}
        where = f"service `{sname}`"

        for key, value in svc.items():
            if key in SERVICE_KEYS_FREE or key in SERVICE_KEYS_CHECKED or key.startswith("x-"):
                continue
            if value in (None, False, [], {}, ""):
                continue  # clé normalisée à vide par `compose config`
            refuse("clé", f"{where} : option `{key}` non autorisée")

        # Interdits nommés par le contrat — un message par cas.
        if svc.get("privileged"):
            refuse("privileged", f"{where} : `privileged` interdit")
        if svc.get("cap_add"):
            refuse("cap_add", f"{where} : `cap_add` interdit ({', '.join(map(str, svc['cap_add']))})")
        if svc.get("devices"):
            refuse("devices", f"{where} : `devices` interdit")
        if svc.get("device_cgroup_rules"):
            refuse("device_cgroup_rules", f"{where} : `device_cgroup_rules` interdit")
        if svc.get("network_mode") not in (None, ""):
            refuse("network_mode", f"{where} : `network_mode: {svc['network_mode']}` interdit "
                                   "(host, container:…, service:… — seuls les réseaux déclarés sont permis)")
        if svc.get("pid") not in (None, ""):
            refuse("pid", f"{where} : `pid: {svc['pid']}` interdit")
        if svc.get("ipc") not in (None, "", "private", "none"):
            refuse("ipc", f"{where} : `ipc: {svc['ipc']}` interdit")

        # container_name
        cname = svc.get("container_name")
        if cname is not None and not str(cname).startswith(app + "-"):
            refuse("container_name", f"{where} : `container_name: {cname}` ne commence pas par « {app}- »")
        hostname = svc.get("hostname")
        if hostname is not None and not (hostname == app or str(hostname).startswith(app + "-")):
            refuse("hostname", f"{where} : `hostname: {hostname}` ne commence pas par « {app}- »")

        # build
        build = svc.get("build")
        if build:
            if isinstance(build, str):
                build = {"context": build}
            ctx = build.get("context", app_dir)
            if re.match(r"^[a-zA-Z][a-zA-Z0-9+.-]*://|^git@", str(ctx)):
                refuse("build", f"{where} : contexte de build distant non autorisé ({ctx})")
            elif not inside(ctx, app_dir):
                refuse("build", f"{where} : contexte de build hors du dossier de l'app ({ctx})")
            else:
                dockerfile = build.get("dockerfile")
                if dockerfile and not inside(os.path.join(ctx, dockerfile), app_dir):
                    refuse("build", f"{where} : Dockerfile hors du dossier de l'app ({dockerfile})")
            for name, extra in (build.get("additional_contexts") or {}).items():
                if not inside(str(extra), app_dir):
                    refuse("build", f"{where} : contexte additionnel `{name}` hors du dossier de l'app")
            for k, v in build.items():
                if k in {"context", "dockerfile", "args", "target", "labels", "additional_contexts",
                         "dockerfile_inline", "platforms", "pull", "no_cache", "shm_size", "tags"}:
                    continue
                if v in (None, False, [], {}, ""):
                    continue
                refuse("build", f"{where} : option de build `{k}` non autorisée")

        # env_file : uniquement dans le dossier de l'app (../sso-lab/.env
        # injecterait le mot de passe admin de Keycloak dans le conteneur).
        for ef in svc.get("env_file") or []:
            path = ef.get("path") if isinstance(ef, dict) else ef
            if not inside(str(path), app_dir):
                refuse("env_file", f"{where} : `env_file` hors du dossier de l'app ({path})")

        # volumes
        for vol in svc.get("volumes") or []:
            if isinstance(vol, str):
                refuse("volume", f"{where} : montage non normalisé ({vol})")
                continue
            vtype = vol.get("type")
            source = str(vol.get("source", ""))
            target = str(vol.get("target", ""))
            if "docker.sock" in source or "docker.sock" in target:
                refuse("docker.sock", f"{where} : montage de docker.sock interdit ({source} → {target})")
                continue
            if vtype == "bind":
                if not inside(source, app_dir):
                    refuse("bind", f"{where} : bind mount hors du dossier de l'app ({source})")
                if (vol.get("bind") or {}).get("propagation") not in (None, "", "rprivate", "private"):
                    refuse("bind", f"{where} : propagation de montage non autorisée ({source})")
            elif vtype == "volume":
                if source and source not in volumes:
                    refuse("volume", f"{where} : volume « {source} » non déclaré dans ce projet")
            elif vtype == "tmpfs":
                pass
            else:
                refuse("volume", f"{where} : type de montage « {vtype} » non autorisé")

        # ports
        for port in svc.get("ports") or []:
            published = str(port.get("published", "")) if isinstance(port, dict) else str(port)
            if published not in allowed_ports:
                shown = published or "(port hôte aléatoire)"
                refuse("ports", f"{where} : port publié {shown} absent de la ligne .ports de l'app "
                                f"({', '.join(sorted(allowed_ports)) or 'aucun port réservé'})")
            if isinstance(port, dict) and port.get("mode") not in (None, "ingress"):
                refuse("ports", f"{where} : mode de publication « {port.get('mode')} » non autorisé")

        # networks du service
        svc_nets = svc.get("networks") or {}
        if isinstance(svc_nets, list):
            svc_nets = {n: None for n in svc_nets}
        on_shared = False
        for nkey, nconf in svc_nets.items():
            nconf = nconf or {}
            if nkey not in networks:
                refuse("network", f"{where} : réseau `{nkey}` non déclaré")
                continue
            shared = nkey in net_shared
            on_shared = on_shared or shared
            for k, v in nconf.items():
                if v in (None, [], {}, ""):
                    continue
                if k == "aliases" and not shared:
                    continue
                # Sur un réseau partagé, un alias est un nom DNS vu par TOUTES
                # les apps : `aliases: [keycloak]` usurperait le SSO.
                refuse("network", f"{where} : option `{k}` non autorisée sur le réseau `{nkey}`"
                                  + (" (réseau partagé du lab)" if shared else ""))
        # Le nom d'un service est lui-même un alias DNS sur chaque réseau qu'il
        # rejoint. Sur dev-net/sso-net, « postgres », « keycloak » ou « redis »
        # répondraient à la place d'un service d'une autre app.
        if on_shared and not (sname in ("backend", "frontend") or sname == app or sname.startswith(app + "-")):
            refuse("service", f"{where} : un service relié à dev-net/sso-net doit s'appeler `backend`, `frontend` "
                              f"ou « {app}-… » (son nom y devient un nom DNS visible de toutes les apps)")
        if sname in reserved_names or (cname and cname in reserved_names):
            refuse("service", f"{where} : nom déjà porté par un service ou un conteneur du lab")

        # labels
        labels = svc.get("labels") or {}
        if isinstance(labels, list):
            labels = dict(item.split("=", 1) if "=" in item else (item, "") for item in labels)
        for lkey, lval in labels.items():
            lval = "" if lval is None else str(lval)
            if lkey.startswith("com.docker."):
                refuse("labels", f"{where} : label `{lkey}` réservé à Docker")
                continue
            if not (lkey == "caddy" or lkey.startswith("caddy.") or lkey.startswith("caddy_")):
                continue
            if lkey == "caddy":
                # Le site : uniquement le domaine du lab. Toute autre valeur
                # ouvrirait un autre site (ou un autre port) dans le Caddy commun.
                if lval != domain:
                    refuse("caddy", f"{where} : label `caddy: {lval}` — seul le domaine du lab (${{DOMAIN}}) est autorisé")
                continue
            if lkey.startswith("caddy_"):
                refuse("caddy", f"{where} : label `{lkey}` non autorisé (second site Caddy)")
                continue
            if block_re.match(lkey):
                # Un seul chemin par matcher : « /app/* /storage-api/* » en
                # listerait deux, dont celui d'une autre app.
                if not path_re.match(lval):
                    refuse("caddy", f"{where} : label `{lkey}: {lval}` — le chemin doit être /{app} ou "
                                    f"/{app}-api (ou un sous-chemin de ceux-ci)")
                continue
            parts = lkey.split(".")
            parent = ".".join(parts[:2])
            if len(parts) >= 3 and block_re.match(parent):
                sub = re.sub(r"^\d+_|_\d+$", "", parts[2])
                if sub not in CADDY_SUBDIRECTIVES:
                    refuse("caddy", f"{where} : label `{lkey}` — directive `{sub}` non autorisée dans un bloc de "
                                    f"routage (autorisées : {', '.join(sorted(CADDY_SUBDIRECTIVES))})")
                elif sub == "reverse_proxy" and len(parts) == 3 and not upstream_re.match(lval.strip()):
                    refuse("caddy", f"{where} : label `{lkey}: {lval}` — la cible doit être ce service "
                                    "(`{{upstreams <port>}}`)")
                continue
            # Tout le reste est une directive au niveau du SITE (caddy.respond,
            # caddy.reverse_proxy, caddy.tls, caddy.import…) : elle s'appliquerait
            # à toutes les apps du domaine.
            refuse("caddy", f"{where} : label `{lkey}` — directive Caddy hors d'un bloc handle/handle_path, "
                            "elle s'appliquerait à tout le site")

        # logging : pilotes locaux uniquement.
        logging = svc.get("logging") or {}
        if logging.get("driver") not in (None, "", "json-file", "local", "none"):
            refuse("logging", f"{where} : pilote de journalisation « {logging.get('driver')} » non autorisé")

        # deploy : uniquement des limites de ressources.
        deploy = svc.get("deploy") or {}
        for k, v in deploy.items():
            if k == "resources":
                for rk, rv in (v or {}).items():
                    if rk == "limits":
                        continue
                    if rk == "reservations" and not (rv or {}).get("devices") and not (rv or {}).get("generic_resources"):
                        continue
                    refuse("deploy", f"{where} : `deploy.resources.{rk}` non autorisé (accès à un périphérique)")
            elif k in {"replicas", "restart_policy", "labels", "mode"}:
                continue
            elif v not in (None, [], {}, ""):
                refuse("deploy", f"{where} : `deploy.{k}` non autorisé")

        for section in ("secrets", "configs"):
            for item in svc.get(section) or []:
                src = item.get("source") if isinstance(item, dict) else item
                if src not in (model.get(section) or {}):
                    refuse(section, f"{where} : {section} « {src} » non déclaré dans ce projet")

    for line in sorted(set(reasons)):
        print(line)
    return 1 if reasons else 0


if __name__ == "__main__":
    sys.exit(main())
