# Orchestration — accès direct frontend → storage, partage hiérarchique, synchronisation par app

Ce document est un brief autonome : tout ce qui est nécessaire pour l'exécuter
y est décrit, sans supposer de conversation ou de contexte préalable. Il est
destiné à être exécuté par une instance de Claude Code disposant du Agent
tool, à la racine `dev/` (dépôt parent du lab, voir `dev/CLAUDE.md` — à lire
en entier avant de commencer, c'est le guide de travail de ce dépôt).

Toutes les apps du lab qui stockent des fichiers utilisateur (`conciergerie`,
`carto-lab`, `restauration`, `traitement-de-fichiers-compils`,
`arbre-genealogique`, `atelier-3d`) ont déjà été migrées vers l'app `storage`
(point d'entrée unique du lab pour les fichiers utilisateur — voir
`CLAUDE.md`, section « Fichiers rasters / médias », et le git log de
`<app>/backend/api/` pour chacune, qui détaille comment). Cette migration a
éliminé les volumes/blobs privés, mais a conservé un schéma d'accès simple :
un seul `Share` global par app dans `storage`, et chaque app **proxie**
systématiquement l'accès fichier via son propre backend authentifié. Ce
document orchestre l'étape suivante : un chantier fondation (unique, sur
`storage/`) et un chantier par app (parallèle, un sous-agent chacun) pour
répondre aux 4 objectifs ci-dessous.

## Les 4 objectifs (formulation d'origine, à respecter à la lettre)

1. **Passer autant que possible par une requête directe depuis le frontend
   d'une app vers les « médias »** (les fichiers stockés dans `storage`),
   plutôt que de systématiquement proxier via le backend de l'app. Concerne
   la **lecture** en priorité (`<img src>`, viewer 3D, téléchargement) — les
   écritures peuvent rester proxiées si l'app a besoin d'enregistrer des
   métadonnées en même temps (ex. créer une ligne `Fichier`/`Photo`).
2. **Synchroniser la logique de partage de chaque app avec les partages que
   permet `storage`** — c.-à-d. que le modèle de partage propre à chaque app
   (`TreeShare`, `Partage`, co-propriétaires de `conciergerie`, un futur
   `ProjectShare` pour atelier-3d) doit se traduire par de **vrais**
   `Share`/`ShareMember` dans `storage`, tenus à jour à chaque changement côté
   app. Ce n'est plus une option de défense en profondeur : c'est ce qui rend
   l'objectif 1 possible en toute sécurité (si le frontend appelle `storage`
   directement avec son propre token, c'est `storage` qui devient le seul
   rempart — il doit donc connaître les bonnes règles).
3. **Passer d'un système de partages plat à un système où un partage peut en
   contenir d'autres, l'enfant primant sur le parent** en termes de droits
   hérités — c.-à-d. une vraie hiérarchie dans le modèle de données de
   `storage` (pas une convention de nommage), avec une sémantique
   d'override : un enfant ne doit **pas** hériter automatiquement de tout ce
   que voit le parent (sinon partager un sous-dossier reviendrait à partager
   tout le dossier parent) — ses propres règles priment.
4. **`storage` doit permettre de voir clairement et simplement ses propres
   dossiers/fichiers et tous les partages qui nous sont accessibles** —
   remonter les ancêtres d'un partage profond auquel on a accès (sans exposer
   leur contenu si on n'y a pas droit), pour pouvoir naviguer jusqu'à ce qui
   nous est réellement partagé. Scénario concret à satisfaire : le
   propriétaire d'un dossier personnel dans `storage` en partage un
   sous-dossier à un utilisateur qui n'avait initialement accès à rien de ce
   dossier — cet utilisateur doit voir apparaître le partage racine (comme
   conteneur, pour pouvoir naviguer jusqu'à ce qui lui est accessible), mais
   en l'ouvrant, il ne doit voir **que** ce qui lui est effectivement partagé
   (pas les fichiers/dossiers/partages voisins auxquels il n'a pas droit).

## Constat de départ — vérifié à la rédaction de ce document, à revérifier rapidement

**Aucune app du lab ne fait aujourd'hui de requête directe frontend → storage.**
Vérifié explicitement sur `carto-lab`, qui semblait le candidat le plus
évident (le seul à forwarder le token de l'utilisateur plutôt qu'un compte de
service) : son frontend appelle `GET /api/layers/<id>/raster/` sur **son
propre backend** (`carto-lab/backend/api/views.py`, `LayerRasterView`), qui
lui **forward l'en-tête Authorization reçu** vers `storage` côté serveur
(`storage_client.download(request.headers.get('Authorization', ''), ...)`).
Le navigateur ne parle jamais à `storage` directement. Même schéma partout
ailleurs (`MediaView` pour atelier-3d/arbre-généalogique,
`FichierDownloadView` pour traitement-de-fichiers-compils, `FraisViewSet.facture`
pour conciergerie, `public_plat_photo` pour restauration).

**`storage` n'a aucun fallback `?token=`** dans
`KeycloakJWTAuthentication.authenticate()` (`storage/backend/api/authentication.py`)
— seul l'en-tête `Authorization: Bearer` est lu. Or ni une balise `<img src>`
ni le `fetch()` interne de `GLTFLoader` ne peuvent poser d'en-tête. **Sans ce
fallback, l'objectif 1 est irréalisable pour tout média affiché en `<img>` ou
chargé par un viewer 3D** (seuls les téléchargements déclenchés par du code —
qui peut poser un header via `fetch()` — s'en passeraient). C'est un
prérequis d'infra partagée, pas un détail : à traiter dans le chantier
fondation.

**Le nom d'un `Share` est un slug plat** (`validate_namespace_slug`,
`^[a-z0-9]([a-z0-9-]{0,62}[a-z0-9])?$`, sans séparateur hiérarchique) — la
hiérarchie demandée par l'objectif 3 ne peut donc pas être simulée par une
convention de nommage crédible (le validateur l'interdit, et ça ne donnerait
pas de vraie sémantique d'héritage/override) : il faut une vraie relation
parent/enfant dans le modèle de données.

**Point important qui simplifie le travail** : l'**autorisation correcte**
pour un accès direct (objectifs 1+2) ne dépend **pas** de la hiérarchie
(objectif 3). Un `Share` plat classique, avec de vrais `ShareMember`
synchronisés sur le modèle de partage de l'app, suffit déjà à sécuriser un
accès direct frontend → storage — c'est le modèle qui existe déjà, juste
sous-utilisé (un seul `Share` global par app aujourd'hui, au lieu d'un par
ressource). La hiérarchie n'est nécessaire que pour l'**organisation** et la
**découverte** (objectifs 3+4). **Conséquence pour l'orchestration** : le
chantier fondation (hiérarchie + découverte + fallback `?token=`) et les
chantiers par app (accès direct + synchronisation) peuvent tourner **en
parallèle**, aucun ne bloque le démarrage de l'autre — seule la
**convention de nommage** des partages créés par les chantiers app doit être
choisie en pensant à une hiérarchie future (voir plus bas), pour rester
migrable sans renommage quand le chantier fondation aboutit.

## Règle de coordination — ne pas éditer `storage/.env` en parallèle

Plusieurs chantiers vont vouloir ajouter des lignes à `storage/.env`
(`KEYCLOAK_TRUSTED_CLIENTS`, `KEYCLOAK_SERVICE_WRITE_PREFIXES`/`_SHARES`) en
même temps que le chantier fondation modifie `storage/backend/`. Pour éviter
tout conflit d'édition concurrente sur un fichier partagé :

> **Chaque sous-agent d'un chantier App ne modifie JAMAIS `storage/.env` ni
> aucun fichier sous `storage/`.** Il rapporte dans sa synthèse finale les
> lignes exactes à y ajouter (client à ajouter à `KEYCLOAK_TRUSTED_CLIENTS`,
> préfixe/partage à ajouter à `KEYCLOAK_SERVICE_WRITE_PREFIXES`/`_SHARES`).
> C'est l'orchestrateur (toi, après réception de tous les rapports) qui
> applique ces lignes en un seul edit groupé et relance `storage` une fois.

Le chantier fondation, lui, est seul sur `storage/` — pas de conflit pour lui.

## Chantier fondation — `storage/` (un seul agent)

Contexte à lire en entier avant de commencer : `dev/CLAUDE.md` (notamment
« Sécurité — cloisonnement », « Verrou 2 généralisé » et « Partage lié à un
groupe Keycloak »), puis tout `storage/backend/api/` (`models.py`,
`permissions.py`, `views.py`, `serializers.py`, `validators.py`,
`authentication.py`) et `storage/frontend/`.

Trois livrables, dans cet ordre de priorité :

### 1. Fallback `?token=` dans `KeycloakJWTAuthentication` (rapide, à faire en premier)

Reprendre exactement le pattern déjà utilisé par les apps (ex.
`atelier-3d/backend/api/authentication.py`,
`arbre-genealogique/backend/api/authentication.py`,
`KeycloakQueryTokenAuthentication`) : si pas d'en-tête `Authorization`,
lire `request.GET.get('token', '')`. Tous les autres contrôles (azp trusted,
groupes…) restent identiques, juste la source du token change. Documenter
pourquoi (comme le fait déjà l'app atelier-3d dans son commentaire équivalent) :
une balise `<img>`/`GLTFLoader` ne peut pas poser d'en-tête.

### 2. Hiérarchie de partages avec override

Ajouter un vrai `parent` (FK nullable vers `Share`) sur le modèle `Share`.
Sémantique à implémenter :

- Un enfant **n'hérite pas automatiquement** des droits de son parent — ses
  propres `required_groups`/`ShareMember` priment complètement (pas d'union
  avec ceux du parent). Un partage parent peut donc exister uniquement comme
  **conteneur d'organisation**, sans donner accès à son contenu.
- `resolve_namespace` doit continuer à fonctionner sur le partage **exact**
  demandé (résolution par nom, comme aujourd'hui) — la hiérarchie ne change
  pas la résolution d'un accès direct à un partage donné, seulement la
  **découverte**.
- Réfléchis à la contrainte d'unicité du nom : aujourd'hui `Share.name` est
  globalement unique dans tout le realm. Avec une hiérarchie, un nom
  peut-il se répéter sous des parents différents (ex. deux personnes ayant
  chacune un sous-partage nommé « photos ») ? Documente le choix et pourquoi.

### 3. Découverte — « mes fichiers et tous les partages qui me sont accessibles »

Nouvel endpoint (ou extension de `GET /api/shares/`) qui renvoie, pour
l'utilisateur courant :

- Ses partages possédés/membre directement (comportement actuel, conservé).
- Les **ancêtres** de tout partage auquel il a accès par un chemin plus
  profond (visible comme conteneur, **sans** exposer les fichiers/sous-partages
  de cet ancêtre auxquels il n'a pas droit).
- Réfléchis à l'implication de sécurité : afficher l'**existence** et le
  **nom** d'un ancêtre auquel on n'a pas accès direct est-il acceptable ?
  D'après le scénario de l'objectif 4 ci-dessus, oui — le but est justement
  de pouvoir remonter jusqu'à ce qui nous est partagé. Documente ce choix
  explicitement, comme le fait `CLAUDE.md` pour les décisions de sécurité
  similaires.
- Adapter `storage/frontend/` pour naviguer cette hiérarchie (arborescence
  cliquable), pas juste deux listes plates comme aujourd'hui.

### Contrat que les chantiers App doivent pouvoir suivre

Documente clairement, dans ta synthèse finale, comment un partage créé par un
chantier App aujourd'hui (plat, ex. `arbre-genealogique-sacha-tree-12` —
naming à confirmer avec eux) pourra être **rattaché a posteriori** à une
hiérarchie une fois ton modèle en place (migration de données : remplir
`parent` sur les partages existants sans changer leur `name` ni casser les
`relative_path` déjà utilisés par les apps). Les chantiers App n'ont pas
besoin d'attendre ce chantier pour démarrer, mais leurs partages doivent
rester migrables sans renommage.

### Implémente si le design est clair, sinon rapporte les options

Même barre que les chantiers App : si un point (ex. l'unicité du nom sous
hiérarchie, ou la profondeur de récursion acceptable pour la découverte) a
une réponse ambiguë ou risquée en termes de sécurité, arrête-toi et rapporte
les options plutôt que de trancher seul — c'est l'app la plus sensible du
lab. Teste en réel — sur de vrais comptes, avec `force_authenticate` (DRF) ou
des tokens Keycloak réels, jamais de mock de `storage_client` : c'est la
méthode utilisée pour toutes les migrations passées vers `storage`,
vérifiable dans le git log de chaque app déjà migrée. Au minimum : un
propriétaire, un membre direct d'un partage profond sans accès au parent, et
un compte sans aucun accès.

## Chantiers App — instructions communes à tous les sous-agents

Lancer **en parallèle**, un sous-agent par app :

1. `carto-lab`
2. `conciergerie`
3. `traitement-de-fichiers-compils`
4. `arbre-genealogique`
5. `atelier-3d`

(`restauration` est un cas à part, voir sa section dédiée plus bas — pas de
sous-agent dédié sauf décision explicite de l'utilisateur.)

Contexte et instructions communes à donner à chaque sous-agent :

> Tu travailles sur `dev/<app>/`, un sous-module git du lab décrit dans
> `dev/CLAUDE.md` (lis-le en entier avant de commencer, notamment « Fichiers
> rasters / médias », « Sécurité — cloisonnement » et « Verrou 2 généralisé —
> KEYCLOAK_TRUSTED_CLIENTS »). Cette app est déjà migrée vers `storage` (lis
> le git log de `<app>/backend/api/` pour le détail de cette migration).
>
> Objectif à deux volets, dans cet ordre :
>
> **1. Synchroniser le modèle de partage de l'app avec de vrais `Share`/
> `ShareMember` dans `storage`.** Aujourd'hui `storage` ne voit qu'un seul
> partage global pour toute l'app. Il faut un partage **par ressource
> métier** (arbre / bien / fichier partagé individuellement / projet),
> synchronisé à chaque création/modification/suppression du partage côté app
> (`TreeShare`, `Partage`, co-propriétaires de biens, ou le nouveau
> `ProjectShare` pour atelier-3d — voir sa section dédiée). Utilise
> `KEYCLOAK_SERVICE_WRITE_PREFIXES` (le compte de service existe déjà, voir
> `.keycloak-service-account-roles` et l'entrée déjà présente dans
> `storage/.env`) avec un préfixe qui reste compatible avec une hiérarchie
> future (ex. `<app>-<owner_username>-<type>-<id>`, à ajuster selon l'app).
> Tu tournes en parallèle d'autres sous-agents (dont celui du chantier
> fondation sur `storage/`) sans visibilité sur leurs rapports — choisis un
> nommage clair, documente ton raisonnement, la coordination avec le modèle
> de hiérarchie final se fera après coup, par l'orchestrateur, une fois tous
> les rapports reçus. Ajoute/retire les `ShareMember` correspondants via
> `POST/DELETE /api/shares/<name>/members/` à chaque changement du modèle de
> partage propre à l'app — c'est ce qui rend l'étape 2 sûre.
>
> **2. Faire lire les médias directement par le frontend, sans passer par le
> backend de l'app.** Une fois le partage réel en place, le backend de l'app
> n'a plus besoin de proxier la *lecture* : son serializer peut renvoyer
> l'URL storage complète et signée par un token utilisateur
> (`https://<domaine>/storage-api/api/files/<namespace>/content/<relative_path>`,
> même origine que l'app donc pas de souci CORS — voir `CLAUDE.md`, « Verrou 2
> généralisé »), et le frontend appelle cette URL directement (avec son
> propre token, en en-tête `Authorization` pour un `fetch()`, ou en
> `?token=` pour un `<img>`/viewer 3D — **ce fallback query-token dépend du
> chantier fondation sur `storage/`, vérifie s'il est déjà livré avant de
> câbler les balises `<img>`/GLTFLoader ; sinon documente la dépendance et
> avance sur tout le reste**). Les écritures (upload) peuvent rester proxiées
> par le backend de l'app si celui-ci a besoin d'enregistrer des métadonnées
> en même temps.
>
> Si tu ajoutes le client de l'app à `KEYCLOAK_TRUSTED_CLIENTS` côté storage :
> **ne modifie pas `storage/.env` toi-même** (risque de conflit avec les
> autres sous-agents qui tournent en parallèle) — rapporte la ligne exacte à
> ajouter dans ta synthèse finale.
>
> Implémente si le design est clair et sans ambiguïté ; si tu as un doute
> réel sur la sémantique attendue, arrête-toi et rapporte les options.
>
> Teste en réel — vrais comptes, `force_authenticate` ou tokens réels, jamais
> de mock de `storage` (méthode déjà utilisée pour toutes les migrations
> passées, vérifiable dans le git log de l'app) : partage créé, accès direct
> qui fonctionne pour un membre, refusé pour un non-membre, retrait d'un
> partage qui coupe l'accès direct immédiatement.
>
> Termine par : ce qui a été fait, les lignes à ajouter à `storage/.env`, les
> commandes de provisionnement (`create_group_share`/prefix) à lancer, et tout
> redéploiement nécessaire (`setup2.sh <app> --yes`) — **ne lance pas
> toi-même `setup2.sh`** si un autre agent est susceptible de tourner en même
> temps (cette machine n'a que 2 vCPU : deux builds Docker lourds en parallèle
> se ralentissent mutuellement au point de sembler bloqués) : rapporte
> la commande, l'orchestrateur séquencera les déploiements.

### Précisions par app

- **`carto-lab`** : cas le plus simple — tout le groupe `developers` a déjà
  accès à toute la carte via un unique partage `required_groups=developers`.
  L'objectif 1 (accès direct) peut donc être fait **sans même créer de
  partage par ressource** : storage autorise déjà n'importe quel développeur
  directement sur le namespace `carto-lab` via son propre token forwardé.
  Vérifie que `azp=carto-lab` est bien dans `KEYCLOAK_TRUSTED_CLIENTS`
  (`grep KEYCLOAK_TRUSTED_CLIENTS storage/.env` — déjà le cas au moment de la
  rédaction de ce document, mais reconfirme) et adapte le frontend pour
  appeler storage directement au lieu de `LayerRasterView`. Bon candidat pour
  valider le pattern avant les apps plus complexes.
- **`conciergerie`** : le modèle par Bien existe déjà (`conciergerie-bien-<id>`)
  mais **sans** `ShareMember` réels — le compte de service a une confiance
  totale sur tout le préfixe, l'app fait 100 % du contrôle elle-même
  aujourd'hui. Ajoute les `ShareMember` (co-propriétaires du bien + managers)
  pour que l'objectif 1 soit sûr.
- **`traitement-de-fichiers-compils`** : `Fichier.proprietaire` + `Partage`
  (par email) existent déjà côté app — à répliquer en `Share`/`ShareMember`
  par fichier (ou par lot si un partage par fichier individuel s'avère trop
  fin/coûteux à maintenir ; à toi de juger et documenter).
- **`arbre-genealogique`** : `TreeShare` existe déjà — à répliquer en
  `Share`/`ShareMember` par arbre. Cas particulier à trancher explicitement :
  `Tree.is_public` (arbre visible sans être dans `TreeShare`) — un accès
  direct storage doit-il aussi fonctionner pour ce cas, et comment
  l'exprimer (un groupe couvrant « tout utilisateur authentifié de l'app » ne
  correspond à aucun groupe Keycloak réel) ? Si pas de solution propre,
  garder le proxy pour les arbres publics uniquement et documenter pourquoi.
- **`atelier-3d`** : **aucun modèle de partage de projet n'existe
  aujourd'hui** (`Project.owner_email` seul). Avant de parler storage,
  propose un modèle `ProjectShare` (email + rôle lecture/écriture, sur le
  modèle de `TreeShare`) et les endpoints qui vont avec. Implémente-le
  seulement si le design est clair (ex. un sous-projet CAO doit-il hériter du
  partage de son `parent_project` ? — arrête-toi et rapporte si ambigu).
  Ensuite seulement, réplique ce modèle en `Share`/`ShareMember` par projet
  côté storage.

### `restauration` — exception documentée, pas de sous-agent

La lecture (photos de plats sur la carte publique) doit rester **anonyme**
(page « commander » sans authentification), et `storage` n'a — et ne doit
avoir — aucun chemin de lecture anonyme (cf. `CLAUDE.md`). L'objectif 1 ne
s'applique donc **pas** à ce chemin de lecture : garder le proxy
`public_plat_photo` tel quel. Si l'utilisateur souhaite explicitement
qu'un sous-agent regarde le volet manager (upload authentifié), le lancer
séparément — ne pas l'inclure dans le lot parallèle par défaut.

## Séquencement recommandé

1. Lancer les 5 sous-agents App + le sous-agent Fondation **en même temps**
   (aucune dépendance de démarrage entre eux, cf. constat plus haut).
2. Une fois tous les rapports revenus : appliquer en un seul edit groupé les
   lignes rapportées pour `storage/.env`, relancer `storage` une fois,
   provisionner les partages rapportés (`create_group_share`/prefix), puis
   séquencer les redéploiements des apps (jamais plus d'un build lourd à la
   fois sur cette machine à 2 vCPU — atelier-3d en particulier peut prendre
   des dizaines de minutes si le cache Docker est perdu, cf.
   `atelier-3d/backend/.heavy-build`).
3. Revérifier après coup que le fallback `?token=` de storage (chantier
   fondation) est bien déployé avant de considérer les balises `<img>`/
   GLTFLoader des apps comme fonctionnelles en direct.
