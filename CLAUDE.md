# dev/ — Guide de travail pour Claude

Dépôt parent qui héberge toutes les applications du lab (Django + Angular, Spring, Angular seul).
Les applications sont des **sous-modules git** pointant vers leurs propres dépôts GitHub (`Sacha37420/<app>`).

---

## Créer une nouvelle application

### Étape 1 — Scaffold : `new-app.sh`

```bash
bash scripts/new-app.sh
```

Le script demande interactivement :
- **Nom** de l'application (ex: `mon-app`, lettres minuscules + tirets)
- **Type** : Spring Boot seul / Spring+Angular / Django seul / Django+Angular / Angular seul
- **Port backend** (suggéré automatiquement à partir du dernier port libre ≥ 8083)
- **Port frontend** (suggéré automatiquement à partir du dernier port libre ≥ 4200)
- **Scaffold** : télécharge Django via Docker ou Angular via Docker (répond `O`)

Ce que fait `new-app.sh` :
- Crée `dev/<app>/` avec la structure complète (backend, frontend, docker-compose, Dockerfiles, nginx, .env…)
- Copie et adapte le template depuis `_templates/django-angular/`
- Ajoute `<app>/` au `.gitignore` du dépôt parent (car ce sera un sous-module)
- Enregistre les ports dans `.ports`
- Ajoute le schéma SQL dans `infra/init/00_schemas.sql` (ou `infra/init-postgis/00_schemas.sql`
  si l'instance PostGIS est choisie — voir section « Base de données » plus bas)
- Crée `.keycloak-client-opts` (utilisé par `create-app-client.sh`)
- **Ne crée pas** le client Keycloak ni le dépôt GitHub

Le script demande ensuite le **groupe requis** (cloisonnement). Le laisser vide rend l'app
accessible à tout compte du realm — le script le signale bruyamment.

Enfin, pour une app avec base (Spring seul/+Angular, Django seul/+Angular), le script demande
l'**instance PostgreSQL** : `postgres` (partagée, `devdb`, défaut) ou `postgis` (dédiée SIG,
`gisdb` — extension PostGIS absente de l'instance partagée, voir la section dédiée plus bas).
Cette question est posée en tout dernier, justement pour ne décaler aucune des questions
précédentes : un appel non-interactif qui ne fournit pas de réponse pour cette dernière ligne
obtient EOF → défaut `postgres`, exactement comme pour le groupe. L'exemple ci-dessous, déjà
utilisé pour les apps existantes, continue donc de fonctionner sans modification et choisit
`postgres` :

```bash
printf 'mon-app\n4\n8088\n4206\nO\ndevelopers\n' | bash scripts/new-app.sh
```

Pour choisir explicitement l'instance `postgis`, ajouter une dernière ligne `2` :
```bash
printf 'carto-lab\n4\n8091\n4209\nO\ndevelopers\n2\n' | bash scripts/new-app.sh
```

---

### Étape 2 — Dépôt GitHub + sous-module

Après le scaffold, initialiser git dans le dossier créé, créer le repo GitHub et l'enregistrer comme sous-module :

```bash
cd mon-app
git init && git checkout -b main
git add . && git commit -m "feat: initial scaffold"
gh repo create Sacha37420/mon-app --public
git remote add origin https://github.com/Sacha37420/mon-app.git
git push -u origin main
cd ..
# Retirer du .gitignore (new-app.sh l'y avait ajouté) et enregistrer comme sous-module
sed -i '/^mon-app\/$/d' .gitignore
git submodule add https://github.com/Sacha37420/mon-app.git mon-app
```

---

### Étape 3 — Remplir `.env`

```bash
nano mon-app/.env
```

Champs à renseigner au minimum :
- `SECRET_KEY` (généré par `new-app.sh`, peut être laissé tel quel en dev)
- `DEBUG=True` en dev
- `DOMAIN=CHANGE_ME` → laisser `CHANGE_ME` en HTTP local, ou mettre le FQDN pour Caddy HTTPS

---

### Étape 3 bis — Cloisonner l'app (à ne pas sauter)

Le lab est **exposé sur Internet**. Être authentifié dans le realm `ssolab` ne doit donner accès
à rien : toute app se réserve à un ou plusieurs groupes LDAP. Ajouter `--require-group` dans
`<app>/.keycloak-client-opts` (liste séparée par des virgules) :

```
--public --port 4208 --caddy-path mon-app --require-group famille,amis
```

`create-app-client.sh` en déduit tout, de façon idempotente : rôle `<client>-access` assigné à chaque
groupe, flow `require-<client>` lié au client, et `KEYCLOAK_REQUIRED_GROUPS` écrit dans `<app>/.env`.

> ⚠ Tout nouveau groupe LDAP créé ici (dans `sso-lab/ldap/init.ldif`) **doit** ajouter `e2e_member`
> comme membre — voir section « Tests end-to-end » plus bas. Sans ça, le test de cloisonnement
> automatisé de toute app qui utilise ce groupe considère `e2e_member` comme non-membre et casse
> en silence (faux négatif : le test échoue alors que le cloisonnement réel est correct).

---

### Étape 4 — Déploiement complet : `setup2.sh`

```bash
bash scripts/setup2.sh mon-app --yes
```

`setup2.sh <app>` enchaîne **dans l'ordre** :
1. `clean2.sh <app>` — arrête et supprime les containers de l'app
2. `reset_url.sh` — propage LAN/WAN/Keycloak dans tous les `.env`
3. Démarrage de **sso-lab** (Keycloak + LDAP + Caddy)
4. Attente que Keycloak réponde (jusqu'à 300 s)
5. **`create-app-client.sh <app>`** — crée ou met à jour le client Keycloak (secret, redirect URIs, claim `groups`)
6. `recompose_docker.sh --app <app> --force` — build et démarre les containers
7. `get-ports-list.sh` — régénère `ports.env`
8. `open-bbox-ports2.sh` — ouvre les ports sur le routeur Bbox si accessible

> **C'est `setup2.sh` qui crée le client Keycloak**, via `create-app-client.sh` à l'étape 5.  
> `create-app-client.sh` peut aussi être appelé seul pour recréer/mettre à jour un client sans tout redéployer :
> ```bash
> bash scripts/create-app-client.sh mon-app $(cat mon-app/.keycloak-client-opts)
> ```

---

## Base de données — deux instances PostgreSQL

`infra/docker-compose.yml` héberge **deux** instances PostgreSQL séparées, jamais une par app :

| Instance | Container | Image | Base | Rôle | Pour qui |
|---|---|---|---|---|---|
| `postgres` | `dev-postgres` | `postgres:16-alpine` | `devdb` | `devuser` | La grande majorité des apps — un schéma par app |
| `postgis` | `dev-postgis` | `postgis/postgis:16-3.5` | `gisdb` | `gisuser` | Apps SIG uniquement (ex. `carto-lab`) |

**Pourquoi deux instances et pas juste l'extension PostGIS en plus sur `postgres`** :
- L'image de `postgres` est **alpine (musl)** ; le paquet PostGIS d'Alpine dépend de `postgresql18`,
  incompatible avec le PG16 de `devdb`.
- Les images `postgis/postgis` officielles sont **Debian (glibc)**. Basculer le datadir existant de
  `devdb` (collation `en_US.utf8` sur musl) vers glibc **corromprait silencieusement les index
  texte**, et serait en plus un *downgrade* (16.14 → 16.9 au mieux sur les tags PostGIS stables).
- Bénéfice annexe : une charge SIG lourde (import raster, calcul Voronoï national…) ne peut pas
  dégrader les autres apps, et le rôle read-only d'un service comme `pg_featureserv` (accès QGIS,
  cf. `carto-lab`) reste enfermé dans une base qui ne contient **que** du SIG.

**Aucune des deux instances ne publie jamais le port 5432** sur l'hôte ni sur Internet — même
règle que pour toute base du lab.

### Convention de nommage des identifiants

Les mots de passe vivent dans `infra/.env` sous des **clés distinctes** :
`POSTGRES_PASSWORD` (instance `postgres`) et `POSTGIS_PASSWORD` (instance `postgis`).
`reset_url.sh` propage chacun sous sa propre clé vers les `.env` des apps ; `upsert_env` est un
no-op quand la clé cible est absente d'un `.env`, donc les deux jeux d'identifiants ne peuvent
jamais se marcher dessus. Une app sur `postgres` déclare `DB_PASSWORD` dans son `.env` ; une app
sur `postgis` déclare `POSTGIS_PASSWORD` (jamais `DB_PASSWORD`) — c'est ce nom de clé, pas
`DB_HOST`, qui fait que `reset_url.sh` sait quoi propager où.

### Choisir l'instance pour une nouvelle app

`new-app.sh` pose la question (voir Étape 1) pour toute app avec base. Par défaut : `postgres`.
Choisir `postgis` uniquement si l'app manipule réellement des données géospatiales (imports de
cartes, calculs géo, rasters…) — pas par précaution.

Schéma créé dans `infra/init/00_schemas.sql` (instance `postgres`) ou
`infra/init-postgis/00_schemas.sql` (instance `postgis`) selon le choix. Comme ce fichier n'est
rejoué qu'à l'initialisation du volume, `ensure-schemas.sh` (appelé par `setup2.sh` avant chaque
déploiement) rattrape les schémas manquants à chaud — il lit `DB_HOST` de chaque app pour cibler
le bon container, donc il n'y a rien à faire de spécial pour une app `postgis`.

### Fichiers rasters / médias (apps avec upload)

Si une app persiste des fichiers hors base (ex. rasters GeoTIFF de `carto-lab`), son volume doit
être déclaré `external: true` dans son `docker-compose.yml`, avec un `name:` explicite. Sans ça,
`clean2.sh <app>` (`docker compose down --volumes`) le supprime à chaque `setup2.sh <app> --yes`
— `clean2.sh` protège les volumes de `infra` et `sso-lab`, mais pas ceux qu'une app se serait
donnés elle-même. Voir `carto-lab/docker-compose.yml` (volume `carto-media`) pour l'exemple —
c'est le défaut pour tout fichier **propre à une app** (rasters SIG, exports…).

**Stockage de fichiers partagé du lab — `storage`** : contrairement au cas général ci-dessus,
l'app `storage/` (voir sa description dans le tableau des sous-modules) est le point d'entrée
unique désigné pour tout fichier **utilisateur** du lab — au même titre que `postgres`/`postgis`
pour les données structurées. Son volume (`storage-media`) est donc **possédé par
`infra/docker-compose.yml`**, pas par `storage/docker-compose.yml`, exactement comme `dev-net` :
créé automatiquement au premier `docker compose up` de `infra` (pas de `docker volume create`
manuel), et jamais touché par le cycle de vie d'une seule app. `storage/docker-compose.yml` le
référence en `external: true` (nom `infra_storage-media`). Seul `storage-backend` le monte —
toute autre app y accède exclusivement via l'API de `storage` (`KEYCLOAK_TRUSTED_CLIENTS`, voir
plus haut), jamais en montant le volume directement : un montage direct court-circuiterait les
contrôles de permission par namespace/partage de l'API.

**Reste à migrer** (état au 2026-07-30, revue complète des 11 sous-modules — volumes déclarés,
champs fichier des modèles, `MEDIA_ROOT`, code recevant des uploads) :

- `atelier-3d` — le **seul volume média privé** restant (`atelier3d-media`, monté par `backend`
  *et* `worker`). La plus lourde des migrations : le worker Celery écrit plusieurs Go par projet
  (photos → nuages de points → maillages) sans utilisateur connecté, et tout le pipeline de
  reconstruction est à revérifier de bout en bout. Pas de trou de sécurité en attendant : le
  serving passe déjà par une `MediaView` authentifiée.
- `traitement-de-fichiers-compils` et `arbre-genealogique` — pas de volume, mais des **blobs de
  fichiers utilisateur dans `devdb`** (`Fichier.fichier_binaire`, `MediaObject.data`, tous deux
  `BinaryField`), ce qui gonfle la base et ses sauvegardes. Le premier est une réimplémentation
  quasi complète de `storage` (propriétaire par email + partages) : sa migration supprime plus de
  code qu'elle n'en ajoute.

Toute **nouvelle** app qui a besoin de stocker des fichiers utilisateur doit appeler l'API
`storage` directement plutôt que de se donner son propre volume média ou de mettre des blobs en base.

> `robot-lab` n'est **pas** concernée : son volume `downloads` est non-`external` à dessein
> (contenu transitoire, `engine` écrit / `backend` sert puis supprime).

**`conciergerie`, `carto-lab` et `restauration` sont migrées.**

- `conciergerie` (`Frais.facture` → `Frais.facture_path`, un partage `storage` par bien nommé
  `conciergerie-bien-<id>`, créé automatiquement au premier upload) est l'exemple de référence pour
  le cas « plusieurs partages dynamiques, autorisation déjà décidée par l'app appelante » : voir
  `conciergerie/backend/api/storage_client.py` (miroir de `keycloak_admin.py` — même compte de
  service `<app>-admin`, réutilisé ici pour appeler `storage` au lieu de l'API Admin Keycloak) et
  `FraisViewSet` (`conciergerie/backend/api/views.py`).
- `carto-lab` (`Layer.raster_file` → `Layer.raster_path`, un unique partage `carto-lab` avec
  `required_groups='developers'`, provisionné via `create_group_share`) est l'exemple de référence
  pour le cas « carte commune, tout le groupe lit/écrit tout » : voir
  `carto-lab/backend/api/storage_client.py` (variante **sans** compte de service — le token de
  l'utilisateur courant est simplement forwardé, `azp=carto-lab` ajouté à
  `KEYCLOAK_TRUSTED_CLIENTS` côté `storage`, aucune tâche Celery ne touchant de fichier). Piège
  évité au passage, à garder en tête pour toute future opération de traitement qui aurait besoin du
  token : ne **jamais** faire transiter un `Authorization` par un dict de paramètres persisté en
  base (`Layer.metadata`/`Recipe.steps` sont exposés publiquement par l'API) — un `contextvars.ContextVar`
  module-level (`api/processing.py`) porte le token le temps de l'opération, jamais stocké.
- `restauration` (`Plat.photo` → `Plat.photo_path`, un unique partage `restauration` provisionné via
  `create_group_share`, compte de service `restauration-admin` autorisé par
  `KEYCLOAK_SERVICE_WRITE_SHARES=restauration-admin:restauration`) est l'exemple de référence pour
  le cas **« la lecture doit être anonyme »** : la carte du restaurant (page « commander », sans
  authentification) affiche les photos des plats, donc il n'existe aucun token à forwarder sur le
  chemin de lecture. `storage` n'a — et ne doit avoir — aucun chemin de lecture anonyme : c'est
  l'app qui **republie** délibérément les octets via un endpoint proxy `AllowAny`
  (`views_public.public_plat_photo`), le compte de service restant le seul à parler à `storage`.
  La décision d'exposer publiquement vit ainsi dans l'app qui porte la règle métier. Voir
  `restauration/backend/api/storage_client.py` et `PlatViewSet` (`api/views.py`).

Les trois migrations ont aussi corrigé un défaut préexistant, de la même famille. Pour
`conciergerie` et `carto-lab`, un trou de sécurité : le téléchargement du fichier (facture /
raster) n'était pas authentifié (`django.views.static.serve` monté sur `config/urls.py`, hors DRF,
sans permission) — le nouvel endpoint proxy réapplique le cloisonnement de l'app
(manager/co-propriétaire pour `conciergerie`, groupe `developers` pour `carto-lab`). Pour
`restauration`, une fonctionnalité **cassée** : les photos étaient écrites dans `MEDIA_ROOT`
(= `BASE_DIR/media`, donc dans le bind mount `./backend:/app`, hors de tout volume) et servies par
`static(settings.MEDIA_URL, …)`, qui retourne une liste vide quand `DEBUG=False` — c'est-à-dire
toujours, en déploiement. Toute photo uploadée donnait un 404.

> ⚠ `restauration` n'a **pas** d'interface d'upload de photo côté Angular : le champ n'est
> renseignable que par l'API (`photo_file`, multipart). C'est pourquoi la colonne était vide en base
> et que la migration n'a eu aucune donnée à reprendre. Si une interface est ajoutée un jour, elle
> poste `photo_file` sur `POST/PATCH /api/plats/` — rien d'autre à changer côté backend.

---

## Sécurité — cloisonnement des applications

Le lab est exposé sur Internet. **Deux verrous** protègent chaque app, et il faut les deux :
supprimer l'un ouvre l'app en grand.

### Verrou 1 — Barrière navigateur (flow Keycloak)

Flow `require-<client>` lié au client via `authenticationFlowBindingOverrides.browser`. Il refuse
(`Access denied`) qui n'a pas le rôle realm `<client>-access`. Posé automatiquement par
`create-app-client.sh` dès que `--require-group` est présent.

**Structure obligatoire du flow** — ne pas improviser ici, les deux variantes évidentes sont fausses :

```
require-<client>                        (top level)
  ├─ require-<client>-auth              REQUIRED      ← encapsule TOUTE l'authentification
  │    ├─ Cookie                        ALTERNATIVE
  │    ├─ Identity Provider Redirector  ALTERNATIVE
  │    └─ require-<client>-forms        ALTERNATIVE
  │         ├─ Username Password Form   REQUIRED
  │         └─ require-<client>-otp     CONDITIONAL
  └─ require-<client>-gate              CONDITIONAL   ← la barrière
       ├─ Condition - user role (negate = true, rôle <client>-access)  REQUIRED
       └─ Deny access                                                  REQUIRED
```

- ❌ **Barrière à la racine d'une copie du flow `browser`** → Keycloak compte un sous-flow
  `CONDITIONAL` non désactivé comme « required », et `REQUIRED and ALTERNATIVE at same level` ⇒ il
  **ignore les alternatives**. Le formulaire de login disparaît et **plus personne ne peut se
  connecter**. (Vérifié : ça a cassé `test-angular`.)
- ❌ **Barrière dans le sous-flow `forms`** → l'utilisateur qui a déjà une session SSO passe par
  l'authentificateur `Cookie`, qui court-circuite `forms` : la barrière n'est jamais évaluée.
  **Contournement vérifié.**
- ✅ **Encapsuler l'authentification dans un sous-flow `REQUIRED`** supprime toute `ALTERNATIVE` de la
  racine. La barrière, frère `CONDITIONAL`, est alors toujours évaluée — cookie SSO ou pas.

### Verrou 2 — Serrure API (backend)

**Le flow ne voit jamais un appel direct à l'API.** Tout backend Django doit vérifier lui-même, dans
`api/authentication.py` (le template le fait déjà) :

1. **`azp`** — le client émetteur du token doit être `settings.KEYCLOAK_CLIENT_ID` ;
2. le claim **`groups`** doit croiser `settings.KEYCLOAK_REQUIRED_GROUPS` (vide ⇒ aucun filtre).

> **Pourquoi `azp` et pas `aud`** : les backends tournent en `verify_aud: False` (Keycloak ne met pas
> le `clientId` dans `aud` sans mapper d'audience). Or le realm expose `admin-cli` en client **public
> avec password grant** (défaut Keycloak). Sans contrôle de `azp`, tout compte du realm obtient un
> token via `admin-cli` et appelle **n'importe quelle API**, sans jamais croiser le flow — un token
> `admin-cli` ne porte d'ailleurs aucun claim `groups`, donc le contrôle des groupes seul le
> rejetterait aussi. **Ne jamais retirer ces deux contrôles.**

### Règles

- Toute nouvelle app **doit** avoir un `--require-group`. Sans lui, elle accepte tout compte du realm.
- Un nouvel inscrit n'a **aucun groupe** ⇒ accès à **aucune** app. C'est voulu.
- `code-server` est l'exception : pas de flow, protégé en amont par **oauth2-proxy**
  (`OAUTH2_PROXY_ALLOWED_GROUPS`). Il tourne en `--auth=none` et n'a **aucune protection propre**.
- Après tout changement de cloisonnement, **tester dans les deux sens** : un membre du groupe passe,
  un non-membre est refusé — et vérifier qu'un non-membre avec une session SSO active est aussi refusé.
  Ce test est maintenant automatisable — voir section « Tests end-to-end » ci-dessous.

### Verrou 2 généralisé — API appelable par d'autres apps du lab (`KEYCLOAK_TRUSTED_CLIENTS`)

Le contrôle `azp` du Verrou 2 ci-dessus suppose un client unique (`azp == settings.KEYCLOAK_CLIENT_ID`).
Ça bloque toute app tierce : le frontend d'une autre app obtient un token dont `azp` est **son propre**
client_id, jamais celui de l'API appelée — et toutes les apps du lab partagent le même `DOMAIN` (seul le
chemin Caddy change), donc un tel appel est **same-origin**, aucun CORS à gérer, seul `azp` bloque.

Pour une API qui doit être appelable par d'autres apps au nom de leurs utilisateurs (ex. `storage`),
remplacer l'égalité stricte par une **liste blanche explicite** :

```python
KEYCLOAK_TRUSTED_CLIENTS = {
    c.strip()
    for c in config('KEYCLOAK_TRUSTED_CLIENTS', default=KEYCLOAK_CLIENT_ID).split(',')
    if c.strip()
}
# ...
if claims.get('azp') not in settings.KEYCLOAK_TRUSTED_CLIENTS:
    raise AuthenticationFailed(...)
```

Défaut : uniquement le client de l'app elle-même — même périmètre que le pattern habituel. Pour
autoriser une app tierce, ajouter son `client_id` à `KEYCLOAK_TRUSTED_CLIENTS` dans le `.env` de l'API
appelée — **aucun changement côté Keycloak**. La propriété de sécurité est préservée à l'identique :
`admin-cli` n'est jamais dans la liste. Le contrôle de groupe reste inchangé et continue de s'appliquer
normalement (chaque client du realm porte le même claim `groups`). Voir `storage/backend/api/authentication.py`
pour l'implémentation de référence.

#### Écriture sans utilisateur connecté — comptes de service (`KEYCLOAK_SERVICE_WRITE_SHARES`)

`KEYCLOAK_TRUSTED_CLIENTS` suppose toujours un utilisateur humain derrière le token (son propre
token, forwardé par l'app appelante). Un **worker asynchrone** (Celery, tâche planifiée…) n'a
aucun utilisateur connecté à cet instant-là — rien à forwarder. Pour ce cas, `storage` réutilise le
mécanisme de **compte de service** déjà en place pour `lab-admin`/`restauration`
(`scripts/create-app-client.sh`, section "Service account" — client compagnon confidentiel
`<app>-admin`, `serviceAccountsEnabled: true`, activé par la présence de
`<app>/.keycloak-service-account-roles`, flux `client_credentials`, voir
`lab-admin/backend/api/keycloak_admin.py` pour l'implémentation de référence du côté obtention de
token). Ce fichier ne sert habituellement qu'à assigner des rôles `realm-management` (administrer
Keycloak) — mais le client `<app>-admin` qu'il fait créer est un client OAuth2 générique, rien
n'empêche de l'utiliser *aussi* pour appeler `storage`. Une app qui veut uniquement un accès de
service à `storage` (pas d'administration Keycloak) crée ce fichier **vide** : le client compagnon
et son secret sont créés tout aussi bien, avec zéro rôle `realm-management` assigné.

Côté `storage` : `KEYCLOAK_SERVICE_WRITE_SHARES` (`.env`, format `client_id:partage,...`) mappe
chaque client de confiance vers **le seul partage** sur lequel il a un accès lecture/écriture — pas
de claim `email`/`groups` requis pour ce chemin (un compte de service n'en porte pas). Les clients
qui y figurent sont automatiquement inclus dans `KEYCLOAK_TRUSTED_CLIENTS` (pas besoin de les lister
deux fois). Voir `api.authentication.KeycloakServiceUser` et `api.permissions.resolve_namespace`.

#### Partage lié à un groupe Keycloak (`Share.required_groups`)

Pensé pour une app dont **tout le groupe autorisé** doit lire/écrire les mêmes données — cas
d'`atelier-3d` (encore à migrer) et de `carto-lab` (migré, cf. plus haut) : aucun cloisonnement
individuel, n'importe quel membre du groupe requis lit/modifie/supprime les données de n'importe
qui. Plutôt que de dupliquer la composition du groupe dans une liste de `ShareMember` à maintenir à
la main (risque de dérive silencieuse — même piège que documenté pour `e2e_member` plus haut),
`Share.required_groups` (CSV, même convention que `KEYCLOAK_REQUIRED_GROUPS`) lie dynamiquement
l'accès lecture/écriture au(x) groupe(s) LDAP : un nouveau membre du groupe a accès immédiatement,
un membre retiré perd l'accès immédiatement, rien à synchroniser côté `storage`.

Hors self-service à dessein : `POST /api/shares/` ne permet pas de le renseigner (un partage
lié à un groupe reste une décision d'infrastructure, pas quelque chose qu'un compte peut
s'attribuer). Provisionné via une commande de gestion — exemple réel (`carto-lab`) :
```
python manage.py create_group_share carto-lab --owner sacha --required-groups developers
```
`ShareMember.role` (`read`/`write`, défaut `read`) reste disponible en complément pour des membres
nommés individuellement (ex. `conciergerie` : accès par bien, ensembles de co-propriétaires
différents d'un bien à l'autre — ni un partage global par groupe, ni des espaces personnels ne
conviennent, une liste de membres explicite avec droit d'écriture reste nécessaire).

---

## Tests end-to-end (Playwright)

Chaque app a **un seul fichier** de test Playwright, à cet emplacement fixe et ce nom :
`<app>/frontend/e2e/cloisonnement.spec.ts`. Le formalisme complet (variables d'environnement
attendues, structure des tests) vit dans le template, à copier tel quel dans toute nouvelle app :
`_templates/django-angular/frontend/e2e/cloisonnement.spec.ts`. Ce fichier ne doit dépendre
d'aucun contenu spécifique à l'app (pas de sélecteur/texte propre à une page) — il doit rester
copiable sans adaptation.

**Pourquoi ce format précis** : il automatise le test manuel documenté juste au-dessus (section
« Règles ») — membre du groupe requis passe, non-membre refusé, non-membre avec session SSO déjà
active refusé aussi (le contournement historique : un authentificateur `Cookie` court-circuite un
flow mal structuré, cf. section « Verrou 1 » plus haut). **N'ajoutez pas d'autre fichier de test
E2E** dans une app sans d'abord mettre à jour cette section — le pipeline (catalogue + exécution
ci-dessous) suppose un seul fichier, ce nom précis.

### Architecture

- **`runner/`** (racine du dépôt, comme `infra/`/`sso-lab/` — pas un sous-module) : conteneur
  unique portant Playwright + Chromium pour tout le lab. Jamais dans l'image d'une app (contrainte
  2 vCPU/16 Go — voir `to_do_3D.md` pour le même principe côté atelier-3d). Réseau `sso-net`
  uniquement, monte tout le dépôt en lecture seule (`${HOST_DEV_ROOT}`, voir ci-dessous), **jamais
  exposé** (pas de port publié, pas de label Caddy) — atteint uniquement par nom de conteneur
  (`lab-runner`) depuis `lab-admin` (worker Celery) ou via `docker exec` depuis `setup_unit.sh`.
- **Deux comptes LDAP synthétiques** (`sso-lab/ldap/init.ldif`) : `e2e_member`, membre de **tous**
  les groupes existants (toujours le cas « membre » positif, quelle que soit l'app testée), et
  `e2e_outsider`, membre d'**aucun** groupe (toujours le cas « non-membre » négatif — aucune
  maintenance requise). Leurs mots de passe rotent normalement avec `rotate-ldap-user-passwords.sh`
  — le runner relit toujours la valeur courante dans `sso-lab/.env`, jamais de cache.
- **Catalogue vs exécution**, deux choses bien distinctes :
  - *Catalogue* (`GET /list` sur le runner, **pas de navigateur**) : à chaque déploiement d'une app
    (`scripts/setup_unit.sh`, étape best-effort en toute fin), liste les tests du fichier
    `cloisonnement.spec.ts` de l'app et les enregistre dans `lab-admin` (table `DebugTest`). Ne
    lance jamais de navigateur — reste rapide, compatible avec le dispatch parallèle tout-le-lab
    de `setup2.sh`.
  - *Exécution* (`POST /run` sur le runner, navigateur réel) : jamais automatique. Déclenchée à la
    main depuis la page **Debug** de `lab-admin` (une app, ou toutes), via
    `POST /api/debug/run/` → tâche Celery (`lab-admin` a son propre `redis`+`worker`, comme
    carto-lab) → runner → résultats stockés dans `DebugTest`, visibles dans le tableau.
- Un seul run à la fois, lab-wide : mutex en mémoire côté runner (409 si déjà occupé) **et**
  `--concurrency=1` sur le worker Celery de `lab-admin` — même principe que le verrou global
  d'atelier-3d, pour la même raison (2 vCPU/16 Go partagés).
- `CatalogSyncView` (`POST /api/debug/catalog-sync/`) est le seul endpoint de `lab-admin` en
  dehors de l'auth Keycloak par défaut : appelé par un script (`setup_unit.sh`), pas un navigateur,
  authentifié par secret partagé (header `X-Setup-Key` / `SETUP_CATALOG_KEY` dans
  `lab-admin/.env`, auto-généré si absent) — même famille de pattern que `X-Meteo-Key` de
  carto-lab.

### `HOST_DEV_ROOT` — piège à connaître avant de toucher au montage `/mnt/dev`

`lab-admin` et `runner/` montent tout le dépôt en lecture seule (`${HOST_DEV_ROOT}:/mnt/dev:ro`).
Si ce dépôt est édité depuis un conteneur (ex. `code-server`) **séparé** de la machine qui héberge
le démon Docker, un chemin relatif (`../`) se résout différemment selon l'endroit d'où
`docker compose` est invoqué et peut monter un dossier **vide** côté démon, en silence (pas
d'erreur — juste `/mnt/dev` vide). `HOST_DEV_ROOT` (`.env` racine, propagé par `reset_url.sh`)
fixe ça : vide par défaut (= pas de traduction nécessaire, cas courant d'une install classique),
à renseigner uniquement dans ce cas précis — voir le commentaire dans `.env.example`. Concerne
aussi `lab-admin/docker-compose.yml` : son ancien bind mount `./backend:/app` (code source, pas
juste `/mnt/dev`) a été retiré pour la même raison — le code de l'app est baké dans l'image
(comme carto-lab/atelier-3d), jamais monté en live.

---

## Rotation des secrets

Trois niveaux, tous à chaud (aucun wipe de volume) — détail complet dans le README, section
« Rotation des secrets » :

- **Ciblée** : `setup2.sh <app> --rotate-secrets --yes` (`SECRET_KEY` d'une app) ou `setup2.sh
  --rotate-secrets --yes` (`SECRET_KEY` de toutes les apps + mot de passe PostgreSQL partagé).
  ⚠ La variante « tout le lab » arrête d'abord l'infra (volumes préservés) — si la rotation échoue
  avec `Conteneur 'dev-postgres' non démarré`, relancer `recompose_docker.sh --app infra` puis
  reprendre.
- **Admin sso-lab** : `rotate-secrets.sh --yes` (LDAP admin/config, Keycloak admin).
- **Complète** : `rotate-secrets-full.sh --yes` — roule tout ce qui est automatisable, y compris
  le mot de passe de **chaque compte LDAP**, puis redémarre tous les services. Chaque utilisateur
  ayant une adresse email réelle (pas `uid@ssolab.local`) reçoit automatiquement son nouveau mot
  de passe par email (`notify-password-email.sh`, via le SMTP déjà configuré pour Keycloak dans
  `sso-lab/.env` — best-effort, un échec d'envoi n'annule jamais la rotation).

**Non automatisés, à roter manuellement** : `BBOX_ADMIN_PASSWORD` (risque de verrouiller l'admin
du routeur en cas d'échec de script) et `SMTP_PASSWORD` (mot de passe d'application Gmail, action
interactive côté compte Google).

**Ne jamais enchaîner `rotate-secrets-full.sh` avec `setup2.sh`** : `setup2.sh` sans nom d'app
régénère `sso-lab/.env` via `init-secrets.sh` (nouvelles valeurs `KEYCLOAK_ADMIN_PASSWORD`/`LDAP_*`
non appliquées aux services), ce qui désynchroniserait le `.env` des secrets tout juste rotés à
chaud. `rotate-secrets-full.sh` termine lui-même par `recompose_docker.sh --force`.

---

## Sous-modules existants

| Dossier | Dépôt | Type | Ports |
|---|---|---|---|
| `analyse-lora` | `Sacha37420/analyse-lora` | Django + Angular | 8086 / 4204 |
| `app-builder` | `Sacha37420/app-builder` | Django + Angular | 8087 / 4205 |
| `arbre-genealogique` | `Sacha37420/arbre-genealogique` | Django + Angular | 8090 / 4208 |
| `atelier-3d` | `Sacha37420/atelier-3d` | Django + Angular | 8092 / 4210 |
| `carto-lab` | `Sacha37420/carto-lab` | Django + Angular | 8091 / 4209 |
| `conciergerie` | `Sacha37420/conciergerie` | Django + Angular | 8084 / 4202 |
| `lab-admin` | `Sacha37420/lab-admin` | Django + Angular | 8083 / 4201 |
| `restauration` | `Sacha37420/restauration` | Django + Angular | 8088 / 4206 |
| `robot-lab` | `Sacha37420/robot-lab` | Django + Angular (+ `engine/` Playwright) | 8094 / 4212 |
| `storage` | `Sacha37420/storage` | Django + Angular | 8093 / 4211 |
| `traitement-de-fichiers-compils` | `Sacha37420/traitement-de-fichiers-compils` | Django + Angular | 8089 / 4207 |

> `robot-lab` a un **troisième service**, `engine/` (Node + Playwright + `ws`, port 8095) : le
> navigateur qu'il pilote est isolé là, jamais dans l'image Django — même règle que `runner/`.
> Il n'écrit jamais en base et ne voit jamais les clés API des utilisateurs (c'est Django qui
> appelle les fournisseurs IA et lui renvoie l'action à exécuter).

### Vitrine publique vs outils d'administration

`.app-descriptions` (racine) pilote **uniquement** la page 404 publique, servie **sans
authentification** : y ajouter une app publie son nom et sa description à tout visiteur. Les lignes
commentées gardent les bacs à sable et l'infra hors de cette page. Après toute modification :

```bash
bash scripts/complete_404.sh     # régénère sso-lab/fallback/html/404.html
```

Les **outils d'administration** (page « Apps du lab » de lab-admin, catalogue des tests E2E,
`add-user.sh`) affichent en revanche **toutes** les apps réellement déployées — une entrée de
`.ports` dont le dossier contient un `docker-compose.yml`. Ils étaient auparavant limités à
`.app-descriptions`, ce qui rendait invisible en silence toute app absente de ce fichier : trois
apps déployées (`conciergerie`, `storage`, `robot-lab`) n'apparaissaient nulle part et **n'étaient
jamais testées**. Découplé le 2026-07-30. Une app hors vitrine est signalée par une étiquette
« hors vitrine » dans lab-admin, pas masquée.

> Il n'y a **plus** de fichier `.hidden-groups`. Il n'existait que pour cacher `dom`/`harem` du temps
> où ils ne servaient qu'à `google-agenda` (app déplacée vers `dev2/` le 2026-07-29). Ces deux
> groupes sont désormais requis par `app-builder` et `storage` : les masquer donnait une vue fausse
> des droits à attribuer à un nouveau compte. Ne pas réintroduire ce mécanisme — si un groupe ne doit
> pas apparaître, c'est qu'il ne doit pas exister dans le realm.

---

## Scripts utiles

Les scripts d'orchestration vivent dans **`scripts/`** — les lancer avec `bash scripts/<nom>`
depuis la racine `dev/` (ils résolvent eux-mêmes la racine, donc le répertoire courant importe peu).
Les scripts **propres à un service** gardent leur chemin (ex: `sso-lab/setup-code-server-auth.sh`
ci-dessous, lancé avec `bash sso-lab/…`).

| Script | Rôle |
|---|---|
| `new-app.sh` | Scaffold d'une nouvelle app (interactif) |
| `setup2.sh <app> --yes` | Déploiement complet d'une app (ou de tout le lab) |
| `create-app-client.sh <app>` | Créer/mettre à jour le client Keycloak seul |
| `sso-lab/setup-code-server-auth.sh` | Créer le client Keycloak pour oauth2-proxy/code-server |
| `reset_url.sh` | Propager LAN/WAN/Keycloak dans tous les `.env` |
| `clean2.sh <app>` | Arrêter et supprimer les containers d'une app |
| `recompose_docker.sh --app <app>` | Rebuilder et redémarrer les containers d'une app |
| `get-ports-list.sh` | Régénérer `ports.env` depuis `.ports` |
| `open-bbox-ports2.sh` | Ouvrir les ports sur le routeur Bbox |
| `rotate-secrets-full.sh --yes` | Rotation complète de tous les secrets automatisables + redémarrage (voir « Rotation des secrets ») |
| `rotate-ldap-user-passwords.sh --yes` | Rotation à chaud du mot de passe de chaque compte LDAP, avec email au titulaire |
| `rotate-secrets.sh --yes` | Rotation à chaud des secrets admin sso-lab |
| `rotate-db-password.sh --yes` | Rotation à chaud du mot de passe PostgreSQL partagé |
| `rotate-app-secret.sh <app>` | Régénère le `SECRET_KEY` Django d'une app |

---

## Templates

Les templates sont dans `_templates/` :
- `_templates/django-angular/backend/` — config Django, authentication Keycloak JWT, drf-spectacular
- `_templates/django-angular/frontend/` — Angular avec Keycloak, auth guard, interceptor, pages home/profile

`new-app.sh` copie ces templates et remplace les placeholders :
- `__APP_NAME__` → slug kebab-case (ex: `mon-app`)
- `__APP_SLUG__` → snake_case pour le schéma SQL (ex: `mon_app`)
- `__APP_TITLE__` → titre lisible (ex: `Mon App`)
- `__BACKEND_PORT__` / `__FRONTEND_PORT__` → ports choisis
