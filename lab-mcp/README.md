# lab-mcp — le moteur du lab multi-dev

Le **seul composant privilégié** du lab multi-dev (il monte `docker.sock`). Il donne à chaque
développeur de quoi créer, déployer, observer **ses** projets et ouvrir son éditeur — sans compte
Docker, sans compte sur l'hôte.

Service partagé à la racine du dépôt, comme `runner/` : ni une app, ni un sous-module.
Interface : `chantiers/multi-dev/CONTRAT.md` (I5, I3). **Formes exactes de l'API : [`API.md`](API.md)**,
qui fait foi.

```
                         ┌────────────── lab-mcp (moteur) ──────────────┐
 une IA ──── /mcp ─────► │ mcp_entry.py ─┐                              │──► scripts/ (I4), sous lab-lock.sh
 lab-admin ─ /mcp/api ─► │ web.py ───────┴─► engine.py  (UNE fonction)  │──► PostgreSQL (rôle dev_<uid>)
                         │                                              │──► oauth-hub → GitHub (jeton de l'appelant)
 navigateur ─ /ws/<uid>/ │ ◄── ws-auth ── lab-ws-gateway ──► ws-<uid>   │──► docker : espaces de travail
                         └──────────────────────────────────────────────┘
```

Deux entrées, aucune logique d'un seul côté : chaque outil MCP et chaque route web appellent la
même opération de `labmcp/engine.py`. `tests/compare.py` le vérifie (22 opérations, même objet
rendu par les deux entrées, succès comme erreurs).

---

## Pour un développeur

1. Se connecter une première fois à `https://<DOMAIN>/lab-admin/` : l'initialisation est
   automatique (inscription, base `dev_<uid>`, dossier de travail).
2. Relier son compte GitHub dans `https://<DOMAIN>/oauth-hub/` (obligatoire pour créer un projet,
   ouvrir un ticket, ouvrir l'éditeur).
3. Tout se fait ensuite depuis lab-admin, sans IA — ou par le MCP.

### Depuis l'éditeur du lab
Rien à régler : l'espace de travail reçoit `LAB_MCP_URL` et `LAB_MCP_TOKEN`, et l'image déclare le
serveur à Claude Code et à Mistral Vibe. Ce jeton est **limité au projet ouvert** (état, journaux,
variables, déploiement, tests).

### Depuis son propre poste (Claude Code ≥ 2.1.231)
```bash
claude mcp add --transport http --client-id lab-mcp --callback-port 8976 lab https://<DOMAIN>/mcp
```
puis `/mcp` → `lab` → *Authenticate* (ou `claude mcp login lab`). Client Keycloak **pré-enregistré**
et public (PKCE S256) ; l'URI de rappel `http://localhost:8976/callback` est enregistrée telle
quelle. Le lab n'offre pas d'enregistrement dynamique de client. Si la découverte du serveur
d'autorisation échoue (le realm a un chemin, `/auth/realms/ssolab`) :

```json
{"mcpServers": {"lab": {"type": "http", "url": "https://<DOMAIN>/mcp",
  "oauth": {"clientId": "lab-mcp", "callbackPort": 8976, "scopes": "openid profile email",
            "authServerMetadataUrl": "https://<DOMAIN>/auth/realms/ssolab/.well-known/openid-configuration"}}}}
```
> ⚠ Suit la documentation de Claude Code ; **jamais essayé contre ce serveur** (non déployé, pas de
> `claude` sur l'hôte). Le client MCP éprouvé est celui du SDK Python (`tests/client.py`).

### Outils MCP
`whoami` · `list_apps` · `check_name` · `create_app` · `deploy` · `job_status` · `status` · `logs` ·
`env_list` / `env_set` / `env_unset` · `sql` · `run_tests` · `open_ticket`.
`create_app`, `deploy`, `run_tests` rendent un `job_id` : rappeler `job_status` jusqu'à
`terminal: true`. Résultats et erreurs : ceux d'`API.md` (table de correspondance au §1).

---

## API web (`/mcp/api/…`) — pour lab-admin

Jeton Keycloak `azp = lab-admin` (celui du frontend), même origine que lab-admin. Toutes les routes
de la table d'I5, plus `GET /mcp/api/groups`. **Tout est décrit dans [`API.md`](API.md)** : formes,
format d'erreur unique, états d'un job, quatre profils de `GET /me`.

---

## Espaces de travail (I3)

`POST /mcp/api/projects/<app>/workspace` ouvre `ws-<uid>` : l'image `lab-workspace` (I7) sur **son**
réseau `ws-net-<uid>`, le clone de travail du projet en `/work/<app>`, la maison du dev en
`/home/coder`, et rien d'autre. Un par dev, `LAB_WS_MAX` (3) sur le lab, arrêt après
`LAB_WS_IDLE_MIN` (30) minutes sans activité : dernière requête du dev passée par la passerelle, ou
dernier battement de code-server (`GET /healthz` → `lastHeartbeat`, sondé par la passerelle), qui
continue tant qu'une fenêtre de l'éditeur reste connectée.

**Acheminement** — question ouverte du §8, tranchée par un essai réel :

- le Caddy du lab ne route que vers `sso-net` (`CADDY_INGRESS_NETWORKS`), où un espace ne doit jamais
  être. **Rien n'est changé de ce côté** : une passerelle de ce dossier, `lab-ws-gateway`
  (`gateway/Caddyfile`), est sur `sso-net` et le moteur la connecte au réseau de chaque espace à
  l'ouverture, l'en retire à la fermeture. Deux espaces n'ont aucun réseau commun ;
- pour **chaque** requête, WebSocket compris, la passerelle demande au moteur
  (`GET /mcp/api/ws-auth`) si cette personne peut entrer dans cet espace, puis retire `/ws/<uid>` et
  relaie vers `ws-<uid>:8080` ;
- lab-admin reçoit une URL à **ticket** (usage unique, 60 s) ; la première requête l'échange contre un
  cookie `lab_ws_<uid>` (`HttpOnly`, `Secure`, `SameSite=Lax`, `Path=/ws/<uid>/`, 12 h). Tickets,
  cookies et jetons d'espace ne sont gardés qu'en condensat, en mémoire ;
- l'espace joint l'URL publique du lab par l'hôte (`--add-host <DOMAIN>:host-gateway`), sans dépendre
  du NAT en épingle de la box.

**Enfermement** : `--cap-drop ALL`, `no-new-privileges`, mémoire/CPU/pids plafonnés, ni socket Docker
ni montage du dépôt. Variables injectées par l'environnement du client `docker`, jamais sur sa ligne
de commande : `LAB_MCP_URL`, `LAB_MCP_TOKEN`, `LAB_APP`, `LAB_UID`, `GH_TOKEN`, et — quand le jeton
GitHub du propriétaire est là — `LAB_GIT_AUTHOR_NAME` / `LAB_GIT_AUTHOR_EMAIL` (son compte GitHub,
adresse `noreply`).

Ce que la passerelle doit à l'image (I7), vérifié à travers deux sauts (Caddy simulé → passerelle →
éditeur réel) : préfixe `/ws/<uid>` retiré ; `/ws/<uid>` redirigé vers `/ws/<uid>/` ; hôte public
transmis inchangé (code-server refuse en 403 un WebSocket dont l'`Origin` n'est pas cet hôte) ;
`Upgrade` admis sur tout chemin sous le préfixe, sans délai ; contrôle d'accès sur chaque requête.
`keepalive off` vers l'éditeur : code-server tient un espace pour actif tant qu'il lui reste une
connexion, la passerelle n'en garde donc aucune entre deux requêtes.

À savoir :
- **`GH_TOKEN` est celui du propriétaire.** Quand le superutilisateur ouvre l'espace d'un autre,
  aucun jeton GitHub n'y est injecté.
- **Supprimer la maison d'un dev** (`<LAB_WORK_DIR>/<uid>`) : Vibe y pose des dossiers en lecture
  seule — `chmod -R u+rwX` d'abord, sinon `rm -rf` échoue. Le moteur ne supprime jamais ce dossier.
- **Un redémarrage du moteur ferme tous les espaces** (leurs jetons sont en mémoire). Rien n'est
  perdu : sources et maison sont sur disque.
- **Limite connue** : comme tout conteneur, un espace joint les ports **publiés sur l'hôte**
  (Keycloak `:8080`, LDAP `:389`, pgAdmin `:5050`, `sshd :22`…). C'est l'exposition qu'a déjà toute
  machine du réseau local ; la fermer demande un pare-feu sur l'hôte, hors de ce dossier.
  PostgreSQL, les Redis, `lab-runner` et tout ce qui n'est pas publié restent injoignables.

---

## Sécurité — ce qui tient, et où

| Garde | Où |
|---|---|
| Signature du jeton (clés du realm), expiration, émetteur, `typ == Bearer` | `labmcp/auth.py` |
| `azp` **exact par entrée** : `lab-mcp` pour `/mcp`, `lab-admin` pour `/mcp/api` ; `admin-cli` refusé partout | `labmcp/auth.py` |
| Entrée MCP : compte dans `.devs`, relu à chaque requête. Superutilisateur = `LAB_SUPERUSER`, jamais un groupe | `labmcp/auth.py`, `registry.py` |
| Propriété du projet pour toute opération qui en prend un ; « inconnu » et « à un autre » indistincts | `Engine._app` |
| Jeton d'espace : 256 bits, haché, limité à un projet et à neuf opérations, jamais superutilisateur | `workspaces.py`, `Engine.call` |
| Seuls les scripts d'I4 sont exécutés, en liste d'arguments ; enchaînements lancés **par** `lab-lock.sh` | `procs.py`, `chain.py` |
| `docker` lancé directement **uniquement** pour les espaces, avec des noms dérivés d'un uid validé | `workspaces.py` |
| Jeton GitHub = celui de l'appelant, redemandé à oauth-hub à chaque fois, jamais écrit ni journalisé ; pas de `gh` dans l'image | `oauthhub.py`, `github.py` |
| **Un déploiement ne reçoit aucun jeton** : clé de déploiement en lecture seule, déposée à la création | `chain.py` |
| Console SQL : connexion réseau avec le rôle `dev_<propriétaire>` et son mot de passe ; jamais `devuser` | `sqlconsole.py` |
| Webhook : HMAC-SHA256 par projet, comparaison à temps constant ; le SHA reçu n'est jamais déployé | `Engine.hook` |

**Aucun mode « identité forcée »** : émetteur, adresse des clés et les deux `azp` ne sont pas
configurables. Les tests remplacent la clé de vérification par programme, depuis `tests/harness.py`,
absent de l'image.

Décisions de ce secteur :
- Python, SDK MCP officiel 1.x, Streamable HTTP sans état ; client OAuth pré-enregistré.
- File de jobs en mémoire, un travailleur, un job par projet : un job ne survit pas à un redémarrage.
- `me/init` est synchrone ; `create_app`, `deploy`, `run_tests` sont des jobs.
- Le conteneur rejoint `dev-net` en plus de `sso-net` : PostgreSQL n'est joignable que par là.
- Groupes proposés à la création : lus dans `sso-lab/ldap/init.ldif`.
- Journal d'audit : une ligne JSON par opération sur la sortie du conteneur
  (`docker logs lab-mcp | grep '"audit"'`) — ni valeur de variable, ni requête SQL, ni jeton.

---

## Exploitation (superutilisateur)

```bash
mkdir -p /home/sacha/lab-work              # LAB_WORK_DIR : doit exister AVANT (sinon Docker le crée en root)
cp lab-mcp/.env.example lab-mcp/.env       # vérifier LAB_UID / LAB_GID / DOCKER_GID
bash scripts/reset_url.sh                  # remplit DOMAIN, HOST_DEV_ROOT, LAB_WORK_DIR
bash scripts/setup2.sh lab-mcp --yes       # client Keycloak + build + moteur + passerelle
```
Préalables : l'image `lab-workspace:latest` construite (`workspace/`), et `lab-mcp` **et**
`lab-admin` ajoutés aux « Apps autorisées » d'oauth-hub (portée `repo` sur la fiche GitHub).

| Clé du conteneur | Rôle (défaut) |
|---|---|
| `DOMAIN`, `LAB_ROOT`, `LAB_WORK_DIR` | posées par le compose ; chemins **identiques à l'hôte** |
| `LAB_WS_IMAGE` / `LAB_WS_MAX` / `LAB_WS_IDLE_MIN` | `lab-workspace:latest` / 3 / 30 |
| `LAB_WS_MEMORY` / `LAB_WS_CPUS` / `LAB_WS_PIDS` | `2g` / `1` / 512 |
| `LAB_WS_PUBLIC_VIA_HOST` | `1` : `<DOMAIN>` résolu vers l'hôte dans l'espace |
| `LAB_SQL_TIMEOUT_S` / `LAB_SQL_MAX_ROWS` | 10 / 500 |
| `LAB_MCP_QUICK_LOCK_TIMEOUT` / `LAB_MCP_JOB_LOCK_TIMEOUT` | 20 s / 900 s |
| `LAB_TICKET_REPO` | `Sacha37420/sso-lab` |
| `LAB_GIT_ALLOW_FILE=1` | origines git en `file://` — **tests uniquement**, absent du compose, signalé au démarrage |

État écrit par le moteur dans `<LAB_STATE_DIR>` : `deploy-keys/<app>` (+`.pub`, 600) et
`auto-deploy/<app>.json` (secret du webhook, 600).

---

## Tests

`tests/` n'est pas dans l'image. Tout se joue dans des conteneurs jetables (`lab-mcp-test`,
`ws-test-…`), builds sous `scripts/lab-lock.sh`.

- `tests/harness.py` — le moteur livré, avec une clé de vérification de test et des doubles
  d'oauth-hub/GitHub (`tests/doubles.py`) ;
- `tests/client.py` — clients des deux entrées (client MCP officiel du SDK ; HTTP) ;
- `tests/compare.py` — les deux entrées rendent-elles le même objet ?
- `tests/keycloak_login.js` — vrai jeton Keycloak (`lab-mcp` ou `lab-admin`) par le navigateur de `lab-runner` ;
- `tests/ws/` — essai réseau des espaces (substitut d'espace, sonde, client WebSocket).

### Ce qui reste à vérifier en réel
1. Un compte humain : première connexion (`me/init` qui inscrit réellement), parcours complet.
2. Tout ce qui parle au vrai GitHub par le vrai oauth-hub : création d'un projet jusqu'au bout
   (dépôt, clé de déploiement, webhook), déploiement par SSH avec la clé, commits, ticket.
3. Le moteur derrière le Caddy du lab : labels `/mcp`, `/mcp/*`, `/ws/*`.
4. Claude Code et Vibe appelant le MCP depuis un espace avec le jeton d'espace (éprouvé ici avec le
   client du SDK).
