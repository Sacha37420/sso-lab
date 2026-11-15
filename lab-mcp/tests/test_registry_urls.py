"""Liens d'un projet (`urls` de GET /projects) : lus dans les labels Caddy, comme la page 404.

Bibliothèque standard seule, aucune pièce du lab : `python3 lab-mcp/tests/test_registry_urls.py`.
"""
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
from labmcp.registry import Registry  # noqa: E402


def compose(*labels):
    lignes = "\n".join(f'      {k}: "{v}"' for k, v in labels)
    return f"services:\n  web:\n    labels:\n{lignes}\n"


class CaddyPaths(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = self.tmp.name
        os.makedirs(os.path.join(self.root, "deploiement"))
        self.reg = Registry(self.root)

    def tearDown(self):
        self.tmp.cleanup()

    def app(self, nom, texte, deploiement=True):
        d = os.path.join(self.root, "deploiement" if deploiement else "", nom)
        os.makedirs(d)
        if texte is not None:
            with open(os.path.join(d, "docker-compose.yml"), "w", encoding="utf-8") as fh:
                fh.write(texte)

    def test_convention(self):
        self.app("mon-app", compose(("caddy.handle_path", "/mon-app-api/*"), ("caddy_2.handle_path", "/mon-app/*")))
        self.assertEqual(self.reg.caddy_paths("mon-app"), ("/mon-app/", "/mon-app-api/"))

    def test_chemin_historique_different_du_nom(self):
        # Cas réel : analyse-lora est servie sous /lora/ et /lora-api/.
        self.app("analyse-lora", compose(("caddy.handle_path", "/lora-api/*"), ("caddy_1.handle_path", "/lora/*")))
        self.assertEqual(self.reg.caddy_paths("analyse-lora"), ("/lora/", "/lora-api/"))

    def test_chemins_annexes_ignores(self):
        # robot-lab, craft-lab, carto-lab : un troisième chemin ne prend pas la place du front.
        self.app("robot-lab", compose(("caddy.handle_path", "/robot-lab-engine/*"),
                                      ("caddy_1.handle_path", "/robot-lab-api/*"),
                                      ("caddy_2.handle_path", "/robot-lab/*")))
        self.assertEqual(self.reg.caddy_paths("robot-lab"), ("/robot-lab/", "/robot-lab-api/"))
        self.app("carto-lab", compose(("caddy.handle_path", "/${OGC_SERVICE_PATH:-carto-ogc}/*"),
                                      ("caddy_1.handle_path", "/carto-lab/*")))
        self.assertEqual(self.reg.caddy_paths("carto-lab"), ("/carto-lab/", None))

    def test_outil_a_la_racine(self):
        self.app("storage", compose(("caddy.handle_path", "/storage/*"), ("caddy_1.handle_path", "/storage-api/*")),
                 deploiement=False)
        self.assertEqual(self.reg.caddy_paths("storage"), ("/storage/", "/storage-api/"))

    def test_sans_label_ou_sans_compose(self):
        # lab-mcp, lab-media : aucun handle_path → aucun lien inventé.
        self.app("lab-media", "services:\n  media:\n    image: x\n", deploiement=False)
        self.assertEqual(self.reg.caddy_paths("lab-media"), (None, None))
        self.app("neuf", None)
        self.assertEqual(self.reg.caddy_paths("neuf"), (None, None))
        self.assertEqual(self.reg.caddy_paths("inconnue"), (None, None))

    def test_compose_reel_du_depot(self):
        # Les vrais docker-compose.yml présents dans le dépôt : aucun front ne finit par -api.
        racine = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
        reg = Registry(racine)
        for app in reg.all_apps():
            front, api = reg.caddy_paths(app)
            if front:
                self.assertFalse(front.endswith("-api/"), app)
            if api:
                self.assertTrue(api.endswith("-api/"), app)


if __name__ == "__main__":
    unittest.main(verbosity=2)
