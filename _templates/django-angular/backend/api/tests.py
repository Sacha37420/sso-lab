"""Tests backend du gabarit — lancés par le lab avant chaque mise en service.

Le déploiement s'arrête si l'un d'eux échoue : l'ancienne version reste en
service. Ajoute ici les tests de chaque lot (voir FEUILLE_DE_ROUTE.md).
"""
from django.test import TestCase


class CloisonnementApiTests(TestCase):
    """Verrou 2 : l'API ne répond à personne sans jeton valide."""

    def test_api_refuse_sans_jeton(self):
        for path in ('/api/me/', '/api/departments/', '/api/users/'):
            with self.subTest(path=path):
                response = self.client.get(path)
                self.assertIn(response.status_code, (401, 403))

    def test_api_refuse_un_jeton_fantaisiste(self):
        response = self.client.get('/api/me/', HTTP_AUTHORIZATION='Bearer pas-un-jeton')
        self.assertIn(response.status_code, (401, 403))
