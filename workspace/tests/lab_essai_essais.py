#!/usr/bin/env python3
"""Essais de la commande `lab-essai` contre le faux moteur de tests/faux_mcp.py.

Lancé par verify.sh DANS un espace (`python3 /t/lab_essai_essais.py`) ; se lance aussi à la main :
    LAB_ESSAI_CMD=workspace/bin/lab-essai python3 workspace/tests/lab_essai_essais.py

Tout est en boucle locale : le faux moteur, et un « piège » — un port qui ne doit JAMAIS
recevoir de connexion (il joue le proxy d'environnement et la cible d'une redirection).
Le jeton est factice. Une ligne par contrôle : `OK <libellé>` ou `KO <libellé> — <détail>`,
puis `BILAN <verts> <rouges>` ; code de sortie 1 s'il y a un rouge.
"""
import os
import signal
import socket
import subprocess
import sys
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import faux_mcp  # noqa: E402

CMD = os.environ.get("LAB_ESSAI_CMD", "lab-essai")
JETON = "labws_factice-" + os.urandom(12).hex()
APP = "demo-app"
URL_ESSAI = "https://lab.exemple.test/dev-alice/"
API_ESSAI = "https://lab.exemple.test/dev-alice-api/"

verts = rouges = 0


def controle(libelle, vrai, detail=""):
    global verts, rouges
    if vrai:
        verts += 1
        print(f"OK {libelle}", flush=True)
    else:
        rouges += 1
        print(f"KO {libelle} — {str(detail)[:600]!r}", flush=True)


# ── faux moteur et piège ─────────────────────────────────────────────────────
faux = faux_mcp.Faux(JETON, None, APP)
serveur = faux.demarre(0)
threading.Thread(target=serveur.serve_forever, daemon=True).start()
URL = f"http://127.0.0.1:{serveur.server_address[1]}/mcp"

piege = socket.socket()
piege.bind(("127.0.0.1", 0))
piege.listen(8)
piege_vu = []


def _garde_piege():
    while True:
        c, _ = piege.accept()
        try:
            c.settimeout(1)
            piege_vu.append(c.recv(4096))
        except OSError:
            piege_vu.append(b"")
        c.close()


threading.Thread(target=_garde_piege, daemon=True).start()
PIEGE = f"http://127.0.0.1:{piege.getsockname()[1]}"
faux.piege = PIEGE + "/mcp"

ferme = socket.socket()
ferme.bind(("127.0.0.1", 0))
PORT_FERME = ferme.getsockname()[1]
ferme.close()


def env(**plus):
    e = {"PATH": os.environ.get("PATH", "/usr/local/bin:/usr/bin:/bin"), "LANG": "C.UTF-8",
         "LAB_APP": APP, "LAB_UID": "alice", "LAB_MCP_URL": URL, "LAB_MCP_TOKEN": JETON, "LAB_ESSAI_POLL_S": "0.05"}
    for k, v in plus.items():
        if v is None:
            e.pop(k, None)
        else:
            e[k] = v
    return e


sorties = []   # tout ce que la commande a affiché, pour les contrôles transverses de la fin


def lance(*args, scenario="succes", delai=60, **plus):
    faux.regle(scenario)
    r = subprocess.run([CMD, *args], env=env(**plus), capture_output=True, text=True, timeout=delai, cwd="/")
    sorties.append(r.stdout + r.stderr)
    return r.returncode, r.stdout, r.stderr


# ── 1. Construire : journal au fil de l'eau, adresse à la fin ────────────────
rc, out, err = lance()
l = out.splitlines()
controle("construire : code 0", rc == 0, (rc, err))
controle("construire : l'adresse est seule sur la dernière ligne", l and l[-1] == URL_ESSAI, l[-3:])
attendues = faux_mcp.lignes(1, 12)
vues = [x for x in l if x.startswith("[build] ligne ")]
controle("construire : chaque ligne du journal affichée une fois, dans l'ordre", vues == attendues, vues)
controle("construire : les lignes d'étape du journal sont affichées une fois",
         out.count("étape « source »") == 1 and out.count("étape « build »") == 1, out)
controle("construire : la file d'attente est dite une fois par changement (2 devant, puis 1)",
         out.count("2 job(s) devant") == 1 and out.count("1 job(s) devant") == 1, out)
controle("construire : groupes, services, terme et adresse de l'API affichés",
         "developers, famille" in out and "backend (running)" in out and "14/10/2026 à 03:02" in out and API_ESSAI in out, out)
controle("construire : dit que l'essai a sa propre base", "base" in out.lower() and "à part" in out, out)
controle("construire : rien sur la sortie d'erreur", err == "", err)
controle("construire : outils appelés = preview_deploy puis job_status seulement",
         faux.appels[0] == "preview_deploy" and set(faux.appels[1:]) == {"job_status"} and len(faux.appels) > 3, faux.appels)

rc, out, err = lance(scenario="sans_frontend")
controle("app sans frontend : la dernière ligne est l'adresse de l'API", rc == 0 and out.splitlines()[-1] == API_ESSAI, (rc, out[-200:]))
rc, out, err = lance(scenario="degrade")
controle("build réussi mais un service arrêté : code 0, état « dégradé » et service fautif affichés",
         rc == 0 and "dégradé" in out and "backend (exited)" in out and out.splitlines()[-1] == URL_ESSAI, (rc, out[-400:]))

# ── 2. Journal : volume, troncature, contenu hostile ─────────────────────────
rc, out, err = lance(scenario="gros_journal")
l = out.splitlines()
vues = [x for x in l if x.startswith("[build] ligne ")]
controle("journal plus gros que ce que le moteur rend d'un coup : aucune ligne répétée, l'écart est dit",
         rc == 0 and len(vues) == len(set(vues)) == 3 + 1000 + 2 and "1500 ligne(s) du journal non affichée(s)" in out
         and vues[:3] == faux_mcp.lignes(1, 3) and vues[3] == "[build] ligne 1504" and vues[-1] == "[build] ligne 2505",
         (rc, len(vues), vues[:5], vues[-2:]))
rc, out, err = lance(scenario="journal_tronque")
vues = [x for x in out.splitlines() if x.startswith("[build] ligne ")]
controle("journal dont le moteur a jeté le début : ni répétition ni ligne sautée", rc == 0 and vues == faux_mcp.lignes(1, 5), vues)
rc, out, err = lance(scenario="fuite")
controle("une ligne de journal qui porterait le jeton : il est masqué", rc == 0 and JETON not in out + err and "LAB_MCP_TOKEN=***" in out, out)
controle("séquences de terminal du journal retirées (pas d'ESC ni de BEL), tabulation gardée",
         "\x1b" not in out and "\x07" not in out and "tab\tgardée" in out, repr(out[:300]))

# ── 3. Échecs du job ─────────────────────────────────────────────────────────
rc, out, err = lance(scenario="refus")
controle("refus du contrôle de sûreté : code 1", rc == 1, rc)
controle("refus : étape, raison et chaque `reasons` affichées",
         "« validate »" in err and "refusé par le contrôle de sûreté" in err
         and "  - [ports] le service backend publie le port 8088" in err and "  - [bind] montage hors du dossier de l'app : /etc" in err, err)
controle("refus : aucune adresse affichée", "https://" not in out, out)
rc, out, err = lance(scenario="echec_build")
controle("build en échec : code 1, étape « build », journal affiché avant", rc == 1 and "« build »" in err and "npm ERR! code 1" in out, (rc, err))

for scenario, etape, morceau in (("echec_lock", "lock", "verrou du lab occupé"), ("echec_interne", "interne", "inexploitable"),
                                 ("echec_etape_inconnue", "etape-de-demain", "raison de demain")):
    rc, out, err = lance(scenario=scenario)
    controle(f"job en échec à l'étape « {etape} » (contrat v2 : toute étape inconnue est un échec ordinaire) : code 1, `error` affichée",
             rc == 1 and f"« {etape} »" in err and morceau in err and "https://" not in out, (rc, err))
controle("étape inconnue : ses `reasons` sont affichées aussi", "  - précision de demain" in err, err)

# ── 4. Erreurs immédiates du moteur ──────────────────────────────────────────
for scenario, morceau in (("no_workspace", "ouvrir d'abord son espace"), ("queue_full", "Trop de jobs"),
                          ("unavailable", "pas de domaine")):
    rc, out, err = lance(scenario=scenario)
    controle(f"{scenario} : code 1, phrase du moteur affichée, code d'erreur nommé", rc == 1 and morceau in err and scenario in err, (rc, err))
rc, out, err = lance(scenario="invalid")
controle("erreur immédiate avec `reasons` : chacune affichée", rc == 1 and "  - raison un" in err and "  - raison deux" in err, err)
rc, out, err = lance(LAB_APP="autre-app")
controle("projet inconnu du moteur (not_found) : code 1, dit par le moteur", rc == 1 and "not_found" in err and "Projet inconnu" in err, (rc, err))
rc, out, err = lance(scenario="outil_inconnu")
controle("moteur sans l'outil preview_deploy : code 1, dit que le moteur n'est pas à jour, rien de lancé",
         rc == 1 and "preview_deploy" in err and "pas (encore) à jour" in err, (rc, err))

# ── 5. 409 job_exists : la commande suit le job en cours ─────────────────────
rc, out, err = lance(scenario="job_exists")
l = out.splitlines()
controle("job_exists (un build d'essai tourne déjà) : code 0, le job en cours est suivi jusqu'à l'adresse",
         rc == 0 and "déjà en cours" in out and "dejaencours00001" in out and l[-1] == URL_ESSAI
         and [x for x in l if x.startswith("[déjà]")] == faux_mcp.lignes(1, 6, "déjà"), (rc, out, err))
controle("job_exists : prévient que ce build a commencé avant la commande", "avant cette commande" in out, out)
controle("job_exists : un seul preview_deploy, aucun second build lancé", faux.appels.count("preview_deploy") == 1, faux.appels)
rc, out, err = lance(scenario="job_exists_autre")
l = out.splitlines()
controle("job_exists (c'est un déploiement qui tourne) : il est attendu, puis l'essai est lancé et suivi",
         rc == 0 and "(deploy) est terminé" in out and faux.appels.count("preview_deploy") == 2 and l[-1] == URL_ESSAI
         and [x for x in l if x.startswith("[build] ligne ")] == faux_mcp.lignes(1, 12), (rc, out, err, faux.appels))

# ── 6. status et stop ────────────────────────────────────────────────────────
rc, out, err = lance("status")
controle("status : code 0, état, projet, groupes, terme, adresse en dernière ligne",
         rc == 0 and "en service" in out and APP in out and "developers" in out and "14/10/2026 à 03:02" in out
         and out.splitlines()[-1] == URL_ESSAI and faux.appels == ["preview_status"], (rc, out, faux.appels))
rc, out, err = lance("status", scenario="status_absent")
controle("status sans essai : code 0, « aucun essai », aucune adresse", rc == 0 and "aucun essai" in out and "https://" not in out, (rc, out))
rc, out, err = lance("status", scenario="status_autre")
controle("status quand l'adresse montre un autre projet : il est nommé, et dit comme tel",
         rc == 0 and "autre-projet" in out and "AUTRE de vos projets" in out and "la remplacera" in out, (rc, out))
rc, out, err = lance("status", scenario="status_degrade")
controle("status dégradé : code 0, service fautif nommé", rc == 0 and "dégradé" in out and "backend (unhealthy)" in out, (rc, out))
rc, out, err = lance("stop")
controle("stop : code 0, dit arrêté, un seul appel preview_stop", rc == 0 and "arrêté" in out and faux.appels == ["preview_stop"], (rc, out, faux.appels))
rc, out, err = lance("stop", scenario="stop_rien")
controle("stop quand l'adresse ne montrait pas ce projet : code 0, « rien à arrêter »", rc == 0 and "Rien à arrêter" in out, (rc, out))
rc, out, err = lance("stop", scenario="stop_occupe")
controle("stop refusé par `busy` (contrat v2) : code 1, « le lab est occupé », phrase du moteur, invite à réessayer",
         rc == 1 and "Le lab est occupé" in err and "essai est en construction" in err and "réessayer" in err, (rc, err))
rc, out, err = lance("status", scenario="status_sans_terme")
controle("status avec `expires_at` nul alors que l'essai tourne (contrat v2) : code 0, état et adresse affichés, pas de ligne de terme",
         rc == 0 and "en service" in out and "Valable" not in out and "Construit" not in out and out.splitlines()[-1] == URL_ESSAI and err == "", (rc, out, err))
for scenario, morceau in (("status_failed", "inexploitable"), ("status_unavailable", "absent de ce lab")):
    rc, out, err = lance("status", scenario=scenario)
    controle(f"status refusé par `{scenario[7:]}` (contrat v2) : code 1, phrase du moteur, dit que le projet n'est pas en cause",
             rc == 1 and morceau in err and scenario[7:] in err and "pas le projet" in err and out == "", (rc, out, err))

# ── 7. Environnement et usage : code 2, rien n'est appelé ────────────────────
for nom in ("LAB_APP", "LAB_MCP_URL", "LAB_MCP_TOKEN"):
    rc, out, err = lance(**{nom: None})
    controle(f"{nom} absente : code 2, la variable est nommée, le moteur n'est pas appelé",
             rc == 2 and nom in err and faux.appels == [] and faux.requetes == 0, (rc, err, faux.appels))
rc, out, err = lance(LAB_MCP_TOKEN="")
controle("LAB_MCP_TOKEN vide : code 2", rc == 2 and "LAB_MCP_TOKEN" in err, (rc, err))
rc, out, err = lance(LAB_MCP_URL="http://exemple.test/mcp")
controle("LAB_MCP_URL en http hors boucle locale : code 2, aucun appel (le jeton ne part pas en clair)",
         rc == 2 and "LAB_MCP_URL invalide" in err, (rc, err))
rc, out, err = lance(LAB_APP="../etc")
controle("LAB_APP invalide : code 2", rc == 2 and "LAB_APP" in err, (rc, err))
for args in (("deploy",), ("status", "x"), ("--json",)):
    rc, out, err = lance(*args)
    controle(f"argument inconnu « {' '.join(args)} » : code 2, usage, le moteur n'est pas appelé",
             rc == 2 and "Usage : lab-essai" in err and faux.requetes == 0, (rc, err))
rc, out, err = lance("--help", LAB_MCP_TOKEN=None)
controle("--help : code 0, usage, même sans environnement", rc == 0 and "Usage : lab-essai" in out, (rc, out, err))

# ── 8. Moteur injoignable, jeton refusé, réponses qui ne sont pas du moteur ──
rc, out, err = lance(LAB_MCP_URL=f"http://127.0.0.1:{PORT_FERME}/mcp")
controle("moteur injoignable (port fermé) : code 1, « injoignable », dit que rien n'a été fait",
         rc == 1 and "injoignable" in err and "Rien n'a été fait" in err, (rc, err))
rc, out, err = lance(LAB_MCP_TOKEN="labws_un-autre-jeton")
controle("jeton refusé (401) : code 1, dit quoi faire (rouvrir l'espace)", rc == 1 and "refusé" in err and "rouvrir l'espace" in err, (rc, err))
controle("jeton refusé : le jeton envoyé n'est pas affiché", "labws_un-autre-jeton" not in out + err, err)
rc, out, err = lance(scenario="interdit")
controle("403 du moteur : code 1, sa phrase est affichée", rc == 1 and "plus un développeur inscrit" in err, (rc, err))
rc, out, err = lance(scenario="passerelle")
controle("502 de la passerelle (moteur arrêté) : code 1, « injoignable »", rc == 1 and "injoignable" in err and "502" in err, (rc, err))
rc, out, err = lance(scenario="pas_json")
controle("réponse qui n'est pas du JSON : code 1, message clair", rc == 1 and "illisible" in err, (rc, err))
rc, out, err = lance(scenario="perdu")
controle("job disparu pendant le suivi (moteur redémarré) : code 1, renvoie à `lab-essai status`",
         rc == 1 and "n'existe plus" in err and "lab-essai status" in err, (rc, err))
rc, out, err = lance(scenario="coupure", LAB_ESSAI_POLL_S="0.05")
controle("deux appels de suivi sans réponse : la commande insiste et finit à l'adresse, sans ligne répétée",
         rc == 0 and out.splitlines()[-1] == URL_ESSAI
         and [x for x in out.splitlines() if x.startswith("[build] ligne ")] == faux_mcp.lignes(1, 12), (rc, out, err))

# ── 9. Le jeton ne va nulle part ailleurs que LAB_MCP_URL ────────────────────
piege_vu.clear()
proxys = {k: PIEGE for k in ("http_proxy", "https_proxy", "HTTP_PROXY", "HTTPS_PROXY", "all_proxy", "ALL_PROXY")}
rc, out, err = lance("status", **proxys)
time.sleep(0.3)
controle("variables *_proxy posées dans l'environnement : ignorées (aucune connexion au proxy), l'appel aboutit",
         rc == 0 and piege_vu == [] and faux.appels == ["preview_status"], (rc, err, piege_vu))
rc, out, err = lance("status", scenario="redirection")
time.sleep(0.3)
controle("redirection rendue par le serveur : non suivie (aucune connexion à la cible), code 1, dit pourquoi",
         rc == 1 and piege_vu == [] and "redirection" in err, (rc, err, piege_vu))

# ── 10. Ctrl-C pendant le suivi ; aucun processus lancé ──────────────────────
for nom_signal, sig in (("Ctrl-C (SIGINT)", signal.SIGINT), ("arrêt de la tâche (SIGTERM)", signal.SIGTERM)):
    faux.regle("long")
    p = subprocess.Popen([CMD], env=env(), stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, cwd="/")
    fin = time.time() + 20
    while time.time() < fin and faux.appels.count("job_status") < 4:
        time.sleep(0.05)
    try:
        with open(f"/proc/{p.pid}/task/{p.pid}/children") as f:
            enfants = f.read().split()
        with open(f"/proc/{p.pid}/cmdline", "rb") as f:
            ligne_cmd = f.read()
    except OSError as exc:
        enfants, ligne_cmd = [f"illisible : {exc}"], b""
    p.send_signal(sig)
    try:
        out, err = p.communicate(timeout=15)
    except subprocess.TimeoutExpired:
        p.kill()
        out, err = p.communicate()
    sorties.append(out + err)
    if sig == signal.SIGINT:
        controle("pendant le suivi : la commande n'a lancé aucun processus", enfants == [], enfants)
        controle("pendant le suivi : le jeton n'est pas dans la ligne de commande du processus",
                 JETON.encode() not in ligne_cmd and b"lab-essai" in ligne_cmd, ligne_cmd)
    controle(f"{nom_signal} pendant le suivi : sortie propre, code 1", p.returncode == 1, (p.returncode, err))
    controle(f"{nom_signal} : dit que le build N'EST PAS arrêté, nomme le job et la façon de reprendre",
             "N'EST PAS arrêté" in err and "0000000000000001" in err and "`lab-essai` reprend le suivi" in err, err)
    controle(f"{nom_signal} : rien n'est demandé au moteur à l'interruption (ni arrêt, ni autre appel)",
             set(faux.appels) == {"preview_deploy", "job_status"} and "preview_stop" not in faux.appels, faux.appels)

# Après Ctrl-C, relancer la commande reprend le MÊME job (scénario « long » encore en cours).
faux.scenario = "long"
p = subprocess.Popen([CMD], env=env(), stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, cwd="/")
time.sleep(1.5)
p.send_signal(signal.SIGINT)
out, err = p.communicate(timeout=15)
sorties.append(out + err)
controle("relancer après Ctrl-C : la commande reprend le suivi du job en cours (job_exists)",
         "déjà en cours" in out and "0000000000000001" in out and "… le build continue" in out, (out[:300], err))

# ── 11. Sortie fermée par le lecteur, et contrôles transverses ───────────────
faux.regle("gros_journal")
r = subprocess.run(f"{CMD} | head -1", shell=True, env=env(), capture_output=True, text=True, timeout=60, cwd="/")
sorties.append(r.stdout + r.stderr)
controle("sortie fermée par le lecteur (`lab-essai | head -1`) : pas de trace Python", "Traceback" not in r.stderr and "Exception" not in r.stderr, r.stderr)

tout = "\n".join(sorties)
controle("sur l'ensemble des essais : aucune trace Python affichée", "Traceback" not in tout and 'File "' not in tout, "")
controle("sur l'ensemble des essais : le jeton n'apparaît dans aucune sortie", JETON not in tout, "")

print(f"BILAN {verts} {rouges}", flush=True)
sys.exit(1 if rouges else 0)
