# Feuille de route — __APP_NAME__

Ce fichier est lu par une machine : `validate-app.sh` refuse de déployer s'il manque ou s'il ne
contient aucun lot au format ci-dessous. Garder les titres tels quels.

## Commande de test
__TEST_COMMAND__

## Lot 1 — Socle livré par le gabarit   ·   statut : livré
**Objectif :** partir d'une app qui démarre, s'authentifie par Keycloak et refuse qui n'est pas du groupe requis.
**Tâches :**
- [x] Scaffold par `new-app.sh` (aucune ligne modifiée à la main)
**Tests à passer avant de clore le lot :**
- [x] Tests backend du gabarit (commande ci-dessus)
- [x] Test de cloisonnement `frontend/e2e/cloisonnement.spec.ts`, s'il y a un frontend
**Vérifié le :** __DATE__ — scaffold généré ; tests à relancer au premier déploiement (résultat visible dans l'état du projet).

## Lot 2 — <titre du premier lot métier>   ·   statut : à faire
**Objectif :** <ce que l'utilisateur pourra faire à la fin du lot, en une phrase>
**Tâches :**
- [ ] <tâche>
**Tests à passer avant de clore le lot :**
- [ ] <test nommé et vérifiable : « `python manage.py test api.tests.NomDuTest` passe », « un non-membre reçoit 403 sur /api/… »>
**Vérifié le :** <date + ce qui a été réellement lancé — obligatoire pour passer à « livré »>
