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
donnés elle-même. Voir `carto-lab/docker-compose.yml` (volume `carto-media`) pour l'exemple.

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

---

## Sous-modules existants

| Dossier | Dépôt | Type | Ports |
|---|---|---|---|
| `analyse-lora` | `Sacha37420/analyse-lora` | Django + Angular | 8086 / 4204 |
| `app-builder` | `Sacha37420/app-builder` | Django + Angular | 8087 / 4205 |
| `front-cadriciel` | `Sacha37420/front-cadriciel` | Angular seul | 4200 |
| `spring-app` | `Sacha37420/spring-app` | Spring Boot | 8082 |
| `table-manager` | `Sacha37420/table-manager` | — | — |

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
