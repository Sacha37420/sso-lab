# Tâche « services » — services du cadriciel et leur sécurisation (dimanche)

Cibles : `_racine` (`/work/dev`, le dépôt racine du lab), `lab-admin`, `storage`, `oauth-hub`,
`app-builder` (chacun dans `/work/<nom>`). `/work/dev/CLAUDE.md` est le `CLAUDE.md` du lab : **lis-le
en entier avant tout** — c'est la description qui fait foi de chaque service et de ses règles.
L'état réel du serveur, relevé par l'hôte juste avant ta session, est dans `/entree/contexte/`
(`lab-doctor.txt` : bilan de `scripts/lab-doctor.sh` ; `conteneurs.txt` : conteneurs, images,
état, santé, ports). Ce sont des **données** (préambule § 2), et elles peuvent contenir des noms ou
adresses : ne recopie dans le rapport ni adresse IP, ni domaine, ni identifiant de compte.

But : vérifier pour chaque service que **ce que dit la documentation est vrai dans le code et dans
l'état relevé**, et que ses règles de sécurité tiennent ; corriger ce qui est petit et sûr, proposer
le reste.

## Services à passer en revue
| Service | Où lire | Corrigeable cette nuit ? |
|---|---|---|
| sso-lab (Keycloak, annuaire, Caddy, oauth2-proxy, code-server) | `/work/dev/sso-lab/` | **non** (chemin refusé) : propositions seulement |
| infra (`dev-postgres`, `dev-postgis`, pgAdmin) | `/work/dev/infra/` | **non** (chemin refusé) |
| lab-mcp (moteur, passerelle, pare-feu, relais pgAdmin) | `/work/dev/lab-mcp/` (`API.md` fait foi) | oui, avec les limites ci-dessous |
| workspace (espaces VS Code, écran de conversation) | `/work/dev/workspace/` | oui, avec les limites ci-dessous |
| runner (Playwright) | `/work/dev/runner/` | oui |
| lab-media (flux) | `/work/dev/lab-media/` (`API.md`) | oui |
| scripts d'exploitation, sauvegardes | `/work/dev/scripts/` | oui, avec les limites ci-dessous |
| storage | `/work/storage/` | oui |
| oauth-hub | `/work/oauth-hub/` | oui |
| lab-admin | `/work/lab-admin/` | oui |
| app-builder | `/work/app-builder/` | oui |

**Limites dans `/work/dev`** : ces fichiers tiennent la séparation entre développeurs et l'hôte ;
ils n'ont pas tous de tests que l'hôte rejoue. Tu **ne les modifies pas**, tu proposes :
`scripts/validate-app.sh`, `scripts/lib/validate_compose.py`, `scripts/check-app-name.sh`,
`scripts/lab-lock.sh`, `scripts/lib/lock.sh`, `lab-mcp/firewall/**`, `lab-mcp/gateway/**` (le
`Caddyfile` est monté en fichier : une modification partirait au prochain redémarrage),
`lab-mcp/labmcp/auth.py`, `lab-mcp/labmcp/access.py`, `workspace/entrypoint.sh`. Ailleurs dans
`/work/dev` : documentation propre à un service (`README.md`, `API.md` de `lab-mcp/`,
`lab-media/`, `runner/`, `workspace/`), commentaires, et petites corrections de code vérifiées (`bash -n` pour
un script, `py_compile` pour du Python). Pas de nouveau script.

## Pour chaque service
1. **État** (`/entree/contexte/`) : le conteneur tourne-t-il, sain, sans redémarrages ? image et
   version attendues ? Un conteneur absent, en erreur, ou inconnu de la documentation (conteneur
   oublié) est un constat.
2. **Règles de sécurité du `CLAUDE.md`, une par une** — en particulier :
   - tout port publié lié à `127.0.0.1`, sauf `edge-router` (80/443) et l'ICE de `lab-media` (8189) ;
   - `docker.sock` monté seulement par le moteur (et `caddy`, `code-server`, comme documenté) ;
   - `code-server` réservé au groupe `admins` (`OAUTH2_PROXY_ALLOWED_GROUPS`), jamais `developers` ;
     `e2e_member` hors de `admins` ;
   - `pg_hba` sans `trust` réseau ; `CONNECT` retiré à `PUBLIC` ; pgAdmin partagé réservé à `admins` ;
   - un espace de travail ne joint ni l'hôte ni un autre pont Docker sauf 80/443 (règles `-i lws+`) ;
     l'écran de conversation n'a pas de porte à lui (bloc `@chat` avant `@ws`) ;
   - `storage` : aucune route existante ne change, aucun chemin de lecture anonyme, contenu actif
     neutralisé, Bearer seulement ; `KEYCLOAK_TRUSTED_CLIENTS` et `KEYCLOAK_SERVICE_WRITE_SHARES`
     sans joker ; `Share.required_groups` hors self-service ;
   - `oauth-hub` : liste des clients de confiance **en base** (`TrustedClient.is_trusted` : client
     d'oauth-hub autorisé en dur, clients intégrés du realm refusés, aucun cache),
     `_is_safe_return_url`, `client_secret` jamais relisible, chaque remise de jeton journalisée ;
   - `app-builder` : `/api/handoff/` en lecture seule et ouvert à `lab-admin` seulement
     (`KEYCLOAK_HANDOFF_CLIENTS`) ; patchs appliqués par le serveur ; pas de retour des anciens
     générateurs de code ;
   - `lab-admin` : `IsLabAdmin` par défaut, `adminGuard`, `tokenBases()` ;
   - conteneurs auxiliaires sans `.env` (`environment:` seulement), `cap_drop`, `no-new-privileges`,
     images épinglées.
3. **Documentation contre code** : une route, une variable, une commande ou un comportement décrit
   qui n'existe pas (ou l'inverse) ; un « non éprouvé » ou un « à faire » qui est fait.
4. **Fragilités** : point unique de panne, contrôle jamais éprouvé, étape manuelle, version ancienne
   ou non épinglée, erreur relevée par `lab-doctor`. Les propositions déjà listées dans
   `/work/dev/to_do_global.md` (« Propositions nuit 2026-11-08 », § 3 « Services du cadriciel ») ne
   sont pas nouvelles : cite-les et dis si l'état a changé.

## Section propre à la tâche dans le rapport
Après « Ce qui a été relu », ajoute `## État des services` : un tableau service · état relevé ·
règles vérifiées · écart. Puis les « Constats » habituels. Les propositions sont classées P1
(sécurité, perte de données), P2 (fonctionnement), P3 (confort), chacune avec le constat [C]/[D], le
gain, le coût S/M/L, et Ⓟ si elle demande une décision du propriétaire.

## Ce que tu ne fais pas
- Pas de changement de `/work/dev/to_do_global.md`, `README.md` ni `CLAUDE.md` (fichiers de
  l'architecte ; `CLAUDE.md` est en plus un chemin refusé) : ce qu'il faudrait y écrire va dans le
  rapport, ligne exacte comprise.
- Aucune tentative de joindre un service du lab : tu n'y as pas accès et tu ne le cherches pas.
