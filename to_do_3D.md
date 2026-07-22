# MISSION — Atelier 3D : photos/vidéo → objet 3D, analyse cinématique, impression, sémantique bâtiment

Nouvelle application du lab, en 4 modules construits dans cet ordre (décidé après
discussion, voir raisons plus bas) :

1. **Reconstruction** — convertir des photos (ou un film dont on extrait les frames)
   en objet 3D texturé.
2. **Impression 3D** — réparer/orienter/exporter ce maillage pour l'impression.
3. **Mouvements** — segmenter un objet 3D en parties et définir les jointures/mouvements
   possibles entre elles.
4. **Bâtiments** — reconnaître murs/fenêtres/portes sur un maillage de bâtiment et
   réécrire un maillage portant une information sémantique par triangle.

Ce document est le cahier des charges complet de l'app — décisions d'architecture,
contraintes, découpage en lots — pour être exécutable sans dépendre d'un autre
document. Toute tâche ci-dessous qui semble sortir des contraintes listées est un
signal pour s'arrêter et clarifier plutôt que d'improviser.

---

## Contraintes fondamentales (jamais à improviser)

- **Serveur du lab : 2 vCPU, 16 Go RAM, aucun GPU.** Toute solution ici est CPU-only.
  Ne jamais introduire de dépendance CUDA (NeRF, 3D Gaussian Splatting, gros modèle de
  vision GPU) — si une tâche semble l'exiger, s'arrêter et remonter le problème plutôt
  que d'improviser un fallback.
- **100 % local, pas de burst cloud.** Décision actée : on n'externalise aucun calcul.
  Un job long doit rester supportable en local (voir presets qualité/résolution par
  module) plutôt que de réclamer plus de puissance qu'il n'y en a.
- **Un seul job « lourd » actif à la fois pour toute l'app** (verrou global), même si
  Celery permettrait la concurrence — le CPU est partagé avec le reste du lab.
  `CELERY_WORKER_CONCURRENCY=1` et un verrou applicatif (ex. lock DB/Redis) qui refuse
  de lancer un second job tant qu'un premier tourne, tous modules confondus.
- **Aucun job ne se déclenche automatiquement à l'upload.** L'utilisateur lance
  explicitement chaque étape lourde, avec une estimation de durée affichée avant
  confirmation.
- Le module Impression exporte un maillage propre ; il **ne réimplémente pas un
  slicer** (Cura/PrusaSlicer existants font ce travail).
- Le module Mouvements ne tente **pas** de résoudre automatiquement des mécanismes à
  liaisons couplées (type 4 barres) — l'édition manuelle est le mode principal, pas un
  repli d'exception (décision actée : usage général, objets organiques inclus, donc la
  segmentation automatique par primitives ne sera pas fiable dans le cas général).
- Le module Bâtiments ne s'appuie sur **aucun modèle pré-entraîné spécifique
  façades** (pas de dataset côté lab) — segmentation 2D zero-shot + labellisation
  assistée + propagation multi-vue uniquement.

## HORS PÉRIMÈTRE

- NeRF, 3D Gaussian Splatting, tout pipeline nécessitant CUDA.
- Slicing / génération de G-code.
- Résolution automatique de mécanismes à liaisons couplées entre plusieurs jointures.
- Entraînement d'un modèle de segmentation sémantique façades.
- Calcul cloud/GPU loué à la demande.

---

## Pourquoi cet ordre et ces choix (contexte de la discussion)

- **Reconstruction d'abord** : les 3 autres modules consomment son résultat (maillage,
  et pour Bâtiments les poses caméra) — c'est la fondation.
- **Impression avant Mouvements** : c'est le module le plus tractable (réparation de
  maillage = ingénierie connue), un premier cas d'usage complet livrable rapidement.
- **Mouvements avant Bâtiments** : Bâtiments est le module le plus expérimental
  (segmentation sémantique sans modèle entraîné dédié) — logique de le construire en
  dernier, une fois la mécanique de segmentation/labellisation manuelle déjà rodée sur
  Mouvements.
- **Aucun GPU, aucun burst cloud** : décision actée malgré le coût en temps de calcul —
  cohérent avec le principe self-hosted du reste du lab (aucune autre app n'externalise
  de calcul).
- **Mouvements en usage général (objets organiques inclus)** : implique que l'édition
  manuelle des parties/jointures est l'outil principal, la segmentation automatique par
  primitives n'étant qu'une suggestion en fond.
- **Bâtiments : sol ET drone** : implique de dimensionner les presets qualité/résolution
  pour le scénario le plus lourd (drone, centaines de photos) dès la conception, pas
  en rattrapage.

---

## Architecture générale

- **Scaffold** : `new-app.sh`, type Django+Angular (type 4). Nom suggéré `atelier-3d`
  (librement ajustable). Instance PostgreSQL `postgres` partagée suffit — pas de besoin
  géospatial au sens SIG (pas de `postgis`), les maillages sont des fichiers, pas des
  géométries en base.
- **Groupe `--require-group`** : à choisir à l'étape 3bis du scaffold (voir CLAUDE.md
  racine) — non décidé dans ce document, ne pas déployer sans lui.
- **File de tâches** : Celery + Redis, calqué sur `carto-lab/backend/api/tasks.py` et
  son modèle `Job` (`carto-lab/backend/api/models.py:69`) — mêmes noms de champs :
  `kind`, `status` (`PENDING/RUNNING/DONE/ERROR`), `progress` (0..100), `message`,
  `params` (JSONField), `celery_task_id`, `owner_email`, `created_at`/`updated_at`,
  méthode `set_state()`. Un `kind` par étape lourde : `RECONSTRUCTION`, `REPAIR`,
  `SEGMENTATION_PARTS`, `SEGMENTATION_FACADE`.
- **Stockage** : volume Docker `external: true` dédié (voir `carto-lab/docker-compose.yml`
  → volume `carto-media` comme référence) — photos sources, nuages de points
  intermédiaires et maillages peuvent peser plusieurs Go par projet (388 Go disponibles
  sur le serveur au moment de la rédaction, marge confortable).
- **Format pivot interne** : PLY (attributs par face/sommet arbitraires — `class_id`,
  `part_id` — lus/écrits via `trimesh`/`open3d`/`pymeshlab`). Exports : glTF pour le
  viewer three.js (Angular), STL/3MF pour l'impression.
- **Viewer 3D frontend** : three.js (`OrbitControls`, `GLTFLoader`, `STLLoader`) — seule
  dépendance 3D à ajouter au template Angular pour cette app.
- **Bibliothèques Python** (`requirements.txt`, en plus du socle template) :
  `trimesh>=4.0`, `open3d>=0.18`, `pymeshlab>=2023.12`, `pyransac3d>=0.6`, `numpy`,
  `scipy` — `celery`/`redis` déjà dans le template.
- **Binaires système (non-pip)**, à compiler dans le Dockerfile backend **sans CUDA** :
  COLMAP, OpenMVS. Voir Lot 0 — c'est le risque technique principal du projet.

## Modèle de données (aperçu)

```
Project    (nom, description, type dominant: objet|bâtiment, owner_email)
Photo      (project FK, fichier, ordre, pose caméra JSON — nulle avant reconstruction)
Job        (project FK, kind, status, progress, message, params, celery_task_id, ...)
Mesh       (project FK, job FK d'origine, fichier PLY, version)
             — reconstruction / réparation / segmentation produisent chacune une
               nouvelle version plutôt que d'écraser la précédente
Part       (mesh FK, ids de faces, nom)                              — module Mouvements
Joint      (part_a FK, part_b FK, type revolute|prismatic|fixed,
            axe, limites)                                            — module Mouvements
SemanticClass (mesh FK, nom, couleur)                                 — module Bâtiments
```

---

## Lot 0 — Spike technique (avant toute UI/API)

Avant d'écrire une seule route Django ou un seul composant Angular : prouver que
COLMAP (CPU-only) → OpenMVS (CPU-only, densify + mesh + texture) tourne bout-en-bout
dans un conteneur Docker sur un petit jeu de test (10-20 photos d'un objet simple), et
produit un maillage texturé exploitable. **Mesurer le temps réel sur 2 vCPU.** C'est le
risque technique le plus élevé du projet — s'il échoue ou est inexploitablement lent,
il faut le savoir avant de construire quoi que ce soit autour, pas après.

## Lot 1 — Module Reconstruction (photos/vidéo → objet 3D)

- Upload : glisser-déposer photos, OU upload vidéo + extraction automatique de frames
  (`ffmpeg` + filtre netteté par variance du Laplacien, sous-échantillonnage temporel
  pour garantir une baseline suffisante entre frames retenues).
- Presets qualité/résolution (ex. Rapide/Équilibré/Précis) bornant la résolution
  d'image et le nombre de features SfM — chaque preset affiche une **estimation de
  durée avant lancement**, calibrée sur la mesure du Lot 0.
- Calibration d'échelle : champ optionnel (distance entre deux points cliqués sur une
  photo, ou taille connue d'un objet de référence dans la scène) pour ancrer le
  maillage à une échelle métrique réelle. Sans cette info, avertir clairement que le
  maillage sort à une **échelle arbitraire** (point bloquant pour le module Impression).
- Job `RECONSTRUCTION` : COLMAP (SfM, poses caméra) → OpenMVS (densify, mesh, texture)
  → export PLY texturé + glTF.
- Page résultat : viewer three.js (orbit, bascule filaire), infos (nb photos utilisées,
  poses résolues/échouées, temps de calcul réel).

## Lot 2 — Module Impression 3D

- Réparation watertight (`pymeshlab`, ou reconstruction de Poisson via `open3d` si le
  maillage est trop dégradé) — rapport avant/après (trous comblés, non-manifold
  corrigé).
- Décimation/remaillage (cible : nombre de triangles ou poids de fichier).
- Mise à l'échelle réelle — **bloquer l'export tant que le mesh n'a pas d'échelle
  métrique connue** (cf. calibration du Lot 1).
- Orientation d'impression : heuristique d'auto-orientation (face la plus plate posée /
  surface en surplomb minimisée par échantillonnage d'orientations), ajustable
  manuellement dans le viewer.
- Export STL/3MF téléchargeable. Pas de slicing, pas de g-code (voir Hors périmètre).

## Lot 3 — Module Mouvements (parties + jointures)

- Décision actée : usage général, objets organiques inclus → **l'édition manuelle est
  l'outil principal**, la segmentation automatique n'est qu'une suggestion en fond.
- Outil de sélection manuelle de faces (peinture au pinceau 3D ou lasso dans le viewer)
  pour découper le maillage en `Part`, avec suggestion automatique en fond (ajustement
  RANSAC plans/cylindres/sphères via `pyransac3d`) que l'utilisateur accepte, ajuste ou
  ignore entièrement.
- Définition manuelle des jointures entre deux `Part` : type (pivot/glissière/fixe),
  axe (suggestion automatique si la zone de contact est cylindrique/planaire, sinon
  entièrement manuel via manipulateur 3D dans le viewer), limites (angle ou distance
  min/max).
- Arbre cinématique (`Joint` reliant des `Part`) + prévisualisation : un slider par
  jointure, three.js applique les transformations comme une hiérarchie de nœuds
  rigides (pas de skinning — plus proche d'un assemblage CAO que d'un rig de
  personnage).
- Hors périmètre ici (rappel) : résolution automatique de contraintes couplées entre
  plusieurs jointures.

## Lot 4 — Module Bâtiments (façades)

- Décision actée : capture au sol **et** par drone → les presets qualité du Lot 1
  doivent couvrir le scénario drone (centaines de photos) ; **avertir explicitement**
  si l'estimation de durée dépasse un seuil (ex. plusieurs heures) avant de lancer le
  job.
- Réutilise obligatoirement les poses caméra du Lot 1 — un projet « bâtiment » sans
  reconstruction préalable ne peut pas lancer ce module.
- Segmentation 2D zero-shot par région (ex. SAM en CPU — accepter une latence par
  image, traiter en batch) sur chaque photo.
- Labellisation assistée : l'utilisateur clique quelques régions par classe
  (mur/fenêtre/porte/toit) sur une ou deux photos ; propagation automatique aux
  régions équivalentes des autres photos du même bâtiment via les correspondances
  multi-vues déjà calculées par le SfM (Lot 1) — pas de modèle entraîné.
- Job `SEGMENTATION_FACADE` : rétro-projection multi-vues (vote majoritaire par
  triangle à partir des labels 2D + poses caméra) → `class_id` par face.
- Régularisation : ajustement de plan RANSAC sur les faces « mur » (projection des
  sommets sur le plan ajusté, aplanit le bruit de reconstruction), régularisation
  rectangulaire des contours fenêtres/portes.
- Export : PLY avec `class_id` par face (interne) + glTF en sous-maillages par
  classe/matériau nommé (viewer).

---

## Sécurité / cloisonnement

Rappel (voir CLAUDE.md racine) : `--require-group` obligatoire dans
`<app>/.keycloak-client-opts` avant tout `setup2.sh`. Groupe(s) LDAP à choisir à
l'étape 3bis du scaffold — non décidé dans ce document.

## Checklist de vérification (par lot)

- [ ] Lot 0 : pipeline COLMAP+OpenMVS CPU-only reproductible en Docker, temps mesuré
      sur le jeu de test.
- [ ] Lot 1 : upload photos et vidéo fonctionnels, job de reconstruction visible avec
      statut/progress, viewer three.js affiche le résultat, avertissement d'échelle
      arbitraire si non calibré.
- [x] Lot 2 : réparation watertight vérifiable (rapport avant/après), export STL/3MF
      valide (ouvrable dans un slicer externe), export bloqué si échelle inconnue.
      Implémenté et vérifié end-to-end le 2026-07-21 (voir mémoire atelier-3d-lot2-impression).
      open3d abandonné (crash SIGILL, wheels AVX2-only sur CPU sans AVX) — repli Poisson
      fait par pymeshlab (`generate_surface_reconstruction_screened_poisson`), décision
      utilisateur.
- [x] Lot 3 : sélection manuelle de faces fonctionnelle, suggestion automatique non
      bloquante, arbre cinématique + sliders de prévisualisation fonctionnels sur un
      objet test à au moins 2 jointures. Implémenté le 2026-07-21 (voir mémoire
      atelier-3d-lot3-mouvements) — backend vérifié en conditions réelles (RANSAC +
      API HTTP sur un vrai maillage), puis UI vérifiée en navigateur réel le même jour
      (peinture, pose d'axe manuelle et suggérée, sliders cinématiques). 3 bugs trouvés
      et corrigés au passage (lien profond Keycloak — lab-wide, OrbitControls actif
      pendant la peinture, raycast non accéléré) — voir mémoire
      keycloak-deeplink-redirect-bug pour le premier, qui affecte aussi les 8 autres
      apps du lab.
- [x] Lot 4 : labellisation assistée + propagation multi-vue fonctionnelles sur un
      petit jeu de test, export glTF par classe visible dans le viewer, avertissement
      de durée avant job drone-scale. Implémenté et vérifié end-to-end le 2026-07-22
      (voir mémoire atelier-3d-lot4-batiments) — backend vérifié en conditions réelles
      (jobs RECONSTRUCTION puis SEGMENTATION_FACADE réels sur 18 photos réelles, worker
      Celery réel), puis UI vérifiée en navigateur réel (labellisation sur 2 photos,
      propagation multi-vue, légende de classes). Segmentation 2D zero-shot : FastSAM
      (CPU, ~15s/photo, pas de SAM classique). 2 bugs réels trouvés et corrigés
      (mismatch d'échelle projection caméra/carte de régions, cascade de propagation
      inter-photos) — voir mémoire pour le détail.
- [ ] À chaque lot : un seul job lourd actif à la fois (verrou global vérifié), aucun
      déclenchement automatique de job à l'upload.
