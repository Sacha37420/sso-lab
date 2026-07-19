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
├── analyse-lora/                    ← Django + Angular  [submodule]
├── app-builder/                     ← Django + Angular  [submodule] — éditeur de specs d'apps
├── arbre-genealogique/              ← Django + Angular  [submodule]
├── carto-lab/                       ← Django + Angular  [submodule] — SIG (instance PostGIS dédiée)
├── lab-admin/                       ← Django + Angular  [submodule] — portail du lab (admin, déploiement, utilisateurs)
├── restauration/                    ← Django + Angular  [submodule]
├── traitement-de-fichiers-compils/  ← Django + Angular  [submodule]
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
| lab-admin | 8083 | `https://DOMAIN/lab-admin-api/` | 4201 | `https://DOMAIN/lab-admin/` |
| analyse-lora | 8086 | `https://DOMAIN/lora-api/` | 4204 | `https://DOMAIN/lora/` |
| app-builder | 8087 | `https://DOMAIN/app-builder-api/` | 4205 | `https://DOMAIN/app-builder/` |
| restauration | 8088 | `https://DOMAIN/restauration-api/` | 4206 | `https://DOMAIN/restauration/` |
| traitement-de-fichiers-compils | 8089 | `https://DOMAIN/traitement-de-fichiers-compils-api/` | 4207 | `https://DOMAIN/traitement-de-fichiers-compils/` |
| arbre-genealogique | 8090 | `https://DOMAIN/arbre-genealogique-api/` | 4208 | `https://DOMAIN/arbre-genealogique/` |
| carto-lab | 8091 | `https://DOMAIN/carto-lab-api/` | 4209 | `https://DOMAIN/carto-lab/` |

---

## Accès

**Caddy** (dans `sso-lab`) sert de reverse proxy HTTPS avec certificats Let's Encrypt automatiques.

| Chemin | Service |
|---|---|
| `https://DOMAIN/auth/` | Keycloak (realm ssolab) |
| `https://DOMAIN/code/` | code-server (VS Code navigateur) — restreint aux groupes `developers` et `admins` |
| `https://DOMAIN/lab-admin/` | lab-admin (portail du lab : admin, déploiement, utilisateurs) |

`code-server` est protégé par **oauth2-proxy** : seuls les utilisateurs authentifiés Keycloak appartenant aux groupes `developers` ou `admins` y ont accès. Docker de l'hôte est accessible depuis son terminal.

---

## Caddy & HTTPS

Caddy (dans `sso-lab`) **n'est pas configuré à la main** via un `Caddyfile` classique. Le fichier
`sso-lab/caddy/Caddyfile` ne contient que la config globale (email ACME) :

```
{
	email {$ACME_EMAIL}
}
```

Le routage réel vient de [**caddy-docker-proxy**](https://github.com/lucaslorentz/caddy-docker-proxy)
(image `lucaslorentz/caddy-docker-proxy`, service `caddy` dans `sso-lab/docker-compose.yml`) :
chaque container porte des labels Docker que Caddy découvre dynamiquement via le socket Docker
monté en lecture seule. Exemple (Keycloak) :

```yaml
labels:
  caddy: "${DOMAIN}"
  caddy.handle_path: "/auth/*"
  caddy.handle_path.reverse_proxy: "{{upstreams 8080}}"
```

`new-app.sh` génère automatiquement ces labels pour toute nouvelle app (chemin `/<app>/` pour le
frontend, `/<app>-api/` pour le backend) — **il n'y a jamais rien à éditer dans Caddy à la main**
pour une app créée via le scaffold standard.

Un service `fallback` (label `caddy.handle: "/*"`) capte tout ce qu'aucun préfixe d'app ne
matche. Il doit rester un label et non un bloc écrit dans `Caddyfile` : caddy-docker-proxy ne
fusionne pas les deux sources pour un même domaine, il les concatène — Caddy rejette alors le
domaine en double (« ambiguous site definition ») et les routes de **toutes** les apps
disparaissent.

### Activation

HTTPS ne s'active qu'en renseignant `DOMAIN` (un nom de domaine, pas une IP) dans `.env` **et**
`sso-lab/.env` — les deux valeurs doivent être identiques. Tant que `DOMAIN=CHANGE_ME`, tout reste
en HTTP avec accès direct par port.

Les certificats Let's Encrypt sont obtenus automatiquement par Caddy via challenge HTTP-01 : le
port 80 doit être joignable depuis Internet (redirection NAT vers le port 80 de l'hôte).

### Effet sur l'ouverture des ports (Bbox)

`open-bbox-ports2.sh` (appelé par `setup2.sh`) regarde `DOMAIN` :

| Mode | Ports ouverts sur la Bbox |
|---|---|
| HTTP (`DOMAIN=CHANGE_ME`) | Tous les `PORT_*` de `ports.env` — un par service/app, accès direct |
| HTTPS (`DOMAIN` configuré) | Seulement **80** (challenge ACME + redirect) et **443** — Caddy route en interne vers chaque app par chemin, les ports individuels ne sont plus exposés sur Internet |

C'est une réduction volontaire de la surface exposée, pas un bug : en HTTPS,
`https://DOMAIN/lab-admin/` par exemple passe entièrement par Caddy sur le port 443 ; le port 4201
du container reste interne au réseau Docker `sso-net`.

---

## Nom de domaine (DDNS)

Le lab n'automatise **aucune** partie du nommage DNS — c'est entièrement à la charge de
l'opérateur, en dehors de ce dépôt :

1. **Obtenir un nom de domaine** pointant vers l'IP WAN du serveur. Un service DDNS gratuit
   convient (No-IP, DuckDNS…) puisque l'IP WAN d'une connexion résidentielle change.
2. **Maintenir ce nom à jour** avec l'IP WAN courante : soit via le client officiel du
   fournisseur (ex. No-IP DUC), soit via le client DynDNS intégré du routeur s'il en propose un.
   Aucun script de ce dépôt ne fait cette mise à jour — `reset_url.sh` et `bbox.env` ne font que
   *lire* l'IP WAN courante pour configurer les services locaux ; ils ne la poussent jamais vers
   un fournisseur DNS.
3. Une fois le domaine actif, le renseigner dans `.env` et `sso-lab/.env` (`DOMAIN=`) — voir
   [Caddy & HTTPS](#caddy--https) ci-dessus.

> **Vérification rapide** : `reset_url.sh` compare l'IP WAN détectée (`api.ipify.org`) à celle
> configurée dans `bbox.env`. Un écart signalé peut venir d'un client DDNS arrêté ou d'un
> changement pas encore propagé (TTL DNS).

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
| `analyse-lora` | Django + Angular | `developers` | ✅ flow | ✅ `azp` + `groups` |
| `app-builder` | Django + Angular | tous les groupes du lab (accès volontairement ouvert à tout utilisateur) | ✅ flow | ✅ `azp` + `groups` |
| `arbre-genealogique` | Django + Angular | `famille` | ✅ flow | ✅ `azp` + `groups` |
| `carto-lab` | Django + Angular | `developers` | ✅ flow | ✅ `azp` + `groups` |
| `lab-admin` | Django + Angular | `admins` | ✅ flow | ✅ `azp` + `groups` |
| `restauration` | Django + Angular | `manager`, `cuisinier`, `serveur` | ✅ flow | ✅ `azp` + `groups` |
| `traitement-de-fichiers-compils` | Django + Angular | `developers` | ✅ flow | ✅ `azp` + `groups` |
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
| sacha | developers, admins, famille, amis, manager, cuisinier, serveur | ✓ |
| hassan | developers, amis | ✓ |
| lea | famille, amis | ✗ |
| elodie | famille, manager | ✗ |
| sabrina | manager | ✗ |
| bruno | — | ✗ |

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

## Créer une application — méthode IA avancée (app-builder + lab-admin)

Pour des applications plus complexes, le lab intègre un workflow de conception assistée par IA :

### Vue d'ensemble

```
app-builder  →  lab-admin  →  code-server (Claude Code)  →  new-app.sh
(specs)          (prompts)     (construction)                 (scaffold)
```

### Étape 1 — Concevoir les specs dans app-builder

**app-builder** (`https://LAN_IP:4205`) est un éditeur visuel de spécifications d'application. Pour chaque app (`AppSpec`), on y définit :

- **Modèles de données** (`DataModel`) — entités métier, champs, types, relations (FK, M2M)
- **Groupes d'endpoints** (`EndpointGroup` / `Endpoint`) — API REST : méthode, path, opération CRUD, rôles requis, schémas requête/réponse
- **Services frontend** (`FrontendService`) — services Angular qui consomment les endpoints
- **Pages** (`Page`) — routes, layout (liste / détail / formulaire / dashboard), composants
- **Interactions** — clics, formulaires, navigation, affichage
- **Pipelines de données** — enchaînements d'appels service → transformation → mise à jour d'état

### Étape 2 — Générer les prompts dans lab-admin

**lab-admin** (`https://DOMAIN/lab-admin/`) est le portail central du lab. Sa page **"Prompts de déploiement"** lit les specs de app-builder et génère des **prompts Claude Code** prêts à l'emploi, couvrant :

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

## Rotation des secrets

Trois niveaux, du plus ciblé au plus large. Tous appliquent le nouveau secret **à chaud** sur
les services en cours — aucun n'exige de wipe de volume.

### Ciblée — `setup2.sh --rotate-secrets`

```bash
bash scripts/setup2.sh mon-app --rotate-secrets --yes   # une app : son SECRET_KEY
bash scripts/setup2.sh --rotate-secrets --yes            # tout le lab : SECRET_KEY de
                                                            # chaque app + mot de passe
                                                            # PostgreSQL partagé
```

> ⚠ La variante « tout le lab » (sans nom d'app) arrête d'abord l'infra (`clean2.sh`, volumes
> préservés) avant de la roter — si l'infra n'est pas relancée entre les deux, la rotation échoue
> avec `Conteneur 'dev-postgres' non démarré`. Relancer alors `bash scripts/recompose_docker.sh
> --app infra` puis reprendre `setup2.sh --rotate-secrets --yes`.

### Admin sso-lab seul — `rotate-secrets.sh`

Rote `LDAP_ADMIN_PASSWORD`, `KEYCLOAK_ADMIN_PASSWORD` et `LDAP_CONFIG_PASSWORD`, à chaud, sans
toucher aux comptes LDAP des utilisateurs :

```bash
bash scripts/rotate-secrets.sh --yes
bash scripts/rotate-secrets.sh --yes --only=keycloak-admin   # un seul des trois
```

### Complète — `rotate-secrets-full.sh`

Roule tout ce qui est automatisable : mot de passe PostgreSQL, `SECRET_KEY` et
`KEYCLOAK_CLIENT_SECRET` de chaque app, secrets admin de sso-lab, secrets code-server
(cookie oauth2-proxy + client Keycloak), **et le mot de passe de chaque compte LDAP** — puis
redémarre tous les services pour que chaque backend relise son `.env`.

```bash
bash scripts/rotate-secrets-full.sh --yes
bash scripts/rotate-secrets-full.sh --yes --keep-password carpeta,naty   # exclure des comptes
```

À utiliser sur suspicion de fuite large, ou par précaution périodique. Effets de bord assumés :
**toutes** les sessions, sur **toutes** les apps, sont invalidées, et **chaque utilisateur LDAP
ayant une adresse email réelle (pas `uid@ssolab.local`) reçoit automatiquement son nouveau mot
de passe par email**, via le SMTP déjà configuré pour Keycloak dans `sso-lab/.env` — le même
compte que celui utilisé pour le flow « mot de passe oublié ». L'envoi est *best-effort* : SMTP
non configuré, adresse factice ou échec d'envoi n'annulent jamais la rotation — le mot de passe
reste de toute façon écrit dans `sso-lab/.env` et affiché dans le terminal.

Le mot de passe de chaque compte LDAP peut aussi être roté seul, avec la même notification par
email :

```bash
bash scripts/rotate-ldap-user-passwords.sh --yes
```

**Non couverts, à roter manuellement** (aucun des trois niveaux ci-dessus n'y touche) :

| Secret | Pourquoi pas automatisé |
|---|---|
| `BBOX_ADMIN_PASSWORD` | Scripter le changement du mot de passe admin du routeur risquerait de verrouiller son propre accès admin en cas d'échec — pas de filet de rattrapage possible sans accès physique. À changer dans l'interface web de la Bbox. |
| `SMTP_PASSWORD` | Mot de passe d'application Gmail — nécessite une action interactive côté compte Google (Sécurité → Mots de passe d'application), non automatisable par script. |

### Pourquoi pas `setup2.sh` comme étape finale de `rotate-secrets-full.sh`

`setup2.sh` (sans `--rotate-secrets`) régénère quand même `sso-lab/.env` via `init-secrets.sh` dès
qu'il tourne sur tout le lab — avec de **nouvelles** valeurs `KEYCLOAK_ADMIN_PASSWORD`/`LDAP_*`
jamais appliquées aux services (elles ne prennent effet qu'après un wipe de volume). Appeler
`setup2.sh` après une rotation à chaud désynchroniserait donc `sso-lab/.env` des secrets
réellement actifs. `rotate-secrets-full.sh` rappelle directement les scripts unitaires puis
termine par un simple `recompose_docker.sh --force`.

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
| `sso-lab/setup-code-server-auth.sh` | Créer le client Keycloak pour code-server (`--rotate` pour forcer la rotation) |
| `rotate-secrets-full.sh --yes` | Rotation complète de tous les secrets automatisables, avec redémarrage (voir [Rotation des secrets](#rotation-des-secrets)) |
| `rotate-ldap-user-passwords.sh --yes` | Rotation à chaud du mot de passe de chaque compte LDAP, avec email au titulaire |
| `rotate-secrets.sh --yes` | Rotation à chaud des secrets admin sso-lab (LDAP admin/config, Keycloak admin) |
| `rotate-db-password.sh --yes` | Rotation à chaud du mot de passe PostgreSQL partagé |
| `rotate-app-secret.sh <app>` | Régénère le `SECRET_KEY` Django d'une app |
| `notify-password-email.sh <uid> <email> <mdp>` | Envoie un mot de passe par email via le SMTP de sso-lab (best-effort) |

---

## Secrets et fichiers `.env`

Tous les `.env` sont ignorés par git. Chaque dossier contient un `.env.example` à copier :

```bash
cp .env.example            .env            # racine — DOMAIN, ACME_EMAIL, SERVER_URL_*
cp sso-lab/.env.example    sso-lab/.env
cp infra/.env.example      infra/.env
cp mon-app/.env.example    mon-app/.env
cp bbox.env.example        bbox.env
```

> Le `.env` racine et `sso-lab/.env` doivent porter le **même** `DOMAIN`/`ACME_EMAIL` — voir
> [Caddy & HTTPS](#caddy--https). Laisser `DOMAIN=CHANGE_ME` dans les deux pour rester en HTTP.

`infra/init/00_schemas.sql` est la source de vérité pour les schémas PostgreSQL — `new-app.sh` y ajoute automatiquement la ligne `CREATE SCHEMA` de chaque nouvelle app.

---

## Dépôts Git

| Dépôt | Contenu | Type |
|---|---|---|
| [sso-lab](https://github.com/Sacha37420/sso-lab) | Infra + scripts (dépôt parent) | — |
| [lab-admin](https://github.com/Sacha37420/lab-admin) | Portail du lab (admin, déploiement, utilisateurs) | Django + Angular |
| [app-builder](https://github.com/Sacha37420/app-builder) | Éditeur de specs d'apps | Django + Angular |
| [analyse-lora](https://github.com/Sacha37420/analyse-lora) | Analyse LoRa | Django + Angular |
| [arbre-genealogique](https://github.com/Sacha37420/arbre-genealogique) | Arbre généalogique | Django + Angular |
| [carto-lab](https://github.com/Sacha37420/carto-lab) | Traitement cartographique (SIG) | Django + Angular |
| [restauration](https://github.com/Sacha37420/restauration) | Gestion de restaurant | Django + Angular |
| [traitement-de-fichiers-compils](https://github.com/Sacha37420/traitement-de-fichiers-compils) | Dépôt de fichiers | Django + Angular |

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
├── .env                    ← DOMAIN, ACME_EMAIL, SERVER_URL_* (non commité)
├── .env.example
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

> **Avant le tout premier lancement** : copier les `.env.example` (voir
> [Secrets et fichiers .env](#secrets-et-fichiers-env)) et lancer `reset_url.sh`. `DOMAIN` peut
> rester à `CHANGE_ME` pour démarrer en HTTP — voir [Caddy & HTTPS](#caddy--https) pour activer
> HTTPS ensuite.

```bash
# Premier lancement (ou après un reset complet)
bash scripts/reset_url.sh      # propage bbox.env/.env vers tous les .env
bash scripts/setup2.sh --yes   # démarre tout le lab
```

Ensuite on ne manipule plus que les applications individuelles :

```bash
bash scripts/setup2.sh mon-app --yes    # déployer une app
bash scripts/clean2.sh mon-app          # arrêter une app
```

> **Journal de bugs** : les incidents rencontrés et leurs corrections sont documentés dans `.debug/` (ignoré par git).
