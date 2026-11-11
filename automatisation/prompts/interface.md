# Tâche « interface » — lab-admin et gabarit Foyer (samedi)

Cibles : `lab-admin` (dans `/work/lab-admin`) et `_racine` (dans `/work/dev`, **seulement le
dossier `_templates/`** pour cette tâche ; le reste de `/work/dev` se lit, ne se modifie pas ici).
`/work/dev/CLAUDE.md` est le `CLAUDE.md` du lab : lis en entier les sections « Lab
multi-développeurs » (« Ce que voit un utilisateur — `lab-admin` », règles de `lab-admin`) et
« UI — identité Foyer » avant tout.

But : vérifier que l'interface du lab est **juste, sûre et simple**, et que le gabarit dont naissent
toutes les apps est **conforme à Foyer et cohérent** ; corriger ce qui est petit et sûr, proposer
le reste, puis ouvrir une PR (l'hôte s'en charge si les tests passent).

## 1. lab-admin — ce qu'il faut savoir avant de toucher
- Pages : Accueil, Services, Projets (sections « Projets de déploiement » et « Outils de dev »),
  « Nouvel utilisateur » (admins). Les anciennes routes `/outils`, `/conception`,
  `/apps-hebergees`, `/debug`, `/code` sont des **redirections** : ne les supprime pas.
- Deux niveaux : la porte (`admins,developers`) et l'administration (`admins`). **Toute vue backend
  est d'admin tant qu'elle ne déclare rien (`IsLabAdmin` par défaut) ; toute route Angular d'admin
  porte `adminGuard`.** Un membre de `developers` sans `admins` ne doit voir ni appeler aucune page
  ou route d'administration.
- lab-admin n'a ni socket Docker ni script : son frontend appelle le moteur (`core/engine.*`) ; il
  n'appelle App Builder que par `core/handoff.*`. L'intercepteur ne joint le jeton qu'aux bases de
  `tokenBases()` (`core/env.ts`, garde `carriesToken`) : un appel vers une nouvelle base sans l'y
  ajouter part sans jeton.
- Le bloc « Ma base » ne montre le mot de passe du développeur qu'au clic (`Cache-Control:
  no-store`, journalisé) : ne change pas ce comportement. La réponse de création d'utilisateur ne
  porte `password` que si l'email n'est pas parti.
- Tests : backend `backend/api/tests.py` ; frontend `*.spec.ts` dans `core/` (lancés par l'hôte au
  build seulement s'ils font partie du build ; ne les modifie pas).

## 2. lab-admin — relecture
1. **Sécurité de l'interface** : chaque vue de `backend/api/views.py` et sa permission ; chaque
   route de `app.routes.ts` et sa garde ; un élément d'administration affiché à un non-admin (même
   s'il est refusé par l'API, c'est un constat `basse` ou `moyenne`) ; `localStorage` ;
   `innerHTML`/`bypassSecurityTrust*` ; secrets affichés ou journalisés dans la console.
2. **Simplicité** : pour chaque page, l'utilisateur comprend-il en une lecture ce qu'il peut faire ?
   Parcours à vérifier : première connexion d'un développeur (Accueil, initialisation) ; créer un
   projet, le déployer, lire le verdict des tests ; ouvrir son espace VS Code ; lire sa base ;
   régler un compte d'envoi d'email ; adresse d'essai. Pour chacun : étapes, messages d'erreur
   (le moteur rend des codes comme `409 pg_trust_enabled` : l'utilisateur voit-il une phrase
   compréhensible ?), états vides, états de chargement et d'attente d'un job (`job-suivi`),
   confirmation avant une action destructive (`confirm-dialog`).
3. **Foyer** (règles exactes au § 5 du préambule) : couleurs en dur hors `src/styles.scss`, 44 px,
   900 px, navigation verticale, polices auto-hébergées, thème sombre (chaque token défini dans les
   deux thèmes).

## 3. Gabarit `_templates/` — relecture
Variantes : `django-angular/` (référence Foyer), `angular-only/`, `django-only/`, et `regles/`
(`FEUILLE_DE_ROUTE.md`, `CLAUDE.md`, `AGENTS.md` copiés dans chaque projet).
1. **Cohérence entre variantes** : mêmes tokens, même navigation, mêmes `core/` (`token-scope.ts`,
   `redirect-uri.ts`, `keycloak.service.ts` avec `pkceMethod: 'S256'`) dans `angular-only` et
   `django-angular` ; même `api/authentication.py` et mêmes réglages dans `django-only` et
   `django-angular` (`DEFAULT_PERMISSION_CLASSES`, docs en `DEBUG` seulement, `gunicorn.conf.py`).
   Un écart entre variantes est un constat ; la correction aligne sur `django-angular`.
2. **Foyer** : la référence elle-même respecte-t-elle ses règles (aucune couleur en dur dans un
   composant, 44 px, 900 px, polices dans `src/assets/fonts/`) ? Pages `home` et `profile` : textes,
   état vide, erreurs.
3. **`regles/`** : les règles qu'ils énoncent sont-elles exactes face au `CLAUDE.md` du lab ?
   Une phrase fausse ou périmée se corrige.

**Contraintes propres au gabarit — à respecter absolument :**
- `_templates/regles/FEUILLE_DE_ROUTE.md` **doit garder sa ligne `## Lot 2 — `** (sinon toute
  création de projet avec graine échoue) et le format exact des titres de lot ; ne touche pas aux
  titres « Commande de test » et « Lot 1 ».
- Garde tous les marqueurs `__APP_NAME__`, `__APP_SLUG__`, `__APP_TITLE__`, `__BACKEND_PORT__`,
  `__FRONTEND_PORT__`, `__TEST_COMMAND__`, `__DATE__` : `new-app.sh` les remplace. Vérifie avant de
  finir : `grep -rho "__[A-Z_]*__" /work/dev/_templates | sort | uniq -c` donne les mêmes marqueurs
  qu'au début (note la liste au départ dans `/tmp`).
- `_templates/django-angular/frontend/e2e/cloisonnement.spec.ts` est **le** test que le runner joue
  pour toutes les apps : ne le modifie pas.
- Une modification du gabarit ne touche que les futures apps : si elle corrige un défaut, dis dans
  le rapport quelles apps existantes le portent probablement (sans les modifier, elles ne sont pas
  montées).
- Le gabarit n'a pas de suite de tests jouée par l'hôte : n'y change que ce que tu as relu deux fois,
  et vérifie la syntaxe (`PYTHONPYCACHEPREFIX=/tmp/pycache python3 -m py_compile` pour le Python).

## Section propre à la tâche dans le rapport
Après « Constats », ajoute `## Parcours de lab-admin` (par parcours : étapes, frictions, corrections
faites ou proposées) et `## Gabarit` (écarts entre variantes, conformité Foyer, marqueurs vérifiés).

## Ce que tu ne fais pas
- Pas de nouvelle page, pas de changement de navigation, pas de nouvelle route d'API, pas de
  changement d'appel au moteur (`lab-mcp/API.md` fait foi, il n'est pas dans tes cibles).
- Rien dans `/work/dev` hors de `_templates/` pour cette tâche (même si ce n'est pas un chemin
  refusé) : propose-le.
