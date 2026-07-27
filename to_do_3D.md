# MISSION — Atelier 3D : photos/vidéo → objet 3D, analyse cinématique, impression, sémantique bâtiment, conception CAO manuelle

Application du lab en 5 modules. **Les Lots 1 à 4 sont livrés** (Reconstruction,
Impression, Mouvements, Bâtiments) — la section « Architecture actuelle » ci-dessous
en décrit l'état réel, pas un plan à exécuter. **Le Lot 5 (Conception CAO manuelle)**
est en cours de cadrage (2026-07-26) : c'est la seule partie de ce document qui reste
un cahier des charges à construire, et le point central de ce cadrage est de
**s'intégrer** dans l'architecture existante plutôt que de vivre à côté.

Ce document reste exécutable sans dépendre d'un autre : toute tâche qui semble sortir
des contraintes listées est un signal pour s'arrêter et clarifier plutôt que
d'improviser.

---

## Contraintes fondamentales (toujours valables, y compris pour le Lot 5)

- **Serveur du lab : 2 vCPU, 16 Go RAM, aucun GPU.** CPU-only partout. Ne jamais
  introduire de dépendance CUDA — si une tâche semble l'exiger, s'arrêter et remonter
  le problème plutôt que d'improviser un fallback.
- **100 % local, pas de burst cloud.** Aucun calcul externalisé.
- **Un seul job « lourd » actif à la fois pour toute l'app** (verrou global), tous
  modules confondus — implémenté par `--concurrency=1` sur le worker Celery
  (`docker-compose.yml`, filet de sécurité) + un verrou applicatif réel en base
  (`select_for_update()` sur `Job` dans une transaction atomique, posé côté vue avant
  `Job.objects.create()` — voir `ReconstructionLaunchView`/`RepairLaunchView`/
  `FacadeLaunchView`), pas un lock Redis séparé.
- **Aucun job ne se déclenche automatiquement à l'upload/à la création.** L'utilisateur
  lance explicitement chaque étape lourde.
- Le module Impression n'a jamais réimplémenté de slicer (Cura/PrusaSlicer existants) ;
  même logique de non-réinvention appliquée au Lot 5 (voir plus bas : noyau
  géométrique, solveur d'assemblage, génération de denture — tous réutilisent une
  bibliothèque existante plutôt qu'une réimplémentation maison).
- Le module Mouvements ne résout jamais automatiquement des mécanismes à liaisons
  couplées — l'édition manuelle reste l'outil principal.
- Le module Bâtiments ne s'appuie sur aucun modèle pré-entraîné spécifique façades.

## HORS PÉRIMÈTRE

- NeRF, 3D Gaussian Splatting, tout pipeline nécessitant CUDA.
- Slicing / génération de G-code.
- Résolution automatique de mécanismes à liaisons couplées entre plusieurs jointures.
- Entraînement d'un modèle de segmentation sémantique façades.
- Calcul cloud/GPU loué à la demande.
- Éditeur de sketch 2D interactif (dessin souris, accroche, contraintes géométriques 2D
  résolues en direct) — Lot 5, reporté (voir décisions actées).
- Arbre paramétrique éditable façon FreeCAD PartDesign (retouche d'une opération
  ancienne avec propagation incrémentale intelligente) — Lot 5, réévaluation complète
  à chaque édition en V1 (voir limites connues).

---

## Architecture actuelle (Lots 1 à 4 — livrés, référence pour intégrer le Lot 5)

Stack : Django + Angular (scaffold `new-app.sh` type 4), Celery + Redis pour les jobs
lourds, PostgreSQL `postgres` partagée, volume Docker `external: true` dédié pour les
fichiers (photos, maillages), viewer three.js (`OrbitControls`, `GLTFLoader`,
`STLLoader`) côté frontend. Format pivot interne : PLY (attributs par face/sommet) +
export glTF (viewer) / STL / 3MF (impression).

**Modèle de données actuel** (`backend/api/models.py`) :

```
Project    (nom, description, project_type: objet|bâtiment, scale_meters_per_unit,
            owner_email)
Photo      (project FK, fichier, ordre, pose caméra JSON, cache segmentation 2D)
Job        (project FK, kind, status PENDING|RUNNING|DONE|ERROR, progress, message,
            params, celery_task_id, owner_email) — kinds réellement exécutés par une
            tâche Celery : RECONSTRUCTION, REPAIR, SEGMENTATION_FACADE. SEGMENTATION_PARTS
            existe comme choix mais n'est jamais créé : la suggestion RANSAC de Part
            (module Mouvements) tourne en synchrone dans la vue (pure géométrie, quelques
            centaines de ms) — ni tâche Celery, ni verrou global, cf. `PartSuggestView`
Mesh       (project FK, job FK d'origine, fichier PLY, gltf_file, version,
            vertex_count, face_count, is_watertight, repair_report)
             — chaque étape lourde produit une nouvelle version plutôt que d'écraser
Part       (mesh FK, face_ids JSON, nom, color, suggested, primitive_type/params)
             — module Mouvements : un sous-ensemble de faces d'un Mesh
Joint      (parent_part FK, child_part FK, joint_type revolute|prismatic|fixed,
            axis_origin, axis_direction, limit_min/max)  — module Mouvements
PhotoLabel (photo FK, semantic_class, region_index)       — module Bâtiments
SemanticClass (mesh FK, nom, color, face_ids JSON)        — module Bâtiments
```

**Pipeline** : un `Project` reçoit des `Photo` → `Job(RECONSTRUCTION)` produit le
premier `Mesh` (COLMAP + OpenMVS) → `Job(REPAIR)` produit une version réparée
(`repair.py`, watertight + repli Poisson via `pymeshlab` — `open3d` abandonné, wheels
AVX2-only incompatibles avec le CPU cible) → `Part`/`Joint` posés manuellement sur un
`Mesh` pour définir un arbre cinématique (`mouvements`, suggestion RANSAC en fond) →
`Job(SEGMENTATION_FACADE)` (réutilise les poses caméra du `Job(RECONSTRUCTION)`,
segmentation zero-shot FastSAM + propagation multi-vue) produit un nouveau `Mesh`
avec des `SemanticClass`.

**Point clé pour le Lot 5** : Impression, Mouvements et Bâtiments (`repair.py`,
Part/Joint, `facade.py`) sont tous écrits contre `Project`/`Mesh` **génériquement** —
aucun ne suppose que le `Mesh` vient d'une reconstruction. Historique détaillé (bugs
corrigés, mesures réelles) dans les mémoires `atelier-3d-lot{2,3,4}-*` — pas répété ici.

---

## Lot 5 — Conception CAO manuelle : intégration dans l'architecture existante

### Principe d'intégration (le point central de ce cadrage)

La conception CAO **n'est pas un module à part** avec ses propres tables `CadPart`/
`CadMesh` isolées — c'est **une deuxième façon de peupler `Mesh` sur un `Project`**,
en parallèle de la Reconstruction (Lot 1) :

- **Un `Project` sans photos**, dont l'historique d'opérations CAO (`CadOperation`,
  voir plus bas) est évalué par un nouveau `Job(kind=CAD_BUILD)` → produit un `Mesh`
  exactement comme `Job(RECONSTRUCTION)` le fait aujourd'hui (même modèle, même
  versionnage, mêmes champs `gltf_file`/`vertex_count`/`face_count`).
- **Un assemblage est lui-même un `Project`** (nouveau choix `project_type=ASSEMBLY`),
  dont les instances/contraintes (`CadAssemblyInstance`/`CadAssemblyConstraint`, voir
  plus bas) sont résolues par un nouveau `Job(kind=CAD_ASSEMBLE)` → produit lui aussi
  un `Mesh` du même `Project`.

**Conséquence directe (ce que la demande visait)** : Impression (réparation/export
STL), Mouvements (`Part`/`Joint`, arbre cinématique) et Bâtiments s'appliquent à un
`Mesh` d'origine CAO ou d'assemblage **sans aucune modification de leur code** — ils
consomment déjà `Project`/`Mesh` génériquement (cf. Architecture actuelle ci-dessus).
Concrètement, pour construire un train d'engrenages : Lot 5.1 crée chaque roue dentée
comme un `Project` CAO, Lot 5.2 les assemble (axes concentriques/parallèles + distance
d'entraxe) en un `Project(ASSEMBLY)`, puis le Lot 3 (déjà construit, aucun changement)
pose un `Joint` pivot sur chaque roue de l'assemblage résultant pour prévisualiser la
rotation — Lot 5.2 ne fait que le **positionnement statique** des pièces, le Lot 3 gère
déjà le **mouvement**. Pas de solveur cinématique couplé à écrire (l'utilisateur tourne
chaque slider séparément, comme prévu pour Mouvements — cf. Hors périmètre).

### Décisions actées (à ne pas remettre en question sans le signaler)

- **Noyau géométrique : `build123d` (wrapper Python d'OpenCASCADE/OCCT), pas de noyau
  maison.** Réimplémenter un noyau B-rep exact (NURBS, booléens exacts, STEP) est hors
  de portée réaliste. `build123d` distribue des wheels précompilées (`OCP`) qui
  s'installent par `pip` sur une image **glibc** — l'image `atelier-3d` est déjà
  `ubuntu:24.04`, donc pas le problème musl/Alpine de `postgis`. Le maillage (point 7
  de la demande) est la tessellation OCCT native (`BRepMesh_IncrementalMesh`) :
  **finesse** = déflection angulaire, **erreur** = déflection linéaire — exposées
  comme paramètres utilisateur.
- **Solveur d'assemblage : FreeCAD headless (workbench `Assembly`, OndselSolver), pas
  un solveur maison.** Plus puissant et déjà éprouvé (DOF couplés) qu'un solveur à
  moindres carrés maison, au prix d'une dépendance lourde et d'une API moins stable
  pour un usage embarqué. **Risque non vérifié, à lever au Lot 5.0** : le paquet `apt`
  `freecad` d'Ubuntu 24.04 est antérieur à FreeCAD 1.0 (nov. 2024) et n'a
  probablement pas ce workbench — l'AppImage officielle ≥ 1.0 sera vraisemblablement
  nécessaire. `build123d` et FreeCAD communiquent par STEP (les deux reposent sur
  OCCT, échange sans perte).
- **Sketcher V1 = formulaires paramétriques + aperçu 3D three.js**, pas de canvas
  interactif ni de contraintes géométriques 2D résolues en direct dans le sketch.
- **Sélection de faces/arêtes/axes (denture, contraintes d'assemblage) réutilise le
  raycast de sélection three.js déjà construit pour la peinture de `Part` au Lot 3** —
  pas une nouvelle interaction à inventer, juste appliquée à l'aperçu tessellé du
  `CadOperation` courant.
- **Endpoint public = lecture seule, sans authentification, limité aux `Project` de
  type `ASSEMBLY` au statut résolu + leur `Mesh` le plus récent.** Contourne
  délibérément les deux verrous du lab pour ces routes précises — même logique que
  l'endpoint image `AllowAny` de `google-agenda`. Aucune autre route n'est concernée.
- **Courbes 2D non analytiques (sinusoïde...) ne sont pas des primitives exactes** :
  contrairement à la droite, au cercle ou à l'ellipse (exactes dans STEP), une
  sinusoïde est transcendante — approximée par une B-spline interpolée sur des points
  échantillonnés, comme dans toute CAO. « Épaisseur » = offset de cette courbe
  (`build123d.offset()`) avant extrusion/révolution.
- **Deux limites topologiques distinctes, assumées pour la V1** (problème connu, non
  résolu même par les CAO commerciales en général — détecté et signalé, pas réparé) :
  1. *Au sein d'un `Project` CAO* : une opération référence une face/arête par index
     du résultat d'une opération antérieure. Modifier une opération en amont peut
     renuméroter les faces avec dans l'historique. Réévaluation complète à chaque
     édition (pas de cache) ; si le nombre de faces/arêtes change après réévaluation,
     avertir avant d'appliquer les opérations suivantes plutôt que de les appliquer
     aveuglément sur les mauvais indices.
  2. *Entre `Project` au moment de l'assemblage* : une `CadAssemblyConstraint`
     référence une face/arête d'un `Mesh` **précis et immuable** (fichier déjà
     produit) — donc jamais ambiguë tant que l'instance pointe ce `Mesh`-là. Le seul
     moment risqué est un re-pointage explicite vers une version plus récente du
     `Mesh` source (la pièce a été rééditée) : c'est cette action qui doit avertir
     « les références de cette contrainte peuvent ne plus désigner les mêmes faces »,
     pas une invalidation spontanée.

### Modèle de données (Lot 5 — noms préfixés `Cad*` pour éviter toute collision avec
`Part`/`Joint` du Lot 3, qui désignent un concept différent : un sous-ensemble de
faces d'un `Mesh` triangulé, pas une pièce paramétrique)

```
Project        + project_type gagne ASSEMBLY (en plus de objet|bâtiment) ;
                 + assembly_status (DRAFT|SOLVED|ERROR, non nul seulement si
                 project_type=ASSEMBLY — état courant, distinct du status d'un Job
                 individuel, même logique que Mesh.is_watertight)
Job            + kind gagne CAD_BUILD (évalue les CadOperation d'un Project → Mesh)
                 et CAD_ASSEMBLE (résout les CadAssemblyConstraint d'un Project
                 ASSEMBLY via FreeCAD headless → Mesh)
Mesh           + step_file (fichier STEP exact, nul pour un Mesh issu de la
                 photogrammétrie qui n'a pas de B-rep — seulement pour CAD_BUILD/
                 CAD_ASSEMBLE) ; + linear_deflection/angular_deflection utilisés pour
                 la tessellation
CadSketch      (project FK, nom, plan de référence XY|XZ|YZ, entités 2D en JSON :
                segments, polylignes/polygones fermés, cercles, arcs, courbes
                B-spline échantillonnées + épaisseur)
CadOperation   (project FK, ordre, type : PRIMITIVE_BOX|SPHERE|CYLINDER|CONE|TORUS,
                EXTRUDE|REVOLVE (mode ADD|CUT|INTERSECT, référence une CadSketch),
                SURFACE_FROM_WIRE, BOOLEAN_UNION|CUT|INTERSECT (référence 2
                opérations précédentes), PATTERN_CIRCULAR|PATTERN_LINEAR (référence
                une opération + nombre de répétitions + pas), GEAR_TEETH (référence
                une opération + un index de face cylindrique/conique + module,
                nombre de dents, angle de pression, largeur, interne/externe),
                params JSON) — réévalué en entier à chaque édition (limite 1
                ci-dessus)
CadAssemblyInstance (assembly_project FK [project_type=ASSEMBLY], source_project FK,
                source_mesh FK [pin la version exacte utilisée, limite 2 ci-dessus],
                label, placement JSON — nul avant résolution)
CadAssemblyConstraint (assembly_project FK, type COINCIDENT|CONTACT|PARALLEL|
                CONCENTRIC|DISTANCE|ANGLE|FIXED|GEAR_MESH, instance_a FK +
                référence_a JSON {kind: face|edge|vertex, index}, instance_b FK +
                référence_b JSON (nul si FIXED = ancrée au monde), params JSON —
                GEAR_MESH dérive automatiquement PARALLEL + la DISTANCE d'entraxe
                correcte à partir du module/nombre de dents de chaque roue posés à
                l'opération GEAR_TEETH de chaque pièce, au lieu de la faire calculer
                à la main par l'utilisateur)
```

### Opérations sur les surfaces : denture (engrenages)

Une denture n'est **pas** une déformation d'une surface existante — comme dans toute
CAO, c'est une géométrie de denture (calculée par une formule d'évolvante) **générée
séparément puis combinée** à la pièce existante par un booléen, positionnée sur l'axe
de la face cylindrique/conique désignée :

1. L'utilisateur choisit une opération antérieure (le corps existant, ex. un cylindre)
   et désigne une de ses faces cylindriques via le raycast three.js déjà en place —
   validation explicite : la face doit être cylindrique (ou conique pour une future
   extension denture conique), sinon erreur claire plutôt qu'un résultat silencieux.
2. Génération du profil de denture : **réutiliser une bibliothèque existante
   (`cq_gears`, un plugin CadQuery qui génère des engrenages droits/hélicoïdaux/
   coniques/crémaillères en évolvante comme solides OCCT exacts)** plutôt que de
   dériver les équations d'évolvante soi-même — même logique de non-réinvention que
   COLMAP/OpenMVS ou FastSAM. `cadquery` et `build123d` reposent sur les mêmes
   bindings OCCT (`OCP`) : le solide généré par `cq_gears` peut être extrait comme
   forme OCCT brute et intégré directement dans un objet `build123d`, sans passer par
   un fichier — **à valider en Lot 5.0** (compatibilité de versions `OCP` entre les
   deux paquets, sinon repli par export/import STEP, plus lent mais robuste).
3. Combinaison : booléen union (engrenage externe — les dents dépassent du rayon de
   pied) ou intersection/soustraction (couronne/engrenage interne) avec le corps
   existant, sur l'axe de la face désignée.
4. Le résultat redevient une pièce comme une autre — tessellée, exportée STEP/glTF/STL
   via le pipeline `CAD_BUILD` normal, aucun traitement spécial en aval.

V1 : engrenages droits externes et internes (couronnes), axe cylindrique. Hélicoïdal,
conique et crémaillère (face plane plutôt que cylindrique) : extensions naturelles de
la même opération une fois validée, pas dans le périmètre initial.

### Lot 5.0 — Spike technique (avant toute UI/API, même logique que le Lot 0 historique)

- Installer `build123d` dans l'image `atelier-3d` (Ubuntu 24.04, CPU-only) : booléen,
  extrusion depuis un sketch, export STEP, tessellation à déflections réglables —
  vérifier qu'aucune wheel ne réclame une extension CPU absente du matériel cible
  (leçon du SIGILL d'`open3d`, à revérifier plutôt que supposer OCCT non concerné).
- Installer `cq_gears` (ou équivalent) et valider la génération d'un engrenage droit +
  son intégration comme forme OCCT dans `build123d` (voir ci-dessus, point 2).
- Installer FreeCAD ≥ 1.0 headless (probablement AppImage officielle) : charger deux
  pièces STEP, poser une contrainte, résoudre, exporter le résultat assemblé
  tessellé — sans serveur X, en CPU-only. **Point bloquant à lever avant le Lot 5.2** :
  si le workbench `Assembly`/OndselSolver n'est pas scriptable proprement en headless,
  remonter le problème plutôt que forcer un contournement fragile.
- Mesurer le poids ajouté à l'image Docker (FreeCAD complet) et le temps de build.

### Lot 5.1 — Modélisation de pièces (`Project` sans photos, `Job(CAD_BUILD)`)

- `CadSketch` : segments, polylignes/polygones fermés, cercles, arcs, courbes
  B-spline échantillonnées avec épaisseur — formulaires numériques.
- Primitives 3D directes : boîte, sphère, cylindre, cône, tore.
- Opérations : extrusion (classique et « trou » via booléen soustractif), révolution,
  booléens union/intersection/différence, surface depuis un contour plan
  (`SURFACE_FROM_WIRE`), répétition circulaire/linéaire (`PATTERN_CIRCULAR`/
  `PATTERN_LINEAR`), denture (`GEAR_TEETH`, voir ci-dessus).
- `Job(CAD_BUILD)` : évalue l'historique `CadOperation` du `Project`, tessellation à
  déflections réglables, écrit un nouveau `Mesh` (fichier STEP + `gltf_file`, comme
  n'importe quel autre `Mesh`) — réutilisable tel quel par Impression (export STL),
  Mouvements (`Part`/`Joint`) et Bâtiments sans changement de leur code.

### Lot 5.2 — Assemblage par contraintes (`Project(ASSEMBLY)`, `Job(CAD_ASSEMBLE)`)

- Page Assemblage : ajouter des `CadAssemblyInstance` (référençant un `Project` CAO
  existant + son `Mesh` précis), poser des `CadAssemblyConstraint` (coïncidence,
  contact/coplanarité, parallélisme, concentricité d'axes, distance, angle, fixation
  au monde, `GEAR_MESH` pour deux roues dentées) via le raycast three.js existant.
- `Job(CAD_ASSEMBLE)` : export STEP de chaque `Mesh` référencé → document FreeCAD →
  contraintes → résolution → placements par instance + `Mesh` global tessellé du
  `Project(ASSEMBLY)` (même modèle `Mesh` que partout ailleurs).
- Avant résolution : vérifier qu'aucune instance ne pointe un `Mesh` plus ancien que
  la version actuelle de son `Project` source sans confirmation explicite (limite 2
  ci-dessus).
- `Project.assembly_status` : `DRAFT` (contraintes incomplètes/non résolues) /
  `SOLVED` / `ERROR` (système surcontraint ou insoluble — remonter le message du
  solveur, ne pas l'avaler).
- Une fois `SOLVED`, le `Mesh` résultant est un `Mesh` de `Project` comme un autre :
  le Lot 3 (déjà construit) peut y poser des `Joint` (ex. pivot par roue dentée) pour
  prévisualiser le mouvement — aucun changement requis côté Lot 3.

### Lot 5.3 — API publique (lecture seule)

- Endpoints sans authentification, en lecture seule : liste des `Project`
  `project_type=ASSEMBLY, assembly_status=SOLVED`, détail, et leur `Mesh` le plus
  récent (glTF pour visualisation, STEP pour réutilisation exacte). Voir Sécurité
  ci-dessous pour le contournement délibéré des deux verrous sur ces routes précises.

---

## Sécurité / cloisonnement

Rappel (voir CLAUDE.md racine) : `--require-group` obligatoire dans
`<app>/.keycloak-client-opts` avant tout `setup2.sh`.

**Exception actée (Lot 5.3)** : les endpoints publics `Project(ASSEMBLY, SOLVED)` +
leur `Mesh` global sont volontairement en dehors des deux verrous — pas de flow
Keycloak, pas de contrôle `azp`/`groups` côté DRF (`permission_classes = [AllowAny]`,
même pattern que l'endpoint image de `google-agenda`). Strictement en lecture seule
(GET), filtré à `project_type=ASSEMBLY` + `assembly_status=SOLVED` uniquement — un
`Project` CAO mono-pièce ou un assemblage encore `DRAFT`/`ERROR` n'y est jamais
exposé. Toutes les autres routes de l'app restent derrière le cloisonnement standard.

## Checklist de vérification (par lot)

- [x] Lot 0 : pipeline COLMAP+OpenMVS validé, temps mesuré.
- [x] Lot 1 : Reconstruction livrée.
- [x] Lot 2 : Impression livrée (2026-07-21, mémoire atelier-3d-lot2-impression).
- [x] Lot 3 : Mouvements livré (2026-07-21, mémoire atelier-3d-lot3-mouvements).
- [x] Lot 4 : Bâtiments livré (2026-07-22, mémoire atelier-3d-lot4-batiments).
- [x] Lot 5.0 : `build123d` + `cq_gears` fonctionnels dans l'image cible (booléen,
      extrusion, export STEP, tessellation à déflections réglables, engrenage généré
      et intégré comme forme OCCT, vérifié 2026-07-26) ; FreeCAD 1.1.3 headless
      installé (AppImage extraite au build) et le workbench Assembly/OndselSolver
      scriptable sans serveur X — point bloquant explicitement levé (résolution
      réelle vérifiée : déplacement mesuré de la pièce contrainte, export STEP du
      résultat). Intégré dans le vrai `atelier-3d/backend/Dockerfile` et testé dans
      le conteneur réel aux côtés de torch/ultralytics/pymeshlab (aucun conflit).
      Bug trouvé et corrigé en cours de route : `ENV PATH=".../opt/freecad/usr/bin:$PATH"`
      faisait résoudre `python` vers l'interpréteur embarqué de FreeCAD (3.11, sans
      Django) au lieu du python système (3.12) — remplacé par un lien symbolique
      ciblé sur `freecadcmd` uniquement.
- [ ] Lot 5.1 : sketch, primitives 3D, extrusion (classique et trou), révolution,
      booléens, surface depuis un contour, pattern circulaire/linéaire, denture —
      chacun vérifié sur un cas réel ; `Job(CAD_BUILD)` produit un `Mesh` standard
      réutilisable tel quel par Impression/Mouvements (vérifier explicitement : ouvrir
      un `Mesh` d'origine CAO dans la page Mouvements et y poser un `Joint`).
- [ ] Lot 5.2 : au moins deux `Project` CAO assemblés avec au moins deux types de
      contraintes différents dont un `GEAR_MESH` (deux roues dentées), résolution
      FreeCAD réelle, `Mesh` global correct dans le viewer, avertissement de
      re-pointage vers un `Mesh` plus récent vérifié.
      **Fait le 2026-07-26** (assemblage réel « push-machine », 6 sous-parties,
      7 contraintes de 4 types différents dont `GEAR_MESH` — FIXED, CONCENTRIC,
      GEAR_MESH, CONTACT — résolues par `Job(CAD_ASSEMBLE)` réel via
      `cad_assemble.py`/`cad_assemble_freecad_worker.py` : compound 6 solides,
      watertight, toutes les coïncidences attendues vérifiées à la précision
      machine (~1e-15), entraxe pignon/grand-engrenage exact 48mm, longueur
      bielle exacte 70mm — cf. mémoire atelier_3d_lot5_2_assembly_findings.
      **Reste à faire avant de cocher** : l'avertissement de re-pointage vers un
      `Mesh` plus récent (limite topologique n°2) n'a pas d'UI/logique dédiée —
      `CadAssemblyInstanceListCreateView` prend juste le dernier `Mesh` à la
      création, sans mécanisme de ré-association explicite ni avertissement si
      la sous-partie source est reconstruite après coup.
- [ ] Lot 5.3 : endpoints publics accessibles sans aucun token/cookie, strictement
      limités aux `Project(ASSEMBLY, SOLVED)`, en lecture seule.
- [ ] À chaque lot : un seul job lourd actif à la fois (verrou global vérifié), aucun
      déclenchement automatique de job à l'upload/à la création.
- [ ] **Une fois le Lot 5 entièrement terminé et vérifié** (5.0 à 5.3 cochés
      ci-dessus) : nettoyer `dev/atelier-3d-spike/` (spike Lot 0, jamais suivi par
      git, ses conclusions sont déjà absorbées dans `atelier-3d/backend/Dockerfile` —
      voir mémoire atelier-3d-lot0-spike-findings avant de le supprimer, au cas où un
      détail du spike original n'aurait pas encore été reporté).
