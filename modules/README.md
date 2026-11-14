# Modules du lab — description, dépendances, installation

Un **module** est une unité du lab : un dossier avec un `docker-compose.yml` (une app de
`deploiement/`, un service du cadriciel), un sous-module déclaré, ou une entrée de ce catalogue.
Ce dossier `modules/` est le **catalogue central de repli** : une description par module qui n'en
porte pas encore.

| Catégorie | Modules | Installation |
|---|---|---|
| `socle` | `sso-lab`, `infra`, `runner` | toujours, par `scripts/install.sh` (étapes 1 à 9) ; jamais par le moteur |
| `cadriciel` obligatoire | `storage`, `oauth-hub`, `lab-admin`, `lab-mcp` | toujours (étape 10) |
| `cadriciel` facultatif | `app-builder`, `lab-media` | au choix |
| `application` | les apps de `deploiement/` | au choix |

## Où vit la description d'un module

1. `<dossier du module>/lab-module.json` — **portée par le module**, source de vérité quand elle
   existe (toute app née de `new-app.sh` en a une depuis le 2026-11-14) ;
2. sinon `modules/<nom>.json` — ce catalogue ;
3. sinon une description **déduite** : nom, libellé de `.app-descriptions`, groupes de
   `.keycloak-client-opts`, poids de `scripts/app-priorities.conf`, **aucune dépendance**, aucun
   réglage, aucun script d'installation.

Le premier présent gagne **en entier** (aucune fusion). Une description présente mais invalide met
le module à l'état « description invalide » : pas de repli silencieux, et un déploiement le refuse.

## Format (schéma 1)

```json
{
  "schema": 1,
  "name": "peripheriques",
  "label": "Périphériques",
  "description": "Caméra, micro et haut-parleur de l'hôte en direct et en relecture.",
  "category": "application",
  "required": false,
  "priority": 50,
  "provides": { "interface": "1" },
  "requires": {
    "modules": [ { "name": "lab-media", "interface": "1" } ],
    "system":  [ { "command": "ffmpeg", "min_version": "6.0", "why": "conversion des enregistrements" } ],
    "domain": false
  },
  "resources": { "build_ram_mb": 1500, "disk_mb": 2000, "build_minutes": 6, "heavy_build": false },
  "settings": [
    { "key": "PERIPHERIQUES_BRIDGE_KEY", "question": "Clé du pont vers google-agenda (vide : pont fermé)",
      "required": false, "secret": true }
  ],
  "groups": ["developers", "admins", "famille"],
  "install": { "script": "install.sh", "windows": "install.bat", "timeout_s": 900 }
}
```

| Champ | Sens |
|---|---|
| `name` | nom du dossier, obligatoire |
| `label`, `description` | ce qu'affichent `install.sh` et la page « Modules » de lab-admin |
| `category`, `required` | voir le tableau ci-dessus ; `required` est fixé par le lab (la liste fait foi) |
| `priority` | départage l'ordre entre modules indépendants (petit = tôt). Défaut : `scripts/app-priorities.conf`, sinon 50 |
| `provides.interface` | version d'interface que ce module sert à d'autres (`storage` : `"1"`) |
| `requires.modules` | dépendances ; `interface` facultatif : une version majeure différente bloque l'installation |
| `requires.system` | commandes de l'**hôte** nécessaires (vérifiées, jamais installées par le lab) ; `min_version` lue sur `<commande> --version` |
| `requires.domain` | exige `DOMAIN` (HTTPS) — `lab-mcp` |
| `resources` | indicatif : RAM et durée de build, disque ; `heavy_build` = build lourd (voir `.heavy-build`) |
| `settings` | réglages **demandés** à l'installation et écrits dans le `.env` du module ; jamais une clé gérée par le cadriciel (`DB_*`, `KEYCLOAK_*`, `SECRET_KEY`…, liste de `scripts/app-env.sh`) ; **aucune valeur** dans le fichier |
| `groups` | groupes LDAP d'accès (informatif ; `.keycloak-client-opts` fait foi pour le cloisonnement). Vérifiés, jamais créés : un groupe naît dans l'annuaire |
| `install` | `null`, ou les deux scripts à la racine du module (noms fixes) et le délai |

Le socle est une dépendance implicite de tout module. Clés inconnues refusées.

## Commandes

```bash
bash scripts/lab-modules.sh list                      # catalogue et état
bash scripts/lab-modules.sh show <nom> --check        # prérequis, réglages, dépendances, groupes, install.sh --check
bash scripts/lab-modules.sh plan <nom>[,<nom>…]       # ce qu'une installation ferait, dans quel ordre
bash scripts/lab-modules.sh plan --reinstall --with-deps <nom>
bash scripts/lab-modules.sh selection                 # sélection mémorisée (.lab-state/modules/selection.json)
bash scripts/install.sh --modules <nom>[,…]           # installer un module et ses dépendances (sur l'hôte)
bash scripts/setup2.sh <nom> --yes                    # relancer l'installation d'un module installé
```

Depuis lab-admin : page **Modules** (superutilisateur) — plan affiché avant confirmation, réglages
saisis une fois, suivi du job. Le moteur passe par le chemin de déploiement standard (commit présent
sur GitHub, portes, tests) et ne se réinstalle jamais lui-même.

## Scripts d'installation d'un module

Règles complètes : `chantiers/modules/REGLES_MODULE.md` et les règles servies aux IA
(`_templates/regles/CLAUDE.md`, section « Module »). En bref : ce qui peut aller dans l'image va dans
le Dockerfile ; sinon `install.sh` (et `install.bat`, pour un poste Windows) à la racine, déclarés
par `install`, idempotents, avec `--check`, sans `sudo` ni secret. Le lab joue `install.sh` **à l'installation
seulement** (premier lancement, ou module absent du serveur), après les contrôles et avant le build
(`scripts/module-hook.sh --if-new`) ; une mise à jour par `setup2.sh` ne le rejoue pas ; jamais pour
l'app d'un développeur (décision P1 du 2026-11-14).

## Ajouter un module au catalogue

Une app existante sans `lab-module.json` : ajouter `modules/<nom>.json` ici, puis
`bash scripts/tests/modules/run.sh` (vérifie que tout le catalogue est valide, sans cycle ni
dépendance inconnue). Mieux : poser `lab-module.json` dans le dépôt de l'app — il prime.
