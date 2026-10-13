# workspace/ — image d'espace de travail par projet (`lab-workspace`)

Service racine du dépôt, comme `runner/` : pas une app, pas un sous-module. C'est l'image du
conteneur `ws-<uid>` que le moteur du lab (`lab-mcp`) lance pour un dev, ouvert sur **un** projet
(contrat « multi-dev », interfaces I3 et I7). Ce dossier ne livre **que l'image** : le cycle de vie
des conteneurs, leurs réseaux, l'acheminement par Caddy et le contrôle d'accès sont au moteur.

L'espace porte deux services, lancés côte à côte par l'entrée et indépendants l'un de l'autre :
l'**éditeur** (code-server, `:8080`) et le **service de conversation** (`chat/`, `:8090`) — une page
pensée pour le téléphone où l'on ne voit que la conversation avec Claude Code ou Mistral Vibe
(chantier « espace-chat »). Voir « Le service de conversation » plus bas.

## Ce que contient l'image

| Composant | Version épinglée | Où |
|---|---|---|
| Base | `python:3.12.15-slim-bookworm` (Debian 12) | — |
| code-server | 4.141.0 (`.deb`, sha256 vérifié) | `/usr/lib/code-server` |
| GitHub CLI `gh` | 2.102.0 (`.deb`, sha256 vérifié) | `/usr/bin/gh` |
| Node | 20.20.2 (copié de `node:20.20.2-bookworm-slim`) | `/usr/local/bin/node` |
| Claude Code | `@anthropic-ai/claude-code@2.1.296` (npm global) | `/usr/local/bin/claude` |
| Mistral Vibe | `mistral-vibe==2.26.1` (`uv tool`) | `/opt/uv-tools`, commande `/usr/local/bin/vibe` |
| uv | 0.13.0 (copié de `ghcr.io/astral-sh/uv:0.13.0`) | `/usr/local/bin/uv` |
| Extension Python | `ms-python.python@2026.4.0` (Open VSX) | `/opt/lab/extensions` |
| Service de conversation | `chat/server.js` + page statique | `/opt/lab/chat` |
| … son WebSocket | `ws@8.21.3` (npm, verrou `chat/package-lock.json`) | `/opt/lab/chat/node_modules` |
| … agent ACP de Claude | `@agentclientprotocol/claude-agent-acp@0.81.2` (npm, même verrou), **sans** ses dépendances optionnelles | `/opt/lab/chat/node_modules` |
| … agent ACP de Vibe | `vibe-acp`, fourni par `mistral-vibe` | `/usr/local/bin/vibe-acp` |
| Commande `lab-essai` | `bin/lab-essai` (Python de l'image, bibliothèque standard seule) | `/usr/local/bin/lab-essai` |
| Tâches VS Code de l'essai | `vscode/lab-essai/` (extension `lab.lab-essai`, sans dépendance) | `/usr/lib/code-server/lib/vscode/extensions/lab-essai` |
| git, openssh-client, curl, jq, tini, nano, less | paquets Debian 12 | — |

Utilisateur `coder`, uid/gid 1000, seul groupe `coder`. **Ni `sudo`, ni Docker, ni compilateur.**
Toutes les versions sont des `ARG` en tête du `Dockerfile`, nulle part ailleurs — sauf les deux
dépendances npm du service de conversation, dont la source est `chat/package.json` et son verrou
(sommes d'intégrité de chaque paquet, dépendances transitives comprises) : les `ARG` du
`Dockerfile` les répètent et le build échoue s'ils divergent. L'image annonce le tout dans la
variable `LAB_WORKSPACE_VERSIONS`.

Tout ce que l'image apporte vit **hors de `/home/coder`** : la maison du dev est montée par-dessus
et masquerait le reste. La maison de l'image est vide, et un garde-fou de build le vérifie.

## Construire

Le contexte est ce dossier seul (`.dockerignore` en liste blanche) : rien du dépôt n'entre dans
l'image, aucun secret, aucun identifiant. Un build passe par le verrou du lab (2 vCPU) :

```bash
bash scripts/lab-lock.sh docker build -t lab-workspace:dev workspace
```

Premier build : environ 8 minutes sur cet hôte (dont 4 d'export des couches). Image : ~600 Mo
compressée, 2,5 Go sur disque.

## Lancer (ce que le moteur fait — exemple minimal)

```bash
docker run -d --name ws-alice \
  --cap-drop ALL --security-opt no-new-privileges \
  --memory 2g --cpus 1 --pids-limit 512 \
  --network <réseau de l'espace> \
  -v <LAB_WORK_DIR>/alice/mon-app:/work/mon-app \
  -v <LAB_WORK_DIR>/alice/.home:/home/coder \
  -e LAB_UID=alice -e LAB_APP=mon-app \
  -e LAB_MCP_URL=https://<DOMAIN>/mcp -e LAB_MCP_TOKEN=… -e GH_TOKEN=… \
  -e LAB_GIT_AUTHOR_NAME="Alice" -e LAB_GIT_AUTHOR_EMAIL=alice@exemple.org \
  lab-workspace:dev
```

- Aucun port à publier : l'éditeur écoute sur **8080** dans le conteneur, le service de
  conversation sur **8090**.
- Le conteneur ne s'arrête que sur `SIGTERM` : si l'un des deux services tombe, l'entrée le
  relance (délai de 2 s, doublé jusqu'à 60 s s'il retombe aussitôt) et l'autre continue.
- Les deux dossiers montés doivent appartenir à l'**uid 1000** (sinon l'entrée s'arrête, code 64).
- `--read-only --tmpfs /tmp` fonctionne aussi (vérifié) : le moteur peut l'ajouter.
- Pas besoin de `--init` : `tini` est le PID 1 de l'image.
- Avec des arguments, l'entrée exécute la commande telle quelle **sans rien préparer**
  (`docker run --rm lab-workspace:dev claude --version`).

### Variables d'environnement

| Variable | | Effet |
|---|---|---|
| `LAB_UID` | **obligatoire** | `^[a-z][a-z0-9]{1,30}$`. Sert au préfixe `/ws/<uid>/`. |
| `LAB_APP` | **obligatoire** | nom du projet (règle 1 d'I1). `/work/<app>` doit être monté : c'est le dossier ouvert. |
| `LAB_MCP_URL` | attendue | adresse du MCP du lab. `https://` obligatoire (`http://` admis seulement en boucle locale). Absente : avertissement, aucune déclaration, l'éditeur démarre. |
| `LAB_MCP_TOKEN` | attendue | jeton d'espace (I5). **Jamais lu ni écrit par l'entrée** — voir plus bas. |
| `GH_TOKEN` | attendue | jeton GitHub du dev. Lu par `gh` et par `git` au moment de l'appel, jamais écrit. |
| `LAB_GIT_AUTHOR_NAME`, `LAB_GIT_AUTHOR_EMAIL` | facultatives | auteur des commits (mêmes noms qu'en I4). Exportées en `GIT_AUTHOR_*` / `GIT_COMMITTER_*` vers l'éditeur et son terminal — rien sur disque. Ignorées si le dev a mis `user.name` / `user.email` dans son `~/.gitconfig`. Sans elles ni réglage du dev, `git commit` demande une identité. |

Une variable obligatoire absente ou invalide, un projet non monté, une `LAB_MCP_URL` mal formée :
l'entrée écrit une ligne `ERROR` et sort en **code 64**, sans rien écrire dans la maison.

## Ce que l'entrée écrit, et où

À **chaque** démarrage, `entrypoint.sh` (dans l'image : `/usr/local/bin/lab-entrypoint`) :

| Fichier de la maison | Ce qui est écrit | Comment |
|---|---|---|
| `~/.claude/CLAUDE.md` | les règles du lab, dans un **bloc balisé** (`LAB:REGLES:DEBUT` … `FIN`) | `lib/bloc_regles.py` — le texte du dev hors du bloc est conservé |
| `~/.vibe/AGENTS.md` | idem, même contenu | idem |
| `~/.claude.json` | la clé `mcpServers.lab` seule | par `claude mcp add --scope user` : c'est Claude Code qui fusionne dans son fichier |
| `~/.vibe/config.toml` | l'entrée `[[mcp_servers]]` nommée `lab` seule | par `vibe mcp add` : c'est Vibe qui fusionne |
| `~/.local/share/code-server/extensions` | les extensions de l'image | **au premier démarrage seulement** (dossier absent) |

Tout est idempotent : si la déclaration ou le bloc est déjà celui voulu, rien n'est réécrit (le
journal dit « inchangé »). Changer `LAB_MCP_URL` met la déclaration à jour sans doublon.

**Source unique des règles : `regles-lab.md`** (contrat I8 : français, court, impératif). Le bloc
est remplacé à chaque ouverture ; le modifier dans la maison ne sert à rien, il faut modifier ce
fichier et reconstruire l'image.

**Ce que l'entrée ne touche jamais** : `~/.claude/.credentials.json`, le reste de `~/.claude.json`
(compte, autres serveurs MCP), `~/.vibe/.env`, le reste de `~/.vibe/config.toml`, `~/.gitconfig`,
`~/.config/gh`, `~/.ssh`, les réglages de l'éditeur (`~/.local/share/code-server/User`).
`verify.sh` dépose des identifiants factices dans chacun et compare leurs sommes avant/après.

> Effet de bord connu : quand Vibe réécrit son `config.toml` (ajout ou changement de la
> déclaration, pas à chaque démarrage), il le resérialise — les **commentaires** du dev y sont
> perdus, ses réglages conservés.

### Le jeton n'est écrit dans aucun fichier

Les deux outils savent référencer une variable d'environnement — vérifié sur les versions
épinglées, par un appel réel à un serveur qui exige le jeton (`verify.sh`, section 3d) :

```jsonc
// ~/.claude.json — Claude Code développe ${VAR} à la lecture
"mcpServers": { "lab": { "type": "http", "url": "https://<DOMAIN>/mcp",
                         "headers": { "Authorization": "Bearer ${LAB_MCP_TOKEN}" } } }
```

```toml
# ~/.vibe/config.toml — Vibe lit la variable nommée par api_key_env
[[mcp_servers]]
name = "lab"
transport = "streamable-http"
url = "https://<DOMAIN>/mcp"

[mcp_servers.auth]
type = "static"
api_key_env = "LAB_MCP_TOKEN"      # en-tête « Authorization: Bearer <valeur> » (défauts de Vibe)
```

L'entrée ne manipule que le **nom** `LAB_MCP_TOKEN`. Le jeton reste dans l'environnement du
conteneur, donc lisible par le dev dans son terminal (`echo $LAB_MCP_TOKEN`) — c'est le sien, limité
à son projet, détruit à la fermeture.

### git et gh

`/etc/gitconfig` (dans l'image, pas dans la maison) confie les identifiants de `github.com` à
`gh auth git-credential`, qui rend `GH_TOKEN` s'il est dans l'environnement : `git push` et `gh`
fonctionnent sans réglage, rien n'est stocké. Sans `GH_TOKEN`, repli sur la connexion `gh` du dev
s'il en a fait une (`gh auth login`, conservée dans sa maison). `GH_TOKEN` n'est jamais envoyé à un
autre hôte que GitHub.

## L'essai du développeur : `lab-essai` et ses tâches VS Code

Chaque développeur a une adresse d'essai (`https://<DOMAIN>/dev-<uid>/`, contrat « essai-dev ») qui
sert son dossier de travail tel qu'il est, non commité compris, sans tests, dans un schéma à part.
Le moteur la construit ; l'espace n'apporte que **de quoi le demander** :

```
lab-essai            # construit l'essai de $LAB_APP, suit le job, affiche l'adresse
lab-essai status     # ce que montre l'adresse, et jusqu'à quand
lab-essai stop       # arrête l'essai (sa base est conservée)
```

- **Transport** : l'entrée MCP du moteur (`$LAB_MCP_URL`, jeton `$LAB_MCP_TOKEN`), un `POST`
  JSON-RPC `tools/call` par appel, sans session ni `initialize` — c'est ce que sert le moteur
  (`FastMCP`, `stateless_http=True, json_response=True`, vérifié sur le SDK `mcp==1.30.0` de son
  image). Outils : `preview_deploy`, `preview_status`, `preview_stop`, `job_status`.
- **Codes de sortie** : `0` réussi · `1` échec (la raison, et les `reasons` du job ou de l'erreur,
  sont affichées) · `2` usage, ou variable de l'espace absente ou invalide (rien n'est appelé).
  Une interruption rend `1` : l'issue du build n'est pas connue.
- **Sortie** : le journal du job au fil de l'eau sur la sortie standard, chaque ligne une seule
  fois (compte `log_lines_total` du moteur ; si le journal a avancé de plus de 1000 lignes entre
  deux interrogations, l'écart est dit) ; à la fin, l'adresse **seule sur la dernière ligne**
  (celle de l'interface, à défaut celle de l'API). Les messages d'échec vont sur la sortie d'erreur.
- **`409 job_exists`** : la commande suit le job en cours au lieu d'échouer. Si c'est un build
  d'essai, son résultat est le sien (et elle prévient qu'il a commencé avant elle) ; si c'est un
  autre job du projet (déploiement, tests), elle l'attend puis lance l'essai.
- **Ctrl-C** (ou l'arrêt de la tâche dans l'éditeur) n'arrête que le suivi : le build continue
  côté lab, la commande le dit et nomme le job ; la relancer reprend le suivi.
- **Le jeton** n'est ni affiché (il serait masqué même si le moteur le renvoyait dans un journal),
  ni écrit, ni passé à un processus : la commande n'en lance aucun. Elle ne joint que
  `LAB_MCP_URL` — variables `*_proxy` ignorées, aucune redirection suivie, `https://` exigé hors
  boucle locale. Les caractères de commande du journal (séquences de terminal) sont retirés.
- Moteur injoignable, jeton refusé, moteur sans les outils d'essai, réponse qui n'est pas du
  moteur : une phrase en français, jamais une trace Python.
- `LAB_ESSAI_POLL_S` règle le rythme d'interrogation (défaut 2 s) — **essais seulement**.

**Tâches VS Code.** Trois tâches sont proposées dans tout espace : « Lab : construire l'essai »
(tâche de build par défaut : `Ctrl+Maj+B`), « Lab : état de l'essai », « Lab : arrêter l'essai »
(*Terminal → Run Task… → lab-essai*). Elles lancent `lab-essai` directement, sans shell.

Elles viennent d'une **extension intégrée à code-server** (`vscode/lab-essai/`), et non d'un
`.vscode/tasks.json` ni des réglages de l'éditeur, parce que :
- le dépôt du projet (`/work/<app>`) ne doit rien recevoir du lab ;
- la maison du dev est montée par-dessus l'image, ses réglages d'éditeur lui appartiennent
  (l'entrée ne les touche jamais), et ses extensions n'y sont recopiées qu'**une fois** : une
  extension de la maison n'arriverait jamais dans un espace déjà ouvert une fois, et ne suivrait
  pas l'image.
Le dossier des extensions intégrées est dans l'image, hors de la maison : l'extension est là dans
tout espace et change avec l'image. Un projet qui définit sa propre tâche de build par défaut dans
son `.vscode/tasks.json` garde la sienne (l'éditeur la préfère) ; les tâches du lab restent dans la liste.

## Ce que le proxy doit faire (préfixe `/ws/<uid>/`)

**code-server n'a aucune option de préfixe.** Il sert à la racine et toutes ses URL sont
**relatives** (`./_static/…`, `stable-<commit>/static/…`, redirection `Location: ./?folder=…`).
Vérifié en réel, curl et Chromium (`verify.sh`, sections 4 et 7) :

1. **Retirer le préfixe** avant de transmettre : la requête publique `/ws/<uid>/x` doit arriver à
   `ws-<uid>:8080` sous la forme `/x`. Sans retrait, tout répond **404**.
2. **Rediriger `/ws/<uid>` vers `/ws/<uid>/`** (avec la barre finale). Sans elle, le navigateur
   résout les chemins relatifs contre `/ws/` et demande des ressources chez un autre espace.
3. **Transmettre l'hôte public** : `Host` inchangé, ou `X-Forwarded-Host`. code-server refuse
   (**403**) tout WebSocket dont l'`Origin` ne correspond pas à l'hôte reçu — c'est sa protection
   contre le détournement de WebSocket depuis un autre site, à ne pas contourner avec
   `--trusted-origins`. Un proxy qui réécrit `Host` casse les WebSockets, pas les pages : l'éditeur
   s'affiche puis reste sur « reconnexion ».
4. **Laisser passer les WebSockets** (`Upgrade`), sur n'importe quel chemin sous le préfixe
   (`/ws/<uid>/stable-<commit>?reconnectionToken=…`), sans délai d'inactivité court : la connexion
   reste ouverte des heures.
5. **Appliquer le contrôle d'accès à chaque requête, WebSocket compris** : l'éditeur est en
   `auth: none`, il n'a **aucune** protection propre.

Avec Caddy (c'est la forme utilisée par `verify.sh`) :

```caddyfile
redir /ws/alice /ws/alice/ 308
handle_path /ws/alice/* {
	# forward_auth … (contrôle d'accès du moteur, I5 : /mcp/api/ws-auth)
	reverse_proxy ws-alice:8080      # Host et X-Forwarded-Host transmis par défaut
}
```

`code-server` reçoit aussi `--abs-proxy-base-path /ws/<uid>` : cela ne concerne que sa redirection
de ports (`/ws/<uid>/proxy/<port>/` et `/absproxy/<port>/`), par laquelle le dev voit dans son
navigateur un serveur qu'il lance dans son terminal. Elle passe par le même contrôle d'accès,
puisqu'elle est sous le même préfixe.

Pour la détection d'inactivité, `GET /healthz` (sans préfixe, côté conteneur) rend
`{"status":"alive"|"expired","lastHeartbeat":<ms>}` ; code-server a aussi `--idle-timeout-seconds`.
Ni l'un ni l'autre n'est utilisé ou éprouvé ici : le cycle de vie est au moteur.

## Le service de conversation (`chat/`, port 8090)

Un petit serveur Node (`chat/server.js`, une seule dépendance : `ws`) qui sert une page statique
(`chat/public/` : HTML, CSS, JavaScript simple, aucune ressource externe) et fait le pont entre
cette page (WebSocket) et un **agent ACP v1 sur stdio** :

| `?agent=` | Agent lancé | Reçoit le MCP `lab` par… |
|---|---|---|
| `claude` | `claude-agent-acp`, qui pilote le `claude` de l'image (`CLAUDE_CODE_EXECUTABLE`) | `~/.claude.json` (l'agent charge les réglages « user ») |
| `vibe` | `vibe-acp` | `~/.vibe/config.toml` |

Les deux agents travaillent dans `/work/<app>`, avec l'environnement de l'espace (donc
`LAB_MCP_TOKEN`) et les déclarations posées par l'entrée : **rien n'est passé dans `mcpServers` de
`session/new`**, le service ne lit jamais le jeton. Vérifié par un appel réel au faux serveur MCP
(`verify.sh`, section 3f).

### Routes (vues par le service ; la passerelle retire `/ws/<uid>/_chat`)

| Route | Réponse |
|---|---|
| `GET /healthz` | `200 {"ok": true}` |
| `GET /activity` | `200 {"last_activity_ms": <époque en ms>}` — voir ci-dessous ; `0` tant qu'il ne s'est rien passé |
| `GET /` | la page ; `?agent=claude\|vibe`, sinon le dernier utilisé, sinon `claude` |
| `GET /app.js`, `/style.css` | ses deux fichiers |
| WebSocket `/ws` | le fil de la conversation. **403** si l'`Origin` ne désigne pas l'hôte public (`X-Forwarded-Host`, à défaut `Host`), ou s'il est absent |

Toutes les URL émises sont relatives (`style.css`, `app.js`, `ws`, `../` pour l'éditeur).
**Aucune authentification propre** : comme l'éditeur, le service compte sur le contrôle d'accès de
la passerelle, à chaque requête, WebSocket compris.

`/activity` rend le dernier instant où **un client était connecté et où quelque chose s'est
passé** : un geste de l'utilisateur (message, réponse à une demande, arrêt, nouvelle conversation,
reprise, réglage) ou un élément de conversation émis par l'assistant. Un tour en cours avec un
client connecté vaut activité continue. Ne comptent **pas** : une page ouverte qui n'échange
rien, sa (re)connexion automatique, les `ping` WebSocket, un tour qui continue alors que plus
personne n'est connecté. Conséquence à connaître : une demande d'autorisation laissée sans
réponse, page ouverte, est un tour en cours — elle garde l'espace ouvert.

### Ce que garantit le service

- **Autorisations conservées.** À chaque ouverture ou reprise de conversation, le mode de l'agent
  est ramené à « demander avant d'agir » (`default` pour Claude, `ask` pour Vibe — qui démarre de
  lui-même en `accept-edits`), quel que soit le réglage du dev ; si ce mode est introuvable, la
  conversation n'est pas ouverte. Toute demande (`session/request_permission`) est présentée et
  attend. « Tout accepter » est un réglage du service, par conversation, inactif par défaut,
  jamais repris d'une conversation à l'autre ; il répond « autoriser une fois » à la place de
  l'utilisateur et le marque dans le fil. Si l'utilisateur choisit une option de l'assistant qui
  change son mode (« toujours autoriser les modifications »), la page l'affiche et propose de
  revenir au mode strict.
- **Un tour survit à la coupure du téléphone.** L'état de la conversation est gardé en mémoire par
  le service et rejoué en entier à la reconnexion ; une demande d'autorisation en attente le reste.
- **Rien de secret ni de privé dans le journal.** Le service ne lit, n'affiche ni ne journalise
  aucun identifiant ; il ne connaît l'état de connexion d'un assistant que par ce que l'agent
  répond (`_auth/status_update` de Claude, erreur `-32000`). La sortie d'erreur des agents est
  jetée (elle peut porter du contenu). Le journal ne contient que des lignes de cycle de vie
  (`[lab-chat] agent claude lancé (pid …)`).
- **Mémoire.** Un agent n'est lancé qu'à la première ouverture ; une seule conversation au repos
  par agent ; un agent sans page ouverte ni tour en cours est arrêté après 5 min
  (`LAB_CHAT_AGENT_IDLE_S`). La conversation se reprend ensuite par `session/load`.

Sans identifiants, la page le dit et explique quoi lancer dans le terminal de l'éditeur
(`claude` puis `/login` ; `vibe --setup`), avec un lien vers l'éditeur et un bouton « Réessayer »
qui relance l'agent. Elle ne demande jamais d'identifiant.

### Protocole page ⇄ service (WebSocket, JSON)

Page → service : `open {agent, sessionId?}` (attachement, automatique à la connexion),
`new`, `load {sessionId}`, `list`, `prompt {text}`, `cancel`, `permission {permId, optionId}`,
`auto {value}`, `mode_strict`, `trust {decision}` (Vibe), `retry`.
Service → page : `hello`, `agent` (état de l'agent et de sa connexion), `session` (instantané
complet : état + éléments), `item` / `append` / `patch` (éléments du fil : `user`, `text`,
`thought`, `tool`, `plan`, `perm`, `end`, `error`), `state`, `sessions`, `error`.

### Variables

| Variable | Effet |
|---|---|
| `LAB_CHAT_AGENT_IDLE_S` | délai d'arrêt d'un agent inoccupé (défaut 300) |
| `LAB_CHAT_PORT` | port d'écoute (défaut 8090 ; le contrat fixe 8090, ne sert qu'aux essais) |
| `LAB_CHAT_CMD_CLAUDE`, `LAB_CHAT_CMD_VIBE` | commande de l'agent, en tableau JSON — **essais seulement** (faux agent de `tests/`). Posées par qui lance le conteneur, donc hors de portée d'une page |

## Vérifier

```bash
bash workspace/verify.sh                    # ~13 min, navigateur réel compris (293 contrôles)
bash workspace/verify.sh --sans-navigateur  # sans Chromium : curl et protocole seulement
bash workspace/verify.sh --conversation     # ~5 min, section 10 seule (service de conversation)
```

Conteneurs jetables `ws-test-image-*`, réseaux jetables `ws-test-image-net*` (jamais `dev-net` ni
`sso-net` ; préfixe réglable par `WS_VERIFY_PREFIX`), options d'enfermement d'I3, jetons factices,
faux serveur MCP, faux agent ACP : aucun identifiant réel. Tout est supprimé à la sortie. Le
navigateur est celui de l'image du runner du lab (`runner-runner:latest`, lancée comme conteneur
jetable sur le réseau jetable — le service `lab-runner` n'est pas touché, il ne joint d'ailleurs que
`sso-net`) ; c'est une charge Playwright : la section 10c attend que le runner du lab soit libre.
`WS_VERIFY_CAPTURES=<dossier>` garde les captures d'écran de la conversation (390 px et 1280 px).

Pour l'essai du développeur, les essais (`tests/`) sont :

| Fichier | Rôle |
|---|---|
| `faux_mcp.py` | faux moteur : même transport que le vrai (relevé sur son SDK), jeton exigé, outils d'essai et `job_status` selon un **scénario** (succès, refus avec `reasons`, `job_exists`, job perdu, journal énorme, journal portant le jeton, redirection, passerelle en 502…). Sert aussi, depuis l'origine, à prouver que Claude Code et Vibe envoient le jeton |
| `lab_essai_essais.py` | joue `lab-essai` dans chaque situation (section 3g de `verify.sh`), avec un « piège » : un port qui ne doit jamais recevoir de connexion (proxy d'environnement, cible de redirection). Se lance aussi seul : `LAB_ESSAI_CMD=… python3 workspace/tests/lab_essai_essais.py` |
| `navigateur.js` | en plus de l'éditeur : relève les tâches que l'éditeur propose, lance « état » puis « Run Build Task » (section 7) |

Pour le service de conversation, les essais (`tests/`) sont :

| Fichier | Rôle |
|---|---|
| `faux_agent_acp.js` | faux agent ACP v1 sur stdio : flux, outil, modification avec diff, demandes d'autorisation, plan, tour long, conversations gardées sur disque, modes (il **démarre en mode permissif**, comme Vibe), assistant « sans identifiants » sur commande |
| `chat_client.js` | client du protocole de la page, lancé dans l'espace : ouverture avec les vrais agents, scénario complet avec le faux agent, relevés de `/activity` |
| `chat_navigateur.js` | le même scénario joué à l'écran (Chromium), à travers un proxy qui retire `/ws/<uid>/_chat` ; coupures réseau provoquées en redémarrant le proxy ; contrôle du défilement horizontal, des cibles tactiles, des requêtes hors préfixe et de la politique de contenu |

Ce que le script **ne peut pas** prouver : une conversation réelle avec Claude ou Mistral (il
faudrait un identifiant ; aucun n'est emprunté à l'hôte). La preuve s'arrête à : binaires présents
et utilisables depuis le terminal intégré, déclarations lues par chaque outil, jeton de
l'environnement reçu par le serveur MCP (`claude mcp get lab` → *Connected* ; client MCP de Vibe →
liste des outils). Pour la conversation : `initialize` et ouverture de session des deux **vrais**
agents à travers le service (mode strict imposé, MCP `lab` joint, « non connecté » transmis à la
page), et tout le reste avec le faux agent. Restent donc à voir avec de vrais identifiants : la
forme exacte des appels d'outils et des demandes d'autorisation de chaque assistant à l'écran,
la reprise d'une vraie conversation (`session/load`), et l'arrêt d'un vrai tour.

## Mesures (2026-10-12, hôte 2 vCPU, limites 2 Go / 1 vCPU / 512 pids)

| | Mémoire du conteneur | Processus/fils |
|---|---|---|
| Au repos, personne de connecté (éditeur + service de conversation) | ~195 Mo (115 anonymes) | 38 |
| Éditeur ouvert, fichier Python, extension Python active, un terminal | ~700 Mo (590 anonymes) | 101 |
| + Claude Code et Vibe lancés dans le terminal (premier écran, sans conversation) | ~930 Mo (820 anonymes) | 119 |
| Pic observé | 950 Mo | 127 |
| **Conversation seule** (éditeur jamais ouvert) : les deux agents ACP lancés, une conversation chacun | ~470 Mo | — |

Détail de la conversation (RSS) : service 48 Mo ; agent ACP de Claude 91 Mo + le `claude` qu'il
pilote 232 Mo ; `vibe-acp` 178 Mo. Un seul assistant à la fois est le cas courant : ~370 Mo
(Claude) ou ~310 Mo (Vibe) au-dessus du repos. Ouvrir une conversation depuis la page : ~3 s pour
Claude, ~10 s pour Vibe (son démarrage Python), à froid sur 1 vCPU.

Le service de conversation ajoute à l'image 58 Mo sur disque (7,5 Mo compressés), dont 55 Mo de
`node_modules` — contre 284 Mo si l'agent ACP de Claude embarquait son propre binaire.

Premier démarrage 6,2 s (le service de conversation répond 0,1 s après l'éditeur) ; redémarrage
1,6 à 2,7 s selon les passes. Les défauts du contrat (2 Go, 3 espaces) tiennent
pour éditer et faire travailler une IA. Ce qui n'y tiendrait pas : un `ng build` ou un
`npm install` lourd lancé **dans** l'espace — mais construire et déployer est le rôle du moteur.

## Pièges connus

- **Une tâche fournie par une extension s'affiche « <source>: <nom> »** : la source de l'extension
  est `Lab ` (avec l'espace) pour obtenir exactement « Lab : construire l'essai ».
- **« Tâche de build par défaut » pour une tâche d'extension** : l'API publique ne permet pas de le
  dire (`TaskGroup.isDefault` est en lecture seule dans `vscode.d.ts`) ; l'extension construit son
  propre groupe `build` et y pose `isDefault` — lu par l'éditeur (code-server 4.141 / VS Code
  1.141, vérifié en navigateur : `Run Build Task` part sans rien demander, même avec une tâche
  `npm: build` concurrente). **À revérifier à chaque montée de code-server** (`verify.sh`,
  section 7) : si cela cesse, `Ctrl+Maj+B` proposera un choix au lieu de lancer.
- **Dans la palette, « Tasks: Run Task » est classé derrière « Tasks: Restart Running Task »** :
  un essai qui tape le titre puis Entrée lance la mauvaise commande (`tests/navigateur.js` clique
  la ligne exacte).
- **Une tâche d'extension sans détecteur d'erreurs déclaré** fait proposer par l'éditeur d'en
  associer un — ce qu'il écrirait dans `.vscode/tasks.json` du projet. L'extension passe un
  tableau vide, ce qui supprime la question.

- **`@agentclientprotocol/claude-agent-acp` déclare `engines: node >= 22`**, comme Claude Code :
  il fonctionne sous le Node 20 de l'image (`initialize`, sessions, MCP : vérifiés), npm avertit
  au build. Même dette que ci-dessous, à solder avec la montée de Node.
- **Le SDK de l'agent ACP (0.3.280) a été écrit pour `claude` 2.1.280** ; il pilote ici le 2.1.296
  de l'image. Vérifié : démarrage, session, modes, MCP. Monter l'un sans l'autre : rejouer
  `verify.sh` (section 3f).
- **Vibe démarre en `accept-edits`** (il modifie les fichiers sans demander) : le service le ramène
  à `ask` à chaque conversation. Si une version future renomme ce mode, la conversation Vibe ne
  s'ouvre plus (échec fermé, message explicite) : corriger `strict` dans `chat/server.js`.
- **Vibe parle hors de tout tour** (à l'ouverture, il annonce l'état de ses serveurs MCP) : ces
  messages s'affichent mais ne comptent pas comme activité.
- **`vibe-acp` met plusieurs secondes à s'arrêter sur SIGTERM** : le service ferme son entrée,
  signale le groupe de processus, puis tue après 5 s ; il ne réutilise jamais un agent en train de
  s'arrêter.
- **`wait -n` de bash perd un enfant mort pendant qu'on attendait l'autre** : l'entrée surveille
  ses deux services par scrutation (`kill -0`, une fois par seconde). Ne pas « simplifier ».
- **`page.waitForFunction` de Playwright est bloqué par la politique de contenu de la page**
  (`script-src 'self'`, pas d'`unsafe-eval`) : `tests/chat_navigateur.js` interroge la page par
  `evaluate`. Ne pas désactiver la politique (`bypassCSP`) pour s'en sortir : elle fait partie de
  ce qu'on éprouve.
- **Le verrou npm est généré avec `--before`** (date = deux semaines plus tôt) pour qu'aucune
  dépendance transitive ne soit plus récente : `npm install --package-lock-only --before=<date>`
  dans `chat/`, depuis un conteneur de l'image.

- **Node 20 est en fin de vie** (avril 2026) et `@anthropic-ai/claude-code@2.1.296` déclare
  `engines: node >= 22` : npm avertit (`EBADENGINE`) au build, sans conséquence — la commande
  `claude` est un binaire natif qui n'utilise pas le Node de l'image. À revoir avec le contrat
  (I7 dit « Node 20 ») à la prochaine montée de version.
- **Mise à jour automatique de Claude Code coupée** (`DISABLE_AUTOUPDATER=1`) : `coder` ne peut pas
  écrire dans `/usr/local`, et l'image doit rester celle qui a été vérifiée.
- **Mode restreint de l'éditeur désactivé** (`disable-workspace-trust`) : l'espace n'ouvre que le
  projet du dev ; le mode restreint coupait en silence l'extension Python.
- **Les extensions de l'image ne sont copiées qu'une fois.** Monter `EXT_PYTHON_VERSION` ne change
  rien pour une maison existante ; le dev met à jour depuis l'éditeur.
- **Vibe ne lit le `AGENTS.md` du projet que pour un dossier « de confiance »** : au premier `vibe`
  dans `/work/<app>`, il pose la question au dev. Celui de la maison (`~/.vibe/AGENTS.md`, les
  règles du lab) est chargé à part (`load_user_doc`, Vibe 2.26.1) — lu dans le code, non éprouvé
  en conversation faute d'identifiant.
- **`vibe mcp add` ne met pas à jour** une entrée existante (« already configured », code 0) :
  l'entrée la retire puis la recrée quand elle diffère.
- **Les dépendances transitives de Vibe ne sont pas verrouillées** (seule `mistral-vibe` l'est) :
  deux builds éloignés dans le temps peuvent différer. `verify.sh` est le filet.
- Dans la maison, Vibe crée des dossiers en lecture seule (`~/.vibe/logs/session/plugins/…`) :
  un `rm -rf` de la maison échoue sans `chmod -R u+rwX` préalable.
