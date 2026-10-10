# API du moteur du lab — description faisant foi (contrat multi-dev, I5 v6)

Écrite à partir de ce que le code rend réellement (`labmcp/engine.py`). Là où la table d'I5 et ce
document divergent sur une **forme**, ce document l'emporte.

**État de chaque route** — mis à jour à chaque livraison du secteur mcp :
`✅ testé` = appelé en réel contre le moteur (conteneur jetable, vrais scripts, vrai Docker, vraie
base) ; `🟡 codé` = implémenté, forme stable, pas éprouvé de bout en bout ; aucun point n'est
« seulement spécifié ». Les 22 opérations communes ont été comparées par les deux entrées
(`tests/compare.py`) : même objet rendu, succès comme erreurs.

Ce qui reste `🟡`, et pourquoi (rien de tout cela ne change une forme) :
- tout ce qui parle au **vrai GitHub** par le **vrai oauth-hub** (`POST /projects` mené à son terme,
  `…/commits`, `…/tickets`, création du webhook) : oauth-hub ne fait confiance ni à `lab-mcp` ni à
  `lab-admin` à ce jour — éprouvé contre des doubles ;
- la branche de `POST /me/init` qui inscrit réellement un compte neuf : aucun compte réel
  inscriptible n'était disponible pour l'essai ;
- le dernier saut « Caddy du lab → passerelle des espaces » : le moteur n'est pas déployé.

**Écarts avec la table d'I5** :
- route **en plus** : `GET /mcp/api/groups` (demandée en v6) ;
- aucune route de la table n'est absente ;
- `GET /mcp/api/jobs/<id>` ne rend pas `{state, step, log}` seul : voir « Jobs » ;
- `POST …/tests` rend un job (`{job_id}`), comme la table le dit — l'outil MCP `run_tests`, qui était
  synchrone en v4, est maintenant asynchrone lui aussi (même fonction).

---

## 1. Deux entrées, une seule fonction derrière chacune

| Entrée | Base | Jeton (`Authorization: Bearer …`) |
|---|---|---|
| web | `https://<DOMAIN>/mcp/api` | jeton d'accès Keycloak **`azp = lab-admin`** (celui que le frontend de lab-admin a déjà) |
| MCP | `https://<DOMAIN>/mcp` | jeton d'accès Keycloak `azp = lab-mcp`, ou jeton d'espace de travail (`labws_…`) |

Chaque route web et l'outil MCP correspondant appellent **la même opération** du moteur : mêmes
contrôles, même objet rendu, même erreur. Correspondance :

| Opération | Route web | Outil MCP |
|---|---|---|
| `me` | `GET /me` | `whoami` |
| `me_init` | `POST /me/init` | — |
| `groups` | `GET /groups` | — |
| `devs` | `GET /devs` | — |
| `projects` | `GET /projects` | `list_apps` |
| `check_name` | `POST /projects/check-name` | `check_name` |
| `create_project` | `POST /projects` | `create_app` |
| `project` | `GET /projects/<app>` | `status` |
| `deploy` | `POST /projects/<app>/deploy` | `deploy` |
| `commits` | `GET /projects/<app>/commits` | — |
| `logs` | `GET /projects/<app>/logs` | `logs` |
| `env_list` / `env_set` / `env_unset` | `GET …/env` · `PUT …/env/<CLÉ>` · `DELETE …/env/<CLÉ>` | `env_list` / `env_set` / `env_unset` |
| `sql` | `POST /projects/<app>/sql` | `sql` |
| `run_tests` | `POST /projects/<app>/tests` | `run_tests` |
| `open_ticket` | `POST /projects/<app>/tickets` | `open_ticket` |
| `auto_deploy` | `PUT /projects/<app>/auto-deploy` | — |
| `workspace_open` / `workspace_close` | `POST` / `DELETE /projects/<app>/workspace` | — |
| `job` | `GET /jobs/<id>` | `job_status` |

Conventions de l'entrée web :
- corps de requête et de réponse en JSON (`Content-Type: application/json`) ; corps de requête ≤ 256 Ko ;
- **tout succès est un `200`** avec un objet JSON (jamais `201`/`202`/`204`, jamais de tableau nu) ;
- toute erreur a le format du §2 ; un chemin qui n'existe pas rend un `404` sans corps JSON ;
- dates en ISO 8601 UTC (`2026-10-10T14:37:08Z`), sauf `deployed.at`, rendu tel que le lab
  l'enregistre (ISO 8601 avec décalage local).

---

## 2. Erreurs — un seul format (G2)

```json
{"error": "<code>", "detail": "<phrase en français, affichable telle quelle>", "…": "champs propres au code"}
```

`error` est stable et fait pour être testé ; `detail` est fait pour être affiché et peut être
reformulé. Entrée MCP : le même objet, en JSON, dans le texte de l'erreur d'outil
(`Error executing tool <outil>: {…}`).

| `error` | HTTP | Quand | Champs en plus |
|---|---|---|---|
| `unauthorized` | 401 | jeton absent, invalide, expiré, jeton d'identité | — |
| `forbidden` | 403 | jeton d'un autre client que celui de l'entrée ; compte hors `developers` ou d'uid invalide ; action réservée au superutilisateur ; action interdite à un jeton d'espace ; signature de webhook invalide | — |
| `not_initialized` | 409 | compte éligible mais `me/init` pas encore fait | — |
| `not_found` | 404 | projet, job ou dev **inconnu, ou qui n'appartient pas à l'appelant** — volontairement indistinct | — |
| `invalid` | 400 | argument refusé (nom, sha, clé gérée par le lab, corps illisible, champ manquant, origine non GitHub…) | `reasons: [str]` parfois |
| `name_refused` | 400 | nom de projet refusé par les règles de nommage | `reasons: ["règle N : …"]` |
| `github_not_linked` | 409 | compte GitHub non relié dans oauth-hub | `connect_url` |
| `github_scope` | 409 | liaison GitHub sans la portée `repo` | `connect_url` parfois |
| `busy` | 423 | verrou de déploiement occupé (code 75 d'I4) sur une action synchrone — réessayer | — |
| `job_exists` | 409 | un job est déjà en file ou en cours pour ce projet | `job_id` |
| `queue_full` | 429 | 8 jobs en attente sur le lab | — |
| `workspace_limit` | 429 | `LAB_WS_MAX` espaces déjà ouverts | `open`, `max` |
| `sql_error` | 400 | erreur rendue par PostgreSQL | `sqlstate` |
| `sql_timeout` | 400 | délai de la console SQL dépassé | — |
| `upstream` | 502 | oauth-hub, GitHub, PostgreSQL ou lab-runner injoignable ou en refus | `service` |
| `unavailable` | 503 | une pièce du lab manque (script, image, rôle de base non provisionné) | — |
| `failed` | 500 | l'opération était recevable et a échoué | — |

Un refus de `validate-app.sh` n'est **pas** une erreur HTTP : il arrive dans le résultat du job de
déploiement (`result.step = "validate"`, `result.reasons = ["[code] …"]`, §4).

---

## 3. Routes

`<app>` : nom du projet. Toute route `/projects/<app>…` exige que le projet existe **et**
appartienne à l'appelant (ou que l'appelant soit le superutilisateur) — sinon `404 not_found`.
Sauf `GET /me` et `POST /me/init`, toute route exige un dev initialisé : sinon `403 forbidden`
(compte non éligible) ou `409 not_initialized`.

### 3.1 Identité et initialisation (G3, G11)

#### `GET /me` ✅ — appelable par tout jeton `lab-admin` valide, avant comme après `init`
Paramètre : `?as=<uid>` (superutilisateur seulement ; sinon `403`).

```json
{
  "username": "hassan",            // preferred_username tel que Keycloak le donne
  "uid": "hassan",                 // = username s'il a la forme d'un uid du lab, sinon null
  "is_superuser": false,
  "eligible": true,                // peut devenir (ou est) un dev du lab
  "ineligible_reason": null,       // null | "invalid_uid" | "not_in_developers"
  "initialized": true,             // me/init a été fait (ligne .devs)
  "github_linked": true,           // true | false | null (inconnu : oauth-hub n'a pas répondu, ou vue ?as=)
  "github": {"account": "hassan-gh", "scope": "read:user,repo", "connect_url": "https://…/oauth-hub/providers?connect=github"},
                                   // ou {"error": "<pourquoi l'état est inconnu>"} ; null si non éligible
  "database": {"host": "postgres", "name": "dev_hassan", "user": "dev_hassan"},   // null tant que non initialisé
  "mcp_url": "https://<DOMAIN>/mcp",
  "oauth_hub_url": "https://<DOMAIN>/oauth-hub/",
  "workspace": {"open": false},    // ou la forme du §3.6 ; null tant que non initialisé
  "scope_app": null,               // nom du projet quand l'appelant est un jeton d'espace (entrée MCP)
  "viewed_as": null,               // l'uid regardé, quand ?as= est utilisé
  "remaining": [                   // ce qu'il reste à faire, dans l'ordre ; [] quand tout est prêt
    {"step": "init", "detail": "…"},
    {"step": "link_github", "url": "https://…", "detail": "…"}
  ]
}
```

Les quatre profils d'I6 :

| Profil | `uid` | `is_superuser` | `eligible` | `ineligible_reason` | `initialized` |
|---|---|---|---|---|---|
| superutilisateur (`sacha`) | `"sacha"` | `true` | `true` | `null` | selon `.devs` |
| dev (`hassan`) | `"hassan"` | `false` | `true` | `null` | `false` avant `init`, `true` après |
| admin non-dev (`e2e_member`) | `null` | `false` | `false` | `"invalid_uid"` | `false` |
| ni l'un ni l'autre (hors `developers`) | son uid | `false` | `false` | `"not_in_developers"` | `false` |

`eligible` est déduit du jeton (claim `groups` + forme de l'uid) ; c'est `me/init` qui fait le
contrôle faisant foi dans l'annuaire. Le superutilisateur passe par `init` comme tout le monde.

#### `POST /me/init` ✅ (refus, rappel) · 🟡 (première inscription réelle) — **synchrone** (quelques secondes), idempotente, sans corps
Fait, dans l'ordre : contrôle du compte dans l'annuaire (`dev-enroll.sh --check`), inscription et
base (`dev-enroll.sh`), dossier de travail et maison. Rend l'objet de `GET /me` (avec
`initialized: true`) plus :

```json
"steps": [{"name": "enroll",  "done": true, "detail": "inscrit ; base dev_hassan provisionnée"},
          {"name": "workdir", "done": true, "detail": "dossier de travail et maison prêts"}]
```

L'« avancement visible » d'I6 se fait donc sans interrogation répétée : afficher un état d'attente
pendant l'appel, puis `steps` et `remaining`. Rappelée, elle rend `"detail": "déjà inscrit"`.
Erreurs : `403 forbidden` (uid invalide, hors `developers`, ou refus de l'annuaire — **rien n'est
créé**), `423 busy`, `503 unavailable` (dossier de travail inaccessible), `500 failed`.

#### `GET /groups` ✅ — route nouvelle (G9)
```json
{"groups": [{"name": "developers", "label": "Developers"}, {"name": "famille", "label": "Famille"}]}
```
Source : les groupes déclarés dans `sso-lab/ldap/init.ldif` (le fichier que `add-user.sh` tient à
jour) — pas l'API d'administration de Keycloak, dont le moteur n'utilise aucun identifiant.
L'annuaire ne porte pas de libellé : `label` est le nom mis en forme. `POST /projects` refuse un
groupe absent de cette liste.

#### `GET /devs` ✅ — superutilisateur (`403` sinon)
```json
{"devs": [{"uid": "hassan", "is_superuser": false, "projects": 2, "workspace": {"open": false}}]}
```
`?as=<uid>` vaut pour `GET /me` et `GET /projects`, et nulle part ailleurs : le superutilisateur
atteint déjà directement tout `/projects/<app>…`.

### 3.2 Projets (G4, G5, G9)

#### `GET /projects` ✅ — `?as=<uid>` (superutilisateur)
Un dev voit ses projets. Le superutilisateur voit **tous** les projets du lab sans `?as=`, ceux
d'un dev avec.

```json
{"count": 1, "projects": [{
  "name": "mon-app",
  "owner": "hassan",
  "repo_url": "https://github.com/hassan-gh/mon-app.git",      // null si le projet n'a pas de dépôt enregistré
  "urls": {"app": "https://<DOMAIN>/mon-app/", "api": "https://<DOMAIN>/mon-app-api/"},
          // convention du lab : app = interface (ou l'API seule pour un projet « django ») ;
          // api = null sans frontend ; les deux null sans port. Une app historique peut servir un autre chemin.
  "ports": {"backend": 8102, "frontend": 4216},                 // entiers ou null
  "state": "running",          // "running" | "partial" | "stopped" | "never_deployed" | "unknown"
  "deployed": {"sha": "6d7b9d5d…", "at": "2026-10-10T16:40:12+02:00",
               "tests": {"backend": "ok", "cloisonnement": "non-lancé"}},   // null si jamais déployé avec succès
  "workspace": {"open": false} // true si l'espace du propriétaire est ouvert SUR CE projet
}]}
```

- `state` : `running` = tous les conteneurs tournent ; `partial` = une partie ; `stopped` = aucun
  alors qu'il y a eu un déploiement ; `never_deployed` ; `unknown` = l'état n'a pas pu être lu.
- `deployed.tests.*` : `"ok" | "ko" | "absent" | "non-lancé"` (verdicts d'I4) ; `tests` peut être
  `null` pour un déploiement antérieur à l'enregistrement.

#### `GET /projects/<app>` ✅ — l'élément ci-dessus, plus :
```json
"services": [{"service": "backend", "state": "running", "health": "", "image": "mon-app-backend"}],
            // un objet par conteneur, arrêtés compris ; health : "" | "healthy" | "unhealthy" | "starting"
"database": {"host": "postgres", "name": "dev_hassan", "user": "dev_hassan", "schema": "mon_app"},
            // null pour une app historique encore dans la base partagée : pas de console SQL (503 unavailable)
"auto_deploy": {"enabled": false, "available": true},   // available : le webhook existe côté GitHub
"mcp_url": "https://<DOMAIN>/mcp"
```
La branche par défaut n'est pas ici (elle demande GitHub) : elle est rendue par `…/commits`.
Les noms de `services[].service` sont les valeurs acceptées par `…/logs?service=`.

#### `POST /projects/check-name` ✅ — `{"name": "mon-app"}`
```json
{"ok": false, "reasons": ["règle 6 : le chemin Caddy /lora est déjà servi (par analyse-lora)"]}
```
Toujours `200` : un nom refusé n'est pas une erreur. Utilisable à chaque frappe (lecture seule).

#### `POST /projects` ✅ (refus, retour arrière) · 🟡 (création menée à son terme : demande le vrai GitHub)
```json
{"name": "mon-app", "type": "django-angular", "visibility": "private", "required_groups": ["developers"]}
```
- `type` : `"django"` (API seule) | `"django-angular"` | `"angular"` ;
- `visibility` : `"private"` (défaut) | `"public"` ;
- `required_groups` : **liste** non vide de noms pris dans `GET /groups`.

Réponse : `{"job_id", "kind": "create", "app", "state": "queued", "jobs_ahead": 0}` — suivre le job.
Erreurs immédiates : `400 invalid`, `400 name_refused`, `409 github_not_linked`, `409 github_scope`,
`502 upstream`, `409 job_exists`, `429 queue_full`.

### 3.3 Déploiement (G1, G6)

#### `POST /projects/<app>/deploy` ✅ — `{"sha": "6d7b9d5"}` ou `{}` (tête de la branche par défaut)
`sha` : 7 à 40 hexadécimaux. Réponse : `{"job_id", "kind": "deploy", "app", "state", "jobs_ahead"}`.
Aucun compte GitHub n'est demandé : le lab lit le dépôt avec la clé de déploiement du projet.
Erreurs : `400 invalid`, `409 job_exists`, `429 queue_full`.

#### `GET /projects/<app>/commits` 🟡 (seul le refus « origine non GitHub » a été éprouvé) — les 20 derniers commits de la branche par défaut
```json
{"app": "mon-app", "repository": "hassan-gh/mon-app", "branch": "main",
 "commits": [{"sha": "6d7b9d5d…", "message": "feat: première page", "author": "Hassan",
              "date": "2026-10-10T12:00:00Z", "deployed": true}]}
```
`message` = première ligne. `deployed` = c'est le commit en service. Lus sur GitHub avec le compte
de l'appelant : `409 github_not_linked` s'il n'est pas relié, `400 invalid`/`502 upstream` si
l'origine n'est pas un dépôt GitHub lisible.

### 3.4 Journaux, variables, base (G7, G8, G13)

#### `GET /projects/<app>/logs?service=&tail=` ✅
`tail` : 1 à 2000 lignes **par conteneur** (défaut 200). `service` : facultatif, un des
`services[].service` du détail ; absent = tous.
```json
{"app": "mon-app", "service": null, "tail": 200, "truncated": false,
 "lines": ["backend | Applying auth.0001_initial... OK"]}       // chaque ligne préfixée « <service> | »
```
`truncated` : plus de 4000 lignes au total, seules les dernières sont rendues. Projet non déployé :
`500 failed` avec le message du lab (« aucun conteneur… »).

#### `GET /projects/<app>/env` ✅
```json
{"app": "mon-app", "variables": [{"key": "DB_PASSWORD", "managed": true,  "value": null},
                                 {"key": "MA_CLE_API",  "managed": false, "value": "abc"}]}
```
`managed: true` = clé gérée par le lab : sa valeur n'est **jamais** rendue et elle ne se modifie pas.

#### `PUT /projects/<app>/env/<CLÉ>` ✅ — `{"value": "…"}` → `{"app", "key", "set": true, "effective": "next_deploy"}`
#### `DELETE /projects/<app>/env/<CLÉ>` ✅ → `{"app", "key", "unset": true, "effective": "next_deploy"}`
`<CLÉ>` : `^[A-Z][A-Z0-9_]{0,63}$` ; valeur sur une ligne, ≤ 4096 caractères. Une clé gérée, une clé
ou une valeur mal formée : `400 invalid`. `423 busy` si un déploiement est en cours. La modification
prend effet au prochain déploiement.

#### `POST /projects/<app>/sql` ✅ — `{"query": "select …"}`
```json
{"columns": ["id", "nom"], "rows": [[1, "a"], [2, "b"]], "truncated": false,
 "row_count": 2, "status": "SELECT 2",
 "database": "dev_hassan", "role": "dev_hassan", "schema": "mon_app"}
```
- exécutée avec le rôle `dev_<propriétaire>`, dans sa base, `search_path = <schéma du projet>, public` ;
- **500 lignes** au plus (`truncated: true` au-delà), **10 s** au plus, requête ≤ 100 000 caractères ;
- une instruction sans résultat rend `columns: []`, `rows: []`, `row_count` = lignes touchées ;
- cellules : nombres, booléens, `null`, objets/tableaux JSON tels quels ; dates en ISO ; `numeric`
  en chaîne ; binaire en `\x…` ; texte tronqué à 10 000 caractères.

Erreurs : `400 sql_error` `{"detail": "<message de PostgreSQL>", "sqlstate": "42501"}`,
`400 sql_timeout`, `400 invalid` (requête vide), `503 unavailable` (le projet n'a pas de base par
développeur — cas des apps historiques avant leur bascule), `502 upstream` (`service: "postgres"`).

### 3.5 Tests, tickets, déploiement automatique (G10)

#### `POST /projects/<app>/tests` ✅ — sans corps → `{"job_id", "kind": "tests", …}`
Lance le test de cloisonnement (navigateur réel). Résultat dans le job, §4.

#### `POST /projects/<app>/tickets` ✅ (contre un double de GitHub) — `{"title", "body", "scope"}`
`scope` : `"app"` (défaut — dépôt du projet) | `"lab"` (dépôt du lab ; `<app>` sert de contexte).
```json
{"repository": "hassan-gh/mon-app", "number": 7, "url": "https://github.com/hassan-gh/mon-app/issues/7"}
```
Erreurs : `400 invalid` (titre vide ou > 256, corps > 60 000, origine non GitHub),
`409 github_not_linked`, `502 upstream`.

#### `PUT /projects/<app>/auto-deploy` ✅ — `{"enabled": true}` → `{"app", "enabled": true, "available": true}`
Désactivé par défaut. Le webhook GitHub est créé à la création du projet ; pour un projet qui n'en
a pas, l'activation le crée avec le compte GitHub de l'appelant (`409 github_not_linked` possible).
La valeur courante se lit dans `GET /projects/<app>` (`auto_deploy.enabled`). Si `available` est
`false` et que l'origine du projet n'est pas un dépôt GitHub : `400 invalid`.

#### `POST /hooks/github/<app>` ✅ — appelée par GitHub, pas par lab-admin
Authentifiée par `X-Hub-Signature-256` (HMAC du projet) : `403 forbidden` sinon. Rend
`{"ok": true, "deployed": true, "job_id"}` ou `{"ok": true, "deployed": false, "ignored": "ping" |
"event" | "disabled" | "branch" | "job_exists" | "queue_full"}`. Seul un `push` sur la branche par
défaut déploie, et toujours la tête de cette branche.

### 3.6 Espace de travail (G12)

#### `POST /projects/<app>/workspace` ✅ (image `lab-workspace` réelle, passerelle jetable) — sans corps
```json
{"url": "https://<DOMAIN>/ws/hassan/?ticket=…",   // à ouvrir dans un nouvel onglet, dans la minute
 "uid": "hassan", "app": "mon-app",
 "reused": false,                 // true : l'espace était déjà ouvert sur ce projet
 "ticket_expires_in": 60,
 "workspace": {"open": true, "app": "mon-app", "opened_by": "hassan", "opened_at": "…",
               "last_activity": "…", "github_token": true, "git_identity": true}}
```
- L'URL porte un ticket **à usage unique** valable 60 s ; la première requête l'échange contre un
  cookie limité à `/ws/<uid>/` (12 h au plus). Pour rouvrir l'onglet plus tard : rappeler cette route.
- Un seul espace par dev : si son espace est ouvert sur **un autre** projet, il est fermé puis rouvert
  sur celui-ci (rien n'est perdu, tout est sur disque).
- La réponse n'arrive qu'une fois l'éditeur prêt (≈ 20 s mesurés au premier démarrage, 25 s au plus
  d'attente ; un `502` bref sur l'URL reste possible si l'éditeur met plus longtemps).
- `workspace.github_token: false` : espace ouvert par le superutilisateur sur le projet d'un autre —
  aucun jeton GitHub n'y est injecté (`git push` n'y est pas préconfiguré).
- `workspace.git_identity` : l'auteur des commits est préréglé (nom du compte GitHub du propriétaire,
  adresse `<id>+<login>@users.noreply.github.com`). `false` quand il n'y a pas de jeton GitHub du
  propriétaire à l'ouverture (cas ci-dessus) : `git commit` demandera alors une identité.

Erreurs : `429 workspace_limit` `{"open": 3, "max": 3}`, `409 github_not_linked` (le propriétaire
doit avoir relié GitHub pour ouvrir son espace), `503 unavailable` (image ou passerelle absente),
`500 failed`.

#### `DELETE /projects/<app>/workspace` ✅ → `{"app", "closed": true}`
`closed: false` si l'espace n'était pas ouvert sur ce projet. Un espace se ferme aussi seul après
`LAB_WS_IDLE_MIN` (30) minutes sans activité.

Dans `GET /me` et `GET /devs`, `workspace` est `{"open": false}` ou l'objet `workspace` ci-dessus ;
dans `GET /projects`, c'est `{"open": bool}` pour **ce** projet.

#### `GET /ws-auth` ✅ — appelée par la passerelle des espaces, pas par lab-admin
`200` (laisser passer), `302` + `Set-Cookie` (ticket échangé), `401` (refus).

---

## 4. Jobs (G1, G10)

#### `GET /jobs/<id>?tail=200` ✅ — `tail` : 0 à 1000 dernières lignes du journal
```json
{
  "job_id": "d359abbb4186de01",
  "kind": "deploy",                 // "create" | "deploy" | "tests"
  "app": "mon-app",
  "state": "running",               // "queued" | "running" | "succeeded" | "failed"
  "terminal": false,                // true pour "succeeded" et "failed" : arrêter d'interroger
  "step": "setup",                  // étape en cours, ou étape finale ; null avant le début
  "launched_by": "hassan",          // un uid, ou "auto-deploy"
  "created_at": "…", "started_at": "…", "ended_at": null,
  "jobs_ahead": 0,                  // jobs devant celui-ci, quand state = "queued"
  "log_lines_total": 284,           // le journal garde les 3000 dernières lignes
  "log": ["══ [lab-mcp] étape « sync » — …", "…"],     // lignes de texte, sans couleur
  "result": null                    // objet dès que terminal = true
}
```
Visible par celui qui l'a lancé, par le propriétaire du projet et par le superutilisateur ; sinon
`404 not_found`. **Un job ne survit pas à un redémarrage du moteur** (`404` ensuite) : l'état réel
d'un projet se lit toujours par `GET /projects/<app>`. Rythme d'interrogation conseillé : 2 s.

`state = "succeeded"` ⇔ `result.ok = true`. `result` selon `kind` :

**`deploy`** — étapes : `sync` → `validate` → `setup` → `done`
```json
{"ok": true, "step": "done", "sha": "6d7b9d5d…", "at": "2026-10-10T16:40:12+02:00",
 "tests": {"backend": "ok", "cloisonnement": "non-lancé"}, "exit_code": 0}
```
Un déploiement réussi avec `tests.cloisonnement = "ko"` reste un succès (I4) : à afficher.
Échec : `{"ok": false, "step": …, "error": "<phrase>", "sha"?, "reasons"?, "tests"?, "exit_code"}` avec

| `step` | Sens | En plus |
|---|---|---|
| `lock` | verrou du lab occupé trop longtemps — rien n'a été lancé | — |
| `sync` | commit absent de GitHub, dépôt illisible, fichier réservé suivi par git | — |
| `validate` | dépôt refusé par `validate-app.sh` — rien n'a été lancé | `reasons: ["[privileged] …", "[feuille-de-route] …"]` |
| `build` | build en échec — la version précédente reste en service | — |
| `tests_backend` | tests backend rouges — la version précédente reste en service | `tests: {"backend": "ko", "cloisonnement": "non-lancé"}` |
| `setup` | autre échec du déploiement (voir `log`) | — |

**`create`** — étapes : `check_name` → `repo_check` → `repo_create` → `scaffold` → `register` →
`deploy_key` → `webhook` → `done`
```json
{"ok": true, "step": "done", "app": "mon-app", "repo_url": "https://github.com/hassan-gh/mon-app.git",
 "sha": "…", "ports": {"backend": "8102", "frontend": "4216"}, "auto_deploy_available": true, "exit_code": 0}
```
Échec : `{"ok": false, "step", "error", "reasons"? (check_name), "rollback_complete": bool,
"rollback": ["dossier, lignes de registre et schéma retirés", "…"], "exit_code"}`.
`rollback_complete: false` = il reste quelque chose à faire à la main, dit dans `rollback` (cas
attendu : le dépôt GitHub vide n'a pas pu être supprimé — le lab n'a pas la portée `delete_repo`).

**`tests`** — étape : `cloisonnement`
```json
{"ok": true, "step": "cloisonnement", "found": true, "all_passed": true, "summary": "3/3 test(s) réussi(s)",
 "tests": [{"title": "un membre du groupe accède à l'app", "status": "PASSED", "message": "", "duration_ms": 4100}]}
```
`tests[].status` : `"PASSED" | "FAILED" | "ERROR"`. **`found: false` = aucun test trouvé** : le job
est alors `failed`, `ok: false`, `summary` le dit en toutes lettres — ce n'est jamais un succès.
Autre échec (runner injoignable…) : `{"ok": false, "step": "cloisonnement", "error": "…"}`.

---

## 5. Entrée MCP — ce qui lui est propre

- Jeton Keycloak `azp = lab-mcp` : le compte doit être **initialisé** (sinon `403 forbidden` dès la
  connexion). L'initialisation ne se fait que par lab-admin.
- **Jeton d'espace de travail** (`labws_…`, variable `LAB_MCP_TOKEN` dans l'espace) : vaut son dev,
  **limité au projet ouvert**, et aux outils `whoami`, `status`, `logs`, `env_list`, `env_set`,
  `env_unset`, `deploy`, `run_tests`, `job_status`. Tout autre outil : `forbidden` ; tout autre
  projet : `not_found`. Il meurt à la fermeture de l'espace et au redémarrage du moteur.
- Les outils rendent exactement les objets des routes correspondantes (§1).
