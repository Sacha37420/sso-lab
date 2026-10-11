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

- **`to_do_storage.md`** — `storage` est un service du cadriciel dont l'interface n'a presque aucun
  geste usuel de gestionnaire de fichiers (analyse du 2026-10-11 : 1 geste présent sur 27). Plan
  par lots ; décisions du propriétaire du 2026-10-11 dans le fichier. **Lots 0, 1 et 2 en
  service** : contenu actif neutralisé (`api/content_safety.py`), sélection, clavier, menu
  contextuel, suppression annulable, glisser-déposer, file d'envoi, conflits de nom. Tests :
  `python manage.py test --settings=config.settings_test api` (backend) et
  `LAB_ROOT=$PWD bash storage/frontend/e2e/jouer-gestes.sh --deploye` (25 gestes en navigateur
  réel, compte `e2edev`). Reste connu : `?token=` en paramètre d'URL (trois frontends s'en servent).
  **Neuf apps consomment son API** (les six listées plus bas, plus `code-route`, `craft-lab` et
  son propre frontend) : aucune route existante ne doit changer.
- **Sauvegardes** — aucune procédure (voir « Installer le lab »).
- **Constats de relecture laissés au propriétaire** : `chantiers/multi-dev/rapports/` (`relecture-lab-admin.md`,
  `audit-installation.md`) — documentation d'API publique et `.env` complet dans le conteneur
  nginx du frontend (défauts du gabarit, donc de toutes les apps), deux lanceurs de tests de
  cloisonnement, page « Apps du lab » redondante avec « Projets ».

### Huit apps sur quinze n'ont aucun test de cloisonnement ⚠️

`analyse-lora`, `app-builder`, `arbre-genealogique`, `atelier-3d`, `conciergerie`, `lab-admin`,
`restauration` et `traitement-de-fichiers-compils` n'ont **pas** de
`frontend/e2e/cloisonnement.spec.ts` (recompté le 2026-08-16 sur l'arborescence réelle ; le relevé
du 2026-08-09 en oubliait un et ignorait `oauth-hub`, créée depuis). Les sept autres l'ont.

Ce qui rend le trou dangereux : **le runner répond `[]` pour ces apps, sans erreur ni
avertissement** — une app sans spec est donc indiscernable, dans lab-admin comme en ligne de
commande, d'une app dont tous les tests passent. Or ce test est présenté plus bas comme *le*
contrôle automatisé du cloisonnement, et le lab est exposé sur Internet.

C'est peu coûteux à combler : le spec est **copiable tel quel** depuis
`_templates/django-angular/frontend/e2e/cloisonnement.spec.ts` (il ne doit dépendre d'aucun contenu
propre à l'app — c'est sa règle de conception), et `e2e_member` porte désormais une adresse email,
donc les tests peuvent aller au-delà du simple accès à la page. Vérifier ensuite app par app :

```bash
docker exec lab-runner sh -c "curl -s -X POST -H 'Content-Type: application/json' \
  -d '{\"app\":\"<app>\"}' http://localhost:4300/run"
```

Une réponse `[]` signifie « aucun test trouvé », jamais « tout va bien ».

À envisager en même temps : faire échouer bruyamment `setup_unit.sh` (ou l'affichage de lab-admin)
quand une app déployée n'expose aucun spec, pour que le trou ne puisse plus réapparaître en silence.

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
- Pour `admins` en plus : « Apps du lab », « Nouvel utilisateur », « Debug ». Les anciennes routes
  `/outils`, `/conception` et `/code` (la route Angular, pas code-server) sont des redirections.
- Toute nouvelle vue backend est d'admin tant qu'elle ne déclare rien (`IsLabAdmin` par défaut) ;
  toute nouvelle route Angular d'admin porte `adminGuard`. Les tests backend demandent un
  PostgreSQL jetable (le rôle `lab` ne peut pas créer de base) : commande en tête de
  `lab-admin/backend/api/tests.py`.

### Qui est quoi

- **Superutilisateur** : `LAB_SUPERUSER` dans le `.env` racine (`sacha`). **Jamais un groupe LDAP** :
  `e2e_member` est dans `admins` *et* `developers`.
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
| **Espace de travail** | `workspace/` (image `lab-workspace`), conteneur `ws-<uid>` | Un VS Code par projet, à la demande : code-server, Claude Code, Mistral Vibe. Pas de Docker, pas de `sudo`, ni `dev-net` ni `sso-net` |
| **pgAdmin par dev** | conteneur `pg-<uid>`, relais `lab-pg-relay` (`lab-mcp/pg-relay/`) | Un pgAdmin à la demande vers la **seule** base du dev, sans mot de passe enregistré, sur un réseau interne qui ne joint que le relais PostgreSQL |
| **Comptes d'envoi d'email** | `lab-mcp/labmcp/smtp.py`, `scripts/app-smtp.sh`, `scripts/app-restart.sh` | Un dev définit ses comptes SMTP ; le lab pose les variables `EMAIL_*` de Django dans l'app. **Pas de service d'envoi** : l'app parle à son fournisseur |
| **Scripts** | `scripts/app-*.sh`, `validate-app.sh`, `check-app-name.sh`, `dev-db.sh`, `lab-lock.sh`, `lib/registry.sh` | Les seules commandes que le moteur exécute |

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
- **`lab-admin` a deux niveaux** : la porte (`admins,developers`) et l'administration (`admins`,
  permission DRF par défaut `IsLabAdmin`). Toute nouvelle vue est d'admin tant qu'elle ne déclare
  rien ; toute nouvelle route Angular porte `adminGuard`. Ne jamais recréer `lab-admin-backend`
  sur une image antérieure au commit `c4449e8` avec `KEYCLOAK_REQUIRED_GROUPS=admins,developers`.
- **`code-server` (`/code`) est réservé au groupe `admins`** (`OAUTH2_PROXY_ALLOWED_GROUPS`,
  `sso-lab/docker-compose.yml`) : il monte tout le dépôt, le socket Docker, `~/.ssh` et
  `~/.claude` — y entrer vaut un accès root à l'hôte. Il était ouvert à `developers` jusqu'au
  2026-10-11 (constaté par audit, refermé). **Ne jamais y remettre `developers`.** `e2e_member`,
  membre d'`admins`, y entre : c'est un compte synthétique à mot de passe long, mais c'est un
  second chemin vers l'hôte à garder en tête.
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

### Règles de développement imposées à tout projet (IA comprises)

Chaque projet scaffoldé porte `FEUILLE_DE_ROUTE.md` (lots, tests à passer par lot, « vérifié le »),
`CLAUDE.md` et `AGENTS.md` (lu par Mistral Vibe) — gabarits dans `_templates/regles/`, copie
globale dans chaque espace de travail (`workspace/regles-lab.md`). **Imposé par la machine** :
feuille de route présente et bien formée, `frontend/e2e/cloisonnement.spec.ts` présent, tests
backend verts avant mise en service, verdicts enregistrés avec chaque déploiement
(`<LAB_STATE_DIR>/deployed/<app>.json`). Non imposable : la qualité des tests écrits.

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
- Ces trois corrections sont **en service** dans toutes les apps depuis le 2026-10-11, sauf
  `atelier-3d` et `bilan-thermique` (reconstruction reportée par le propriétaire : heures de
  compilation pour l'une, commit « wip » en tête pour l'autre) et `test` (au prochain déploiement
  par le moteur). Ces trois-là ont la première règle seulement ; leur documentation d'API répond
  encore sans connexion.
- **Reconstruire sans couper** : construire l'image pendant que l'ancienne tourne, lancer
  `scripts/app-test.sh <app>` dessus, puis `up -d --no-build` — c'est l'ordre du chemin à portes.
  `setup2.sh` sur une app historique commence au contraire par `clean2.sh` (arrêt, volumes non
  externes supprimés) et laisse l'app coupée pendant tout le build.
- **Un lanceur de tests qui a besoin d'options le dit dans `FEUILLE_DE_ROUTE.md`** (section
  « Commande de test ») : `peripheriques` et `storage` exigent `--settings=config.settings_test`,
  sans quoi leurs tests prennent le `.env` de service et échouent. `lab-admin` reste à part : son
  rôle `lab` ne peut pas créer de base de test, `app-test.sh` ne sait pas le tester (procédure à
  PostgreSQL jetable en tête de `lab-admin/backend/api/tests.py`).
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
  courante, jamais un paramètre, seulement sous l'origine et le préfixe de l'app). **Le même
  défaut est dans `_templates/` et dans toutes les autres apps**, non corrigé.
- **Le noyau rend le commentaire d'une règle iptables entre guillemets** : un script qui cherche
  ses propres règles par leur commentaire sans en tenir compte les pose en double et ne sait plus
  les retirer (constaté sur des règles de test).
- **L'image pgAdmin ne démarre pas sous `cap_drop ALL` seul** (son Python porte une capacité de
  fichier) : il lui faut `NET_BIND_SERVICE`. Démarrage : 35 à 55 s.

### État de la bascule

Bascule des 16 apps historiques faite le 2026-10-11 (bases `dev_sacha`, `gis_sacha`, `lab` ;
applications dans `deploiement/`). Les anciens schémas de `devdb`/`gisdb` sont supprimés. Le moteur, la passerelle, `lab-admin` et le runner sont en
service et vérifiés avec les comptes de test. Ce qui reste à faire avant d'ouvrir le lab à un autre développeur (autorisations `oauth-hub`,
durcissement de l'hôte, bascule des 17 apps vers `dev_sacha` et `deploiement/`, parcours réel d'un
dev) est suivi dans `chantiers/multi-dev/BASCULE.md` — non versionné, à lire avant toute action
sur ce sujet. Depuis le 2026-10-11 la séparation des bases est effective pour les rôles de dev (voir « Base de
données ») ; les apps historiques partagent encore le rôle `devuser` jusqu'à leur bascule.

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
  `open-bbox-ports2.sh` (ouverture NAT côté routeur) — sans effet sur le routage applicatif de
  Caddy désormais, mais toujours corrects pour cet usage-là, ne pas les supprimer.
- Toute modification de `edge-net` ou des `ports:` de `caddy`/`caddy2` affecte **les deux**
  cadriciels à la fois : à faire uniquement en présence de l'utilisateur, jamais en autonomie.

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
- **Rien de ce qui suit n'est dans un dépôt** — le perdre, c'est perdre le lab : tous les `.env`,
  `infra/dev-roles.env`, `sso-lab/ldap/init.ldif`, `.ports`, `.devs`, `.owners`, `.lab-state/`
  (clés de déploiement, comptes d'envoi), `~/edge-router/`, `~/lab-work/`, et les volumes Docker.
  `OAUTH_HUB_ENCRYPTION_KEY` en fait partie. **Aucune sauvegarde n'est programmée** (chantier
  ouvert) ; les seules existantes sont manuelles, dans `~/sauvegardes/`.
- Un projet privé enregistré comme sous-module porte `update = none` dans `.gitmodules` (posé par
  `app-register.sh`) : sans cela, `git clone --recurse-submodules` avorte pour quiconque n'y a pas
  accès, et n'extrait aucun sous-module.

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

### PKCE et clients publics — pourquoi ce n'est pas activé partout

`create-app-client.sh` accepte `--native-redirect <uri>` (répétable) et `--pkce` / `--no-pkce`.
PKCE S256 est posé **automatiquement** sur tout client ayant une URI native, et disponible en opt-in
ailleurs. Il n'est **pas** posé par défaut sur les clients publics, malgré la règle générale, pour
une raison vérifiée : **keycloak-js 22.0.5 n'envoie `code_challenge` que si `pkceMethod` est passé
explicitement à `init()`** (`node_modules/keycloak-js/dist/keycloak.js:811`), et **aucun des 14
frontends Angular du lab ne le fait**. Poser l'attribut sur les clients publics existants les
casserait tous d'un coup (`Missing parameter: code_challenge`).

Pour généraliser : ajouter `pkceMethod: 'S256'` dans `<app>/frontend/src/app/core/keycloak.service.ts`
**et** dans `_templates/django-angular/`, app par app, puis relancer avec `--pkce`. Chantier ouvert,
non fait.

> ⚠ Trou préexistant repéré au passage, **non corrigé lab-wide** : le bloc de création de
> `create-app-client.sh` pose `redirectUris: ["*"]` et `webOrigins: ["*"]`. Un joker de redirection
> sur un client public autorise le renvoi du code d'autorisation vers n'importe quelle URL — ce qui
> annule le bénéfice de PKCE. Le joker n'est purgé que sur les clients à URI native
> (`--native-redirect`), parce que les clients web du lab s'appuient aujourd'hui dessus pour les
> accès LAN/WAN non calculés : les purger tous couperait des accès en service sans prévenir. À
> reprendre en même temps que le chantier PKCE ci-dessus.

`--no-env` (nouveau) crée un client **sans écrire de `<app>/.env`** : pour un client dont
l'application vit hors de `dev/` (application de bureau, autre dépôt). Sans lui, le script créait un
dossier vide avec un `.env` orphelin que rien ne déployait. Utilisé par `storage-analysis`.

---

### Périphériques de l'hôte — `peripheriques`

`peripheriques` (Django + Angular + `media/`, 8101 / 4216) donne accès, en direct et en relecture,
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
- Port ICE **8189 udp/tcp** publié par `lab-media`, redirigé à la main sur la Bbox.
- Vérification rejouable sans matériel : `bash lab-media/verify.sh` (sources synthétiques, deux
  apps fictives, 99 contrôles). MediaMTX écrit l'URL du hook, donc sa clé, dans son journal quand
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
E2E** dans une app sans d'abord mettre à jour cette section — le pipeline (catalogue + exécution
ci-dessous) suppose un seul fichier, ce nom précis.

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
  les groupes existants (toujours le cas « membre » positif, quelle que soit l'app testée), et
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
| `install.sh [--check]` | Installation rejouable du lab ; `--check` ne fait rien et dit ce qui manque |
| `new-app.sh [--owner <uid>]` | Scaffold d'une nouvelle app dans `deploiement/` (appelé par le moteur) |
| `app-register.sh`, `app-sync.sh`, `app-remote.sh`, `app-status.sh`, `app-logs.sh`, `app-env.sh`, `app-test.sh`, `app-smtp.sh`, `app-restart.sh`, `app-remove.sh`, `app-relocate.sh` | Les commandes d'exploitation d'une app — les seules que le moteur exécute. Chacune documente son usage en tête de fichier |
| `validate-app.sh`, `check-app-name.sh` | Contrôle de sûreté d'un dépôt avant déploiement ; règles de nommage |
| `dev-db.sh ensure\|ensure-lab\|ensure-all\|status\|hba-status\|rotate\|lockdown-*` | Rôles et bases par propriétaire |
| `lab-lock.sh <commande>` | Exécute sous le verrou de déploiement (code 75 si occupé) |
| `workspace-image.sh` | Construit l'image `lab-workspace` des espaces VS Code |
| `storage-shares.sh [--check]` | Partages de groupe de `storage` attendus par les apps |
| `setup2.sh <app> --yes` | Déploiement complet d'une app (ou de tout le lab) |
| `create-app-client.sh <app>` | Créer/mettre à jour le client Keycloak seul (`--native-redirect`, `--pkce`, `--no-env`) |
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
