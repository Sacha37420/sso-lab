# Copilot instructions — dev/ (lab SSO multi-applications)

Ce dépôt héberge l'infrastructure partagée (Keycloak, OpenLDAP, PostgreSQL/PostGIS, Caddy) d'un
lab auto-hébergé exposé sur Internet, plus onze applications Django + Angular en **sous-modules
git** (`Sacha37420/<app>`), chacune dans son propre dépôt.

**Documentation faisant autorité — la lire avant d'agir, pas seulement ce fichier :**
- `README.md` — procédures complètes (démarrage local/WAN/HTTPS, créer une app, gestion des
  fichiers, gestion des bases de données), tables de référence (ports, scripts, groupes LDAP).
- `CLAUDE.md` — détail fin par fichier/décision (pièges déjà rencontrés et corrigés, exemples de
  référence pour chaque pattern de migration ou de sécurité). Consulter systématiquement avant
  de toucher à la sécurité, aux migrations de fichiers/BDD, ou au réseau partagé entre cadriciels.
- `to_do_ui_foyer.md` — cahier des charges UI complet (« Foyer »), à lire avant toute tâche
  touchant la navigation ou les styles d'une app.

Ce fichier ne redit pas ces documents en détail : il liste les règles **non négociables**, celles
dont l'oubli casse silencieusement quelque chose de large (authentification de tout le lab,
routage de deux cadriciels, intégrité des sauvegardes BDD).

## Règles non négociables

**Déploiement**
- Toujours utiliser `bash scripts/setup2.sh <app> --yes` (ou `setup_unit.sh <app> --yes`) pour
  (re)déployer une app — jamais `docker compose up --build` ni `recompose_docker.sh` directement
  en dehors de ces scripts, sous peine de sauter les étapes Keycloak/schéma/ports.
- `setup2.sh --yes` sans nom d'app régénère `sso-lab/.env` via `init-secrets.sh` — ne **jamais**
  l'enchaîner après `rotate-secrets-full.sh` (désynchronise les secrets tout juste rotés à
  chaud). Voir README §2.3.

**Sécurité (deux verrous obligatoires, aucun ne suffit seul)**
- Toute nouvelle app **doit** avoir `--require-group` dans `<app>/.keycloak-client-opts`. Une
  liste vide accepte tout compte du realm — décision explicite à documenter, jamais un oubli.
- Le flow Keycloak `require-<client>` a une structure obligatoire précise (encapsuler
  l'authentification dans un sous-flow `REQUIRED`, la barrière en `CONDITIONAL` frère) — voir
  README §2.2/CLAUDE.md « Sécurité ». Une barrière mal placée soit casse tous les logins, soit
  est contournable par une session SSO déjà active (`Cookie` court-circuite `forms`).
- Tout backend Django doit vérifier **`azp`** (pas `aud`) **et** le claim `groups` dans
  `api/authentication.py`. `admin-cli` est un client public à password grant activé par défaut
  dans Keycloak — sans contrôle de `azp`, n'importe quel compte du realm appelle n'importe quelle
  API sans jamais croiser le flow.
- Tout **nouveau groupe LDAP** doit inclure `e2e_member` comme membre, sinon le test E2E de
  cloisonnement de toute app qui l'utilise échoue en silence (faux négatif).

**Fichiers utilisateur**
- Aucune app ne doit créer son propre volume média ni stocker de blob de fichier utilisateur en
  base. Toute nouvelle app appelle l'API de `storage` (voir README §3 / CLAUDE.md). Seul du
  contenu **transitoire** (scratch de calcul, téléchargements temporaires) peut vivre dans un
  volume Docker privé non-`external`.

**Bases de données**
- Deux instances Postgres séparées (`postgres`/`devdb` pour la majorité des apps,
  `postgis`/`gisdb` uniquement pour les apps SIG) — jamais de port 5432 publié sur l'hôte. Un
  schéma par app dans `infra/init/00_schemas.sql` (ou `init-postgis/...`). Une app sur
  `postgres` déclare `DB_PASSWORD` ; une app sur `postgis` déclare `POSTGIS_PASSWORD` — jamais
  les deux, c'est ce nom de clé qui pilote la propagation par `reset_url.sh`.
- Après un `DROP COLUMN` sur une colonne de blobs (migration vers `storage`), lancer
  `VACUUM FULL <schéma>.<table>` — sinon la table et les sauvegardes gardent le poids des
  données TOAST malgré la suppression logique.

**UI — identité « Foyer »**
- Toute app existante suit déjà les tokens CSS (`--accent`, `--bg`, `--text`…) définis en tête
  de `src/styles.scss`, jamais de couleur en dur dans un composant. Navigation toujours
  verticale (sidebar rétractable ≥ 900px, recouvrement plein écran < 900px, rupture fixe à
  900px pour toutes les apps). Une nouvelle app scaffoldée via `new-app.sh` hérite de Foyer
  automatiquement depuis `_templates/` — aucune reprise à prévoir tant qu'on ne modifie pas une
  app existante ou le système Foyer lui-même.

**Infrastructure partagée entre cadriciels**
- Cet hôte fait tourner deux cadriciels indépendants, `dev/` et `~/dev2/`, qui partagent les
  ports 80/443 via `~/edge-router/` — un dossier **hors de tout dépôt git**, non versionné.
  Le service `caddy` de `sso-lab/docker-compose.yml` ne publie donc plus `ports:` lui-même
  (normal, pas une régression). Ne jamais modifier le réseau `edge-net` ou les `ports:` de
  `caddy`/`caddy2` sans l'utilisateur présent : ça affecte les deux cadriciels à la fois.

**Secrets**
- Tous les `.env` sont ignorés par git — ne jamais en committer un, ni logguer sa valeur.
  `BBOX_ADMIN_PASSWORD` et `SMTP_PASSWORD` ne sont volontairement pas automatisés (voir README
  §2.3) : ne pas les inclure dans un script de rotation générique.

## Repères rapides

| Sujet | Où regarder |
|---|---|
| Créer une app | README §2.1, `scripts/new-app.sh` |
| Ports/groupes de chaque app | README §2.5 |
| Rotation des secrets | README §2.3, `scripts/rotate-*.sh` |
| Storage / fichiers | README §3, `storage/backend/api/authentication.py` |
| Bases de données | README §4, `infra/docker-compose.yml` |
| Démarrage local/WAN/HTTPS/répartiteur | README §1 |

Quand une instruction de ce fichier semble entrer en conflit avec le code observé, faire
confiance au code et au comportement actuel des scripts plutôt qu'à ce résumé — puis signaler
l'écart plutôt que de le corriger silencieusement.
