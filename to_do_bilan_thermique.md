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

**Lots F et G livrés** (tests physiques automatisés, renouvellement d'air) — voir leur section
respective pour le détail. Chaque lot suivant qui touche `_assemble_F`/`_assemble_F_hour` (H, K)
doit maintenant faire passer `python manage.py test api` avant/après modification — c'est tout
l'intérêt du Lot F : détecter une régression au lieu de la découvrir en production. **Lot L (météo
automatique) reste la priorité la plus haute côté ergonomie** : c'est le goulot d'étranglement le
plus lourd du parcours actuel (CSV collé à la main) et un prérequis moral avant de recommander
l'outil pour un vrai bâtiment. Les lots H→K sont indépendants entre eux mais touchent tous
`solver.py`/`building_solver.py` — à faire un par un, jamais en parallèle. Les lots L→P sont
largement indépendants les uns des autres (fichiers distincts) et parallélisables par sous-agents
une fois leurs contrats d'API respectifs figés. **Lot Q dépend du Lot H** (généralise
`apports_internes_w` et le `debit_vent_m3h`/`eta_recup_vent` du Lot G à un planning horaire commun) —
à faire juste après H, pas en parallèle des autres. **Lots R et S dépendent du Lot L** (tous deux ont
besoin de la météo automatique : `vent_m_s` pour R, choix de la source pour S) — à ne pas commencer
avant que L soit en place.

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

## Lot H — Apports internes (occupants, éclairage, électroménager)

### Constat
Rien ne modélise les gains internes — chauffage systématiquement surestimé, climatisation sous-estimée
par rapport à un bâtiment réellement occupé.

### Étapes
1. Ajouter un champ `apports_internes_w` (puissance constante, W) à `BuildingInteriorSerializer` —
   version minimale de ce lot : une seule valeur pour tout le run. Besoin confirmé d'un profil horaire
   (planning d'occupation, plutôt qu'une constante) — traité au **Lot Q**, à faire juste après celui-ci
   plutôt qu'en itération lointaine : Lot Q généralise `apports_internes_w` ET `debit_vent_m3h`/
   `eta_recup_vent` (Lot G) au même mécanisme de planning, les deux grandeurs suivant le même moteur
   physique (la présence humaine).
2. Injecter directement dans `F[air_idx]` (`_assemble_F_hour`) — c'est le point d'injection le plus
   simple, aucune dépendance à la géométrie d'un triangle particulier.
3. Documenter dans la page Théorie (section « Portée et hypothèses ») au même titre que les autres
   hypothèses déjà listées.

---

## Lot I — Cadre de fenêtre (Uw, fraction de cadre)

### Constat
Le catalogue le documente déjà lui-même (« Modélise uniquement le vitrage, pas le cadre »,
`seed_paroi_catalogue.py`) — le cadre a souvent un U bien plus élevé que le vitrage (alu ~3-7 W/m²·K
contre 1,1-2,9 pour un double vitrage), donc l'ignorer sous-estime les pertes par les baies.

### Étapes
1. Ajouter deux champs optionnels à `ParoiModel` (pertinents seulement pour un modèle de type
   fenêtre) : `frame_u` (W/m²·K) et `frame_fraction` (0..1, part de l'aire totale occupée par le
   cadre plutôt que le vitrage).
2. Au niveau triangle (`_build_triangle_systems`/`_assemble_global_kc`) : si ces champs sont
   présents, pondérer la conductance du triangle comme une résistance en parallèle
   (`U_global = frame_fraction * frame_u + (1 - frame_fraction) * U_vitrage`) plutôt que d'appliquer
   le système multicouche 1D complet sur toute l'aire — le cadre n'a pas de comportement optique
   (tau=0) et sa capacité thermique est négligeable, un terme purement résistif suffit.
3. Étendre les deux entrées « Fenêtre » du catalogue de départ avec des valeurs de cadre usuelles
   (PVC ≈ 1,5-2 W/m²·K, alu ≈ 3-5, bois ≈ 1,5-2 ; `frame_fraction` ≈ 0,20-0,30 pour une fenêtre
   standard).

---

## Lot J — Occultations mobiles (volets, stores)

### Constat
Aucun moyen de simuler un volet fermé la nuit (fort impact sur les pertes par les baies) ni un
store extérieur qui limite les apports solaires d'été — seule la paroi statique existe.

### Étapes — à cadrer avec l'utilisateur avant de commencer (plusieurs designs possibles)
1. Option la plus simple : un champ additionnel dans `BuildingWeatherPointSerializer`
   (`volet_ferme: bool`, par triangle-groupe ou global) qui, quand actif, ajoute une résistance
   supplémentaire fixe (volet fermé ≈ R additionnel usuel 0,2-0,25 m²·K/W) et annule `e_glo` pour
   les triangles concernés à cette heure.
2. Option plus fidèle : un second `ParoiModel` "volet fermé" par fenêtre, sélectionné dynamiquement
   heure par heure selon un planning fourni par l'utilisateur (plus lourd à implémenter — l'
   assemblage `_build_triangle_systems` est aujourd'hui figé une fois pour tout le run, pas recalculé
   heure par heure).
3. Trancher entre les deux avant d'écrire du code — la deuxième change la structure de mise en cache
   des systèmes triangle (actuellement un seul système par `(paroi_model_id, dx_max)` pour tout le
   run, cf. `building_solver.py:61-91`).

---

## Lot K — Triangles au contact du sol (dallage)

### Constat
Aucune distinction entre un triangle de mur/toiture (face à l'air extérieur, `h_e`/`t_ext`) et un
triangle de plancher bas au contact du sol. Si un tel triangle est maillé, il reçoit aujourd'hui la
même condition limite qu'un mur — physiquement faux, le sol a une température bien plus stable et
amortie que l'air extérieur (grossièrement 10-14°C de moyenne annuelle en France, quasi-constante).

### Étapes
1. Ajouter un champ `boundary` sur le triangle (`TriangleInputSerializer`) : `'exterior_air'`
   (défaut, comportement actuel) ou `'ground'`.
2. Pour les triangles `'ground'` : soit une température de sol constante fournie par l'utilisateur
   (champ sur `Building` ou dans le payload de calcul), soit — plus tard — une valeur dérivée de la
   moyenne annuelle de la série météo fournie. Commencer par la constante, la dérivation automatique
   n'a de sens qu'une fois le Lot L (météo réelle) en place.
3. `_assemble_F_hour`/`_assemble_F` : brancher `t_ground` à la place de `t_ext` pour ces triangles,
   éventuellement avec un `h_e` différent (pas de convection due au vent contre le sol).

---

## Lot L — Import météo automatique (Open-Meteo Archive / PVGIS TMY)

### Constat
La météo horaire reste 100 % manuelle : coller un CSV à la main (`calcul-3d.component.ts:127-146`)
ou générer une série synthétique sinusoïdale de démonstration (`loadExample`/`loadConstant`, mêmes
lignes 148-169) — ni l'une ni l'autre n'est une vraie donnée météo. C'est le goulot d'étranglement
le plus lourd du parcours actuel, et déjà identifié comme prochain chantier (mémoire
`project_bilan_thermique.md`). Sources déjà repérées : **Open-Meteo Archive API**
(`temperature_2m`, `direct_normal_irradiance`, `diffuse_radiation` — correspondent presque champ
pour champ à `BuildingWeatherPointSerializer`) ou **PVGIS TMY** (année type, plus représentatif pour
un dimensionnement que l'historique brut d'une année réelle).

### Étapes
1. Nouveau module pur `backend/api/weather_source.py` (même patron que `geodata.py` : pas de
   dépendance Django, prend lat/lon/période, retourne une liste de dicts) — appel Open-Meteo Archive,
   conversion `direct_normal_irradiance`/`diffuse_radiation` (repère solaire) vers `e_dir`/`e_dif`
   plus **calcul de l'azimuth/élévation solaire réels** heure par heure (formule d'éphéméride
   standard, lat/lon/date/heure → position du soleil) puisqu'Open-Meteo ne les fournit pas
   directement.
2. **Point d'attention critique** : convertir l'azimuth solaire réel (convention météo usuelle,
   0°=Sud ou 0°=Nord selon la source) vers la convention interne de l'app (`geometry.py:8-12` :
   azimuth 0°=+Y, sens horaire) — et si le bâtiment est géoréférencé (`georef_north_offset_deg`),
   appliquer la même rotation que `geodata._rotate_xy` pour que météo et géométrie restent dans le
   même repère. Vérifier à la main sur un point connu (ex. midi solaire vrai, soleil plein sud)
   avant de livrer — mêmes précautions que pour l'alignement bâtiment/environnement du 2026-08-05.
3. Tâche Celery `fetch_weather` (même pattern que `generate_environment`), endpoint
   `POST /api/batiments/<id>/meteo/` (ou un endpoint autonome si la météo doit pouvoir être
   récupérée indépendamment d'un bâtiment précis).
4. UI : sur la page Calcul 3D, un panneau « Récupérer depuis Open-Meteo » (lat/lon — réutiliser le
   géoréférencement du bâtiment s'il existe — + période) à côté du textarea CSV existant, qui
   remplit `weatherRaw`/`weather` en résultat. Le CSV manuel et les générateurs synthétiques restent
   utiles (tests rapides, bâtiment non géoréférencé) — à garder, pas à remplacer.
5. Annoter clairement dans l'UI que `loadExample`/`loadConstant` sont des données de démonstration,
   pas une source utilisable pour un vrai bilan (actuellement aucune distinction visuelle avec une
   vraie série).

---

## Lot M — Surface de référence et résultats normalisés (kWh/m²/an)

### Constat
Le dashboard (`calcul-3d.component.html:189-210`) affiche des kWh bruts, jamais de kWh/m²/an — pourtant
le catalogue de parois cite explicitement les seuils RT2005/RT2012/RE2020, qui ne sont comparables
qu'en valeur surfacique. Sans ce champ, l'utilisateur ne peut pas juger si un résultat est bon ou
mauvais.

### Étapes
1. Ajouter un champ `surface_ref_m2` à `Building` (saisie directe — la déduire automatiquement des
   triangles de plancher suppose le Lot K déjà en place pour identifier lesquels en sont).
2. Dashboard : `heating_kwh / surface_ref_m2` et `cooling_kwh / surface_ref_m2` affichés à côté des
   valeurs brutes existantes, avec un repère visuel simple (comparaison aux seuils déjà documentés
   dans le catalogue : RT2012 ≈ 50 kWh/m²/an de consommation conventionnelle, RE2020 plus strict).

---

## Lot N — Checklist de progression guidée (page Bâtiment)

### Constat
Le parcours complet traverse 5 pages sans fil conducteur explicite : créer les modèles de paroi →
importer un maillage OBJ groupé → assigner chaque groupe à un modèle → géoréférencer le bâtiment →
générer/importer un environnement → précalculer l'ombrage → construire la météo → lancer le calcul.
Le badge « ombrage périmé » (`calcul-3d.component.html:31-33`) est le seul repère d'état existant.

### Étapes
1. Sur la page Bâtiment, une checklist compacte (5-6 items : parois assignées / géoréférencement /
   environnement lié / ombrage à jour / météo chargée) avec état coché/manquant par item, dérivée de
   données déjà présentes côté client (pas de nouvel endpoint nécessaire).
2. Chaque item non coché est un lien direct vers l'action qui le résout (ex. « ombrage périmé » →
   bouton précalcul directement dans la checklist, pas seulement un badge d'avertissement).
3. Généraliser le pattern du badge existant plutôt que le dupliquer.

---

## Lot O — Générateur de bâtiment simple (« boîte »)

### Constat
La seule voie d'entrée pour un bâtiment est l'import d'un fichier OBJ/STL groupé
(`mesh-import.ts`) — suppose une maîtrise d'un outil de modélisation 3D externe (Blender, etc.).
Sans ça, impossible de tester l'outil sur un cas simple.

### Étapes
1. Sur la page Bâtiment, un formulaire « Générer une boîte » : longueur × largeur × hauteur (+
   option toiture plate/2 pans), génère directement `vertices`/`triangles` côté client (géométrie
   triviale, pas besoin d'un endpoint dédié) avec des groupes nommés automatiquement (`mur_nord`,
   `mur_sud`, `toiture`, etc.) pour que l'assignation par groupe (déjà en place,
   `batiment.component.ts:173-181`) fonctionne immédiatement.
2. L'import OBJ reste la voie avancée pour une géométrie réelle — ce générateur est un point d'entrée
   pédagogique/de test, pas un remplacement.

---

## Lot P — Aide au calcul de `c_air_int`

### Constat
`c_air_int` (J/K, capacité thermique de l'air intérieur) est demandé en valeur brute
(`calcul-3d.component.html:110-111`) — une grandeur qu'un utilisateur non spécialiste ne sait pas
estimer.

### Étapes
1. Petit calcul assisté dans le formulaire : à partir d'un volume d'air saisi (m³, ou déduit du Lot
   M si `surface_ref_m2` × hauteur sous plafond sont connus), `c_air_int ≈ volume_m3 * 1200`
   (J/m³·K, capacité thermique volumique usuelle de l'air à pression normale) — bouton "calculer
   depuis le volume" qui pré-remplit le champ, resté éditable ensuite.

---

## Lot Q — Plannings horaires (ventilation + apports internes)

### Constat
Après le Lot G (`debit_vent_m3h`/`eta_recup_vent`, déjà livré) et le Lot H (`apports_internes_w`, à
livrer) tels que décrits, ces deux grandeurs restent **constantes sur toute la durée du run**. Or
elles suivent le même moteur physique : la présence humaine. Un logement occupé le soir/week-end et
vide en semaine journée a des apports internes ET un besoin de ventilation (VMC hygroréglable, cf. le
profil « 2000-2012 » de `ventilation-profiles.ts`, déjà modulé selon l'occupation dans la réalité)
qui varient ensemble — une seule valeur moyenne sur toute l'année écrase les pointes réelles
(matin/soir en semaine, toute la journée le week-end) au lieu de les représenter. **Dépend du Lot H**
— rien à faire ici tant que `apports_internes_w` n'existe pas encore comme constante à généraliser.

### Étapes
1. **Décision à trancher avant de coder** : un seul profil « jour type » (24 valeurs, répété
   cycliquement sur toute la série météo) ou deux profils distincts semaine/week-end (48 valeurs) ?
   Le second est plus réaliste mais suppose de savoir quel jour de semaine correspond à `weather[0]`
   — aucune donnée de calendrier n'existe aujourd'hui dans `BuildingWeatherPointSerializer` (une
   série séquentielle d'heures, sans date). Commencer par un seul profil « jour type » (plus simple,
   couvre déjà le cas le plus utile : nuit vs journée) ; le distinguo semaine/week-end n'a de sens
   qu'une fois le Lot L (météo réelle, datée) en place.
2. **Nouveau champ optionnel `planning`** sur `BuildingCalculRequestSerializer` (`serializers.py`) :
   liste de 24 entrées `{debit_vent_m3h, eta_recup_vent, apports_internes_w}`, une par heure de la
   journée (index 0 = minuit). Absent → comportement actuel inchangé (valeurs constantes de
   `interior`, ou 0 si non fournies — rétrocompatible avec les Lots G/H tels quels).
3. **Phase horaire** : ajouter `heure_debut` (0-23, défaut 0) au payload de calcul — l'heure de la
   journée du premier point de `weather`. Sans lui, `planning[hour_idx % 24]` suppose que la série
   météo démarre toujours à minuit, hypothèse fragile dès que le Lot L (import Open-Meteo, période
   arbitraire) sera en place.
4. **`_assemble_F_hour`/`run_building_simulation`** (`building_solver.py`) : si `planning` est fourni,
   calculer `g_vent`/`apports_internes_w` de chaque heure via
   `planning[(heure_debut + hour_idx) % 24]` au lieu des constantes de `interior`. **Point dur** :
   `g_vent` est aujourd'hui ajouté une seule fois à `K_global[air_idx, air_idx]` avant la boucle
   horaire (voir Lot G), et `A_free`/`A_pinned` sont factorisés une seule fois par `spla.splu`
   (`run_building_simulation:283-306`) en supposant `K_global` fixe pour tout le run. Un `g_vent`
   variable par heure casse cette hypothèse — il faudra factoriser une fois **par valeur distincte**
   de `g_vent` rencontrée dans le planning (24 au plus pour un profil « jour type », pas une par heure
   simulée) plutôt qu'une seule fois pour tout le run. `apports_internes_w`, lui, n'affecte que `F`
   (second membre, déjà recalculé à chaque heure) — aucun problème de factorisation de ce côté.
5. **UI** (page Calcul 3D) : éditeur de planning réutilisant le même patron que la météo horaire déjà
   en place (`calcul-3d.component.ts:127-146` — textarea CSV collée + bouton d'exemple) : 24 lignes
   `débit_m3h, eta_recup, apports_w`. Le profil de ventilation par époque (Lot G,
   `ventilation-profiles.ts`) reste utile comme point de départ (valeur constante) même une fois le
   planning disponible — un planning est une variation AUTOUR d'un profil de base, pas forcément un
   remplacement complet.

---

## Lot R — Coefficient de convection extérieure dynamique (h_e)

### Constat
`h_e` est aujourd'hui une valeur unique saisie par l'utilisateur, constante sur tout le run (25 W/m²K
par défaut — c'est justement la valeur conventionnelle Rse=0,04 d'EN ISO 6946, pensée pour un calcul
de U statique en régime permanent, pas pour une simulation dynamique heure par heure). Les outils de
simulation dynamique (EnergyPlus, TRNSYS) recalculent h_e à partir du vent réel — un h_e peut varier
d'un facteur 2 à 5 selon qu'il vente ou non, ce qui change directement la vitesse à laquelle un
bâtiment perd/gagne de la chaleur. Axe indépendant des Lots G→K : ceux-là ajoutent des postes de perte
manquants, celui-ci corrige la précision d'un poste déjà modélisé (la convection extérieure).

### Étapes — à cadrer avec l'utilisateur avant de coder (implication de performance significative)
1. **Formule de corrélation** vitesse de vent → h_e : ex. Jürges (`h_e = 5,8 + 3,94·v`, v en m/s,
   souvent citée en physique du bâtiment française) ou McAdams (`h_e = 5,7 + 3,8·v`) — à choisir et
   documenter avec la même rigueur que les U indicatifs du catalogue de parois
   (`seed_paroi_catalogue.py`), en citant la source. Version minimale : une seule valeur de vent pour
   tout le bâtiment à une heure donnée, sans dépendance à l'orientation de la façade par rapport au
   vent (une façade au vent et une façade sous le vent ont en réalité des coefficients différents —
   simplification à assumer explicitement, pas un oubli).
2. **Nouvelle donnée météo** `vent_m_s`, optionnelle sur `WeatherPointSerializer`/
   `BuildingWeatherPointSerializer` — Open-Meteo Archive fournit déjà `wind_speed_10m` (Lot L), donc
   alimentable automatiquement dès que ce lot est en place. Absent → comportement actuel inchangé
   (h_e constant fourni par l'utilisateur).
3. **Point dur — même famille de problème que le Lot Q, en plus sévère.** `h_e` est aujourd'hui posé
   UNE FOIS dans `K[0,0]` de CHAQUE système de paroi (`_build_triangle_systems`, mis en cache par
   `(paroi_model_id, dx_max)`), et `A_free`/`A_pinned` sont factorisés une seule fois pour tout le run
   (`spla.splu`). Un `h_e` variable par heure touche la diagonale de TOUTES les parois extérieures à
   la fois — pas seulement le nœud d'air partagé comme `g_vent` — donc une factorisation à chaque
   heure serait inacceptable sur le worker à `--concurrency=1` du lab pour un run d'un an. Discrétiser
   `vent_m_s` en un nombre borné de classes (ex. arrondi au m/s le plus proche — quelques dizaines de
   valeurs distinctes au plus sur un historique réel) et factoriser une fois par classe rencontrée —
   même stratégie que le Lot Q pour `g_vent`, mais à généraliser à `K_global` en entier, pas au seul
   nœud d'air.
4. **`h_i` : raffinement séparé, beaucoup moins coûteux.** Contrairement à `h_e` (dépend du vent, donc
   du temps), `h_i` peut être raffiné PAR ORIENTATION du triangle (ISO 6946 : ≈7,7 W/m²K pour un mur
   vertical, ≈10 pour un flux montant type plancher chauffant, ≈5,9 pour un flux descendant type
   plafond) — une valeur PAR TRIANGLE mais CONSTANTE dans le temps (dérivée de `tilt_deg`, déjà
   calculé), donc sans le problème de factorisation ci-dessus. Faisable indépendamment du reste de ce
   lot si seul un raffinement de `h_i` est souhaité.

---

## Lot S — Années type (TMY)

### Constat
Même une fois le Lot L livré, l'import météo automatique reste l'historique BRUT d'**une année réelle
particulière** (Open-Meteo Archive) — un hiver anormalement doux ou rude biaise le résultat sans que
rien ne le signale. Les outils de dimensionnement std utilisent une **année type** (TMY — Typical
Meteorological Year), construite pour être statistiquement représentative (méthode Finkelstein-Schafer
ou équivalent : sélectionne, mois par mois, le mois le plus « typique » parmi plusieurs années
d'historique, puis les assemble en une seule année synthétique). Déjà repéré comme piste au Lot L :
**PVGIS TMY**, qui calcule déjà ce type d'année de façon validée — pas la peine de réimplémenter
Finkelstein-Schafer à la main.

### Étapes
1. **PVGIS TMY comme source privilégiée** (`backend/api/weather_source.py`, créé au Lot L) : endpoint
   PVGIS `tmy` (lat/lon → une année horaire déjà assemblée comme année type) — même principe que le
   repli IGN→OSM de `geodata.py` (`is_in_france()`), mais la bascule ici ne se fait pas sur la France :
   PVGIS couvre l'essentiel du globe hors zones polaires (à vérifier précisément la couverture au
   moment de coder — PVGIS s'appuie sur différentes bases satellite selon la zone, SARAH2/NSRDB/ERA5).
   Repli sur l'historique brut Open-Meteo Archive (Lot L) hors couverture PVGIS.
2. **Choix explicite côté UI** entre « année type (PVGIS TMY) » — pour un dimensionnement
   représentatif — et « année réelle (Open-Meteo Archive), datée au choix » — pour étudier un épisode
   précis (ex. la canicule d'un été réel donné). Les deux sources produisant le même format interne
   (`e_dir`/`e_dif`/`t_ext`/`sun_azimuth`/`sun_elevation`, plus `vent_m_s` si le Lot R est en place), le
   reste du pipeline (solveur, dashboard) ne voit aucune différence entre les deux.
3. Annoter clairement dans le dashboard quelle source a produit le résultat affiché (TMY vs année
   réelle datée) — un résultat en kWh/m²/an (Lot M) n'a pas le même sens statistique selon la source,
   à ne jamais laisser ambigu.

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
