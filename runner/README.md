# runner — tests de cloisonnement en navigateur réel

Conteneur `lab-runner` : Playwright + Chromium, une seule fois pour tout le lab (jamais dans
l'image d'une app). Il joue le test de cloisonnement d'une app : un membre du groupe requis
entre, un non-membre est refusé, y compris après un premier refus dans le même navigateur.
Contexte complet : `CLAUDE.md`, section « Tests end-to-end (Playwright) ».

Réseau `sso-net` seulement, aucun port publié, aucun label Caddy. On le joint par son nom,
`http://lab-runner:4300`.

## Qui l'appelle

- **Le moteur `lab-mcp`** (`labmcp/engine.py`, `POST /run`) : après un déploiement à portes,
  à la demande depuis `lab-admin` (outil MCP `run_tests`), et pour « Tout tester ».
- `scripts/setup_unit.sh`, pour une app à portes déployée par `setup2.sh`
  (`docker exec lab-runner curl … /run`).
- `storage/frontend/e2e/jouer-gestes.sh`, à la main par `docker exec`. Il réutilise
  `playwright.config.ts` pour `gestes.spec.ts` et pose `E2E_GESTES=1` (voir la config).

## API (contrat « urgences » v1, interface I2)

| Route | Réponse |
|---|---|
| `GET /healthz` | `{"ok": true, "busy": <bool>}` |
| `GET /list?app=<app>` | `[{file, title}]` (catalogue sans navigateur) |
| `POST /run` `{"app": "<app>"}` | `[{file, title, status, message, durationMs}]`, `status` ∈ `PASSED`/`FAILED`/`ERROR` |

- **400** si le nom est absent ou ne suit pas `^[a-z][a-z0-9-]{0,62}$`. Dans ce cas, rien n'est lancé.
- **409** si un run est déjà en cours : un seul à la fois sur tout le lab (2 vCPU).
- **422** si l'URL de l'app ne se résout pas : `DOMAIN` absent, ou aucun label `caddy.handle_path`.
- **`[]`** si l'app n'a pas de `frontend/e2e/cloisonnement.spec.ts`. Cela veut dire « aucun
  test », jamais « tout va bien ». Le moteur le rend comme le verdict `absent`.

## Ce qui est exécuté, et pourquoi

Le dépôt d'une app est écrit par son développeur. Ce conteneur, lui, monte tout le dépôt
parent en lecture, `sso-lab/.env` compris, et il a les mots de passe de `e2e_member` et
`e2e_outsider` dans l'environnement de chaque run. Jouer le spec de l'app reviendrait à
exécuter le code du développeur à côté de ces secrets. Donc :

- Le fichier joué est **toujours celui du gabarit** :
  `/mnt/dev/_templates/django-angular/frontend/e2e/cloisonnement.spec.ts`.
  - Il est copié dans un dossier temporaire neuf à chaque appel (`/tmp/lab-runner-*`,
    `lib/spec.js`), puis supprimé.
  - Ce dossier devient `testDir` (`E2E_TEST_DIR`).
- Pour l'app, le runner ne regarde que la **présence** de son
  `frontend/e2e/cloisonnement.spec.ts` : c'est le seul signal « cette app a un test ».
  - Le contenu de ce fichier n'est jamais lu.
  - Aucun autre fichier de son `e2e/` n'est chargé, ni par `/run`, ni par `/list`.
- `playwright.config.ts` limite aussi `testMatch` à `cloisonnement.spec.ts`. C'est un second
  rempart.
- Lu dans le dépôt, sans rien exécuter :
  - les labels `caddy.handle_path` du `docker-compose.yml` de l'app (son chemin public) ;
  - `DOMAIN` dans le `.env` racine ;
  - `E2E_MEMBER_PASSWORD` et `E2E_OUTSIDER_PASSWORD` dans `sso-lab/.env`, relus à chaque run.
- Variables passées au spec : `E2E_APP_URL`, `E2E_DOMAIN`, `E2E_MEMBER_USER`,
  `E2E_MEMBER_PASSWORD`, `E2E_OUTSIDER_USER`, `E2E_OUTSIDER_PASSWORD`.
- Le domaine public est résolu vers le conteneur `caddy` (`--host-resolver-rules`), pour ne pas
  dépendre du NAT en épingle de la box.
- `init: true` : sans init en PID 1, les processus Chromium orphelins restaient zombies.

Conséquence : un changement du test de cloisonnement se fait **dans le gabarit**. Il vaut
alors pour toutes les apps au run suivant, sans reconstruire le runner.

## Reconstruire et redémarrer

Ce sont des gestes de l'architecte. Avant de les faire, vérifier qu'aucun run n'est en cours :
`busy` à `false` sur `/healthz`.

```bash
bash scripts/lab-lock.sh bash scripts/recompose_docker.sh --app runner   # up -d --build
docker inspect -f '{{.State.Running}} {{.HostConfig.Init}}' lab-runner     # attendu : true true
```

`HOST_DEV_ROOT` (`runner/.env`, propagé par `reset_url.sh`) : voir le piège décrit dans
`CLAUDE.md`. Un chemin faux monte un `/mnt/dev` vide sans erreur, et chaque app répond alors `[]`.

## Reste à faire

- **Mettre Playwright à jour** : l'image et `@playwright/test` sont en 1.48.0. L'image
  `mcr.microsoft.com/playwright:vX-jammy` et `package.json` doivent bouger ensemble. C'est un
  build lourd, à rejouer ensuite sur toutes les apps.
- **R1** (`to_do_global.md` § 3) :
  - réduire le montage de tout le dépôt au strict nécessaire ;
  - restreindre la sortie réseau du navigateur.
