---
name: chantier
description: Protocole d'orchestration à 3 strates pour les travaux lourds du lab (architecte → chefs de secteur → codeurs), avec contrat d'interface figé, escalade d'amendement et redescente aux secteurs impactés. À invoquer avant tout chantier touchant plusieurs apps/sous-modules, ou toute refonte transverse (modèle de données partagé, sécurité, infra, UI lab-wide). Ne pas l'utiliser pour un lot isolé dans une seule app.
---

# Chantier — orchestration à 3 strates

## Quand l'appliquer, quand s'en abstenir

**Appliquer** dès qu'un travail remplit **au moins deux** de ces conditions :
- il touche ≥ 3 sous-modules / dossiers racine distincts ;
- il crée ou modifie une **interface consommée par plusieurs parties** (schéma de données partagé,
  endpoint appelé par d'autres apps, clé `.env` lue ailleurs, format de fichier, événement) ;
- il dépasse une session de travail confortable (> ~2 h d'exécution estimée) ;
- il touche la sécurité du cloisonnement, `storage`, `infra/` ou `sso-lab/`.

**Ne pas appliquer** pour un lot isolé dans une seule app (`to_do_<app>.md`, un `Lot N`) : le
cadrage coûte alors plus cher qu'il ne rapporte. Travailler linéairement, c'est le bon mode là.

**Règle de découpe — un secteur n'est valide que si les trois sont vrais :**
1. son **périmètre de fichiers est disjoint** de celui des autres secteurs ;
2. il ne parle aux autres **que par une interface écrite dans le CONTRAT** ;
3. il est **testable seul**, sans attendre les autres.

Un candidat qui échoue à l'un des trois n'est pas un secteur : le fusionner avec son voisin.
Sur-paralléliser coûte plus cher que ne pas paralléliser — deux secteurs qui s'écrivent
mutuellement dessus produisent des conflits et du travail à refaire.

---

## Les trois strates

| Strate | Qui | Ce qu'il fait | Ce qu'il ne fait JAMAIS |
|---|---|---|---|
| **S1 — Architecte** | la session principale (avec l'utilisateur) | découpe en secteurs, **écrit et possède le CONTRAT**, arbitre les amendements, intègre, séquence les déploiements | coder dans un secteur ; déléguer l'arbitrage d'interface |
| **S2 — Chef de secteur** | 1 subagent par secteur, lancés en parallèle | découpe son secteur en tâches, lance ses S3, intègre et teste **son** secteur, rapporte | sortir de son périmètre ; trancher une question d'interface ; toucher un fichier partagé |
| **S3 — Codeur** | subagents lancés par S2 | une tâche fermée, un livrable, ses tests | décider d'un contrat ; élargir son périmètre |

> **Règle d'or : une strate ne tranche jamais une question qui appartient à la strate du dessus.**
> C'est la seule chose qui empêche l'arbre de diverger. Un S3 qui bute sur une interface remonte à
> son S2 ; un S2 qui bute sur une interface remonte à S1 **sans deviner** — voir « Escalade ».

---

## Phase 0 — Cadrage (S1 seul, **avant** de lancer le moindre subagent)

Produire `chantiers/<nom>/CONTRAT.md` à partir de
`.claude/skills/chantier/templates/CONTRAT.md`. **Tant que ce fichier n'existe pas, aucun subagent
n'est lancé.** Un subagent lancé sans contrat écrit devine — et du code écrit sur une interface
devinée compile, passe ses propres tests, et casse à l'intégration : le mode d'échec le plus cher
du parallélisme, et le plus tardif à apparaître.

Le cadrage comporte obligatoirement :

1. **Objectif en formulation d'origine** — recopier les mots de l'utilisateur, à respecter à la
   lettre. Ne pas les reformuler « proprement » : la reformulation est déjà une décision.
2. **Constat vérifié** — l'état réel du code au moment de la rédaction, vérifié (pas supposé), avec
   les commandes/fichiers qui l'établissent. Les S2 le revérifient rapidement au démarrage.
3. **Carte des secteurs** — nom, périmètre = liste explicite de chemins, propriétaire exclusif.
4. **Interfaces figées** — pour chaque paire de secteurs qui se parlent : schéma de données exact,
   signature d'endpoint, nom de clé `.env`, convention de nommage. **Versionné `v1`, `v2`…**
5. **Fichiers partagés** — la liste de ce que **seul S1** édite (voir « Propriété exclusive »).
6. **Ressources sérialisées** — ce qui ne tolère jamais deux exécutions concurrentes.
7. **Critère d'acceptation par secteur** — comment on sait que ce secteur est fini.

Si un point de design est réellement ambigu ou risqué : **le poser à l'utilisateur maintenant**,
pas le déléguer à un S2. Une ambiguïté descendue dans l'arbre remonte multipliée par le nombre de
secteurs qui l'ont tranchée différemment.

---

## Phase 1 — Fondation (fréquente, pas obligatoire)

Quand un secteur **produit** l'interface que les autres **consomment** (typiquement `storage/`,
`infra/`, `_templates/`), deux options :

- **Séquentiel** — la fondation d'abord, seule, puis les autres. À choisir si l'interface est encore
  en discussion.
- **Parallèle avec dépendance documentée** — tout le monde démarre en même temps, les consommateurs
  codent contre le CONTRAT et **documentent explicitement le point où ils dépendent d'un livrable
  fondation non encore déployé** (ex. « le câblage `<img src>` attend le fallback `?token=` »). À
  choisir si le contrat est net.

> **On ne parallélise jamais sur du code pas encore écrit — on parallélise sur un contrat écrit.**
> C'est la distinction qui décide entre les deux options ci-dessus.

---

## Phase 2 — Exécution parallèle

S1 lance **tous les S2 dans un seul message** (sinon ils s'exécutent en série). Le prompt de chaque
S2 est monté depuis `.claude/skills/chantier/references/prompts.md` — il doit contenir, sans
exception : le chemin du CONTRAT **et sa version**, le périmètre exclusif, l'interdiction d'en
sortir, les fichiers partagés interdits, le format de rapport, et le protocole d'escalade.

### Propriété exclusive des fichiers partagés

Un fichier lu ou écrit par plusieurs secteurs appartient à **S1 seul**. Un S2 qui a besoin d'une
modification dedans **rapporte la ligne exacte à ajouter** ; S1 applique tout en un seul edit
groupé à l'intégration. Dans ce dépôt, sont toujours propriété de S1 :

`CLAUDE.md` · `README.md` · `.ports` · `.gitignore` · `.app-descriptions` · `infra/**` ·
`sso-lab/**` · `runner/**` · `scripts/**` · le `.env` de toute app **autre** que celle du secteur ·
`~/edge-router/` (hors dépôt, jamais en autonomie — voir CLAUDE.md).

### Ressources sérialisées (2 vCPU / 16 Go)

Jamais deux en parallèle, quelle que soit la strate : build Docker lourd (`.heavy-build`),
`setup2.sh` / `recompose_docker.sh`, migration de base, exécution Playwright (`lab-runner` a déjà
un mutex lab-wide et répond 409). **Les S2 ne déploient pas eux-mêmes** : ils rapportent la commande,
S1 séquence.

### Isolation git

Ne **pas** utiliser `isolation: "worktree"` par défaut ici : un agent en worktree ne voit que le
HEAD **commité**, jamais les modifications en cours de la session. Le découpage par sous-module est
déjà une isolation suffisante et sans ce piège. Réserver le worktree au cas où plusieurs secteurs
doivent réellement écrire dans les **mêmes** fichiers — ce qui, d'après la règle de découpe, ne
devrait pas arriver.

---

## Escalade — la remontée d'alerte et la redescente

Trois statuts de retour possibles pour un S2. **Un seul veut dire « j'ai fini ».**

| Statut | Sens | Ce que fait le S2 |
|---|---|---|
| `OK` | livré, tests réels passés | rapporte (template `RAPPORT.md`) |
| `AMENDEMENT` | le contrat d'interface ne tient pas | **s'arrête immédiatement**, écrit `chantiers/<nom>/amendements/<secteur>-NN.md`, rend la main |
| `BLOQUÉ` | ambiguïté métier, risque sécurité, dépendance externe | même forme, pas d'improvisation |

**Interdit explicitement à un S2 :** implémenter un contournement, « faire au mieux », ou adapter
l'interface de son côté seulement. Un secteur qui s'auto-dépanne casse silencieusement les autres —
et l'échec n'apparaît qu'à l'intégration, quand tout est déjà écrit.

Un amendement contient : l'interface concernée + sa version, ce qui ne marche pas (constaté, pas
supposé), **2-3 options avec leur conséquence pour chaque autre secteur**, et l'option préférée du
S2 avec sa raison.

### La redescente (S1)

1. Arbitrer — trancher, ou remonter la question à l'utilisateur si elle est structurante.
2. **Éditer le CONTRAT et bumper la version** (`v1` → `v2`), avec une ligne de journal disant ce
   qui change et pour qui.
3. **`SendMessage`** — pas un nouvel `Agent` : `SendMessage` reprend l'agent avec son contexte
   intact, un nouvel `Agent` repartirait de zéro.
   - vers le S2 demandeur : « amendement accepté/refusé, voici v2, reprends » ;
   - **et vers tout S2 dont le périmètre touche l'interface modifiée — même s'il n'a rien demandé,
     même s'il a déjà rendu `OK`.** C'est l'étape qu'on oublie systématiquement, et la seule raison
     pour laquelle l'arbitrage sert à quelque chose.

### Garde-fou de version (mécanique, pas déclaratif)

Chaque rapport de S2 **porte en première ligne la version du contrat sur laquelle il a travaillé**.
À l'intégration, S1 compare : un rapport `OK` estampillé `v1` alors que le contrat est en `v2` est
**périmé** — revalidation par `SendMessage` obligatoire avant de l'intégrer. Sans ce contrôle, un
travail fait sur une interface morte s'intègre sans que rien ne le signale.

---

## Phase 3 — Intégration (S1 seul)

Dans cet ordre :

1. Vérifier la **version** de chaque rapport (garde-fou ci-dessus).
2. Appliquer **en un seul edit groupé** toutes les modifications de fichiers partagés rapportées.
3. Séquencer les déploiements (jamais deux builds lourds ensemble), un par un.
4. **Test transverse**, pas seulement les tests de secteur : le cloisonnement (`lab-runner`,
   `POST /run` — une réponse `[]` veut dire « aucun test trouvé », jamais « tout va bien »), et un
   parcours réel de bout en bout traversant au moins deux secteurs.
5. Mettre à jour `CLAUDE.md` (décisions tranchées, pièges découverts), la mémoire, le `to_do`.
6. Archiver `chantiers/<nom>/` ou le supprimer une fois le chantier absorbé dans `CLAUDE.md`.

---

## Strate 3 — ce que S2 fait de ses codeurs

S2 applique le même protocole en petit :
- une tâche fermée par S3, périmètre de fichiers disjoint à l'intérieur du secteur, critère de test ;
- **le premier exemplaire d'une famille n'est jamais parallélisé** : il sert de patron. On ne
  parallélise les suivants qu'une fois son schéma validé (c'est déjà la note « ⚡ Parallélisable
  via subagent » de `to_do_craft_lab.md`, Lot 11 — gabarit Bipède d'abord, les 3 autres ensuite) ;
- un S3 qui bloque remonte à S2 ; si c'est une question d'interface, **S2 la relaie à S1 sans la
  trancher**.

---

## Checklist S1

- [ ] `chantiers/<nom>/CONTRAT.md` écrit, interfaces figées et **versionnées**, avant tout subagent
- [ ] Chaque secteur passe le test à 3 critères (disjoint / interface écrite / testable seul)
- [ ] Fichiers partagés listés comme propriété exclusive de S1
- [ ] Tous les S2 lancés **dans un seul message**
- [ ] Chaque prompt S2 contient version du contrat + périmètre + protocole d'escalade + format de rapport
- [ ] Amendement reçu → contrat bumpé → `SendMessage` au demandeur **et aux secteurs impactés**
- [ ] Versions des rapports vérifiées avant intégration
- [ ] Déploiements séquencés, test transverse lancé
- [ ] `CLAUDE.md` / mémoire mis à jour avec ce que le chantier a appris
