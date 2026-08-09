# bilan-thermique — to_do.md (Phase 2 : fiabilité, physique manquante, ergonomie)

Lots A→E livrés (`git log` du sous-module) : scaffold, page Théorie + Calcul 1D, bibliothèque de
parois, catalogue de départ (vitrages/murs ITE-ITI/toitures RT2005-RT2012-RE2020), maillage
bâtiment + ombrage par lancer de rayons (Lot B/C), solveur bâtiment multi-triangle sparse (Lot D),
dashboard résultats (Lot E), puis hors numérotation : raffinement de maillage, facteur de vue du
ciel occlus, mode ombrage temps réel, génération auto d'environnement (IGN BD TOPO / OSM) avec
géoréférencement du bâtiment. Détails et pièges déjà rencontrés : mémoire `project_bilan_thermique.md`.

Ce document couvre ce qui reste, identifié en relisant `solver.py`, `building_solver.py`,
`shadow.py`, `geometry.py`, `geodata.py`, `serializers.py` et le parcours Angular
(page Bâtiment → Calcul 3D) le 2026-08-06. Trois familles de chantiers : fiabiliser le solveur
existant (Lot F), combler des manques physiques qui faussent le résultat (Lots G→K, R), simplifier le
travail de l'utilisateur (Lots L→P, S) — Lot Q à cheval sur les deux dernières familles (généralise
G/H à un planning, ce qui est autant une correction physique qu'une simplification de saisie).

**Tous les lots sont livrés : F, G, H, I, J, K, L, M, N, O, P, Q, R, S, T, U et V** (tests
physiques automatisés, renouvellement d'air, apports internes, cadre de fenêtre, occultations
mobiles, triangles au contact du sol, import météo automatique Open-Meteo + PVGIS TMY, résultats
normalisés kWh/m²/an, checklist de progression, générateur de boîte, aide au calcul de
`c_air_int`, plannings horaires, convection dynamique (vent + orientation), années type, mode
simplifié pour un bâtiment réel existant, rayonnement transmis intégralement à travers un vitrage,
calendrier d'occupation pour le mode thermostat) — voir leur section respective pour le détail.
**Lot V livré le 2026-08-09**, dernier lot restant, cadré avec l'utilisateur avant de coder
(six profils d'usage scolaire/tertiaire/habitation × climatisé ou non, calendrier jour de la
semaine + jours ouvrés + plages de vacances) — voir sa section, notamment la correction de cadrage
en cours de route (le hors-gel « vacances » est propre au scolaire, jamais au tertiaire) tranchée
avec l'utilisateur avant implémentation. **Lot J livré le 2026-08-09**, cadré avec l'utilisateur
avant de coder (patron de factorisation, puis valeurs des deux profils usuels) — voir sa section,
notamment le design en calque (`shading_profile_id`) qui a résolu le dilemme des deux options
d'origine sans les compromis d'aucune des deux. **Lot U (2026-08-08) est un correctif, pas une
nouvelle fonctionnalité** — signalé par l'utilisateur en testant manuellement des fenêtres en 1D,
il touchait `solver._propagate_solar`, partagée par les deux solveurs : jusqu'à 87 % du
rayonnement solaire incident sur tout le catalogue de vitrages disparaissait du bilan avant ce
correctif (voir sa section) — le plus significatif en gravité de tous les correctifs de cette
phase 2.
Chaque lot qui touche `_assemble_F`/`_assemble_F_hour` doit faire passer `python manage.py test api`
avant/après modification — c'est tout l'intérêt du Lot F : détecter une régression au lieu de la
découvrir en production (H, K, Q, I, R, U et J l'ont fait, 15/15 puis 28/28 puis 36/36 puis 43/43
puis 48/48 puis 70/70 puis 78/78 puis 91/91 OK à chaque étape ; Q, R et J touchaient la
factorisation LU du solveur, I a fait remonter un vrai trou de couverture par mutation testing, R un
piège d'identité tautologique (la conservation d'énergie ne peut pas détecter un bug dans K), U
l'inverse — un bug dans **F**, où cette même identité redevient légitime — et J une variante des
deux (un test avec soleil restait aveugle à un bug dans K, masqué par un canal F correct ; corrigé en
retirant le soleil pour isoler le canal K) — voir leurs sections respectives). **Lot I livré avec un
design différent de l'étape 2 d'origine** (tranché
avec l'utilisateur avant de coder — voir sa section) : le vitrage garde son maillage complet sur une
aire réduite plutôt que d'être remplacé par un résistor unique, pour ne pas perdre le gain solaire.
**Lot R livré le 2026-08-08** (cadré avec l'utilisateur avant de coder — formule Jürges, portée
étendue à h_i par orientation — voir sa section) : le « point dur » performance anticipé par le texte
d'origine (factorisation par valeur de vent) s'est avéré non bloquant une fois mesuré en réel
(14-21 classes de vent sur un an réel, ~30 s de calcul dans le pire cas mesuré) ; généralise le
patron de factorisation-par-valeur-distincte du Lot Q à `K_global` en entier plutôt qu'au seul nœud
d'air, comme anticipé. **Lot N livré le 2026-08-08** (checklist de progression, page Bâtiment) — voir
sa section, notamment l'écart assumé sur l'item « météo chargée » (aucun état persisté possible, Lot
L). **Lot O livré le 2026-08-08** (générateur de boîte) — voir sa section, notamment la dérivation à
la main des normales sortantes par groupe, vérifiée en réel via `api.geometry.compute_envelope_geometry`.
**Lot T (mode simplifié, spécifié par
l'utilisateur le 2026-08-07) livré le 2026-08-08** — recherche de bâtiment réel (IGN/OSM) + taux de
vitrage par paroi + météo automatique (réutilise le préremplissage existant de Calcul 3D), pensé
comme point d'entrée pédagogique vers la méthode complète ; les deux décisions à trancher au moment
de coder (regroupement des faces par mur, distinction paroi opaque/vitrage) ont été résolues sans
cadrage utilisateur supplémentaire — voir sa section pour le détail et les découvertes en réel
(limite `MAX_WALLS_SIMPLIFIED_MODE`, cascade de raffinement).

À lire intégralement avant tout lot, comme pour tout cahier des charges du lab. Mêmes règles que le
reste de `dev/` (CLAUDE.md racine) : mémoire tenue à jour, demander avant tout commit/push et avant
toute décision d'architecture significative non tranchée ici.

---

## Lot F — Tests physiques automatisés ✅ livré le 2026-08-07

### Ce qui a été fait
`backend/api/tests.py` (nouveau, 11 tests, `django.test.SimpleTestCase` — pas de DB, cohérent avec
le reste du lab qui utilise déjà le framework de test Django plutôt que pytest, ex. `restauration`).
Chaque test compare le solveur à un oracle **indépendant de son propre code** (formule physique à la
main ou identité algébrique dérivée à la main) — jamais un appel aux fonctions privées
`_assemble_*`/`_build_mesh` du module testé, pour ne pas faire reproduire un bug côté « attendu ».

1. **Régime permanent connu** (`WallSteadyStateTest`) — mur mono-couche ET mur bi-couche finement
   maillé, comparés à U = 1/(1/h_e + Σe/λ + 1/h_i) après convergence.
2. **Conservation d'énergie** :
   - **1D** (`WallEnergyConservationTest`) — identité EXACTE (pas une tolérance de convergence) issue
     de l'algèbre d'Euler implicite sur un mur à un seul élément : la variation d'énergie stockée
     (capacités nodales `rho*c*e/2`, convention documentée de `_assemble_kc`) égale exactement le
     flux entrant moins sortant, intégré sur une météo **variable** (pas constante, pour ne pas
     laisser une erreur s'annuler par symétrie).
   - **3D** (`BuildingAirNodeEnergyBalanceTest`) — même identité sur le nœud d'air global, dérivée à
     la main : `C_air·ΔT_air = Σ envelope_flux_w·dt` en mode `'free'`. **Déviation assumée par
     rapport à l'énoncé d'origine** : testé en `'free'`/`'thermostat'` plutôt qu'`'imposed'` — en
     mode `imposed` le nœud d'air est figé par Dirichlet, il n'y a rien à conserver qui ne soit déjà
     couvert par le test de cohérence 1D↔3D (étape 3) et par le test 1D en mode `imposed` ci-dessus.
3. **Cohérence 1D ↔ 3D** (`Building1D3DConsistencyTest`) — bâtiment à un seul triangle d'aire
   volontairement différente de 1 m² (3,7 m²), même paroi/météo/conditions que `solver.run_simulation`
   en mode `imposed` : températures de surface identiques à 1e-6 près.
4. **Mode thermostat** (`test_thermostat_mode_hvac_matches_residual_energy_balance`) — même identité
   de conservation que l'étape 2 mais avec le terme HVAC en plus (`C_air·ΔT_air = Σflux·dt +
   (heating_kwh-cooling_kwh)·3,6e6`), sur un scénario météo forçant **chauffage ET climatisation**
   dans la même série (sinon le test ne dit rien sur le signe du résidu).
5. **`sun_direction` dédupliquée** — `building_solver._sun_direction` supprimée, `building_solver.py`
   appelle désormais `shadow.sun_direction` (seul point de vérité pour la convention azimuth).
6. **Ombrage** (`ShadowSkyViewFactorTest`, `ShadowOcclusionTest`) — sans obstacle, le facteur de vue
   du ciel retombe exactement sur `(1+cos(tilt))/2` (toiture plate ET mur vertical) ; avec un
   panneau plat placé juste au-dessus d'un triangle tourné vers le ciel, l'occlusion au zénith
   (élévation 90°) passe bien de visible à bloqué.

**Vérification que les tests détectent vraiment des bugs** (pas seulement qu'ils passent) : mutation
délibérée du signe du résidu HVAC dans une copie temporaire de `building_solver.py`, confirmé que
`test_thermostat_mode_hvac_matches_residual_energy_balance` échoue alors — pas un test vide qui
passerait de toute façon.

Vérifié dans le conteneur backend rebuildé (`setup2.sh bilan-thermique --yes`, pas juste patché à
chaud) : `python manage.py test api` → 11/11 OK, `python manage.py check` → aucun problème.
Inclut aussi une couverture du Lot G (renouvellement d'air) manquante à sa livraison initiale :
`test_free_mode_air_node_conserves_energy_with_ventilation` étend l'identité de conservation avec
le terme `g_vent`, plus une non-régression (plus de ventilation ⇒ un bâtiment chaud se refroidit
davantage vers `t_ext`).

### Reste ouvert
Pas de CI qui lance `manage.py test` automatiquement (aucune app du lab n'en a — cohérent avec le
reste de `dev/`, hors scope de ce lot). Pas de test sur le mode `'realtime'` de l'ombrage
(`_assemble_F_hour` avec `occluder_intersector`) ni sur `geodata.py` (appels réseau, plus difficile à
tester unitairement — nécessiterait de mocker `requests`).

---

## Lot G — Renouvellement d'air / infiltrations ✅ livré le 2026-08-06

### Ce qui a été fait
Terme de ventilation ajouté des deux côtés, mais **pas avec la même donnée d'entrée** — le 1D et le
3D n'ont pas la même convention d'unités pour le nœud d'air (voir `c_air_int` : J/(m²·K) en 1D,
J/K absolu en 3D), la ventilation suit la même logique :

- **1D** (`solver.py`) : `interior.g_vent` (W/m²·K), une conductance déjà ramenée au m² de la paroi
  étudiée — cohérent avec `c_air_int`, pas un débit réel (le 1D n'a pas de volume de bâtiment).
  Appliquée uniquement en mode `'free'` (le seul avec un nœud d'air). `_assemble_F` prend
  `air_idx`/`g_vent` et ajoute `F[air_idx] += g_vent * t_ext` ; `K[air, air] += g_vent` posé une fois
  à l'assemblage.
- **3D** (`building_solver.py`) : `interior.debit_vent_m3h` (m³/h, tout le bâtiment) +
  `interior.eta_recup_vent` (0..1, rendement VMC double flux) — grandeurs physiques réelles, converties
  en `g_vent = 0.34 * debit_vent_m3h * (1 - eta_recup_vent)` (W/K absolu) et ajoutées **une seule fois**
  à `K_global[air_idx, air_idx]`, jamais par triangle. Appliqué en modes `'free'`/`'thermostat'`
  (les deux ont un nœud d'air réel) ; sans effet en `'imposed'` (Dirichlet écrase la ligne du nœud
  d'air — vérifié par test, `flux_positive_kwh`/`flux_negative_kwh` strictement identiques avec ou
  sans `debit_vent_m3h`).
- **Pas de conversion 1D→3D** : ce sont deux paramètres distincts, chacun cohérent avec son solveur —
  la ventilation n'est pas un phénomène de surface (contrairement aux parois), donc pas de facteur
  d'aire entre les deux.
- **Catalogue de profils par époque** (avant 1948, 1948-1974, 1974-2000 RT/VMC autoréglable, 2000-2012
  hygroréglable, RE2020 double flux) : `frontend/src/app/core/ventilation-profiles.ts`, **côté 3D
  uniquement** — un profil (taux vol/h + rendement) ne se combine à un débit réel qu'avec un volume de
  bâtiment réel, qui n'existe pas côté 1D. UI Calcul 3D : champ volume (m³) + sélecteur de profil qui
  pré-remplit débit/rendement, modifiables ensuite à la main.
- Vérifié en réel (conteneur backend, patché à chaud puis testé) : la ventilation accélère bien le
  refroidissement en 1D et en 3D, la récupération de chaleur réduit bien la perte nette sans
  l'annuler, le mode `'imposed'` est bien insensible à `debit_vent_m3h`.

### Reste ouvert
Test automatisé pérenne ajouté depuis (Lot F, `test_free_mode_air_node_conserves_energy_with_ventilation`).
Reste hors scope : pas d'affichage dans le dashboard de la part du besoin de chauffage imputable à
la ventilation (différence avec/sans `debit_vent_m3h`) — resterait utile pour que l'utilisateur juge
l'ordre de grandeur. `debit_vent_m3h`/`eta_recup_vent` restent des **constantes pour tout le run** —
voir Lot Q pour les faire varier heure par heure (planning d'occupation), au même titre que les
apports internes du Lot H.

---

## Lot H — Apports internes (occupants, éclairage, électroménager) ✅ livré le 2026-08-07

### Ce qui a été fait
`apports_internes_w` (W, défaut 0) ajouté à `BuildingInteriorSerializer` — 3D uniquement (comme
`debit_vent_m3h`/Lot G, un bâtiment a un volume réel, pas le 1D), injecté directement dans
`F[air_idx]` (`_assemble_F_hour`/`run_building_simulation`, `building_solver.py`) : puissance
directe (W), pas de multiplication par `t_ext` contrairement à `g_vent`. Actif en modes
`'free'`/`'thermostat'` uniquement — sans effet en `'imposed'` (Dirichlet écrase la ligne du nœud
d'air, même raisonnement que le Lot G, vérifié par test). UI Calcul 3D : champ « Apports internes
(W) » dans le bloc intérieur libre/thermostat. Documenté dans la page Théorie, section « Portée et
hypothèses » (paragraphe sur les deux termes que le solveur 3D ajoute au nœud d'air, absents du
bilan 1D d'une paroi isolée). Tests (`backend/api/tests.py`, classe
`BuildingAirNodeEnergyBalanceTest`) : identité de conservation d'énergie
`C_air·ΔT_air = Σ(flux + apports_internes_w)·dt` (mode `'free'`), non-régression (des apports
internes laissent un bâtiment plus chaud), et non-effet en mode `'imposed'`.

### Reste ouvert
Valeur constante pour tout le run — le besoin d'un profil horaire (planning d'occupation) est
confirmé et traité au **Lot Q**, qui généralise `apports_internes_w` ET `debit_vent_m3h`/
`eta_recup_vent` (Lot G) au même mécanisme de planning (même moteur physique : la présence
humaine). Lot Q peut démarrer maintenant que ce lot est livré.

---

## Lot I — Cadre de fenêtre (Uw, fraction de cadre) ✅ livré le 2026-08-07

### Ce qui a été fait
**Design différent de l'étape 2 d'origine, tranché avec l'utilisateur avant de coder** (voir
mémoire projet) : la formule `U_global` combinée en un résistor unique remplaçant tout le système
du triangle a été écartée — elle aurait perdu le calcul détaillé du gain solaire du vitrage (le
poste le plus important pour une fenêtre) sans que le texte d'origine ne dise ce qui le remplace.
Design retenu à la place : le maillage multicouche existant du vitrage garde sa physique complète
(gains solaires couche par couche, capacité) **sur l'aire réduite à `(1 - frame_fraction) * aire`**
— aucun changement à `_build_triangle_systems` ni à la forme de `paroi_layers_by_id` (le cadre est
passé séparément via `paroi_frame_by_id = {paroi_model_id: (frame_u, frame_fraction)}`, construit
dans `tasks.py`). Le cadre lui-même devient une **résistance directe extérieur → nœud d'air**,
exactement le même schéma que `g_vent` (Lot G) mais **par triangle** plutôt qu'un terme global
unique (des fenêtres différentes peuvent avoir des cadres différents) : conductance
`frame_fraction * frame_u * aire_triangle`, ajoutée à `K_global[air_idx,air_idx]`
(`_assemble_global_kc`) et à `F[air_idx]` heure par heure (`_assemble_F_hour`, réutilise le même
`t_boundary` que la paroi — donc `t_ground` si le triangle est aussi marqué `'ground'`, combo non
réaliste pour une fenêtre mais géré sans crash). Pas de nœud de surface propre pour le cadre : pas
de comportement optique, capacité négligeable — hypothèses du texte d'origine conservées, juste
réparties différemment. `frame_u` est interprété comme déjà inclusif des résistances superficielles
(comme Uf/Uw dans le vocabulaire fenêtre standard, cohérent avec Ug du catalogue — voir
`seed_paroi_catalogue.py`, calculé avec Rsi/Rse conventionnels).

`ParoiModel.frame_u`/`frame_fraction` (migration `0009`), les deux à renseigner ensemble ou ni l'un
ni l'autre (`ParoiModelSerializer.validate`). **`frame_fraction` plafonné à 0,95, pas 1,0**, piège
découvert en concevant les tests : à 1,0 l'aire "vitrage" tomberait exactement à zéro, annulant tout
le bloc du triangle dans la matrice globale (lignes nulles) → système singulier, `spla.splu`
échouerait. Garde-fou en double : plafond côté `ParoiModelSerializer` ET vérification directe dans
`run_building_simulation` (`BuildingSimulationError` explicite) pour tout appelant direct du solveur
qui contournerait le serializer. Catalogue de départ étendu (cadre PVC usuel, `frame_u` 2,0/1,8
W/m²·K pour simple/double vitrage, `frame_fraction` 0,25). **UI non prévue par le texte d'origine
mais ajoutée** (page « Bibliothèque de parois ») : sans elle, `frame_u`/`frame_fraction` n'auraient
été réglables que par appel API direct — case à cocher « a un cadre » + deux champs, affichage
récapitulatif dans la liste des modèles.

**Tests** (`backend/api/tests.py`, `WindowFrameTest`, 5 nouveaux — 48/48 au total) :
non-régression `frame_fraction=0`, conservation d'énergie généralisée (frame_fraction 0,3 et 0,9),
attribution par triangle (comparaison différentielle, pas une égalité stricte — voir piège
ci-dessous), validation `frame_fraction` invalide. Mutation testing : 2 mutations injectées, la
formule de conductance du cadre détectée immédiatement (test de conservation), **la réduction d'aire
du vitrage NON détectée du premier coup** — un vrai trou de couverture corrigé en cours de route
(voir mémoire projet pour le piège de conception qui l'a causé).

### Reste ouvert
Aucun.

---

## Lot J — Occultations mobiles (volets, stores) ✅ livré le 2026-08-09

### Ce qui a été fait
Cadré avec l'utilisateur avant de coder, sur deux échanges successifs : d'abord confirmation que le
patron de factorisation-par-combinaison-distincte (Lot Q/R) s'applique aussi ici pour éviter de
refactoriser heure par heure, puis fourniture de deux profils usuels concrets (valeurs indicatives,
pas une table réglementaire officielle — même esprit que le catalogue de parois) :

| | Volet roulant (PVC/alu) | Store extérieur (toile/brise-soleil) |
|---|---|---|
| ΔR ajoutée | 0,20 m²·K/W | 0,08 m²·K/W |
| Fs,dir (fermé) | 0,0 (opaque) | 0,15 |
| Fs,dif (fermé) | 0,0 | 0,40 |

Toujours **entièrement fermés** quand actifs — pas de position intermédiaire modélisée, comme
explicitement demandé.

**Design retenu, résolvant le dilemme des deux options d'origine** : ni un champ résistance globale
(option 1, imprécis — un seul volet pour tout le bâtiment) ni un second `ParoiModel` complet par
fenêtre fermée (option 2 littérale, qui aurait nécessité de recalculer `_build_triangle_systems`
heure par heure) — un dispositif est un **calque** (`shading_profile_id`, nouveau champ sur chaque
triangle, indépendant de `paroi_model_id`) appliqué PAR-DESSUS le vitrage existant : résistance
ajoutée en série avec `h_e` (`1/(1/h_e + deltaR)`, PAR TRIANGLE) et rayonnement réduit
(`e_dir *= fs_dir`, `e_dif *= fs_dif`) AVANT propagation dans `_propagate_solar`. `paroi_model_id`
et `_build_triangle_systems` restent totalement inchangés — aucune reconstruction de maillage,
seulement K/F modifiés au moment de l'assemblage, exactement comme le cadre de fenêtre (Lot I) ou
`g_vent` (Lot G).

**Restructuration de `building_solver.py`** : puisque `h_e` peut désormais varier PAR TRIANGLE (pas
seulement par heure comme au Lot R), le motif `K_e_pattern` du Lot R (scalaire `h_e * pattern`
précalculé une fois) ne suffit plus — remplacé par `_h_e_diagonal(h_e_vec, ...)`, qui construit la
contribution directement depuis un vecteur PAR TRIANGLE (uniforme = `h_e` de l'heure si aucun volet
fermé, réduit pour les seuls triangles concernés sinon). Coût O(nb triangles), négligeable devant la
factorisation elle-même — reconstruite seulement pour chaque combinaison DISTINCTE `(g_vent, h_e,
volets_fermes)` rencontrée, toujours paresseusement (Lot R). `volets_fermes` réutilise le `planning`
24h du Lot Q (`PlanningEntrySerializer.volets_fermes`) — **un seul planning pour toutes les fenêtres
à dispositif**, comme demandé, pas un planning par fenêtre. Contrairement à
`debit_vent_m3h`/`apports_internes_w`, s'applique dans **tous** les modes intérieurs (y compris
`'imposed'`) : `h_e` touche l'équation de chaque triangle, pas seulement le nœud d'air libre.

**Piège découvert empiriquement en écrivant les tests (avant tout bug réel), instructif** : un
premier test comparant un run « ouvert puis fermé » à un run « toujours ouvert », AVEC soleil, ne
détectait PAS une mutation qui retire `volets_fermes` de la clé de cache — parce que la réduction
optique (F, appliquée fraîchement chaque heure indépendamment du cache) suffisait à elle seule à
créer un écart, masquant l'absence de mise à jour du côté K (résistance). Corrigé en retirant tout
soleil du test : sans lui, le SEUL effet possible d'un volet fermé est la résistance ajoutée — un
bundle réutilisé à tort pour la mauvaise heure fait alors disparaître TOUT écart avec « toujours
ouvert » (vérifié par mutation : les deux scénarios deviennent bit-à-bit identiques). Même famille de
leçon que le piège du Lot R (une identité peut être aveugle à un bug situé dans une partie du système
qu'elle ne teste pas assez directement) mais sous une forme différente : ici il fallait ÉLIMINER un
canal (l'optique) pour isoler l'autre (la résistance), pas changer d'oracle.

**Backend** — champs ajoutés : `TriangleInputSerializer.shading_profile_id` (choix parmi
`building_solver.SHADING_PROFILES`, défaut `None`) ; `PlanningEntrySerializer.volets_fermes` (bool,
défaut `False`). **Piège du Lot K appliqué par anticipation** : `BuildingSerializer._build_envelope`
reconstruit les triangles existants lors d'un PATCH partiel (`triangles` absent) — `shading_profile_id`
ajouté explicitement à cette liste de reconstruction dès l'écriture du champ, pas découvert après
coup. `geometry.py` (pass-through générique par exclusion, pas par inclusion) n'a nécessité AUCUNE
modification — vérifié en le relisant plutôt que supposé.

**Frontend** : nouveau module d'affichage `shading-profiles.ts` (id/label/description SEULEMENT —
les valeurs physiques elles-mêmes vivent uniquement côté backend, un seul point de vérité). Page
Bâtiment : sélecteur d'occultation par groupe OBJ, même patron que l'assignation de paroi/condition
limite déjà en place. Page Calcul 3D : 4e colonne optionnelle du planning existant
(`volets_fermes`), et la condition qui limitait l'envoi du `planning` aux modes libre/thermostat a
été retirée (les 3 champs ventilation restent ignorés en mode imposé côté backend, mais
`volets_fermes` doit désormais passer dans tous les cas). **Écart UI assumé** : le panneau
« Planning horaire » reste visible seulement en modes libre/thermostat (même gating que le
renouvellement d'air) — un utilisateur en mode imposé ne peut donc pas configurer de volets depuis
l'UI, bien que l'API le permette (vérifié directement) ; cohérent avec le fait qu'aucun réglage
n'est exposé pour le mode imposé de toute façon (T_int fixée artificiellement, cas déjà secondaire
dans cette app).

**Tests** (`backend/api/tests.py`, `MovableShadingTest` + `TriangleShadingSerializerTest`, 17
nouveaux) : catalogue sain, formule série indépendante, volet roulant fermé ≡ h_e réduit à la main +
rayonnement nul (équivalence exacte), store extérieur ≡ identité de conservation étendue à un terme
calculé à la main (transmission partielle, pas nulle), deux triangles à dispositifs différents
divergent, effet en mode imposé confirmé, non-régression (triangle sans dispositif jamais affecté),
préservation lors d'un PATCH partiel (`_build_envelope` appelé directement sur une instance
`Building()` non sauvegardée — aucun accès DB, cohérent avec le reste de `tests.py`), validation des
deux nouveaux champs de serializer. Mutation testing : clé de cache (voir piège ci-dessus), formule
de résistance série, réduction optique — les 3 confirmées détectées après correction du test de
transition. 91/91 tests au total, `manage.py check` propre.

**Vérifié en réel de bout en bout sur l'image rebuildée**, via le chemin API public complet (pas
seulement `run_building_simulation` directement) : création d'un bâtiment avec un triangle vitrage
+ volet-roulant (`BuildingSerializer`), sauvegarde en base, rechargement, **PATCH partiel
(vertices seul) confirmant `shading_profile_id` survit** (piège du Lot K vérifié sur le vrai flux
DB, pas seulement l'instance non sauvegardée des tests), validation `BuildingCalculRequestSerializer`
avec un planning `volets_fermes`, puis simulation complète réussie. `ng build` propre.

### Reste ouvert
Orientation de la façade par rapport au vent toujours pas modélisée pour `h_e` de base (simplification
du Lot R, inchangée). Pas de planning volets par groupe/fenêtre (un seul planning global, comme
demandé — une évolution possible si le besoin apparaît). Pas d'indicateur visuel dans le viewer 3D
pour les triangles ayant un dispositif assigné (seul le compteur du groupe le confirme). Panneau
« Planning horaire » invisible en mode imposé (voir ci-dessus). Non vérifié en navigateur réel (même
réserve que les autres lots récents).

---

## Lot K — Triangles au contact du sol (dallage) ✅ livré le 2026-08-07

### Ce qui a été fait
Champ `boundary` sur `TriangleInputSerializer` : `'exterior_air'` (défaut, comportement historique
inchangé pour tout maillage existant) ou `'ground'`. Température de sol **constante fournie dans le
payload de calcul** (`t_ground`, `BuildingCalculRequestSerializer`, défaut 12°C — moyenne annuelle
usuelle en France) plutôt qu'un champ sur `Building` : reste modifiable d'un run à l'autre sans
éditer le bâtiment, pas de migration sur `Building`. `_assemble_F_hour`
(`building_solver.py`) : pour un triangle `'ground'`, `f_local[0] += h_e * t_ground` au lieu de
`h_e * t_ext` — même conductance `h_e` que les autres triangles (pas de `h_e` distinct pour le sol,
cf. étape 3 d'origine — extension possible, non faite). UI : sélecteur « Sol / Air extérieur » par
groupe OBJ sur la page Bâtiment (même patron que l'assignation de modèle de paroi par groupe),
champ « Température de sol » sur la page Calcul 3D. Piège corrigé au passage :
`BuildingSerializer._build_envelope` reconstruisait les triangles existants (chemin PATCH
« triangles seul ») en ne recopiant que `v`/`group`/`paroi_model_id` — `boundary` aurait été
silencieusement perdu à la moindre sauvegarde partielle sans le correctif.

Tests (`backend/api/tests.py`, `GroundBoundaryTest`) : identité EXACTE (pas une convergence) — un
triangle `'ground'` soumis à une météo `t_ext` très différente et variable doit reproduire au
chiffre près (1e-6) un mur 1D alimenté par une météo **constante** égale à `t_ground`, prouvant que
`t_ext` n'a strictement aucune influence sur ce triangle ; non-régression sur un triangle
`'exterior_air'` (jamais influencé par `t_ground`, quelle que soit sa valeur).

### Reste ouvert
`h_e` distinct pour un triangle au sol (pas de convection due au vent contre la terre) — extension
possible, non faite (voir étape 3 d'origine). Dérivation automatique de `t_ground` depuis la
moyenne annuelle de la météo — n'a de sens qu'une fois le Lot L (météo réelle) en place.

---

## Lot L — Import météo automatique (Open-Meteo Archive) ✅ livré le 2026-08-07

### Ce qui a été fait
Nouveau module pur `backend/api/weather_source.py` (même patron que `geodata.py`) :
**Open-Meteo Archive** retenu comme unique source (PVGIS TMY laissé de côté — voir Lot S, qui
reste la bonne occasion d'ajouter une seconde source « année type »). `temperature_2m`,
`direct_normal_irradiance`, `diffuse_radiation` → `t_ext`/`e_dir`/`e_dif` directement (mêmes
grandeurs physiques, DNI = irradiance normale au rayon = exactement ce que `e_dir*cos(theta_i)`
attend). Open-Meteo ne fournissant ni azimuth ni élévation, calcul de la **position solaire réelle**
heure par heure : déclinaison + équation du temps (séries de Fourier de Spencer 1971, la référence
usuelle — citée par NOAA et Duffie & Beckman), puis (élévation, azimuth réel) par un changement de
repère équatorial → horizon **dérivé à la main** (`_elevation_azimuth`) plutôt que la formule
`cos(azimuth)` usuelle des calculatrices solaires — dont la disambiguïsation de quadrant (signe de
l'angle horaire) est une source classique d'erreur de signe, piège concrètement rencontré pendant ce
lot (première version basée sur la formule usuelle donnait un azimuth de 0° au lieu de 180° à midi
solaire). Formule finale recoupée numériquement avec la bibliothèque tierce `astral` (installée
temporairement dans le conteneur pour vérification, jamais ajoutée aux dépendances de l'app) sur 7
cas latitudes/saisons/hémisphères variés : écart < 0,4° partout sauf singularité connue au zénith.

**Point d'attention critique traité** : `to_local_azimuth` applique très exactement la même
rotation que `geodata._rotate_xy` (même signe, même convention `Building.georef_north_offset_deg`),
appliquée à un vecteur direction plutôt qu'à un point. Vérifié à la main comme demandé (soleil plein
sud à midi solaire quand latitude > déclinaison — cas général de « soleil plein sud », pas
seulement à l'équinoxe) et par test automatisé avec rotation à 90° (voir tests). Azimuth déjà dans
la convention interne (`geometry.py`) en sortie de `build_weather_series` — aucune conversion
supplémentaire côté appelant.

Tâche Celery `fetch_weather` (même pattern que `generate_environment`) + **endpoint autonome**
`POST /api/meteo/recuperer/` (pas `/batiments/<id>/meteo/` — la météo n'est jamais persistée côté
serveur, seulement renvoyée via `job.result` ; un endpoint autonome fonctionne aussi pour un
bâtiment non géoréférencé, conforme à l'étape 4 d'origine). `WeatherFetchRequestSerializer` : dates
converties en chaînes ISO avant `Job.params`/`.delay()` — un `datetime.date` brut n'est pas
sérialisable JSON (piège rencontré et corrigé pendant ce lot). UI page Calcul 3D : panneau
« Récupérer depuis Open-Meteo » (lat/lon pré-remplies depuis le géoréférencement du bâtiment si
disponible, rotation nord, période) au-dessus du bloc météo constante ; CSV manuel et générateurs
synthétiques conservés mais annotés explicitement « donnée de démonstration » (étape 5).

Tests (`backend/api/tests.py`, 13 nouveaux — `SolarEphemerisTest`, `SolarElevationAzimuthTest`,
`LocalAzimuthRotationTest`, `WeatherSeriesAssemblyTest`) : déclinaison bornée par l'inclinaison de
l'axe terrestre (fait astronomique indépendant de la formule), midi solaire → azimuth exact
0°/180° selon signe(déclinaison-latitude) + élévation exacte `90-|lat-décl|` (identité dérivée à la
main), lever/coucher exactement Est/Ouest à l'équinoxe à 6 latitudes différentes, symétrie
temporelle autour de midi solaire, rotation locale (identité à offset nul + deux cas à 90°),
assemblage de série synthétique (clampe vers les bornes de `BuildingWeatherPointSerializer`, saute
les heures à donnée manquante sans en inventer). **`_assemble_weather_series` séparée de
`fetch_open_meteo_archive`** spécifiquement pour rendre l'assemblage testable sans réseau (suit la
même réserve que le Lot F pour `geodata.py`, tout en couvrant la partie qui ne nécessite pas de
mocker `requests`). Vérifié par mutation testing sur les deux formules les plus critiques
(`_elevation_azimuth` et `to_local_azimuth`) : échec confirmé sur code muté, 28/28 après
restauration. Vérifié en réel sur l'image rebuildée (`recompose_docker.sh --force`) : appel direct
à l'API Open-Meteo (curl + script Python dans le conteneur), pipeline complet
DRF → `Job` → Celery **via le vrai worker/Redis** (`.delay()`, pas seulement `.apply()` synchrone) →
résultat exploitable, et chemin d'erreur (date hors plage Open-Meteo) → `Job` en `ERROR` avec message
clair plutôt qu'un crash. `manage.py test` → 28/28, `manage.py check` → propre, `ng build
--configuration production` → propre.

### Reste ouvert
**PVGIS TMY** (année type) non ajouté — traité au Lot S, qui devient significativement plus simple
maintenant que `weather_source.py` existe (juste une seconde fonction de fetch produisant le même
format de sortie). `vent_m_s` (Lot R, livré depuis) est désormais demandé à Open-Meteo — voir la
section du Lot R pour le détail (`wind_speed_unit=ms` explicite, le défaut étant km/h).
Pas de vérification manuelle dans un navigateur (UI derrière Keycloak SSO, non testée en
interactif) — vérifié uniquement en API directe + build de production ; à tester en réel dans le
navigateur avant de recommander l'outil pour un vrai bâtiment.

---

## Lot M — Surface de référence et résultats normalisés (kWh/m²/an) ✅ livré le 2026-08-07

### Ce qui a été fait
`surface_ref_m2` (optionnel, saisie directe — pas de déduction automatique depuis les triangles de
plancher, qui aurait supposé le Lot K déjà exploité pour ça) ajouté à `Building`
(migration `0008_building_surface_ref_m2`), champ sur la page Bâtiment. Dashboard Calcul 3D :
tuiles « Chauffage normalisé »/« Climatisation normalisée » (`heating_kwh`/`cooling_kwh` divisés
par `surface_ref_m2`) à côté des valeurs brutes existantes, avec un message explicite invitant à
renseigner la surface si absente (plutôt que de masquer silencieusement la fonctionnalité). Repère
visuel : note textuelle sous les tuiles (RT2012 ≈ 50 kWh/m²/an, RE2020 plus strict), avec la
réserve explicite que ces seuils couvrent aussi ECS/éclairage/auxiliaires non modélisés ici — donc
une comparaison approximative, pas une certification.

### Reste ouvert
Repère visuel volontairement textuel (pas de jauge/couleur) — un raffinement graphique reste
possible mais non fait faute de temps dans ce lot.

---

## Lot N — Checklist de progression guidée (page Bâtiment) ✅ livré le 2026-08-08

### Ce qui a été fait
Checklist compacte affichée en haut de la page Bâtiment (`batiment.component.ts`, getter `checklist`)
dès qu'un bâtiment est chargé/créé — 4 items dérivés uniquement de l'état déjà présent côté client
(aucun nouvel endpoint, comme requis) : **parois assignées** (`assignedCount === totalCount`),
**géoréférencement** (`georefLat`/`georefLon` renseignés), **environnement lié**
(`selectedEnvironmentId`), **ombrage à jour** (`!sunVisibilityStale()`). Chaque item est un lien
(`<a href="#section-...">`) vers l'ancre de la section qui le résout sur la même page — trois nouveaux
`id` posés sur les blocs existants (`#section-georef`, `#section-ombrage`, `#section-assignation`),
pas de nouvelle UI dupliquée. Badge généralisé plutôt que dupliqué, comme demandé : l'ancien
`.stale-badge` (couleur `--warning`/`--warning-tint`, un seul état) devient `.status-badge` avec deux
variantes (`.done` → `--success`/`--success-tint`, `.todo` → l'ancien style inchangé) — l'usage
existant du badge ombrage (`sunVisibilityStale()`) a été migré vers cette classe généralisée plutôt
que d'en garder deux qui se ressemblent.

**Écart assumé par rapport au texte d'origine** : « météo chargée » listée comme 5ᵉ item n'a **aucun**
état persisté à observer — Lot L a délibérément choisi de ne jamais stocker la météo côté serveur
(`weather_source`, réponse renvoyée directement au client, jamais écrite sur `Building`), et la page
Bâtiment n'a de toute façon aucun accès à l'état local de la page Calcul 3D. Ajouter un état factice
aurait été trompeur (rien ne peut vraiment se « décocher » si l'utilisateur revient sur Calcul 3D sans
rien construire). Remplacé par un item non trackable en fin de liste — toujours affiché, jamais coché
— pointant vers Calcul 3D avec la mention explicite que cette étape n'est pas suivie ici. Item
« parois assignées » également sans lien d'ancre séparé menant ailleurs : sa résolution est déjà sur
cette même page, juste plus bas.

Vérifié sur l'image rebuildée (`recompose_docker.sh --app bilan-thermique --force`) : le chunk lazy
de la page Bâtiment contient bien le nouveau code (`grep checklist` sur le bundle nginx), build
Angular sans erreur (`ng build` fait partie du `docker build`, un échec de template aurait fait
échouer le build), `manage.py test` → 56/56 inchangé (lot purement frontend), `manage.py check`
propre. **Non vérifié en navigateur réel** — même réserve que Lots L/S/Q/T (app derrière Keycloak SSO,
non testée en interactif dans cette session).

### Reste ouvert
Pas de test frontend dédié (aucune infrastructure de test frontend dans cette app, cohérent avec les
lots précédents à UI pure — P, T). Pas d'ancre pour l'item « parois assignées » si aucun triangle n'est
encore importé (`#section-assignation` n'existe pas tant que `totalCount === 0`) — sans conséquence
(le lien est simplement sans effet, le hint textuel dit déjà « importez un maillage »).

---

## Lot O — Générateur de bâtiment simple (« boîte ») ✅ livré le 2026-08-08

### Ce qui a été fait
Nouveau module pur `frontend/src/app/core/box-generator.ts` (`generateBoxEnvelope`, même patron que
`mesh-import.ts` — aucune dépendance Angular/Django) : génère `vertices`/`triangles`/`groups`
directement côté client à partir de largeur/longueur/hauteur, sans endpoint dédié, comme prévu.
Groupes nommés automatiquement (`sol`, `mur_est`, `mur_ouest`, `mur_sud`, `mur_nord`, `toiture` ou
`toiture_est`/`toiture_ouest` en 2 pans) — l'assignation par groupe déjà en place sur la page Bâtiment
fonctionne immédiatement, aucune modification nécessaire là. `sol` est marqué `boundary: 'ground'`
(convention Lot K, déjà réutilisée par le Lot T) plutôt que `exterior_air`, cohérent avec toute autre
source de maillage de l'app. Nouveau bloc « Générer une boîte » sur la page Bâtiment
(`batiment.component.html`), juste après l'import de fichier, avec un rappel que l'import reste la
voie avancée pour une géométrie réelle (et un lien vers le mode simplifié du Lot T pour un bâtiment
réel existant) — le générateur n'est qu'un point d'entrée pédagogique/de test, comme spécifié.

**Point délicat traité avec soin, malgré une géométrie qualifiée de « triviale » par le texte
d'origine** : chaque triangle doit avoir une normale sortante correcte (`api.geometry` la déduit du
seul ordre des sommets — produit vectoriel) pour que l'ombrage/l'exposition solaire aient un sens
physique. L'ordre des sommets de chacun des 6 groupes (et des 2 groupes de pignon en toiture 2 pans)
a été dérivé à la main (produit vectoriel), puis **vérifié en réel** dans le conteneur backend en
appelant directement `api.geometry.compute_envelope_geometry` sur le maillage généré : tilt/azimuth
obtenus exactement conformes à la convention documentée dans `geometry.py` pour les deux variantes de
toiture (murs à tilt=90° et l'azimuth attendu par orientation ; toiture plate à tilt=0° ; toiture 2
pans à tilt≈20,6° pour une boîte 8×6×3 avec faîtage +1,5 m, azimuth 90°/270° pour les pans est/ouest ;
sol à tilt=180°, normale vers le bas) — et aires cohérentes avec la géométrie attendue (aire de pan
en 2 pans = longueur de rampant × largeur, rampant = √(4²+1,5²) ≈ 4,27 m). Round-trip complet vérifié
via `BuildingSerializer` (création réelle, `manage.py shell`) : 16 triangles, 7 groupes, `sol` bien
seul groupe marqué `ground`.

Toiture 2 pans : faîtage toujours orienté nord-sud (les murs est/ouest restent rectangulaires jusqu'à
l'égout, les murs nord/sud deviennent des pentagones portant le pignon) — un seul degré de liberté
d'orientation plutôt que deux, cohérent avec l'esprit « point d'entrée simple » du lot (une vraie
orientation de faîtage librement choisie aurait nécessité un paramètre de rotation supplémentaire,
hors scope).

Vérifié sur l'image rebuildée (`recompose_docker.sh --app bilan-thermique --force`) : chunk lazy de
la page Bâtiment contient bien le nouveau code, build Angular sans erreur, `manage.py test` → 56/56
inchangé (lot purement frontend), `manage.py check` propre.

### Reste ouvert
Pas de test automatisé dédié dans `tests.py` — `box-generator.ts` est un module frontend pur sans
infrastructure de test frontend dans cette app (même situation que Lots P/T), vérifié à la place par
appel réel à `api.geometry.compute_envelope_geometry` sur le maillage produit (voir ci-dessus).
Orientation du faîtage fixe (nord-sud) — toiture à 2 pans orientée est-ouest non couverte, hors scope
initial. Non vérifié en navigateur réel (même réserve que L/S/Q/N/T).

---

## Lot P — Aide au calcul de `c_air_int` ✅ livré le 2026-08-07

### Ce qui a été fait
Bouton « Calculer depuis le volume » à côté du champ `c_air_int` (page Calcul 3D) :
`c_air_int = round(volumeM3 * 1200)` (J/m³·K, capacité thermique volumique usuelle de l'air),
champ resté éditable ensuite. Réutilise **le champ `volumeM3` déjà existant** (bloc « Renouvellement
d'air », Lot G) plutôt qu'un champ dupliqué — c'est physiquement le même volume d'air du bâtiment
qui sert aux deux calculs. Pas de déduction depuis `surface_ref_m2` × hauteur sous plafond (option
mentionnée en note) : `volumeM3` saisi directement est suffisant et évite une hauteur sous plafond
supplémentaire à demander.

### Reste ouvert
Aucun test automatisé ajouté (calcul UI pur, une multiplication ; l'app n'a pas d'infrastructure de
test frontend existante — aucune autre page n'en a non plus, cohérent avec le reste du lab).
Vérifié par un build Angular de production propre (`ng build --configuration production`, aucune
erreur, seulement les warnings de budget SCSS déjà présents avant ce lot).

---

## Lot Q — Plannings horaires (ventilation + apports internes) ✅ livré le 2026-08-07

### Ce qui a été fait
**Décision de l'étape 1 confirmée telle que recommandée** : un seul profil « jour type » (24
valeurs, cyclique), pas de distinguo semaine/week-end — reste hors scope (nécessiterait une donnée
de calendrier, absente de `BuildingWeatherPointSerializer` même avec le Lot L livré entretemps :
une série météo reste une séquence d'heures sans date attachée).

`PlanningEntrySerializer` (`{debit_vent_m3h?, eta_recup_vent?, apports_internes_w?}`, mêmes bornes
que les champs constants équivalents) + `planning` (liste, `required=False`, validée à exactement 24
entrées via `validate_planning`) + `heure_debut` (0-23, défaut 0) sur
`BuildingCalculRequestSerializer`. Absent → comportement inchangé (constantes de `interior`).

**Point dur traité** (`building_solver.py`) : extraction de `_factorize_for_g_vent(K_global_no_vent,
C_global, air_idx, mode, g_vent)` — construit `K_global[air_idx,air_idx] += g_vent` puis factorise
(`spla.splu`, l'étape coûteuse) le(s) système(s) nécessaires au mode donné, retournés dans un dict
(`'imposed'` : solver+col_saved+dirichlet_row ; `'free'` : solver ; `'thermostat'` : solver+
pinned_solver+A_free+col_saved_pinned, pour le résidu HVAC). `run_building_simulation` calcule
`g_vent_by_slot`/`apports_by_slot` (24 valeurs) si `planning` fourni, sinon une seule constante comme
avant ; `bundles_by_g_vent = {g: _factorize_for_g_vent(...) for g in set(g_vent_by_slot)}` — une
factorisation par **valeur distincte**, jamais par heure simulée (24 au plus, souvent bien moins :
le test de conservation d'énergie du Lot Q exerce jusqu'à 12 valeurs distinctes sur 24 heures et
reste quasi-instantané). La boucle horaire sélectionne `bundle = bundles_by_g_vent[g_vent]` selon
`(heure_debut + hour_idx) % 24`. `apports_internes_w` par heure n'affecte que `F` (recalculé à
chaque heure de toute façon) — aucun problème de factorisation de ce côté, comme anticipé. Sans
effet en mode `'imposed'` (le planning n'y est simplement pas exploité), cohérent avec les
constantes qu'il remplace.

**UI** (page Calcul 3D) : case à cocher « Utiliser un planning horaire », qui révèle un champ
`heure_debut` + un textarea 24 lignes (`débit_m3h, eta_recup, apports_w`) + un bouton d'exemple
(profil résidentiel plausible, creux nocturne/pointes matin-soir, dérivé des constantes déjà
saisies). Les champs constants restent affichés et actifs comme point de départ — un planning est
une variation AUTOUR, pas un remplacement (conforme à l'étape 5 d'origine).

Tests (`backend/api/tests.py`, 7 nouveaux — `HourlyPlanningTest`, `PlanningSerializerTest`) :
identité EXACTE entre planning constant (24 entrées identiques) et constantes équivalentes, dans les
trois modes `'imposed'`/`'free'`/`'thermostat'` (non-régression sur le nouveau mécanisme de bundles) ;
`heure_debut` sélectionne bien le bon index dès `hour_idx=0` ; identité de conservation d'énergie
généralisée à un `g_vent`/`apports_internes_w` variable heure par heure (même famille que Lot F/G,
avec un planning exerçant réellement plusieurs bundles distincts) ; `'imposed'` ignore le planning ;
validation stricte à 24 entrées. Mutation testing sur la sélection de slot (`heure_debut`) et sur la
sélection de bundle (forcer l'usage d'un seul bundle peu importe `g_vent`) : échec confirmé dans les
deux cas, 43/43 après restauration. Vérifié en réel sur l'image rebuildée via le pipeline DRF →
`validated_data` → `run_building_simulation` complet (payload avec planning variable + `heure_debut`
non nul).

---

## Lot R — Coefficient de convection extérieure dynamique (h_e) ✅ livré le 2026-08-08

### Ce qui a été fait
Cadré avec l'utilisateur avant de coder (`AskUserQuestion`, deux questions) : formule **Jürges**
(`h_e = 5,8 + 3,94·v`, retenue plutôt que McAdams comme pressenti — plus couramment citée en physique
du bâtiment française) et **portée étendue** aux deux volets prévus (h_e dynamique ET h_i par
orientation dans le même lot, plutôt que h_e seul).

**Le « point dur » performance a été mesuré empiriquement AVANT de coder, pas supposé** : appels curl
réels à Open-Meteo Archive sur une année complète (2023) à Paris et à Brest (côte venteuse, cas
défavorable) — le vent arrondi au m/s le plus proche ne donne que **14 à 21 valeurs distinctes** sur
8760 heures, largement dans l'ordre de grandeur déjà géré par le Lot Q (24 valeurs). Combiné à un
planning de ventilation (Lot Q) à 24 valeurs toutes distinctes (pire cas), le nombre de paires
(heure_du_jour, classe_vent) réellement rencontrées sur une année reste **272-338** — mesuré, pas
supposé. Benchmark réel d'une factorisation LU sur un bâtiment de taille réaliste (768 triangles,
8449 DOF) : ~0,09 s chacune, donc ~30 s pour le pire cas mesuré — largement absorbable sur le worker
`--concurrency=1` du lab. Le texte d'origine anticipait ce point comme bloquant ; la mesure a montré
qu'il ne l'était pas, avec la même discrétisation (arrondi au m/s) déjà envisagée.

**Restructuration de `building_solver.py`** : `h_e` (vent, varie par HEURE) et `h_i` (orientation,
varie par TRIANGLE mais jamais dans le temps) ne peuvent plus être bakés une fois pour toutes dans
`_build_triangle_systems` comme avant (Lots F→Q) — désormais construite « nue » (juste K/C par unité
de surface du mur, cache purement `(paroi_model_id, dx_max)`). `_assemble_global_kc` pose maintenant
`h_i_list` (une valeur par triangle) et retourne en plus `K_e_pattern` : la sensibilité de K à `h_e`
est **linéaire** (`+area_i` sur la diagonale du nœud extérieur de chaque triangle), donc
`K_global(h_e) = K_global_base + h_e * K_e_pattern` — pas besoin de reconstruire toute la matrice par
valeur de `h_e`, juste une addition creuse bon marché. `_factorize_for_g_vent` généralisé en
`_factorize_for(..., g_vent, h_e)`, appelé **paresseusement** (au premier usage, mis en cache) pour
chaque combinaison `(g_vent, h_e)` RÉELLEMENT rencontrée pendant le run plutôt que le produit
cartésien complet à l'avance — optimisation naturelle une fois la structure en place.
`MAX_DISTINCT_BOUNDARY_COMBOS = 2000` en garde-fou (marge ~6x au-delà du pire cas mesuré).

**h_e dynamique** (`payload.h_e_dynamic`, optionnel, défaut False) : dérive `h_e` heure par heure de
`weather[h].wind_m_s` (nouveau champ optionnel, `BuildingWeatherPointSerializer`) via
`h_e_from_wind` — vent arrondi au m/s AVANT la formule (c'est cet arrondi, pas la formule
elle-même, qui borne le nombre de valeurs distinctes). Si activé, chaque point météo DOIT porter
`wind_m_s` (validé côté serializer ET défensivement dans `run_building_simulation`, appelable
directement). `h_e` (constante) reste requis dans le payload mais simplement ignoré si actif — pas
d'exigence conditionnelle pour un gain marginal.

**h_i par orientation** (`payload.interior.h_i_auto`, optionnel, défaut False) : dérive `h_i` de
`tilt_deg` (déjà calculé par `api.geometry`) via `h_i_from_tilt` — classification ISO 6946 par TYPE
d'élément (murs tilt∈]60°,120°[ → 7,7 ; toiture/plafond tilt≤60° → 10,0, flux montant ; sol/plancher
tilt≥120° → 5,9, flux descendant), pas par le signe instantané du flux à un instant donné (comme la
norme elle-même) — cohérent avec le fait que `h_i` n'a jamais varié dans le temps dans ce solveur,
seulement, désormais, d'un triangle à l'autre. `h_i` (constante) devient optionnel si `h_i_auto` est
actif (sinon requis comme avant).

**Météo** : `weather_source.py` demande désormais `wind_speed_10m` (Open-Meteo, avec
`wind_speed_unit=ms` explicite — le défaut est km/h) et lit `WS10m` (PVGIS TMY, déjà nativement en
m/s) — vérifié en réel que les deux sources sont bien normalisées en m/s sans conversion
supplémentaire nécessaire. Une heure sans vent (bord de couverture) n'annule PAS l'heure entière
(contrairement à t_ext/e_dir/e_dif) : `h_e_dynamic` devient simplement inutilisable pour cette heure
précise si le payload l'exige, sans dégrader le reste du bilan.

**Frontend** (`Calcul3DComponent`) : case à cocher « h_e dynamique » (désactive le champ constant) et
« h_i par orientation » (idem), symétriques. CSV météo étendu à une 6e colonne optionnelle
(`vent_m_s`) — déjà remplie automatiquement par le fetch Lot L/S (le backend renvoie maintenant
`wind_m_s` par point), modifiable à la main sinon. Garde-fou côté UI (`weatherMissingWind`) qui
bloque le bouton de lancement tant qu'une heure manque de vent alors que le mode dynamique est actif,
plutôt que de laisser échouer la requête.

**Tests** (`backend/api/tests.py`, `DynamicConvectionTest` + `BuildingCalculRequestSerializerWindTest`,
14 nouveaux) : formules pures (`h_e_from_wind`, `h_i_from_tilt`, bornes de bucket incluses/exclues),
équivalence dynamique-avec-vent-constant ≡ constant-avec-h_e-manuel (oracle direct), arrondi du vent
avant Jürges, validation (vent manquant → erreur), non-régression (comportement par défaut inchangé
sans les deux nouveaux flags). **Piège identifié en écrivant les tests, avant tout bug réel — le plus
instructif du lot** : une identité de conservation d'énergie (même famille que Lots F/Q) est
**tautologique vis-à-vis de K** — elle re-dérive la ligne du nœud d'air du système linéaire
RÉELLEMENT résolu, quel que soit le contenu de K, donc elle est satisfaite par construction même si
un bundle est réutilisé à tort pour le mauvais `h_e` (confirmé par mutation : retirer `h_e` de la clé
de cache du bundle laisse ce test intact). Remplacé par un test comparant à un oracle **indépendant du
système résolu** (formule U(h_e) en régime permanent, méthode de `WallSteadyStateTest`) : vent
constant sur une longue phase, puis vent constant DIFFÉRENT sur une seconde phase assez longue pour
reconverger — le flux final doit correspondre au NOUVEAU h_e. Ce test-ci détecte bien la mutation
(vérifié). Mutation testing complet : formule de Jürges (signe), buckets `h_i_from_tilt` (permutés),
arrondi du vent (retiré), clé de cache du bundle (h_e retiré) — les 4 confirmées détectées après
correction, aucune non détectée en survivant. 70/70 tests, `manage.py check` propre.

**Vérifié en réel de bout en bout sur l'image rebuildée** : fetch réseau réel Open-Meteo (Paris, vent
présent sur 100% des points) → validation `BuildingCalculRequestSerializer` avec `h_e_dynamic` ET
`h_i_auto` actifs simultanément → simulation réelle (boîte 8×6×3, maillage réaliste, mode thermostat)
aboutissant à un résultat physique cohérent. `ng build` propre.

### Reste ouvert
Orientation de la façade par rapport à la direction du vent (face au vent / sous le vent) non
modélisée — une seule valeur de `h_e` pour tout le bâtiment à une heure donnée, simplification
assumée dès le cadrage, pas un oubli. Non vérifié en navigateur réel (même réserve que L/S/Q/N/T).

---

## Lot S — Années type (TMY) ✅ livré le 2026-08-07

### Ce qui a été fait
**PVGIS TMY** (`re.jrc.ec.europa.eu/api/v5_2/tmy`, JRC — Commission européenne, gratuite, sans clé)
ajouté à `backend/api/weather_source.py` (créé au Lot L) : `fetch_pvgis_tmy` + `_assemble_tmy_series`
(partie pure, testable sans réseau) + `build_tmy_series` (sans repli) + `build_tmy_or_fallback_series`
(point d'entrée principal, avec repli). `Gb(n)`/`Gd(h)` de la réponse PVGIS sont EXACTEMENT les mêmes
grandeurs physiques que `direct_normal_irradiance`/`diffuse_radiation` d'Open-Meteo (irradiance directe
normale au rayon / diffuse horizontale) → `e_dir`/`e_dif` directement. La position solaire (module déjà
écrit au Lot L) s'applique telle quelle : refactor `_enrich_hour`, extrait de
`_assemble_weather_series`, partagé par les deux sources — seul le parsing du format brut change d'une
source à l'autre (Open-Meteo : tableaux parallèles + timestamp ISO ; PVGIS : un tableau de dicts par
heure + timestamp `'YYYYMMDD:HHMM'`, `_parse_pvgis_timestamp`).

**Couverture PVGIS vérifiée en réel** (pas seulement documentée) : Paris/New York/Australie centrale
couverts (SARAH2/NSRDB/ERA5 selon la zone, confirmant la note d'origine) ; Pacifique, Svalbard (arctique)
et pôle Sud renvoient tous le **même message générique** `"Location over the sea"` malgré le fait que
Svalbard/pôle Sud soient des terres — PVGIS ne distingue pas "vraiment en mer" de "zone polaire non
couverte" dans son message d'erreur, `fetch_pvgis_tmy` ne cherche donc pas à interpréter ce message,
il déclenche simplement le repli sur toute erreur PVGIS (coverage ou transitoire). Pas de bbox de
couverture précalculée façon `geodata.is_in_france()` : PVGIS renvoie lui-même clairement si la zone
est couverte, un test try/except suffit, plus simple que le Lot L ne l'anticipait.

**Choix explicite côté UI** : `WeatherFetchRequestSerializer.source` (`'archive'` par défaut = Lot L
inchangé, `'tmy'` = Lot S) ; toggle sur la page Calcul 3D entre « Année type (PVGIS TMY) » et « Année
réelle datée (Open-Meteo) », avec les dates existantes réutilisées comme **repli uniquement** en mode
TMY (pas de champ dupliqué, pas de validation conditionnelle côté serializer — toujours requises, sans
effet si PVGIS répond). **Source annotée à deux endroits distincts** (to_do.md étape 3) : dans le
panneau météo dès la récupération (`weatherSourceLabel`, y compris le message de repli s'il a eu lieu),
et **séparément** dans le dashboard de résultats (`submittedWeatherSourceLabel`, capturée au moment du
clic « Lancer le calcul » plutôt que relue en direct — si l'utilisateur recharge une autre météo pendant
qu'un calcul tourne, le dashboard doit continuer à refléter la source qui a vraiment produit ce
résultat, pas celle actuellement dans le formulaire).

Tests (`backend/api/tests.py`, 8 nouveaux — `PvgisTimestampTest`, `TmySeriesAssemblyTest`,
`TmyFallbackTest`) : parsing du format de timestamp PVGIS, assemblage synthétique (mêmes vérifications
de clamping/heures manquantes que Lot L, format brut différent), et **branchement du repli mocké**
(`unittest.mock.patch.object` sur `build_tmy_series`/`build_weather_series` — première utilisation de
mock dans ce fichier de tests, pour isoler la logique de branchement du réseau réel, déjà couvert par
la vérification en direct). Mutation testing sur le retour `'pvgis-tmy'` du chemin succès : échec
confirmé, 36/36 après restauration. Vérifié en réel sur l'image rebuildée : Paris en mode TMY → 8760
heures `source: pvgis-tmy` ; océan Pacifique en mode TMY → repli automatique vers Open-Meteo Archive
avec avertissement clair, via le vrai worker Celery/Redis.

### Reste ouvert
`vent_m_s` (Lot R, livré depuis) est désormais lu depuis `WS10m` — vérifié en réel : PVGIS l'exprime
nativement en m/s, comme Open-Meteo avec `wind_speed_unit=ms`, aucune conversion nécessaire (voir la
section du Lot R). Pas de vérification dans un navigateur réel (même réserve qu'au Lot L).

---

## Lot T — Mode simplifié pour un bâtiment existant (recherche + taux de vitrage, pédagogique) ✅ livré le 2026-08-08

### Ce qui a été fait
Spécifié par l'utilisateur en 4 étapes (2026-08-07), implémenté le lendemain. Les deux décisions
« à trancher avant de coder » ont été résolues sans nécessiter de cadrage utilisateur :

- **Regroupement par mur** : `trimesh.creation.extrude_polygon` a en réalité un ordre de faces
  parfaitement déterministe (vérifié empiriquement sur un rectangle N=4 et un polygone en L non
  convexe N=6), même si non documenté par trimesh — pour une empreinte à N sommets, les N-2
  premières faces triangulent le sol, les N-2 suivantes le toit, puis exactement 2 triangles par
  arête dans l'ordre des arêtes. `geodata.extrude_footprint_grouped` exploite ce fait directement
  (avec une vérification de structure qui échoue bruyamment si jamais trimesh changeait de
  comportement) — pas besoin d'extruder côté par côté à la main comme l'étape 2 d'origine
  l'envisageait.
- **Distinction vitrage/opaque** : `ParoiModel.is_glazing` (booléen explicite, migration `0010`)
  plutôt qu'une heuristique sur les couches, comme pressenti.

**Découverte en réel non anticipée par le cadrage d'origine** : une empreinte IGN en zone urbaine
dense peut avoir des centaines de sommets (515 murs observés en plein Paris — un pâté de maisons
digitalisé comme un seul bâtiment complexe), inutilisable pour une configuration paroi par paroi.
`MAX_WALLS_SIMPLIFIED_MODE = 30` : `geodata.search_nearby_buildings` écarte silencieusement les
candidats trop complexes (comptés dans `n_skipped_too_complex`, affiché à l'utilisateur) plutôt que
de produire une UI à des centaines de menus déroulants — une zone pavillonnaire donne typiquement
4-26 murs, largement dans la limite.

**Deuxième découverte en réel, plus structurante** : `geometry.refine_envelope` (Lot raffinement de
maillage, existant) propage la subdivision à tout le maillage connecté par arêtes partagées — un
volume extrudé étanche (murs soudés au sol et au toit) ne permet donc PAS de raffiner finement les
murs sans que ça cascade vers le sol/la toiture. Un premier essai à 0,6 m de finesse a produit
16 384 triangles pour un petit pavillon à 5 murs (bien au-delà de ce que le solveur peut absorber
une fois chaque triangle maillé en profondeur — `MAX_TOTAL_DOF` aurait été dépassé). Testé
empiriquement plusieurs valeurs : 2,0 m donne ~128 triangles/mur (1024 au total pour ce même
bâtiment), largement assez fin pour un taux de vitrage à quelques % près, avec une marge
confortable — retenu comme défaut. Pas de raffinement séparé par groupe (aurait nécessité de
désolidariser les groupes en dupliquant les sommets aux jonctions, hors scope de cette V1).

**Étape météo simplifiée par réutilisation** : plutôt que d'intégrer un panneau météo dans
l'assistant, la dernière étape redirige vers la page Calcul 3D — celle-ci pré-remplit déjà
automatiquement `weatherFetchLat/Lon/NorthOffset` depuis `Building.georef_lat/lon/north_offset_deg`
(mécanisme du Lot L), donc un bâtiment créé par ce mode simplifié a sa météo déjà prête à récupérer
sans code supplémentaire — il suffit à l'utilisateur de choisir l'année.

**Entrée simplifiée ajoutée après coup (même jour, sur demande utilisateur) : renouvellement d'air.**
Même schéma de préremplissage que la météo, généralisé : `Building.suggested_debit_vent_m3h`/
`suggested_eta_recup_vent` (migration `0011`, nouveaux champs nullable, jamais lus par le solveur —
une SUGGESTION uniquement) sont calculés à l'étape 2 de l'assistant à partir d'un profil du catalogue
existant `ventilation-profiles.ts` (déjà utilisé par Calcul 3D, Lot G) appliqué au volume RÉEL du
bâtiment — empreinte (aire des triangles du groupe `sol`) × hauteur, calculé côté client depuis la
géométrie déjà récupérée, plus précis que la saisie manuelle du volume sur Calcul 3D. Repris par
`Calcul3DComponent.onBuildingChange` au chargement du bâtiment pour préremplir `debitVentM3h`/
`etaRecupVent`, exactement comme `georef_lat/lon` préremplit déjà le panneau météo — les deux champs
restent modifiables ensuite sur Calcul 3D comme pour tout bâtiment. Optionnel : aucun profil choisi
⇒ aucune suggestion envoyée, comportement inchangé pour un bâtiment créé sans passer par ce mode.
Vérifié en réel (round-trip serializer + bornes de validation, dans le conteneur rebuildé) plutôt
qu'ajouté aux tests automatisés du module `tests.py` — ce fichier est explicitement sans accès DB
(`SimpleTestCase` partout, voir son docstring) et ces deux champs sont de purs passe-plats
(`FloatField` sans logique propre) comme `georef_lat`/`surface_ref_m2`, qui n'ont eux non plus jamais
eu de test dédié.

**Backend** : `geodata.extrude_footprint_grouped` (triangles `{'v','group','boundary'}`, sol marqué
`boundary='ground'` — Lot K — puisqu'un plancher bas issu d'une empreinte réelle touche le terrain
par construction) + `geodata.search_nearby_buildings` (recherche, tri par distance existant réutilisé,
extrusion de chaque candidat au moment de la recherche pour éviter un second aller-retour réseau une
fois choisi) ; endpoint autonome et **synchrone** `POST /api/batiments/rechercher/`
(`SearchNearbyBuildingsView`/`SearchNearbyBuildingsRequestSerializer`, rayon plafonné à 150 m — pas
de Celery, contrairement à la génération d'environnement, le rayon volontairement petit rend l'appel
assez rapide). **Aucun nouvel endpoint de création** : le mesh extrudé d'un candidat est directement
consommable par `POST /api/batiments/` existant (`BuildingSerializer` accepte déjà `group`/`boundary`
par triangle) — vérifié en réel.

**Frontend** : nouvelle page `/mode-simplifie` (assistant à 4 étapes, lazy-loaded comme
Bâtiment/Environnement/Calcul 3D), lien de nav Foyer ajouté. Étape 3 (assignation proportionnelle)
entièrement côté client : pour chaque paroi configurée, tous les triangles reçoivent le modèle
opaque, puis un triangle sur N (N = arrondi de 1/taux) est réassigné au modèle vitrage — motif
régulier plutôt qu'aléatoire, comme décidé. Aperçu 3D coloré (vitrage/opaque/non assigné) via le
`mesh-viewer` déjà utilisé ailleurs.

**Tests** (`backend/api/tests.py`, 8 nouveaux — `ExtrudeFootprintGroupedTest`,
`SearchNearbyBuildingsSerializerTest`) : structure de faces figée (rectangle + polygone en L),
oracle indépendant du comptage de groupes (sol/toiture aux bonnes élévations z), intégration avec
`compute_envelope_geometry`, validation du serializer de recherche. `search_nearby_buildings`
lui-même (réseau) vérifié uniquement en réel, comme les autres fonctions réseau de `geodata.py`
(même réserve que Lot F pour ce module). Mutation testing sur l'arithmétique d'indices de faces :
échec confirmé. **Pipeline complet vérifié en réel de bout en bout sur l'image rebuildée** :
recherche (bâtiment réel, zone pavillonnaire) → création → subdivision (1024 triangles) →
assignation proportionnelle (130 triangles vitrage / 1024, ≈12,7 % pondéré sol+toiture+murs
inclus) → sauvegarde → **calcul thermique réel réussi** sur le bâtiment ainsi produit.
`manage.py test` → 56/56, `manage.py check` → propre, `ng build --configuration production` →
propre.

### Reste ouvert
Génération automatique d'un environnement voisin (Lot C existant, `generate_environment_for_building`)
non incluse dans l'assistant — l'utilisateur peut l'ajouter ensuite depuis la page Bâtiment, le
mécanisme existe déjà entièrement. Toiture non plane (pans, faîtage) hors scope — toiture plate,
cohérent avec `extrude_footprint`/`extrude_footprint_grouped`. Pas de raffinement différencié par
groupe (voir découverte ci-dessus) — un bâtiment avec une très grande façade et une très petite
pourrait avoir une précision de taux de vitrage inégale entre les deux à finesse de subdivision
égale. Pas de vérification dans un navigateur réel (même réserve que Lots L/S).

---

## Lot U — Correctif : rayonnement transmis intégralement à travers un vitrage ✅ livré le 2026-08-08

### Constat
Signalé par l'utilisateur : ses tests 1D sur des fenêtres montraient les nœuds du vitrage chauffant
toujours plus vite que l'air intérieur, même en réduisant `c_air_int` — alors que la lumière qui
traverse une fenêtre devrait au contraire chauffer l'air directement, donc plus vite que le vitrage
à `c_air_int` faible.

### Ce qui a été fait
Bug réel trouvé dans `solver._propagate_solar` (module partagé, réutilisé tel quel par
`building_solver.py` — **identique en 1D et 3D**) : à chaque couche translucide (τ &gt; 0), une
fraction `alpha·e_inc` est absorbée (chauffe la couche) et le reliquat `tau·e_inc` continue vers la
couche suivante. Le cas déjà géré et documenté (page Théorie, section 05) est le **mur Trombe** — une
couche translucide toujours suivie d'une couche opaque qui arrête tout et absorbe le reliquat. Mais
**rien ne gérait le cas où TOUTES les couches sont translucides** (pas de couche opaque en fond) :
à la fin de la boucle, le reliquat qui a traversé la DERNIÈRE couche était silencieusement perdu — ni
sur un nœud de la paroi, ni sur le nœud d'air. Or c'est exactement la structure de **tout le
catalogue de vitrages actuel** (`VITRAGE_SIMPLE` : 1 couche τ=0,87 ; `VITRAGE_DOUBLE` : 3 couches
τ=0,88/0,97/0,88) — pour ces valeurs, 87 % (simple) à 75 % (double) du rayonnement solaire incident
disparaissait purement et simplement du bilan, sur tout calcul avec vitrage fait jusqu'ici. Les nœuds
du vitrage chauffaient bien un peu (la petite fraction absorbée, ~6 % par vitre), mais l'air ne
recevait AUCUN gain solaire direct — seulement une conduction lente via `h_i`, insensible à
`c_air_int` puisqu'aucun grand terme ne l'alimente : exactement le symptôme rapporté.

**Correctif** : `_propagate_solar` détecte désormais (via `for...else` sur la boucle des couches — le
`else` ne s'exécute que si aucun `break` n'a eu lieu, donc jamais de couche opaque rencontrée) le cas
où le rayonnement a traversé toute la paroi sans être arrêté, et retourne une source supplémentaire
`('interior', None, énergie_W_par_m2)`. `solver._assemble_F` (1D) et `building_solver._assemble_F_hour`
(3D) l'ajoutent directement à `F[air_idx]` — même convention que le renouvellement d'air/apports
internes déjà en place (Lots G/H) : actif en cas 2 (nœud d'air libre), sans effet en cas 1 (T_int
imposée, 1D n'a même pas de nœud d'air dans ce mode) ni en mode `'imposed'` 3D (Dirichlet absorbe le
terme, comme pour `g_vent`/`apports_internes_w`). Non-régression stricte du mur Trombe (couche
translucide + couche opaque) et du mur opaque simple, vérifiée explicitement par test.

**Tests** (`backend/api/tests.py`, `TransmittedSolarGainTest`, 8 nouveaux) : formules pures (oracle
= produit des τ des couches successives, calculé à la main, indépendant de `_propagate_solar`),
non-régression mur opaque/mur Trombe, intégration 1D et 3D (identité de conservation d'énergie
étendue au nouveau terme — légitime ici, contrairement au piège du Lot R : le bug visé est dans **F**,
pas dans **K**, donc l'identité n'est pas tautologique, elle re-dérive `e_interior` à la main plutôt
que d'appeler `_propagate_solar`), et un test reproduisant directement le symptôme rapporté
(`c_air_int` faible → l'air chauffe désormais plus vite que le vitrage). Mutation testing sur les
trois points de correction (le `for...else` lui-même, le consommateur 1D, le consommateur 3D) : les
trois confirmées détectées, exactement les 5 tests concernés échouant à chaque fois (les 3 tests de
non-régression restant verts, comme attendu). 78/78 tests au total, `manage.py check` propre.

**Documentation** : page Théorie (section 05) complétée avec un troisième paragraphe couvrant ce cas
« aucune couche opaque », symétrique au terme de renouvellement d'air déjà documenté.

Vérifié en réel dans le conteneur (avant et après le correctif) avec les valeurs réelles du
catalogue : `c_air_int` faible → l'air atteint désormais 137°C après quelques heures pendant que le
vitrage reste à ~44°C, conforme à l'intuition physique de l'utilisateur.

### Reste ouvert
Pas de vérification en navigateur réel (même réserve que les autres lots récents).

---

## Lot V — Calendrier d'occupation (mode thermostat) ✅ livré le 2026-08-09

### Constat
Le mode thermostat (Lot précédent à celui-ci dans la conversation, pas un lot numéroté) n'avait
que deux constantes `t_min`/`t_max` pour tout le run — aucun moyen d'exprimer qu'un bâtiment
scolaire tombe en hors-gel pendant les vacances et le week-end, qu'un bureau se réduit la nuit, ou
qu'un logement n'a pas cette notion de fermeture. L'utilisateur a demandé de définir ces plages par
jour et par heure, avec quatre profils d'usage détaillés (scolaire, scolaire climatisé, tertiaire,
tertiaire climatisé) et deux profils supplémentaires proposés pour l'habitation.

**Cadrage** : la question clé, soulevée par l'utilisateur avant tout code, était de savoir si les
occultations mobiles (Lot J) avaient déjà établi un précédent d'équation-par-configuration pour
éviter de réinverser la factorisation heure par heure — non applicable ici puisque `t_min`/`t_max`
n'entrent **jamais dans K** (seulement dans la décision de pincement du second membre F, comme
`g_vent`/`apports_internes_w`), donc aucun souci de factorisation à anticiper, contrairement au
calque de Lot J. Un aller-retour de cadrage a corrigé ma première lecture du besoin : le hors-gel
« vacances » est un concept **propre au scolaire** (jamais au tertiaire, climatisé ou non) et
s'applique **également aux deux variantes scolaires** — confirmé explicitement par l'utilisateur
avant implémentation. Sur un jour classé hors-gel ou week-end entier, la consigne résultante
remplace les 24 heures de ce jour (pas de sous-distinction jour/nuit ce jour-là) ; le cycle
jour/nuit (19°C/16°C, frontière 7h-19h — même convention que l'exemple de planning du Lot Q) ne
s'applique que sur les jours normaux — confirmé également.

### Ce qui a été fait
**Backend** (`building_solver.py`) : chaque point météo peut désormais porter `t_min`/`t_max`
optionnels (`BuildingWeatherPointSerializer`, `FloatField(required=False, allow_null=True,
default=None)` — même modèle que `wind_m_s` du Lot R). En mode thermostat, l'heure courante utilise
ces valeurs si fournies, sinon replie sur les constantes du run (`interior.t_min`/`t_max`). Piège
DRF retrouvé et corrigé **avant** tout bug utilisateur (vérifié empiriquement en shell Django avant
d'écrire le code définitif) : `default=None` rend la clé **toujours présente** dans
`validated_data` avec la valeur `None` quand rien n'est fourni — un `point.get('t_min',
repli)` ne retombe alors **jamais** sur le repli (`.get()` ne consulte le défaut que si la clé est
absente, pas si sa valeur est `None`), ce qui aurait fait planter tout calcul thermostat en
production dès qu'un point réel passait par le serializer (`t_air < None` → `TypeError`). Corrigé
avec un test explicite (`is not None`), même convention déjà en place pour `wind_m_s` (Lot R).
Aucun changement de factorisation requis (contrairement à g_vent/h_e/volets_fermes) — confirmé par
le cadrage puis par l'implémentation elle-même : `t_min`/`t_max` ne touchent que la décision de
pincement du second membre, jamais `K_global`.

**Frontend** — nouveau catalogue `core/usage-profiles.ts` (résolu entièrement côté client, même
patron que `ventilation-profiles.ts`/`shading-profiles.ts` : le backend ne reçoit que deux nombres
optionnels par heure, jamais d'identifiant de profil ni de date calendaire). Six profils
(`UsageProfile[]`) : `scolaire`/`scolaire-clim` (hors-gel 7°C vacances+week-end, réduit 16°C la
nuit, normal 19°C/100°C ou 19°C/26°C le jour), `tertiaire`/`tertiaire-clim` (hors-gel week-end
seulement, jamais lié aux vacances), `habitation`/`habitation-clim` (aucune notion de fermeture,
seul le cycle jour/nuit 19°C/16°C compte). `OccupationCalendar` (jour de la semaine du premier
point météo, 7 booléens jours ouvrés, liste de plages de vacances en **indice de jour relatif au
début du run** — jamais de vraie date, cohérent avec le fait qu'aucun concept de date calendaire
n'existe ailleurs dans le solveur, seulement des séquences horaires pures, valable aussi bien pour
des données Open-Meteo Archive datées que pour un TMY composite non daté). `computeThermostatSetpoints()`
dérive un tableau `{t_min, t_max}[]` de même longueur que la météo. Vérifié par un script Node.js
autonome (arithmétique jour/semaine/vacances) avant intégration, puis par un script Python miroir
exécuté dans le conteneur backend contre le vrai solveur (`building_solver.run_building_simulation`)
sur un scénario 4 jours incluant un jour de vacances : le jour hors-gel reste sous 19°C toute la
journée (jamais pincé à la consigne normale), l'heure de jour normal se pince exactement à 19°C,
l'heure de nuit réduite se pince exactement à 16°C — comportement conforme au cadrage validé.

**UI** (`pages/calcul-3d/`) : section « Calendrier d'occupation (optionnel) », visible uniquement
en mode thermostat — sélecteur de profil, jour de la semaine du premier point météo, cases à cocher
jours ouvrés, liste de plages de vacances (ajout/retrait), bouton « Générer le calendrier ».
`submit()` fusionne les consignes générées dans chaque point météo avant envoi, uniquement si un
calendrier a été généré pour la longueur exacte de la météo actuelle ; toute modification de la
météo invalide le calendrier généré (`thermostatSetpoints.set(null)` dans `parseWeather()`) pour
éviter un calendrier périmé silencieusement réappliqué à une autre série. Aucune nouvelle classe
CSS introduite — réutilise uniquement `field-grid`/`mode-option`/`weather-actions`/`weather-count`/
`hint`/`btn-primary`/`btn-secondary`, déjà présentes dans `calcul-3d.component.scss`.

**Tests** (`backend/api/tests.py`, `ThermostatCalendarTest`, 4 nouveaux) : défaut inchangé sans
calendrier, `None` explicite dans le point météo retombe bien sur la constante du run, une
suspension ponctuelle (une heure hors-gel au milieu d'une série chaude) fait chuter le
`cooling_kwh` par rapport au run constant témoin et laisse l'air dépasser `t_max` pendant l'heure
suspendue puis se re-pincer normalement l'heure suivante, bornes invalides (`t_min >= t_max` pour
une heure donnée) lèvent bien `BuildingSimulationError`. Mutation testing sur le point de correction
(retour au `.get(key, repli)` fautif) : détecté immédiatement (`TypeError`), exactement le test de
retombée sur repli explicite qui échoue. 95/95 tests au total, `manage.py check` propre.

Vérifié en réel dans le conteneur (script Python miroir de la logique `usage-profiles.ts`, profil
`scolaire`, 4 jours dont un jour de vacances) : jour de vacances → air entre 7°C et 16°C toute la
journée (jamais pincé à 19°C), heure de jour normal → pincé exactement à 19°C, heure de nuit
normale → pincé exactement à 16°C.

### Reste ouvert
Pas de vérification en navigateur réel (même réserve que les autres lots récents). Les six profils
sont des valeurs indicatives usuelles (GTB/GTC, ADEME), pas une table réglementaire officielle —
même statut que le catalogue de parois.

---

## Hors scope — décisions déjà prises, à ne pas entreprendre sans en rediscuter

La page Théorie (section « Portée et hypothèses ») exclut déjà explicitement, comme choix assumé et
non comme oubli : **ponts thermiques linéiques / effets 2D-3D**, **couplage multi-locaux** (un seul
nœud d'air pour tout le bâtiment), **échanges IR grande longueur d'onde avec le ciel**, **albédo du
sol**, **réflexions multiples entre vitrages successifs**. Ce sont des refontes structurelles bien plus
lourdes que les lots ci-dessus — à ne considérer que si l'utilisateur le demande explicitement, pas à
improviser en marge d'un autre lot. Pour le pont thermique linéique : un ψ par arête de jonction entre
triangles d'orientations différentes, sommé sur le linéaire réel — pas amorcé plus loin ici.

**Précision sur le couplage multi-locaux** (le plus structurant des trois refontes ci-dessus si jamais
entrepris), pour qu'une décision future ait un vrai point de départ :

- **Multiplier les nœuds d'air** suppose d'abord un **découpage en zones** : chaque triangle devrait
  porter un `zone_id` (aujourd'hui seul `group`, une chaîne libre côté import OBJ, existe —
  réutilisable ou à distinguer). `_assemble_global_kc` créerait alors N nœuds d'air (un par zone) au
  lieu d'un seul, chaque triangle couplé à SON nœud de zone plutôt qu'au nœud global partagé.
- **Échange entre zones adjacentes** : soit un mélange d'air simplifié (une conductance entre deux
  nœuds de zone, un paramètre utilisateur — même famille que `g_vent`, mais entre deux nœuds internes
  plutôt qu'un nœud interne et l'extérieur), soit — plus juste physiquement — une vraie **paroi de
  refend** entre les deux zones : un type de triangle qui n'existe pas aujourd'hui, puisque tout
  triangle est actuellement un morceau d'ENVELOPPE (convection vers `h_e`/`t_ext` ou `t_ground` au
  Lot K) — un refend n'a ni l'un ni l'autre, juste de la convection intérieure (`h_i`) sur ses DEUX
  faces, chacune vers un nœud de zone différent.
- **« Analyse des échanges intérieurs »** est un chantier séparé et plus fin encore : même à
  l'intérieur d'une SEULE zone, le modèle actuel fait déjà une approximation forte en fusionnant tout
  échange de surface (convectif ET radiatif) dans un unique coefficient `h_i` vers un nœud d'air commun
  — une fenêtre froide ne « voit » pas rayonner un mur chaud, tout passe par l'air. Les outils std
  séparent `h_i` en une composante convective (vers l'air) et une composante radiative (vers les autres
  surfaces, via un réseau de facteurs de forme entre chaque paire de surfaces intérieures — coûteux en
  O(n²) — ou son approximation usuelle, une température radiante moyenne unique par zone). Un premier
  pas réaliste, si ce chantier est un jour entrepris seul (sans multiplier les zones), serait cette
  seule séparation convectif/radiatif à zone unique, avant d'aller jusqu'au réseau complet multi-zone.
