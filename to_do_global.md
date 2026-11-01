# to_do_global — reste à faire du lab, vue d'ensemble

Analyse du 2026-10-31, **en lecture seule** : rien n'a été corrigé, déployé ni commité pendant
l'analyse. Elle couvre les 17 apps, les services du cadriciel, les scripts d'installation et de
déploiement, les gabarits et la documentation.

Ce fichier contient trois choses :
- les **urgences** ;
- les **chantiers transverses**, qui touchent plusieurs apps ou le cadriciel ;
- un **pointeur vers la feuille de route de chaque app**.

Le détail propre à une app vit dans son dépôt, dans `FEUILLE_DE_ROUTE.md`. C'est le format que la
machine lit déjà : `validate-app.sh` vérifie sa présence et son format, et `app-test.sh` y prend la
commande de test.

**Légende**
- **P1** : sécurité ou perte de données. **P2** : fonctionnel. **P3** : propreté ou documentation.
- **[C]** : constaté (code lu, état réel, commande lancée). **[D]** : déduit, sans l'avoir exécuté.
- **Ⓟ** : demande une décision ou une action du propriétaire.
- **⚙ chantier** : relève du régime chantier (skill `chantier`, contrat écrit avant tout subagent).

---

## Tests à mener par le propriétaire (liste tenue à jour)

Ne restent ici que les vérifications que la machine ne peut pas faire : un compte humain, de vraies
clés, un vrai site, du matériel ou un coût. Ce que `lab-runner` sait vérifier avec les comptes de
test est fait, et coché dans la feuille de route de l'app.

**Fait par la machine le 2026-11-01**, sur les 16 apps et avec `e2e_member`, sans rien laisser derrière :
- PKCE S256 à la connexion ;
- un lien direct revient sur sa page après la connexion ;
- polices WOFF2 en 200 ;
- aucune requête avec `token=` ;
- `Authorization` envoyé seulement à l'API de l'app (plus storage pour craft-lab, le moteur et
  app-builder pour lab-admin) ;
- une photo d'atelier-3d et les icônes de craft-lab s'affichent par `blob:` ;
- le média d'un arbre privé est lu par son propriétaire et refusé à un autre compte (404) ;
- le relais de craft-lab ne voit ni `DB_` ni `SECRET` ;
- les clés déjà enregistrées côté serveur (code-route, craft-lab, restauration, robot-lab) se
  déchiffrent toutes.

**Après le chantier « failles »**
- [ ] Te connecter avec ton compte (et ton OTP s'il y en a un) à deux ou trois apps : Keycloak 26.
- [ ] Ressaisir une fois les clés qui étaient gardées dans le navigateur, puis faire un appel réel
      avec chacune :
  - app-builder : clés Claude et Mistral, une conversation ;
  - traitement-de-fichiers-compils : clé OCR Mistral, un OCR ;
  - carto-lab : clé Météo-France, la page Météo ;
  - arbre-genealogique : identifiants des fournisseurs externes, une recherche.
- [ ] Un appel IA réel dans code-route (génération), craft-lab et robot-lab ; un appel Météo-France
      dans restauration. Leurs clés se lisent, mais aucun appel n'a été fait.
- [ ] craft-lab : une partie multijoueur, textures Phaser en jeu.
- [ ] robot-lab : une session sur un vrai site HTTPS (le proxy de sortie de l'engine).
- [ ] Ouvrir la console Keycloak par tunnel (`ssh -L 8080:localhost:8080 …`) : Caddy ne la sert plus.
- [ ] **Le 2026-11-08** : fin de la fenêtre de retour arrière de Keycloak (PROCEDURE.md § 6), et fin
      du gel. Ensuite, faire tourner le mot de passe PostgreSQL (`rotate-db-password.sh`) : il est
      apparu dans un journal de session.

**Dans les apps** (détail dans leur feuille de route)
- [ ] peripheriques : direct H.264, WebRTC depuis le WAN, révocation pendant une lecture, HD USB Camera.
- [ ] code-route : les 8 scénarios de `route-robot.md` (lot 2).
- [ ] traitement-de-fichiers-compils : partage à un destinataire puis retrait ; recadrage, filtres, PDF (lot 3).
- [ ] carto-lab : QGIS ouvre une couche publiée (lot 2).
- [ ] storage : glisser depuis le bureau, tactile, lecteur d'écran.

**Lab multi-dev** (T10) : redémarrage de l'hôte et règles `lws`, webhook push, ticket et commits
GitHub, `me/init` d'un compte neuf, pgAdmin personnel, conversation Claude et Vibe, `lab-essai`,
création d'un projet avec graine App Builder jusqu'au déploiement.

---

## État au 2026-11-01, après le chantier « failles » (`chantiers/failles/`)

Les 16 failles F1 à F16 du contrat sont corrigées et **en service** ; tout est commité et poussé.

**Fait**
- [x] **§ 1.3 (F1)** : tout port publié est lié à `127.0.0.1`, apps, Keycloak, LDAP, pgAdmin et phpLDAPadmin compris.
      `validate_compose.py` refuse le reste dès qu'un domaine est configuré.
- [x] **T3 (F2 à F4)** : gabarits et 16 apps — `tokenBases()`, `redirectUri` borné, PKCE S256, polices relatives,
      `.dockerignore`. Chaque client est en PKCE exigé, avec ses seules URI (`--prune-uris`).
- [x] **§ 1.4 (F12)** : plus aucun joker `*` sur un client actif ; `front-cadriciel` et `infra` sont désactivés.
- [x] **T4 (F5)** : plus de `?token=` nulle part, storage compris.
- [x] **F6, F7** : clés d'API dans un coffre serveur (`VAULT_ENCRYPTION_KEY`), plus rien en `localStorage`.
      `SECRET_KEY` peut tourner sans rien détruire (fait pour craft-lab).
- [x] **F8** conciergerie, **F9** craft-lab, **F10** lab-admin : voir leurs feuilles de route.
- [x] **F11** : Keycloak 26.8.1 en `start --optimized` sur PostgreSQL. La console et le realm `master` ne sont plus servis.
      Retour arrière possible jusqu'au 2026-11-08, et **gel** jusque-là (CLAUDE.md, « Keycloak 26 »).
- [x] **F13, en partie** : `e2e_member` n'est plus dans `admins`. Le runner monte toujours tout le dépôt (R1 ouvert).
- [x] **F14 / W1** : `lab-workspace:latest` en Node 22 (`workspace/verify.sh` 293/293). Un espace déjà ouvert garde l'ancienne image.
- [x] **F15** : bail fixe `192.168.1.50` pour le serveur sur la Freebox.
- [x] **F16** : secret du compte de service d'arbre-genealogique régénéré.

**Reste**
- [x] Images d'atelier-3d, d'arbre-genealogique et de craft-lab : vérifiées le 2026-11-01 (`lab-runner`).
      Coffres, appels réels et textures Phaser : voir « Tests à mener par le propriétaire ».
- [ ] Ouverts, hors de ce chantier :
  - le runner monte tout le dépôt (R1) ;
  - restauration rend les 4 derniers caractères d'un secret ;
  - le frontend de tdfc s'installe par `npm install` ;
  - GitHub App pour oauth-hub ;
  - `manage-users` de restauration à restreindre par les permissions fines de Keycloak 26 ;
  - `create-app-client.sh` affiche les secrets en clair ;
  - la carte « console Keycloak » de lab-admin ne mène plus nulle part ;
  - `code-server`, `carto-ogc` : clients confidentiels, joker retiré, mais aucun PKCE ;
  - `dev2/`.
- [ ] Le 2026-11-08 : fin de la fenêtre de retour arrière de Keycloak (PROCEDURE.md § 6).

## État au 2026-10-31, après le chantier « urgences » (`chantiers/urgences/`)

Huit secteurs ont rendu `OK` sur le contrat v1. Les correctifs sont **en service**, commités et poussés dans
leurs sous-modules. Le cloisonnement a été rejoué par `lab-runner` (3/3) sur restauration, lab-admin, storage,
robot-lab, craft-lab et analyse-lora.

**Fait**
- [x] **U3** : formules d'analyse-lora évaluées sur l'AST. Au passage, la clé d'ingestion est réservée à `developers`, aussi sur `/connection/`.
- [x] **U4** : restauration — un manager ne gère que les comptes de l'app, et ne peut ni se désactiver ni se retirer `manager`.
- [x] **U1, côté robot-lab** : proxy de sortie dans l'engine, `start_url` validée, engine sans `.env`.
- [x] **§ 1.1, runner (cœur de R1) et R2** : seul le spec du gabarit est joué, le nom d'app est validé, `init: true`, README.
      Restent le montage de tout le dépôt, la sortie réseau du navigateur et la mise à jour de Playwright.
- [x] **§ 1.2** : `robot-lab-engine` et `craft-lab-relay` ne reçoivent plus que leurs variables.
- [x] **§ 1.3, lab-admin** : ports liés à `127.0.0.1`, mot de passe rendu seulement si l'email n'est pas parti.
      Les autres services publient toujours sur `0.0.0.0`.
- [x] **T4, première étape** : storage n'accepte plus `?token=` qu'en GET/HEAD sur la route de contenu.
- [x] `./backend:/app` retiré d'arbre-genealogique et de restauration ; limite de 50 Mo par média dans arbre-genealogique.

**Reste**
- [x] **U1, côté réseau** : code-server sur le réseau `code-net`, partagé avec oauth2-proxy seul. **En service le 2026-10-31**
      (commit `d6d703e`) : `robot-lab-engine` et `lab-runner` ne résolvent plus `code-server` ; `/code/` répond 302 vers Keycloak.
- [x] **U2** (NAS) : bail DHCP fixe `192.168.1.136` pour `truenas` posé par l'API Freebox, `LAB_BACKUP_NAS` corrigé ;
      sauvegarde lancée à la main le 2026-10-31 à 22 h 46 : « ✓ Sauvegarde complète », 20 fichiers déposés et vérifiés sur le NAS.
- [x] **U5** : travail de `test-video` commité et poussé le 2026-10-31 (`c2f21bb`, Lot 2 toujours en cours).
- [ ] À vérifier en navigateur réel :
  - images d'atelier-3d, icônes de craft-lab, médias d'un arbre privé (`?token=` restreint) ;
  - une partie multijoueur de craft-lab ;
  - une session robot-lab sur un vrai site HTTPS.
- [ ] Non commités, à dessein : ce fichier, les `FEUILLE_DE_ROUTE.md` et les `to_do_*.md` déplacés. Ils décrivent
      des failles encore ouvertes et les dépôts sont publics : à relire avant toute publication. Le dépôt parent
      a 2 commits locaux non poussés (`9f81339`, `68633ef`).

## 0. Urgences — à traiter avant tout le reste

| # | Constat | Où | Action |
|---|---|---|---|
| U1 | **P1 [C] Tout membre de `developers` peut atteindre `code-server`, donc root sur l'hôte, par robot-lab.** `code-server` tourne en `--auth=none` sur `sso-lab_sso-net`. `robot-lab-engine` est sur ce même réseau, et `Robot.start_url` est un `URLField` sans filtre (`api/models.py:50`). La vue live permet donc d'ouvrir `http://code-server:8091/` puis un terminal, alors que code-server monte `docker.sock`. Plus largement, **tout conteneur d'app relié à `sso-net` joint code-server** sans passer par oauth2-proxy. | `sso-lab/docker-compose.yml`, robot-lab | 1) Mettre code-server sur un réseau `internal` dédié qu'il partage avec `oauth2-proxy-code` seulement (fichier d'architecte, Ⓟ : touche `sso-lab`). 2) robot-lab lot 2 (filtre de destinations de l'engine). |
| U2 | **P1 [C] La copie NAS des sauvegardes échoue depuis le 2026-10-30** (« NAS injoignable //192.168.1.85/Saves », `~/sauvegardes/lab/2026-10-3*/RAPPORT.txt`). Cela coïncide avec le passage à la Freebox ; le NAS a probablement changé d'adresse. Seule la copie locale existe. | `scripts/backup.sh`, `.env` racine (`LAB_BACKUP_NAS`) | Ⓟ Réserver un bail DHCP fixe pour le NAS sur la Freebox, corriger `LAB_BACKUP_NAS`, puis lancer `bash scripts/backup.sh`. Voir T5. |
| U3 | **P1 [C] Exécution de code dans analyse-lora** : `_safe_eval` fait `eval()` avec `__builtins__` vidé (`backend/api/views.py:236`). Ce n'est pas un bac à sable, et tout titulaire d'un accès au capteur (`amis`, `famille`) écrit la formule. | [analyse-lora](deploiement/analyse-lora/FEUILLE_DE_ROUTE.md) lot 2 | Évaluateur par AST, liste blanche. |
| U4 | **P1 [C] Dans restauration, un `manager` peut désactiver ou réinitialiser n'importe quel compte du realm**, `sacha` compris. Les vues `views_users.py:103-148` prennent un `user_id` arbitraire, et le compte de service a `manage-users`. | [restauration](deploiement/restauration/FEUILLE_DE_ROUTE.md) lot 2 | Restreindre aux membres des groupes de l'app. |
| U5 | **P1 [C] Le travail du didacticiel `test-video` n'est ni commité ni sauvegardé.** Il est non commité depuis le 2026-10-14 dans `~/lab-work/sacha/test-video` (chapitres, pages, tests), et la sauvegarde nocturne exclut `~/lab-work`. | `~/lab-work/sacha/test-video` | Ⓟ Commit et push depuis l'espace de travail. Le moteur ne lance jamais git dans ce dossier. |

---

## 1. Avant d'ouvrir le lab à un autre développeur (bloquants)

Aujourd'hui seuls `sacha` et des comptes synthétiques développent ; ces points deviennent
exploitables dès l'arrivée d'un tiers dans `developers`.

1. **P1 [C] Le runner exécute du code écrit par un développeur avec tous les secrets à portée.**
   - Il monte tout le dépôt (`runner/docker-compose.yml:33`, `${HOST_DEV_ROOT}:/mnt/dev:ro`), donc tous les `.env`, dont `sso-lab/.env`.
   - Il exécute le `frontend/e2e/*.spec.ts` du dépôt du développeur : `validate-app.sh` n'en vérifie que la présence.
   - Il reçoit `E2E_MEMBER_PASSWORD`, alors que `e2e_member` est dans `admins`, donc entre dans `/code`.
   - `sso-net` n'est pas `internal`.
   - ⚙ chantier R1 : conteneur jetable par exécution, montage limité au dossier `e2e/`, spec imposé égal au gabarit, réseau sans sortie, `e2e_member` hors `admins`.
2. **P1 [C] `robot-lab-engine` et `craft-lab-relay` reçoivent `env_file: .env` complet** : `SECRET_KEY`, qui est aussi la clé Fernet des clés IA, et `DB_PASSWORD` de `dev_sacha`, propriétaire des schémas des 12 apps. Ils n'en lisent que 2 ou 3 variables. Voir les feuilles de route de [robot-lab](deploiement/robot-lab/FEUILLE_DE_ROUTE.md) et [craft-lab](deploiement/craft-lab/FEUILLE_DE_ROUTE.md).
3. **P1 [C] Ports publiés sur toutes les interfaces** : lab-admin (8083/4201), storage (8093), oauth-hub (8100), app-builder (8087), et vraisemblablement chaque app selon `.ports`. L'API reste authentifiée, mais tout le LAN contourne Caddy. Lier à `127.0.0.1` ou retirer les `ports:`, ce qui touche `validate_compose.py` et `.ports`.
4. **P1 [C] `redirectUris: ["*"]` sur 21 clients Keycloak**, plus des URI vers l'ancienne IP WAN : `create-app-client.sh:932-938` ne fait qu'ajouter. Voir T3.
5. **P2 [C] Le parcours réel d'un développeur n'a jamais été joué** : première connexion d'un vrai compte, GitHub, projet, espace, `lab-essai`, push, déploiement, webhook, ticket, pgAdmin personnel connecté. Voir T10.

---

## 2. Chantiers transverses

### T1 — Un seul chemin de déploiement · P1/P2 · ⚙ chantier (scripts + 12 apps)

**Constat [C].** Il existe quatre façons de déployer, qui divergent :
- le moteur : `app-sync` → `validate` → `setup2` → `setup_unit` ;
- `setup2.sh <app>` lancé à la main, qui déploie l'arbre de travail sans synchronisation ;
- `install.sh` → `setup_unit` ;
- `setup2.sh --yes`, qui dispatche en parallèle.

Seule `test-video` a une ligne `.owners`. **Les 12 apps historiques passent donc par l'ancien ordre** :
`clean2.sh`, build, démarrage, **sans `app-test.sh`**. L'app est coupée pendant le build et ses tests
ne conditionnent rien (`setup_unit.sh:65-75`). Le moteur ne leur applique aucune porte
(`lab-mcp/labmcp/chain.py:145-156`). CLAUDE.md affirme le contraire : « tests joués avant chaque mise
en service ».

- [ ] Feuille de route de chaque app, au format machine. **Écrite par cette analyse** : à relire,
      puis à commiter dans chaque sous-module (voir § 4).
- [ ] `validate-app.sh` :
  - [x] la règle `[service-account]` compte les commentaires comme des rôles (faux positif sur atelier-3d) — corrigé le 2026-11-01, même lecture que `create-app-client.sh` ;
  - [x] (2026-11-01, réservée aux apps du superutilisateur, lignes posées dans les deux feuilles de route) exemption déclarée du cloisonnement (`cloisonnement : aucun — <raison>` dans la feuille de
        route) pour arbre-genealogique et traitement-de-fichiers-compils, aujourd'hui refusées
        par `validate-app.sh:96`.
- [ ] Mises en conformité côté apps, détaillées dans leurs feuilles de route :
  - [ ] noms de service `worker` → `<app>-worker` (atelier-3d, bilan-thermique, carto-lab) ;
  - [ ] chemin Caddy `/carto-ogc` de carto-lab — Ⓟ décision : passer à `/carto-lab-api/ogc` ou ajouter une exception déclarée ;
  - [ ] `.keycloak-client-opts` suivi par git dans conciergerie ;
  - [ ] fichier de rôles non vide dans restauration.
- [ ] Ligne `.owners` `<app>:sacha` pour les 12 apps historiques, une fois chacune conforme. Elles
      passent alors au chemin à portes : build pendant que l'ancienne version tourne, tests, puis
      `up -d --no-build`.
- [ ] `setup2.sh <app> --from-origin` (passe par `app-sync`), puis retrait de la branche non gatée de `setup_unit.sh`.
- **Test.** Redéployer analyse-lora :
  - l'identifiant d'image ne change qu'après des tests verts ;
  - un test rouge provoqué laisse l'ancienne version en service ;
  - `.lab-state/deployed/<app>.json` porte les deux verdicts.

### T2 — Un point d'entrée unique et une installation sans surprise · P2 · S–M

- [ ] **`install.sh --check` ne conclut pas « rien à faire » sur la machine en service** [C] : il veut déployer `test-video`. Il déploierait en plus l'arbre de travail d'un projet privé sans `app-sync`.
- [ ] **`lab-media` est traité comme une app** par `install.sh` (l. 510-520) et par `setup2.sh --yes` [C/D] : risque qu'un client Keycloak sans groupe soit créé pour lui. Le corriger soit par `lab-media/.no-autodeploy`, soit par un `units.conf` (nom, type infra/cadriciel/app, priorité, RAM, Keycloak oui/non) lu par `install.sh`, `setup2.sh` et `app-priorities.conf`.
- [ ] **Répartiteur `scripts/lab`**, sans supprimer aucun script :
  - `install [--check]`
  - `deploy <app>|--all`
  - `status [<app>]`
  - `doctor` : `install --check`, `hba-status`, `storage-shares --check`, santé de la dernière sauvegarde, jokers Keycloak, cloisonnement jamais joué
  - `backup`
  - `restore`
  - `test <app>`
  - `logs`
  - `help`, généré depuis les en-têtes `# Usage`
- [ ] **Découper `setup2.sh`** (611 lignes, trois rôles) : déploiement d'une app, déploiement de tout le lab, opérations destructrices (`--restart-sso-lab`, `--rotate-secrets`). Garder `setup2.sh` comme enveloppe compatible, le moteur l'appelle.
- [ ] **`install.sh`** :
  - [ ] poser le cron de `backup.sh` et vérifier ses prérequis (`~/.lab-backup-nas`, image `lab-backup`) ;
  - [ ] corriger le message faux « rien n'est planifié » (`install.sh:579`, README:175).
- [ ] **Routeur** : Freebox par défaut dans la doc. Renommer `bbox.env` en `router.env` (renommage différé, plusieurs scripts le lisent).
- [ ] **Essais rejouables de l'installation** : `install.sh --check` sur un clone jetable, et `validate-app.sh` sur des dépôts piégés (`scripts/tests/`).
- **Test.**
  - `lab doctor` rend 0 sur la machine en service.
  - `lab help` liste chaque `scripts/*.sh`.
  - Sur un clone jetable, `install.sh --check` décrit ce qui manque.

### T3 — Gabarits et report dans les apps · P1/P2 · ⚙ chantier (17 apps, sécurité)

**Défauts du gabarit encore présents** [C] :

| Défaut | `_templates` | Apps encore touchées |
|---|---|---|
| L'intercepteur joint le jeton à **toute** origine (pas de `tokenBases()`) | oui | toutes sauf lab-admin |
| Lien direct qui retombe sur l'accueil (`redirectUri = env.appUrl`) | corrigé dans `django-angular`, **pas** dans `angular-only` | analyse-lora, arbre-genealogique, carto-lab, conciergerie, restauration (tdfc est en `check-sso`, non concernée) |
| `redirectUri` non limité à l'origine et au préfixe (`window.location.href` au lieu de `core/redirect-uri.ts` de lab-admin) | oui | les autres |
| Polices en URL absolue `url("/assets/…")`, donc 404 derrière Caddy | corrigé | analyse-lora, arbre, tdfc, restauration, atelier-3d, bilan-thermique, carto-lab, conciergerie, code-route, craft-lab, robot-lab, oauth-hub, test-video |
| `pkceMethod: 'S256'` absent | oui | toutes |
| `django-only` en retard sur `django-angular/backend` : pas de `PyJWKClientError` (500 sur un `kid` forgé), noms en dur « Test Django », pas de `FORCE_SCRIPT_NAME` | oui | aucune app ne l'utilise ; utilisé par le type 3 de `new-app.sh` |

**Ordre de travail**
- [ ] Ordre : `_templates/` d'abord, puis un même diff reporté app par app, puis `--pkce` client par
      client, puis `create-app-client.sh --prune-uris`. Ce dernier recalcule les URI exactes (LAN,
      WAN courante, DOMAIN), retire le joker et l'ancienne IP.
- [ ] Retirer Spring et le mode `legacy` devdb de `new-app.sh` (environ 400 lignes mortes, types 1/2,
      `devdb` en dur l. 946-947). Retirer aussi `clean2.sh:67,136-138`, `reset_url.sh:284` et
      `spring-app:8082` du `.ports` par défaut. Aucune app Spring n'existe.
- [ ] Vérifier que `workspace/regles-lab.md` est bien la copie de `_templates/regles/`.

**Test**
- Cloisonnement 3/3 par app.
- Lien direct conservé.
- WOFF2 en 200.
- Un `fetch` vers une autre origine part sans `Authorization` (Playwright).
- Aucun client avec `*` (requête admin).
- `new-app.sh` types 3, 4 et 5 sur un clone jetable, suivi de `essai.sh`.

### T4 — Sortir le jeton des URL (`?token=`) · P1 · ⚙ chantier (interface de storage, 9 consommateurs)

- [ ] [C] `storage` accepte `?token=` sur **toutes** les routes et méthodes (`api/authentication.py:105`), alors que seuls des `GET …/content/` en ont besoin. Première étape sans casse : [storage](storage/FEUILLE_DE_ROUTE.md), lot 2.
- [ ] Consommateurs qui le mettent dans des `<img src>` : arbre-genealogique (`core/api.service.ts:48-56`), atelier-3d (`:361`) et craft-lab (`:397-401`). Le JWT complet part dans l'historique et le `Referer`.
- [ ] Cible : ticket court à usage unique, ou `fetch` + `Blob` (déjà prévu dans le lot 5 de storage).
- **Test.**
  - Aucune requête d'image ne porte `token=`.
  - Les images d'un contenu privé s'affichent toujours, et un étranger reçoit 403.

### T5 — Sauvegarde et restauration · P1 · M–L

- [x] U2 : NAS de retour (2026-10-31) ; reste à voir une nuit complète « ✓ Sauvegarde complète ».
- [ ] `install.sh --check` / `lab doctor` signalent un `RAPPORT.txt` en défaut ou plus vieux que 26 h.
- [ ] **`scripts/restore.sh`** (`--list`, `--check <date>`, `<date> --only base:<nom>|ldap|volume:<v>|config`), avec restauration à blanc dans des conteneurs jetables (réutiliser `chantiers/tests/essai.sh`).
- [ ] Première restauration de Keycloak (copie à chaud d'une base H2), jamais jouée.
- [ ] Ⓟ **Chiffrement** : `seal()` est vide (`scripts/backup.sh:144`). Il faut une clé publique sur l'hôte et la clé privée chez le propriétaire (`age` conseillé).
- [ ] Ⓟ Côté NAS : le compte `saver` lisait le partage `Videos` au 2026-10-12, à restreindre.
- **Test.**
  - `restore.sh --check <date>` trouve autant de tables et de lignes qu'en service.
  - L'annuaire restauré répond à `ldapsearch`.
  - Une archive ne s'ouvre qu'avec la clé privée.

### T6 — Documentation claire et complète · P3 · M

**Principe.** Le README porte les procédures, CLAUDE.md les décisions et les pièges, et `docs/` les
guides par public.

**Corrections du README**
- [ ] §2.1 décrit encore la synchronisation du catalogue E2E (supprimée), un pipeline qui commence
      toujours par `clean2.sh`, et la « Méthode IA avancée » par `/code`, réservé à `admins`.
      Réécrire §2.1 autour de « lab-admin → Nouveau projet », avec la voie manuelle en annexe.
- [ ] Table des sous-modules :
  - « éditeur de code, catalogue E2E » pour lab-admin ;
  - « media ICE » pour peripheriques ;
  - `test-video` absent ;
  - « `dev/<app>/` ».
- [ ] La table des scripts omet `install.sh`, `backup.sh`, `dev-db.sh`, `lab-lock.sh`, tous les
      `app-*.sh`, `storage-shares.sh`, `workspace-image.sh` et `edge-router-install.sh`. Aucune
      mention de `backup.sh`, `app-preview` ni `/dev-<uid>`.

**Phrases fausses ou périmées de CLAUDE.md** [C]
- [ ] « Créer une nouvelle application », étapes 1 à 4 : `dev/<app>/`, `00_schemas.sql`,
      `gh repo create` à la main, `postgres (devdb)`. Les remplacer par un renvoi au README §2.
- [ ] « Les apps historiques partagent encore le rôle `devuser` » : faux depuis la bascule.
- [ ] « Le même défaut [redirectUri] est dans `_templates/` et dans toutes les autres apps » :
      corrigé dans le gabarit et dans 11 apps (voir T3).
- [ ] « atelier-3d et bilan-thermique non reconstruits » avec les trois correctifs du gabarit :
      ils sont en service dans les deux.
- [ ] « Tests backend joués par `app-test.sh` avant chaque mise en service » : faux pour les apps
      historiques (T1).
- [ ] « Aucun des 14 frontends » : il y en a 16.
- [ ] « Pour admins en plus : Apps du lab, Nouvel utilisateur, Debug » (l. 108) : Apps du lab et
      Debug sont des redirections.
- [ ] Constats « page Apps du lab redondante » et « deux lanceurs » (l. 66-68) : réglés.
- [ ] § Tests E2E « un seul fichier » : storage a aussi `e2e/gestes.spec.ts`, autorisé par la décision Q6.
- [ ] Tableau des sous-modules : `test-video` absent.
- [ ] Les doublons README/CLAUDE.md (base de données, cloisonnement, Foyer, vitrine, E2E) sont
      rédigés deux fois. Garder un texte, l'autre renvoie.

**Guides à créer**
- [ ] `docs/developpeur.md` : compte → première connexion → projet → espace → essai `/dev-<uid>` → push → déployer → lire les verdicts.
- [ ] `docs/exploitation.md` : que faire quand le NAS est injoignable, l'IP change (rappeler `MEDIA_WEBRTC_HOSTS`), Keycloak est arrêté, le disque est plein, ou `install --check` n'est pas vide.
- [ ] `docs/restauration.md` (avec T5).
- [ ] Glossaire : cadriciel, unité, app à portes, essai.

**Autres**
- [ ] Commentaires périmés :
  - `dev-db.sh:29-30` (`lockdown-*` « jamais appelés ») ;
  - `infra/docker-compose.yml:132` (renvoie à `setup-keycloak-pgadmin.sh`, mort) ;
  - `init-secrets.sh` (`./rotate-secrets.sh`) ;
  - `runner/server.js:20-28` (« worker Celery », `setup_unit.sh`) ;
  - `SCRIPT_DIR` qui désigne la racine dans `clean2.sh:8`, `rotate-db-password.sh:33` et `create-app-client.sh:142`.
- [ ] `chantiers/multi-dev/BASCULE.md` : cocher ce qui est fait (l. 12, 19, 28, 34-37).
- **Test.**
  - Le grep de `dev/<app>`, `devdb` (hors historique), `catalogue`, `Prompts de déploiement` et
    « rien n'est planifié » ne rend plus rien.
  - Chaque script apparaît dans `lab help` ou dans le README.

### T7 — code-server portable · P2 · S

- [ ] [C] `sso-lab/docker-compose.yml:239-254` et `sso-lab/code-server/Dockerfile:5-7` fixent en dur `1000:1000`, le GID docker `989` et `/home/sacha/{dev,dev2,.claude,.ssh}` (point S18). Passer par `${LAB_HOME}`, `${LAB_UID}` et `${DOCKER_GID}`, posés par `install.sh`, avec `dev2` en override. À faire en même temps que le réseau dédié de U1.
- **Test.** `docker compose config` identique sur cet hôte.

### T8 — Ménage · P3 · S

- [ ] Ⓟ **26 images `rollback/*:prev`**, dont 2 × 12,5 Go pour atelier-3d, et l'image orpheline `lab-admin-worker:latest`.
- [ ] Code mort « legacy devdb » :
  - `new-app.sh:249,336,343-375` ;
  - `ensure-schemas.sh:90` ;
  - `app-test.sh:35,107` ;
  - `setup2.sh:15`.
- [ ] `scripts/verify-setup2-routine.md` (prompt de juillet, obsolète) et `infra/setup-keycloak-pgadmin.sh` (plus appelé) : à supprimer après un grep de confirmation.
- [ ] Dépôt public : `chantiers/app-builder-lab/`, `essai-dev/` et `webcams/` ne sont ni suivis ni ignorés (l'exclusion des autres vit dans `.git/info/exclude`, local à la machine). Les ajouter à `.gitignore` (`chantiers/*`), sinon un `git add -A` publierait des rapports de défauts.
- [ ] Branche `worktree-agent-a92726caa5e3e0dce` d'app-builder, déjà fusionnée.
- [ ] `KEYCLOAK_URL` : `reset_url.sh` l'écrit dans chaque `.env` en `http://<IP WAN>:8080`, adresse morte
      depuis que 8080 n'est lié qu'à `127.0.0.1`. Aucune app ne la lit (vérifié le 2026-11-01) : retirer la clé
      des `.env`, des gabarits et de `reset_url.sh`.

### T9 — Le moteur n'a jamais joué le cloisonnement de la plupart des apps · P2 · S

- [ ] [C] `.lab-state/tests/` n'existe pas ; les `deployed/<app>.json` portent `cloisonnement: non-lancé` (atelier-3d, bilan-thermique, carto-lab, conciergerie, code-route, craft-lab, robot-lab, storage, oauth-hub…). Lancer « Tout tester » dans lab-admin.
- **Test.** Un verdict `ok` par app, dans `.lab-state/tests/`.

### T10 — Preuves réelles avec le propriétaire · Ⓟ

Ces points ont été écrits et testés sur des doubles, jamais en réel.

**Lab multi-dev**
- [ ] Redémarrage de l'hôte, puis contrôle que le moteur repose ses règles (`iptables -S | grep -c lws`).
- [ ] Webhook push mené à son terme.
- [ ] Ticket et commits contre le vrai GitHub.
- [ ] `me/init` d'un compte neuf.
- [ ] pgAdmin personnel connecté avec son mot de passe, et base SIG par le relais (port 5433).

**Espaces de travail**
- [ ] Une conversation Claude et une Vibe avec reprise.
- [ ] `lab-essai` avec un vrai jeton d'espace.
- [ ] `Ctrl+Maj+B` dans un vrai projet.

**Apps et services**
- [ ] Création réelle d'un projet avec graine App Builder, jusqu'au déploiement.
- [ ] peripheriques : direct H.264 en vrai navigateur, WebRTC depuis le WAN, révocation pendant une lecture.
- [ ] storage : glisser depuis le bureau, tactile, lecteur d'écran.
- [ ] Restauration de Keycloak (T5).

---

## 3. Services du cadriciel sans dépôt propre

Ce sont des dossiers du dépôt parent, sans sous-module, donc sans feuille de route à eux : leurs lots
sont ici.

### lab-mcp — moteur

État : en service ; les 34 routes correspondent à `API.md` ; pas de TODO dans le code [C].

- [ ] **M1 · P3** : doc vraie.
  - Le bandeau d'`API.md` (l. 12-17) dit encore « oauth-hub ne fait confiance ni à lab-mcp ni à lab-admin » et « moteur non déployé ». Les deux sont faux.
  - `README.md:285` : `LAB_PREVIEW_TTL_H` est bien transmise.
  - `README.md:338-344` : « reste à vérifier » partiellement fait.
- [ ] **M2 · P2** : suite cœur rejouable `tests/core/run.sh` (`harness.py` + `compare.py`, sur des doubles). Il n'existe pas de non-régression pour le déploiement, les droits et le SQL. Test : deux exécutions vertes de suite, rien laissé derrière.
- [ ] **M3 · Ⓟ** : preuves réelles (T10).
- [ ] P2 : `LAB_TICKET_REPO` vaut par défaut `Sacha37420/sso-lab` en dur (`labmcp/config.py:108`) : vérifier que ce dépôt existe, sinon le rendre obligatoire.

### workspace — espaces VS Code

État : README de 454 lignes, `verify.sh` à 293 contrôles ; l'image en service peut précéder le dernier commit [D].

- [x] **W1 · P1** (fait le 2026-11-01) : **Node 22**. L'image est en Node 20.20.2 (`Dockerfile:19`), en fin de vie, alors que Claude Code et `claude-agent-acp` demandent Node ≥ 22. Régénérer le verrou `chat/` avec `--before`. Test : `WS_IMAGE=… bash workspace/verify.sh` vert, aucun `EBADENGINE`.
- [ ] **W2 · Ⓟ** : parcours réel (T10).
- [ ] **W3 · Ⓟ** : décider si une demande d'autorisation sans réponse garde l'espace ouvert indéfiniment (`espace-chat/rapports/workspace.md:198-206`).
- [ ] P3 : dépendances transitives de Vibe non verrouillées. Le marqueur `isDefault` des tâches est hors API publique : à revérifier à chaque montée de code-server.

### runner — Playwright

État : `server.js` de 145 lignes, fonctionne ; pas de README.

- [ ] **R1 · P1 · ⚙** : enfermer le runner (§ 1, point 1). Test : un spec piège qui lit `/mnt/dev/sso-lab/.env` et joint Internet échoue, et `run-all` reste vert.
- [ ] **R2 · P2** :
  - `init: true` (zombies Chromium) ;
  - nom d'app validé (`lib/resolve-app.js:27`, `path.join` sans contrôle) ;
  - `testMatch: cloisonnement.spec.ts` (aujourd'hui tout `e2e/` est joué) ;
  - Playwright 1.48 à mettre à jour ;
  - commentaires corrigés ;
  - `runner/README.md`.
  Test : `POST /run {"app":"../x"}` → 400.

### lab-media — flux audio et vidéo

État : la brique la mieux prouvée (`verify.sh` à 149 contrôles, tests unitaires).

- [ ] **LM1 · P3** :
  - `API.md` §6 indique encore « non prouvé » pour H.264 en navigateur et pour la capture réelle, alors que c'est validé par le propriétaire ;
  - archiver `API.md` §5 et `lab-media/BASCULE.md` (procédures terminées) ;
  - dire dans le README que le service tourne à `MEDIA_CAPTURE_MAX=3` et `FPS=8`, contre 2 et 15 par défaut.
- [ ] **LM2 · P2** : `MEDIA_WEBRTC_HOSTS` en dur, non propagé par `reset_url.sh`. Le propager depuis `SERVER_URL_WAN`, ce qui touche un fichier d'architecte.
- [ ] P2 : la clé du hook apparaît dans le journal de MediaMTX quand le hook est injoignable (limite connue, à documenter dans `docs/exploitation.md`).

---

## 4. Feuilles de route des apps

Chaque app a désormais sa `FEUILLE_DE_ROUTE.md`, au format lu par `validate-app.sh`. Pour une app
historique, le Lot 1 résume l'existant ; les lots suivants viennent de cette analyse.

**Fichiers créés ou complétés le 2026-10-31, non commités** : à relire, puis à commiter dans chaque
sous-module. La commande de test est celle qu'`app-test.sh` emploie déjà : rien ne change pour les tests.

| App | Rôle | P1 ouverts | Feuille de route |
|---|---|---|---|
| analyse-lora | capteurs LoRa, formules | `eval` (U3), clé d'ingestion lisible par un accès webhook | [FEUILLE_DE_ROUTE.md](deploiement/analyse-lora/FEUILLE_DE_ROUTE.md) |
| arbre-genealogique | généalogie, GEDCOM, médias | `./backend:/app` monté, `?token=`, pas de limite de taille | [FEUILLE_DE_ROUTE.md](deploiement/arbre-genealogique/FEUILLE_DE_ROUTE.md) |
| atelier-3d | photogrammétrie et CAO | jobs orphelins, `?token=` | [FEUILLE_DE_ROUTE.md](deploiement/atelier-3d/FEUILLE_DE_ROUTE.md) · note d'analyse : [to_do_atelier_3d.md](deploiement/atelier-3d/to_do_atelier_3d.md) |
| bilan-thermique | simulation thermique | garde-fou de coût (L5), course au calcul | [FEUILLE_DE_ROUTE.md](deploiement/bilan-thermique/FEUILLE_DE_ROUTE.md) · journal des lots : [to_do_bilan_thermique.md](deploiement/bilan-thermique/to_do_bilan_thermique.md) |
| carto-lab | SIG partagé, OGC | tables orphelines `carto_public` (C5), image non épinglée | [FEUILLE_DE_ROUTE.md](deploiement/carto-lab/FEUILLE_DE_ROUTE.md) |
| code-route | code de la route | — | [FEUILLE_DE_ROUTE.md](deploiement/code-route/FEUILLE_DE_ROUTE.md) |
| conciergerie | gestion locative | URL iCal secrète rendue aux co-propriétaires, ré-association DNS | [FEUILLE_DE_ROUTE.md](deploiement/conciergerie/FEUILLE_DE_ROUTE.md) |
| craft-lab | jeu 2D multijoueur | relais avec tout le `.env`, `?token=` | [FEUILLE_DE_ROUTE.md](deploiement/craft-lab/FEUILLE_DE_ROUTE.md) · historique : [to_do_craft_lab.md](deploiement/craft-lab/to_do_craft_lab.md) |
| peripheriques | droits caméra et micro | — | [FEUILLE_DE_ROUTE.md](deploiement/peripheriques/FEUILLE_DE_ROUTE.md) |
| restauration | restaurant, commande publique | gestion des comptes du realm (U4), `./backend:/app` | [FEUILLE_DE_ROUTE.md](deploiement/restauration/FEUILLE_DE_ROUTE.md) |
| robot-lab | robots de navigation IA | pivot vers code-server (U1), engine avec tout le `.env` | [FEUILLE_DE_ROUTE.md](deploiement/robot-lab/FEUILLE_DE_ROUTE.md) |
| test-video | en fait le **didacticiel du cadriciel** | travail non commité (U5) | feuille de route réelle dans l'espace de travail `~/lab-work/sacha/test-video` (non modifiée ici) |
| traitement-de-fichiers-compils | atelier de fichiers dans le navigateur | — | [FEUILLE_DE_ROUTE.md](deploiement/traitement-de-fichiers-compils/FEUILLE_DE_ROUTE.md) |
| lab-admin | interface du lab | mot de passe renvoyé même quand l'email part, ports publiés | [FEUILLE_DE_ROUTE.md](lab-admin/FEUILLE_DE_ROUTE.md) |
| storage | fichiers du lab (9 consommateurs) | `?token=` sur toutes les routes, API sans tests hors contenu | [FEUILLE_DE_ROUTE.md](storage/FEUILLE_DE_ROUTE.md) · analyse et décisions : [to_do_storage.md](storage/to_do_storage.md) |
| oauth-hub | jetons OAuth des sites externes | — | [FEUILLE_DE_ROUTE.md](oauth-hub/FEUILLE_DE_ROUTE.md) |
| app-builder | spécifications → projets | clés IA en `localStorage` | [FEUILLE_DE_ROUTE.md](app-builder/FEUILLE_DE_ROUTE.md) |

Les anciens `to_do_*.md` de la racine sont **déplacés dans leur app**, sous le même nom. Leur contenu
n'a pas été modifié ; les points encore ouverts sont repris dans la feuille de route de l'app.

---

## 5. Décisions attendues du propriétaire (Ⓟ)

1. Réseau dédié pour code-server (U1). Touche `sso-lab`, à faire en sa présence.
2. Adresse fixe du NAS (U2), chiffrement des sauvegardes (T5), droits du compte `saver` sur le NAS.
3. Commit du didacticiel `test-video` (U5), et son nom : le garder, ou recréer le projet sous un nom explicite.
4. Chemin de la porte OGC de carto-lab (T1).
5. Suppression des images `rollback/*` (T8).
6. Par app, détaillées dans chaque feuille de route :
   - restauration : socle de caisse NF525 ;
   - conciergerie : confidentialité entre co-propriétaires, `Remboursement.montant` ;
   - atelier-3d : verrou des jobs, laissé tel quel jusqu'ici ;
   - code-route : sessions abandonnées dans le bilan ;
   - app-builder : coffre des clés IA ;
   - oauth-hub : GitHub App.
7. lab-admin : cartes pgAdmin et phpLDAPadmin en IP LAN (point B5), libellés « éditeur » ou « espace ».

---

## 6. Ordre conseillé

1. **Urgences U1 à U5** (une demi-journée à une journée, hors décisions).
2. **§ 1, bloquants avant ouverture** : R1 runner, `environment:` minimal de robot-lab-engine et craft-lab-relay, ports publiés.
3. **T9** : cloisonnement joué par le moteur sur toutes les apps. C'est rapide, et cela donne une ligne de base avant les chantiers.
4. **T1** : un seul chemin de déploiement. Les feuilles de route sont déjà écrites.
5. **T5** : restauration scriptée, puis chiffrement.
6. **T3 + T4** : gabarits, PKCE, jeton hors URL. Deux chantiers à contrat, l'un après l'autre (ils touchent les mêmes frontends).
7. **T2, T6, T7, T8** : point d'entrée `lab`, documentation, code-server portable, ménage. On peut les intercaler.
8. Lots métier de chaque app, selon l'usage.
