# __APP_NAME__ — règles de travail (pour toute IA, et tout humain)

Ce projet tourne dans un lab partagé et exposé sur Internet. Ces règles ne sont pas des conseils.

## Méthode — lot par lot

1. **Avant de coder, écris le lot** dans `FEUILLE_DE_ROUTE.md` : objectif, tâches, et les tests qui
   prouveront qu'il est fini. Pas de code sans lot écrit.
2. **Un seul lot « en cours » à la fois.** Termine-le avant d'ouvrir le suivant.
3. **Ne clos jamais un lot sans avoir lancé ses tests.** Note sous « Vérifié le » la date et ce que
   tu as réellement lancé, avec le résultat. « Devrait marcher » n'est pas une vérification.
4. **Un lot livré = un commit poussé** sur GitHub, avec la feuille de route à jour dans le même commit.
5. **Ne change pas le format de `FEUILLE_DE_ROUTE.md`** : une machine le lit. Titres de lot :
   `## Lot <N> — <titre>   ·   statut : à faire | en cours | livré`.

Si `CAHIER_DES_CHARGES.md` est à la racine (projet lancé depuis une spécification App Builder),
**lis-le avant d'ouvrir un lot** : il décrit ce que l'app doit faire — modèles, API, pages, règles
métier, groupes — et les lots de la feuille de route en découlent. S'il contredit une règle de ce
fichier, c'est la règle qui gagne : note l'écart dans le lot au lieu de le suivre.

**Spécification modifiée après la création du projet** : lab-admin peut ouvrir un ticket GitHub
titré « Spécification App Builder n° … modifiée » (marqueur `<!-- lab-spec-update … -->`). Avant
d'ouvrir un lot, regarde s'il en existe un ouvert (`gh issue list --search "Spécification App Builder"`).
S'il y en a un : compare-le à `CAHIER_DES_CHARGES.md`, **propose** au développeur la mise à jour du
cahier et des lots « à faire » (jamais de réécriture d'un lot livré), applique seulement ce qu'il
accepte, puis ferme le ticket en citant le commit.

## Déployer

- **Par le moteur du lab uniquement** : outil MCP `deploy`, ou le bouton « Déployer » de lab-admin.
  Jamais de `docker`, jamais de script lancé à la main : tu n'y as pas accès, et c'est voulu.
- Seul un **commit poussé** est déployable. Le déploiement lance les tests backend (section
  « Commande de test » de la feuille de route) : **s'ils échouent, rien n'est mis en service** et
  l'ancienne version continue de tourner. Lis le journal, corrige, repousse.
- Après le déploiement, le test de cloisonnement est lancé et son résultat affiché dans l'état du projet.

## Règles du lab qui s'imposent à cette app

- **Cloisonnement à deux verrous, ne jamais en retirer un.** (1) Le flow Keycloak refuse à la
  connexion qui n'est pas du groupe requis. (2) L'API vérifie elle-même, dans
  `api/authentication.py`, que le jeton vient de ce client (`azp`) et que ses `groups` croisent
  `KEYCLOAK_REQUIRED_GROUPS`. Toute nouvelle route d'API reste derrière cette authentification ;
  une route publique est une décision à écrire dans la feuille de route, pas un oubli.
- **`frontend/e2e/cloisonnement.spec.ts` ne se modifie pas** et ne dépend d'aucun contenu de l'app.
  Pas d'autre fichier de test E2E.
- **Fichiers des utilisateurs : par l'API `storage` du lab.** Pas de volume média, pas de blob en base.
- **Base de données** : uniquement celle que désigne `.env` (`DB_NAME`, `DB_USER`, `DB_SCHEMA`).
  Ne les change pas ; tu n'as accès à aucune autre.
- **Interface : identité « Foyer ».** Aucune couleur en dur (tokens CSS de `src/styles.scss`),
  navigation verticale, rupture à 900 px, polices embarquées, cibles tactiles de 44 px minimum.
- **Pour envoyer un email : `send_mail(...)` de Django, rien d'autre.** Le compte SMTP se règle
  dans lab-admin (carte « Email » du projet), jamais dans le dépôt ni dans `settings.py`. Sans
  compte rattaché, les emails s'affichent dans le journal du conteneur.
- **Aucun secret dans le dépôt.** `.env` et `.keycloak-client-opts` sont ignorés par git et
  appartiennent au lab : ne les ajoute jamais (`git add -f` fait refuser le déploiement). Une clé
  d'API se règle par l'outil `env_set`, pas dans le code.
- **`docker-compose.yml`** : pas de `privileged`, pas de montage hors du dossier, pas d'autre réseau
  que `dev-net`/`sso-net`, pas d'autre port que ceux du projet, chemins Caddy `/__APP_NAME__` et
  `/__APP_NAME__-api` seulement. Le déploiement refuse le reste et dit pourquoi.

## Module — description et installation

Le lab installe chaque app comme un **module** : il lit sa description, installe d'abord ce dont
elle dépend, demande ses réglages, puis la déploie. Règles complètes : `modules/README.md` du lab.

- **`lab-module.json`** (à la racine) décrit l'app. Tiens-le à jour dans le même commit que le code :
  chaque service du lab appelé va dans `requires.modules` (`storage` pour les fichiers, `oauth-hub`
  pour un jeton GitHub, `lab-media` pour un flux, avec `"interface": "1"`) ; une commande de
  **l'hôte** exigée dans `requires.system` ; chaque réglage à demander (clé d'API…) dans `settings`
  avec une `question` claire — **jamais de valeur** dans ce fichier, jamais une clé gérée par le lab.
- **Tout ce qui peut aller dans l'image Docker y va** (Dockerfile : paquets, données de référence,
  migrations et commandes de gestion au démarrage).
- Sinon, **`install.sh`** (joué par le lab à l'installation seulement — premier lancement, ou projet encore absent du serveur ; pas à une mise à jour —, avant le build, dans le dossier du
  projet, environnement vide) et **`install.bat`** (même chose pour un poste Windows, jamais joué par
  le lab) : idempotents, `--check` qui ne modifie rien et dit ce qui manque (code 1 s'il manque
  quelque chose), sans `sudo` ni `apt`, sans secret, sans toucher un fichier suivi par git. Un
  échec arrête le déploiement avant le build : la version en service continue.
- **Projet d'un développeur** : le lab ne joue pas `install.sh` (règle actuelle) ; tout doit passer
  par l'image. Le journal du déploiement le dit.
- Le déploiement refuse une description invalide ou un script déclaré absent ou sans `--check`.

## Règles de code tenues par le gabarit — ne pas les défaire

- **Aucune route ne rend la liste des comptes** (pas d'annuaire) : `/api/me/` suffit.
- **`/api/schema/` et `/api/docs/` n'existent qu'en `DEBUG`** (404 en service).
- **`backend/gunicorn.conf.py`** retire `SCRIPT_NAME` de l'environnement du worker et n'a pas de
  journal d'accès (il écrirait en clair les paramètres d'URL) : garde les deux.
- **Une exception `requests` porte l'URL demandée** : ne renvoie ni ne journalise `str(exc)`,
  rends un message fixe.
- **Un sérialiseur appelé sans `request`** dans son contexte ne sait pas qui lit : un champ réservé
  au propriétaire y est masqué par défaut.
- **Une clé d'API d'un utilisateur** se garde chiffrée côté serveur, jamais dans `localStorage` ;
  une réponse d'API dit seulement si elle est réglée, jamais sa valeur.
- **Frontend** : `pkceMethod: 'S256'` à `kc.init()` ; le jeton n'est joint qu'aux adresses de
  `tokenBases()` (`core/env.ts`) — une API de plus s'y ajoute ; le retour après connexion passe par
  `core/redirect-uri.ts`, jamais par un paramètre d'URL. Fichiers servis par `storage` : jeton en
  en-tête `Authorization`, jamais `?token=`.
- **`docker-compose.yml`** : tout port publié est lié à `127.0.0.1` ; un frontend ne reçoit jamais
  `env_file: .env`.

## En cas de blocage

Ne contourne pas une règle pour avancer. Écris ce qui bloque dans la feuille de route et ouvre un
ticket (`gh issue create` depuis le terminal du projet, ou le bloc « Signaler un problème » de
la page du projet dans lab-admin).
