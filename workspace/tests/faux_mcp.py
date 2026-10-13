#!/usr/bin/env python3
"""Faux serveur MCP (Streamable HTTP, réponses JSON, sans session) pour verify.sh — bibliothèque
standard seule.

Deux usages :

1. PROUVER que Claude Code et Mistral Vibe lisent bien leur déclaration et envoient l'en-tête
   `Authorization: Bearer <valeur de LAB_MCP_TOKEN>` tirée de l'environnement.
2. Jouer le MOTEUR du lab devant la commande `lab-essai` (contrat « essai-dev », I2) : outils
   `preview_deploy`, `preview_status`, `preview_stop` et `job_status`, selon un SCÉNARIO.

Il parle le transport du vrai moteur (`lab-mcp/labmcp/mcp_entry.py` : FastMCP 1.30,
`stateless_http=True, json_response=True`), relevé sur le vrai SDK le 2026-10-13 :
  - un POST JSON-RPC par appel sur le chemin exact, `tools/call` sans `initialize` préalable ;
  - jeton refusé : HTTP 401 et corps `{"error": "unauthorized", "detail": …}` (pas du JSON-RPC) ;
  - résultat d'outil : `{"content": [{"type": "text", "text": "<objet JSON>"}], "isError": false}` ;
  - erreur du moteur : `isError: true`, texte `Error executing tool <outil>: {"error", "detail", …}` ;
  - outil inconnu : `isError: true`, texte `Unknown tool: <outil>`.

Refuse (401) toute requête sans le bon jeton. Chaque requête est journalisée — sans le jeton —
dans le fichier donné : `<méthode JSON-RPC> auth=OK|KO|ABSENT agent=<User-Agent>[ outil=<nom>]`.

Usage : faux_mcp.py <port> <fichier journal>
        jeton attendu : variable FAUX_MCP_JETON ; scénario : FAUX_MCP_SCENARIO (défaut « succes ») ;
        projet attendu : FAUX_MCP_APP (défaut « demo-app »).
Importable : `Faux(jeton, journal)` puis `.demarre(port)` — voir tests/lab_essai_essais.py.
"""
import json
import os
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

BASE = "https://lab.exemple.test"


class ErreurMoteur(Exception):
    def __init__(self, code, detail, **plus):
        super().__init__(code)
        self.corps = {"error": code, "detail": detail, **plus}


def essai(app, uid="alice", **plus):
    """L'objet « essai » d'I2, en service et montrant `app`."""
    objet = {
        "state": "running", "current": True, "app": app,
        "url": f"{BASE}/dev-{uid}/", "api_url": f"{BASE}/dev-{uid}-api/",
        "groups": ["developers", "famille"], "built_at": "2026-10-13T15:02:11+02:00",
        "expires_at": "2026-10-14T03:02:11+02:00",
        "services": [{"service": "backend", "state": "running"}, {"service": "frontend", "state": "running"}],
    }
    objet.update(plus)
    return objet


ABSENT = {"state": "absent", "current": False, "app": None, "url": None, "api_url": None,
          "groups": [], "built_at": None, "expires_at": None, "services": []}


class Job:
    """Un job simulé : chaque appel à `job_status` avance d'un cran (déterministe, sans horloge)."""

    def __init__(self, ident, app, kind, crans, resultat, sans_fin=False, garde=3000):
        self.ident, self.app, self.kind = ident, app, kind
        self.crans, self.resultat, self.sans_fin = list(crans), resultat, sans_fin
        self.garde = garde         # comme le moteur : seules les dernières lignes sont gardées, les autres comptées
        self.journal, self.perdues, self.cran, self.devant, self.etat = [], 0, 0, 0, "queued"

    def vue(self, tail):
        if self.cran < len(self.crans):
            c = self.crans[self.cran]
            self.cran += 1
            self.etat, self.devant = c.get("state", "running"), c.get("devant", 0)
            self.journal += c.get("lignes", [])
        elif not self.sans_fin:
            self.etat = "succeeded" if self.resultat.get("ok") else "failed"
        else:
            self.journal.append(f"… le build continue (ligne {len(self.journal) + 1})")
        if len(self.journal) > self.garde:
            self.perdues += len(self.journal) - self.garde
            self.journal = self.journal[-self.garde:]
        fini = self.etat in ("succeeded", "failed")
        return {
            "job_id": self.ident, "kind": self.kind, "app": self.app, "state": self.etat, "terminal": fini,
            "step": self.resultat.get("step") if fini else "build", "launched_by": "alice",
            "created_at": "2026-10-13T13:00:00Z", "started_at": "2026-10-13T13:00:01Z",
            "ended_at": "2026-10-13T13:02:11Z" if fini else None,
            "jobs_ahead": self.devant if self.etat == "queued" else 0,
            "log_lines_total": len(self.journal) + self.perdues,
            "log": self.journal[-tail:] if tail > 0 else [],
            "result": self.resultat if fini else None,
        }


def lignes(debut, fin, prefixe="build"):
    return [f"[{prefixe}] ligne {i:03d}" for i in range(debut, fin + 1)]


class Faux:
    """État du faux moteur. `scenario` se change entre deux essais ; `appels` garde les outils appelés."""

    def __init__(self, jeton, journal=None, app="demo-app", scenario="succes"):
        self.attendu = "Bearer " + jeton
        self.jeton, self.journal, self.app = jeton, journal, app
        self.verrou = threading.Lock()
        self.piege = ""            # adresse vers laquelle le scénario « redirection » renvoie
        self.regle(scenario)

    def regle(self, scenario):
        with self.verrou:
            self.scenario, self.jobs, self.appels, self.n, self.requetes = scenario, {}, [], 0, 0
            if scenario in ("job_exists", "job_exists_autre"):
                kind = "preview" if scenario == "job_exists" else "deploy"
                res = self._reussi() if kind == "preview" else {"ok": True, "step": "done", "sha": "6d7b9d5", "exit_code": 0}
                self.jobs["dejaencours00001"] = Job("dejaencours00001", self.app, kind, [
                    {"lignes": lignes(1, 4, "déjà")}, {"lignes": lignes(5, 6, "déjà")}], res)

    # ── résultats de job ──
    def _reussi(self):
        return {"ok": True, "step": "done", "preview": essai(self.app)}

    def _nouveau_job(self):
        self.n += 1
        ident = f"{self.n:016x}"
        s = self.scenario
        if s == "refus":
            job = Job(ident, self.app, "preview", [{"lignes": ["══ étape « source »", "══ étape « validate »"]}], {
                "ok": False, "step": "validate", "error": "le dépôt est refusé par le contrôle de sûreté",
                "reasons": ["[ports] le service backend publie le port 8088", "[bind] montage hors du dossier de l'app : /etc"]})
        elif s == "echec_build":
            job = Job(ident, self.app, "preview", [{"lignes": ["══ étape « build »", "npm ERR! code 1"]}],
                      {"ok": False, "step": "build", "error": "le build a échoué", "reasons": []})
        elif s == "echec_lock":     # contrat v2 : étapes d'échec propres au moteur, hors de celles d'I1
            job = Job(ident, self.app, "preview", [{"lignes": ["══ attente du verrou du lab"]}],
                      {"ok": False, "step": "lock", "error": "verrou du lab occupé trop longtemps — rien n'a été lancé"})
        elif s == "echec_interne":
            job = Job(ident, self.app, "preview", [{"lignes": ["══ étape « up »"]}],
                      {"ok": False, "step": "interne", "error": "sortie du script inexploitable", "reasons": []})
        elif s == "echec_etape_inconnue":
            job = Job(ident, self.app, "preview", [{"lignes": ["…"]}],
                      {"ok": False, "step": "etape-de-demain", "error": "raison de demain", "reasons": ["précision de demain"]})
        elif s == "long":
            job = Job(ident, self.app, "preview", [{"lignes": lignes(1, 3)}], {}, sans_fin=True)
        elif s == "perdu":
            job = Job(ident, self.app, "preview", [{"lignes": lignes(1, 2)}], {})
        elif s == "gros_journal":   # 2500 lignes d'un coup : plus que ce que `tail` (1000) peut rendre
            job = Job(ident, self.app, "preview", [{"lignes": lignes(1, 3)}, {"lignes": lignes(4, 2503)},
                                                    {"lignes": lignes(2504, 2505)}], self._reussi())
        elif s == "journal_tronque":  # le moteur ne garde que ses dernières lignes (ici 3) et compte les autres
            job = Job(ident, self.app, "preview", [{"lignes": lignes(1, 2)}, {"lignes": lignes(3, 4)}, {"lignes": lignes(5, 5)}],
                      self._reussi(), garde=3)
        elif s == "fuite":          # un journal qui porterait le jeton et des séquences de terminal
            job = Job(ident, self.app, "preview", [{"lignes": [
                f"export LAB_MCP_TOKEN={self.jeton}", "\x1b[31mrouge\x1b[0m \x1b]0;titre\x07fin", "tab\tgardée"]}], self._reussi())
        elif s == "sans_frontend":
            job = Job(ident, self.app, "preview", [{"lignes": lignes(1, 2)}],
                      {"ok": True, "step": "done", "preview": essai(self.app, url=None, services=[{"service": "backend", "state": "running"}])})
        elif s == "degrade":
            job = Job(ident, self.app, "preview", [{"lignes": lignes(1, 2)}],
                      {"ok": True, "step": "done", "preview": essai(self.app, state="degraded", services=[
                          {"service": "backend", "state": "exited"}, {"service": "frontend", "state": "running"}])})
        else:                       # « succes » et tout scénario qui ne touche pas au job
            job = Job(ident, self.app, "preview", [
                {"state": "queued", "devant": 2}, {"state": "queued", "devant": 2}, {"state": "queued", "devant": 1},
                {"lignes": ["══ [lab-mcp] étape « source »"] + lignes(1, 3)},
                {"lignes": []},
                {"lignes": lignes(4, 9) + ["══ [lab-mcp] étape « build »"]},
                {"lignes": lignes(10, 12)},
            ], self._reussi())
        self.jobs[ident] = job
        return job

    # ── outils ──
    def outil(self, nom, args):
        with self.verrou:
            self.appels.append(nom)
            s = self.scenario
            if s == "outil_inconnu" or nom not in ("preview_deploy", "preview_status", "preview_stop", "job_status", "whoami"):
                return None
            if nom == "whoami":
                return {"uid": "alice"}
            if nom == "job_status":
                job = self.jobs.get(args.get("job_id"))
                if job is None or (s == "perdu" and job.cran >= 1):
                    raise ErreurMoteur("not_found", "Job inconnu (ou lancé par un autre développeur, ou perdu au redémarrage du moteur).")
                return job.vue(max(0, min(int(args.get("tail", 200)), 1000)))
            if args.get("app") != self.app:
                raise ErreurMoteur("not_found", "Projet inconnu.")
            if nom == "preview_deploy":
                if s == "no_workspace":
                    raise ErreurMoteur("no_workspace", "Aucun dossier de travail pour ce projet : ouvrir d'abord son espace.")
                if s == "queue_full":
                    raise ErreurMoteur("queue_full", "Trop de jobs en attente sur le lab : réessayer plus tard.")
                if s == "unavailable":
                    raise ErreurMoteur("unavailable", "Ce lab n'a pas de domaine : pas d'adresse d'essai.")
                if s == "invalid":
                    raise ErreurMoteur("invalid", "Demande refusée.", reasons=["raison un", "raison deux"])
                en_cours = [j for j in self.jobs.values() if j.etat not in ("succeeded", "failed")]
                if en_cours:
                    raise ErreurMoteur("job_exists", "Un job est déjà en file ou en cours pour ce projet.", job_id=en_cours[0].ident)
                job = self._nouveau_job()
                return {"job_id": job.ident, "kind": "preview", "app": self.app, "state": "queued", "jobs_ahead": 0}
            if nom == "preview_status":
                if s == "status_failed":        # contrat v2
                    raise ErreurMoteur("failed", "La sortie du script d'essai est inexploitable.")
                if s == "status_unavailable":
                    raise ErreurMoteur("unavailable", "Le script d'essai est absent de ce lab.")
                if s == "status_sans_terme":    # contrat v2 : expires_at null alors que l'essai tourne
                    return essai(self.app, expires_at=None, built_at=None)
                if s == "status_absent":
                    return dict(ABSENT)
                if s == "status_autre":
                    return essai("autre-projet", current=False)
                if s == "status_degrade":
                    return essai(self.app, state="degraded", services=[{"service": "backend", "state": "unhealthy"},
                                                                       {"service": "frontend", "state": "running"}])
                return essai(self.app)
            if s == "stop_occupe":
                raise ErreurMoteur("busy", "Un déploiement est en cours, ou l'essai est en construction.")
            return {"app": self.app, "stopped": s != "stop_rien"}

    # ── serveur ──
    def demarre(self, port=0, hote="127.0.0.1"):
        faux = self

        class H(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def log_message(self, *a):  # silence
                pass

            def _rep(self, code, corps=None, brut=None, entetes=()):
                data = brut if brut is not None else (b"" if corps is None else json.dumps(corps, ensure_ascii=False).encode())
                self.send_response(code)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(data)))
                for nom, valeur in entetes:
                    self.send_header(nom, valeur)
                self.end_headers()
                self.wfile.write(data)

            def do_GET(self):
                self._rep(405, {"error": "pas de flux SSE"})

            def do_DELETE(self):
                self._rep(200, {})

            def do_POST(self):
                brut = self.rfile.read(int(self.headers.get("Content-Length", 0) or 0))
                try:
                    msg = json.loads(brut or b"{}")
                except ValueError:
                    msg = {}
                recu = self.headers.get("Authorization")
                etat = "ABSENT" if recu is None else ("OK" if recu == faux.attendu else "KO")
                methode, ident = msg.get("method"), msg.get("id")
                params = msg.get("params") if isinstance(msg.get("params"), dict) else {}
                suffixe = f" outil={params.get('name')}" if methode == "tools/call" else ""
                if faux.journal:
                    with open(faux.journal, "a", encoding="utf-8") as f:
                        f.write(f"{methode} auth={etat} agent={self.headers.get('User-Agent', '')}{suffixe}\n")
                with faux.verrou:
                    faux.requetes += 1
                    rang, scenario = faux.requetes, faux.scenario
                if etat != "OK":
                    return self._rep(401, {"error": "unauthorized", "detail": "Jeton d'espace de travail inconnu ou révoqué (espace fermé ?)."})
                # Pannes de transport provoquées (vues par lab-essai) :
                if scenario == "redirection":
                    return self._rep(307, entetes=[("Location", faux.piege)])
                if scenario == "passerelle":
                    return self._rep(502, brut=b"<html>Bad Gateway</html>")
                if scenario == "pas_json":
                    return self._rep(200, brut=b"<html>une page, pas le moteur</html>")
                if scenario == "interdit":
                    return self._rep(403, {"error": "forbidden", "detail": "Le compte 'alice' n'est plus un développeur inscrit."})
                if scenario == "coupure" and rang in (3, 4):      # deux appels de suivi sans réponse du moteur
                    return self._rep(502, brut=b"<html>Bad Gateway</html>")
                if "application/json" not in self.headers.get("Accept", ""):
                    return self._rep(406, {"jsonrpc": "2.0", "id": "server-error", "error": {"code": -32600, "message": "Not Acceptable: Client must accept application/json"}})
                if "application/json" not in self.headers.get("Content-Type", ""):
                    return self._rep(415, {"jsonrpc": "2.0", "id": "server-error", "error": {"code": -32600, "message": "Unsupported Media Type"}})
                if ident is None:  # notification
                    return self._rep(202)
                if methode == "initialize":
                    res = {
                        "protocolVersion": params.get("protocolVersion", "2025-03-26"),
                        "capabilities": {"tools": {}},
                        "serverInfo": {"name": "faux-lab-mcp", "version": "0"},
                    }
                elif methode == "tools/list":
                    res = {"tools": [{
                        "name": "whoami",
                        "description": "outil factice de verify.sh",
                        "inputSchema": {"type": "object", "properties": {}},
                    }]}
                elif methode == "ping":
                    res = {}
                elif methode == "tools/call":
                    nom = params.get("name")
                    try:
                        rendu = faux.outil(nom, params.get("arguments") or {})
                        if rendu is None:
                            res = {"content": [{"type": "text", "text": f"Unknown tool: {nom}"}], "isError": True}
                        else:
                            res = {"content": [{"type": "text", "text": json.dumps(rendu, ensure_ascii=False, indent=2)}], "isError": False}
                    except ErreurMoteur as exc:
                        res = {"content": [{"type": "text", "text": f"Error executing tool {nom}: " + json.dumps(exc.corps, ensure_ascii=False)}], "isError": True}
                else:
                    return self._rep(200, {"jsonrpc": "2.0", "id": ident,
                                           "error": {"code": -32601, "message": "méthode inconnue"}})
                self._rep(200, {"jsonrpc": "2.0", "id": ident, "result": res})

        serveur = ThreadingHTTPServer((hote, port), H)
        serveur.daemon_threads = True
        return serveur


if __name__ == "__main__":
    Faux(os.environ["FAUX_MCP_JETON"], sys.argv[2], os.environ.get("FAUX_MCP_APP", "demo-app"),
         os.environ.get("FAUX_MCP_SCENARIO", "succes")).demarre(int(sys.argv[1])).serve_forever()
