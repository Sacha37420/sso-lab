# Relectures de nuit — `automatisation/`

Claude Code relit le lab chaque nuit, **sans intervention humaine** : deux apps par nuit en
semaine (sécurité les lundi, mercredi, vendredi ; validité métier et interface les mardi et
jeudi), `lab-admin` et le gabarit le samedi, les services du cadriciel le dimanche. Chaque
passage produit un rapport (email) et, si les tests sont verts, une PR par dépôt. **Rien n'est
déployé ; la fusion reste humaine**, le déploiement reste le bouton « Déployer ».

Contrat : `chantiers/nuit-auto/CONTRAT.md` (v1). Quel prompt à quel moment :
`calendrier.conf` et `prompts/` (secteur « prompts »).

## Ce qu'il faut faire une fois (gestes humains)

1. **Jeton Claude** — sur l'hôte, `claude setup-token` (abonnement Claude), puis :
   ```bash
   install -d -m 700 .lab-state/auto
   ( umask 077; printf '%s\n' '<jeton affiché>' > .lab-state/auto/claude-token )
   ```
2. **Jeton GitHub à portée fine** — github.com → Settings → Developer settings → *Fine-grained
   tokens* : propriétaire `Sacha37420`, accès aux dépôts des apps du superutilisateur et à
   `sso-lab` ; permissions **Contents : Read and write**, **Pull requests : Read and write**,
   rien d'autre (surtout pas *Administration*). Puis :
   ```bash
   ( umask 077; printf '%s\n' 'github_pat_…' > .lab-state/auto/github-token )
   ```
   Il n'est utilisé que par l'hôte (clone, push, création de PR), jamais transmis à Claude.
   Le `gh` de l'hôte (portée `delete_repo`) n'est jamais utilisé.
3. **Vérifier** : `bash automatisation/bin/auto.sh verifier` doit conclure « Rien ne peut
   attendre l'utilisateur ». Chaque ligne `✘ [point]` dit ce qui bloque.
4. **Un essai réel** (6 tours de Claude, ni push, ni PR, ni email) :
   `bash automatisation/bin/auto.sh lancer --tache securite --essai`, puis
   `bash automatisation/bin/auto.sh etat`.
5. **Planifier** : `bash automatisation/bin/auto.sh planifier --check` (ne fait rien), puis
   `bash automatisation/bin/auto.sh planifier`. Deux lignes dans la crontab de l'utilisateur
   (cron, pas systemd : `Linger=no`), aucune autre ligne touchée ; `--retirer` les enlève.

## Commandes

| Commande | Rôle |
|---|---|
| `auto.sh lancer [--date AAAA-MM-JJ] [--tache T] [--essai]` | Passage de 0 h (tâche du jour d'après `calendrier.conf`). S'arrête de lui-même à 5 h 00 (`limite`) |
| `auto.sh rattraper` | 5 h 10 : reprend le passage de la nuit si son statut n'est pas `fini` (session reprise par `--resume`), ou le lance s'il n'a pas eu lieu (`manque`) ; s'arrête à 8 h 00 |
| `auto.sh verifier` | Contrôle tout ce qui pourrait faire attendre l'utilisateur ; code 0 = rien |
| `auto.sh etat [--json]` | Derniers passages : statut, phase, PR |
| `auto.sh planifier [--retirer] [--check]` | Crontab |

## Ce que fait un passage

1. Choisit les cibles (`rotation:N` : les N apps suivantes de la rotation propre à la tâche,
   `.lab-state/auto/rotation-<tache>` ; ou la liste fixe). Rotation = apps du superutilisateur
   qui ont leur propre dépôt GitHub (`lab-mcp`, `lab-media`, sans dépôt propre, n'y sont pas).
2. Clone chaque cible deux fois depuis GitHub, au même commit : `work/<cible>` (monté pour
   Claude) et `propre/<cible>` (**jamais monté**).
3. Lance Claude dans `lab-workspace` (I3) : réseau dédié `lws…` derrière le pare-feu des espaces,
   sans étiquette `lab.ws`, `--cap-drop ALL`, 2 Go, 1 CPU, uid 1000 ; montages `/work/<cible>`
   (son `.git` en lecture seule), `/entree` (lecture seule : `mission.md`, contexte), `/sortie`,
   `/home/coder` (`~/lab-work/auto/home`, pour `--resume`). Seul secret transmis :
   `CLAUDE_CODE_OAUTH_TOKEN`, par l'environnement du client docker. Phase 2 (`<tache>-suite.md`)
   si `resume.json` dit `"charge": "faible"`.
4. Pour chaque cible : correctif calculé **dans un conteneur sans réseau** (le clone de travail
   y est en lecture seule ; `__pycache__`, `*.pyc`, `node_modules`, `.venv` ignorés), appliqué
   par `git apply` sur le clone propre, puis **rejeté en entier** s'il touche un chemin refusé
   (I3 : `.github/`, `.env*`, `Dockerfile*`, `docker-compose*.yml`, `nginx*.conf`, liens,
   > 1 Mo, et pour le dépôt racine `sso-lab/`, `infra/`, `.claude/`, `CLAUDE.md`) ou s'il
   contient un secret du lab.
5. `validate-app.sh --quality-only` sur l'arbre corrigé (ce que `setup_unit.sh` joue pour une
   app du superutilisateur), puis tests backend sous `scripts/lab-lock.sh` : commande de la
   feuille de route **du commit de base**, PostgreSQL jetable sur réseau `--internal`, `.env`
   **assaini** ; image en service, ou `<image>:auto` reconstruite si un `requirements*.txt` a
   changé (jamais pour une app à `.heavy-build` : rapport seul) ; frontend modifié ⇒
   `npm ci && npx ng build`. Dépôt racine : contrôle de syntaxe des fichiers modifiés.
6. Rouge ⇒ une phase `_correction` (avec `/entree/tests.txt`), puis on reteste ; encore rouge ⇒
   rapport seul. Vert ⇒ commit, branche `auto/<date>-<tache>`, push, PR (brouillon si un constat
   `critique` reste non corrigé).
7. Email du rapport (SMTP de `sso-lab/.env`, à `LAB_BACKUP_EMAIL` ou `SMTP_FROM`).

## Où lire

- `.lab-state/auto/runs/<date>-<tache>/` : `etat.json`, `journal.txt` (filtré : aucun secret),
  `tests/<cible>/` (sorties des tests, refus), `sortie/` (ce que Claude a écrit),
  `rapport-publie.md` (rapport filtré, tel que publié).
- `~/lab-work/auto/travail/<passage>/` : clones, supprimés quand le passage est fini (ou après 7 jours).

## Statuts (`etat.json`)

`en_cours` · `fini` · `limite` (fin d'heure, limite d'usage) · `echec` (le moteur n'a pas pu :
clone, docker, verrou de déploiement occupé au-delà de 30 min) · `refuse` (un correctif rejeté :
le rattrapage reprend la session pour le corriger) · `manque` (pas de passage à 0 h).

## Essais

`bash automatisation/tests/run.sh` (≈ 10 min ; `unitaires` : sans conteneur). Faux Claude
(`tests/faux-claude`, scénario choisi par le jeton), faux GitHub sur 127.0.0.1, dépôts nus
locaux, faux lab ; vrais Docker, pare-feu (préfixe d'essai `lwtq`, retiré à la fin),
`validate-app.sh`, `lab-lock.sh`, PostgreSQL jetable. Tout est nettoyé.

Réglages surchargeables (essais) : `AUTO_LAB_ROOT`, `AUTO_DIR_PROMPTS`, `AUTO_CALENDRIER`,
`AUTO_IMAGE`, `AUTO_BRIDGE_PREFIX`, `AUTO_REMOTE_BASE`, `AUTO_GITHUB_API`, `AUTO_EMAIL_DIR`,
`AUTO_CRONTAB_FILE`, `AUTO_FIN`, `AUTO_FIN_RATTRAPAGE`, `AUTO_MODEL`… (en tête de `lib/commun.sh`).
