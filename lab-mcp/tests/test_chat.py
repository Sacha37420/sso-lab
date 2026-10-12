"""Écran de conversation d'un espace (chantier espace-chat, I2 et I3) — tests du moteur SEUL.

Aucun Docker, aucun réseau, aucune pièce du lab : le moteur livré (labmcp/, monté depuis le dossier
de travail) contre une racine factice créée dans /tmp. À lancer dans un conteneur jetable de l'image
du moteur, sans réseau — voir tests/chat/run.sh, qui joue aussi l'essai de la passerelle :

    docker run --rm --name zz-chat-mcp-unit --network none \\
        -v $PWD/lab-mcp/labmcp:/app/labmcp:ro -v $PWD/lab-mcp/tests:/tests:ro \\
        lab-mcp-lab-mcp:latest python /tests/test_chat.py -v

Ce qui est remplacé ici, et rien d'autre : le démarrage du conteneur d'espace (`_start`), la sonde
vers la passerelle (`_probe`), oauth-hub, GitHub et work-clone.sh. La décision d'accès, le choix de
l'URL, l'attente de la cible, le calcul d'inactivité et la lecture du corps de la requête sont le
code livré.
"""
import asyncio
import os
import sys
import tempfile
import time
import unittest
from urllib.parse import parse_qs, urlsplit

ROOT = tempfile.mkdtemp(prefix="zz-chat-root-")
os.makedirs(os.path.join(ROOT, "scripts"))
open(os.path.join(ROOT, "scripts", "lab-lock.sh"), "w").close()
for _app in ("zzapp", "zzbob"):
    os.makedirs(os.path.join(ROOT, "deploiement", _app))
    open(os.path.join(ROOT, "deploiement", _app, "docker-compose.yml"), "w").close()
with open(os.path.join(ROOT, ".devs"), "w") as fh:
    fh.write("alice\nbob\nzzroot\n")
with open(os.path.join(ROOT, ".owners"), "w") as fh:
    fh.write("zzapp:alice\nzzbob:bob\n")
with open(os.path.join(ROOT, ".ports"), "w") as fh:
    fh.write("zzapp:18001:14001\nzzbob:18002:14002\n")
os.environ.update(LAB_ROOT=ROOT, DOMAIN="lab.test", LAB_SUPERUSER="zzroot",
                  LAB_STATE_DIR=os.path.join(ROOT, ".lab-state"), LAB_WORK_DIR=os.path.join(ROOT, "work"),
                  LAB_WS_IDLE_MIN="0.02")       # 1,2 s : le ramasse-miettes tourne toutes les 2 s

from labmcp import access as access_module, config, engine as engine_module, web  # noqa: E402
from labmcp import workspaces as ws_module  # noqa: E402
from labmcp.access import Access  # noqa: E402
from labmcp.auth import Caller  # noqa: E402
from labmcp.workspaces import Workspace, WorkspaceManager  # noqa: E402

CFG = config.load()
ALLOW = lambda viewer, owner: viewer == owner or viewer == "zzroot"   # noqa: E731


class Resp:
    def __init__(self, status, payload=None):
        self.status_code, self._payload = status, payload

    def json(self):
        if isinstance(self._payload, Exception):
            raise self._payload
        return self._payload


def cookie_of(info):
    return info["set_cookie"].split(";", 1)[0]


# ═════════════════════════════════════════════════════════════════════════════
class AccessTests(unittest.TestCase):
    """L'échange du ticket et la décision par requête (labmcp/access.py)."""

    def setUp(self):
        self.a = Access(secure_cookies=True)
        self.touched = 0

    def go(self, uri, cookie="", target="alice", kind="ws", landings=("_chat/",)):
        def touch():
            self.touched += 1
        return self.a.authorize(kind, target, uri, cookie, ALLOW, touch, landings=landings)

    def test_ticket_conversation_conserve_agent(self):
        t = self.a.ticket("ws", "alice", "alice")
        decision, info = self.go(f"/ws/alice/_chat/?agent=claude&ticket={t}")
        self.assertEqual(decision, "redirect")
        self.assertEqual(info["location"], "/ws/alice/_chat/?agent=claude")
        t = self.a.ticket("ws", "alice", "alice")
        self.assertEqual(self.go(f"/ws/alice/_chat/?ticket={t}&agent=vibe")[1]["location"], "/ws/alice/_chat/?agent=vibe")

    def test_cookie_limite_a_la_racine_de_l_espace(self):
        """Le cookie posé depuis l'URL de conversation reste celui de l'espace : Path=/ws/<uid>/."""
        t = self.a.ticket("ws", "alice", "alice")
        _, info = self.go(f"/ws/alice/_chat/?agent=claude&ticket={t}")
        parts = [p.strip() for p in info["set_cookie"].split(";")]
        self.assertTrue(parts[0].startswith("lab_ws_alice="))
        self.assertIn("Path=/ws/alice/", parts)
        self.assertIn("HttpOnly", parts)
        self.assertIn("Secure", parts)
        self.assertIn("SameSite=Lax", parts)
        self.assertNotIn("ticket", info["location"])

    def test_editeur_inchange(self):
        t = self.a.ticket("ws", "alice", "alice")
        self.assertEqual(self.go(f"/ws/alice/?ticket={t}")[1]["location"], "/ws/alice/")
        t = self.a.ticket("ws", "alice", "alice")
        self.assertEqual(self.go(f"/ws/alice/?folder=/work/zzapp&ticket={t}")[1]["location"],
                         "/ws/alice/?folder=%2Fwork%2Fzzapp")
        t = self.a.ticket("ws", "alice", "alice")   # un chemin profond de l'éditeur revient à sa racine, comme avant
        self.assertEqual(self.go(f"/ws/alice/static/x.js?ticket={t}")[1]["location"], "/ws/alice/")

    def test_pgadmin_inchange(self):
        """Un service qui ne déclare aucun sous-dossier revient toujours à sa racine."""
        t = self.a.ticket("pg", "alice", "alice")
        d, info = self.go(f"/pg/alice/_chat/?ticket={t}", kind="pg", landings=())
        self.assertEqual((d, info["location"]), ("redirect", "/pg/alice/"))
        self.assertIn("Path=/pg/alice/", info["set_cookie"])

    def test_retour_jamais_recopie_de_la_requete(self):
        """Quelle que soit l'URL présentée, le retour est l'une des deux adresses fixes de l'espace visé."""
        for uri in ("//evil.example/_chat/?ticket={t}", "/ws/alice/_chat/../../bob/?ticket={t}",
                    "https://evil.example/ws/alice/_chat/?ticket={t}", "/ws/bob/_chat/?ticket={t}",
                    "/ws/alice/_chat%2F..%2F..%2Fx?ticket={t}", "/ws/alice/_chat/a/b/c?next=//evil.example&ticket={t}",
                    "/ws/alice/_chatx/?ticket={t}", "?ticket={t}"):
            t = self.a.ticket("ws", "alice", "alice")
            d, info = self.go(uri.format(t=t))
            self.assertEqual(d, "redirect", uri)
            self.assertIn(urlsplit(info["location"]).path, ("/ws/alice/", "/ws/alice/_chat/"), uri)
            self.assertTrue(info["location"].startswith("/ws/alice/"), uri)
            self.assertFalse(info["location"].startswith("//"), uri)

    def test_ticket_usage_unique_et_lie_a_l_espace(self):
        t = self.a.ticket("ws", "alice", "alice")
        self.assertEqual(self.go(f"/ws/alice/_chat/?agent=claude&ticket={t}")[0], "redirect")
        self.assertEqual(self.go(f"/ws/alice/_chat/?agent=claude&ticket={t}")[0], "deny")       # rejoué
        t = self.a.ticket("ws", "bob", "bob")
        self.assertEqual(self.go(f"/ws/alice/_chat/?agent=claude&ticket={t}", target="alice")[0], "deny")  # ticket de bob
        t = self.a.ticket("pg", "alice", "alice")
        self.assertEqual(self.go(f"/ws/alice/_chat/?ticket={t}")[0], "deny")                    # autre sorte
        t = self.a.ticket("ws", "bob", "alice")     # bob n'a pas (plus) le droit d'entrer chez alice
        self.assertEqual(self.go(f"/ws/alice/_chat/?ticket={t}")[0], "deny")
        self.assertEqual(self.go("/ws/alice/_chat/?agent=claude&ticket=nimportequoi")[0], "deny")

    def test_decision_independante_du_chemin(self):
        """Avec ou sans « _chat », la même session donne la même réponse — et aucune session, aucun accès."""
        t = self.a.ticket("ws", "alice", "alice")
        alice = cookie_of(self.go(f"/ws/alice/?ticket={t}")[1])
        t = self.a.ticket("ws", "bob", "bob")
        bob = cookie_of(self.go(f"/ws/bob/_chat/?agent=vibe&ticket={t}", target="bob")[1])
        paths = ("/ws/alice/", "/ws/alice/_chat/", "/ws/alice/_chat/ws", "/ws/alice/_chat/healthz",
                 "/ws/alice/_chat/activity", "/ws/alice/_chat", "/ws/alice/_chatx/", "/ws/alice/%5Fchat/")
        for p in paths:
            self.assertEqual(self.go(p, alice)[0], "ok", p)
            self.assertEqual(self.go(p, "")[0], "deny", p)
            self.assertEqual(self.go(p, bob)[0], "deny", p)                                 # cookie de bob, tel quel
            self.assertEqual(self.go(p, bob.replace("lab_ws_bob", "lab_ws_alice"))[0], "deny", p)  # sa valeur sous le nom d'alice
            self.assertEqual(self.go(p, alice.replace("lab_ws_alice", "lab_pg_alice"))[0], "deny", p)
        self.assertEqual(self.go("/ws/bob/_chat/", alice, target="bob")[0], "deny")
        self.assertEqual(self.go("/ws/bob/_chat/", bob, target="bob")[0], "ok")

    def test_session_du_moteur_ne_compte_pas_comme_activite(self):
        """La sonde `/activity` (session interne) ne prolonge pas l'espace qu'elle interroge."""
        engine_cookie = "lab_ws_alice=" + self.a.engine_session("ws", "alice")
        before = self.touched
        self.assertEqual(self.go("/ws/alice/_chat/activity", engine_cookie)[0], "ok")
        self.assertEqual(self.go("/ws/alice/_chat/healthz", engine_cookie)[0], "ok")
        self.assertEqual(self.touched, before)
        t = self.a.ticket("ws", "alice", "alice")
        dev = cookie_of(self.go(f"/ws/alice/?ticket={t}")[1])
        before = self.touched
        self.go("/ws/alice/_chat/", dev)
        self.assertEqual(self.touched, before + 1)


# ═════════════════════════════════════════════════════════════════════════════
class Manager(WorkspaceManager):
    """Le gestionnaire livré, sans Docker : `_start` enregistre l'espace, `_probe` suit un scénario."""

    def __init__(self, cfg=CFG):
        class _Fw:
            async def ensure(self, force=False):
                return None
        super().__init__(cfg, Access(secure_cookies=True), _Fw())
        self.probes: list[str] = []
        self.answers: dict[str, object] = {}     # chemin → Resp | None | fonction
        self.started: list[tuple] = []
        self.removed: list[str] = []

    async def _docker(self, *args, env=None, timeout=60):
        return 0, "", ""

    async def _remove(self, uid):
        self.removed.append(uid)

    async def _start(self, owner, app, viewer, gh_token, author):
        self.started.append((owner, app))
        ws = Workspace(uid=owner, app=app, token_hash="x", opened_by=viewer, with_github=bool(gh_token),
                       probe_cookie=self.access.engine_session("ws", owner))
        self._ws[owner] = ws
        return ws

    async def _probe(self, ws, path, timeout=3):
        self.probes.append(path)
        answer = self.answers.get(path)
        return answer() if callable(answer) else answer


class OpenTests(unittest.IsolatedAsyncioTestCase):
    """L'URL rendue et l'attente de la cible (labmcp/workspaces.py::open)."""

    async def asyncSetUp(self):
        self.m = Manager()
        self.m.answers = {"healthz": Resp(200, {}), "_chat/healthz": Resp(200, {"ok": True})}
        self.m._start_reaper = lambda: None     # le ramasse-miettes (limite 1,2 s ici) a ses propres tests

    async def asyncTearDown(self):
        if self.m._reaper:
            self.m._reaper.cancel()

    async def test_url_selon_la_cible(self):
        want = {"editor": ("/ws/alice/", {}), "chat-claude": ("/ws/alice/_chat/", {"agent": ["claude"]}),
                "chat-vibe": ("/ws/alice/_chat/", {"agent": ["vibe"]})}
        for target, (path, params) in want.items():
            out = await self.m.open("alice", "zzapp", "alice", "", None, target)
            url = urlsplit(out["url"])
            query = parse_qs(url.query)
            self.assertEqual((url.scheme, url.netloc, url.path), ("https", "lab.test", path), target)
            self.assertEqual(len(query.pop("ticket")[0]), 43, target)
            self.assertEqual(query, params, target)
            self.assertEqual(out["target"], target)
            # Même forme qu'avant, plus « target ».
            self.assertEqual(set(out), {"url", "uid", "app", "target", "reused", "ticket_expires_in", "workspace"})
            self.assertEqual((out["uid"], out["app"], out["ticket_expires_in"]), ("alice", "zzapp", 60))
        # « agent » avant « ticket », comme l'écrit le contrat.
        out = await self.m.open("alice", "zzapp", "alice", "", None, "chat-claude")
        self.assertRegex(out["url"], r"^https://lab\.test/ws/alice/_chat/\?agent=claude&ticket=[\w-]{43}$")

    async def test_defaut_editeur(self):
        out = await self.m.open("alice", "zzapp", "alice", "", None)
        self.assertEqual(out["target"], "editor")
        self.assertRegex(out["url"], r"^https://lab\.test/ws/alice/\?ticket=[\w-]{43}$")

    async def test_ticket_rendu_s_echange_et_garde_agent(self):
        """Bout à bout dans le moteur : URL rendue → décision de la passerelle → retour sans ticket."""
        out = await self.m.open("alice", "zzapp", "alice", "", None, "chat-vibe")
        url = urlsplit(out["url"])
        d, info = self.m.authorize("alice", f"{url.path}?{url.query}", "", ALLOW)
        self.assertEqual((d, info["location"]), ("redirect", "/ws/alice/_chat/?agent=vibe"))
        self.assertIn("Path=/ws/alice/;", info["set_cookie"])
        cookie = cookie_of(info)
        self.assertEqual(self.m.authorize("alice", "/ws/alice/_chat/?agent=vibe", cookie, ALLOW)[0], "ok")
        self.assertEqual(self.m.authorize("alice", "/ws/alice/", cookie, ALLOW)[0], "ok")      # la même session ouvre l'éditeur
        self.assertEqual(self.m.authorize("bob", "/ws/bob/_chat/", cookie, ALLOW)[0], "deny")  # espace fermé / pas le sien
        await self.m.close("alice")
        self.assertEqual(self.m.authorize("alice", "/ws/alice/_chat/", cookie, ALLOW)[0], "deny")

    async def test_un_seul_espace_partage(self):
        """Ouvrir la conversation ne ferme pas l'éditeur (ni l'inverse) ; un autre projet, si."""
        a = await self.m.open("alice", "zzapp", "alice", "", None, "editor")
        ws = self.m.get("alice")
        b = await self.m.open("alice", "zzapp", "alice", "", None, "chat-claude")
        c = await self.m.open("alice", "zzapp", "alice", "", None, "editor")
        self.assertEqual((a["reused"], b["reused"], c["reused"]), (False, True, True))
        self.assertIs(self.m.get("alice"), ws)
        self.assertEqual((self.m.started, self.m.removed), ([("alice", "zzapp")], []))
        d = await self.m.open("alice", "autre", "alice", "", None, "chat-vibe")
        self.assertFalse(d["reused"])
        self.assertEqual(self.m.removed, ["alice"])
        self.assertEqual(self.m.get("alice").app, "autre")

    async def test_attente_de_la_cible(self):
        # Espace neuf, éditeur : on attend l'éditeur (comme avant), pas la conversation.
        await self.m.open("alice", "zzapp", "alice", "", None, "editor")
        self.assertEqual(self.m.probes, ["healthz"])
        # Espace rejoint, éditeur : aucune attente (comme avant).
        self.m.probes.clear()
        await self.m.open("alice", "zzapp", "alice", "", None, "editor")
        self.assertEqual(self.m.probes, [])
        # Espace rejoint, conversation : on attend SON /healthz, jusqu'à ce qu'il rende 200.
        seq = iter([None, Resp(502), Resp(404), Resp(200, {"ok": True})])
        self.m.answers["_chat/healthz"] = lambda: next(seq)
        t0 = time.time()
        await self.m.open("alice", "zzapp", "alice", "", None, "chat-claude")
        self.assertEqual(self.m.probes, ["_chat/healthz"] * 4)
        self.assertGreater(time.time() - t0, 1.9)
        # Espace neuf, conversation : une seule attente, celle du service de conversation.
        await self.m.close("alice")
        self.m.probes.clear()
        self.m.answers["_chat/healthz"] = Resp(200, {"ok": True})
        await self.m.open("alice", "zzapp", "alice", "", None, "chat-vibe")
        self.assertEqual(self.m.probes, ["_chat/healthz"])

    async def test_limite_de_temps_commune(self):
        """Même limite pour les deux cibles ; un service muet ne fait pas échouer l'ouverture."""
        import inspect
        self.assertEqual(inspect.signature(WorkspaceManager._wait_ready).parameters["timeout"].default,
                         ws_module.READY_TIMEOUT)
        self.assertEqual(ws_module.READY_TIMEOUT, 25)
        ws = await self.m._start("alice", "zzapp", "alice", "", None)
        self.m.answers["_chat/healthz"] = Resp(502)
        t0 = time.time()
        self.assertFalse(await self.m._wait_ready(ws, "_chat/", timeout=1.5))
        self.assertLess(time.time() - t0, 3)
        self.m.answers["healthz"] = Resp(404)        # l'éditeur : « répond » suffit (inchangé)
        self.assertTrue(await self.m._wait_ready(ws, "", timeout=1.5))
        self.m.answers["_chat/healthz"] = Resp(404)  # la conversation : 200 exigé (I1)
        self.assertFalse(await self.m._wait_ready(ws, "_chat/", timeout=1.5))


class ActivityTests(unittest.IsolatedAsyncioTestCase):
    """L'inactivité tient compte de `/activity` (labmcp/workspaces.py::_activity, _reap)."""

    async def asyncSetUp(self):
        self.m = Manager()
        self.m.answers = {"healthz": Resp(200, {"lastHeartbeat": 0}), "_chat/healthz": Resp(200, {"ok": True})}
        self.ws = await self.m._start("alice", "zzapp", "alice", "", None)
        self.old = time.time() - 3600
        self.ws.last_activity = self.old

    async def asyncTearDown(self):
        if self.m._reaper:
            self.m._reaper.cancel()

    def chat(self, answer):
        self.m.answers["_chat/activity"] = answer

    async def test_activite_recente_de_la_conversation(self):
        recent = time.time() - 5
        self.chat(Resp(200, {"last_activity_ms": int(recent * 1000)}))
        self.assertAlmostEqual(await self.m._activity(self.ws), recent, delta=0.01)
        self.assertIn("_chat/activity", self.m.probes)

    async def test_activite_ancienne_ne_prolonge_pas(self):
        self.chat(Resp(200, {"last_activity_ms": int((self.old - 600) * 1000)}))
        self.assertEqual(await self.m._activity(self.ws), self.old)

    async def test_service_absent_ou_en_erreur_ignore(self):
        """Ni une raison de garder : la valeur reste celle des deux autres signes."""
        future = int((time.time() + 86400) * 1000)
        for label, answer in [
            ("injoignable", None), ("502 de la passerelle", Resp(502)), ("500", Resp(500, {"last_activity_ms": future})),
            ("404 (image sans le service)", Resp(404)), ("401", Resp(401)), ("corps illisible", Resp(200, ValueError("x"))),
            ("liste", Resp(200, [1])), ("champ absent", Resp(200, {})), ("null", Resp(200, {"last_activity_ms": None})),
            ("chaîne", Resp(200, {"last_activity_ms": str(future)})), ("booléen", Resp(200, {"last_activity_ms": True})),
            ("zéro", Resp(200, {"last_activity_ms": 0})), ("négatif", Resp(200, {"last_activity_ms": -5})),
            ("infini", Resp(200, {"last_activity_ms": float("inf")})), ("NaN", Resp(200, {"last_activity_ms": float("nan")})),
            ("dans le futur", Resp(200, {"last_activity_ms": future})),
            ("secondes au lieu de ms", Resp(200, {"last_activity_ms": int(time.time())})),
        ]:
            self.chat(answer)
            self.assertEqual(await self.m._activity(self.ws), self.old, label)

    async def test_service_absent_ne_ferme_pas(self):
        """Ni une raison de fermer : les deux autres signes continuent de valoir."""
        for answer in (None, Resp(502), Resp(500), Resp(200, {"last_activity_ms": 1})):
            self.chat(answer)
            beat = time.time() - 2
            self.m.answers["healthz"] = Resp(200, {"lastHeartbeat": beat * 1000})      # battement de l'éditeur
            self.assertAlmostEqual(await self.m._activity(self.ws), beat, delta=0.01)
            self.m.answers["healthz"] = Resp(200, {"lastHeartbeat": 0})
            self.ws.last_activity = now = time.time()                                  # requête du dev
            self.assertEqual(await self.m._activity(self.ws), now)
            self.ws.last_activity = self.old

    async def test_le_plus_recent_des_trois_signes(self):
        now = time.time()
        self.chat(Resp(200, {"last_activity_ms": (now - 30) * 1000}))
        self.m.answers["healthz"] = Resp(200, {"lastHeartbeat": (now - 10) * 1000})
        self.assertAlmostEqual(await self.m._activity(self.ws), now - 10, delta=0.01)
        self.m.answers["healthz"] = Resp(200, {"lastHeartbeat": (now - 90) * 1000})
        self.assertAlmostEqual(await self.m._activity(self.ws), now - 30, delta=0.01)

    async def test_ramasse_miettes_reel(self):
        """Le vrai `_reap` (limite 1,2 s) : gardé tant que la conversation vit, fermé ensuite."""
        closed = []
        self.m.on_idle_close = closed.append
        self.chat(lambda: Resp(200, {"last_activity_ms": int(time.time() * 1000)}))   # un tour d'assistant en cours
        self.m._start_reaper()
        await asyncio.sleep(5)
        self.assertIsNotNone(self.m.get("alice"), "fermé sous une conversation en cours")
        self.assertEqual(closed, [])
        stopped = time.time()
        self.chat(Resp(200, {"last_activity_ms": int(stopped * 1000)}))               # plus rien ne se passe
        await asyncio.sleep(5)
        self.assertIsNone(self.m.get("alice"), "gardé alors que la conversation est inactive")
        self.assertEqual((closed, self.m.removed), (["alice"], ["alice"]))

    async def test_ramasse_miettes_service_absent(self):
        """Sans service de conversation, un espace sans autre signe de vie se ferme comme avant."""
        self.chat(None)
        self.m._start_reaper()
        await asyncio.sleep(5)
        self.assertIsNone(self.m.get("alice"))


# ═════════════════════════════════════════════════════════════════════════════
class RouteTests(unittest.TestCase):
    """`POST /mcp/api/projects/<app>/workspace` : la vraie route, le vrai moteur (I3)."""

    @classmethod
    def setUpClass(cls):
        from starlette.applications import Starlette
        from starlette.testclient import TestClient

        cls.engine = engine = engine_module.Engine(CFG)
        manager = Manager()
        manager.answers = {"healthz": Resp(200, {}), "_chat/healthz": Resp(200, {"ok": True})}
        manager._start_reaper = lambda: None
        engine.ws = manager
        cls.calls = calls = []

        async def github_token(token, need_repo_scope=False):
            calls.append("hub")
            return "gho_faux"
        engine.hub.github_token = github_token

        async def script(name, args, *, stdin=None, timeout=120):
            calls.append(f"{name} {' '.join(args)}")
            return 0, "", ""
        engine._script = script

        class _Gh:
            def __init__(self, *a): pass
            def __enter__(self): return self
            def __exit__(self, *a): return False
            def user(self): return {"login": "alice-gh", "id": 7, "name": "Alice"}
        engine_module.Github = _Gh

        inner = Starlette(routes=web.routes(engine))
        cls.who = {"uid": "alice"}

        async def app(scope, receive, send):
            uid = cls.who["uid"]
            if scope["type"] == "http" and uid:
                scope["lab.caller"] = Caller(username=uid, uid=uid, entrance="web", in_developers=uid != "visiteur",
                                             initialized=engine.registry.is_dev(uid),
                                             is_superuser=engine.registry.is_superuser(uid), token="jeton-kc")
            await inner(scope, receive, send)
        cls.http = TestClient(app)

    def setUp(self):
        self.who["uid"] = "alice"

    def post(self, app="zzapp", **kw):
        return self.http.post(f"/mcp/api/projects/{app}/workspace", **kw)

    def test_sans_corps_editeur(self):
        r = self.post()
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r.json()["target"], "editor")
        self.assertRegex(r.json()["url"], r"^https://lab\.test/ws/alice/\?ticket=")

    def test_cible_vide_ou_absente_editeur(self):
        for body in ({}, {"target": ""}, {"target": None}, {"autre": 1}, {"target": "editor"}):
            r = self.post(json=body)
            self.assertEqual((r.status_code, r.json()["target"]), (200, "editor"), body)
            self.assertRegex(r.json()["url"], r"^https://lab\.test/ws/alice/\?ticket=", body)

    def test_cibles_conversation(self):
        for target, agent in (("chat-claude", "claude"), ("chat-vibe", "vibe")):
            r = self.post(json={"target": target})
            self.assertEqual(r.status_code, 200)
            self.assertEqual(r.json()["target"], target)
            self.assertRegex(r.json()["url"], rf"^https://lab\.test/ws/alice/_chat/\?agent={agent}&ticket=[\w-]{{43}}$")
            self.assertEqual(r.json()["workspace"]["app"], "zzapp")

    def test_cible_inconnue_400(self):
        for bad in ("chat", "chat-gpt", "Editor", "chat-claude ", "editor/../x", 5, True, ["chat-claude"], {"a": 1}):
            r = self.post(json={"target": bad})
            self.assertEqual(r.status_code, 400, bad)
            self.assertEqual((r.json()["error"], r.json()["field"]), ("invalid", "target"), bad)
        before = list(self.calls)
        self.post(json={"target": "nimporte"})
        self.assertEqual(self.calls, before, "une cible refusée ne doit rien lancer")

    def test_corps_illisible_400(self):
        for raw in (b"{", b'["chat-claude"]', b'"chat-claude"'):
            r = self.post(content=raw, headers={"Content-Type": "application/json"})
            self.assertEqual((r.status_code, r.json()["error"]), (400, "invalid"), raw)

    def test_memes_refus_quelle_que_soit_la_cible(self):
        """La cible n'ouvre rien de plus que l'éditeur : mêmes gardes, avant tout le reste."""
        for body in (None, {"target": "editor"}, {"target": "chat-claude"}, {"target": "chat-vibe"}, {"target": "x"}):
            kw = {} if body is None else {"json": body}
            self.who["uid"] = "alice"
            self.assertEqual(self.post("zzbob", **kw).status_code, 404, body)      # projet d'un autre
            self.assertEqual(self.post("inconnu", **kw).status_code, 404, body)
            self.who["uid"] = "visiteur"                                           # hors de « developers »
            self.assertEqual(self.post(**kw).status_code, 403, body)
            self.who["uid"] = ""                                                   # sans appelant
            self.assertEqual(self.post(**kw).status_code, 401, body)

    def test_superutilisateur_dans_l_espace_d_un_autre(self):
        """Comme pour l'éditeur : l'espace est celui du propriétaire, le ticket celui de l'appelant."""
        self.who["uid"] = "zzroot"
        r = self.post("zzbob", json={"target": "chat-claude"})
        self.assertEqual(r.status_code, 200)
        self.assertRegex(r.json()["url"], r"^https://lab\.test/ws/bob/_chat/\?agent=claude&ticket=")
        self.assertEqual((r.json()["uid"], r.json()["workspace"]["opened_by"], r.json()["workspace"]["github_token"]),
                         ("bob", "zzroot", False))

    def test_fermeture_inchangee(self):
        self.post(json={"target": "chat-claude"})
        r = self.http.delete("/mcp/api/projects/zzapp/workspace")
        self.assertEqual((r.status_code, r.json()), (200, {"app": "zzapp", "closed": True}))

    def test_aucun_outil_mcp_nouveau(self):
        from labmcp import mcp_entry
        self.assertNotIn("workspace_open", mcp_entry.TOOL_OPS.values())
        self.assertNotIn("workspace_open", engine_module.WS_OPS)


if __name__ == "__main__":
    unittest.main(verbosity=2)
