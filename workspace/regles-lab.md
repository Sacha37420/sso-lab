# Règles du lab — à suivre pour tout travail dans cet espace

Tu travailles dans l'espace de travail d'**un** projet du lab (`/work/<projet>`), pour son
développeur. Ces règles s'imposent à toute IA comme à tout humain. Les règles propres au projet
(`CLAUDE.md` / `AGENTS.md` à sa racine) les complètent ; en cas de doute, la plus stricte gagne.

## Méthode — lot par lot, feuille de route d'abord

1. **Lis `FEUILLE_DE_ROUTE.md`** à la racine du projet avant toute chose.
   S'il y a un `CAHIER_DES_CHARGES.md` (projet lancé depuis une spécification App Builder), lis-le
   aussi : il dit ce que l'app doit faire, les lots en découlent.
2. **Écris ou complète le lot avant de coder** : objectif, tâches, et les **tests nommés** à passer
   pour le clore. Pas de lot dans la feuille de route ⇒ pas de code.
3. **Un seul lot à la fois.** Passe-le « en cours », termine-le, puis seulement le suivant.
4. **Ne clos jamais un lot sans avoir lancé ses tests.** Note sous « Vérifié le » la date et ce
   qui a été **réellement** lancé, avec son résultat. « Devrait marcher » n'est pas une vérification.
5. **Un lot livré = un commit poussé** sur GitHub (`git push`). Ce qui n'est pas poussé n'existe pas.
6. Respecte le format de la feuille de route à la lettre : une machine le relit, et un déploiement
   est refusé s'il est absent ou mal formé.

## Déployer — par le moteur du lab, jamais autrement

- Le serveur MCP **`lab`** est déjà déclaré. Outils disponibles pour ce projet : `whoami`,
  `status`, `logs`, `env_list` / `env_get` / `env_set` / `env_unset`, `deploy`, `run_tests`, `job_status`,
  `sql` (ta base, schéma de ce projet), `smtp_status` (quel compte d'envoi d'email est rattaché),
  `preview_deploy` / `preview_status` / `preview_stop` (l'adresse d'essai, voir plus bas).
- **Pousse, puis appelle `deploy`.** Seul un commit présent sur GitHub est déployable. Suis le
  job avec `job_status` jusqu'au bout et lis le résultat des tests.
- Les tests backend passent **avant** la mise en service : s'ils sont rouges, rien n'est déployé.
  Corrige le code ou le test, ne contourne pas.
- Après un déploiement, lance `run_tests` (cloisonnement) et lis le résultat. Une liste vide
  veut dire « aucun test trouvé », jamais « tout va bien ».
- Il n'y a **ni Docker, ni `sudo`, ni accès à l'hôte** ici, et il n'y en aura pas : ne cherche
  pas à les obtenir. Ce qui ne passe pas par le moteur ne se fait pas depuis cet espace.
- Un problème du lab lui-même (pas du projet) : ouvre un ticket depuis `lab-admin`, ne bricole pas.

## Essayer avant de pousser — l'adresse d'essai

- Chaque développeur a **une** adresse d'essai, `https://<domaine>/dev-<uid>/` (API :
  `/dev-<uid>-api/`). Elle sert le dossier de travail **tel qu'il est, non commité compris**.
- Pour la construire : l'outil MCP **`preview_deploy`** (puis `job_status` jusqu'au bout), ou la
  commande **`lab-essai`** dans le terminal, ou dans l'éditeur la tâche « Lab : construire
  l'essai » (Ctrl+Maj+B). `preview_status` / `lab-essai status` disent ce que l'adresse montre ;
  `preview_stop` / `lab-essai stop` l'arrêtent. Rien ne la construit tout seul : seulement sur demande.
- **L'essai ne remplace pas le déploiement.** Il ne passe aucun test et n'est pas la version en
  service : un lot n'est livré que par un commit poussé, `deploy`, et ses tests verts.
- **L'essai a sa propre base** (un schéma à part, vide au départ), jamais les données en service :
  crée-y les données dont tu as besoin, n'attends pas d'y retrouver celles de l'app.
- Une seule adresse par développeur : construire l'essai d'un autre projet remplace le précédent.
  Elle est réservée aux groupes requis du projet, et démontée d'office après quelques heures.
- Un essai refusé l'est pour une raison affichée (contrôle de sûreté, build) : corrige-la, ne la
  contourne pas. L'essai ne publie aucun port et n'envoie aucun email.

## Règles qui s'imposent à toute app du lab

- **Cloisonnement à deux verrous, les deux obligatoires.** Ne retire jamais `--require-group`, ni
  le contrôle de `azp` et du claim `groups` dans `api/authentication.py`. Garde
  `frontend/e2e/cloisonnement.spec.ts` tel quel : il est copiable sans adaptation, n'y mets rien
  de propre à l'app.
- **Fichiers des utilisateurs : par l'API `storage`**, jamais dans un volume privé ni en base.
- **Identité « Foyer »** : aucune couleur en dur (tokens CSS seulement), navigation verticale,
  rupture à 900 px, cibles tactiles d'au moins 44 px, polices auto-hébergées.
- **Aucun secret dans le dépôt** : ni `.env`, ni jeton, ni mot de passe, ni clé. Une variable
  propre à l'app se pose avec `env_set`.
- Ne touche pas aux variables gérées par le lab (`DB_*`, `POSTGIS_*`, `KEYCLOAK_*`, `SECRET_KEY`,
  `DOMAIN`, `LAB_*`) : elles sont refusées.

## Secrets de cet espace

- Les jetons de l'espace (`LAB_MCP_TOKEN`, `GH_TOKEN`) sont dans l'environnement. **Ne les
  affiche pas, ne les écris dans aucun fichier, ne les mets dans aucun commit ni aucun ticket.**
- `git push` et `gh` fonctionnent sans réglage : n'enregistre aucun identifiant sur disque.

## Quand tu doutes

Arrête-toi et demande au développeur. Ne devine pas une règle, ne contourne pas un refus.
