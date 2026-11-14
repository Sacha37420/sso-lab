# dev/ — Guide de travail pour Claude

Dépôt parent qui héberge toutes les applications du lab (Django + Angular, Spring, Angular seul).
Les applications sont des **sous-modules git** pointant vers leurs propres dépôts GitHub (`Sacha37420/<app>`).

Démarrage/exploitation courants (clone, `.env`, HTTP local, WAN, HTTPS) : voir `README.md`,
sections 1 et 5 — ce fichier ne redocumente pas ces procédures, seulement ce qui demande un
raisonnement (règles, pièges, décisions déjà tranchées).

## Méthode de travail — travail linéaire vs chantier orchestré

Ce fichier dit **ce qu'il faut savoir** ; cette section dit **comment s'organiser**. Deux régimes,
et le choix se fait au début, pas en cours de route.

**Régime linéaire** (défaut) — un lot dans une seule app, un correctif, une question. Travailler
de bout en bout dans la session, sans subagent. C'est le bon mode pour la majorité des tâches, y
compris longues : `to_do_<app>.md` est fait pour ça.

**Régime chantier** — dès qu'au moins **deux** de ces conditions sont réunies : ≥ 3 sous-modules
ou dossiers racine touchés · création/modification d'une **interface consommée par plusieurs
parties** (schéma partagé, endpoint appelé par d'autres apps, clé `.env` lue ailleurs, convention
de nommage) · > ~2 h d'exécution estimée · sécurité du cloisonnement, `storage`, `infra/` ou
`sso-lab/` touchés.

Dans ce cas : **invoquer la skill `chantier`** (`.claude/skills/chantier/SKILL.md`) et suivre son
protocole à 3 strates — architecte (la session) → chefs de secteur (1 subagent par secteur,
parallèles) → codeurs. Points non négociables du protocole, rappelés ici parce que ce sont eux
qu'on saute :

- **Aucun subagent n'est lancé avant que `chantiers/<nom>/CONTRAT.md` existe**, avec les interfaces
  écrites et **versionnées**. On ne parallélise jamais sur du code pas encore écrit — on
  parallélise sur un contrat écrit.
- **Un secteur ne devine jamais une interface.** S'il bute dessus, il s'arrête et émet un
  amendement ; l'architecte tranche, bump la version, et **redescend le changement par
  `SendMessage` au demandeur *et* à tout secteur impacté, y compris ceux qui ont déjà rendu `OK`**.
- **Les fichiers partagés appartiennent à l'architecte seul** (`CLAUDE.md`, `.ports`, `infra/**`,
  `sso-lab/**`, `scripts/**`, le `.env` d'une autre app…). Un secteur rapporte la ligne exacte à
  ajouter, l'architecte applique tout en un seul edit groupé.
- **Les secteurs ne déploient pas** : 2 vCPU, jamais deux builds lourds ni deux `setup2.sh` en
  parallèle. Ils rapportent la commande, l'architecte séquence.

Précédent de référence : `.claude/plans/sharing-model-orchestration.md` (chantier fondation
`storage/` + un secteur par app) — écrit à la main avant l'existence de la skill, il en applique
déjà l'essentiel, il lui manquait la 3ᵉ strate et le mécanisme d'amendement.

---

## Chantiers ouverts (à traiter, pas encore faits)

### Feuilles de route en cours

- **`to_do_global.md`** (analyse du 2026-10-31) — reste à faire de tout le lab : urgences,
  bloquants avant l'ouverture à un autre développeur, chantiers transverses (T1 à T10), et un
  pointeur vers la `FEUILLE_DE_ROUTE.md` de chaque app. Les anciens `to_do_*.md` de la racine sont
  dans leur app (`storage/to_do_storage.md`, `deploiement/bilan-thermique/`, `craft-lab/`,
  `atelier-3d/`). Plusieurs phrases de ce fichier sont périmées : la liste est au § T6.
- **`storage/to_do_storage.md`** — `storage` est un service du cadriciel dont l'interface n'a presque aucun
  geste usuel de gestionnaire de fichiers (analyse du 2026-10-11 : 1 geste présent sur 27). Plan
  par lots ; décisions du propriétaire du 2026-10-11 dans le fichier. **Lots 0, 1 et 2 en
  service** : contenu actif neutralisé (`api/content_safety.py`), sélection, clavier, menu
  contextuel, suppression annulable, glisser-déposer, file d'envoi, conflits de nom. Tests :
  `python manage.py test --settings=config.settings_test api` (backend) et
  `LAB_ROOT=$PWD bash storage/frontend/e2e/jouer-gestes.sh --deploye` (25 gestes en navigateur
  réel, compte `e2edev`). `?token=` en paramètre d'URL n'est plus accepté nulle part (2026-11-01,
  chantier « failles ») : Bearer seulement, les images passent par `fetch` + `URL.createObjectURL`.
  **Neuf apps consomment son API** (les six listées plus bas, plus `code-route`, `craft-lab` et
  son propre frontend) : aucune route existante ne doit changer.
- **Sauvegardes : chiffrement à faire.** Elles tournent chaque nuit (voir « Sauvegardes ») mais
  **en clair**, par décision du propriétaire du 2026-10-12 : à brancher dans `seal()` de
  `scripts/backup.sh` (clé publique sur le serveur, clé privée chez lui).
- **Modules — décision P1 attendue** (`chantiers/modules/CONTRAT.md` § 9) : jouer ou non le
  `install.sh` de l'app d'un **développeur** (aujourd'hui : jamais ; option préparée : conteneur
  jetable `--network none`, contrôle de sûreté rejoué après).
- **Constats de relecture** (`chantiers/multi-dev/rapports/`) : tous réglés — documentation d'API
  et `.env` du conteneur nginx (gabarit, 2026-10-11), un seul lanceur de tests (le moteur), « Apps du
  lab » redirigée vers « Projets ».

### Tests : état au 2026-10-12

- **Tests backend** : toutes les apps en ont (≈ 1 500 au total), joués par `scripts/app-test.sh`
  avant la mise en service **sur le chemin à portes** (moteur). `setup2.sh` sur une app historique ne
  les joue pas (T1 de `to_do_global.md`) : la reconstruire par build → `app-test.sh` → `up -d --no-build`. Écrits par le chantier `chantiers/tests/` (contrat, rapports par
  secteur — non versionnés : ils décrivent des défauts). Ils ont révélé une trentaine de défauts
  réels, dont plusieurs trous de cloisonnement (traversée de chemin dans
  `traitement-de-fichiers-compils`, prise de contrôle d'un arbre dans `arbre-genealogique`,
  corrections lisibles pendant un quiz dans `code-route`…), corrigés et en service.
  **Restent au propriétaire** les points de comportement listés en fin de chaque rapport.
- **Patron commun** : jetons RS256 signés par une clé locale passant par la vraie classe
  d'authentification (seul le téléchargement du JWKS est remplacé), tout appel sortant simulé —
  le conteneur de test n'a que la base. Un test `expectedFailure` qui se met à passer rend la
  suite rouge : retirer le décorateur avec le correctif.
- **Test de cloisonnement navigateur** (`frontend/e2e/cloisonnement.spec.ts`) : présent partout
  où il s'applique. **Deux apps n'en ont pas, à dessein** : `arbre-genealogique` (aucun groupe
  requis) et `traitement-de-fichiers-compils` (page publique en `check-sso`, atelier dans le
  navigateur) — leur protection est entièrement dans l'API, tenue par leurs tests backend.
  Pour elles le runner répond `[]`, ce qui veut dire « aucun test », jamais « tout va bien ».
  Leur feuille de route porte la ligne `cloisonnement : aucun — <raison>`, que `validate-app.sh`
  accepte (avertissement) **pour une app du superutilisateur seulement** (2026-11-01) : un
  développeur ne soustrait pas lui-même son app au test.
- `carto-lab` teste par `--settings=config.settings_test` (base clonée de `template_postgis` :
  créer l'extension demande un superutilisateur ; la migration du rôle lecteur y est neutralisée).
- Pour lancer une suite sans tenir le verrou de déploiement ni toucher une base du lab :
  `bash chantiers/tests/essai.sh <app>` (PostgreSQL jetable, réseau fermé, code monté).

---

## Lab multi-développeurs — moteur, projets, espaces de travail

Mis en service le 2026-10-10 ; bascule des apps historiques faite le 2026-10-11 (voir « État de
la bascule » en fin de section). Contrat complet, interfaces et preuves : `chantiers/multi-dev/`
(non versionné : il décrit des points encore ouverts et ce dépôt est public).

**Ce que voit un utilisateur — `lab-admin`** (seule interface du lab multi-dev) :
- **Accueil** : présente le lab, joue l'initialisation à la première connexion, parcours en étapes.
- **Services** (a absorbé « Outils ») : Keycloak, « Ma base et pgAdmin », Email (comptes d'envoi),
  Storage, OAuth Hub, MCP ; cartes d'administration pour `admins` seulement.
- **Projets** (a absorbé « Conception ») : sections « Projets de déploiement » (`deploiement/`) et
  « Outils de dev » (cadriciel), d'après le champ `kind` du moteur ; état, version en service,
  écart avec GitHub, liens vers l'app et son VS Code ; bloc App Builder pour `admins`.
- Pour `admins` en plus : « Nouvel utilisateur ». Les anciennes routes `/outils`, `/conception`,
  `/apps-hebergees`, `/debug` et `/code` (la route Angular, pas code-server) sont des redirections.
- Toute nouvelle vue backend est d'admin tant qu'elle ne déclare rien (`IsLabAdmin` par défaut) ;
  toute nouvelle route Angular d'admin porte `adminGuard`. Les tests backend demandent un
  PostgreSQL jetable (le rôle `lab` ne peut pas créer de base) : commande en tête de
  `lab-admin/backend/api/tests.py`.

### Qui est quoi

- **Superutilisateur** : `LAB_SUPERUSER` dans le `.env` racine (`sacha`). **Jamais un groupe LDAP** :
  un compte synthétique peut être dans `admins` comme dans `developers`.
- **Développeur** : membre du groupe `developers` dont l'uid a la forme `^[a-z][a-z0-9]{1,30}$`.
  Il est inscrit (`.devs`) **automatiquement à sa première connexion à `lab-admin`** : rôle et base
  PostgreSQL `dev_<uid>`, dossier de travail. Mettre un compte dans `developers` (`add-user.sh`)
  est donc l'acte d'autorisation. `e2e_member` (tiret bas) ne peut pas être inscrit — voulu. Le parcours « dev » se teste avec
  **`e2edev`** (voir « Tests end-to-end ») ; ce compte n'a pas de compte GitHub, donc tout ce qui
  passe par GitHub (créer un projet, ouvrir l'éditeur) ne se vérifie qu'avec un compte humain.
- **Propriété d'une app** : `.owners` (`<app>:<uid>`), gitignoré comme `.ports` et `.devs`. Une app
  sans ligne est une app historique du superutilisateur.

### Les pièces

| Pièce | Où | Rôle |
|---|---|---|
| **Moteur** | `lab-mcp/` (racine, pas un sous-module), conteneurs `lab-mcp` + `lab-ws-gateway` | **Seul composant privilégié** (monte `docker.sock`). Deux entrées sur les mêmes fonctions : `/mcp` pour une IA, `/mcp/api/…` pour l'interface. Description faisant foi : `lab-mcp/API.md` |
| **Interface** | `lab-admin` | « Mes projets » et page projet : tout se fait **sans IA**. N'a ni socket Docker ni script ; son frontend appelle le moteur |
| **Espace de travail** | `workspace/` (image `lab-workspace`), conteneur `ws-<uid>` | Un VS Code par projet, à la demande : code-server (`:8080`), Claude Code, Mistral Vibe ; et un écran de conversation pour téléphone (`:8090`, `workspace/chat/`, servi sous `/ws/<uid>/_chat/`) qui relaie un agent ACP (`claude-agent-acp`, `vibe-acp`). Pas de Docker, pas de `sudo`, ni `dev-net` ni `sso-net` |
| **pgAdmin par dev** | conteneur `pg-<uid>`, relais `lab-pg-relay` (`lab-mcp/pg-relay/`) | Un pgAdmin à la demande vers la **seule** base du dev, sans mot de passe enregistré, sur un réseau interne qui ne joint que le relais PostgreSQL |
| **Comptes d'envoi d'email** | `lab-mcp/labmcp/smtp.py`, `scripts/app-smtp.sh`, `scripts/app-restart.sh` | Un dev définit ses comptes SMTP ; le lab pose les variables `EMAIL_*` de Django dans l'app. **Pas de service d'envoi** : l'app parle à son fournisseur |
| **Scripts** | `scripts/app-*.sh` (dont `app-preview.sh`), `validate-app.sh`, `check-app-name.sh`, `dev-db.sh`, `lab-lock.sh`, `lib/registry.sh` | Les seules commandes que le moteur exécute |

### Règles à ne pas rouvrir

- **Un dev n'a ni compte Unix, ni SSH, ni Docker.** Ce qui tient la séparation n'est pas l'absence
  du groupe `docker` mais `validate-app.sh` : un dépôt libre déployé par le moteur serait un accès
  root. Il refuse `privileged`, `cap_add`, `devices`, `docker.sock`, tout montage hors du dossier
  de l'app, tout réseau autre que `dev-net`/`sso-net`, tout `ports:` hors `.ports`, tout chemin
  Caddy autre que `/<app>` et `/<app>-api`, un `.keycloak-service-account-roles` non vide (rôles
  d'administration du realm), un `.env` suivi par git.
- **On ne déploie qu'un commit présent sur GitHub.** Le dev pousse ; le moteur récupère
  (`app-sync.sh`, clé de déploiement en lecture seule par dépôt, `<LAB_STATE_DIR>/deploy-keys/`),
  valide, construit, **lance les tests backend, puis seulement démarre**. Un test rouge laisse
  l'ancienne version en service (pas de `clean2.sh` ni de `down` sur ce chemin).
- **Toute app vit dans `deploiement/<app>`** (sous-module). Les nouvelles y naissent ; une app
  historique reste à la racine jusqu'à sa bascule. Ne jamais écrire `$ROOT/<app>` en dur :
  `registry_app_dir` (shell), `appDir` (`runner/lib/resolve-app.js`), `app_dir`
  (`lab-admin/backend/api/lab_groups.py`) appliquent la même règle — `deploiement/` d'abord.
- **Un déploiement ou un build à la fois sur l'hôte** : `scripts/lab-lock.sh <commande>` (code 75 si
  occupé). `setup2.sh` le prend lui-même ; ne jamais poser un `flock` à part.
- **Nom d'app** : `check-app-name.sh` (unicité, noms réservés, pas de préfixe/extension d'un nom
  existant, pas de `-api`/`-admin`, chemins Caddy réellement servis). S'applique aussi au
  superutilisateur.
- **Le jeton GitHub est toujours celui de l'appelant** (via `oauth-hub`), jamais le `gh` de l'hôte
  (il porte `delete_repo`). Pas de portée `delete_repo` : une création ratée après la création du
  dépôt nomme le dépôt vide à supprimer à la main.
- **Conteneurs auxiliaires sans `.env`** (2026-10-31) : `robot-lab-engine` et `craft-lab-relay`
  ne reçoivent que leurs variables (`environment:`). Le navigateur piloté de robot-lab passe par un
  proxy de sortie interne à l'engine (`engine/egress-proxy.js`) qui refuse toute adresse privée :
  `page.route` seul ne voit ni les redirections, ni les WebSocket, ni les Workers, ni le rebinding DNS.
  La réponse de création d'utilisateur de `lab-admin` ne porte `password` que si l'email n'est pas parti.
- **Tout port publié sur l'hôte est lié à `127.0.0.1`** (2026-11-01) : `"${LAB_BIND_ADDR:-127.0.0.1}:<hôte>:<conteneur>"`
  dans chaque compose (apps, `sso-lab`, `infra`, gabarits). `reset_url.sh` pose `LAB_BIND_ADDR=0.0.0.0`
  dans le `.env` d'une app **seulement en HTTP local sans domaine** ; avec un domaine,
  `validate_compose.py` refuse tout autre `host_ip`. Seuls restent ouverts `edge-router` (80/443) et
  l'ICE de `lab-media` (8189). Keycloak (8080), LDAP (389), pgAdmin (5050), phpLDAPadmin (8081) ne
  se joignent plus que par tunnel SSH (`ssh -L 8080:localhost:8080 …`).
- **`lab-admin` a deux niveaux** : la porte (`admins,developers`) et l'administration (`admins`,
  permission DRF par défaut `IsLabAdmin`). Toute nouvelle vue est d'admin tant qu'elle ne déclare
  rien ; toute nouvelle route Angular porte `adminGuard`. Seule exception backend (2026-11-11) :
  `/api/spec-links/<app>/` (`IsLabMember`, lignes de l'appelant seulement ; l'inventaire
  `MEMBER_ROUTES` est tenu par `DefaultDenyTests`). Ne jamais recréer `lab-admin-backend`
  sur une image antérieure au commit `c4449e8` avec `KEYCLOAK_REQUIRED_GROUPS=admins,developers`.
- **`code-server` (`/code`) est réservé au groupe `admins`** (`OAUTH2_PROXY_ALLOWED_GROUPS`,
  `sso-lab/docker-compose.yml`) : il monte tout le dépôt, le socket Docker, `~/.ssh` et
  `~/.claude` — y entrer vaut un accès root à l'hôte. Il était ouvert à `developers` jusqu'au
  2026-10-11 (constaté par audit, refermé). **Ne jamais y remettre `developers`.** `e2e_member`
  n'est plus dans `admins` depuis le 2026-11-01 (il y entrait, et le runner lit son mot de passe) :
  ne pas l'y remettre. Après un changement de groupe dans l'annuaire, le mapper LDAP de Keycloak
  (`LDAP_ONLY`) garde l'ancien état en cache : `POST /admin/realms/ssolab/clear-user-cache`.
- **Comptes d'envoi d'email (SMTP)** : mot de passe en écriture seule (jamais rendu, jamais
  journalisé) ; identifiant et mot de passe en ASCII seulement (`smtplib` échoue sur un accent) ;
  l'email d'essai ne part que vers l'adresse du compte de l'appelant et que vers Internet (jamais
  une adresse interne : le moteur servirait de sonde de `sso-net`/`dev-net`) ; rien par MCP sauf
  `smtp_status`. Aucun profil par défaut : le SMTP du lab (Keycloak) n'est jamais proposé aux devs.
  Tant que le marqueur `LAB_SMTP_PROFILE` est dans le `.env` d'une app, ses sept clés `EMAIL_*`
  sont gérées. Un déploiement ne réapplique pas un profil modifié : c'est `PUT …/smtp` qui le fait.
- **Changer la configuration d'une app sans la reconstruire** : `scripts/app-restart.sh <app>`
  (`up -d --no-build`, contrôle que l'image de chaque conteneur est la même avant et après, refus
  si l'étiquette d'image ne désigne plus ce qui tourne).
- **Mots de passe des rôles `dev_<uid>`** : `infra/dev-roles.env`, jamais `infra/.env` (c'est
  l'`env_file` de `dev-postgres` et `dev-pgadmin`). Le dev lit le sien dans `lab-admin` (bloc
  « Ma base », au clic seulement, `Cache-Control: no-store`, journalisé) — décision utilisateur
  du 2026-10-10, qui remplace « jamais de mot de passe affiché ». Personne ne lit celui d'un autre.
- **Le pgAdmin partagé (`dev-pgadmin`) est réservé au groupe `admins`** : il porte les serveurs
  `devuser`/`gisuser` (superutilisateurs) avec leur mot de passe. Un dev ouvre **le sien** depuis
  `lab-admin`. Le moteur refuse de l'ouvrir (`409 pg_trust_enabled`) tant que
  `scripts/dev-db.sh hba-status` ne rend pas `locked` : avec une ligne `trust` réseau, taper
  `devuser` dans un pgAdmin personnel donnerait le rôle superutilisateur.
- **Un espace de travail ne joint ni l'hôte ni un autre pont Docker**, sauf 80/443. Le moteur nomme
  ses ponts `lws…` et pose au démarrage dix règles (`INPUT` et `DOCKER-USER`,
  `lab-mcp/firewall/lab-ws-firewall.sh`) qui portent **toutes** `-i lws+` : elles ne peuvent
  toucher aucun autre trafic. Elles disparaissent au redémarrage de l'hôte et sont reposées par
  le moteur. Ne jamais y ajouter une règle sans ce filtre d'interface. `sshd` et la publication
  des ports ne sont pas modifiés : le superutilisateur garde son VS Code réel par SSH.

- **L'écran de conversation n'a aucune porte à lui** (2026-10-12) : `/ws/<uid>/_chat/…` passe
  par le même `forward_auth` que l'éditeur (sorte `ws`, cookie limité à `/ws/<uid>/`) et la
  décision du moteur ne dépend jamais du chemin. Dans `lab-mcp/gateway/Caddyfile`, le bloc `@chat`
  reste avant `@ws`. Le service (`:8090`) n'authentifie rien : ne jamais le joindre autrement que
  par la passerelle. Il tourne dans le conteneur d'espace existant — aucun conteneur, réseau ni
  montage en plus. Ouverture : `POST …/workspace` avec `{"target": "chat-claude" | "chat-vibe"}`.
  Essais rejouables sans rien toucher en service : `bash lab-mcp/tests/chat/run.sh`,
  `WS_IMAGE=lab-workspace:latest bash workspace/verify.sh`.
- **Dans une conversation, l'assistant demande avant d'agir** : le service impose le mode « demander »
  à chaque ouverture et reprise (Vibe démarre de lui-même en `accept-edits`, y compris en ACP).
  « Tout accepter » est un réglage par conversation, jamais actif par défaut ni mémorisé.
- **Inactivité d'un espace** : trois signes — requête par la passerelle, battement de code-server,
  `last_activity_ms` du service de conversation (ignoré s'il est absent, en erreur ou dans le futur).

### Adresse d'essai d'un développeur — `/dev-<uid>` (2026-10-13)

Chaque développeur a **une** adresse à lui, `https://<DOMAIN>/dev-<uid>/` (API : `/dev-<uid>-api/`),
qui sert le projet ouvert dans son espace **tel qu'il est dans son dossier de travail, non commité,
sans tests**, quand il le demande. Ce n'est pas un déploiement : le chemin à portes (commit poussé,
tests) est inchangé et l'essai n'y écrit rien. Contrat et rapports : `chantiers/essai-dev/`.

- **Qui le lance** : dans l'espace, la commande `lab-essai` (`lab-essai`, `status`, `stop`), les
  tâches VS Code « Lab : construire / état / arrêter l'essai » (extension intégrée à code-server,
  `workspace/vscode/lab-essai/`), ou les outils MCP `preview_deploy`, `preview_status`,
  `preview_stop` ; dans `lab-admin`, le bloc « Adresse d'essai » de la page d'un projet (actions
  réservées au propriétaire). Jamais par un push ni un webhook.
- **Tout est dans `scripts/app-preview.sh`** (`up|down|status`, lancé sous `lab-lock.sh`) ; le
  moteur ne fait que l'appeler et tenir le terme (`LAB_PREVIEW_TTL_H`, 12 h après la construction).
- **Une adresse par développeur, pas par projet** (un espace = un projet à la fois) : construire
  l'essai d'un autre projet remplace le précédent. L'essai est celui du **propriétaire** de l'app.
- **Le contrôle de sûreté reste entier** : le dossier de travail est copié (liste établie par un
  dépôt git à nous — la configuration git du développeur n'est jamais lue), réécrit **dans la
  copie** (chemin Caddy → `dev-<uid>`, conteneurs `dev-<uid>-<service>`, aucun port publié), puis
  c'est la copie réécrite qui passe `validate_compose.py` comme une app nommée `dev-<uid>`. Une
  réécriture incomplète est un refus, jamais un essai à moitié.
- **Accès : exactement les groupes requis de l'app**, par un client Keycloak propre (`dev-<uid>`,
  flow `require-dev-<uid>`, `create-app-client.sh --exact-groups` : un groupe de l'essai précédent
  perd l'accès). Un jeton de l'app en service est refusé par l'API de l'essai, et inversement.
- **Données à part** : schéma `<slug>__essai` dans la base du propriétaire (un slug d'app ne
  contient jamais `__`), gardé d'un essai à l'autre et supprimé par `app-remove.sh`. C'est une
  séparation de données, pas une barrière : le rôle `dev_<uid>` possède aussi ses autres schémas.
- **Un essai n'a ni le compte de service de l'app** (donc pas ses fichiers dans `storage`) **ni son
  compte d'envoi d'email**, ne publie aucun port, et n'existe pas sans domaine (HTTP local).
- **Les adresses du lab de l'essai (Keycloak, émetteur des jetons, serveur) sont recalculées**
  comme `reset_url.sh` les calcule, jamais reprises du `.env` de service : un projet **jamais
  déployé** garde dans ce `.env` les valeurs fictives du gabarit (`KEYCLOAK_PUBLIC_URL=
  http://VOTRE_IP_WAN:8080`, `DOMAIN=CHANGE_ME`…), et la connexion de l'essai partait vers elles
  (constaté sur `test-video`, 2026-10-15). Une valeur fictive restante fait refuser l'étape `env`.
- **`dev` et tout nom en `dev-…` sont réservés** (`check-app-name.sh`, règle 8), pour tous.
- **Règle `[image]` ajoutée à `validate_compose.py`, pour tous les déploiements** : un service
  construit ne nomme son image que `<app>-…` — sinon un dépôt pouvait poser son code sous
  l'étiquette `storage-backend` ou celle du moteur.
- **`work-clone.sh` ne lance plus aucune commande git dans un dossier de travail existant**
  (faille fermée le 2026-10-13) : le développeur écrit le `.git/config` de son clone, et un
  `git status` du moteur y exécutait `core.fsmonitor`, un filtre ou un hook avec le socket Docker
  — un accès root à l'hôte pour tout développeur. Le clone est seulement créé ; le développeur
  fait son `git pull`. **Ne jamais lancer git, côté moteur, dans un dossier qu'un développeur écrit.**
- Limites connues : app `postgis` et app à volume `external` non éprouvées ou refusées ; un chemin
  d'app écrit en dur ailleurs que dans `docker-compose.yml`, `nginx.conf` et `nginx-entrypoint.sh`
  n'est pas réécrit ; le superutilisateur ne peut construire l'essai d'un autre que par le MCP ou
  l'API, pas depuis l'interface.
- Essais rejouables : `bash scripts/tests/preview/run.sh`, `bash lab-mcp/tests/preview/run.sh`,
  `WS_IMAGE=lab-workspace:latest bash workspace/verify.sh`.
- **Non éprouvé** : le parcours complet par un développeur réel (bouton de lab-admin ou
  `lab-essai` dans un espace ouvert, avec un vrai jeton d'espace).

### De la spécification au projet — `app-builder` → `lab-admin` → moteur (2026-10-13)

`app-builder` sert à décrire une app (modèles, API, pages, pipelines, règles métier, groupes) et
à en tirer un **cahier des charges** et les **lots** de sa feuille de route. Une spécification
« prête » se construit depuis `lab-admin` → Projets → « Mes spécifications » → « Lancer la
construction ». Contrat et rapports : `chantiers/app-builder-lab/`.

- **Le contenu passe par le navigateur de l'utilisateur, avec son jeton** : lab-admin lit
  `GET /app-builder-api/api/handoff/specs/…/kit/`, puis envoie au moteur `POST /projects` avec un
  champ facultatif `seed` (`lots_md`, `cahier_des_charges_md` — `lab-mcp/API.md` §3.2). **Le
  moteur n'appelle jamais App Builder** : le seul composant privilégié ne dépend d'aucune app.
- **`/api/handoff/` d'App Builder est en lecture seule et n'est ouverte qu'à `lab-admin`**
  (`KEYCLOAK_HANDOFF_CLIENTS` dans `app-builder/.env`). Cette clé n'ouvre que ce préfixe : un jeton
  `lab-admin` reste refusé sur toute autre route. Chacun n'y voit que ses spécifications.
- **La graine ne fournit ni l'en-tête, ni la commande de test, ni le Lot 1** : le moteur garde
  ceux du gabarit et remplace ce qui suit `## Lot 2 — `. Dans `lots_md`, toute ligne commençant
  par `#` doit être un titre de lot « à faire » — une graine ne peut donc pas poser la commande
  que le lab exécute. Deux noms de fichier fixes (`FEUILLE_DE_ROUTE.md`, `CAHIER_DES_CHARGES.md`),
  contenu jamais en argument ni au journal. Si `_templates/regles/FEUILLE_DE_ROUTE.md` perd sa
  ligne `## Lot 2 — `, toute création avec graine échoue (étape `seed`, retour arrière complet).
- **Les patchs IA d'App Builder sont appliqués par le serveur** (`backend/api/patching.py`,
  historique et annulation) ; les générateurs de code de l'ancien « Aperçu » sont supprimés (ils
  produisaient `FileField`, `AllowAny`, vues sans filtre de propriétaire). Ne pas les réintroduire.
- **L'intercepteur de lab-admin ne joint le jeton qu'aux bases de `tokenBases()`**
  (`frontend/src/app/core/env.ts`) : il le joignait à toute requête, quelle que soit l'origine.
  Un appel vers un nouveau service demande d'y ajouter sa base, sinon il part sans jeton (401).
  Même garde (`core/token-scope.ts`, `carriesToken`) dans `_templates/` et toutes les apps depuis le
  2026-11-01.
- Le catalogue admin de lab-admin lit toujours les tables d'App Builder directement
  (`models_appbuilder.py`) : colonnes tenues par `test_tables_lues_par_lab_admin`.
- Essais rejouables : `bash lab-mcp/tests/seed/run.sh` (graine, sans GitHub réel),
  `bash chantiers/tests/essai.sh app-builder`, `npm run test:engine` dans `lab-admin/frontend`.
- **Non éprouvé** : une création réelle menée à son terme avec graine (demande un compte GitHub
  humain) — le vrai `new-app.sh` et le vrai `app-register.sh` n'ont pas été joués avec une graine.
- Pièges vus : `app-builder/docker-compose.yml` montait `./backend:/app` (un redémarrage mettait
  en service le dossier, hors des tests) — retiré ; un lien direct vers une page d'App Builder
  retombe sur l'accueil (défaut `redirectUri` du gabarit, voir « Pièges constatés ») ;
  `lab-runner` accumulait des processus Chromium zombies (corrigé le 2026-10-31 : `init: true`).

**App Builder v2 (chantier `chantiers/app-builder-v2/`, en service depuis le 2026-11-11 ;
non éprouvés : un vrai appel Claude/Mistral avec outils, Claude Code réel relié par MCP)** :
- **Forme universelle, additive** (migrations `0011`, `0012`) : rôles applicatifs distincts de la
  porte (`required_groups`), accès par modèle (`access` : owner/shared/group/parent/public_read/
  global), machines à états, contraintes, tâches de fond, intégrations **du lab** (liste fermée),
  API externes, extensions typées, `Endpoint.auth` (jwt/public/api_key/hmac/internal_key/ticket).
  Un accès non décrit est un **avertissement**, pas un blocage (décision de nuit : les specs
  « prêtes » d'hier le restent). Inventaire qui la justifie : `etude/01-inventaire-apps.md`.
- **L'IA écrit par des opérations atomiques, jamais par un patch JSON en texte** : outils
  `lire_elements`, `proposer_operations` (essai à blanc), `proposer_choix`, `verifier_spec`, boucle
  bornée côté serveur (6 appels, 90 s), même code pour Claude et Mistral ; seul du texte reste
  dans l'historique ; la spec part en **index compact**, lue en base, jamais depuis le navigateur.
  Une proposition s'applique par `POST /api/apps/<id>/operations/` avec `base_version` (409 si la
  spec a changé). Ne pas réintroduire `PATCH_READY`/`CHOICES_*` ni de fusion côté TypeScript.
- **Jeton d'abonnement Claude (`sk-ant-oat…`) refusé au coffre** : les conditions d'Anthropic
  réservent l'OAuth d'abonnement à Claude Code et aux applications d'Anthropic (vérifié le
  2026-11-11, code.claude.com/docs/en/legal-and-compliance). La voie « abonnement » est **Claude
  Code ou Vibe de l'utilisateur, relié au serveur MCP d'App Builder** (`POST /app-builder-api/api/mcp/`,
  jeton personnel `abt_…` haché, 90 j au plus, révocable, portée lire/écrire, éventuellement lié
  à une spec ; page `/connexion-ia`). Un `abt_` n'ouvre que `/api/mcp/` ; un jeton Keycloak n'y
  entre pas. **Limite assumée** : le jeton ne revérifie pas les groupes Keycloak de son titulaire
  pendant sa durée de vie (il ne donne accès qu'à ses propres specs). Le jeton est posé par
  l'utilisateur lui-même : ni lab-admin ni le moteur ne le transportent.
- **Passerelle** : la remise porte `fingerprint` (sha256 du contenu remis, stable tant qu'il ne
  change pas — `updated_at` change à chaque enregistrement automatique et ne sert pas de témoin) ;
  lab-admin garde le lien projet ↔ spec (`spec_links`), signale une spec modifiée et la transmet
  au projet par un **ticket** (`POST /projects/<app>/tickets`, route existante du moteur) que les
  règles d'agent font traiter avant le lot suivant. Le moteur n'a pas changé.
- Piège : `PUT /api/apps/<id>/` **recrée tous les éléments enfants avec de nouveaux ids**. Le graphe
  et les liens `edit.query` passent par une correspondance d'ids côté front (`resolveId`) ; tout
  nouveau lien par id vers un élément de spec doit en tenir compte (l'id de la spec, lui, est stable).

### Règles de développement imposées à tout projet (IA comprises)

Chaque projet scaffoldé porte `FEUILLE_DE_ROUTE.md` (lots, tests à passer par lot, « vérifié le »),
`CLAUDE.md` et `AGENTS.md` (lu par Mistral Vibe) — gabarits dans `_templates/regles/`, copie
globale dans chaque espace de travail (`workspace/regles-lab.md`). **Imposé par la machine** :
feuille de route présente et bien formée, `frontend/e2e/cloisonnement.spec.ts` présent, tests
backend verts avant mise en service, verdicts enregistrés avec chaque déploiement
(`<LAB_STATE_DIR>/deployed/<app>.json`). Non imposable : la qualité des tests écrits.

Depuis le 2026-11-14, tout projet scaffoldé porte aussi **`lab-module.json`** (description du module :
dépendances, réglages, ressources), `install.sh` et `install.bat` (squelettes, `_templates/module/`) ;
`validate-app.sh` refuse une description invalide ou un script déclaré absent (section « Modules »).

Le cadriciel suit la même discipline : toute tâche de plusieurs lots a son `to_do_<sujet>.md`
(lots, tests par lot, date de vérification), et le régime chantier garde son contrat.

### Trois règles de gabarit, valables pour toute app (2026-10-11)

- **Un frontend ne reçoit jamais `env_file: .env`** : son conteneur nginx ne lit que quelques
  variables, passées une à une par `environment:`. Le `.env` complet y mettait mots de passe de
  base et clés.
- **`/api/schema/` et `/api/docs/` n'existent qu'en `DEBUG`** (404 sinon). Ils étaient lisibles
  sans connexion, et Swagger chargeait du code d'un CDN.
- **Le serveur est `gunicorn`** (`backend/gunicorn.conf.py`, 1 processus, 8 fils), plus
  `runserver`. **Sa configuration retire `SCRIPT_NAME` de l'environnement du worker** et doit
  continuer à le faire : les `.env` portent `SCRIPT_NAME=/<app>-api`, gunicorn exige alors que
  chaque chemin commence par ce préfixe — que Caddy retire — et répond 500 à tout. Pas de journal
  d'accès : il écrirait en clair les `?key=` et `?ticket=` passés en paramètre.
- Ces trois corrections sont **en service** dans toutes les apps (2026-10-12).
- **`api/authentication.py` attrape aussi `PyJWKClientError`** : un jeton forgé avec un `kid`
  inconnu (ou un JWKS injoignable) doit donner un refus, pas une erreur 500. Défaut du gabarit,
  corrigé partout.
- **Plus d'annuaire dans le gabarit** : les routes `/api/users/` et `/api/departments/` (et la
  liste « Utilisateurs enregistrés » de la page profil) rendaient à tout membre l'adresse de
  quiconque s'était connecté. Retirées du gabarit et des quatre apps qui les portaient encore
  (2026-10-12). `/api/me/` reste ; ne pas réintroduire de liste de comptes sans règle d'accès.
- **Reconstruire sans couper** : construire l'image pendant que l'ancienne tourne, lancer
  `scripts/app-test.sh <app>` dessus, puis `up -d --no-build` — c'est l'ordre du chemin à portes.
  `setup2.sh` sur une app historique commence au contraire par `clean2.sh` (arrêt, volumes non
  externes supprimés) et laisse l'app coupée pendant tout le build.
- **Un lanceur de tests qui a besoin d'options le dit dans `FEUILLE_DE_ROUTE.md`** (section
  « Commande de test ») : `peripheriques` et `storage` exigent `--settings=config.settings_test`,
  sans quoi leurs tests prennent le `.env` de service et échouent. Les services du cadriciel
  (rôle `lab`) passent par le même rôle de test transitoire que les apps (`app-test.sh`).
- **Une amorce de test ne doit rien exécuter sur la connexion de maintenance** (base `postgres`,
  `NAME` vide) : le rôle de test n'y a que `CONNECT`. Une erreur y fait retomber Django sur la base
  de test, qu'il ne peut alors plus supprimer (« cannot drop the currently open database » après
  des tests verts — vu sur `restauration`).

### Pièges constatés

- **Redéployer par `setup2.sh` reconstruit l'image depuis le dossier** : cela met en service tout
  ce qui a été commité depuis le dernier déploiement, pas seulement ce qu'on voulait changer.
  Pendant la bascule, `analyse-lora` a ainsi reçu un commit de fonctionnalité non encore déployé,
  et `bilan-thermique` aurait reçu un commit « wip ». Pour un changement de configuration seule
  (base, variable) : `docker compose -f <dir>/docker-compose.yml up -d --no-build`, et vérifier
  que l'identifiant d'image de chaque conteneur est le même avant et après.
- **Un comparateur se teste sur un écart provoqué**, pas seulement sur un cas identique : celui de
  la bascule ne comptait qu'une table par schéma (une boucle `while read` autour de
  `docker exec -i` se fait manger son entrée) et annonçait « identique » à tort.
- **Un contrôle qui arrête une procédure au milieu laisse l'app arrêtée** : une comparaison de
  mot de passe faussée par un retour à la ligne a coupé `conciergerie` une minute. Tout contrôle
  placé après l'arrêt d'une app doit avoir été éprouvé avant, ou être suivi d'une remise en route.

- **Deux secteurs lancés en parallèle sur une API dont seules les routes étaient écrites** : le
  consommateur s'est arrêté (à raison), la forme des réponses n'existait pas. Une interface n'est
  « écrite » que si les réponses le sont ; sinon le producteur publie d'abord sa description.
- **Une règle pare-feu `--gid-owner <groupe>` ne voit que le groupe primaire**, et les ponts Docker
  ne tiennent pas tous dans `172.16.0.0/12` (`atelier3d-net` est en `192.168.16.0/20`).
- **code-server n'a pas d'option de préfixe** : c'est le proxy qui retire `/ws/<uid>`, et il doit
  transmettre l'hôte public inchangé, sinon tout WebSocket est refusé en 403. Il tient aussi un
  espace pour actif tant qu'une connexion lui reste (`keepalive off` dans la passerelle).
- **`ss … | grep -q` sous `pipefail`** déclare libre un port en écoute (`grep` sort tôt, `ss`
  reçoit SIGPIPE) : c'était dans `new-app.sh`.
- **`ss` ne voit que l'espace réseau où il tourne** : lancé par le moteur (conteneur), `new-app.sh`
  ne voyait aucun port de l'hôte et a attribué 8085/4203, tenus par `google-agenda` (`dev2/`, même
  démon Docker, registre `.ports` distinct). Premier déploiement réel d'un projet en échec
  (« port is already allocated »). La vérification interroge maintenant aussi le démon (ports liés
  par tout conteneur, démarré ou non, des deux cadriciels).
- **Fermer `CONNECT` sur la base `postgres` casse le lanceur de tests de Django** : il s'y connecte
  pour créer et supprimer la base de test (« cannot drop the currently open database », après des
  tests pourtant verts). `app-test.sh` donne ce droit à son rôle transitoire, et le lui retire
  avant `DROP ROLE` (un droit sur une base est une dépendance qui bloque la suppression du rôle).
- **Depuis un conteneur, `localhost` n'est pas l'hôte** : une sonde Keycloak sur `localhost`
  concluait à tort que le SSO était arrêté (`scripts/lib/kcprobe.sh`).
- **`vibe mcp add` sur un nom existant répond « already configured », code 0, sans rien changer** ;
  Vibe pose des dossiers en lecture seule dans `~/.vibe` (`chmod -R u+rwX` avant tout `rm -rf`).
- **Le lien direct vers une page retombait sur l'accueil** après le passage par Keycloak
  (`redirectUri = env.appUrl`) : corrigé dans `lab-admin` (`core/redirect-uri.ts` — la page
  courante, jamais un paramètre, seulement sous l'origine et le préfixe de l'app). Repris dans
  `_templates/` et toutes les apps le 2026-11-01.
- **Une exception `requests` porte l'URL demandée** : journaliser ou renvoyer `str(exc)` livre un
  lien secret (iCal Airbnb de `conciergerie`) ou une clé passée en paramètre. Rendre un message fixe.
- **Un sérialiseur appelé sans `request` dans son contexte** (tâche, commande, autre vue) ne sait pas
  qui lit : un champ masqué « sauf pour le propriétaire » doit être masqué par défaut quand
  `request` manque, jamais montré.
- **Sans `.dockerignore`, le `node_modules` de l'hôte écrase celui de l'image** (`COPY . .` après
  `npm ci`) : build qui passe avec d'autres versions que le verrou. Chaque frontend en a un.
- **Le noyau rend le commentaire d'une règle iptables entre guillemets** : un script qui cherche
  ses propres règles par leur commentaire sans en tenir compte les pose en double et ne sait plus
  les retirer (constaté sur des règles de test).
- **`lab-mcp/gateway/Caddyfile` est monté en fichier dans `lab-ws-gateway`** : une modification
  n'est lue qu'au redémarrage du conteneur (`admin off`), mais elle partira à ce redémarrage,
  voulu ou non.
- **Un espace ouvert avant une mise à jour de l'image garde l'ancienne** : y ouvrir une conversation
  attend 25 s puis donne un 502. Fermer l'espace et le rouvrir.
- **`wait -n` de bash perd un enfant mort pendant qu'on attendait autre chose** : l'entrée de
  l'espace surveille ses deux services par scrutation. Elle ne fait plus `exec code-server` : le
  conteneur ne s'arrête plus à la mort de l'éditeur, il le relance.
- **`npm install` résout les dépendances transitives au jour du build** : pour tenir « publié
  depuis plus de deux semaines », verrou généré avec `--before=<date>` et installation par `npm ci`.
- **L'image pgAdmin ne démarre pas sous `cap_drop ALL` seul** (son Python porte une capacité de
  fichier) : il lui faut `NET_BIND_SERVICE`. Démarrage : 35 à 55 s.
- **L'email sert d'identité dans plusieurs apps — non résolu** (relevé de juin, repris de l'ancien
  `.debug/` le 2026-11-11) : changer l'email d'un compte dans l'annuaire rend orphelines ses
  données là où elles sont rattachées à l'email (`app-builder` : `app_specs.owner_email` et
  `mcp_tokens.owner_email` ; `traitement-de-fichiers-compils` : `utilisateurs.email` ; plus
  largement tout `owner_email` ; `google-agenda` de dev2 en clé primaire). Contournement : `UPDATE`
  de l'ancien vers le nouvel email dans une transaction, parent avant enfants. Vrai correctif :
  rattacher au `sub` Keycloak, immuable.
- **Derrière un chemin Caddy qui retire le préfixe (`handle_path`), une URL absolue part hors de
  l'app** : `/assets/…` est demandé à la racine du domaine et rend 404 (vu sur `apps.json` de
  l'ancien cadriciel, puis sur les polices Foyer). Toujours une URL relative au `base href`.
- **« Unexpected error when handling authentication request » à la connexion** : la vraie cause
  n'est que dans `docker logs keycloak` (vu : `LDAP: error code 49`, mot de passe de bind LDAP
  désynchronisé par une régénération de secrets jamais appliquée). Une édition à la main des
  fichiers `olcDatabase=*.ldif` d'OpenLDAP doit retirer leur en-tête `# CRC32`, sinon
  `slapd`/`slaptest` refusent la configuration.
- **Les appels d'administration à Keycloak passent par l'adresse interne** (`keycloak:8080` depuis
  un conteneur, `localhost:8080` sur l'hôte), jamais par l'URL publique : la box n'a pas toujours
  le hairpin NAT, et le jeton reste sur la machine.

### État de la bascule

Bascule des 16 apps historiques faite le 2026-10-11 (bases `dev_sacha`, `gis_sacha`, `lab` ;
applications dans `deploiement/`). Les anciens schémas de `devdb`/`gisdb` sont supprimés. Le moteur, la passerelle, `lab-admin` et le runner sont en
service et vérifiés avec les comptes de test. Ce qui reste à faire avant d'ouvrir le lab à un autre développeur (autorisations `oauth-hub`,
durcissement de l'hôte, bascule des 17 apps vers `dev_sacha` et `deploiement/`, parcours réel d'un
dev) est suivi dans `chantiers/multi-dev/BASCULE.md` — non versionné, à lire avant toute action
sur ce sujet. Depuis le 2026-10-11 la séparation des bases est effective pour les rôles de dev (voir « Base de
données ») ; les apps historiques aussi, depuis leur bascule (rôle `dev_sacha`, `lab` pour le cadriciel).

---

## Infrastructure partagée entre cadriciels (`dev/` / `dev2/`)

Cet hôte fait tourner **deux cadriciels indépendants** : `dev/` (ce dépôt, « lab1 ») et
`~/dev2/` (« lab2 », copie isolée avec son propre domaine/realm Keycloak/LDAP — voir
`dev2/CLAUDE.md`). Aucune donnée ni secret partagé entre les deux, à trois exceptions près :
l'hôte Docker lui-même, `code-server` (un seul conteneur, monte `/home/sacha/dev` **et**
`/home/sacha/dev2`), et **`~/edge-router/`**.

`~/edge-router/` est un répartiteur nginx (SNI pour 443, `Host` pour 80) qui aiguille le trafic
entrant 80/443 de l'hôte vers le bon Caddy (`caddy` pour `dev/`, `caddy2` pour `dev2/`) selon le
domaine demandé — sans jamais déchiffrer le TLS, chaque Caddy garde son propre ACME. C'est ce
qui permet aux deux cadriciels de partager les mêmes ports 80/443 d'une seule IP WAN. Procédure
complète, schéma et fichiers de config : `README.md` section 1.5.

**À savoir avant de toucher au réseau `edge-net` ou au service `caddy` de `sso-lab/docker-compose.yml`** :
- `~/edge-router/` vit **hors de tout dépôt git** (ni `dev/`, ni `dev2/`) — il n'apparaîtra
  jamais dans une exploration du dépôt, `git grep`, ou `git log`. S'il faut le lire/modifier,
  c'est un dossier séparé sur l'hôte (`docker-compose.yml` + `nginx.conf`), à ne jamais confondre
  avec `sso-lab/caddy/`.
  - Ne pas le recréer « proprement » dans un des deux dépôts de sa propre initiative : le retirer
    de `~/edge-router/` couperait 80/443 pour **les deux** cadriciels simultanément.
  - Depuis le 2026-10-11, `dev/edge-router.example/` en est le **gabarit versionné** (un seul
    cadriciel, emplacement commenté pour un second, aucun nom de domaine réel) et
    `scripts/edge-router-install.sh` le pose sur une machine **où il n'existe pas** — décision de
    l'utilisateur, pour qu'une installation neuve ait le HTTPS. Le script ne modifie jamais un
    `~/edge-router/` existant. Mode d'emploi pour un second cadriciel :
    `edge-router.example/README.md`.
- Le service `caddy` de `sso-lab/docker-compose.yml` ne publie plus de `ports:` — c'est **normal**
  depuis le passage en Phase C (commit `bd97ff0`), pas une régression à « corriger ». Si Caddy
  doit redevenir directement joignable en 80/443 (rollback), réajouter le bloc `ports:` et
  relancer `docker compose up -d` — ne pas toucher à `~/edge-router/` pour ça.
- `PORT_HTTP`/`PORT_HTTPS` subsistent dans `sso-lab/.env.example` et sont toujours utilisés par
  `open-bbox-ports2.sh` / `open-freebox-ports.sh` (ouverture NAT côté routeur) — sans effet sur le routage applicatif de
  Caddy désormais, mais toujours corrects pour cet usage-là, ne pas les supprimer.
- Toute modification de `edge-net` ou des `ports:` de `caddy`/`caddy2` affecte **les deux**
  cadriciels à la fois : à faire uniquement en présence de l'utilisateur, jamais en autonomie.

---

## Routeur — Freebox depuis le 2026-10-30

La box est une **Freebox Pop** (avant : Bbox), avec une **IPv4 full-stack**
obtenue depuis l'espace abonné Free : une IPv4 partagée (défaut des nouveaux abonnés) n'offre
qu'une plage de ports (16384-32767 constaté), donc ni 80 ni 443 — `open-freebox-ports.sh status`
le dit. Redirections posées par `scripts/open-freebox-ports.sh apply` (80/443 TCP, 8189 TCP+UDP
en HTTPS) :
- **L'API Freebox n'accepte pas le mot de passe administrateur** : un jeton d'application,
  obtenu une fois par `authorize` et validé sur l'écran du Freebox Server, puis le droit
  « Modification des réglages » coché dans Freebox OS (Gestion des accès → Applications →
  « Lab dev »). Jeton dans `.lab-state/freebox-app-token` (600, dans la sauvegarde) ; le perdre
  oblige à refaire `authorize` devant la box.
- Une redirection existante vers une autre machine est signalée, jamais modifiée.
- **Le NAS des sauvegardes a un bail DHCP fixe** (`truenas`, `192.168.1.136`, posé par l'API le
  2026-10-31) : il avait changé d'adresse au passage à la Freebox et la copie NAS échouait en silence
  depuis deux nuits. `LAB_BACKUP_NAS` doit suivre toute modification de ce bail.
- Changer d'IP publique : `SERVER_URL_WAN` dans `bbox.env` **et** `~/dev2/bbox.env`, puis
  `reset_url.sh` des deux côtés, `MEDIA_WEBRTC_HOSTS` à la main, et le DNS chez No-IP pour le
  domaine de **chaque** cadriciel (aucun client DDNS sur l'hôte ni dans la Freebox).

---

## Installer le lab sur une machine neuve

`bash scripts/install.sh` — rejouable ; **`--check` ne fait rien et dit ce qui manque** (c'est le
seul mode à lancer sur une machine en service, où il doit conclure « rien à faire »). Il crée les
`.env` depuis les gabarits (base selon l'emplacement : `lab` à la racine, `dev_<uid>` dans
`deploiement/`), génère les secrets restés à `CHANGE_ME`, reconstruit `.ports`, crée `edge-net`,
les rôles et bases (`dev-db.sh ensure-lab`, `ensure <superutilisateur> --gis`), ferme `CONNECT`,
déploie le cadriciel d'abord (`storage`, `oauth-hub`, `lab-admin`, `lab-mcp`) puis les apps,
construit `lab-workspace`. Détail et gestes qui restent humains (fiche GitHub d'`oauth-hub`, SMTP
de Keycloak, domaine, routeur, `~/edge-router/`) : `README.md` §1.2.

- Prouvé par morceaux (clone de test, instances PostgreSQL jetables), **jamais joué de bout en
  bout** : cet hôte ne peut pas porter un second lab. À la première vraie installation, s'attendre
  à des écarts dans les étapes de démarrage de `sso-lab`, des apps et de l'image d'espace.
- **Keycloak 26 dépend de PostgreSQL** (relu le 2026-11-08) : jusqu'à cette date, `install.sh`
  démarrait `sso-lab` (étape 7) avant `infra` (étape 8), sans `dev-db.sh ensure-keycloak` ni
  `keycloak-nonce-compat.sh` — sur une machine neuve Keycloak ne pouvait pas démarrer, et sans le
  scope les apps bouclaient à la connexion. L'étape 7 prépare maintenant la base `keycloak` (infra
  démarrée pour elle) puis pose le scope. Le témoin « sso-lab initialisé » est le volume de
  l'annuaire (`ldap-data`), dans `install.sh` comme dans `setup2.sh` (2026-11-11).
- Le superutilisateur doit exister dans `init.ldif` (membre de `admins` et `developers`) : le
  gabarit ne connaît que `sacha`, `install.sh` le signale. Le gabarit ne contient plus `dom`,
  `harem`, ni `e2e_member` dans `admins` (ils y étaient encore le 2026-11-08).
- `install.sh` planifie la sauvegarde (`backup-cron.sh`) ; `lab-doctor.sh` fait le bilan.
- **Rien de ce qui suit n'est dans un dépôt** — le perdre, c'est perdre le lab : tous les `.env`,
  `infra/dev-roles.env`, `sso-lab/ldap/init.ldif`, `.ports`, `.devs`, `.owners`, `.lab-state/`
  (clés de déploiement, comptes d'envoi), `~/edge-router/`, `~/lab-work/`, et les volumes Docker.
  `OAUTH_HUB_ENCRYPTION_KEY` en fait partie. Tout cela est dans la sauvegarde nocturne (section
  « Sauvegardes ») ; elle ne remplace pas la procédure de restauration, qui n'est pas automatisée.
- Un projet privé enregistré comme sous-module porte `update = none` dans `.gitmodules` (posé par
  `app-register.sh`) : sans cela, `git clone --recurse-submodules` avorte pour quiconque n'y a pas
  accès, et n'extrait aucun sous-module.

---

## Modules : description, dépendances, installation (2026-11-14, chantier `chantiers/modules/`)

Le lab s'installe par **modules**. Socle (`sso-lab`, `infra`, `runner`) et cadriciel obligatoire
(`storage`, `oauth-hub`, `lab-admin`, `lab-mcp`) : toujours. Facultatifs : les apps de
`deploiement/`, `app-builder`, `lab-media`. Format et commandes : `modules/README.md` ; ce qu'une app
doit fournir : `chantiers/modules/REGLES_MODULE.md` (versionné par exception au `.gitignore`).

- **Description** : `<module>/lab-module.json`, sinon catalogue central `modules/<nom>.json`, sinon
  déduite (sans dépendances). Le premier présent gagne **en entier**, sans fusion ; présent mais
  invalide ⇒ état « description invalide » et déploiement refusé (`[module]`), jamais de repli.
  Les 14 dépôts d'apps n'ont pas été touchés : tout vient du catalogue central.
- **Un seul analyseur, une seule résolution** : `scripts/lib/modules.py`, appelé par
  `scripts/lab-modules.sh` — qu'utilisent `install.sh`, le moteur (`lab-modules.sh` est dans
  `procs.ALLOWED_SCRIPTS`) et, par le moteur, lab-admin. Ne pas réécrire la résolution ailleurs.
- **`install.sh`** : choix à l'**étape 2** (avant le premier conteneur, donc visible avec
  `--check` et `--until`), déploiement à l'étape 10 dans l'ordre du plan (topologique, puis
  `priority`, puis nom). `--yes` sans `--modules` = sélection mémorisée, sinon **tous** (règle
  d'avant). Sélection : `.lab-state/modules/selection.json` (`by` = uid, jamais un email). Sans
  sélection mémorisée, `--check` le *note* et conclut quand même « Rien à faire ».
- **Réglages déclarés** (`settings`) : demandés au terminal ou saisis dans lab-admin, écrits par
  `lab-modules.sh settings` (→ `app-env.sh set`, donc jamais une clé gérée), **jamais réécrits**
  s'ils sont posés. `lib/fresh-env.sh` (sorti d'`install.sh`) laisse un réglage déclaré à
  `CHANGE_ME` au lieu de le tirer au hasard (une « clé Mistral » aléatoire n'en est pas une).
- **Scripts d'installation** (`install.sh` du module, déclaré) : joués par `scripts/module-hook.sh`
  dans `setup_unit.sh`, **après les contrôles et avant tout nettoyage ou build** — donc à chaque
  déploiement, par tous les chemins ; un échec ne coupe rien. Environnement vide, délai
  `timeout_s`. **Jamais pour l'app d'un développeur** (il tournerait avec le groupe `docker` après
  `validate-app.sh` et pourrait réécrire `docker-compose.yml`/`.env` validés) : décision P1 en
  attente du propriétaire (`chantiers/modules/CONTRAT.md` § 9). `install.bat` n'est jamais joué.
- **Moteur** : `GET /mcp/api/modules`, `GET /modules/{name}` (`?check=1`), `POST /modules/plan`,
  `POST /modules/install` — **superutilisateur seul** (jamais sur la foi d'un groupe), aucun outil
  MCP. L'installation suit le chemin de déploiement standard (`app-sync.sh` : seul un commit
  présent sur GitHub), un pas en échec ne saute que ses dépendants, et **le moteur ne se
  réinstalle jamais lui-même** (`engine_self`). Réglages : fichier 0600, chemin seul transmis.
- **Groupes** d'un module : vérifiés (Keycloak, adresse interne), jamais créés — ils viennent de
  l'annuaire.
- **Windows** : `install.bat` racine explique « non pris en charge » (hôte Linux exigé).
- Tests : `bash scripts/tests/modules/run.sh` (faux lab, sans Docker) ; il vérifie aussi que tout
  `modules/*.json` est valide, sans cycle ni dépendance inconnue.
- Écart connu : les secrets **croisés** entre deux modules (`lab-media` ↔ `peripheriques` :
  `LAB_MEDIA_APP_PERIPHERIQUES_*` / `MEDIA_*`) sont tirés au hasard séparément par `fresh_env` sur
  une machine neuve — non relié par ce chantier, à faire avant la première vraie installation.

---

## Sauvegardes

`bash scripts/backup.sh` — chaque nuit à 3 h par le cron de `sacha` (`crontab -l`). `--check` ne
fait rien et dit ce qui serait sauvegardé ; `--list` montre les copies ; `--local` saute le NAS.

- **Contenu** (un dossier daté par passage) : chaque base des deux instances PostgreSQL
  (`pg_dump -Fc`, restaurable base par base) et leurs rôles ; l'annuaire LDAP (`slapcat`) ; les
  volumes `infra_storage-media`, `sso-lab_caddy-data`, `lab-media_config`, `lab-media_state` ; et tout ce qui n'est dans aucun dépôt (`.env`, registres, `.lab-state/`,
  `init.ldif`, `~/edge-router/`, `chantiers/`). **Pas** les enregistrements de `lab-media`, ni les caches, ni
  `~/lab-work`.
- **Deux copies** : `~/sauvegardes/lab/` et le NAS (partage et compte dédié dans le `.env`
  racine : `LAB_BACKUP_NAS`, `LAB_BACKUP_NAS_USER` ; dossier `lab/` ; mot de passe dans
  `~/.lab-backup-nas`). Le NAS est joint par `smbclient` dans un
  conteneur jetable (image `lab-backup`), SMB 3 et chiffrement de transport exigés — pas de
  montage CIFS sur l'hôte.
- **Rétention** : 14 jours, plus la première du mois pendant 6 mois, des deux côtés ; appliquée
  seulement après une sauvegarde sans défaut. Sur le NAS, ce qui protège d'un effacement (serveur
  compromis) est la tâche d'**instantanés ZFS** du jeu de données, pas ce script.
- **En cas de défaut** : code 1, un email part par le SMTP du lab, rien n'est purgé. Le compte
  rendu est `RAPPORT.txt` dans le dossier du passage.
- **⚠ Non chiffrées** pour l'instant : les archives contiennent tous les secrets du lab. Ne jamais
  élargir les droits du partage de sauvegarde.
- Restauration éprouvée le 2026-10-12 depuis la copie du NAS : empreintes identiques, les six
  bases restaurées dans des PostgreSQL jetables avec le même nombre de tables et de lignes qu'en
  service. **Non éprouvé** : remonter un lab entier sur une machine neuve. Depuis
  Keycloak 26 (2026-11-01), le realm est dans la base `keycloak` de `dev-postgres`, sauvegardée avec
  les autres bases (le volume H2 de 22 n'est plus sauvegardé depuis le 2026-11-11).
- Piège : un conteneur lancé avec `--cap-drop ALL` ne lit pas un fichier `600` d'un autre
  utilisateur, même en root — le lancer sous l'identité de l'appelant (`--user`).

---

## Tâches de nuit — `automatisation/` (2026-11-11, chantier `chantiers/nuit-auto/`)

Claude Code relit les apps chaque nuit et ouvre des PR **testées** ; rien n'est déployé, la
fusion et le bouton « Déployer » restent humains. Mode d'emploi : `automatisation/README.md`.

- **Calendrier** (`automatisation/calendrier.conf`, prompts dans `automatisation/prompts/`) :
  lun/mer/ven `securite` (2 apps en rotation), mar/jeu `metier-ux` (2 apps), sam `interface`
  (lab-admin + `_templates/`), dim `services` (cadriciel) ; phase `-suite` si la charge est
  faible. cron à 0 h (`auto.sh lancer`, arrêt de lui-même à 5 h) et 5 h 10 (`auto.sh rattraper` :
  reprend la même session si limite, délai ou refus ; lance si aucun passage).
- **Claude tourne dans `lab-workspace`**, jamais sur l'hôte : `--cap-drop ALL`, réseau `lws…`
  (pare-feu des espaces : 80/443 publics seulement, LAN refusé), **sans étiquette `lab.ws`** (le
  moteur supprimerait le conteneur), `.git` du clone monté en lecture seule, **aucun jeton
  GitHub**. `--dangerously-skip-permissions` n'y est acceptable que parce que c'est le conteneur
  qui fait barrière — ne jamais le reprendre sur l'hôte.
- **Correctif** : calculé dans un conteneur `--network none`, appliqué par `git apply` dans un
  clone propre jamais monté (jamais de git de l'hôte sur un dossier écrit par Claude — même faille
  que `work-clone.sh`). Refusés : `.github/`, `.env*`, `.keycloak-*`, Dockerfile, compose, nginx,
  `.gitmodules`, liens, et pour la racine `sso-lab/`, `infra/`, `.claude/`, `CLAUDE.md`.
- **Avant la PR** : `validate-app.sh --quality-only`, commande de test de la feuille de route
  **du commit de base**, base jetable sur réseau `--internal`, `.env` assaini ; image
  `<app>-backend:auto` reconstruite si `requirements` change (pas pour une app `.heavy-build`).
  Rouge ⇒ une seule phase de correction, puis rapport seul.
- **Gestes humains** : `claude setup-token` → `.lab-state/auto/claude-token` ; jeton GitHub **à
  portée fine** (contents + pull requests) → `.lab-state/auto/github-token` (le `gh` de l'hôte,
  `delete_repo`, n'est jamais utilisé) ; `auto.sh verifier` doit conclure « Rien ne peut attendre
  l'utilisateur » avant `auto.sh planifier`. Les deux jetons sont dans la sauvegarde nocturne
  (`.lab-state/`).
- Essais sans Claude ni GitHub : `bash automatisation/tests/run.sh [unitaires]`. Le droit
  d'écriture du jeton à portée fine ne se prouve que par une vraie PR (l'API rend les droits de
  l'utilisateur, pas ceux du jeton).

**oauth-hub à l'installation** : `python manage.py provider_credentials status|set <slug>`
(secret sur l'entrée standard seulement). `install.sh` demande à la fin client_id et secret de
la fiche GitHub si elle est incomplète (terminal requis) ; `install.sh --check` et
`lab-doctor.sh` la signalent. Jusqu'au 2026-11-11, le bilan ne vérifiait que l'existence de la
ligne — toujours vraie, la migration `0002` la crée vide. Piège : l'analyseur d'arguments de
Django recopie l'argument refusé dans son message — toute commande qui touche un secret doit
avoir un message d'erreur fixe.

---

## Créer une nouvelle application

> **Voie normale depuis le 2026-10-10 : `lab-admin` → Projets → « Nouveau projet »** (ou l'outil
> `create_app` du MCP). Le moteur enchaîne tout ce que décrivent les étapes ci-dessous :
> vérification du nom, dépôt GitHub sous le compte du développeur, scaffold dans
> **`deploiement/<app>`**, ligne `.owners`, schéma dans la base du propriétaire, clé de
> déploiement, enregistrement comme sous-module, puis déploiement par le bouton « Déployer ».
> Les étapes qui suivent décrivent ce que font les scripts appelés — utiles pour comprendre ou
> dépanner, plus pour créer une app à la main. À la main, le superutilisateur passe par
> `new-app.sh --owner <uid>` puis `app-register.sh` ; l'étape 2 (dépôt + sous-module) est faite
> par `app-register.sh`, et l'app naît dans `deploiement/`, jamais à la racine.

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
- Crée `deploiement/<app>/` avec la structure complète (backend, frontend, docker-compose,
  Dockerfiles, nginx, .env, `FEUILLE_DE_ROUTE.md`, `CLAUDE.md`, `AGENTS.md`…) — `new-app.sh:170`
- Copie et adapte le template depuis `_templates/django-angular/`
- Écrit la ligne `.owners` (`--owner <uid>`, défaut : le superutilisateur) et les ports dans `.ports`
- Crée le schéma **à chaud dans la base du propriétaire** par `ensure-schemas.sh`
  (`new-app.sh:356-361`) ; `infra/init*/00_schemas.sql` n'est plus alimenté
- Crée `.keycloak-client-opts` (utilisé par `create-app-client.sh`)
- **Ne crée pas** le client Keycloak ni le dépôt GitHub

Le script demande ensuite le **groupe requis** (cloisonnement). Le laisser vide rend l'app
accessible à tout compte du realm — le script le signale bruyamment.

Enfin, pour une app avec base (Spring seul/+Angular, Django seul/+Angular), le script demande
l'**instance PostgreSQL** : `postgres` (base `dev_<uid>` du propriétaire, défaut) ou `postgis`
(base `gis_<uid>` — extension PostGIS absente de l'instance partagée, voir la section dédiée plus bas).
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

Après le scaffold, créer le dépôt GitHub (vide) puis laisser `app-register.sh` faire le reste :
`git init`, premier commit, push, enregistrement de `deploiement/mon-app` comme sous-module
(indexé, **non commité** dans le parent) et `update = none` pour un dépôt privé.

```bash
gh repo create Sacha37420/mon-app --public      # ou --private
LAB_GIT_AUTHOR_NAME="Prénom Nom" LAB_GIT_AUTHOR_EMAIL=moi@example.org \
  bash scripts/app-register.sh mon-app https://github.com/Sacha37420/mon-app.git
```

---

### Étape 3 — Remplir `.env`

```bash
nano deploiement/mon-app/.env
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

`setup2.sh <app>` délègue à `setup_unit.sh`, qui suit l'un de deux ordres (relu le 2026-11-08) :
- **app à portes** (ligne `.owners`, toute app née après le chantier multi-dev) :
  `validate-app.sh`, build pendant que l'ancienne version tourne, `app-test.sh` (un test rouge
  arrête tout), puis client Keycloak, schéma, `up -d --no-build`, cloisonnement ;
- **app historique** (sans ligne `.owners`) : `clean2.sh <app>`, démarrage de **sso-lab** s'il
  le faut (attente de Keycloak, 300 s), **`create-app-client.sh <app>`**, `ensure-schemas.sh`,
  `recompose_docker.sh --app <app> --force` — sans tests.

`setup2.sh` lui-même ajoute `reset_url.sh`, `get-ports-list.sh` et les redirections de ports de
la box d'après `bbox.env` (`open-freebox-ports.sh` si `FREEBOX_IP`, `open-bbox-ports2.sh` si
`BBOX_IP` ; les deux renseignées → question au terminal, et sans terminal l'étape est sautée).

> **C'est le déploiement qui crée le client Keycloak** (`create-app-client.sh`).
> `create-app-client.sh` peut aussi être appelé seul pour recréer/mettre à jour un client sans tout redéployer :
> ```bash
> bash scripts/create-app-client.sh mon-app $(cat deploiement/mon-app/.keycloak-client-opts)
> ```

---

## Base de données — deux instances PostgreSQL

`infra/docker-compose.yml` héberge **deux** instances PostgreSQL séparées, jamais une par app :

| Instance | Container | Image | Base | Rôle | Pour qui |
|---|---|---|---|---|---|
| `postgres` | `dev-postgres` | `postgres:16-alpine` | `dev_<uid>`, `lab` | `dev_<uid>`, `lab` | La grande majorité des apps — une base par propriétaire, un schéma par app |
| `postgis` | `dev-postgis` | `postgis/postgis:16-3.5` | `gis_<uid>` | `dev_<uid>` | Apps SIG uniquement (ex. `carto-lab`) |

**Répartition depuis la bascule du 2026-10-11** (les 16 apps historiques ont quitté `devdb`/`gisdb`) :
- **`dev_sacha`** (et `gis_sacha` pour `carto-lab`) : les 12 applications de `sacha`, toutes dans
  `deploiement/` ;
- **`lab`** (rôle `lab`, non superutilisateur, mot de passe `LAB_PG_PASSWORD` dans
  `infra/dev-roles.env`) : les services du **cadriciel**, qui restent à la racine — `lab-admin`,
  `storage`, `oauth-hub`, `app-builder` (dont `lab-admin` lit le catalogue par un second alias de
  la même base). Personne n'utilise ce rôle à la main ; `reset_url.sh` ne propage son mot de passe
  qu'à ces quatre dossiers ;
- `devdb` / `gisdb` et les rôles `devuser` / `gisuser` ne servent plus qu'à l'administration
  (`docker exec … psql`, pgAdmin partagé). Les anciens schémas en ont été supprimés le 2026-10-11,
  à la demande du propriétaire, après restauration contrôlée de la sauvegarde d'avant bascule
  (`~/sauvegardes/postgres-2026-10-11-0108.sql.gz`, `postgis-…`). **Ne jamais y remettre une app.**
- Une nouvelle app naît dans la base de son propriétaire (`new-app.sh --owner`). Les valeurs
  `DB_NAME=devdb` / `DB_USER=devuser` du gabarit ne sont plus que des défauts historiques.

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

**Aucune connexion réseau sans mot de passe** (depuis le 2026-10-11) : `pg_hba.conf` ne garde le
`trust` que pour le socket local et la boucle locale — c'est par là que passent
`docker exec … psql` (tous les scripts) et les healthchecks. Tout conteneur présente un mot de
passe, `devuser`/`gisuser` compris. Les scripts d'init qui inséraient un `trust` réseau
(`infra/init*/01_pg_hba_trust.sh`) sont supprimés : ne pas les réintroduire. `CONNECT` est retiré
à `PUBLIC` sur `devdb`, `gisdb`, `postgres` et les modèles : un rôle `dev_<uid>` n'entre que dans
sa propre base (`carto_reader` a un `CONNECT` explicite sur `gisdb`). État lisible par
`bash scripts/dev-db.sh hba-status`.

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

Si une app persiste des fichiers hors base qui ne sont pas des fichiers utilisateur, son volume
doit être déclaré `external: true` dans son `docker-compose.yml`, avec un `name:` explicite. Sans
ça, `clean2.sh <app>` (`docker compose down --volumes`) le supprime à chaque `setup2.sh <app> --yes`
— `clean2.sh` protège les volumes de `infra` et `sso-lab`, mais pas ceux qu'une app se serait
donnés elle-même. (Le volume `carto-media` de `carto-lab`, longtemps l'exemple, n'existe plus :
ses rasters sont dans `storage` — relu le 2026-11-08, `carto-lab/backend/config/settings.py:73-74`.)

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

**Migration terminée** (revue complète des 11 sous-modules le 2026-07-30 : volumes déclarés,
champs fichier des modèles, `MEDIA_ROOT`, code recevant des uploads) — plus aucune app n'a de
volume média privé ni de blob de fichier utilisateur en base.

Toute **nouvelle** app qui a besoin de stocker des fichiers utilisateur doit appeler l'API
`storage` directement plutôt que de se donner son propre volume média ou de mettre des blobs en base.

> `robot-lab` n'est **pas** concernée : son volume `downloads` est non-`external` à dessein
> (contenu transitoire, `engine` écrit / `backend` sert puis supprime).

**Sont migrées : `conciergerie`, `carto-lab`, `restauration`, `traitement-de-fichiers-compils`,
`arbre-genealogique` et `atelier-3d`.**

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
- `traitement-de-fichiers-compils` (`Fichier.fichier_binaire` → `Fichier.fichier_path`, un unique
  partage `traitement-de-fichiers-compils`, compte de service homonyme `-admin`) est l'exemple de
  référence pour deux cas :
  - **« l'autorisation est portée par les modèles de l'app, pas par `storage` »** — un fichier est
    lisible par son propriétaire (`Fichier.proprietaire`, un email) *et* par les destinataires de
    ses `Partage`. `storage` ne connaît ni l'un ni l'autre : le token d'un destinataire ne lui
    donnerait aucun droit sur l'espace du propriétaire, donc le forward de token (variante
    `carto-lab`) est inapplicable. `_owned`/`_accessible` (`api/views.py`) décident, le compte de
    service transporte. Un partage unique et non un par propriétaire : les noms de partage sont des
    slugs `[a-z0-9-]` et les propriétaires des emails, sans dérivation stable de l'un vers l'autre.
  - **la migration de données réelles** (10 fichiers, 19 Mo) : le transfert des octets et la
    suppression de la colonne vivent dans **la même migration** (`0004_fichier_storage.py`), donc
    la même transaction. Si `storage` est injoignable, la migration échoue et la colonne survit —
    le conteneur ne démarre pas (`migrate` est dans le `CMD`), ce qui est le bon mode d'échec. Le
    chemin cible est dérivé de la **clé primaire** (`fichiers/<pk>-<nom>`) et non d'un UUID comme
    les uploads courants : une reprise après échec partiel réécrit au même chemin au lieu de
    dupliquer des blobs orphelins.

- `arbre-genealogique` (`MediaObject.data` → `MediaObject.storage_path`, un unique partage
  `arbre-genealogique`, compte de service homonyme `-admin`) reprend le même cas que
  `traitement-de-fichiers-compils` (autorisation portée par l'app : `Tree.owner_email`,
  `Tree.is_public`, `TreeShare`), et est l'exemple de référence pour **la purge des octets quand
  une app a plusieurs chemins de suppression**. Un `MediaObject` disparaît par au moins quatre
  voies : `MediaObjectViewSet.destroy`, `MediaLinkViewSet.perform_destroy` (média que plus aucun
  lien ne réclame), et les cascades depuis `Tree`. Les couvrir une par une laisserait des blobs
  orphelins au premier chemin oublié — et **les cascades ne passent par aucune vue**. La purge vit
  donc dans un **signal `post_delete`** sur le modèle (`api/models.py`), best-effort : l'échec de la
  purge ne doit pas faire échouer une suppression déjà validée en base. Trois chemins d'écriture
  (upload multipart, base64 `data_base64`, import depuis un fournisseur externe) passent par un
  unique `storage_client.upload_bytes()`, pour que le nommage des chemins reste défini à un seul
  endroit. Le test de « média hébergé ici » vs « média externe » est partout `storage_path` non vide
  (sérialiseurs, `graph.py`, action `file`) — c'était `data` non vide auparavant.

- `atelier-3d` (volume Docker privé `atelier3d-media`, 2,9 Go dont 2,4 Go de scratch de calcul
  jamais nettoyé) est l'exemple de référence pour **la migration d'un volume média vers un backend
  de fichiers Django adossé à `storage`**, plutôt qu'une réécriture champ par champ comme pour les
  quatre migrations précédentes. `FileField.name` (`Photo.file`, `Project.region_map`/
  `region_overlay`, `Mesh.file`/`gltf_file`/`step_file`) contenait déjà un chemin logique
  (`projects/<id>/photos/<nom>`) qui est exactement un `relative_path` `storage` valide : brancher
  `STORAGES['default'] = {'BACKEND': 'api.storage_backend.LabStorage'}` (`config/settings.py`)
  suffit, **sans migration de schéma ni de données en base** — seuls les octets changent de place,
  au même chemin logique. Voir `api/storage_backend.py` (`LabStorage`, `local_copy()`,
  `download_to()`, `scratch_dir()`).
  - `FileField.path` lève désormais `NotImplementedError` (comportement voulu, pas un oubli) : un
    stockage distant n'a pas de chemin local, et ça rend visible chaque endroit qui passait un vrai
    fichier à un outil natif (COLMAP, trimesh, FreeCAD, build123d, pymeshlab) — dix sites au total
    dans `tasks.py`/`views.py`/`facade.py`/`cad_assemble.py`. `local_copy(fieldfile)` (context
    manager, télécharge vers un temp, le supprime en sortie de bloc) remplace un `Path(champ.path)`
    ponctuel ; `download_to(fieldfile, dest)` la variante persistante quand plusieurs fichiers
    doivent survivre ensemble le temps d'un sous-processus (`cad_assemble.py` : chaque STEP d'un
    assemblage doit exister en local avant de lancer `freecadcmd`, qui tourne dans un process séparé
    sans aucun accès à `storage`). Quand la bibliothèque accepte un objet fichier plutôt qu'un
    chemin (`PIL.Image.open`, `np.load` sur un `.npz`), lire directement `champ.open('rb')` sans
    passer par un temporaire — vérifié dans cette migration que `np.load` fonctionne tel quel sur un
    `django.core.files.base.ContentFile`.
  - Le répertoire de travail des jobs (bases COLMAP, nuages de points denses, images
    redimensionnées — plusieurs Go par job) reste un volume Docker **local, non-`external`**
    (`atelier3d-scratch`, même raisonnement que `downloads` de `robot-lab`) : jamais dans `storage`,
    ces fichiers n'ont aucune valeur une fois le job terminé et les faire transiter par HTTP serait
    absurde. `clean2.sh` peut le vider sans rien perdre.
  - Compte de service `atelier-3d-admin` : c'est le **worker Celery** qui en a besoin (écrit
    maillages/glTF/STEP longtemps après la fin de la requête HTTP qui a lancé le job, sans
    utilisateur connecté), pas seulement le backend — `worker` a donc gagné `sso-net` (pour obtenir
    un token du compte de service), en plus de `dev-net` (déjà là pour Postgres, et qui suffit pour
    atteindre `storage-backend`).
  - Migration de données réelles (118 fichiers, 384 Mo) faite via une commande de gestion à usage
    unique (`transferer_vers_storage`, supprimée après coup — inutile en production une fois
    vérifiée), avec vérification par checksum immédiate à chaque fichier transféré, montage
    temporaire en lecture seule de l'ancien volume (`atelier3d-media:/oldmedia:ro`, retiré du
    `docker-compose.yml` une fois la migration terminée) et double vérification indépendante côté
    base (`storage.stored_files`).

> ⚠ Sortir des blobs de `devdb` ne rend pas l'espace disque tout seul : `DROP COLUMN` ne fait que
> marquer la colonne supprimée, les données TOAST restent jusqu'à une réécriture de table. Après
> une migration de ce type, lancer `VACUUM FULL <schéma>.<table>`
> (`traitement_de_fichiers_compils.fichiers` : 20 Mo → 64 ko ;
> `arbre_genealogique.media_objects` : 6,4 Mo → 80 ko). Sans ça, la base et ses sauvegardes gardent
> exactement le poids qu'on cherchait à leur retirer.

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
  (`OAUTH2_PROXY_ALLOWED_GROUPS=admins` — voir « Lab multi-développeurs »). Il tourne en `--auth=none` et n'a **aucune protection propre**.
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
de `carto-lab` (migré, cf. plus haut ; `atelier-3d`, migré lui aussi, a pris un partage par
projet racine — `atelier-3d/backend/api/storage_backend.py:47,65`) : aucun cloisonnement
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

### Identifiants OAuth des sites externes — `oauth-hub`

`oauth-hub` (Django + Angular, 8100 / 4215) centralise les identifiants OAuth2 des **sites**
externes (GitHub, GitLab, Google…) et distribue aux apps autorisées un jeton **au nom de
l'utilisateur connecté**. Mode d'emploi complet — pour les devs comme pour les apps
consommatrices — dans **`oauth-hub/README.md`** ; cette section ne garde que les décisions.

**Cible : des applications qui tournent côté client** (outils de bureau sur le poste de
l'utilisateur), en plus des apps web du lab. D'où trois URI de rappel distinctes, dont **deux en
boucle locale** — la confusion la plus fréquente, détaillée en tête du README de l'app :

| # | URI | Où | Boucle locale ? |
|---|---|---|---|
| 1 | callback du fournisseur | enregistrée chez GitHub/GitLab | **non, jamais** — l'échange du code exige le `client_secret`, qui ne doit pas être distribué sur les postes |
| 2 | redirect URI Keycloak du client natif | client Keycloak de l'app | oui (`http://127.0.0.1:8765/callback`) |
| 3 | `return_url` | paramètre d'appel, rien à enregistrer | oui |

`_is_safe_return_url` (`api/views.py`) n'accepte en `return_url` que le domaine du lab et la boucle
locale : un endpoint de retour redirigeant vers une URL arbitraire fournie par l'appelant serait un
tremplin de hameçonnage.

**Les identifiants sont portés par le site, jamais par l'app consommatrice.** Une seule
application OAuth est enregistrée chez GitHub pour tout le lab ; dix apps s'en servent. L'alternative
(une application OAuth par app du lab) multipliait les `client_secret` à créer, à roter et à ne pas
laisser fuir, sans rien apporter : GitHub ne distingue pas les apps du lab, il distingue les
utilisateurs.

**Décision : courtage maison plutôt que courtage Keycloak.** Keycloak sait faire *identity
brokering* (`storeToken` + `addReadTokenRoleOnCreate`, endpoint `/realms/ssolab/broker/<idp>/token`)
et ç'aurait été moins de code. Le choix retenu est une app maison, actée par l'utilisateur en
connaissance de la contrepartie : **elle concentre en un point** ce que le courtage Keycloak
répartissait — un seul service détient de quoi agir, au nom de tous les comptes du lab, sur tous les
sites configurés. Compensations en place : chiffrement au repos (Fernet, `OAUTH_HUB_ENCRYPTION_KEY`),
liste blanche explicite des apps consommatrices, `client_secret` jamais relisible par l'API, et
journalisation de chaque remise de jeton. En contrepartie l'app offre ce que le broker Keycloak ne
donne pas : des fournisseurs **génériques éditables en base** (ajouter GitLab = un formulaire, pas un
déploiement) et une interface où les devs déposent eux-mêmes les secrets.

**La liste blanche `azp` se donne app par app, jamais au realm.** Même mécanisme que `storage`
(voir plus haut), mais l'enjeu est d'un cran supérieur : `/api/providers/<slug>/token/` rend le jeton
**amont brut**. Toute app qui l'obtient agit sur GitHub au nom de l'utilisateur, avec toutes les
portées accordées. Ouvrir la liste à « tout compte authentifié » reviendrait à l'ouvrir à `admin-cli`
(public, password grant activé par défaut sur le realm), donc à tout compte du lab depuis n'importe où.

> ⚠ **Seule app du lab où cette liste ne vit PAS dans le `.env`** : elle est en base
> (`api.models.TrustedClient`) et s'édite dans la page « Apps autorisées » de l'interface.
> `KEYCLOAK_TRUSTED_CLIENTS` (`oauth-hub/.env`) n'a servi que de graine à la migration `0003` et
> **n'est plus lue à l'exécution** — l'éditer n'autorise ni ne révoque plus rien (piège à connaître
> avant de « corriger » un 403 par là). Le déplacement n'affaiblit rien : la population qui édite
> (`OAUTH_HUB_ADMIN_GROUPS`) écrit déjà `authorization_url`/`token_url` de chaque site, donc peut
> déjà détourner l'aller-retour OAuth de tout le lab — autoriser un client de plus ne lui ouvre rien
> qu'elle ne puisse déjà obtenir. Ce qui change, c'est le délai de **révocation** : immédiat au lieu
> d'un `.env` + recréation de conteneur. Trois invariants non éditables tiennent la propriété de
> sécurité, tous dans `TrustedClient.is_trusted` (donc appliqués même à une ligne insérée
> directement en base, pas seulement à une saisie) : le client d'oauth-hub est autorisé en dur (pas
> de verrouillage possible de l'interface), les clients intégrés du realm (`admin-cli` en tête) sont
> refusés quoi qu'il arrive, et **aucun cache** ne s'interpose (un cache mémoire serait par
> processus gunicorn — une révocation resterait partiellement sans effet, en silence).

**Cloisonnement « au moins un groupe »**, et non un groupe nommé : tout compte réellement rattaché au
lab relie ses propres comptes externes, un auto-inscrit sans groupe n'accède à rien. Implémenté sans
mécanisme parallèle, en passant la **liste complète des groupes** à `--require-group`.
> ⚠ Tout nouveau groupe LDAP doit être ajouté à `oauth-hub/.keycloak-client-opts` **et** à
> `KEYCLOAK_REQUIRED_GROUPS` (`oauth-hub/.env`), sinon ses membres sont refusés à tort.

L'écriture dans le coffre (déposer/modifier un `client_secret`) est réservée à `developers`
(`OAUTH_HUB_ADMIN_GROUPS`) — distinct de l'accès à l'app.

> ⚠ `init-secrets.sh` **ne régénère jamais** `OAUTH_HUB_ENCRYPTION_KEY` si elle existe. C'est la
> seule clé du script qui chiffre des données **au repos qui survivent** : la remplacer rend le
> coffre entier illisible, sans reprise possible.

### PKCE, URI de retour, coffres de clés (chantier « failles », 2026-11-01)

- **PKCE S256 exigé sur tous les clients publics des apps** : chaque frontend passe
  `pkceMethod: 'S256'` à `kc.init()` (gabarits compris), et chaque client a été relancé avec
  `create-app-client.sh <app> $(cat .keycloak-client-opts) --pkce --prune-uris`.
- **Plus de joker `*` en URI de retour** : un nouveau client naît avec `redirectUris: []`, et
  `--prune-uris` remplace la liste d'un client existant par celle que le script calcule (refus si
  elle serait vide). Avec un domaine, plus aucune URI en IP LAN/WAN. Les clients `front-cadriciel`
  et `infra` sont **désactivés** (pas supprimés) — ⚠ `infra` est le client du pgAdmin partagé
  (`infra/.env`), dont la connexion est donc coupée : décision en attente (`to_do_global.md`) ; `dev-<uid>` (essai) est créé
  avec `--prune-uris` par `app-preview.sh`.
- **Clés d'API des utilisateurs : coffre serveur** (`VAULT_ENCRYPTION_KEY`, Fernet, dans le `.env`
  de l'app, générée par `install.sh`) — plus rien en `localStorage`. Les `EncryptedTextField`
  (`code-route`, `craft-lab`, `restauration`, `robot-lab`) lisent encore l'ancienne clé dérivée de
  `SECRET_KEY` (`MultiFernet`, lecture seule) et une migration a tout rechiffré : faire tourner
  `SECRET_KEY` ne détruit plus rien. Une réponse d'API ne rend que `…_configured`, jamais la clé.
  **Ne jamais régénérer `VAULT_ENCRYPTION_KEY`** : comme `OAUTH_HUB_ENCRYPTION_KEY`, la perdre rend
  les clés enregistrées illisibles.

### Keycloak 26 (depuis le 2026-11-01)

`sso-lab-keycloak:26.8.1` (`sso-lab/keycloak/Dockerfile`, `kc.sh build`), `start --optimized`,
base PostgreSQL `keycloak` / rôle `keycloak` de `dev-postgres` (`dev-db.sh ensure-keycloak`, mot de
passe `KEYCLOAK_PG_PASSWORD` dans `infra/dev-roles.env`, recopié dans `sso-lab/.env` par
`reset_url.sh`). Le conteneur n'a plus d'`env_file`. Bascule faite par export 22 → import 26, sans
perte (comptes, secrets, clé de signature identiques). Procédure et essais :
`chantiers/failles/keycloak/PROCEDURE.md`.

- **Scope `nonce-keycloak-js-22` obligatoire** (`scripts/keycloak-nonce-compat.sh`, idempotent) :
  keycloak-js 22 vérifie `nonce` dans l'access_token, que Keycloak ≥ 25 n'y met plus ⇒ **boucle de
  connexion infinie dans toutes les apps**. Le scope est par défaut du realm (clients futurs
  compris). À retirer quand les frontends passeront à keycloak-js ≥ 25. Au premier passage juste
  après le démarrage, le script n'a rien fait et n'a rien dit : relancer jusqu'à lire
  « ✓ … client(s) public(s) portent nonce-keycloak-js-22 ».
- **La console d'administration et le realm `master` ne sont plus servis par Caddy** (404).
  L'API REST `/auth/admin/realms/*` l'est encore (restauration et peripheriques l'appellent par
  l'URL publique). **La console ne s'ouvre pas non plus par tunnel** (constaté le 2026-11-01) :
  servie sur `localhost:8080/admin/master/console/`, elle envoie la connexion vers
  `authServerUrl` = l'adresse publique, où `realms/master` répond 404. Piste, à faire en présence
  du propriétaire (redémarre Keycloak) : `KC_HOSTNAME_ADMIN=http://localhost:8080`. D'ici là,
  administrer par l'API (`docker exec keycloak /opt/keycloak/bin/kcadm.sh …`).
- Hostname v2 : `KC_HOSTNAME=${KEYCLOAK_HOSTNAME_URL}` (URL complète, `/auth` compris),
  `KC_HOSTNAME_BACKCHANNEL_DYNAMIC=true`, `KC_PROXY_HEADERS=xforwarded`. `KC_HOSTNAME_URL`,
  `KC_PROXY`, `KC_HOSTNAME_STRICT*` n'existent plus.
- **Retour arrière clos le 2026-11-11, gel levé** : le volume `sso-lab_keycloak-data` (H2 de 22) est
  retiré du compose et de `backup.sh`, l'image `keycloak-export22:bascule` supprimée. Le volume
  lui-même reste sur le disque (2 Mo, plus rien ne le lit) : `docker volume rm sso-lab_keycloak-data`
  quand on veut. **Ne pas supprimer `quay.io/keycloak/keycloak:22.0`** : c'est l'image du Keycloak
  de `dev2/` (`keycloak2`). `setup2.sh --restart-sso-lab` vide encore l'annuaire mais plus le realm
  (il est dans la base `keycloak`) : non réécrit, à ne pas lancer sans relire.

`create-app-client.sh --no-env` crée un client **sans écrire de `<app>/.env`** : pour un client dont
l'application vit hors de `dev/` (application de bureau, autre dépôt). Sans lui, le script créait un
dossier vide avec un `.env` orphelin que rien ne déployait. Utilisé par `storage-analysis`.

---

### Périphériques de l'hôte — `peripheriques`

`peripheriques` (Django + Angular, 8101 / 4216 ; flux tenus par `lab-media/`) donne accès, en direct et en relecture,
à la caméra et au micro branchés sur l'hôte. Contrat d'origine :
`chantiers/peripheriques/CONTRAT.md` (v6). Décisions à ne pas rouvrir :

- **Les droits sont par email, en base (`Grant`), périphérique par périphérique** (vidéo, micro ou
  les deux), accordés à un compte du realm existant. L'accès à l'app elle-même est « au moins un
  groupe », comme `oauth-hub` — même contrainte : tout nouveau groupe LDAP doit être ajouté à
  `peripheriques/.keycloak-client-opts` **et** à `KEYCLOAK_REQUIRED_GROUPS`.
- **Les administrateurs (`PERIPHERIQUES_ADMIN_GROUPS`) gèrent les droits mais n'ont aucun accès
  implicite** aux flux ni à l'historique : un admin qui veut voir ou écouter s'accorde un droit,
  soumis comme les autres à son `since` (un droit ne vaut que pour ce qui est postérieur à son
  octroi).
- **Une page de gestion des droits ne tire jamais ses référentiels d'un endpoint filtré par les
  droits de l'utilisateur courant.** Le sélecteur de périphériques lisait `/api/devices/`
  (= « là où j'ai un droit ») : un admin sans droit ne pouvait accorder le premier, même à
  lui-même. D'où `/api/grants/devices/` (admin, tous les périphériques).
- **MediaMTX n'interroge le hook d'autorisation HLS qu'à l'ouverture de session** (version
  `1.21.1`) : sous-playlists et segments passent ensuite sans contrôle. Une révocation doit donc
  **expulser** les sessions ouvertes, WebRTC *et* HLS (`webrtcsessions/kick`, `hlssessions/kick`) ;
  refuser au hook ne suffit pas.
- *(vaut désormais pour `lab-media/`, qui a repris la capture)* **Aucun `devices:` figé dans le compose.** Une ré-énumération USB a interverti `video0`/`video1`
  et le conteneur pointait sur le nœud de métadonnées. `/dev` de l'hôte est monté en lecture seule
  sous `/hostdev` avec `device_cgroup_rules` (81 = video4linux, 116 = ALSA), et le chemin est
  résolu à chaque (re)publication.
- **`MEDIA_HOOK_KEY` transite en query string** (contrainte MediaMTX) : le backend ne journalise
  jamais la query de `/api/media-auth/` (`api/log_filters.py`).
- **Les enregistrements ne passent pas par `storage`** (dérogation assumée) : flux machine
  d'environ 11 Go/jour écrit directement par MediaMTX dans le volume `external`
  `lab-media-recordings` (possédé par `lab-media`), rétention 7 jours.
- **MediaMTX n'est plus dans l'app** (bascule du 2026-10-11) : la brique **`lab-media/`** du
  cadriciel détient la caméra et le micro, publie `webcam/{av,video,audio}`, enregistre et sert
  la relecture. L'app ne parle qu'à l'API de contrôle de `lab-media-auth`
  (`MEDIA_API_URL=http://lab-media-auth:9100`, description : `lab-media/API.md`) et ne garde que
  le hook de lecture (`read`). Voir « Flux audio et vidéo — `lab-media` » ci-dessous.
- **Caddy lit les labels de tous les conteneurs de l'hôte** : une pile de test qui garde ses
  labels `caddy` modifie le Caddy en service. Toute pile jetable doit renommer ce label.
- **Du code non commité dans le dossier d'une app en service est un déploiement en attente** :
  le sortir sur une branche poussée et revenir à la version en service.
- Hors vitrine : `peripheriques` n'est pas dans `.app-descriptions`.
- **Coupure globale** (2026-11-05, chantier `chantiers/webcams-modeles/`) : bouton de la page
  Droits (`/api/admin/cutoff/`, admins des droits). Active ⇒ le hook refuse toute lecture par jeton
  Keycloak, les sessions en cours sont expulsées (d'après la liste de lab-media, pas seulement
  `MediaSession`), chaque webcam qui enregistrait passe à `record=false` et `PATCH record=true` répond
  409 ; à la levée, exactement ces webcams reprennent. La **relecture reste permise** et la capture
  tourne toujours (décisions du propriétaire).
- **Pont vers `google-agenda` de dev2** (seul lien entre les deux cadriciels, hors hôte et
  edge-router) : `POST /api/bridge/model-cameras/` avec `Authorization: Bridge
  <PERIPHERIQUES_BRIDGE_KEY>` (même valeur dans `dev2/google-agenda/.env` ; vide ⇒ 404) rend les
  webcams où le **modèle** (rapproché par email) a la vidéo, et un ticket `pt1.` de 120 s que le
  navigateur du watcher présente en `Bearer` au WHEP. Le hook l'accepte en WebRTC seulement, revérifie
  le droit du modèle à chaque ouverture et **ignore la coupure** — voulu. Retirer le droit du modèle
  coupe aussi ses watchers. Passage par l'adresse publique, jamais un réseau Docker commun
  (relier `dev2-net` à `dev-net` ouvrirait les bases de dev). Qui administre l'annuaire de dev2
  décide quel compte porte l'email d'un modèle.

---

### Flux audio et vidéo — `lab-media`

`lab-media/` (racine du dépôt, service du cadriciel comme `lab-mcp/`) est le point d'entrée unique
des flux, au même titre que PostgreSQL pour les données et `storage` pour les fichiers :
conteneurs `lab-media` (MediaMTX), `lab-media-auth` (mini-service d'authentification) et
`lab-media-capture` (périphériques de l'hôte). Contrat et preuves : `chantiers/lab-media/`.

- **Un préfixe de chemin = une app**, qui est l'autorité de lecture pour ce préfixe
  (`lab-media/registry.json` ; secrets dans `lab-media/.env`). Ajouter une app est une entrée de
  configuration. Une app ne publie, ne lit, ne liste, ne coupe et ne relit que sous ses préfixes.
- **`lab-media-auth` décide lui-même** publication, API et relecture, et **relaie `read`** au hook
  de l'app propriétaire, en échec fermé (hook arrêté, en erreur ou qui pend ⇒ refus). Conséquence
  voulue : **redéployer une app ne troue pas l'enregistrement** ; personne ne lit pendant ce temps.
- **`authHTTPExclude` est interdit** : une action exclue n'est pas renvoyée aux identifiants
  internes, elle est ouverte à tous, publication WebRTC comprise (essai réel, MediaMTX 1.21.1).
- **Aucune app n'a les identifiants de MediaMTX** (tirés au hasard à chaque démarrage, en mémoire) :
  elle passe par l'API de contrôle de `lab-media-auth` (`lab-media/API.md`).
- **Aucune app n'ouvre un périphérique ni ne monte le volume d'enregistrements.**
- Arrêter `lab-media-auth` ne coupe ni publication ni enregistrement, mais plus rien ne
  s'authentifie et les expulsions sont impossibles ; redémarrer `lab-media` coupe tout.
- Port ICE **8189 udp/tcp** publié par `lab-media`, redirigé sur la box par
  `open-freebox-ports.sh` (à la main avec une Bbox). `MEDIA_WEBRTC_HOSTS` (`lab-media/.env`)
  porte l'IP publique **en dur** et `reset_url.sh` ne la met pas à jour : à corriger à la main
  à tout changement d'IP, puis `up -d --no-build`, sinon la vidéo ne passe plus hors du LAN.
- **Toutes les webcams USB sont découvertes** (chantier `chantiers/webcams/`, 2026-10-17) :
  `lab-media-auth` lit `/sys` toutes les 2 s (sans ouvrir de nœud) et tient un inventaire
  persistant (`lab-media_state`, `/state/inventory.json` — **dans la sauvegarde nocturne** : le
  perdre oublie les webcams et coupe tous les enregistrements). Identifiant stable
  `usb-<vid>-<pid>-s<série>`, ou `usb-<vid>-<pid>-p<port>` **sans numéro de série** : une telle
  caméra rebranchée sur un autre port devient un nouveau périphérique (les HD USB Camera du lab
  n'ont pas de série et partagent un seul lien `/dev/v4l/by-id`). Chemins `webcam/<id>/{av,video}`
  (+ `audio` si le **même appareil USB** a un micro) — les consommateurs les prennent dans
  `GET /v1/devices`, **jamais recomposés** ; l'ancienne Jieli est `webcam-ancienne` sur
  `webcam/{av,video,audio}`. Un ffmpeg par webcam, au plus `MEDIA_CAPTURE_MAX` (3 depuis le 2026-10-17, `lab-media/.env`,
  ≈ 0,5 cœur chacune à 15 i/s, ≈ 0,35 à 8 i/s — `MEDIA_CAPTURE_FPS`, 8 depuis le 2026-10-17) ; au-delà, « en attente ». Enregistrement **coupé par défaut**, réglé par
  webcam (`PATCH /v1/devices/<id>`), à chaud, persistant. Description : `lab-media/API.md` §1.4.
- **MediaMTX 1.21.1 ignore une modification de `mediamtx.yml` arrivant moins d'environ 1 s après la
  précédente**, sans message : `lab-media-auth` espace ses écritures de 2 s et vérifie par l'API
  qu'elles sont prises. **ffmpeg écrit l'URL de publication, mot de passe compris, dans ses
  erreurs** : la capture les filtre.
- **peripheriques** suit l'inventaire (`api/inventory.py`, cache 10 s) : tout périphérique déjà vu
  apparaît dans les droits sans action ; page « Périphériques » (admins des droits) pour renommer,
  enregistrer, oublier une webcam débranchée. **Noms d'affichage uniques** (casse et espaces de bord
  ignorés, index `device_label_unique_ci`) : un même modèle arrive en « Modèle », « Modèle 2 »… Le
  droit Micro est refusé (400) sur une webcam sans micro. Le hook retrouve le périphérique par ses
  chemins exacts ; l'expulsion à la révocation compare des chemins exacts (un préfixe `webcam/`
  aurait expulsé les lecteurs de toutes les webcams).
- **Haut-parleur** (2026-11-05, chantier `chantiers/haut-parleur/`) : déclaré au registre, pas
  découvert (`devices.speakers.hp-jack`, prise jack de la carte mère, `plughw:CARD=PCH,DEV=0` —
  carte nommée, pas numérotée ; mixeur `PCH Master` remis à 80 % et activé par le lecteur à chaque
  démarrage, il était à 0 % coupé). Chemin `speaker/hp-jack`, préfixe de `peripheriques`. **Seule
  publication WebRTC (WHIP) ouverte du lab** : sur `speaker/*` uniquement, relayée au hook de l'app
  (échec fermé) ; WHIP partout ailleurs et RTSP sur `speaker/*` restent refusés ; **personne ne lit
  `speaker/*`** sauf le lecteur de la capture (RTSP), jamais enregistré, un seul publieur
  (`overridePublisher: no` — le second reçoit 201 puis est fermé : MediaMTX consulte le hook avant
  de le refuser). Le lecteur (`mediamtx/speaker-one.sh`, ffmpeg → `aplay`, tampon 160 ms) vit dans
  `lab-media-capture`. Côté peripheriques : droit « Parler » (`Grant.speaker`), bouton sur Direct,
  coupure et révocation expulsent les publieurs ; le pont rend `speakers`. Avec `Auto-Mute Mode`,
  un casque en façade coupe la prise arrière.
- **Gain automatique des webcams** (2026-11-06, `MEDIA_CAPTURE_AUTOGAIN=1` dans `lab-media/.env`) :
  leur gain matériel était à 0, l'exposition automatique seule laissait l'image sombre. La capture
  mesure la luminosité (une image / 2 s) et règle `gain` (`v4l2-ctl`, ajouté à l'image) vers une
  cible ; réglages et mesures détaillés dans `lab-media/README.md`. Un réglage unique pour toutes
  les webcams ne marche pas (la mieux éclairée sature) : c'est la boucle par webcam qui le tient.
- **Chemins `whip`** (2026-11-05, app `ecran`, chemin `ecran/a`) : clé de chemin `"whip": true`
  au registre ⇒ publication **WebRTC seule, relayée au hook de l'app** (aucun identifiant n'y
  publie, en aucun protocole), lecture relayée, jamais enregistré, un seul publieur ; le
  publieur est expulsable par son app (`/v1/sessions/webrtc/<id>/kick`). Clé d'app
  `"read_hook_env": true` : l'URL du hook vient de `LAB_MEDIA_APP_<NOM>_HOOK_URL` (`.env`), pour
  une app dont l'adresse ne doit pas figurer dans ce dépôt — le relais part alors en **https par
  l'adresse publique** (certificat vérifié). Le relais pose la clé en `?key=` **et** en en-tête
  `X-Lab-Media-Key`. Poser registre et `.env` **avant** de recréer `auth` : l'ancienne image
  refuse ces clés, la nouvelle refuse une clé `.env` manquante — dans les deux cas plus rien ne
  s'authentifie. Essais : `auth/tests/test_whip.py`, contrôles WP1-WP15 de `verify.sh`.
- Redéployer `lab-media-auth`/`lab-media-capture` sans MediaMTX :
  `docker compose -f lab-media/docker-compose.yml --profile capture build auth capture` puis
  `… up -d --no-deps auth capture` (webcams coupées ~15 s). Ne pas recréer `media` par la même
  occasion : son image vient d'une autre étape du Dockerfile.
- Vérification rejouable sans matériel : `bash lab-media/verify.sh` (sources synthétiques, deux
  apps fictives, 149 contrôles dont multi-caméras sur faux matériel). MediaMTX écrit l'URL du hook, donc sa clé, dans son journal quand
  le hook est injoignable : limite connue.

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
E2E** dans une app sans d'abord mettre à jour cette section — le runner ne joue que ce nom précis.
Seule exception : `storage/frontend/e2e/gestes.spec.ts` (25 gestes), joué à la main par
`jouer-gestes.sh` avec `E2E_GESTES=1`, jamais par le moteur.

### Architecture

- **`runner/`** (racine du dépôt, comme `infra/`/`sso-lab/` — pas un sous-module) : conteneur
  unique portant Playwright + Chromium pour tout le lab. Jamais dans l'image d'une app (contrainte
  2 vCPU/16 Go — voir `to_do_3D.md` pour le même principe côté atelier-3d). Réseau `sso-net`
  uniquement, monte tout le dépôt en lecture seule (`${HOST_DEV_ROOT}`, voir ci-dessous), **jamais
  exposé** (pas de port publié, pas de label Caddy) — atteint uniquement par nom de conteneur
  (`lab-runner`) depuis `lab-admin` (worker Celery) ou via `docker exec` depuis `setup_unit.sh`.
  Son Chromium **ne décode pas le H.264** (pas de Chrome dans le runner, décision actée) : une
  lecture vidéo H.264 (`peripheriques`) ne se vérifie que dans un vrai navigateur, à la main.
- **Deux comptes LDAP synthétiques** (`sso-lab/ldap/init.ldif`) : `e2e_member`, membre de **tous**
  les groupes existants **sauf `admins`** (depuis le 2026-11-01 : `admins` ouvre `/code`, donc l'hôte) (toujours le cas « membre » positif, quelle que soit l'app testée), et
  `e2e_outsider`, membre d'**aucun** groupe (toujours le cas « non-membre » négatif — aucune
  maintenance requise). Leurs mots de passe rotent normalement avec `rotate-ldap-user-passwords.sh`
  — le runner relit toujours la valeur courante dans `sso-lab/.env`, jamais de cache.
  - `e2e_member` porte une adresse **factice** `e2e_member@ssolab.local` (2026-08-09). Elle est
    indispensable : `api/authentication.py` refuse tout token sans claim `email`, donc sans elle ce
    compte passait le flow de page mais prenait un **403 sur le moindre appel API** — il ne
    permettait de tester que l'accès à la page, jamais un parcours applicatif réel. Le domaine
    `.local` est ce qui rend l'ajout sûr : `notify-password-email.sh` n'envoie rien à ces
    adresses, et `verify-existing-emails.sh` les marque `emailVerified` **d'office et sans
    garde-fou** — sans quoi, `VERIFY_EMAIL` étant actif sur le realm, donner une adresse à ce
    compte le **bloquerait** à l'écran de vérification (constaté en réel avant correction).
    `e2e_outsider` n'en a délibérément pas : il n'a jamais à dépasser le refus de cloisonnement.
  - **`e2edev`** (2026-10-10) : troisième compte synthétique, membre de `developers` **seul**, uid
    sans tiret bas, adresse factice `e2edev@ssolab.local`, mot de passe `E2EDEV_PASSWORD` dans
    `sso-lab/.env`. C'est le compte du parcours « développeur » du lab multi-dev (inscrit, base
    `dev_e2edev`) et le seul qui prouve qu'un membre de `developers` **sans** `admins` est refusé
    sur les pages et l'API d'administration de `lab-admin`. Il n'est pas utilisé par
    `cloisonnement.spec.ts`. Tout nouveau groupe LDAP ne doit **pas** l'inclure.
- **Qui lance les tests** (depuis le 2026-10-11) : **le moteur `lab-mcp`, et lui seul.** Il joue
  le test de cloisonnement d'une app après chaque déploiement fait par le chemin à portes, à la
  demande depuis la page d'un projet de `lab-admin` (ou l'outil MCP `run_tests`), et pour tous
  les projets à la fois par « Tout tester » (superutilisateur). Il garde le dernier résultat de
  chaque app dans `<LAB_STATE_DIR>/tests/<app>.json` et le rend avec la liste des projets.
  L'ancien dispositif (catalogue synchronisé par `setup_unit.sh`, page « Debug », table
  `DebugTest`, worker Celery et Redis de `lab-admin`, `CatalogSyncView`, `SETUP_CATALOG_KEY`)
  est supprimé : ne pas le réintroduire.
- **Le runner joue toujours le spec du gabarit** (2026-10-31, chantier « urgences ») : la présence de
  `<app>/frontend/e2e/cloisonnement.spec.ts` n'est qu'un signal, son contenu n'est jamais lu ni
  chargé — un dépôt de développeur ne fait donc exécuter aucun code au runner. Nom d'app hors
  `^[a-z][a-z0-9-]{0,62}$` → 400. Changer le test = changer le gabarit. `runner/playwright.config.ts`
  sert aussi à `storage/frontend/e2e/jouer-gestes.sh` (variable `E2E_GESTES`). Voir `runner/README.md`.
- Un seul run à la fois, lab-wide : mutex en mémoire côté runner (409 si déjà occupé) ; le moteur
  attend son tour au lieu d'échouer. Tout script ou agent qui lance un navigateur dans
  `lab-runner` doit d'abord vérifier qu'aucun autre n'y tourne.
- Une réponse `[]` du runner signifie « aucun test trouvé », jamais « tout va bien » : le moteur la
  rend comme un verdict `absent`, et un projet neuf sans spec est refusé au déploiement.


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

Les **applications** sont dans `deploiement/<app>` ; les **services du cadriciel** (`lab-admin`,
`storage`, `oauth-hub`, `app-builder`) restent à la racine. Le tableau donne le nom du dossier ;
pour le chemin réel, toujours passer par `registry_app_dir`.

| Dossier | Dépôt | Type | Ports |
|---|---|---|---|
| `analyse-lora` | `Sacha37420/analyse-lora` | Django + Angular | 8086 / 4204 |
| `app-builder` | `Sacha37420/app-builder` | Django + Angular | 8087 / 4205 |
| `arbre-genealogique` | `Sacha37420/arbre-genealogique` | Django + Angular | 8090 / 4208 |
| `atelier-3d` | `Sacha37420/atelier-3d` | Django + Angular | 8092 / 4210 |
| `bilan-thermique` | `Sacha37420/bilan-thermique` | Django + Angular (+ Celery) | 8099 / 4214 |
| `carto-lab` | `Sacha37420/carto-lab` | Django + Angular | 8091 / 4209 |
| `code-route` | `Sacha37420/code-route` | Django + Angular (+ Celery) | 8096 / 4200 |
| `conciergerie` | `Sacha37420/conciergerie` | Django + Angular | 8084 / 4202 |
| `craft-lab` | `Sacha37420/craft-lab` | Django + Angular (+ `relay/` WebSocket) | 8097 / 4213 |
| `lab-admin` | `Sacha37420/lab-admin` | Django + Angular | 8083 / 4201 |
| `oauth-hub` | `Sacha37420/oauth-hub` | Django + Angular | 8100 / 4215 |
| `peripheriques` | `Sacha37420/peripheriques` | Django + Angular | 8101 / 4216 |
| `restauration` | `Sacha37420/restauration` | Django + Angular | 8088 / 4206 |
| `robot-lab` | `Sacha37420/robot-lab` | Django + Angular (+ `engine/` Playwright) | 8094 / 4212 |
| `storage` | `Sacha37420/storage` | Django + Angular | 8093 / 4211 |
| `test-video` | `Sacha37420/test-video` | Django + Angular | 8102 / 4217 |
| `traitement-de-fichiers-compils` | `Sacha37420/traitement-de-fichiers-compils` | Django + Angular | 8089 / 4207 |

> `lab-admin` et `lab-mcp` font partie du cadriciel : ils restent à la racine, jamais dans
> `deploiement/` (`app-relocate.sh` les refuse).

> `peripheriques` n'a plus de service `media/` depuis le 2026-10-11 : la caméra, le micro et les
> enregistrements sont tenus par la brique `lab-media/` du cadriciel (section « Flux audio et
> vidéo »). L'app ne décide plus que des droits.

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

Les **outils d'administration** (page « Projets » de lab-admin pour le superutilisateur, tests E2E,
`add-user.sh`) affichent en revanche **toutes** les apps réellement déployées — une entrée de
`.ports` dont le dossier contient un `docker-compose.yml`. Ils étaient auparavant limités à
`.app-descriptions`, ce qui rendait invisible en silence toute app absente de ce fichier : trois
apps déployées (`conciergerie`, `storage`, `robot-lab`) n'apparaissaient nulle part et **n'étaient
jamais testées**. Découplé le 2026-07-30. Une app hors vitrine est signalée par une étiquette
« hors vitrine » dans lab-admin, pas masquée.

> Il n'y a **plus** de fichier `.hidden-groups`, ni de groupes `dom` et `harem` : ils ne servaient
> qu'à `google-agenda` (déplacée vers `dev2/`) et ont été supprimés le 2026-10-11 de l'annuaire, de
> Keycloak et des listes de groupes requis, à la demande du propriétaire. Ne pas les recréer, ni
> réintroduire un mécanisme de masquage — si un groupe ne doit
> pas apparaître, c'est qu'il ne doit pas exister dans le realm.

---

## Scripts utiles

Les scripts d'orchestration vivent dans **`scripts/`** — les lancer avec `bash scripts/<nom>`
depuis la racine `dev/` (ils résolvent eux-mêmes la racine, donc le répertoire courant importe peu).
Les scripts **propres à un service** gardent leur chemin (ex: `sso-lab/setup-code-server-auth.sh`
ci-dessous, lancé avec `bash sso-lab/…`).

| Script | Rôle |
|---|---|
| `install.sh [--check]` | Installation rejouable du lab ; `--check` ne fait rien et dit ce qui manque ; `--modules a,b`, `--all-modules` |
| `lab-modules.sh list\|show\|plan\|selection\|settings\|prepare` | Modules : catalogue et état, vérification, plan, sélection mémorisée (section « Modules ») |
| `module-hook.sh <module> [--check]` | Joue le `install.sh` déclaré par un module (appelé par `setup_unit.sh`, avant le build) |
| `lab-doctor.sh` | Bilan de santé en lecture seule (installation, pg_hba, partages, sauvegarde, jokers et PKCE Keycloak, scope nonce, ports, conteneurs oubliés, cloisonnement, disque) ; code 1 si un problème |
| `backup-cron.sh [--check]` | Planifie `backup.sh` à 3 h dans la crontab (ne change jamais une ligne existante) et vérifie les prérequis NAS ; appelé par `install.sh` |
| `new-app.sh [--owner <uid>]` | Scaffold d'une nouvelle app dans `deploiement/` (appelé par le moteur) |
| `app-register.sh`, `app-sync.sh`, `app-remote.sh`, `app-status.sh`, `app-logs.sh`, `app-env.sh`, `app-test.sh`, `app-smtp.sh`, `app-restart.sh`, `app-remove.sh`, `app-relocate.sh` | Les commandes d'exploitation d'une app — les seules que le moteur exécute. Chacune documente son usage en tête de fichier |
| `validate-app.sh`, `check-app-name.sh` | Contrôle de sûreté d'un dépôt avant déploiement ; règles de nommage |
| `app-preview.sh up\|down\|status <uid> [app]` | Adresse d'essai d'un développeur (`/dev-<uid>`) : dossier de travail non commité, sans tests |
| `dev-db.sh ensure\|ensure-lab\|ensure-all\|status\|hba-status\|rotate\|lockdown-*` | Rôles et bases par propriétaire |
| `lab-lock.sh <commande>` | Exécute sous le verrou de déploiement (code 75 si occupé) |
| `workspace-image.sh` | Construit l'image `lab-workspace` des espaces VS Code |
| `storage-shares.sh [--check]` | Partages de groupe de `storage` attendus par les apps |
| `backup.sh [--check\|--list\|--local]` | Sauvegarde nocturne : bases, annuaire, storage, configuration hors dépôt ; copie locale et NAS |
| `setup2.sh <app> --yes` | Déploiement complet d'une app (ou de tout le lab) |
| `create-app-client.sh <app>` | Créer/mettre à jour le client Keycloak seul (`--native-redirect`, `--pkce`, `--no-env`) |
| `sso-lab/setup-code-server-auth.sh` | Créer le client Keycloak pour oauth2-proxy/code-server |
| `reset_url.sh` | Propager LAN/WAN/Keycloak dans tous les `.env` |
| `clean2.sh <app>` | Arrêter et supprimer les containers d'une app |
| `recompose_docker.sh --app <app>` | Rebuilder et redémarrer les containers d'une app |
| `get-ports-list.sh` | Régénérer `ports.env` depuis `.ports` |
| `open-freebox-ports.sh authorize\|status\|apply` | Redirections de ports sur une Freebox (API Freebox OS) |
| `open-bbox-ports2.sh` | Ouvrir les ports sur une Bbox |
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

---

## UI — identité « Foyer »

Toutes les apps du lab (11 sous-modules + les deux templates de scaffold) partagent une même
identité visuelle et une même structure de navigation, baptisées **Foyer** — déployée
intégralement le 2026-07-30 (avant cette date, chaque app avait sa propre nav en en-tête
horizontal ; ne plus reproduire ce pattern). La référence exécutable — tokens, polices,
comportements — est `_templates/django-angular/frontend/` (le cahier des charges d'origine,
`to_do_ui_foyer.md`, a été supprimé de la racine au commit `4d0478d`) : **la lire avant toute tâche
touchant la navigation ou les tokens visuels d'une app**, ce résumé n'en couvre que les points qui
piègent le plus souvent :

- **Aucune couleur en dur** dans un composant — toujours via les tokens CSS (`--accent`,
  `--bg`, `--text`…) définis en tête de `src/styles.scss`. C'est la seule chose qui permet au
  thème sombre (`prefers-color-scheme` + bascule manuelle `[data-theme]`) de fonctionner sans
  reprise page par page. Un `grep` rapide sur des valeurs hex dans un composant modifié est le
  test le plus simple pour détecter une régression.
- **Navigation toujours verticale**, jamais de bascule horizontal (PC) → burger (mobile) :
  sidebar rétractable ≥ 900px, recouvrement plein écran `position: fixed; inset: 0` < 900px.
  Rupture fixe à **900px** pour toutes les apps — ne jamais la faire varier d'une app à l'autre.
- **Les liens de nav sont propres à chaque app** — seule la structure (sidebar/recouvrement) est
  partagée. Avant de toucher la nav d'une app existante, lire son composant actuel et
  `app.routes.ts` pour en extraire la liste réelle des pages ; ne jamais copier les liens d'une
  autre app.
- **Polices self-hébergées** (Inter + JetBrains Mono, WOFF2 dans `src/assets/fonts/`) — jamais
  de CDN Google Fonts.
- **Cible tactile minimale 44×44px**, sans exception, sur tout élément interactif.
- **Toute nouvelle app créée via `new-app.sh` hérite de Foyer automatiquement** (le pattern vit
  dans `_templates/`) — aucun travail supplémentaire à prévoir pour une app scaffoldée
  normalement. Le sujet ne redevient pertinent que pour une modification de nav/UI sur une app
  **existante**, ou une évolution du système Foyer lui-même (auquel cas mettre à jour
  `_templates/` en plus de l'app concernée, sous peine de désynchroniser les futures apps).
- Routes, URLs, logique métier, appels API et code backend sont **hors périmètre** de tout ce
  qui touche à Foyer — une tâche UI qui semble impliquer un changement fonctionnel est un signal
  pour s'arrêter et clarifier plutôt qu'improviser.
