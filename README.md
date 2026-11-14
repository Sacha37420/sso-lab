# dev/ — Lab SSO multi-applications

Plateforme d'apprentissage et de développement autour de **Keycloak**, **OpenLDAP**,
**PostgreSQL/PostGIS** et **Caddy**. Elle héberge des applications Django + Angular authentifiées
par OIDC (quatorze dans `deploiement/`, dont le didacticiel `test-video`) et les services du
cadriciel : `lab-admin` (portail), `storage` (fichiers), `oauth-hub` (jetons des sites externes),
`app-builder` (spécifications), le moteur `lab-mcp` (déploiements, espaces de travail),
`lab-media` (caméras, micro, haut-parleur) et un runner Playwright pour les tests de cloisonnement.

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
   - [1.2 Installation](#12-installation)
   - [1.3 Exposition sur le WAN](#13-exposition-sur-le-wan)
   - [1.4 HTTPS via Caddy + nom de domaine (DDNS)](#14-https-via-caddy--nom-de-domaine-ddns)
   - [1.5 Plusieurs cadriciels sur une même IP WAN — le répartiteur](#15-plusieurs-cadriciels-sur-une-même-ip-wan--le-répartiteur)
   - [1.6 Modules : choisir, ajouter, relancer depuis lab-admin](#16-modules--choisir-ajouter-relancer-depuis-lab-admin)
2. [Créer une nouvelle application](#2--créer-une-nouvelle-application)
   - [2.1 La méthode standard](#21-la-méthode-standard)
   - [2.2 Règles d'infrastructure et de sécurité](#22-règles-dinfrastructure-et-de-sécurité)
   - [2.3 Règles `.env` et rotation des secrets](#23-règles-env-et-rotation-des-secrets)
   - [2.4 Règles UI — identité « Foyer »](#24-règles-ui--identité--foyer-)
   - [2.5 Sous-modules existants et comment les utiliser](#25-sous-modules-existants-et-comment-les-utiliser)
3. [Gestion des fichiers](#3--gestion-des-fichiers)
4. [Gestion des bases de données](#4--gestion-des-bases-de-données)
5. [Annexes](#5--annexes)
6. [Travail automatique de Claude — les sessions de nuit](#6--travail-automatique-de-claude--les-sessions-de-nuit)

---

## Architecture d'ensemble

```
dev/
├── sso-lab/            ← Keycloak 26 + OpenLDAP + phpLDAPadmin + Caddy + fallback + oauth2-proxy + code-server
├── infra/              ← PostgreSQL 16 (bases lab, keycloak, dev_<uid>) + PostGIS 16-3.5 (gis_<uid>) + pgAdmin 8
├── runner/             ← Playwright + Chromium partagé (tests de cloisonnement E2E)
├── lab-mcp/            ← moteur : déploiements, espaces de travail, pgAdmin par dev (seul à monter docker.sock avec Caddy et code-server)
├── lab-media/          ← MediaMTX : caméras, micro, haut-parleur, enregistrements
├── workspace/          ← image lab-workspace des espaces VS Code (code-server, Claude Code, Mistral Vibe)
├── _templates/         ← gabarits Django+Angular / Django seul / Angular seul, règles des projets
├── lab-admin/          ← Django + Angular  [sous-module] — portail du lab (Accueil, Services, Projets)
├── storage/            ← Django + Angular  [sous-module] — stockage de fichiers du lab
├── oauth-hub/          ← Django + Angular  [sous-module] — coffre d'identifiants OAuth externes
├── app-builder/        ← Django + Angular  [sous-module] — spécifications d'apps
├── deploiement/        ← les applications, une par sous-module :
│   ├── analyse-lora/  arbre-genealogique/  atelier-3d/  bilan-thermique/  carto-lab/
│   ├── code-route/  conciergerie/  craft-lab/  peripheriques/  restauration/
│   └── robot-lab/  test-video/  traitement-de-fichiers-compils/
├── scripts/            ← tous les scripts d'orchestration (install.sh, setup2.sh, app-*.sh…)
├── edge-router.example/ ← gabarit du répartiteur 80/443 (posé dans ~/edge-router/ par install.sh)
├── .ports / .owners / .devs / .app-descriptions ← registres (ports, propriétaires, développeurs, vitrine)
└── bbox.env            ← source de vérité réseau (LAN/WAN, routeur)
```

Pour le chemin réel d'une app, les scripts passent toujours par `registry_app_dir` :
`deploiement/<app>` d'abord, sinon la racine (services du cadriciel).

Hors de ce dépôt, sur le même hôte (voir [1.1](#11-ce-qui-est-inclus-dans-dev-ce-qui-ne-lest-pas)
pour le détail) :

```
~/
├── dev/           ← ce dépôt (« lab1 »)
├── dev2/          ← second cadriciel indépendant (« lab2 »), copie isolée de dev/
└── edge-router/    ← répartiteur nginx des ports 80/443, hors dépôt ; posé depuis dev/edge-router.example/
```

---

## 1 — Procédure de construction de l'infrastructure

### 1.1 Ce qui est inclus dans `dev/`, ce qui ne l'est pas

**Inclus et versionné dans ce dépôt (ou ses sous-modules)** :
- `sso-lab/` : Keycloak, OpenLDAP, phpLDAPadmin, Caddy (reverse-proxy), oauth2-proxy,
  code-server.
- `infra/` : les deux instances PostgreSQL (`postgres` et `postgis`), pgAdmin.
- `runner/` : conteneur Playwright partagé pour les tests de cloisonnement E2E.
- `lab-mcp/`, `lab-media/`, `workspace/` : moteur, flux audio/vidéo, image des espaces de travail.
- `_templates/` : templates de scaffold (Django+Angular, Django seul, Angular seul).
- Les applications et les services du cadriciel à interface web, en sous-modules git pointant
  vers leurs propres dépôts.
- Tous les scripts d'orchestration (`scripts/`).
- `edge-router.example/` : le gabarit du répartiteur 80/443 (voir 1.5).

**Explicitement hors de ce dépôt, non versionné, à la charge de l'opérateur** :
- **Le nom de domaine et le DDNS** (No-IP, DuckDNS, client du routeur…) — voir
  [1.4](#14-https-via-caddy--nom-de-domaine-ddns).
- **Le routeur physique** (Freebox ou Bbox) et son interface d'administration — les scripts ne
  font qu'appeler son API pour ouvrir des ports, jamais configurer le WAN/DDNS lui-même.
- **`~/edge-router/`** — le répartiteur partagé entre plusieurs cadriciels (`dev/`, `dev2/`).
  Il vit en dehors de tout dépôt git, sur l'hôte. Voir [1.5](#15-plusieurs-cadriciels-sur-une-même-ip-wan--le-répartiteur).
  Sur une machine neuve, `install.sh` le pose depuis le gabarit `edge-router.example/` ; une fois
  modifié à la main (second cadriciel), seule la sauvegarde nocturne en garde une copie
  (`backup.sh`, « configuration hors dépôt »).
- **`dev2/`** — un second cadriciel complet, structurellement identique à `dev/` (mêmes
  scripts, mêmes mécanismes) mais avec son propre domaine, son propre realm Keycloak/LDAP,
  ses propres apps (non sous-modules, dépôt git local uniquement). Totalement isolé de `dev/` :
  aucune donnée ni secret partagé, hormis l'hôte Docker et `~/edge-router/`.
- **Le serveur SMTP** (Gmail, via mot de passe d'application) utilisé par Keycloak pour
  « mot de passe oublié » et la notification de rotation de mot de passe.
- **Docker Engine + Docker Compose** eux-mêmes, et l'accès SSH/VS Code desktop à la machine.

### 1.2 Installation

Prérequis sur l'hôte : Docker Engine + plugin Compose (utilisateur dans le groupe `docker`),
`git`, `jq`, `curl`, `openssl`, `python3`, `flock` (util-linux), `ss` et `ip` (iproute2). `gh`
ne sert qu'à créer à la main le dépôt d'une app. `install.sh` vérifie tout cela en premier.

```bash
# 1. Cloner avec les sous-modules
#    ⚠️ Le dépôt parent s'appelle « sso-lab » sur GitHub pour des raisons
#    historiques, mais s'installe dans un dossier « dev/ ».
git clone --recurse-submodules https://github.com/Sacha37420/sso-lab.git dev
cd dev

# 2. Voir ce que l'installation ferait, sans rien toucher
bash scripts/install.sh --check

# 3. Installer (rejouable : ne refait jamais ce qui est en place)
bash scripts/install.sh --domain mon-lab.example.org --acme-email moi@example.org
```

`install.sh` enchaîne, en regardant à chaque étape l'état réel de la machine :

1. contrôle des prérequis, extraction des sous-modules manquants, puis **choix des modules
   facultatifs** et affichage du plan d'installation (menu au terminal, voir 1.6) ;
2. `.env` et `bbox.env` de la machine : IP LAN et WAN détectées (ou `--lan-ip`, `--wan`),
   `DOMAIN`, `ACME_EMAIL`, `LAB_SUPERUSER` (`--superuser`, défaut : l'utilisateur courant) ;
3. un `.env` pour **chaque** unité qui a un `.env.example` et pas de `.env` — à la racine comme
   dans `deploiement/` —, avec la bonne base (`lab` pour les services du cadriciel, `dev_<uid>` /
   `gis_<uid>` pour les apps), des secrets générés à la place des `CHANGE_ME`, et pour `lab-mcp`
   les identités de l'hôte (`id -u`, `id -g`, GID du groupe `docker`) ;
4. `sso-lab/ldap/init.ldif` depuis son gabarit, `.ports` reconstruit, `~/lab-work` et
   `.lab-state/` créés ; contrôle que le superutilisateur a un compte dans l'annuaire, membre
   de `admins` et `developers` (le gabarit ne connaît que `sacha`) ;
5. secrets de premier passage (`init-secrets.sh`) : LDAP, Keycloak, `POSTGRES_PASSWORD`,
   `POSTGIS_PASSWORD`, coffre d'`oauth-hub`, **un mot de passe par compte de l'annuaire**
   (écrits dans `sso-lab/.env`, clés `<UID>_PASSWORD`) — seulement tant que les volumes
   correspondants n'existent pas ;
6. réseau Docker `edge-net`, propagation des adresses (`reset_url.sh`) ;
7. base `keycloak` de Keycloak 26 (`infra` démarré pour elle, `dev-db.sh ensure-keycloak`,
   mot de passe recopié par `reset_url.sh`), puis `sso-lab`, realm, fédération LDAP, scope
   `nonce-keycloak-js-22` (`keycloak-nonce-compat.sh` : sans lui, boucle de connexion dans
   toutes les apps), clients Keycloak de `code-server` et de pgAdmin ;
8. `infra`, puis `dev-db.sh ensure-lab` (rôle et base `lab`), `dev-db.sh ensure <superutilisateur>
   --gis`, propagation des mots de passe de base, `dev-db.sh lockdown-connect --apply` ;
9. runner de tests ;
10. `storage`, `oauth-hub`, `lab-admin`, `lab-mcp`, puis les modules choisis et leurs dépendances,
    dans l'ordre du plan (`--no-apps` pour s'arrêter au cadriciel) ;
11. image `lab-workspace:latest` (≈ 8 min ; `--no-workspace-image` pour la remettre à plus tard),
    partages de groupe de `storage`, sauvegarde nocturne planifiée à 3 h (`backup-cron.sh`),
    `ports.env`, page 404 ;
12. bilan, et la liste de ce qui reste à faire à la main.

`--until <n>` arrête après l'étape *n* (par exemple `--until 6` : tout ce qui précède le premier
démarrage de conteneur). En cas d'échec, corriger et relancer la même commande.

**Ce que l'installation ne peut pas faire** (elle le rappelle à la fin) :

- **Fiche GitHub dans `oauth-hub`** : enregistrer une application OAuth chez GitHub (URI de
  rappel `https://<DOMAIN>/oauth-hub-api/api/callback/github/`, portée `read:user repo`) et saisir
  son `client_id` / `client_secret` dans l'interface d'`oauth-hub` — pas à pas dans
  `oauth-hub/README.md`. Sans elle : ni création de projet, ni ticket, ni éditeur. Idem, si
  besoin, pour GitLab et Google.
- **SMTP de Keycloak** (`sso-lab/.env` : `SMTP_FROM`, `SMTP_USER`, `SMTP_PASSWORD`).
- **Nom de domaine et DDNS**, redirection des ports 80/443 du routeur (voir 1.3 et 1.4).
- **`~/edge-router/`** (voir 1.5) : le Caddy de `sso-lab` ne publie plus lui-même 80/443. Sur une
  machine neuve, `install.sh` le pose depuis le gabarit versionné `edge-router.example/`
  (`scripts/edge-router-install.sh`) ; il ne touche jamais à un répartiteur existant. Ajouter un
  second cadriciel sur la même machine : `edge-router.example/README.md`.
- **Adresses réelles des comptes** : le gabarit de l'annuaire donne à chacun une adresse factice
  `<uid>@ssolab.local` ; mettre les vraies dans `sso-lab/ldap/init.ldif` **avant** l'installation
  (après, par phpLDAPadmin) pour que « mot de passe oublié » fonctionne.
- **Copie NAS des sauvegardes** : `install.sh` planifie `scripts/backup.sh` (bases, annuaire,
  volumes, tout ce qui est hors dépôt — voir CLAUDE.md « Sauvegardes ») à 3 h, mais la copie sur
  un NAS demande `LAB_BACKUP_NAS`, `LAB_BACKUP_NAS_USER` (`.env` racine) et `~/.lab-backup-nas`
  (mot de passe, mode 600). Vérifier : `bash scripts/backup-cron.sh --check`. Les archives ne
  sont **pas chiffrées**. `~/lab-work/` n'y est pas : le travail des espaces se sauvegarde en le
  poussant sur GitHub.

> **Sans nom de domaine**, l'installation va au bout d'un lab « HTTP local » (accès direct par
> port), mais **le moteur `lab-mcp` refuse de démarrer** (`DOMAIN=CHANGE_ME`) : la page
> « Projets » de `lab-admin`, les espaces de travail et le déploiement par le moteur exigent
> HTTPS. Relancer `install.sh --domain …` une fois le domaine en place.

> **Un autre installateur que le propriétaire d'origine** règle deux choses : `LAB_SUPERUSER`
> (`.env` racine, par défaut l'utilisateur Unix qui lance l'installation — un uid de l'annuaire,
> membre de `admins` et `developers` : copier le bloc `uid=sacha` de `sso-lab/ldap/init.ldif`
> **avant** le premier démarrage, `install.sh --check` le signale sinon), et
> `LAB_TICKET_REPO` (`lab-mcp/.env` — dépôt GitHub où le moteur ouvre les tickets « lab » ;
> défaut `Sacha37420/sso-lab`).

> **`SERVER_URL_WAN`** (`bbox.env`) doit toujours valoir une vraie adresse : `reset_url.sh`
> refuse `CHANGE_ME`, et la valeur du gabarit (`http://VOTRE_IP_WAN`) serait propagée telle
> quelle. `install.sh` la détecte ; pour un lab purement local, lui passer `--wan <IP LAN>`.

> **Projets privés** : le dépôt d'un projet peut être privé. Son sous-module porte
> `update = none` dans `.gitmodules` (posé par `app-register.sh`), pour que le clone récursif
> d'un tiers saute ce dossier au lieu d'avorter ; `install.sh` l'extrait pour qui y a accès.

À l'issue de l'installation :
- Chaque app est disponible sur `https://<DOMAIN>/<app>/` (sans domaine, en HTTP local :
  `http://<IP_LAN>:<port_frontend>/`).
- Keycloak (8080), phpLDAPadmin (8081) et pgAdmin (5050) ne sont liés qu'à `127.0.0.1` dès
  qu'un domaine est configuré : les joindre par un tunnel SSH
  (`ssh -L 8080:localhost:8080 <hôte>`). La console d'administration de Keycloak ne s'ouvre pas
  aujourd'hui, même par tunnel (CLAUDE.md, « Keycloak 26 ») : administrer par
  `docker exec keycloak /opt/keycloak/bin/kcadm.sh …`.
- `infra/` et `sso-lab/` tournent en `restart: always` : ils redémarrent avec Docker.
- `bash scripts/lab-doctor.sh` fait le bilan de santé (lecture seule).

Ensuite, on ne manipule plus que des unités individuelles :

```bash
bash scripts/setup2.sh mon-app --yes    # (re)déployer une app
bash scripts/clean2.sh mon-app          # l'arrêter et supprimer ses containers
bash scripts/install.sh --check         # l'installation est-elle toujours complète ?
bash scripts/lab-doctor.sh              # bilan de santé : bases, sauvegarde, Keycloak, ports, conteneurs
```

> Sur la machine en service, `install.sh --check` conclut « Rien à faire » (relu le 2026-11-14).

`bash scripts/setup2.sh --yes` (sans nom) redéploie **tout** le lab ; il suppose l'installation
déjà faite.

### 1.3 Exposition sur le WAN

L'exposition WAN ajoute deux choses au démarrage local : une IP publique jusqu'à la machine
(port-forwarding NAT sur le routeur) et une vérification que les identités réseau configurées
correspondent à la réalité.

```bash
# 1. Renseigner l'IP WAN publique dans bbox.env
nano bbox.env    # SERVER_URL_WAN=http://<IP_WAN>

# 2. Décrire le routeur : Freebox (FREEBOX_IP) ou Bbox (BBOX_ADMIN_PASSWORD, BBOX_URL, BBOX_IP)
nano bbox.env

# 3. Propager + valider
bash scripts/reset_url.sh
```

`reset_url.sh` ne se contente pas de propager — il **valide** activement la configuration
réseau à chaque exécution :
- compare l'IP LAN détectée (table de routage) à celle déclarée dans `bbox.env` ;
- compare l'IP WAN détectée (`api.ipify.org`) à celle déclarée ;
- teste que Keycloak répond depuis l'extérieur : `https://<DOMAIN>/auth/realms/ssolab` avec un
  domaine (ports 80/443 et `edge-router`), `<IP_WAN>:<PORT_KEYCLOAK>` en HTTP local seulement.
  Avec un domaine, **ne jamais rediriger 8080** sur la box : Keycloak n'y écoute que sur
  `127.0.0.1`.

Un écart signalé peut venir d'un DDNS pas encore à jour, d'un double NAT, ou d'un port-forwarding
manquant/mal ciblé — `reset_url.sh` explique la piste la plus probable dans son propre message.

```bash
# 4. Ouvrir les ports sur le routeur
bash scripts/open-freebox-ports.sh authorize   # Freebox, une seule fois (voir plus bas)
bash scripts/open-freebox-ports.sh apply       # Freebox
bash scripts/open-bbox-ports2.sh               # Bbox
```

`setup2.sh` fait cette étape lui-même d'après `bbox.env` : `FREEBOX_IP` → Freebox, `BBOX_IP` →
Bbox. Si les deux sont renseignées, il demande laquelle au terminal ; lancé sans terminal (par
le moteur `lab-mcp`), il ne touche à aucune box. Retirer les lignes de la box qu'on n'a plus
évite la question.

**Freebox** — l'API Freebox OS n'accepte pas le mot de passe administrateur. `authorize` demande
un jeton d'application : la demande s'affiche sur l'écran du Freebox Server et se valide avec ses
boutons. Il faut ensuite cocher, dans Freebox OS → Paramètres → Gestion des accès → Applications
→ « Lab dev », le droit **« Modification des réglages de la Freebox »**. Le jeton est gardé dans
`.lab-state/freebox-app-token`. `status` affiche l'IP publique, la plage de ports et les
redirections : une plage autre que `0-65535` signifie une **IPv4 partagée**, où 80 et 443 sont
impossibles — demander l'« adresse IP fixe V4 full-stack » dans l'espace abonné Free (onglet
« Ma Freebox »), puis redémarrer la box. En HTTPS le script ouvre 80 et 443 en TCP et 8189 en
TCP+UDP (ICE de `lab-media`) ; une redirection existante vers une autre machine n'est jamais
modifiée.

**Bbox** — `open-bbox-ports2.sh` parle directement l'API REST de la Bbox Bouygues (`mabbox.bytel.fr`) : authentification
par mot de passe admin, obtention d'un `device token`, puis création d'une règle NAT par port —
idempotent (une règle déjà existante n'est pas recréée). **Tant que `DOMAIN=CHANGE_ME`**, il ouvre
un port par service/app (`ports.env`) : chaque app reste joignable directement par son port, en
HTTP, sur Internet. Voir 1.4 pour le comportement une fois HTTPS activé (surface radicalement
réduite).

> Ces deux scripts sont propres à leur box. Avec un autre routeur, ouvrir les mêmes ports
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
3. Une fois le domaine actif, le renseigner dans le **`.env` racine** : `reset_url.sh` recopie
   `DOMAIN` et `ACME_EMAIL` dans tous les autres `.env`, `sso-lab/.env` compris
   (`scripts/reset_url.sh:338,348`).

```bash
bash scripts/install.sh --domain mondomaine.example.com --acme-email moi@example.com
# ou, à la main :
nano .env            # DOMAIN=mondomaine.example.com, ACME_EMAIL=moi@example.com
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

**Effet sur l'ouverture des ports** — `open-freebox-ports.sh` et `open-bbox-ports2.sh` regardent `DOMAIN` :

| Mode | Ports ouverts sur le routeur |
|---|---|
| HTTP (`DOMAIN=CHANGE_ME`) | Tous les `PORT_*` de `ports.env` — un par service/app, accès direct |
| HTTPS (`DOMAIN` configuré) | Seulement **80** (ACME + redirect) et **443** (plus 8189 pour `lab-media` sur Freebox) — Caddy route en interne par chemin, les ports individuels ne sont plus exposés sur Internet |

C'est une réduction volontaire de la surface exposée : en HTTPS, `https://DOMAIN/lab-admin/`
passe entièrement par Caddy sur le port 443 ; le port du container reste interne au réseau
Docker `sso-net`.

### 1.5 Plusieurs cadriciels sur une même IP WAN — le répartiteur

> **À savoir même avec un seul cadriciel** : le `docker-compose.yml` de `sso-lab` versionné ici
> est déjà dans cette disposition. Il déclare le réseau `edge-net` **externe** (créé par
> `install.sh` et par `setup2.sh` s'il manque — sans lui Compose ne démarre rien) et son Caddy
> **ne publie plus 80/443** : sans `~/edge-router/`, le lab n'est pas joignable en HTTPS de
> l'extérieur. Sur une machine neuve, `install.sh` le pose depuis le gabarit versionné
> `edge-router.example/` (`scripts/edge-router-install.sh`, qui ne touche jamais à un
> `~/edge-router/` existant). Les fichiers ci-dessous décrivent ce qu'il contient.

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
`edge-router` — plus besoin de forwarder un port par cadriciel. Le script de box de chaque
cadriciel continue d'ouvrir `PORT_HTTP`/`PORT_HTTPS` sans effet sur le routage applicatif
(`edge-router` écoute déjà ces ports) — inoffensif à relancer.

**Rollback** (revenir à un seul cadriciel exposé directement) : réajouter le bloc `ports:` sur
le service `caddy` concerné et relancer `docker compose up -d` — aucune autre modification
nécessaire, `edge-net` peut rester connecté sans effet tant que `ports:` republie 80/443.

> ⚠️ **Le `~/edge-router/` réel n'est pas versionné** : le gabarit `edge-router.example/` ne
> connaît qu'un cadriciel. Une fois modifié (second cadriciel, nouveau domaine), sa seule copie
> est la sauvegarde nocturne (`backup.sh`, « configuration hors dépôt »). Toucher à `edge-net`
> ou aux `ports:` de n'importe quel Caddy affecte **tous** les cadriciels simultanément : à
> faire en connaissance de cause, jamais sans vérifier l'état des autres cadriciels avant.
> N'utiliser ce mécanisme que si l'hôte héberge réellement plusieurs cadriciels — un seul
> cadriciel n'a aucune raison de perdre l'exposition directe décrite en 1.3/1.4.

---

### 1.6 Modules : choisir, ajouter, relancer depuis lab-admin

Le lab s'installe **par modules**. Le socle (`sso-lab`, `infra`, `runner`) et les quatre services
du cadriciel (`storage`, `oauth-hub`, `lab-admin`, `lab-mcp`) s'installent toujours ; les apps de
`deploiement/`, `app-builder` et `lab-media` sont **facultatives**. Chaque module a une
**description** (dépendances, prérequis système, réglages à demander, poids de build, groupes,
scripts d'installation) : `<module>/lab-module.json`, sinon le catalogue `modules/<nom>.json`.
Format et exemple complet : [`modules/README.md`](modules/README.md) ; ce qu'une app doit fournir :
`chantiers/modules/REGLES_MODULE.md`.

**Première installation** — `install.sh` demande à l'étape 2 quels modules installer (menu
`whiptail` s'il est présent, sinon liste numérotée ; `LAB_NO_WHIPTAIL=1` pour la liste), montre
le plan (« seront installés après le cadriciel, dans cet ordre : … »), demande confirmation puis
les réglages des modules choisis (clés d'API ; un secret n'est pas affiché), et installe tout à
l'étape 10, dépendances d'abord. Le choix est mémorisé dans `.lab-state/modules/selection.json`.

```bash
bash scripts/install.sh --check                         # montre la sélection et le plan, ne fait rien
bash scripts/install.sh --modules peripheriques,craft-lab   # ceux-là et leurs dépendances (lab-media, storage, oauth-hub)
bash scripts/install.sh --all-modules                   # tous
bash scripts/install.sh --no-apps                       # aucun : socle et cadriciel seulement
bash scripts/install.sh --yes                           # la sélection mémorisée ; sans elle, tous (comme avant)
```

Un module qui échoue n'arrête pas les autres ; ceux qui en dépendent sont sautés, et le bilan
donne la commande pour relancer (`bash scripts/install.sh --modules <nom>`).

**Plus tard, sur l'hôte** :

```bash
bash scripts/lab-modules.sh list                        # catalogue et état de chaque module
bash scripts/lab-modules.sh show <nom> --check          # prérequis, réglages, dépendances, groupes, install.sh --check
bash scripts/lab-modules.sh plan --reinstall --with-deps <nom>   # ce qu'une relance ferait
bash scripts/install.sh --modules <nom>                 # installer un module non installé
bash scripts/setup2.sh <nom> --yes                      # relancer l'installation d'un module installé
```

**Depuis lab-admin** (superutilisateur) : page **Modules** — liste et état, « Vérifier », choix
d'un ou plusieurs modules, options « réinstaller » et « avec ses dépendances », plan affiché avant
confirmation, saisie des réglages manquants (envoyés une fois au moteur, jamais relus), suivi du
job. Le moteur installe par le chemin de déploiement standard (commit présent sur GitHub,
contrôles, tests backend) et ne se réinstalle jamais lui-même (`lab-mcp` : sur l'hôte,
`bash scripts/setup2.sh lab-mcp --yes`).

**Ajouter un module** : une app créée par lab-admin ou `new-app.sh` naît avec `lab-module.json`,
`install.sh` et `install.bat` (squelettes sans effet). Une app existante sans description reçoit
une description déduite (sans dépendances) : lui écrire `modules/<nom>.json` ou, mieux, un
`lab-module.json` dans son dépôt, puis `bash scripts/tests/modules/run.sh`.

**Windows** : le lab ne s'installe pas sous Windows (`install.bat` à la racine l'explique) — il faut
un hôte Linux avec Docker. Le `install.bat` d'un module sert au poste d'un développeur.

---

## 2 — Créer une nouvelle application

### 2.1 La méthode standard

**Voie normale (depuis le 2026-10-10) : `lab-admin` → Projets → « Nouveau projet »** (ou l'outil
`create_app` du moteur `lab-mcp`). Le moteur enchaîne : contrôle du nom, dépôt GitHub sous le
compte du développeur (jeton passé par `oauth-hub`), scaffold dans `deploiement/<app>`, ligne
`.owners`, schéma dans la base du propriétaire, clé de déploiement, sous-module ; puis le bouton
« Déployer » fait le chemin à portes : synchronisation du commit poussé, `validate-app.sh`,
construction, **tests backend**, démarrage, test de cloisonnement. Une spécification « prête »
d'`app-builder` se construit de la même façon (« Mes spécifications » → « Lancer la
construction »). Il faut pour cela la fiche GitHub d'`oauth-hub` (voir 1.2).

Les étapes ci-dessous sont la **voie manuelle** du superutilisateur (ou ce que font les scripts
appelés par le moteur) — utiles pour comprendre ou dépanner.

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

Le script contrôle le nom (`check-app-name.sh`), crée **`deploiement/<app>/`** complet (backend,
frontend, docker-compose, Dockerfiles, nginx, `.env`, feuille de route et règles
`CLAUDE.md`/`AGENTS.md`), enregistre le propriétaire dans `.owners` et les ports dans `.ports`,
crée le schéma de l'app **dans la base de son propriétaire** (`dev_<uid>`, ou `gis_<uid>`), et
écrit `.keycloak-client-opts`. `--owner <uid>` crée l'app pour un développeur inscrit ; sans
lui, elle appartient au superutilisateur. **Il ne crée ni le client Keycloak ni le dépôt GitHub.**

**Étape 2 — Dépôt GitHub + sous-module :**

```bash
gh repo create Sacha37420/mon-app --public      # ou --private
LAB_GIT_AUTHOR_NAME="Prénom Nom" LAB_GIT_AUTHOR_EMAIL=moi@example.org \
  bash scripts/app-register.sh mon-app https://github.com/Sacha37420/mon-app.git
```

`app-register.sh` fait le `git init`, le premier commit, le `push`, puis enregistre
`deploiement/mon-app` comme sous-module du dépôt parent (indexé, **non commité** : le commit du
parent reste à faire à la main). Depuis `lab-admin` (page « Projets ») ou par le moteur, ces deux
étapes et la suivante sont faites d'un seul geste.

**Étape 3 — Remplir `.env`** : voir [2.3](#23-règles-env-et-rotation-des-secrets).

**Étape 3 bis — Cloisonner l'app** (à ne pas sauter) : voir [2.2](#22-règles-dinfrastructure-et-de-sécurité).

**Étape 4 — Déploiement complet :**

```bash
bash scripts/setup2.sh mon-app --yes
```

Avec un nom d'app (et sans `--restart-sso-lab`/`--rotate-secrets`), `setup2.sh` délègue
intégralement à `scripts/setup_unit.sh`, qui suit l'un de deux ordres :
- **app « à portes »** (une ligne dans `.owners` : toute app créée depuis le chantier
  multi-dev) : `validate-app.sh` (contrôle de sûreté pour l'app d'un développeur, portes de
  qualité pour tous), construction pendant que l'ancienne version tourne, **tests backend**
  (`app-test.sh` — un test rouge arrête tout et laisse l'ancienne version en service), client
  Keycloak, schéma, démarrage `--no-build`, test de cloisonnement ;
- **app historique** (sans ligne `.owners`, les douze apps d'origine) : `clean2.sh <app>`
  (l'app est coupée), démarrage de `sso-lab` s'il le faut, `create-app-client.sh <app>`,
  `ensure-schemas.sh <app>`, `recompose_docker.sh --app <app> --force`. **Aucun test n'est
  joué** sur ce chemin (to_do_global.md, T1).

> `setup2.sh <app>` déploie **l'arbre de travail** du dossier, tout ce qui y a été commité ou
> modifié depuis le dernier déploiement — pas seulement ce qu'on voulait changer. Pour un
> changement de configuration seule : `bash scripts/app-restart.sh <app>`.

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

**Avec une IA** — chaque projet a son **espace de travail** (un VS Code par projet, ouvert depuis
la page du projet dans `lab-admin`, avec Claude Code et Mistral Vibe, sans Docker ni accès à
l'hôte) et une **adresse d'essai** `https://DOMAIN/dev-<uid>/` qui sert le dossier de travail
non commité (`lab-essai` dans l'espace). Chaque projet porte `FEUILLE_DE_ROUTE.md`, `CLAUDE.md`
et `AGENTS.md` (règles imposées, gabarits dans `_templates/regles/`). `code-server`
(`https://DOMAIN/code/`) monte tout le dépôt et le socket Docker : il est réservé à `admins`.

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
`oauth2-proxy` (`OAUTH2_PROXY_ALLOWED_GROUPS=admins` — `developers` en a été retiré le
2026-10-11 : y entrer vaut un accès root à l'hôte). Tourne en `--auth=none` sur son propre
réseau `code-net`, partagé avec `oauth2-proxy-code` seul, et n'a **aucune protection propre** —
retirer oauth2-proxy l'exposerait nu, avec un terminal ayant accès au Docker de l'hôte.

**API appelable par d'autres apps du lab — `KEYCLOAK_TRUSTED_CLIENTS`.** Le contrôle `azp`
suppose un client unique. Pour une API qui doit être appelable par d'autres apps au nom de leurs
utilisateurs (ex. `storage`, voir [3](#3--gestion-des-fichiers)), remplacer l'égalité stricte
par une liste blanche explicite dans `.env` : `KEYCLOAK_TRUSTED_CLIENTS=storage,carto-lab,...`
(défaut : uniquement le client de l'app elle-même). Toutes les apps du lab partagent le même
`DOMAIN` (seul le chemin Caddy change) → un tel appel est **same-origin**, aucun CORS à gérer,
seul `azp` bloque. Aucun changement côté Keycloak requis pour ajouter un client de confiance.

> Exception : `oauth-hub` tient cette liste **en base**, éditable par les devs depuis sa page
> « Apps autorisées » — chez elle, la variable `.env` n'est plus lue à l'exécution. Motivation et
> garde-fous : `oauth-hub/README.md`, « Étape 0 — se faire autoriser ».

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
[1.2](#12-installation) pour la liste complète). Règles à respecter :

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
structure de navigation communes, baptisées **Foyer** — déployée intégralement le 2026-07-30 sur
les onze apps d'alors et sur les templates de scaffold. **Toute nouvelle app créée via
`new-app.sh` hérite de Foyer sans travail supplémentaire**, puisque le pattern vit dans
`_templates/` : les apps créées depuis (`code-route`, `craft-lab`, `bilan-thermique`,
`oauth-hub`) en héritent donc d'origine.

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

> Le cahier des charges d'origine (`to_do_ui_foyer.md`) a été **supprimé de la racine** une fois
> le déploiement terminé (commit `4d0478d`) : la référence exécutable est désormais
> `_templates/django-angular/frontend/`, dont toute app scaffoldée est la copie. Pour faire
> évoluer Foyer sur une app **existante**, lire d'abord son composant de navigation actuel et son
> `app.routes.ts` — et répercuter toute évolution du système lui-même dans `_templates/`, sous
> peine de désynchroniser les futures apps.

### 2.5 Sous-modules existants et comment les utiliser

| App | Dépôt | Ports (back/front) | Groupe(s) requis | Instance DB | Description |
|---|---|---|---|---|---|
| `lab-admin` | [Sacha37420/lab-admin](https://github.com/Sacha37420/lab-admin) | 8083 / 4201 | `admins`, `developers` (administration : `admins`) | postgres (`lab`) | Portail du lab multi-dev : Accueil, Services, Projets (création, déploiement et tests par le moteur, adresse d'essai, spécifications), Nouvel utilisateur |
| `conciergerie` | [Sacha37420/conciergerie](https://github.com/Sacha37420/conciergerie) | 8084 / 4202 | `proprietaires`, `admins` | postgres | Gestion locative : biens, frais, co-propriétaires, sync réservations, bilan de capital |
| `analyse-lora` | [Sacha37420/analyse-lora](https://github.com/Sacha37420/analyse-lora) | 8086 / 4204 | `developers`, `amis`, `famille` | postgres | Suivi de capteurs LoRa : relevés, mesures, droits par capteur |
| `app-builder` | [Sacha37420/app-builder](https://github.com/Sacha37420/app-builder) | 8087 / 4205 | tous **sauf** `proprietaires` | postgres | Éditeur visuel de specs d'apps (modèles, endpoints, pages, pipelines) |
| `restauration` | [Sacha37420/restauration](https://github.com/Sacha37420/restauration) | 8088 / 4206 | `manager`, `cuisinier`, `serveur` | postgres | Gestion de restaurant : fournisseurs, recettes, commandes, paiements, planning, analyses de ventes |
| `traitement-de-fichiers-compils` | [Sacha37420/traitement-de-fichiers-compils](https://github.com/Sacha37420/traitement-de-fichiers-compils) | 8089 / 4207 | `developers` | postgres | Atelier de fichiers dans le navigateur (images, PDF, vidéo), OCR Mistral par le serveur, dépôt dans storage et partage par email |
| `arbre-genealogique` | [Sacha37420/arbre-genealogique](https://github.com/Sacha37420/arbre-genealogique) | 8090 / 4208 | *(aucun — ouvert à tout compte du realm ; autorisation par arbre via `Tree.owner_email`/`is_public`/`TreeShare`)* | postgres | Arbre généalogique : personnes, relations, périodes d'union |
| `carto-lab` | [Sacha37420/carto-lab](https://github.com/Sacha37420/carto-lab) | 8091 / 4209 | `developers` | **postgis** (dédiée) | SIG : import de cartes, systèmes de coordonnées, calculs géo, météo France |
| `storage` | [Sacha37420/storage](https://github.com/Sacha37420/storage) | 8093 / 4211 | `famille`,`amis`,`developers`,`admins`,`manager`,`cuisinier`,`serveur`,`proprietaires` (tous — API interne au lab) | postgres | Stockage de fichiers du lab : espaces personnels, partages par groupe, API consommée par les autres apps |
| `atelier-3d` | [Sacha37420/atelier-3d](https://github.com/Sacha37420/atelier-3d) | 8092 / 4210 | `developers`, `famille`, `amis` | postgres | Reconstruction 3D (COLMAP+OpenMVS, CPU-only), impression 3D, mouvements, sémantique de bâtiment |
| `robot-lab` | [Sacha37420/robot-lab](https://github.com/Sacha37420/robot-lab) | 8094 / 4212 (+ `engine` 8095) | `developers` | postgres | Robots de navigation web (Playwright + Claude/Mistral) : enregistrement de parcours, assistant IA, exécution + téléchargements |
| `code-route` | [Sacha37420/code-route](https://github.com/Sacha37420/code-route) | 8096 / **4200** | tous les groupes | postgres | Apprentissage du code de la route : fiches, quiz thématiques, bilan personnalisé, génération IA de questions (+ Celery) |
| `craft-lab` | [Sacha37420/craft-lab](https://github.com/Sacha37420/craft-lab) | 8097 / 4213 (+ `relay` 8098) | `famille`, `amis`, `developers` | postgres | Jeu de construction/survie 2D multijoueur : catalogue objets/monstres/cartes, génération procédurale, combat, artisanat |
| `bilan-thermique` | [Sacha37420/bilan-thermique](https://github.com/Sacha37420/bilan-thermique) | 8099 / 4214 | `developers`, `famille`, `amis` | postgres | Simulation thermique de bâtiment : 1D, 3D sur maillage, ombrage, météo, environnement IGN (+ Celery) |
| `oauth-hub` | [Sacha37420/oauth-hub](https://github.com/Sacha37420/oauth-hub) | 8100 / 4215 | tous les groupes | postgres | Coffre des identifiants OAuth2 de sites externes (GitHub, GitLab…) et distribution de jetons aux apps autorisées |
| `peripheriques` | [Sacha37420/peripheriques](https://github.com/Sacha37420/peripheriques) | 8101 / 4216 | tous les groupes (droits fins par email, en base) | postgres | Droits sur les caméras, le micro et le haut-parleur de l'hôte (flux tenus par `lab-media/`, ICE 8189) : direct WebRTC/HLS, relecture, enregistrement réglé webcam par webcam, « Parler » |
| `test-video` | [Sacha37420/test-video](https://github.com/Sacha37420/test-video) | 8102 / 4217 | `admins`, `developers` | postgres (`dev_sacha`) | Didacticiel du cadriciel (chapitres, exercices) — jamais déployé ; seule app à portes (`.owners`) |

> `code-route` est la seule app dont le port frontend (**4200**) est en dessous du plancher
> habituel des suggestions de `new-app.sh` — valeur historique, à ne pas « corriger ».

**Toutes les apps sont migrées vers le stockage de fichiers partagé** (`storage`, voir
[3](#3--gestion-des-fichiers)) — plus aucune app n'a de volume média privé ni de blob de
fichier utilisateur en base (revue complète des sous-modules le 2026-07-30, portant alors sur
les onze apps existantes ; les apps créées depuis appellent l'API `storage` d'emblée).

**Utiliser une app existante** :
```bash
git submodule update --remote --merge      # mettre à jour tous les pointeurs de sous-module
bash scripts/setup2.sh <app> --yes         # (re)déployer
bash scripts/clean2.sh <app>               # arrêter
```
Le code de chaque app vit intégralement dans son propre dépôt GitHub — `deploiement/<app>/` (ou
`<service>/` à la racine pour lab-admin, storage, oauth-hub, app-builder) est un dépôt git
ordinaire ; `dev/` ne fait que référencer un commit précis via le pointeur de sous-module.
Sauf pour `app-builder`, `lab-admin`, `oauth-hub` et `storage`, les dossiers d'apps sont dans
`deploiement/` (colonne « App » ci-dessus = nom du dossier).

> `storage`, `code-route` et `oauth-hub` requièrent volontairement **tous** les groupes existants
> du realm. Une app « ouverte à tout compte du realm » se déclare ainsi — par la liste complète des
> groupes — et non en laissant `--require-group` vide, ce qui laisserait aussi passer les
> auto-inscrits sans groupe.
>
> ⚠️ Corollaire : **tout nouveau groupe LDAP doit être ajouté au `.keycloak-client-opts` de ces
> trois apps** (et à `KEYCLOAK_REQUIRED_GROUPS` de leur `.env`), sinon ses membres sont refusés à
> tort. `app-builder` illustre la dérive : il lui manque `proprietaires`, ajouté au realm après sa
> création.

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
| Compte de service `<app>-admin` (`KEYCLOAK_SERVICE_WRITE_SHARES` : un partage ; `KEYCLOAK_SERVICE_WRITE_PREFIXES` : un préfixe de chemins — c'est le cas des quatre apps citées ici, `restauration-admin` seul est sous `…_SHARES`) | L'app décide seule de l'autorisation ; pas de token utilisateur à forwarder | `conciergerie` (un partage par bien), `traitement-de-fichiers-compils` (autorisation portée par les modèles de l'app), `arbre-genealogique` (idem + purge best-effort par signal `post_delete`), `atelier-3d` (worker Celery, écrit longtemps après la requête HTTP) |
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

**Détail complet des six migrations déjà réalisées** (mapping champ par champ, pièges évités,
volumes de données réelles transférées) : voir `CLAUDE.md`, section « Base de données — deux
instances PostgreSQL », sous-section « Fichiers rasters / médias (apps avec upload) », pour
`conciergerie`, `carto-lab`, `restauration`, `traitement-de-fichiers-compils`,
`arbre-genealogique` et `atelier-3d`.

---

## 4 — Gestion des bases de données

`infra/docker-compose.yml` héberge **deux instances PostgreSQL séparées**, jamais une par app :

| Instance | Container | Image | Rôle d'administration | Bases applicatives |
|---|---|---|---|---|
| `postgres` | `dev-postgres` | `postgres:16-alpine` | `devuser` (base `devdb`, vide) | `lab` (services du cadriciel), `dev_<uid>` (une par développeur) |
| `postgis` | `dev-postgis` | `postgis/postgis:16-3.5` | `gisuser` (base `gisdb`, vide) | `gis_<uid>` (apps SIG d'un développeur — aujourd'hui `carto-lab`) |

**Qui se connecte à quoi** :
- `devuser` / `gisuser` sont les superutilisateurs de leur instance. **Aucune app ne s'en sert** :
  seuls les scripts, par le socket local du conteneur (`docker exec`).
- Les services du cadriciel restés à la racine (`lab-admin`, `storage`, `oauth-hub`,
  `app-builder`) partagent la base **`lab`**, rôle `lab`, un schéma chacun.
- Chaque app de `deploiement/` vit dans la base de **son propriétaire** : `dev_<uid>` (rôle
  `dev_<uid>`), ou `gis_<uid>` sur l'instance PostGIS, un schéma par app.
- Ces rôles ne sont pas superutilisateurs, et `CONNECT` est retiré à `PUBLIC` sur chaque base :
  un rôle n'entre que dans la sienne. `pg_hba.conf` exige un mot de passe sur le réseau.
- Mots de passe : `infra/.env` pour `devuser`/`gisuser` ; **`infra/dev-roles.env`** (600) pour
  `lab` (`LAB_PG_PASSWORD`) et les développeurs (`DEV_PG_PASSWORD__<uid>`,
  `DEV_GIS_PASSWORD__<uid>`). `reset_url.sh` ne donne à chaque unité que celui de son rôle.

```bash
bash scripts/dev-db.sh ensure-lab            # rôle et base lab
bash scripts/dev-db.sh ensure <uid> [--gis]  # rôle et base(s) d'un développeur
bash scripts/dev-db.sh ensure-all            # tout rejouer depuis dev-roles.env (volume recréé)
bash scripts/dev-db.sh status lab|<uid>      # lecture seule
bash scripts/rotate-db-password.sh --yes     # rotation à chaud (--only admin|gis|lab|devs)
```

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

**Choisir l'instance pour une nouvelle app** : `new-app.sh` pose la question en dernier (voir
[2.1](#21-la-méthode-standard)), défaut `postgres`. Ne choisir `postgis` que si l'app manipule
réellement des données géospatiales — pas par précaution.

**Schémas** : un schéma par app, dans la base que désigne son `.env` (`DB_NAME`, `DB_USER`,
`DB_SCHEMA`). `infra/init*/00_schemas.sql` ne crée plus rien : c'est `ensure-schemas.sh` (appelé
par `new-app.sh` et avant chaque déploiement) qui crée le schéma, avec pour propriétaire le rôle
de l'app. Il refuse de le créer si l'app d'un développeur désigne une autre base que la sienne.

**pgAdmin** : login interne désactivé, uniquement Keycloak (OAuth2), accès réservé au groupe
**`admins`** (`infra/pgadmin/config_local.py`), joignable par tunnel SSH seulement (port lié à
`127.0.0.1`). Son client Keycloak (`infra`) est créé par `install.sh`
(`create-app-client.sh infra --port 5050 --redirect-path /oauth2/authorize`), qui écrit
`KEYCLOAK_CLIENT_SECRET` dans `infra/.env`. ⚠ Sur la machine en service ce client est
**désactivé** depuis le 2026-11-01 : le pgAdmin partagé ne se connecte plus (décision en attente,
to_do_global.md). Chaque développeur a par ailleurs son propre pgAdmin, ouvert sur sa seule base,
depuis `lab-admin`.

> ⚠️ **Après une migration qui supprime une colonne de blobs** (voir [3](#3--gestion-des-fichiers)) :
> `DROP COLUMN` ne fait que marquer la colonne supprimée, les données TOAST restent jusqu'à une
> réécriture de table. Lancer `VACUUM FULL <schéma>.<table>` derrière — sans ça, la base et ses
> sauvegardes gardent exactement le poids qu'on cherchait à retirer (constaté :
> `traitement_de_fichiers_compils.fichiers` 20 Mo → 64 ko ;
> `arbre_genealogique.media_objects` 6,4 Mo → 80 ko après `VACUUM FULL`).

---

## 5 — Annexes

### Services et ports

| Service | Port sur l'hôte | URL HTTPS |
|---|---|---|
| Keycloak | 8080, lié à `127.0.0.1` (tunnel SSH) | `https://DOMAIN/auth/` (realms ; ni la console ni `master`) |
| phpLDAPadmin | 8081, lié à `127.0.0.1` (tunnel SSH) | — |
| pgAdmin partagé | 5050, lié à `127.0.0.1` (tunnel SSH) | — |
| OpenLDAP | 389, lié à `127.0.0.1` | — |
| PostgreSQL / PostGIS | aucun (5432 interne à `dev-net`) | — |
| code-server | — | `https://DOMAIN/code/` (réservé `admins`) |
| Espaces de travail | — | `https://DOMAIN/ws/<uid>/` (passerelle `lab-ws-gateway`) |
| Adresse d'essai d'un dev | — | `https://DOMAIN/dev-<uid>/` |
| `edge-router` | 80, 443 sur toutes les interfaces | — |
| `lab-media` (ICE WebRTC) | 8189 udp/tcp sur toutes les interfaces | — |

Tout autre port publié est lié à `127.0.0.1` (`"${LAB_BIND_ADDR:-127.0.0.1}:…"` dans chaque
compose ; `0.0.0.0` seulement en HTTP local sans domaine). Ports applicatifs : voir le tableau
[2.5](#25-sous-modules-existants-et-comment-les-utiliser). URL frontend `https://DOMAIN/<app>/`,
API `https://DOMAIN/<app>-api/`.

### Vitrine publique vs outils d'administration

`.app-descriptions` (racine) pilote **uniquement** la page 404 publique, servie **sans
authentification** — y ajouter une app publie son nom et sa description à tout visiteur.
Régénérer après modification : `bash scripts/complete_404.sh`.

Les **outils d'administration** (page « Projets » de `lab-admin`, tests de cloisonnement joués
par le moteur, `add-user.sh`) affichent en revanche **toutes** les apps réellement déployées — toute entrée de
`.ports` dont le dossier contient un `docker-compose.yml`, indépendamment de
`.app-descriptions`. Une app hors vitrine est signalée par une étiquette « hors vitrine » dans
`lab-admin`, jamais masquée.

### Utilisateurs LDAP

| Utilisateur | Groupes | code-server |
|---|---|---|
| sacha | developers, admins, famille, amis, manager, cuisinier, serveur, proprietaires | ✓ |
| hassan | developers, amis | ✗ (`admins` seul) |
| lea | famille, amis | ✗ |
| elodie | famille, manager, proprietaires | ✗ |
| sabrina | manager | ✗ |
| bruno | proprietaires | ✗ |
| marie | famille | ✗ |
| fannie | proprietaires | ✗ |

`e2e_member` (membre de tous les groupes **sauf `admins`** depuis le 2026-11-01 — `admins` ouvre
`/code`, donc l'hôte) et `e2e_outsider` (membre d'**aucun** groupe) sont deux comptes
synthétiques réservés aux tests E2E — voir ci-dessous. Un troisième, `e2edev` (`developers`
seul), sert au parcours « développeur » de `lab-admin`. `e2e_member` porte une adresse
**factice** `e2e_member@ssolab.local` : sans claim `email`, `api/authentication.py` lui refuse
tout appel API et il ne permettrait de tester que l'accès à la page. Le domaine `.local` est ce
qui rend l'ajout sûr (aucun email réellement envoyé, adresse marquée vérifiée d'office).
`e2e_outsider` n'en a délibérément pas : il n'a jamais à dépasser le refus de cloisonnement.

> ⚠️ Ce tableau est le reflet de `sso-lab/ldap/init.ldif`, **non versionné** (voir
> [1.2](#12-installation)) : une installation neuve part de `init.ldif.example`. Tout
> **nouveau groupe** y ajouté doit inclure `e2e_member` (jamais `admins`), sans quoi le test de
> cloisonnement de toute app utilisant ce groupe échoue à tort.

### Tests end-to-end (Playwright)

Une app a **un seul fichier** de test, à cet emplacement et sous ce nom exact :
`<app>/frontend/e2e/cloisonnement.spec.ts` (copié tel quel depuis
`_templates/django-angular/frontend/e2e/cloisonnement.spec.ts`, sans adaptation — c'est sa règle
de conception : il ne doit dépendre d'aucun contenu propre à l'app). Il automatise le test manuel
de cloisonnement : membre du groupe requis passe, non-membre refusé, non-membre avec session SSO
déjà active refusé aussi.

Le spec est présent dans toutes les apps où il s'applique. **Deux apps n'en ont pas, à
dessein** : `arbre-genealogique` (aucun groupe requis) et `traitement-de-fichiers-compils` (page
publique, atelier dans le navigateur) ; leur feuille de route porte la ligne
`cloisonnement : aucun — <raison>`, et leur protection est tenue par leurs tests backend. Pour
elles le runner répond `[]` : cela veut dire « aucun test trouvé », **jamais** « tout va bien ».

- **`runner/`** (racine, comme `infra/`/`sso-lab/`) : conteneur unique Playwright + Chromium
  pour tout le lab, réseau `sso-net` uniquement, jamais exposé. Il joue **toujours le spec du
  gabarit** (le fichier de l'app n'est qu'un signal de présence, jamais chargé).
- **Qui lance les tests** : le moteur `lab-mcp`, et lui seul — après chaque déploiement par le
  chemin à portes, à la demande depuis la page d'un projet de `lab-admin` (ou l'outil MCP
  `run_tests`), et pour tous les projets par « Tout tester ». Dernier verdict par app :
  `.lab-state/tests/<app>.json`. Un seul run à la fois, lab-wide (409 si occupé). L'ancien
  catalogue, la page « Debug » et le worker Celery de `lab-admin` sont supprimés.
- Exception : `storage/frontend/e2e/gestes.spec.ts` (25 gestes), joué à la main par
  `storage/frontend/e2e/jouer-gestes.sh`, jamais par le moteur.

### Réseaux Docker

| Réseau | Utilisé par |
|---|---|
| `sso-lab_sso-net` | Keycloak, LDAP, Caddy, oauth2-proxy, toutes les apps, `runner/` |
| `sso-lab_code-net` | `code-server` et `oauth2-proxy-code` **seulement** (rien d'autre ne doit joindre code-server) |
| `dev-net` | PostgreSQL, PostGIS, pgAdmin, Keycloak (base `keycloak`), backends Django |
| ponts `lws…` | espaces de travail (`ws-<uid>`) : ni l'hôte ni un autre pont Docker, sauf 80/443 (règles posées par le moteur) |
| `edge-net` | Répartiteur partagé entre cadriciels (`~/edge-router/`) — Caddy uniquement, voir [1.5](#15-plusieurs-cadriciels-sur-une-même-ip-wan--le-répartiteur) |

### Scripts utiles

Tous lancés avec `bash scripts/<nom>` depuis la racine `dev/` (résolvent eux-mêmes la racine).

| Script | Rôle |
|---|---|
| `install.sh [--check]` | Installation rejouable du lab ; `--check` ne fait rien et dit ce qui manque ; `--modules a,b`, `--all-modules` |
| `lab-modules.sh list\|show\|plan\|selection\|settings\|prepare` | Modules du lab : catalogue et état, vérification, plan d'installation, sélection mémorisée (voir 1.6) |
| `module-hook.sh <module> [--check]` | Joue le `install.sh` déclaré par un module (appelé par `setup_unit.sh`, avant le build) |
| `lab-doctor.sh` | Bilan de santé en lecture seule : installation, bases, sauvegarde, Keycloak, ports, conteneurs, cloisonnement, disque |
| `backup.sh [--check\|--list\|--local]` | Sauvegarde nocturne : bases, annuaire, volumes, configuration hors dépôt ; copie locale et NAS |
| `backup-cron.sh [--check]` | Planifie `backup.sh` dans la crontab (rejouable) et vérifie les prérequis de la copie NAS |
| `new-app.sh [--owner <uid>]` | Scaffold d'une nouvelle app dans `deploiement/` (appelé par le moteur) |
| `app-register.sh`, `app-sync.sh`, `app-remote.sh`, `app-status.sh`, `app-logs.sh`, `app-env.sh`, `app-test.sh`, `app-smtp.sh`, `app-restart.sh`, `app-remove.sh`, `app-relocate.sh` | Commandes d'exploitation d'une app, celles que le moteur exécute ; usage en tête de chaque fichier |
| `app-preview.sh up\|down\|status <uid> [app]` | Adresse d'essai d'un développeur (`/dev-<uid>`) |
| `validate-app.sh <app>`, `check-app-name.sh <nom>` | Contrôle de sûreté d'un dépôt avant déploiement ; règles de nommage |
| `dev-db.sh ensure\|ensure-lab\|ensure-keycloak\|status\|hba-status\|…` | Rôles et bases par propriétaire, base du cadriciel, base de Keycloak |
| `lab-lock.sh <commande>` | Exécute sous le verrou de déploiement (code 75 si occupé) |
| `workspace-image.sh build\|check` | Image `lab-workspace` des espaces de travail |
| `storage-shares.sh [--check]` | Partages de groupe de `storage` attendus par les apps |
| `edge-router-install.sh` | Pose `~/edge-router/` depuis `edge-router.example/` s'il n'existe pas |
| `keycloak-nonce-compat.sh` | Scope `nonce-keycloak-js-22` (keycloak-js 22 ↔ Keycloak 26), idempotent |
| `setup2.sh [<app>] --yes` | Déploiement complet (une app, ou tout le lab en parallèle) |
| `setup_unit.sh <app> --yes` | Pipeline complet d'une seule app (utilisé par `setup2.sh`, appelable seul) |
| `create-app-client.sh <app>` | Créer/mettre à jour le client Keycloak seul (`--native-redirect`, `--pkce`, `--prune-uris`, `--no-env`) |
| `ensure-schemas.sh <app>` | Rattraper à chaud le schéma Postgres manquant |
| `recompose_docker.sh --app <app>` | Rebuilder et redémarrer les containers |
| `clean2.sh <app>` | Arrêter et supprimer les containers d'une app |
| `reset_url.sh` | Propager LAN/WAN/Keycloak/domaine dans tous les `.env`, valider la config réseau |
| `open-freebox-ports.sh` | Redirections de ports (HTTP/HTTPS) sur une Freebox : `authorize`, `status`, `apply` |
| `open-bbox-ports2.sh` | Ouvrir les ports adaptés (HTTP/HTTPS) sur une Bbox |
| `get-ports-list.sh` | Régénérer `ports.env` depuis `.ports` |
| `complete_404.sh` | Régénérer `sso-lab/fallback/html/404.html` depuis `.app-descriptions` |
| `init-secrets.sh` | Générer des mots de passe forts |
| `add-user.sh` | Créer un utilisateur LDAP + l'assigner à des groupes |
| `dev-enroll.sh`, `work-clone.sh` | Inscription d'un développeur, clone de travail d'un projet (appelés par le moteur) |
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
├── .gitignore               ← ignore les .env, .ports, ports.env, ldap/init.ldif
├── .ports                   ← registre des ports (géré par new-app.sh) — non commité
├── .app-descriptions        ← vitrine publique (page 404)
├── .env / bbox.env          ← non commités
├── infra/                   ← PostgreSQL + PostGIS + pgAdmin  [restart: always]
│   ├── docker-compose.yml
│   ├── dev-roles.env            ← mots de passe des rôles lab, keycloak, dev_<uid> — NON commité
│   └── init/ / init-postgis/    ← ne crée plus aucun schéma (ensure-schemas.sh s'en charge)
├── sso-lab/                 ← Keycloak + OpenLDAP + Caddy + fallback + oauth2-proxy + code-server
│   ├── docker-compose.yml
│   ├── ldap/init.ldif           ← utilisateurs et groupes LDAP — NON commité
│   ├── ldap/init.ldif.example   ← gabarit versionné, à copier au 1er clone (voir 1.2)
│   └── caddy/Caddyfile
├── runner/                  ← Playwright + Chromium partagé (tests E2E)
├── _templates/               ← templates copiés par new-app.sh
│   ├── django-angular/
│   ├── django-only/
│   └── angular-only/
└── deploiement/<app>/       ← sous-module git (même modèle pour chaque app)
    ├── .env / .env.example
    ├── .keycloak-client-opts    ← --require-group, port, chemin Caddy
    ├── docker-compose.yml
    ├── backend/ / frontend/
    ├── FEUILLE_DE_ROUTE.md       ← lots, statuts, commande de test (lue par validate-app.sh et app-test.sh)
    └── frontend/e2e/cloisonnement.spec.ts   ← voir « Tests end-to-end »
```

> **Journal de bugs** : les pièges rencontrés et leurs leçons sont dans `CLAUDE.md`, section
> « Pièges constatés » (l'ancien dossier `.debug/` y a été réuni le 2026-11-11).

---


## 6 — Travail automatique de Claude — les sessions de nuit

Chaque nuit, Claude Code relit une partie du lab, corrige ce qui est petit et sûr, et ouvre des
PR **déjà testées**. **Rien n'est déployé.** Fusionner une PR et cliquer sur « Déployer » restent
des gestes humains. Ce chapitre dit comment activer ce travail, ce que fait chaque session et à
quoi elle sert, et comment se servir de ce qu'elle produit. Le détail technique est dans
`automatisation/README.md`, les règles dans `CLAUDE.md` (« Tâches de nuit »). Le contrat de
conception est dans `chantiers/nuit-auto/CONTRAT.md`.

### 6.1 Activer les sessions automatiques

La procédure est **la même pour quiconque clone le cadriciel** : chaque commande se lance
depuis la racine de son clone. `planifier` écrit dans la crontab le chemin absolu de ce clone, et
les dépôts visés (PR, clones) sont lus dans les `origin` des sous-modules du clone, jamais dans
une liste écrite en dur. Seuls les deux jetons sont propres à chaque installation.

**Prérequis** : le lab installé (`bash scripts/install.sh`, qui construit l'image `lab-workspace`
et configure le SMTP), un abonnement Claude, et des apps dont le dépôt est sur GitHub. À la fin,
`install.sh` rappelle ces étapes.

1. **Jeton Claude.** Sur l'hôte (abonnement Claude) :
   ```bash
   claude setup-token
   ```
   Puis enregistrer le jeton affiché (dossier en 700, fichier en 600) :
   ```bash
   install -d -m 700 .lab-state/auto
   ( umask 077; printf '%s\n' '<jeton affiché>' > .lab-state/auto/claude-token )
   ```
2. **Jeton GitHub à portée fine.** Sur github.com : Settings → Developer settings →
   *Fine-grained tokens*. Propriétaire : **le compte ou l'organisation qui possède tes dépôts**
   (celui des `origin`). Accès : le dépôt racine et ceux des apps. Permissions : **Contents** et
   **Pull requests** en lecture et écriture, rien d'autre (surtout pas *Administration*). Puis :
   ```bash
   ( umask 077; printf '%s\n' 'github_pat_…' > .lab-state/auto/github-token )
   ```
   Seul l'hôte s'en sert, Claude ne le reçoit jamais. Le `gh` de l'hôte n'est jamais utilisé.
3. **Vérifier.** Doit conclure « Rien ne peut attendre l'utilisateur » ; chaque ligne
   `✘ [point]` dit ce qui bloque :
   ```bash
   bash automatisation/bin/auto.sh verifier
   ```
4. **Essai** (6 tours de Claude, ni push, ni PR, ni email) :
   ```bash
   bash automatisation/bin/auto.sh lancer --tache securite --essai
   bash automatisation/bin/auto.sh etat
   ```
5. **Planifier** — c'est cette commande qui rend le travail automatique :
   ```bash
   bash automatisation/bin/auto.sh planifier --check   # ne fait rien, montre ce qui sera posé
   bash automatisation/bin/auto.sh planifier
   ```
   Elle ajoute deux lignes à la crontab de l'utilisateur, `0 0 * * *` pour `lancer` et
   `10 5 * * *` pour `rattraper`, et ne touche aucune autre ligne (la sauvegarde de 3 h reste en
   place). On utilise cron et pas une minuterie systemd utilisateur, qui demande `Linger=yes`.
6. **Arrêter** (les sessions déjà faites et leurs PR restent) :
   ```bash
   bash automatisation/bin/auto.sh planifier --retirer
   ```

Après la première vraie nuit, vérifier qu'une PR a bien été ouverte. C'est la seule preuve que le
jeton à portée fine a le droit d'écrire : l'API de GitHub rend les droits de l'utilisateur, pas
ceux du jeton.

**Sur ce lab** : les étapes 1 à 5 sont faites. L'essai a tourné le 2026-11-11, la planification
est posée depuis le 2026-11-14 et `verifier` conclut « Rien ne peut attendre l'utilisateur ».
Premier passage réel : le 2026-11-14 à 5 h 10 (rattrapage, tâche `interface` du samedi) ; puis 0 h
chaque nuit.

### 6.2 Les sessions : ce qu'elles font et pourquoi elles existent

Le calendrier est `automatisation/calendrier.conf`. Le jour compté est celui où le passage démarre
à 0 h. Chaque session reçoit `prompts/_commun.md` (les règles communes), puis le prompt de sa
tâche.

| Quand | Tâche (prompt) | Cibles | Raison d'être | Ce qu'elle produit |
|---|---|---|---|---|
| lun, mer, ven 0 h | `securite` | 2 apps, à tour de rôle | Le lab est exposé sur Internet, et une app change sans que personne relise ses vues ni ses dépendances. Cette tâche contrôle l'authentification (`azp`, groupes), les permissions vue par vue, le cloisonnement des données, les fuites (`str(exc)`, journaux), les dépendances visées par des avis publics | Corrections petites et sûres, avec un test pour chacune ; constats classés par gravité |
| mar, jeu 0 h | `metier-ux` | 2 apps, à tour de rôle | Une app peut passer ses tests et faire faux : un solde mal calculé, une règle du cahier des charges oubliée, un écran qui égare. Cette tâche confronte l'app à sa `FEUILLE_DE_ROUTE.md` et à son cahier des charges, puis vérifie que l'interface est simple | Corrections de comportement contraire à la feuille de route, tests métier ajoutés, libellés, états vides, accessibilité ; fonctionnalités nouvelles **proposées seulement** |
| sam 0 h | `interface`, puis `interface-suite` si la charge est faible | `lab-admin` et `_templates/` | `lab-admin` est la seule interface du lab multi-dev, et le gabarit est le point de départ de toutes les apps futures : un défaut là se recopie partout | Corrections dans lab-admin et le gabarit (Foyer, garde d'admin, jeton limité à `tokenBases()`) ; en phase 2, accessibilité fine, robustesse des écrans, cohérence de la langue |
| dim 0 h | `services`, puis `services-suite` si la charge est faible | Dépôt racine, `lab-admin`, `storage`, `oauth-hub`, `app-builder` | Vérifier que ce que dit `CLAUDE.md` est vrai dans le code et dans l'état du serveur (bilan `lab-doctor.sh`, liste des conteneurs, relevés par l'hôte juste avant) | Corrections hors `sso-lab/` et `infra/`, qui sont refusés ; en phase 2, **un plan sans code** : quel code répété d'app en app gagnerait à devenir un service du cadriciel ou une bibliothèque du gabarit |
| dès que les tests sont rouges | `_correction` | les mêmes | Une seule chance de réparer ou de retirer la modification fautive : mieux vaut une PR plus petite et verte qu'aucune PR | Correctif retesté ; encore rouge, il ne reste que le rapport |
| 5 h 10 | `_reprise` (par `--resume`) | les mêmes | Une session coupée à 5 h ou par la limite d'usage ne doit pas laisser un travail à moitié écrit | Rapport et modifications remis d'accord, puis la suite là où la session s'était arrêtée ; arrêt à 8 h |

Chaque tâche à tour de rôle avance dans la liste triée des apps du superutilisateur, et chaque
tâche a son propre compteur (`.lab-state/auto/rotation-<tache>`). Avec 17 apps, chaque app passe
en `securite` environ toutes les trois semaines (6 apps par semaine) et en `metier-ux` environ
toutes les quatre semaines (4 par semaine).

**La nuit lancée à la main** (exemple : `chantiers/nuit-2026-11-08/PROMPT.md`) est d'une autre
nature. C'est une consigne écrite pour une nuit, lancée depuis une session sur l'hôte en régime
chantier (skill `chantier`), qui traverse tout le lab : installation, documentation face au code,
feuilles de route, analyse de l'infrastructure. Elle convient à un **bilan d'ensemble ponctuel**
(avant d'ouvrir le lab à un autre développeur, après une grosse bascule). Les sessions
automatiques font le **travail régulier, app par app**. Son rapport est recopié dans
`rapports-auto/nuit-<date>.md`.

Limites voulues : une session ne modifie jamais `Dockerfile*`, `docker-compose*.yml`,
`nginx*.conf`, `.env*`, `.github/`, `sso-lab/`, `infra/`, `.claude/` ni `CLAUDE.md`. Elle ne
commite pas, ne pousse pas, ne déploie pas : l'hôte calcule le correctif sans réseau, le refuse
en entier s'il touche un de ces chemins, le teste, puis ouvre la PR.

### 6.3 Se servir de ce qu'elles produisent

**Où lire** :
- l'**email du matin**, envoyé à `LAB_BACKUP_EMAIL`, sinon à `SMTP_FROM` : le rapport et les PR ;
- la **PR** sur GitHub, branche `auto/<date>-<tache>` : son corps est le rapport ;
- `bash automatisation/bin/auto.sh etat`, ou `--json` pour un script : statut de chaque passage ;
- `.lab-state/auto/runs/<date>-<tache>/` : `rapport-publie.md`, `sortie/resume.json` (constats
  structurés : gravité, cible, fichier, corrigé ou non), `tests/<cible>/` (sorties des tests, motif
  d'un refus) et `journal.txt`.

**Le matin, dans cet ordre** :
1. **Statut.** `fini`, c'est terminé. `limite`, `refuse` ou `manque` : le rattrapage de 5 h 10
   s'en est chargé, lire son résultat. `echec` : le moteur n'a pas pu lancer la session (clone,
   Docker, verrou de déploiement occupé), lire `journal.txt` et relancer au besoin
   `auto.sh lancer --date <date>`.
2. **Relire le diff de chaque PR, puis la fusionner** (une PR **brouillon** signale un constat
   critique non corrigé : à traiter avant tout). Les tests sont déjà passés, mais ils ont tourné
   sur une base jetable ; un changement de comportement annoncé Ⓟ demande ta décision.
3. **Mettre à jour le pointeur** de l'app dans `~/dev`, puis déployer :
   ```bash
   git -C <dossier de l'app> pull --ff-only     # dossier donné par registry_app_dir
   git add <dossier de l'app> && git commit -m "chore: pointeur <app> après la PR auto/<date>"
   ```
   Le déploiement se fait ensuite par le bouton « Déployer » de `lab-admin` (chemin à portes,
   tests rejoués). Ne pas laisser une PR ouverte d'un passage à l'autre : le passage suivant part
   de `main` sur GitHub et ne la voit pas, ce qui donne des doublons ou des conflits.
4. **Ranger les constats non corrigés.** Ils ne vivent que dans le rapport, et rien ne les reprend
   tout seul :
   - un constat propre à une app devient un lot ou une ligne de sa `FEUILLE_DE_ROUTE.md` ;
   - un constat qui revient dans plusieurs apps (par exemple `SECRET_KEY` avec une valeur par
     défaut, pas de CSP dans `nginx.conf`, conteneur lancé en root, versions Python non
     épinglées, vus dès l'essai du 2026-11-11) se corrige **une fois, dans `_templates/`**, puis
     dans chaque app, par un chantier humain : ces fichiers sont refusés aux sessions de nuit, qui
     le signaleraient donc à chaque passage. On l'ajoute à `to_do_global.md`, en ligne datée ;
   - une décision Ⓟ va dans `to_do_global.md` tant qu'elle n'est pas prise ;
   - le plan de `services-suite` (nouveau service mutualisé) devient un chantier T de
     `to_do_global.md`, qui sera mené en régime chantier.
5. **Améliorer les sessions elles-mêmes.** Un faux constat qui revient, un point que la session
   n'a pas vu, une consigne mal suivie : on corrige le prompt concerné dans
   `automatisation/prompts/`, par une PR comme le reste. Une règle que la session découvre et
   qui vaut pour tout le lab va dans `CLAUDE.md` (et dans `_templates/regles/` si elle concerne
   toutes les apps) ; si elle peut être contrôlée par une machine, elle va dans `validate-app.sh`.
   C'est ce qui fait que la relecture suivante part de plus haut.

**Points à surveiller** :
- La sauvegarde (3 h) tourne pendant le passage de nuit (0 h à 5 h). Sur 2 vCPU, les deux
  ralentissent, sans se bloquer : Claude est limité à 1 CPU et 2 Go, les tests passent sous
  `lab-lock.sh`, la sauvegarde a son propre verrou.
- Les branches `auto/…` s'accumulent sur GitHub. On peut les supprimer après fusion ; aucune
  session ne le fait.
