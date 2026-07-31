# dev/ — Lab SSO multi-applications

Plateforme d'apprentissage et de développement autour de **Keycloak**, **OpenLDAP**,
**PostgreSQL/PostGIS** et **Caddy**, hébergeant onze applications Django + Angular (+ une
Spring Boot possible) authentifiées via OIDC, plus un service de stockage de fichiers partagé
et un runner Playwright pour les tests de cloisonnement.

Les applications sont des **sous-modules git** autonomes, chacune dans son propre dépôt
GitHub. Les scripts du dépôt parent (`scripts/`) gèrent leur cycle de vie complet : scaffold,
client Keycloak, build Docker, ports réseau, rotation des secrets.

> Documentation complémentaire : `CLAUDE.md` (racine) est le guide de travail détaillé destiné
> aux agents IA qui interviennent sur ce dépôt — il contient le détail fichier par fichier de
> chaque migration/décision. Ce README est le point d'entrée humain : architecture, procédures
> de démarrage, règles à respecter pour créer ou modifier une app.

---

## Sommaire

1. [Procédure de construction de l'infrastructure](#1--procédure-de-construction-de-linfrastructure)
   - [1.1 Ce qui est inclus dans `dev/`, ce qui ne l'est pas](#11-ce-qui-est-inclus-dans-dev-ce-qui-ne-lest-pas)
   - [1.2 Démarrage en local](#12-démarrage-en-local)
   - [1.3 Exposition sur le WAN](#13-exposition-sur-le-wan)
   - [1.4 HTTPS via Caddy + nom de domaine (DDNS)](#14-https-via-caddy--nom-de-domaine-ddns)
   - [1.5 Plusieurs cadriciels sur une même IP WAN — le répartiteur](#15-plusieurs-cadriciels-sur-une-même-ip-wan--le-répartiteur)
2. [Créer une nouvelle application](#2--créer-une-nouvelle-application)
   - [2.1 La méthode standard](#21-la-méthode-standard)
   - [2.2 Règles d'infrastructure et de sécurité](#22-règles-dinfrastructure-et-de-sécurité)
   - [2.3 Règles `.env` et rotation des secrets](#23-règles-env-et-rotation-des-secrets)
   - [2.4 Règles UI — identité « Foyer »](#24-règles-ui--identité--foyer-)
   - [2.5 Sous-modules existants et comment les utiliser](#25-sous-modules-existants-et-comment-les-utiliser)
3. [Gestion des fichiers](#3--gestion-des-fichiers)
4. [Gestion des bases de données](#4--gestion-des-bases-de-données)
5. [Annexes](#5--annexes)

---

## Architecture d'ensemble

```
dev/
├── sso-lab/            ← Keycloak 22 + OpenLDAP + phpLDAPadmin + Caddy + oauth2-proxy + code-server
├── infra/              ← PostgreSQL 16 (devdb) + PostGIS 16-3.5 (gisdb) + pgAdmin 8
├── runner/              ← Playwright + Chromium partagé (tests de cloisonnement E2E)
├── _templates/          ← templates Django+Angular / Django seul / Angular seul
├── analyse-lora/                    ← Django + Angular  [sous-module]
├── app-builder/                     ← Django + Angular  [sous-module] — éditeur de specs d'apps
├── arbre-genealogique/              ← Django + Angular  [sous-module]
├── atelier-3d/                      ← Django + Angular  [sous-module] — reconstruction 3D
├── carto-lab/                       ← Django + Angular  [sous-module] — SIG (instance PostGIS dédiée)
├── conciergerie/                    ← Django + Angular  [sous-module] — gestion locative
├── lab-admin/                       ← Django + Angular  [sous-module] — portail du lab
├── restauration/                    ← Django + Angular  [sous-module]
├── robot-lab/                       ← Django + Angular + engine Playwright [sous-module]
├── storage/                         ← Django + Angular  [sous-module] — stockage fichiers du lab
├── traitement-de-fichiers-compils/  ← Django + Angular  [sous-module]
├── scripts/             ← tous les scripts d'orchestration (new-app.sh, setup2.sh…)
├── .ports / .app-descriptions ← registres (ports, vitrine publique)
└── bbox.env             ← source de vérité réseau (LAN/WAN)
```

Hors de ce dépôt, sur le même hôte (voir [1.1](#11-ce-qui-est-inclus-dans-dev-ce-qui-ne-lest-pas)
pour le détail) :

```
~/
├── dev/           ← ce dépôt (« lab1 »)
├── dev2/          ← second cadriciel indépendant (« lab2 »), copie isolée de dev/
└── edge-router/    ← répartiteur nginx partagé entre dev/ et dev2/, non versionné
```

---

## 1 — Procédure de construction de l'infrastructure

### 1.1 Ce qui est inclus dans `dev/`, ce qui ne l'est pas

**Inclus et versionné dans ce dépôt (ou ses sous-modules)** :
- `sso-lab/` : Keycloak, OpenLDAP, phpLDAPadmin, Caddy (reverse-proxy), oauth2-proxy,
  code-server.
- `infra/` : les deux instances PostgreSQL (`postgres`/`devdb` et `postgis`/`gisdb`), pgAdmin.
- `runner/` : conteneur Playwright partagé pour les tests de cloisonnement E2E.
- `_templates/` : templates de scaffold (Django+Angular, Django seul, Angular seul).
- Les onze applications, en tant que sous-modules git pointant vers leurs propres dépôts.
- Tous les scripts d'orchestration (`scripts/`).

**Explicitement hors de ce dépôt, non versionné, à la charge de l'opérateur** :
- **Le nom de domaine et le DDNS** (No-IP, DuckDNS, client du routeur…) — voir
  [1.4](#14-https-via-caddy--nom-de-domaine-ddns).
- **Le routeur physique** (Bbox Bouygues) et son interface d'administration — les scripts ne
  font qu'appeler son API REST pour ouvrir des ports, jamais configurer le WAN/DDNS lui-même.
- **`~/edge-router/`** — le répartiteur partagé entre plusieurs cadriciels (`dev/`, `dev2/`).
  Il vit en dehors de tout dépôt git, sur l'hôte. Voir [1.5](#15-plusieurs-cadriciels-sur-une-même-ip-wan--le-répartiteur).
  ⚠️ Il n'est donc reconstructible depuis aucun `git clone` — sa config (`docker-compose.yml`
  + `nginx.conf`) doit être sauvegardée manuellement si elle change.
- **`dev2/`** — un second cadriciel complet, structurellement identique à `dev/` (mêmes
  scripts, mêmes mécanismes) mais avec son propre domaine, son propre realm Keycloak/LDAP,
  ses propres apps (non sous-modules, dépôt git local uniquement). Totalement isolé de `dev/` :
  aucune donnée ni secret partagé, hormis l'hôte Docker et `~/edge-router/`.
- **Le serveur SMTP** (Gmail, via mot de passe d'application) utilisé par Keycloak pour
  « mot de passe oublié » et la notification de rotation de mot de passe.
- **Docker Engine + Docker Compose** eux-mêmes, et l'accès SSH/VS Code desktop à la machine.

### 1.2 Démarrage en local

Prérequis sur l'hôte : Docker Engine + plugin Compose, `git`, `gh` (CLI GitHub), `curl`.

```bash
# 1. Cloner avec tous les sous-modules
git clone --recurse-submodules https://github.com/Sacha37420/dev.git
cd dev

# 2. Copier tous les .env.example → .env
cp .env.example .env
cp bbox.env.example bbox.env
cp sso-lab/.env.example sso-lab/.env
cp infra/.env.example infra/.env
for app in analyse-lora app-builder arbre-genealogique atelier-3d carto-lab \
           conciergerie lab-admin restauration robot-lab storage \
           traitement-de-fichiers-compils; do
  cp "$app/.env.example" "$app/.env"
done

# 3. Renseigner bbox.env → SERVER_URL_LAN (IP LAN réelle de la machine)
#    Laisser SERVER_URL_WAN à CHANGE_ME pour rester purement local, ou le
#    renseigner tout de suite si le lab doit aussi être joignable depuis le
#    WAN (voir 1.3) — reset_url.sh exige une valeur non-CHANGE_ME pour WAN.
nano bbox.env

# 4. Propager les adresses réseau vers tous les .env
bash scripts/reset_url.sh

# 5. Démarrer tout le lab (infra + sso-lab, puis toutes les apps en parallèle
#    borné par scripts/app-priorities.conf — voir 2.1)
bash scripts/setup2.sh --yes
```

À l'issue de cette commande :
- Keycloak est disponible sur `http://<IP_LAN>:8080/`, phpLDAPadmin sur `:8081`, pgAdmin sur
  `:5050` (accès direct LAN uniquement pour ces deux derniers, jamais exposés via Caddy).
- Chaque app est disponible sur `http://<IP_LAN>:<port_frontend>/`.
- `infra/` et `sso-lab/` tournent en `restart: always` : ils redémarrent automatiquement avec
  Docker, pas besoin de relancer `setup2.sh` après un reboot de la machine.

Ensuite, on ne manipule plus que des apps individuelles :

```bash
bash scripts/setup2.sh mon-app --yes    # (re)déployer une app
bash scripts/clean2.sh mon-app          # l'arrêter et supprimer ses containers
```

> **DOMAIN reste à `CHANGE_ME`** à ce stade : tout tourne en HTTP, accès direct par port. C'est
> le mode par défaut et il fonctionne pour du développement pur LAN — HTTPS n'est nécessaire
> que pour une exposition WAN sérieuse (voir 1.4).

### 1.3 Exposition sur le WAN

L'exposition WAN ajoute deux choses au démarrage local : une IP publique jusqu'à la machine
(port-forwarding NAT sur le routeur) et une vérification que les identités réseau configurées
correspondent à la réalité.

```bash
# 1. Renseigner l'IP WAN publique dans bbox.env
nano bbox.env    # SERVER_URL_WAN=http://<IP_WAN>

# 2. Renseigner les identifiants d'administration du routeur (Bbox Bouygues)
nano bbox.env    # BBOX_ADMIN_PASSWORD, BBOX_URL, BBOX_IP

# 3. Propager + valider
bash scripts/reset_url.sh
```

`reset_url.sh` ne se contente pas de propager — il **valide** activement la configuration
réseau à chaque exécution :
- compare l'IP LAN détectée (table de routage) à celle déclarée dans `bbox.env` ;
- compare l'IP WAN détectée (`api.ipify.org`) à celle déclarée ;
- teste que Keycloak répond bien depuis l'extérieur sur `<IP_WAN>:<PORT_KEYCLOAK>` (donc que
  le port-forwarding NAT fonctionne).

Un écart signalé peut venir d'un DDNS pas encore à jour, d'un double NAT, ou d'un port-forwarding
manquant/mal ciblé — `reset_url.sh` explique la piste la plus probable dans son propre message.

```bash
# 4. Ouvrir les ports sur le routeur
bash scripts/open-bbox-ports2.sh
```

Ce script parle directement l'API REST de la Bbox Bouygues (`mabbox.bytel.fr`) : authentification
par mot de passe admin, obtention d'un `device token`, puis création d'une règle NAT par port —
idempotent (une règle déjà existante n'est pas recréée). **Tant que `DOMAIN=CHANGE_ME`**, il ouvre
un port par service/app (`ports.env`) : chaque app reste joignable directement par son port, en
HTTP, sur Internet. Voir 1.4 pour le comportement une fois HTTPS activé (surface radicalement
réduite).

> Ce script est spécifique à l'API Bbox Bouygues. Avec un autre routeur, ouvrir les mêmes ports
> manuellement dans son interface d'administration (ou son propre outil d'automatisation) — rien
> d'autre dans le lab ne dépend de la marque du routeur.

### 1.4 HTTPS via Caddy + nom de domaine (DDNS)

**Le lab n'automatise aucune partie du nommage DNS** — entièrement à la charge de l'opérateur,
en dehors de ce dépôt :

1. **Obtenir un nom de domaine** pointant vers l'IP WAN du serveur. Un service DDNS gratuit
   convient (No-IP, DuckDNS…), puisque l'IP WAN d'une connexion résidentielle change.
2. **Maintenir ce nom à jour** avec l'IP WAN courante : client officiel du fournisseur (ex.
   No-IP DUC) ou client DynDNS intégré du routeur. Aucun script de ce dépôt ne pousse une mise
   à jour vers un fournisseur DNS — `reset_url.sh`/`bbox.env` ne font que *lire* l'IP WAN
   courante pour configurer les services locaux.
3. Une fois le domaine actif, le renseigner dans **`.env` et `sso-lab/.env`** — les deux valeurs
   `DOMAIN`/`ACME_EMAIL` doivent être **identiques**.

```bash
nano .env            # DOMAIN=mondomaine.example.com, ACME_EMAIL=moi@example.com
nano sso-lab/.env    # mêmes valeurs
bash scripts/reset_url.sh
bash scripts/setup2.sh --yes
```

**Caddy n'est pas configuré à la main.** Le routage vient de
[caddy-docker-proxy](https://github.com/lucaslorentz/caddy-docker-proxy) : chaque container
porte des labels Docker que Caddy découvre dynamiquement via le socket Docker monté en lecture
seule. `sso-lab/caddy/Caddyfile` ne contient que la config globale (email ACME) :

```
{
	email {$ACME_EMAIL}
}
```

Exemple de labels générés automatiquement (Keycloak) :

```yaml
labels:
  caddy: "${DOMAIN}"
  caddy.handle_path: "/auth/*"
  caddy.handle_path.reverse_proxy: "{{upstreams 8080}}"
```

`new-app.sh` génère ces labels pour toute nouvelle app (chemin `/<app>/` pour le frontend,
`/<app>-api/` pour le backend) — **il n'y a jamais rien à éditer dans Caddy à la main** pour une
app créée via le scaffold standard. Un service `fallback` (label `caddy.handle: "/*"`, le moins
spécifique) capte tout ce qu'aucun préfixe n'a matché.

> ⚠️ Le catch-all `fallback` doit rester un **label**, jamais un bloc écrit dans `Caddyfile` :
> caddy-docker-proxy ne fusionne pas les deux sources pour un même domaine, il les concatène —
> Caddy rejette alors le domaine en double (« ambiguous site definition ») et **les routes de
> toutes les apps disparaissent**.

Les certificats Let's Encrypt sont obtenus automatiquement par Caddy via challenge HTTP-01 : le
port 80 doit être joignable depuis Internet.

**Effet sur l'ouverture des ports** — `open-bbox-ports2.sh` regarde `DOMAIN` :

| Mode | Ports ouverts sur le routeur |
|---|---|
| HTTP (`DOMAIN=CHANGE_ME`) | Tous les `PORT_*` de `ports.env` — un par service/app, accès direct |
| HTTPS (`DOMAIN` configuré) | Seulement **80** (ACME + redirect) et **443** — Caddy route en interne par chemin, les ports individuels ne sont plus exposés sur Internet |

C'est une réduction volontaire de la surface exposée : en HTTPS, `https://DOMAIN/lab-admin/`
passe entièrement par Caddy sur le port 443 ; le port du container reste interne au réseau
Docker `sso-net`.

### 1.5 Plusieurs cadriciels sur une même IP WAN — le répartiteur

Un routeur ne peut rediriger un port externe donné (80 ou 443) que vers **une seule** machine/
port interne. Si l'hôte fait tourner **deux cadriciels indépendants** (deux arbres type `dev/`,
chacun avec son propre Keycloak/Caddy/domaine — ex. `dev/` et `dev2/` sur cette machine), les
deux Caddy ne peuvent pas publier 80/443 chacun de leur côté : il faut un point d'entrée unique
qui aiguille selon le domaine demandé, **avant** d'atteindre l'un ou l'autre Caddy.

C'est le rôle de **`~/edge-router/`** — un répartiteur nginx minimaliste, **hors de `dev/` et de
`dev2/`, non versionné** (voir [1.1](#11-ce-qui-est-inclus-dans-dev-ce-qui-ne-lest-pas)) :

```
Internet ── 80/443 ── ~/edge-router/ (nginx) ── edge-net (réseau Docker externe)
                             │                        │
                    aiguille par SNI (443)    ┌────────┴────────┐
                    ou Host (80)              │                 │
                                          caddy (dev/)     caddy2 (dev2/)
                                          + sso-net              + sso-net2
```

**Principe** : le répartiteur ne déchiffre **jamais** le TLS — il lit le SNI (nom de domaine
demandé) dans le `ClientHello` via `ssl_preread` et relaie les octets bruts au bon Caddy, qui
continue de gérer 100 % de son propre ACME/TLS/auth/routage, exactement comme s'il recevait le
trafic directement.

`~/edge-router/docker-compose.yml` :

```yaml
version: "3.9"
name: edge-router
networks:
  edge-net:
    external: true
    name: edge-net
services:
  router:
    image: nginx:alpine
    container_name: edge-router
    restart: unless-stopped
    ports:
      - "0.0.0.0:80:80"
      - "0.0.0.0:443:443"
    volumes:
      - ./nginx.conf:/etc/nginx/nginx.conf:ro
    networks:
      - edge-net
```

`~/edge-router/nginx.conf` — un bloc `stream` (443, par SNI) et un bloc `http` (80, par en-tête
`Host`, nécessaire pour les challenges ACME HTTP-01 et les redirections HTTP→HTTPS de chaque
Caddy) :

```nginx
stream {
    resolver 127.0.0.11 valid=10s;
    map $ssl_preread_server_name $backend_https {
        default              caddy:443;
        mondomaine1.example  caddy:443;
        mondomaine2.example  caddy2:443;
    }
    server {
        listen 443;
        proxy_pass $backend_https;
        ssl_preread on;
    }
}

http {
    resolver 127.0.0.11 valid=10s;
    map $host $backend_http {
        default              caddy:80;
        mondomaine1.example  caddy:80;
        mondomaine2.example  caddy2:80;
    }
    server {
        listen 80;
        location / {
            proxy_pass http://$backend_http;
            proxy_set_header Host $host;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
        }
    }
}
```

**Côté de chaque cadriciel**, le service `caddy` de `sso-lab/docker-compose.yml` rejoint
`edge-net` en plus de `sso-net` (qu'il garde pour atteindre Keycloak/openldap/oauth2-proxy/
code-server), et **ne publie plus `ports:` lui-même** :

```yaml
networks:
  edge-net:
    external: true   # créé une fois : docker network create edge-net

services:
  caddy:
    environment:
      CADDY_INGRESS_NETWORKS: "sso-lab_sso-net"   # inchangé
    # plus de "ports: - 80:80 / 443:443" ici
    networks:
      - sso-net
      - edge-net
```

**Mise en place, dans l'ordre** :
1. Créer le réseau Docker externe partagé : `docker network create edge-net` (une seule fois,
   sur l'hôte — pas dans un `docker-compose.yml` d'app).
2. Créer `~/edge-router/` avec les deux fichiers ci-dessus, en listant dans `nginx.conf` le
   domaine réel de chaque cadriciel → nom de son container Caddy (`caddy` pour `dev/`, `caddy2`
   pour `dev2/`, etc. — le nom de container doit être unique par cadriciel, pas seulement le
   nom du service).
3. Dans `sso-lab/docker-compose.yml` de **chaque** cadriciel : retirer le bloc `ports:` du
   service `caddy`, ajouter `edge-net` à ses réseaux, `docker compose up -d`.
4. `docker compose up -d` dans `~/edge-router/`.
5. Vérifier : `docker network inspect edge-net` doit lister le container `edge-router` et
   chaque Caddy ; chaque domaine doit rester joignable en 80/443 exactement comme avant.

**Côté routeur** : un seul jeu de règles NAT, 80→80 et 443→443, vers l'hôte qui fait tourner
`edge-router` — plus besoin de forwarder un port par cadriciel. `open-bbox-ports2.sh` de chaque
cadriciel continue d'ouvrir `PORT_HTTP`/`PORT_HTTPS` sans effet sur le routage applicatif
(`edge-router` écoute déjà ces ports) — inoffensif à relancer.

**Rollback** (revenir à un seul cadriciel exposé directement) : réajouter le bloc `ports:` sur
le service `caddy` concerné et relancer `docker compose up -d` — aucune autre modification
nécessaire, `edge-net` peut rester connecté sans effet tant que `ports:` republie 80/443.

> ⚠️ **`~/edge-router/` n'est reproductible depuis aucun `git clone`.** S'il change (nouveau
> cadriciel, nouveau domaine), sauvegarder `docker-compose.yml`/`nginx.conf` manuellement en
> dehors du dépôt — ni `dev/` ni `dev2/` n'en gardent de copie versionnée. Toucher à `edge-net`
> ou aux `ports:` de n'importe quel Caddy affecte **tous** les cadriciels simultanément : à
> faire en connaissance de cause, jamais sans vérifier l'état des autres cadriciels avant.
> N'utiliser ce mécanisme que si l'hôte héberge réellement plusieurs cadriciels — un seul
> cadriciel n'a aucune raison de perdre l'exposition directe décrite en 1.3/1.4.

---

## 2 — Créer une nouvelle application

### 2.1 La méthode standard

**Étape 1 — Scaffold interactif :**

```bash
bash scripts/new-app.sh
```

Demande, dans l'ordre : nom (minuscules + tirets), type (Spring seul / Spring+Angular / Django
seul / Django+Angular / Angular seul), port backend (suggéré ≥ 8083), port frontend (suggéré
≥ 4200), scaffold via Docker (O/n), **groupe(s) LDAP requis** (cloisonnement — vide = accessible
à tout compte du realm, signalé bruyamment), et pour toute app avec base, **l'instance
PostgreSQL** (`postgres`/défaut ou `postgis` — voir [4](#4--gestion-des-bases-de-données)).

```bash
# Non-interactif — instance postgres (défaut)
printf 'mon-app\n4\n8088\n4206\nO\ndevelopers\n' | bash scripts/new-app.sh
# Non-interactif — instance postgis explicite (dernière ligne)
printf 'carto-lab\n4\n8091\n4209\nO\ndevelopers\n2\n' | bash scripts/new-app.sh
```

Le script crée `dev/<app>/` complet (backend, frontend, docker-compose, Dockerfiles, nginx,
`.env`…), ajoute `<app>/` au `.gitignore` racine, enregistre les ports dans `.ports`, ajoute le
schéma SQL dans `infra/init/00_schemas.sql` (ou `infra/init-postgis/00_schemas.sql`), et crée
`.keycloak-client-opts`. **Il ne crée ni le client Keycloak ni le dépôt GitHub.**

**Étape 2 — Dépôt GitHub + sous-module :**

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

**Étape 3 — Remplir `.env`** : voir [2.3](#23-règles-env-et-rotation-des-secrets).

**Étape 3 bis — Cloisonner l'app** (à ne pas sauter) : voir [2.2](#22-règles-dinfrastructure-et-de-sécurité).

**Étape 4 — Déploiement complet :**

```bash
bash scripts/setup2.sh mon-app --yes
```

Avec un nom d'app (et sans `--restart-sso-lab`/`--rotate-secrets`), `setup2.sh` délègue
intégralement à `scripts/setup_unit.sh`, qui enchaîne pour **cette app uniquement** :
1. `clean2.sh <app>` — arrêt + suppression des containers/volumes de l'app
2. démarrage de `sso-lab` s'il ne tourne pas déjà, attente que Keycloak réponde
3. `create-app-client.sh <app>` — client Keycloak (secret, redirect URIs, claim `groups`,
   flow `require-<app>`)
4. `ensure-schemas.sh <app>` — rattrapage à chaud du schéma Postgres si la base existait déjà
5. `recompose_docker.sh --app <app> --force` — build et démarrage des containers

`setup_unit.sh <app> --yes` reste aussi appelable seul, sans passer par `setup2.sh`, pour
redéployer une app sans toucher au reste du lab.

**`setup2.sh --yes` sans nom d'app** (tout le lab) démarre `infra`/`sso-lab` puis dispatche
`setup_unit.sh` **en parallèle** pour chaque app, borné par priorité et budget RAM
(`scripts/app-priorities.conf` — utile sur un hôte à ressources limitées : atelier-3d, la
compilation la plus longue, démarre en premier malgré son poids, pendant que les apps plus
légères tournent en parallèle). `--restart-sso-lab` et `--rotate-secrets` restent exclusivement
sur l'ancien chemin séquentiel (opérations sur l'infra partagée, pas sûres à paralléliser).

> **Les groupes métier Keycloak** (ex: `manager`, `cuisinier`) ne sont pas créés par
> `setup2.sh` — étape manuelle après déploiement, dans `sso-lab/ldap/init.ldif`, si l'app en a
> besoin (ne pas oublier d'y ajouter `e2e_member`, voir [2.2](#22-règles-dinfrastructure-et-de-sécurité)).

**Méthode IA avancée** — pour des applications plus complexes, un workflow de conception
assistée existe : **app-builder** (éditeur visuel de specs — modèles de données, endpoints,
services frontend, pages, pipelines) → **lab-admin** (page « Prompts de déploiement », génère
des prompts Claude Code prêts à l'emploi à partir des specs) → **code-server**
(`https://DOMAIN/code/`, Claude Code CLI pré-installé, Docker de l'hôte monté — coller le
prompt et laisser l'IA construire l'app en exécutant elle-même `new-app.sh`/`setup2.sh`).

### 2.2 Règles d'infrastructure et de sécurité

Le lab est **exposé sur Internet**. Être authentifié dans le realm `ssolab` **ne donne accès à
rien** : chaque app se réserve à un ou plusieurs groupes LDAP via **deux verrous
complémentaires** — aucun des deux ne suffit seul.

**Verrou 1 — Barrière navigateur (flow Keycloak).** Flow `require-<client>` lié au client via
`authenticationFlowBindingOverrides.browser`, posé automatiquement par `create-app-client.sh`
dès que `--require-group` est présent dans `<app>/.keycloak-client-opts`. Structure obligatoire
— les deux variantes évidentes sont fausses :

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

- ❌ Barrière à la racine d'une copie du flow `browser` → Keycloak compte le sous-flow
  `CONDITIONAL` non désactivé comme « required », et `REQUIRED and ALTERNATIVE at same level`
  ⇒ il ignore les alternatives : le formulaire de login disparaît, **plus personne ne peut se
  connecter**.
- ❌ Barrière dans le sous-flow `forms` → un utilisateur avec une session SSO passe par
  l'authentificateur `Cookie`, qui court-circuite `forms` : la barrière n'est jamais évaluée
  (contournement vérifié).
- ✅ Encapsuler l'authentification dans un sous-flow `REQUIRED` supprime toute `ALTERNATIVE` de
  la racine — la barrière, frère `CONDITIONAL`, est alors toujours évaluée, cookie SSO ou pas.

**Verrou 2 — Serrure API (backend).** Le flow ne voit jamais un appel direct à l'API. Tout
backend Django vérifie lui-même, dans `api/authentication.py` (le template le fait déjà) :
1. **`azp`** — le client émetteur du token doit être `settings.KEYCLOAK_CLIENT_ID` ;
2. le claim **`groups`** doit croiser `settings.KEYCLOAK_REQUIRED_GROUPS` (vide ⇒ aucun filtre).

> **Pourquoi `azp` et pas `aud`** : les backends tournent en `verify_aud: False` (Keycloak ne
> met pas le `clientId` dans `aud` sans mapper d'audience). Le realm expose par ailleurs
> `admin-cli` en client **public avec password grant** (défaut Keycloak, non désactivable
> proprement). Sans contrôle de `azp`, tout compte du realm obtient un token via `admin-cli` et
> appelle **n'importe quelle API**, sans jamais croiser le flow — un token `admin-cli` ne porte
> d'ailleurs aucun claim `groups`, donc le contrôle des groupes seul le rejetterait aussi. **Ne
> jamais retirer ces deux contrôles.**

**Restreindre une application** : tout passe par `--require-group` dans
`<app>/.keycloak-client-opts` (liste CSV) :

```
--public --port 4208 --caddy-path mon-app --require-group famille,amis
```

`create-app-client.sh` s'occupe du reste, de façon idempotente : rôle `<client>-access` assigné
à chaque groupe, flow créé et lié, `KEYCLOAK_REQUIRED_GROUPS` écrit dans le `.env` de l'app.

> ⚠️ Un nouvel inscrit n'appartient à **aucun** groupe : il n'a donc accès à **aucune** app tant
> qu'on ne l'a pas ajouté à un groupe LDAP. Une app sans `--require-group` (groupe vide) accepte
> tout compte du realm — c'est un choix explicite pour certaines apps (voir la colonne « Groupe
> requis » du tableau [2.5](#25-sous-modules-existants-et-comment-les-utiliser)), jamais un
> oubli à reproduire par défaut.

> ⚠️ Tout **nouveau groupe LDAP** créé (dans `sso-lab/ldap/init.ldif`) **doit** ajouter
> `e2e_member` comme membre. Sans ça, le test de cloisonnement E2E de toute app utilisant ce
> groupe considère `e2e_member` comme non-membre et casse en silence (faux négatif : le test
> échoue alors que le cloisonnement réel est correct).

**Cas particulier — `code-server`** : pas de flow Keycloak, protégé **en amont** par
`oauth2-proxy` (`OAUTH2_PROXY_ALLOWED_GROUPS=developers,admins`). Tourne en `--auth=none` et
n'a **aucune protection propre** — retirer oauth2-proxy l'exposerait nu, avec un terminal ayant
accès au Docker de l'hôte.

**API appelable par d'autres apps du lab — `KEYCLOAK_TRUSTED_CLIENTS`.** Le contrôle `azp`
suppose un client unique. Pour une API qui doit être appelable par d'autres apps au nom de leurs
utilisateurs (ex. `storage`, voir [3](#3--gestion-des-fichiers)), remplacer l'égalité stricte
par une liste blanche explicite dans `.env` : `KEYCLOAK_TRUSTED_CLIENTS=storage,carto-lab,...`
(défaut : uniquement le client de l'app elle-même). Toutes les apps du lab partagent le même
`DOMAIN` (seul le chemin Caddy change) → un tel appel est **same-origin**, aucun CORS à gérer,
seul `azp` bloque. Aucun changement côté Keycloak requis pour ajouter un client de confiance.

**Écriture sans utilisateur connecté — comptes de service (`KEYCLOAK_SERVICE_WRITE_SHARES`).**
Un worker asynchrone (Celery…) n'a aucun utilisateur connecté à forwarder. Créer un fichier
`<app>/.keycloak-service-account-roles` (vide si aucun rôle `realm-management` requis) fait
créer par `create-app-client.sh` un client compagnon confidentiel `<app>-admin`
(`serviceAccountsEnabled: true`, flux `client_credentials`). Côté `storage`,
`KEYCLOAK_SERVICE_WRITE_SHARES` (`client_id:partage,...`) mappe chaque client de confiance vers
le seul partage sur lequel il a un accès lecture/écriture.

**Partage lié à un groupe Keycloak (`Share.required_groups`)** — pour une app dont tout le
groupe autorisé doit lire/écrire les mêmes données (pas de cloisonnement individuel) :
`required_groups` (CSV) lie dynamiquement l'accès au(x) groupe(s) LDAP, sans liste de membres à
maintenir à la main. Hors self-service à dessein : provisionné via une commande de gestion, pas
par l'API publique.

### 2.3 Règles `.env` et rotation des secrets

Tous les `.env` sont ignorés par git. Chaque dossier contient un `.env.example` à copier (voir
[1.2](#12-démarrage-en-local) pour la liste complète). Règles à respecter :

- **`DOMAIN`/`ACME_EMAIL`** doivent être **identiques** dans `.env` (racine) et `sso-lab/.env`.
- **`HOST_DEV_ROOT`** (`.env` racine) : laisser vide dans le cas courant. À renseigner
  uniquement si ce dépôt est édité depuis un conteneur (ex. code-server) séparé de la machine
  qui héberge le démon Docker — sinon tout service montant le dépôt en lecture seule
  (`lab-admin`, `runner`) verrait un dossier **vide** côté démon, en silence.
- **Convention de nommage des identifiants de base** : une app sur l'instance `postgres`
  déclare `DB_PASSWORD` ; une app sur `postgis` déclare `POSTGIS_PASSWORD` (jamais
  `DB_PASSWORD`). C'est ce nom de clé — pas `DB_HOST` — qui fait que `reset_url.sh` sait quoi
  propager où (`upsert_env` est un no-op quand la clé cible est absente d'un `.env`, donc les
  deux jeux d'identifiants ne se marchent jamais dessus).
- **`infra/init/00_schemas.sql`** (ou `init-postgis/00_schemas.sql`) est la source de vérité
  des schémas PostgreSQL — `new-app.sh` y ajoute automatiquement la ligne `CREATE SCHEMA` de
  chaque nouvelle app.

**Rotation des secrets — trois niveaux, tous à chaud** (aucun wipe de volume) :

| Niveau | Commande | Portée |
|---|---|---|
| Ciblée | `setup2.sh <app> --rotate-secrets --yes` | `SECRET_KEY` Django d'une app |
| Ciblée (tout le lab) | `setup2.sh --rotate-secrets --yes` | `SECRET_KEY` de chaque app + mot de passe PostgreSQL partagé |
| Admin sso-lab | `rotate-secrets.sh --yes` | `LDAP_ADMIN_PASSWORD`, `KEYCLOAK_ADMIN_PASSWORD`, `LDAP_CONFIG_PASSWORD` |
| Complète | `rotate-secrets-full.sh --yes` | Tout ce qui est automatisable : mot de passe PostgreSQL, `SECRET_KEY`/`KEYCLOAK_CLIENT_SECRET` de chaque app, secrets admin sso-lab, secrets code-server, **et le mot de passe de chaque compte LDAP** (notifié par email si l'utilisateur a une adresse réelle) — puis redémarre tous les services |

```bash
bash scripts/setup2.sh mon-app --rotate-secrets --yes
bash scripts/rotate-secrets-full.sh --yes
bash scripts/rotate-secrets-full.sh --yes --keep-password carpeta,naty   # exclure des comptes
bash scripts/rotate-ldap-user-passwords.sh --yes                        # LDAP seul, même notif email
```

> ⚠️ La variante « tout le lab » de `setup2.sh --rotate-secrets` arrête d'abord l'infra
> (volumes préservés) avant de la roter — si l'infra n'est pas relancée entre les deux, la
> rotation échoue avec `Conteneur 'dev-postgres' non démarré`. Relancer alors
> `recompose_docker.sh --app infra` puis reprendre.

> ⚠️ **Ne jamais enchaîner `rotate-secrets-full.sh` avec `setup2.sh`** : `setup2.sh` sans nom
> d'app régénère `sso-lab/.env` via `init-secrets.sh` dès qu'il tourne sur tout le lab, avec de
> nouvelles valeurs `KEYCLOAK_ADMIN_PASSWORD`/`LDAP_*` jamais appliquées aux services (elles ne
> prennent effet qu'après un wipe de volume) — ce qui désynchroniserait `sso-lab/.env` des
> secrets tout juste rotés à chaud. `rotate-secrets-full.sh` termine lui-même par
> `recompose_docker.sh --force`.

**Non automatisés, à roter manuellement** :

| Secret | Pourquoi pas automatisé |
|---|---|
| `BBOX_ADMIN_PASSWORD` | Scripter ce changement risquerait de verrouiller l'accès admin du routeur en cas d'échec, sans filet de rattrapage sans accès physique. |
| `SMTP_PASSWORD` | Mot de passe d'application Gmail — nécessite une action interactive côté compte Google, non automatisable. |

### 2.4 Règles UI — identité « Foyer »

Toutes les apps du lab (et les templates de scaffold) partagent une identité visuelle et une
structure de navigation communes, baptisées **Foyer** — appliquée intégralement aux onze apps et
aux deux templates. **Toute nouvelle app créée via `new-app.sh` hérite de Foyer sans travail
supplémentaire**, puisque le pattern vit dans `_templates/`.

**Identité** : nom « Foyer », logo = monogramme « F » sur badge dégradé (coins mi-arrondis),
favicon = le badge seul. Deux polices self-hébergées (jamais de CDN Google Fonts) : **Inter**
pour toute l'UI (y compris les titres, via la graisse), **JetBrains Mono** pour code/données
tabulaires — 5 fichiers WOFF2 dans `src/assets/fonts/` de chaque app.

**Tokens de couleur** (clair + sombre, bascule auto `prefers-color-scheme` + manuelle via
`[data-theme]`, persistée en `localStorage`), en tête de `src/styles.scss` — neutres teintés
bleu (jamais de gris pur), accent bleu franc, sémantiques succès/attention/erreur indépendantes
de l'accent :

```css
:root {
  --accent: #2a6df4; --accent-deep: #1b4fc4; --accent-tint: #e8effe;
  --success: #1fa463; --warning: #d98e1e; --danger: #e14b4b;
  --bg: #f6f7fb; --card: #ffffff; --border: #e2e5ee;
  --text: #12141c; --text-mute: #5b6172; --accent-on: #ffffff;
  --font-ui: "Foyer UI", -apple-system, "Segoe UI", sans-serif;
  --font-mono: "Foyer Mono", ui-monospace, "SF Mono", monospace;
  --radius-sm: 8px; --radius-md: 12px; --radius-lg: 18px; --radius-full: 999px;
  --nav-h: 64px; --sidebar-w: 240px; --sidebar-w-collapsed: 76px;
}
@media (prefers-color-scheme: dark) { :root { /* variante sombre, mêmes tokens */ } }
```

Tous les composants stylés **via ces tokens**, jamais de couleur en dur — condition pour que le
thème sombre fonctionne partout sans reprise page par page. Cible tactile minimale **44×44px**
sur tout élément interactif, sans exception.

**Navigation — un seul principe, toujours vertical** (jamais de bascule horizontal PC → burger
mobile) :
- **Desktop (≥ 900px)** : `<aside class="sidebar">` sticky, largeur `--sidebar-w` (240px),
  **rétractable** (bouton « Réduire » → `--sidebar-w-collapsed`, 76px, icônes seules).
- **Mobile (< 900px)** : bandeau compact (`--nav-h`, 64px) + bouton menu → panneau
  `position: fixed; inset: 0` en recouvrement plein écran, liste verticale de grands boutons
  tactiles.
- Rupture fixe à **900px**, identique pour toutes les apps.
- Les **liens de navigation restent propres à chaque app** — seule la structure (sidebar +
  recouvrement) est partagée ; ne jamais copier les libellés/cibles d'une autre app.

Cahier des charges complet (composants de base, échelle typographique, checklist de
vérification par app) : `to_do_ui_foyer.md`, conservé à la racine comme référence — à consulter
avant toute évolution touchant la navigation ou les tokens visuels d'une app existante.

### 2.5 Sous-modules existants et comment les utiliser

| App | Dépôt | Ports (back/front) | Groupe(s) requis | Instance DB | Description |
|---|---|---|---|---|---|
| `lab-admin` | [Sacha37420/lab-admin](https://github.com/Sacha37420/lab-admin) | 8083 / 4201 | `admins` | postgres | Portail du lab : apps déployées, éditeur de code, création de projet, gestion des utilisateurs, catalogue de tests E2E |
| `conciergerie` | [Sacha37420/conciergerie](https://github.com/Sacha37420/conciergerie) | 8084 / 4202 | `proprietaires`, `admins` | postgres | Gestion locative : biens, frais, co-propriétaires, sync réservations, bilan de capital |
| `analyse-lora` | [Sacha37420/analyse-lora](https://github.com/Sacha37420/analyse-lora) | 8086 / 4204 | `developers` | postgres | Suivi de capteurs LoRa : relevés, mesures, droits par capteur |
| `app-builder` | [Sacha37420/app-builder](https://github.com/Sacha37420/app-builder) | 8087 / 4205 | tous les groupes (ouvert à tout compte) | postgres | Éditeur visuel de specs d'apps (modèles, endpoints, pages, pipelines) |
| `restauration` | [Sacha37420/restauration](https://github.com/Sacha37420/restauration) | 8088 / 4206 | `manager`, `cuisinier`, `serveur` | postgres | Gestion de restaurant : fournisseurs, recettes, commandes, paiements, planning, analyses de ventes |
| `traitement-de-fichiers-compils` | [Sacha37420/traitement-de-fichiers-compils](https://github.com/Sacha37420/traitement-de-fichiers-compils) | 8089 / 4207 | `developers` | postgres | Dépôt de fichiers : édition, suivi des modifications, historique |
| `arbre-genealogique` | [Sacha37420/arbre-genealogique](https://github.com/Sacha37420/arbre-genealogique) | 8090 / 4208 | *(aucun — ouvert à tout compte du realm ; autorisation par arbre via `Tree.owner_email`/`is_public`/`TreeShare`)* | postgres | Arbre généalogique : personnes, relations, périodes d'union |
| `carto-lab` | [Sacha37420/carto-lab](https://github.com/Sacha37420/carto-lab) | 8091 / 4209 | `developers` | **postgis** (dédiée) | SIG : import de cartes, systèmes de coordonnées, calculs géo, météo France |
| `storage` | [Sacha37420/storage](https://github.com/Sacha37420/storage) | 8093 / 4211 | `famille`,`amis`,`developers`,`admins`,`dom`,`harem`,`manager`,`cuisinier`,`serveur`,`proprietaires` (tous — API interne au lab) | postgres | Stockage de fichiers du lab : espaces personnels, partages par groupe, API consommée par les autres apps |
| `atelier-3d` | [Sacha37420/atelier-3d](https://github.com/Sacha37420/atelier-3d) | 8092 / 4210 | `developers`, `famille`, `amis` | postgres | Reconstruction 3D (COLMAP+OpenMVS, CPU-only), impression 3D, mouvements, sémantique de bâtiment |
| `robot-lab` | [Sacha37420/robot-lab](https://github.com/Sacha37420/robot-lab) | 8094 / 4212 (+ `engine` 8095) | `developers` | postgres | Robots de navigation web (Playwright + Claude/Mistral) : enregistrement de parcours, assistant IA, exécution + téléchargements |

**Toutes les apps sont migrées vers le stockage de fichiers partagé** (`storage`, voir
[3](#3--gestion-des-fichiers)) — plus aucune app n'a de volume média privé ni de blob de
fichier utilisateur en base (revue complète des 11 sous-modules le 2026-07-30).

**Utiliser une app existante** :
```bash
git submodule update --remote --merge      # mettre à jour tous les pointeurs de sous-module
bash scripts/setup2.sh <app> --yes         # (re)déployer
bash scripts/clean2.sh <app>               # arrêter
```
Le code de chaque app vit intégralement dans son propre dépôt GitHub — cloner/modifier depuis
`dev/<app>/` fonctionne comme n'importe quel dépôt git ; `dev/` ne fait que référencer un commit
précis via le pointeur de sous-module.

> `app-builder` et `storage` requièrent volontairement tous les groupes existants du realm,
> y compris `dom`/`harem` (aujourd'hui sans membre réel côté `dev/`, réservés pour un usage
> futur) : les masquer donnerait une vue fausse des droits à attribuer à un nouveau compte.

---

## 3 — Gestion des fichiers

**`storage`** est le point d'entrée **unique** désigné pour tout fichier **utilisateur** du lab
— au même titre que `postgres`/`postgis` pour les données structurées. Son volume
(`storage-media`) est **possédé par `infra/docker-compose.yml`**, pas par
`storage/docker-compose.yml` : créé automatiquement au premier `docker compose up` de `infra`
(pas de `docker volume create` manuel), jamais touché par le cycle de vie d'une seule app. Seul
le container `storage-backend` le monte — toute autre app y accède **exclusivement via l'API**
de `storage`, jamais en montant le volume directement (un montage direct court-circuiterait les
contrôles de permission par namespace/partage de l'API).

**Toute nouvelle app** qui a besoin de stocker des fichiers utilisateur doit appeler l'API
`storage` directement plutôt que de se donner son propre volume média ou de mettre des blobs en
base.

**Trois façons d'appeler `storage`, selon qui agit** :

| Mécanisme | Cas d'usage | Exemple de référence |
|---|---|---|
| Compte de service `<app>-admin` (`KEYCLOAK_SERVICE_WRITE_SHARES`) | L'app décide seule de l'autorisation ; pas de token utilisateur à forwarder | `conciergerie` (un partage par bien), `traitement-de-fichiers-compils` (autorisation portée par les modèles de l'app), `arbre-genealogique` (idem + purge best-effort par signal `post_delete`), `atelier-3d` (worker Celery, écrit longtemps après la requête HTTP) |
| Forward du token utilisateur (`KEYCLOAK_TRUSTED_CLIENTS`) | Carte commune, tout le groupe lit/écrit tout, pas de tâche asynchrone touchant les fichiers | `carto-lab` (`Share.required_groups`) |
| Republication proxy `AllowAny` | Lecture publique nécessaire (page sans authentification) — `storage` lui-même n'a et ne doit avoir aucun chemin de lecture anonyme | `restauration` (photos de plats sur la carte publique) |

**Volumes média privés encore légitimes** : uniquement pour du contenu **transitoire**, jamais
pour un fichier utilisateur durable — ex. `robot-lab` (volume `downloads`, non-`external`,
supprimé après téléchargement) ou `atelier-3d` (volume `atelier3d-scratch`, bases COLMAP/nuages
de points, plusieurs Go par job, aucune valeur une fois le job terminé). Ces volumes restent
**non-`external`** : `clean2.sh <app>` peut les vider sans perte réelle. À l'inverse, tout
volume média destiné à survivre au cycle de vie de l'app doit être déclaré `external: true` avec
un `name:` explicite, sinon `clean2.sh <app>` (`docker compose down --volumes`) le supprime à
chaque `setup2.sh <app> --yes`.

**Détail complet des cinq migrations déjà réalisées** (mapping champ par champ, pièges évités,
volumes de données réelles transférées) : voir `CLAUDE.md`, section « Base de données —
migrations de fichiers », pour `conciergerie`, `carto-lab`, `restauration`,
`traitement-de-fichiers-compils`, `arbre-genealogique` et `atelier-3d`.

---

## 4 — Gestion des bases de données

`infra/docker-compose.yml` héberge **deux instances PostgreSQL séparées**, jamais une par app :

| Instance | Container | Image | Base | Rôle | Pour qui |
|---|---|---|---|---|---|
| `postgres` | `dev-postgres` | `postgres:16-alpine` | `devdb` | `devuser` | La grande majorité des apps — un schéma par app |
| `postgis` | `dev-postgis` | `postgis/postgis:16-3.5` | `gisdb` | `gisuser` | Apps SIG uniquement (aujourd'hui : `carto-lab`) |

**Pourquoi deux instances** plutôt que l'extension PostGIS en plus sur `postgres` :
- `postgres` tourne en image **alpine (musl)** ; le paquet PostGIS d'Alpine dépend de
  `postgresql18`, incompatible avec le PG16 de `devdb`.
- Les images `postgis/postgis` officielles sont **Debian (glibc)**. Basculer le datadir
  existant de `devdb` (collation `en_US.utf8` sur musl) vers glibc corromprait silencieusement
  les index texte, et serait de surcroît un *downgrade*.
- Bénéfice annexe : une charge SIG lourde (import raster, calcul Voronoï national…) ne dégrade
  pas les autres apps, et le rôle read-only d'un service comme `pg_featureserv` (accès QGIS,
  cf. `carto-lab`) reste enfermé dans une base qui ne contient **que** du SIG.

**Aucune des deux instances ne publie jamais le port 5432** sur l'hôte ni sur Internet — seuls
les containers rattachés à `dev-net` peuvent joindre `postgres:5432`/`postgis:5432`.

**Convention de nommage des identifiants** : `POSTGRES_PASSWORD` (instance `postgres`) et
`POSTGIS_PASSWORD` (instance `postgis`) dans `infra/.env`, deux clés distinctes propagées
séparément par `reset_url.sh` (voir [2.3](#23-règles-env-et-rotation-des-secrets)).

**Choisir l'instance pour une nouvelle app** : `new-app.sh` pose la question en dernier (voir
[2.1](#21-la-méthode-standard)), défaut `postgres`. Ne choisir `postgis` que si l'app manipule
réellement des données géospatiales — pas par précaution.

**Schémas** : un schéma par app, déclaré dans `infra/init/00_schemas.sql` (instance `postgres`)
ou `infra/init-postgis/00_schemas.sql` (instance `postgis`). Ce fichier n'est rejoué qu'à
l'initialisation du volume — `ensure-schemas.sh` (appelé par `setup_unit.sh`/`setup2.sh` avant
chaque déploiement) rattrape les schémas manquants à chaud, en lisant `DB_HOST` de chaque app
pour cibler le bon container.

**pgAdmin** : login interne désactivé, uniquement Keycloak (OAuth2), accès réservé au groupe
`developers`. Prérequis : `sso-lab` démarré, `bash infra/setup-keycloak-pgadmin.sh` (une fois),
copier `PGADMIN_OAUTH2_CLIENT_SECRET` dans `infra/.env`.

> ⚠️ **Après une migration qui supprime une colonne de blobs** (voir [3](#3--gestion-des-fichiers)) :
> `DROP COLUMN` ne fait que marquer la colonne supprimée, les données TOAST restent jusqu'à une
> réécriture de table. Lancer `VACUUM FULL <schéma>.<table>` derrière — sans ça, la base et ses
> sauvegardes gardent exactement le poids qu'on cherchait à retirer (constaté :
> `traitement_de_fichiers_compils.fichiers` 20 Mo → 64 ko ;
> `arbre_genealogique.media_objects` 6,4 Mo → 80 ko après `VACUUM FULL`).

---

## 5 — Annexes

### Services et ports

| Service | Port LAN | URL HTTPS |
|---|---|---|
| Keycloak | 8080 | `https://DOMAIN/auth/` |
| phpLDAPadmin | 8081 | direct LAN uniquement |
| pgAdmin | 5050 | direct LAN uniquement |
| PostgreSQL / PostGIS | 5432 (×2 instances) | interne Docker uniquement |
| code-server | — | `https://DOMAIN/code/` (réservé `developers`/`admins`) |

Ports applicatifs : voir le tableau [2.5](#25-sous-modules-existants-et-comment-les-utiliser).
URL frontend `https://DOMAIN/<app>/`, API `https://DOMAIN/<app>-api/`.

### Vitrine publique vs outils d'administration

`.app-descriptions` (racine) pilote **uniquement** la page 404 publique, servie **sans
authentification** — y ajouter une app publie son nom et sa description à tout visiteur.
Régénérer après modification : `bash scripts/complete_404.sh`.

Les **outils d'administration** (page « Apps du lab » de `lab-admin`, catalogue des tests E2E,
`add-user.sh`) affichent en revanche **toutes** les apps réellement déployées — toute entrée de
`.ports` dont le dossier contient un `docker-compose.yml`, indépendamment de
`.app-descriptions`. Une app hors vitrine est signalée par une étiquette « hors vitrine » dans
`lab-admin`, jamais masquée.

### Utilisateurs LDAP

| Utilisateur | Groupes | code-server |
|---|---|---|
| sacha | developers, admins, famille, amis, harem, manager, cuisinier, serveur, proprietaires | ✓ |
| hassan | developers, amis | ✓ |
| lea | famille, amis | ✗ |
| elodie | famille, manager, proprietaires | ✗ |
| sabrina | manager | ✗ |
| bruno | proprietaires | ✗ |
| marie | famille | ✗ |
| fannie | proprietaires | ✗ |

`e2e_member` (membre de **tous** les groupes) et `e2e_outsider` (membre d'**aucun** groupe) sont
deux comptes synthétiques réservés aux tests E2E — voir ci-dessous.

### Tests end-to-end (Playwright)

Chaque app a **un seul fichier** de test : `<app>/frontend/e2e/cloisonnement.spec.ts` (copié
tel quel depuis `_templates/django-angular/frontend/e2e/cloisonnement.spec.ts`, sans
adaptation). Il automatise le test manuel de cloisonnement : membre du groupe requis passe,
non-membre refusé, non-membre avec session SSO déjà active refusé aussi.

- **`runner/`** (racine, comme `infra/`/`sso-lab/`) : conteneur unique Playwright + Chromium
  pour tout le lab, réseau `sso-net` uniquement, jamais exposé, atteint via `lab-admin`
  (worker Celery) ou `docker exec` depuis `setup_unit.sh`.
- **Catalogue** (`GET /list`, pas de navigateur) : à chaque déploiement d'une app, liste les
  tests du fichier de l'app dans `lab-admin` (best-effort, fin de `setup_unit.sh`).
- **Exécution** (`POST /run`, navigateur réel) : jamais automatique — déclenchée à la main
  depuis la page **Debug** de `lab-admin`. Un seul run à la fois, lab-wide (mutex + concurrency=1).

### Réseaux Docker

| Réseau | Utilisé par |
|---|---|
| `sso-lab_sso-net` | Keycloak, LDAP, Caddy, oauth2-proxy, code-server, toutes les apps, `runner/` |
| `dev-net` | PostgreSQL, PostGIS, pgAdmin, backends Django/Spring |
| `edge-net` | Répartiteur partagé entre cadriciels (`~/edge-router/`) — Caddy uniquement, voir [1.5](#15-plusieurs-cadriciels-sur-une-même-ip-wan--le-répartiteur) |

### Scripts utiles

Tous lancés avec `bash scripts/<nom>` depuis la racine `dev/` (résolvent eux-mêmes la racine).

| Script | Rôle |
|---|---|
| `new-app.sh` | Scaffold interactif d'une nouvelle app |
| `setup2.sh [<app>] --yes` | Déploiement complet (une app, ou tout le lab en parallèle) |
| `setup_unit.sh <app> --yes` | Pipeline complet d'une seule app (utilisé par `setup2.sh`, appelable seul) |
| `create-app-client.sh <app>` | Créer/mettre à jour le client Keycloak seul |
| `ensure-schemas.sh <app>` | Rattraper à chaud le schéma Postgres manquant |
| `recompose_docker.sh --app <app>` | Rebuilder et redémarrer les containers |
| `clean2.sh <app>` | Arrêter et supprimer les containers d'une app |
| `reset_url.sh` | Propager LAN/WAN/Keycloak dans tous les `.env`, valider la config réseau |
| `open-bbox-ports2.sh` | Ouvrir les ports adaptés (HTTP/HTTPS) sur le routeur Bbox |
| `get-ports-list.sh` | Régénérer `ports.env` depuis `.ports` |
| `complete_404.sh` | Régénérer `sso-lab/fallback/html/404.html` depuis `.app-descriptions` |
| `init-secrets.sh` | Générer des mots de passe forts |
| `add-user.sh` | Créer un utilisateur LDAP + l'assigner à des groupes |
| `sso-lab/setup-code-server-auth.sh` | Créer le client Keycloak de code-server (`--rotate` pour forcer la rotation) |
| `rotate-secrets-full.sh --yes` | Rotation complète de tous les secrets automatisables + redémarrage |
| `rotate-ldap-user-passwords.sh --yes` | Rotation à chaud du mot de passe de chaque compte LDAP, avec email |
| `rotate-secrets.sh --yes` | Rotation à chaud des secrets admin sso-lab |
| `rotate-db-password.sh --yes` | Rotation à chaud du mot de passe PostgreSQL partagé |
| `rotate-app-secret.sh <app>` | Régénère le `SECRET_KEY` Django d'une app |
| `notify-password-email.sh <uid> <email> <mdp>` | Envoie un mot de passe par email (best-effort) |

### Structure du dossier

```
dev/
├── README.md
├── CLAUDE.md               ← guide détaillé pour les agents IA
├── .gitignore               ← ignore tous les .env et .debug/
├── .ports                   ← registre des ports (géré par new-app.sh)
├── .app-descriptions        ← vitrine publique (page 404)
├── .env / bbox.env          ← non commités
├── infra/                   ← PostgreSQL + PostGIS + pgAdmin  [restart: always]
│   ├── docker-compose.yml
│   └── init/ / init-postgis/
│       └── 00_schemas.sql       ← CREATE SCHEMA par app  ← MODIFIER ICI
├── sso-lab/                 ← Keycloak + OpenLDAP + Caddy + oauth2-proxy + code-server
│   ├── docker-compose.yml
│   ├── ldap/init.ldif           ← utilisateurs et groupes LDAP
│   └── caddy/Caddyfile
├── runner/                  ← Playwright + Chromium partagé (tests E2E)
├── _templates/               ← templates copiés par new-app.sh
│   ├── django-angular/
│   ├── django-only/
│   └── angular-only/
└── <app>/                   ← sous-module git (même modèle pour chaque app)
    ├── .env / .env.example
    ├── .keycloak-client-opts    ← --require-group, port, chemin Caddy
    ├── docker-compose.yml
    ├── backend/ / frontend/
    └── frontend/e2e/cloisonnement.spec.ts
```

> **Journal de bugs** : les incidents rencontrés et leurs corrections sont documentés dans
> `.debug/` (ignoré par git).
