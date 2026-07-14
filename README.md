# dev/ — Lab SSO multi-applications

Plateforme d'apprentissage et de développement autour de **Keycloak**, **OpenLDAP**, **PostgreSQL** et **Caddy**, hébergeant plusieurs applications Django + Angular authentifiées via OIDC.

Les applications sont des **sous-modules git** autonomes. Les scripts du dépôt parent gèrent le cycle de vie complet (scaffold, déploiement, Keycloak, ports réseau).

---

## Architecture

```
dev/
├── sso-lab/            ← Keycloak 22 + OpenLDAP + phpLDAPadmin + Caddy + code-server
├── infra/              ← PostgreSQL 16 + pgAdmin 8
├── _templates/         ← templates Django+Angular (copiés par new-app.sh)
├── analyse-lora/       ← Django + Angular  [submodule]
├── app-builder/        ← Django + Angular  [submodule] — éditeur de specs d'apps
├── front-cadriciel/    ← Angular seul      [submodule] — tableau de bord du lab
├── restauration/       ← Django + Angular  [submodule]
├── spring-app/         ← Spring Boot       [submodule]
├── table-manager/      ← [submodule]
├── new-app.sh          ← scaffold interactif d'une nouvelle app
├── setup2.sh           ← déploiement complet d'une app (ou de tout le lab)
├── create-app-client.sh← crée/met à jour les clients Keycloak
├── recompose_docker.sh ← cycle de vie des stacks Docker
├── clean2.sh           ← arrête et supprime les containers d'une app
├── reset_url.sh        ← propage LAN/WAN/Keycloak dans tous les .env
├── get-ports-list.sh   ← régénère ports.env depuis .ports
├── open-bbox-ports2.sh ← ouvre les ports NAT sur la Bbox Bouygues
├── init-secrets.sh     ← génère des mots de passe forts
├── .ports              ← registre des ports (géré par new-app.sh)
└── bbox.env            ← source de vérité réseau (LAN/WAN)
```

---

## Services et ports

### Infrastructure

| Service | Port LAN | URL HTTPS |
|---|---|---|
| Keycloak | 8080 | `https://DOMAIN/auth/` |
| phpLDAPadmin | 8081 | direct LAN uniquement |
| pgAdmin | 5050 | direct LAN uniquement |
| PostgreSQL | 5432 | interne Docker uniquement |
| code-server | — | `https://DOMAIN/code/` |

### Applications

| Application | Port backend | URL API (HTTPS) | Port frontend | URL frontend (HTTPS) |
|---|---|---|---|---|
| front-cadriciel | — | — | 4200 | `https://DOMAIN/cadriciel/` |
| app-builder | 8087 | `https://DOMAIN/app-builder-api/` | 4205 | `https://DOMAIN/app-builder/` |
| analyse-lora | 8086 | `https://DOMAIN/lora-api/` | 4204 | `https://DOMAIN/lora/` |
| restauration | 8088 | `https://DOMAIN/restauration-api/` | 4206 | `https://DOMAIN/restauration/` |
| spring-app | 8082 | direct LAN uniquement | — | — |

---

## Accès

**Caddy** (dans `sso-lab`) sert de reverse proxy HTTPS avec certificats Let's Encrypt automatiques.

| Chemin | Service |
|---|---|
| `https://DOMAIN/auth/` | Keycloak (realm ssolab) |
| `https://DOMAIN/code/` | code-server (VS Code navigateur) — restreint aux groupes `developers` et `admins` |
| `https://DOMAIN/cadriciel/` | front-cadriciel (tableau de bord lab) |

`code-server` est protégé par **oauth2-proxy** : seuls les utilisateurs authentifiés Keycloak appartenant aux groupes `developers` ou `admins` y ont accès. Docker de l'hôte est accessible depuis son terminal.

---

## Cloisonnement des accès

Être authentifié dans le realm `ssolab` **ne donne accès à rien**. Chaque application est réservée
à un ou plusieurs groupes LDAP, et ce cloisonnement repose sur **deux verrous complémentaires** —
aucun des deux ne suffit seul.

### Verrou 1 — Barrière navigateur (Keycloak)

Chaque client possède un flow d'authentification dédié `require-<client>`, lié via
`authenticationFlowBindingOverrides.browser`. Il refuse la connexion (`Access denied`) à qui n'a pas
le rôle realm `<client>-access` — rôle assigné aux groupes autorisés.

Ce verrou ne protège que **la porte du navigateur**.

### Verrou 2 — Serrure API (backend)

Le flow ne voit jamais un appel direct à l'API. Le backend doit donc vérifier lui-même, dans
`api/authentication.py` :

- **`azp`** (le client émetteur du token) doit être celui de l'application ;
- le claim **`groups`** doit croiser `KEYCLOAK_REQUIRED_GROUPS` (renseigné dans le `.env` de l'app).

> ⚠️ **Pourquoi `azp` et pas `aud`** — Keycloak ne place pas le `clientId` dans `aud` sans mapper
> d'audience dédié, et les backends tournent en `verify_aud: False`. Le realm expose par ailleurs
> `admin-cli` en client **public avec le password grant activé** (défaut Keycloak, non désactivable
> proprement). Sans contrôle de `azp`, n'importe quel compte du realm obtient un token via `admin-cli`
> et appelle **n'importe quelle API**, sans jamais croiser le flow. C'est le contrôle de `azp` qui
> ferme ce contournement.

### Récapitulatif

| Application | Type | Groupe(s) requis | Barrière navigateur | Serrure API |
|---|---|---|---|---|
| `app-builder` | Django + Angular | `admins` | ✅ flow | ✅ `azp` + `groups` |
| `analyse-lora` | Django + Angular | `developers` | ✅ flow | ✅ `azp` + `groups` |
| `arbre-genealogique` | Django + Angular | `famille` | ✅ flow | ✅ `azp` + `groups` |
| `restauration` | Django + Angular | `manager`, `cuisinier`, `serveur` | ✅ flow | ✅ `azp` + `groups` |
| `test-django-angular` | Django + Angular | `developers` | ✅ flow | ✅ `azp` + `groups` |
| `traitement-de-fichiers-compils` | Django + Angular | `developers` | ✅ flow | ✅ `azp` + `groups` |
| `front-cadriciel` | Angular seul | `developers` | ✅ flow | — *(pas de backend)* |
| `test-angular` | Angular seul | `developers` | ✅ flow | — *(pas de backend)* |
| **`code-server`** | oauth2-proxy | `developers`, `admins` | ✅ **oauth2-proxy** | — *(pas d'API exposée)* |

**Le cas `code-server`** est le seul qui n'utilise pas de flow Keycloak : il est protégé **en amont**
par `oauth2-proxy`, qui intercepte `/code/*`, valide la session Keycloak et refuse tout utilisateur
hors de `OAUTH2_PROXY_ALLOWED_GROUPS` (`developers,admins`, dans `sso-lab/docker-compose.yml`).
code-server tourne lui-même en `--auth=none` : **il n'a aucune protection propre**. Retirer
oauth2-proxy l'exposerait nu — avec un terminal ayant accès au Docker de l'hôte.

### Non couverts

| Élément | Situation |
|---|---|
| `admin-cli` | Client Keycloak intégré, public, password grant actif. Ne peut pas être supprimé — neutralisé par le contrôle `azp` des backends. |
| phpLDAPadmin, pgAdmin | Non exposés via Caddy (LAN uniquement). |

### Restreindre une application

Tout passe par `--require-group` dans `<app>/.keycloak-client-opts` (liste séparée par des virgules) :

```bash
# <app>/.keycloak-client-opts
--public --port 4208 --caddy-path mon-app --require-group famille,amis
```

`create-app-client.sh` s'occupe du reste, de façon idempotente : rôle `<client>-access` assigné à
chaque groupe, flow `require-<client>` créé et lié au client, et `KEYCLOAK_REQUIRED_GROUPS` écrit
dans le `.env` de l'app pour armer la serrure backend.

> ⚠️ **Un nouvel inscrit n'appartient à aucun groupe** : il n'a donc accès à **aucune** application
> tant qu'on ne l'a pas ajouté à un groupe LDAP.

---

## Utilisateurs LDAP

| Utilisateur | Groupes | code-server |
|---|---|---|
| sacha | developers, admins, famille, amis | ✓ |
| hassan | developers, amis | ✓ |
| lea | famille, amis | ✗ |
| elodie | famille | ✗ |

> pgAdmin est restreint au groupe **developers** via OAuth2.

---

## Réseaux Docker

| Réseau | Utilisé par |
|---|---|
| `sso-lab_sso-net` | Keycloak, LDAP, Caddy, oauth2-proxy, code-server, toutes les apps |
| `dev-net` | PostgreSQL, pgAdmin, backends Django/Spring |

---

## Créer une nouvelle application — méthode standard

### Étape 1 — Scaffold

```bash
bash scripts/new-app.sh
```

Le script demande interactivement : nom, type (Spring / Django / Angular), ports. Il crée le dossier complet avec backend, frontend, docker-compose, Dockerfiles, nginx, `.env`…

Pour une saisie non-interactive :
```bash
printf 'mon-app\n4\n8089\n4207\nO\n' | bash scripts/new-app.sh
# Types : 1=Spring  2=Spring+Angular  3=Django  4=Django+Angular  5=Angular
```

### Étape 2 — Dépôt GitHub + sous-module

```bash
cd mon-app
git init && git checkout -b main
git add . && git commit -m "feat: initial scaffold"
gh repo create Sacha37420/mon-app --public
git remote add origin https://github.com/Sacha37420/mon-app.git
git push -u origin main
cd ..
sed -i '/^mon-app\/$/d' .gitignore
git submodule add https://github.com/Sacha37420/mon-app.git mon-app
```

### Étape 3 — Remplir `.env`

```bash
nano mon-app/.env
# Champs minimaux : SECRET_KEY, DEBUG=True, DOMAIN=CHANGE_ME
```

### Étape 4 — Déploiement complet

```bash
bash scripts/setup2.sh mon-app --yes
```

`setup2.sh` enchaîne dans l'ordre :
1. `clean2.sh <app>` — arrête et supprime les containers
2. `reset_url.sh` — propage LAN/WAN/Keycloak dans tous les `.env`
3. Démarrage de **sso-lab** (si nécessaire)
4. Attente Keycloak (jusqu'à 300 s)
5. `create-app-client.sh <app>` — crée le client Keycloak (secret, redirect URIs, claim `groups`)
6. `recompose_docker.sh --app <app> --force` — build et démarre les containers
7. `get-ports-list.sh` — régénère `ports.env`
8. `open-bbox-ports2.sh` — ouvre les ports sur le routeur Bbox

> **Les groupes métier Keycloak** (ex: `manager`, `cuisinier`) ne sont pas créés par `setup2.sh` — c'est une étape manuelle après déploiement si l'app en a besoin.

> **Le schéma PostgreSQL** est ajouté automatiquement dans `infra/init/00_schemas.sql` par `new-app.sh`. Si la base existait déjà, créer le schéma manuellement :
> ```bash
> docker exec dev-postgres psql -U devuser -d devdb \
>   -c "CREATE SCHEMA IF NOT EXISTS mon_app; GRANT ALL ON SCHEMA mon_app TO devuser;"
> docker exec mon-app-backend python3 manage.py migrate
> ```

---

## Créer une application — méthode IA avancée (app-builder + cadriciel)

Pour des applications plus complexes, le lab intègre un workflow de conception assistée par IA :

### Vue d'ensemble

```
app-builder  →  front-cadriciel  →  code-server (Claude Code)  →  new-app.sh
(specs)          (prompts)           (construction)                 (scaffold)
```

### Étape 1 — Concevoir les specs dans app-builder

**app-builder** (`https://LAN_IP:4205`) est un éditeur visuel de spécifications d'application. Pour chaque app (`AppSpec`), on y définit :

- **Modèles de données** (`DataModel`) — entités métier, champs, types, relations (FK, M2M)
- **Groupes d'endpoints** (`EndpointGroup` / `Endpoint`) — API REST : méthode, path, opération CRUD, rôles requis, schémas requête/réponse
- **Services frontend** (`FrontendService`) — services Angular qui consomment les endpoints
- **Pages** (`Page`) — routes, layout (liste / détail / formulaire / dashboard), composants
- **Interactions** — clics, formulaires, navigation, affichage
- **Pipelines de données** — enchaînements d'appels service → transformation → mise à jour d'état

### Étape 2 — Générer les prompts dans front-cadriciel

**front-cadriciel** (`https://DOMAIN/cadriciel/`) est le tableau de bord central du lab. Sa page **"Prompts de déploiement"** lit les specs de app-builder et génère des **prompts Claude Code** prêts à l'emploi, couvrant :

- Le scaffold initial via `new-app.sh`
- L'implémentation Django (models, serializers, views, permissions)
- L'implémentation Angular (services, composants, routing, guards)
- La configuration Keycloak (groupes, rôles)

### Étape 3 — Construire l'app depuis code-server

Ouvrir **code-server** (`https://DOMAIN/code/`), coller le prompt généré dans Claude Code et laisser l'IA construire l'application. Les scripts `new-app.sh` et `setup2.sh` sont directement exécutables depuis le terminal intégré (Docker de l'hôte monté).

---

## Opérations courantes

### Rebuilder une app

```bash
bash scripts/setup2.sh mon-app --yes
```

### Rebuilder uniquement les containers (sans recréer le client Keycloak)

```bash
bash scripts/recompose_docker.sh --app mon-app --force
```

### Recréer le client Keycloak seul

```bash
bash scripts/create-app-client.sh mon-app $(cat mon-app/.keycloak-client-opts)
```

### Changer l'IP du serveur

```bash
# 1. Éditer bbox.env → SERVER_URL_LAN / SERVER_URL_WAN
nano bbox.env
# 2. Propager vers tous les .env et redémarrer
bash scripts/reset_url.sh && bash scripts/recompose_docker.sh --force
```

### Arrêter une app

```bash
bash scripts/clean2.sh mon-app
```

---

## Scripts utiles

Les scripts d'orchestration vivent dans **`scripts/`** — les lancer avec `bash scripts/<nom>`
depuis la racine `dev/` (ils résolvent eux-mêmes la racine, donc le répertoire courant importe peu).
Les scripts internes à un service (ex: `sso-lab/`, `infra/`) restent dans leur dossier.

| Script | Rôle |
|---|---|
| `new-app.sh` | Scaffold interactif d'une nouvelle app |
| `setup2.sh <app> --yes` | Déploiement complet (clean → Keycloak → Docker → ports) |
| `create-app-client.sh <app>` | Créer/mettre à jour le client Keycloak seul |
| `recompose_docker.sh --app <app>` | Rebuilder et redémarrer les containers |
| `clean2.sh <app>` | Arrêter et supprimer les containers d'une app |
| `reset_url.sh` | Propager LAN/WAN/Keycloak dans tous les `.env` |
| `get-ports-list.sh` | Régénérer `ports.env` depuis `.ports` |
| `open-bbox-ports2.sh` | Ouvrir les ports sur le routeur Bbox |
| `init-secrets.sh` | Générer des mots de passe forts |
| `sso-lab/setup-code-server-auth.sh` | Créer le client Keycloak pour code-server |

---

## Secrets et fichiers `.env`

Tous les `.env` sont ignorés par git. Chaque dossier contient un `.env.example` à copier :

```bash
cp sso-lab/.env.example   sso-lab/.env
cp infra/.env.example     infra/.env
cp mon-app/.env.example   mon-app/.env
cp bbox.env.example       bbox.env
```

`infra/init/00_schemas.sql` est la source de vérité pour les schémas PostgreSQL — `new-app.sh` y ajoute automatiquement la ligne `CREATE SCHEMA` de chaque nouvelle app.

---

## Dépôts Git

| Dépôt | Contenu | Type |
|---|---|---|
| [sso-lab](https://github.com/Sacha37420/sso-lab) | Infra + scripts (dépôt parent) | — |
| [app-builder](https://github.com/Sacha37420/app-builder) | Éditeur de specs d'apps | Django + Angular |
| [front-cadriciel](https://github.com/Sacha37420/front-cadriciel) | Tableau de bord lab | Angular |
| [analyse-lora](https://github.com/Sacha37420/analyse-lora) | Analyse LoRa | Django + Angular |
| [spring-app](https://github.com/Sacha37420/spring-app) | Exemple Spring Boot | Spring Boot |
| [table-manager](https://github.com/Sacha37420/table-manager) | Gestionnaire de tables | — |

Mettre à jour les pointeurs de sous-modules :
```bash
git submodule update --remote --merge
```

---

## Structure du dossier

```
dev/
├── README.md
├── .gitignore              ← ignore tous les .env et .debug/
├── .ports                  ← registre des ports (géré par new-app.sh)
├── bbox.env                ← source de vérité réseau (non commité)
├── bbox.env.example
├── infra/                  ← PostgreSQL + pgAdmin  [restart: always]
│   ├── docker-compose.yml
│   ├── .env                ← credentials (non commité)
│   └── init/
│       ├── 00_schemas.sql      ← CREATE SCHEMA par app  ← MODIFIER ICI
│       └── 01_pg_hba_trust.sh
├── sso-lab/                ← Keycloak + OpenLDAP + Caddy + code-server
│   ├── docker-compose.yml
│   ├── .env                ← credentials (non commité)
│   ├── code-server/        ← Dockerfile code-server
│   ├── ldap/
│   │   └── init.ldif           ← utilisateurs et groupes LDAP
│   └── caddy/
│       └── Caddyfile
├── _templates/             ← templates copiés par new-app.sh
│   └── django-angular/
│       ├── backend/            ← Django + auth Keycloak JWT + drf-spectacular
│       └── frontend/           ← Angular + Keycloak + auth guard + interceptor
└── <app>/                  ← nouvelle app (même modèle)
    ├── .env                ← secrets (non commité)
    ├── .env.example        ← template (commité)
    ├── docker-compose.yml
    ├── backend/
    └── frontend/
```

---

## Démarrage des infrastructures

`infra/` et `sso-lab/` utilisent `restart: always` : une fois démarrés, ils redémarrent automatiquement avec Docker.

```bash
# Premier lancement (ou après un reset complet)
bash scripts/setup2.sh --yes   # démarre tout le lab
```

Ensuite on ne manipule plus que les applications individuelles :

```bash
bash scripts/setup2.sh mon-app --yes    # déployer une app
bash scripts/clean2.sh mon-app          # arrêter une app
```

> **Journal de bugs** : les incidents rencontrés et leurs corrections sont documentés dans `.debug/` (ignoré par git).
