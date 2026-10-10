# workspace/ — image d'espace de travail par projet (`lab-workspace`)

Service racine du dépôt, comme `runner/` : pas une app, pas un sous-module. C'est l'image du
conteneur `ws-<uid>` que le moteur du lab (`lab-mcp`) lance pour un dev, ouvert sur **un** projet
(contrat « multi-dev », interfaces I3 et I7). Ce dossier ne livre **que l'image** : le cycle de vie
des conteneurs, leurs réseaux, l'acheminement par Caddy et le contrôle d'accès sont au moteur.

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
| git, openssh-client, curl, jq, tini, nano, less | paquets Debian 12 | — |

Utilisateur `coder`, uid/gid 1000, seul groupe `coder`. **Ni `sudo`, ni Docker, ni compilateur.**
Toutes les versions sont des `ARG` en tête du `Dockerfile`, nulle part ailleurs. L'image les
annonce dans la variable `LAB_WORKSPACE_VERSIONS`.

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

- Aucun port à publier : l'éditeur écoute sur **8080** dans le conteneur.
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

## Vérifier

```bash
bash workspace/verify.sh                    # ~4 min, navigateur réel compris
bash workspace/verify.sh --sans-navigateur  # ~2 min, curl seulement
```

Conteneurs jetables `ws-test-image-*`, réseaux jetables `ws-test-image-net*` (jamais `dev-net` ni
`sso-net`), options d'enfermement d'I3, jetons factices, faux serveur MCP : aucun identifiant réel.
Tout est supprimé à la sortie. Le navigateur est celui de l'image du runner du lab
(`runner-runner:latest`, lancée comme conteneur jetable — le service `lab-runner` n'est pas touché) ;
c'est une charge Playwright, à ne pas lancer pendant un autre test navigateur.

Ce que le script **ne peut pas** prouver : une conversation réelle avec Claude ou Mistral (il
faudrait un identifiant ; aucun n'est emprunté à l'hôte). La preuve s'arrête à : binaires présents
et utilisables depuis le terminal intégré, déclarations lues par chaque outil, jeton de
l'environnement reçu par le serveur MCP (`claude mcp get lab` → *Connected* ; client MCP de Vibe →
liste des outils).

## Mesures (2026-10-10, hôte 2 vCPU, limites 2 Go / 1 vCPU / 512 pids)

| | Mémoire du conteneur | Processus/fils |
|---|---|---|
| Au repos, personne de connecté | ~190 Mo (110 anonymes) | 25 |
| Éditeur ouvert, fichier Python, extension Python active, un terminal | ~700 Mo (575 anonymes) | 88 |
| + Claude Code et Vibe lancés (premier écran, sans conversation) | ~920 Mo (800 anonymes) | 106 |
| Pic observé | 940 Mo | 114 |

Premier démarrage 6,3 s ; redémarrage 1,9 s. Les défauts du contrat (2 Go, 3 espaces) tiennent
pour éditer et faire travailler une IA. Ce qui n'y tiendrait pas : un `ng build` ou un
`npm install` lourd lancé **dans** l'espace — mais construire et déployer est le rôle du moteur.

## Pièges connus

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
