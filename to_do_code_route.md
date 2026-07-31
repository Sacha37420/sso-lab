# MISSION — Application « code-route » : apprentissage du code de la route assisté par IA (Mistral)

Nouvelle application du lab (scaffold `new-app.sh`, type 4 — Django + Angular) : zone
documentaire du code de la route, banque de questions/quiz organisée par thème/type/
difficulté, analyse IA des réponses d'un usager pour lui construire un plan de révision
personnalisé, et génération IA de nouvelles questions calquées sur la logique (et les
pièges) des questions existantes.

Ce document est un brief autonome : tout ce qui est nécessaire pour l'exécuter y est
décrit, sans supposer de conversation ou de contexte préalable. Lire `dev/CLAUDE.md`
en entier avant de commencer — notamment les sections « Sécurité — cloisonnement des
applications » (Verrou 1/Verrou 2), « Base de données », « Tests end-to-end » et
« UI — identité Foyer », qui s'appliquent ici sans exception ni adaptation.

Implémente ce qui suit si le design est clair et sans ambiguïté. Si un doute réel
subsiste sur une sémantique attendue (ex. contenu légal exact d'un thème, formulation
d'une question), arrête-toi et rapporte les options plutôt que d'improviser — c'est un
outil de préparation à un examen réel, une approximation silencieuse y coûte plus cher
qu'ailleurs.

---

## Contraintes fondamentales

- **2 vCPU / 16 Go RAM partagés, aucun GPU** — les traitements IA sont des appels
  réseau à l'API Mistral (I/O, pas de calcul local lourd), donc aucun souci de charge
  CPU en soi ; la contrainte réelle ici est le **coût/débit de l'API** (voir Lot 4).
- **Aucune question générée par IA n'est jamais servie directement dans un quiz réel**
  sans validation humaine explicite. Un candidat au permis ne doit jamais tomber sur
  une question juridiquement fausse générée sans relecture.
- **Aucun secret Mistral en dur dans le code** — clé API dans une configuration
  chiffrée en base (voir Lot 3/4), jamais commitée, jamais loguée.
- Toute image (panneau, schéma, illustration) passe par l'API **`storage`** du lab —
  jamais de volume média propre à l'app, jamais de blob binaire en base (règle
  générale du dépôt, voir `CLAUDE.md` section « Fichiers rasters / médias »).

## Hors périmètre

- Génération d'images par IA (uniquement du texte/JSON structuré, voir « Sources de
  contenu » ci-dessous pour la couverture des illustrations — un vrai besoin, mais
  couvert par une banque d'images existante, pas par de la génération).
- Entraînement ou fine-tuning d'un modèle propre — uniquement des appels à l'API
  Mistral hébergée.
- Simulateur de conduite, code en conditions d'examen chronométré officiel, paiement.
- Correction manuscrite/OCR d'un test papier existant.
- Application mobile native — Angular responsive (Foyer) suffit.

## Sources de contenu — pas de banque de questions/images prête à l'emploi

Recherche faite avant ce document : **aucune banque de questions libre/légale n'a été
trouvée**. Les acteurs qui en ont une (Codeclic, Code en Poche, Codes Rousseau, Passe
ton Code…) sont des plateformes commerciales — leurs questions sont protégées par le
droit d'auteur, **ne jamais les scraper ni les recopier**, même reformulées. Toute
question doit être soit écrite à la main, soit générée par Mistral **à partir de
l'échantillon interne déjà validé** de l'app (Lot 4) — jamais à partir d'un contenu
commercial externe.

Pour les **illustrations** (panneaux, marquages), une vraie banque libre existe :
Wikimedia Commons héberge les panneaux de signalisation français en SVG, sous licence
**CC-BY-SA** (catégorie « Road signs of France », fichiers `France road sign
<code>.svg`) — utilisables avec attribution. Prévoir un script/commande de gestion
ponctuel qui télécharge un premier lot de SVG pertinents et les pousse dans `storage`
via `storage_client.upload(...)`, associés aux `FicheCours`/`Question` concernées,
avec la mention d'attribution stockée à côté (champ `illustration_credit` sur
`FicheCours`/`Question`, ex. `"Roulex 45, Wikimedia Commons, CC BY-SA"`). C'est du
travail d'amorçage (seed), pas un flux automatisé — un admin choisit quels panneaux
associer à quelles questions/fiches, il n'y a pas de mapping automatique fiable entre
un SVG Wikimedia et un thème donné.

---

## Décisions d'architecture actées

### Nom, ports, groupe

- Nom de l'app : `code-route` (slug schéma DB : `code_route`). Lancer
  `bash scripts/new-app.sh`, type `4` (Django + Angular), laisser les ports se
  suggérer automatiquement (prochains libres ≥ 8083/4200 — `robot-lab` occupe déjà
  8094/4212 et son `engine` 8095, donc les prochains libres seront vraisemblablement
  8096/4213, mais laisser le script les calculer plutôt que les figer ici).
- **Groupe Keycloak requis** (`--require-group`) : décision à prendre au moment du
  scaffold selon qui doit réellement avoir accès (toute la famille ou seulement les
  personnes en préparation au permis) — ne pas laisser vide. Si un groupe dédié est
  créé (ex. `code-route`), l'ajouter à `sso-lab/ldap/init.ldif` **avec `e2e_member`
  comme membre** (règle obligatoire du dépôt, sans quoi le test e2e de cloisonnement
  considère `e2e_member` comme non-membre et casse en silence).
- Instance PostgreSQL : `postgres` partagée (`devdb`) — aucune donnée géospatiale,
  pas de raison de choisir `postgis`.

### Modèle de données (schéma `code_route`)

- `Theme` — `nom`, `description`, `ordre`. Table éditable en admin, **pré-remplie**
  via une migration de données avec les grands thèmes de l'épreuve officielle
  (route, conducteur, circulation routière, autres usagers, dispositions
  administratives, notions diverses, sécurité du passager/véhicule, équipements,
  environnement, premiers secours) — à ajuster librement, ce n'est pas figé : le but
  est d'avoir une taxonomie de démarrage, pas une liste légale à respecter au mot près.
- `FicheCours` — `theme` (FK), `titre`, `contenu` (markdown, texte en base — pas un
  fichier), `ordre`, `illustration_path` (chemin `storage`, nullable),
  `illustration_credit` (texte nullable — attribution, ex. banque Wikimedia Commons).
- `Question` — `theme` (FK), `enonce`, `type` (`qcm_unique` / `qcm_multiple` /
  `vrai_faux`), `difficulte` (`facile` / `moyen` / `difficile`), `illustration_path`
  (chemin `storage`, nullable), `illustration_credit` (texte nullable),
  `explication_generale`, `origine`
  (`humaine` / `ia`), `statut` (`validee` / `proposee` / `rejetee` — les questions
  d'origine `humaine` sont créées directement `validee`), `generation` (FK nullable
  vers `GenerationIA`, pour tracer d'où vient une question générée).
- `Reponse` — `question` (FK), `texte`, `correcte` (bool), `explication` (nullable —
  utile pour expliciter un piège sur un distracteur).
- `QuizSession` — `utilisateur_email`, `date_debut`, `date_fin` (nullable tant qu'en
  cours), `themes_filtres` (M2M ou CSV d'IDs), `difficulte_filtree` (nullable),
  `nombre_questions`, `score` (nullable tant qu'en cours).
- `QuizReponse` — `session` (FK), `question` (FK), `reponses_choisies` (JSON, IDs de
  `Reponse`), `correcte` (bool), `temps_ms` (nullable).
- `AnalyseIA` — `utilisateur_email`, `date`, `contenu` (JSON structuré, voir Lot 3),
  `resume_texte`.
- `GenerationIA` — `theme` (FK), `difficulte`, `date`, `prompt_utilise` (texte),
  `modele`, `nombre_demande`, `nombre_genere`, `statut` (`en_cours` / `terminee` /
  `erreur`).
- `ConfigurationMistral` — singleton (`pk=1` forcé, comme `restauration`), `actif`
  (bool), `api_key` (chiffrée), `modele` (défaut `mistral-large-latest`).
- `SiteExterne` — `nom`, `url`, `statut` (`gratuit` / `freemium` / `payant`),
  `offre_resume` (texte libre, ex. « abonnement à partir de 2,99 €/mois »),
  `date_verification` (date de dernière vérification manuelle du tarif — ces prix
  changent souvent, voir Lot 1bis), `ordre`.

### Zone documentaire / images — API `storage`

Un seul « pot commun » en lecture/écriture pour tout le groupe autorisé de l'app
(personne ne doit avoir un espace de stockage individuel ici) : c'est exactement le
cas déjà traité par `carto-lab` (« carte commune, tout le groupe lit/écrit tout »),
**pas** celui de `conciergerie`/`restauration` (pas de compte de service nécessaire).

- Copier le pattern `carto-lab/backend/api/storage_client.py` : le token JWT de
  l'utilisateur courant est simplement forwardé vers `storage` (pas de compte de
  service), fonctions `upload(auth_header, relative_path, fileobj, filename,
  content_type)` / `download_to_tempfile(...)` / `delete(...)`.
- Convention de chemin : `questions/<id>/<nom-fichier>` et `fiches/<id>/<nom-fichier>`.
- Côté `storage/.env` : ajouter `azp=code-route` à `KEYCLOAK_TRUSTED_CLIENTS`.
- Provisionner le partage unique une fois, via la commande de gestion de `storage` :
  ```
  python manage.py create_group_share code-route --owner sacha --required-groups <groupe-choisi-ci-dessus>
  ```
- L'endpoint de téléchargement d'une illustration doit réappliquer le cloisonnement
  de l'app (vérifier `azp`/`groups` comme toute route protégée) — ne jamais
  réexposer un accès anonyme à ces fichiers (à la différence du cas `restauration`,
  ici il n'y a pas de page publique sans authentification).

### Intégration Mistral

Deux usages, un seul modèle de configuration global (pas de clé par utilisateur —
c'est le propriétaire du lab qui paie l'usage API pour tout le groupe autorisé,
comme `restauration`, pas comme `robot-lab`) :

- `ConfigurationMistral` (singleton, `pk=1`) — page « Paramétrage » (réservée aux
  emails listés dans `ADMIN_EMAILS`, variable `.env`, séparation simple admin/usager
  sans système de rôles complet) pour saisir/activer la clé.
- Réutiliser le mécanisme de chiffrement de `robot-lab/backend/api/fields.py`
  (`EncryptedTextField`, Fernet dérivé de `SECRET_KEY`) — recopier/adapter ce fichier
  tel quel, ne pas réinventer.
- Amorçage de la clé : variable `MISTRAL_API_KEY` dans `code-route/.env` (gitignoré,
  jamais commité — comme tout `.env` du lab). Une commande de gestion idempotente
  (ex. `seed_config_mistral`, appelée une fois au déploiement, ou un
  `post_migrate` best-effort) lit `config('MISTRAL_API_KEY', default='')` et, si
  non vide et si `ConfigurationMistral` n'a pas encore de clé enregistrée, l'écrit
  dans le champ chiffré et active `actif=True`. La valeur en clair ne doit jamais
  transiter ailleurs que par cette lecture d'env au démarrage — jamais loguée, jamais
  renvoyée par une API (le champ `api_key` est write-only côté serializer, comme
  `restauration`/`robot-lab`). Un admin peut ensuite la changer via la page
  Paramétrage sans toucher au `.env`.
- Client HTTP Mistral : `backend/api/mistral_client.py`, fonction unique
  `completer_json(system, message, schema)` — SDK `mistralai`, `response_format=
  {'type': 'json_object'}`, `temperature=0`, retries sur erreurs transitoires
  (429/5xx/timeout) uniquement, à l'identique du pattern retry de `robot-lab/backend/
  api/ai_client.py` (`RETRY_DELAYS = [3, 10]`).
- Prompts dans un module dédié **sans import de modèle** (évite les imports
  circulaires, comme `restauration/backend/api/prompts.py`) :
  `backend/api/prompts_mistral.py`, deux constructeurs de prompt (texte ci-dessous).

---

## Lot 0 — Scaffold + infra

1. `bash scripts/new-app.sh` (voir décisions ci-dessus pour les valeurs).
2. Créer le dépôt GitHub + sous-module (`dev/CLAUDE.md`, section « Étape 2 »).
3. Remplir `.env` (`SECRET_KEY`, `DEBUG=True`, `DOMAIN`).
4. `--require-group` dans `.keycloak-client-opts` — ne pas sauter cette étape.
5. `bash scripts/setup2.sh code-route --yes`.
6. Ajouter le service Celery + Redis dédiés au `docker-compose.yml` de l'app, sur le
   modèle exact de `carto-lab/docker-compose.yml` (réseau interne bridge dédié +
   `dev-net` pour Postgres/`storage-backend` + `sso-net` uniquement si un compte de
   service devait être ajouté plus tard — pas nécessaire en V1 puisqu'aucun compte
   de service n'est utilisé, voir ci-dessus) :
   ```yaml
   redis:
     image: redis:7-alpine
     networks: [code-route-net]
     healthcheck: {test: ["CMD", "redis-cli", "ping"], interval: 5s, timeout: 3s, retries: 20}

   worker:
     build: ./backend
     command: celery -A config worker --loglevel=info --concurrency=2
     depends_on: {redis: {condition: service_healthy}}
     networks: [dev-net, code-route-net]
   ```
   Concurrency `2` et pas de verrou global façon `atelier-3d` : les tâches sont des
   appels réseau à Mistral, pas des calculs CPU lourds — mais garder un œil sur le
   coût API si plusieurs générations sont lancées en parallèle (voir Lot 4).

## Lot 1 — Zone documentaire

- CRUD `Theme` / `FicheCours` (API + pages Angular Foyer standard : liste par thème,
  détail en markdown rendu, upload d'illustration via `storage`).
- Endpoint de téléchargement d'illustration protégé (voir plus haut).
- Commande de gestion d'amorçage (`seed_illustrations_wikimedia` ou équivalent) qui
  télécharge un premier lot de SVG « France road sign » depuis Wikimedia Commons vers
  `storage`, avec `illustration_credit` renseigné — associer manuellement (admin)
  chaque image à la fiche/question pertinente, pas de mapping automatique.
- Pas de recherche plein texte en V1 (hors périmètre) — navigation par thème suffit.

## Lot 1bis — Page « Autres ressources » (sites tiers)

Page listant les principaux sites/apps externes de préparation au code de la route,
avec pour chacun s'il est gratuit et le résumé de son offre — pas d'appel API vers
ces sites (pas de scraping, fragile et à la limite des CGU), un simple CRUD
`SiteExterne` alimenté à la main comme `Theme`/`FicheCours`.

**Recherche faite le 2026-07-31, à revérifier avant publication** (les tarifs
changent souvent, et certaines sources se contredisaient déjà entre elles au moment
de la recherche — ne pas publier tel quel sans un nouveau contrôle rapide) :

| Site | Statut | Offre (approximative, à vérifier) |
|---|---|---|
| [securite-routiere.gouv.fr](https://www.securite-routiere.gouv.fr/passer-son-permis-de-conduire/preparation-de-lexamen-du-code-de-la-route) | Gratuit | Site officiel de la Sécurité routière — modules vidéo gratuits par thème, pas un simulateur d'examen blanc complet |
| [Prévention Routière](https://www.preventionroutiere.asso.fr/tests-code-de-la-route/) | Gratuit (partiel) | 4 tests gratuits, via partenariat superCode/digiSchool |
| [Passe ton Code](https://www.passetoncode.fr/) | Gratuit | Tests illimités annoncés gratuits, inscription à l'examen également proposée |
| [Codeclic](https://www.codeclic.com/gratuit.php) | Freemium | Test gratuit de 40 questions ; offre complète annoncée à 3000 questions conformes 2026, prix de l'offre complète non trouvé avec certitude |
| [Ornikar](https://www.ornikar.com/code) | Freemium | Abonnement à partir de 2,99 €/mois (3 mois : 7,99 € ; 6 mois : 14,99 €), +1700 questions, examens blancs illimités |
| [Codes Rousseau — Pass Rousseau](https://www.envoituresimone.com/code-de-la-route/guides/code-rousseau) | Payant | Sources contradictoires trouvées (entre ~17 € et ~40 € pour 6 mois selon la source) — **ne pas publier de chiffre avant vérification directe sur le site de l'éditeur** |
| Code en Poche | Non déterminé | Aucune information de prix fiable trouvée lors de la recherche — à vérifier avant d'ajouter une ligne |

Avant de publier cette page, revérifier chaque tarif par une recherche fraîche (les
pages listées datent, les prix bougent) plutôt que de recopier le tableau ci-dessus
tel quel — il sert de point de départ, pas de source de vérité figée.

## Lot 2 — Banque de questions + moteur de quiz

- CRUD `Question`/`Reponse` (réservé aux admins pour la saisie manuelle — un usager
  ne crée jamais de question lui-même).
- `POST /api/quiz/demarrer/` — paramètres `themes[]` (vide = tous), `difficulte`
  (vide = toutes), `nombre_questions` ; tire aléatoirement parmi les questions
  `statut=validee` correspondantes, crée `QuizSession`.
- `POST /api/quiz/<id>/repondre/` — enregistre une `QuizReponse` par question.
- `POST /api/quiz/<id>/terminer/` — calcule le score, marque `date_fin`, déclenche la
  tâche Celery d'analyse (Lot 3) de façon asynchrone (ne bloque pas la réponse HTTP).
- Historique des sessions d'un usager (liste + détail question par question, avec
  explication de chaque piège raté).

## Lot 3 — Analyse IA des résultats (Mistral)

Déclenchée en fin de quiz (tâche Celery), agrège l'historique de l'usager (pas
seulement la session qui vient de se terminer) par thème/type/difficulté :
taux de réussite, pièges récurrents ratés (texte des questions ratées + explication).

**Prompt système** (`prompts_mistral.construire_prompt_analyse`) :

```
Tu es un moniteur d'auto-école expérimenté qui prépare un candidat à l'épreuve
théorique du code de la route français.

On te fournit les statistiques de réussite d'un candidat par thème, ainsi que le
texte des questions qu'il a ratées récemment avec l'explication du piège associé.
Ne te sers d'aucune autre connaissance du code de la route que celle strictement
déductible des données fournies : ne complète jamais avec une règle non citée dans
les questions/fiches transmises.

Produis un diagnostic strictement au format JSON suivant :
{
  "points_forts": ["<theme>", ...],
  "points_faibles": [
    {"theme": "<theme>", "taux_reussite": <0-100>, "explication": "<texte>"}
  ],
  "plan_revision": [
    {"theme": "<theme>", "priorite": "haute|moyenne|basse", "conseil": "<texte>"}
  ],
  "fiches_a_relire": ["<id_theme>", ...],
  "resume": "<2-3 phrases, ton encourageant, jamais culpabilisant>"
}

Ceci est une aide à la révision, pas un verdict — le résumé doit rester encourageant
même si le taux de réussite global est faible.
```

Le résultat est stocké dans `AnalyseIA` et affiché sur une page « Mon bilan » côté
frontend, avec liens directs vers les `FicheCours` recommandées.

## Lot 4 — Génération IA de nouvelles questions (Mistral)

Déclenchée manuellement (page admin, jamais automatique) : `POST
/api/generation-ia/lancer/` avec `theme_id`, `difficulte`, `nombre_demande` — crée un
`GenerationIA` (`statut=en_cours`), lance une tâche Celery, polling du statut côté
frontend (même pattern que la page Debug de `lab-admin` : `GET
/api/generation-ia/<id>/statut/`).

La tâche fournit à Mistral, en few-shot, un échantillon des questions **existantes et
validées** du thème/difficulté demandés (énoncé + réponses + explication du piège).
**Amorçage requis** : ce mécanisme suppose un minimum de questions déjà validées par
thème (quelques-unes suffisent, mais zéro ne fonctionne pas — pas d'échantillon, pas
de génération cohérente). Avant le Lot 4, écrire à la main un premier lot de
questions par thème, en s'appuyant sur le texte réglementaire officiel (Code de la
route, Légifrance — texte de loi public, librement réutilisable, à la différence des
question-tests commerciaux cités plus haut) plutôt que sur une source commerciale.

**Prompt système** (`prompts_mistral.construire_prompt_generation`) :

```
Tu es un concepteur d'épreuves officielles du code de la route français. On te donne
un échantillon de questions déjà validées pour un thème et un niveau de difficulté
donnés (énoncé, réponses, réponse correcte, explication du piège).

Génère de nouvelles questions ORIGINALES pour le même thème et la même difficulté,
qui suivent la même logique pédagogique et réutilisent le même TYPE de piège que les
exemples (double négation, exception à une règle générale, priorité contre-intuitive,
distracteur plausible mais faux, confusion entre deux règles proches...), sans jamais
reformuler ou dupliquer une question de l'échantillon.

Ne fabrique aucune règle de circulation qui ne soit pas déjà présente, explicitement
ou implicitement, dans l'échantillon fourni. Si tu ne peux pas générer une question
sûre sans inventer une règle non couverte par l'échantillon, génère-en moins plutôt
que de deviner.

Réponds strictement au format JSON suivant :
{
  "questions": [
    {
      "enonce": "<texte>",
      "type": "qcm_unique|qcm_multiple|vrai_faux",
      "reponses": [{"texte": "<texte>", "correcte": <bool>, "explication": "<texte ou null>"}],
      "explication_generale": "<texte>",
      "piege_utilise": "<catégorie de piège reprise de l'échantillon>"
    }
  ]
}
```

Chaque question générée est insérée avec `origine=ia`, `statut=proposee`, `generation`
pointant vers le `GenerationIA` correspondant — **jamais** directement `validee`.
Page admin de validation : liste des questions `proposees`, avec édition possible
avant validation, boutons Valider/Rejeter. Une question `rejetee` reste en base pour
traçabilité (jamais supprimée silencieusement) mais n'est jamais tirée dans un quiz.

## Lot 5 — Cloisonnement, tests, vitrine

- Copier tel quel `_templates/django-angular/frontend/e2e/cloisonnement.spec.ts` —
  aucune adaptation de contenu, uniquement les variables d'environnement du runner.
- Vérifier manuellement les deux sens du cloisonnement (membre du groupe passe,
  non-membre refusé, non-membre avec session SSO active refusé aussi).
- Décider si l'app apparaît dans `.app-descriptions` (vitrine publique 404) — probable
  si c'est un outil familial destiné à être visible, à trancher avec l'utilisateur ;
  dans tous les cas elle apparaîtra automatiquement dans les outils d'administration
  (lab-admin, catalogue E2E) dès qu'un `docker-compose.yml` existe, indépendamment de
  ce choix.
- `bash scripts/complete_404.sh` si ajoutée à la vitrine.

---

## Checklist finale

- [ ] App scaffoldée, sous-module créé, `--require-group` non vide, groupe LDAP
      (si nouveau) contient `e2e_member`.
- [ ] Modèle de données en place, thèmes pré-remplis.
- [ ] Zone documentaire (fiches + illustrations via `storage`) fonctionnelle,
      téléchargement d'illustration authentifié.
- [ ] Page « Autres ressources » publiée avec des tarifs revérifiés au moment de la
      construction (pas recopiés tels quels depuis ce document).
- [ ] Moteur de quiz : démarrage filtré par thème/difficulté, correction, historique.
- [ ] `ConfigurationMistral` chiffrée, page Paramétrage réservée aux `ADMIN_EMAILS`.
- [ ] Analyse IA post-quiz : tâche Celery asynchrone, résultat affiché avec liens
      vers les fiches recommandées, ton toujours encourageant même en cas d'échec.
- [ ] Génération IA de questions : jamais publiée sans passage par `proposee` →
      validation humaine explicite ; page de validation admin fonctionnelle.
- [ ] Worker Celery + Redis dédiés démarrés (`docker-compose.yml`), pas de secret
      Mistral en dur.
- [ ] Test e2e `cloisonnement.spec.ts` copié tel quel et vert dans les deux sens.
- [ ] Décision vitrine publique tranchée avec l'utilisateur.
