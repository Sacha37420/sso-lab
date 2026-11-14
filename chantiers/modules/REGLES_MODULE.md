# Ce qu'un module du lab doit fournir — règles v1 (2026-11-14)

Document court, cité par toute app qui s'installe dans le lab (dont la refonte de
`bilan-thermique`). Détail du format : `modules/README.md`. Contrat d'origine :
`chantiers/modules/CONTRAT.md` (I1, I3).

## 1. Une description : `lab-module.json` à la racine du dépôt

- `schema: 1`, `name` = nom du dossier, `label`, `description`, `category: "application"`.
- **Toutes ses dépendances** dans `requires` :
  - `modules` : chaque service du lab qu'elle appelle (`storage` pour tout fichier utilisateur,
    `oauth-hub` pour un jeton GitHub/GitLab/Google, `lab-media` pour un flux…), avec
    `"interface": "1"` quand le module en sert une ;
  - `system` : une commande **de l'hôte** qu'elle exige (rare : ce qui tourne dans un conteneur n'en
    est pas une) ;
  - `domain: true` si elle ne fonctionne qu'en HTTPS.
- `resources` : RAM et durée de build, disque ; `heavy_build: true` si le build est lourd.
- `settings` : chaque **réglage à demander** à l'installation (clé d'API…), avec une `question`
  claire, `required`, `secret`. **Jamais de valeur dans le fichier**, jamais une clé gérée par le lab
  (`DB_*`, `KEYCLOAK_*`, `SECRET_KEY`, `DOMAIN`…). Le lab écrit la réponse dans `.env` et ne la
  réécrit jamais ensuite. Le `.env.example` porte la clé à `CHANGE_ME` (ou vide).
- `groups` : les groupes d'accès (les mêmes que `--require-group`) ; ils doivent exister dans
  l'annuaire, le lab ne les crée pas.

## 2. L'installation dans l'image d'abord

Tout ce qui peut être installé **dans l'image Docker** l'est, par les Dockerfiles : paquets,
bibliothèques, modèles, données de référence téléchargeables au build, migrations et commandes de
gestion au démarrage (`CMD`). C'est la seule voie pour une app de développeur.

## 3. Sinon : `install.sh` et `install.bat` à la racine, déclarés

`"install": {"script": "install.sh", "windows": "install.bat", "timeout_s": 900}` — squelettes dans
`_templates/module/` (posés par `new-app.sh`).

- **Idempotents** : relancés, ils ne refont rien. **`--check`** : ne modifie rien, dit ce qui manque,
  code 1 s'il manque quelque chose. Code ≠ 0 en échec.
- **Sans privilège** : ni `sudo`, ni `apt`, ni écriture hors du dossier du module ; un outil système
  manquant se **déclare** (`requires.system`), le lab le signale.
- **Sans secret** : rien d'écrit dedans ; un réglage manquant se déclare (`settings`).
- Ne modifient **aucun fichier suivi par git** : ils écrivent dans des dossiers ignorés.
- `install.bat` fait la même chose sur un poste Windows ; le lab ne le joue jamais.

## 4. Quand le lab les joue

À **chaque déploiement** (installation, réinstallation depuis lab-admin, `setup2.sh`), par
`scripts/module-hook.sh` : après les contrôles (`validate-app.sh`, portes de qualité), **avant**
tout nettoyage ou build ; dans le dossier du module, environnement vide (`PATH`, `HOME`, `LANG`,
`LAB_ROOT`, `LAB_MODULE`, `LAB_MODULE_DIR`), délai `timeout_s`. Journal :
`══ <app> — script d'installation du module (install.sh)` puis la sortie indentée. Échec ⇒ ligne
`ERROR`, rien n'est arrêté ni construit, la version en service continue.

**App d'un développeur** : le script n'est **pas joué** (v1 — décision du propriétaire attendue) ; le
journal le dit. Tout doit donc passer par l'image.

## 5. Contrôlé par la machine

`validate-app.sh` (portes de qualité, refus `[module]` / `[module-install]`) : description valide si
présente ; scripts déclarés présents, fichiers réguliers, `install.sh` commençant par
`#!/usr/bin/env bash`, les deux traitant `--check`. Vérifier soi-même :
`bash scripts/lab-modules.sh show <app> --check` et `bash scripts/lab-modules.sh plan <app>`.
