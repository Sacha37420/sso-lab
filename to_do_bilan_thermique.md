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

**Lots F, G, H, K, L, M, P, Q et S livrés** (tests physiques automatisés, renouvellement d'air,
apports internes, triangles au contact du sol, import météo automatique Open-Meteo + PVGIS TMY,
résultats normalisés kWh/m²/an, aide au calcul de `c_air_int`, plannings horaires, années type) — voir
leur section respective pour le détail. Chaque lot qui touche `_assemble_F`/`_assemble_F_hour` doit
faire passer `python manage.py test api` avant/après modification — c'est tout l'intérêt du Lot F :
détecter une régression au lieu de la découvrir en production (H, K et Q l'ont fait, 15/15 puis 28/28
puis 36/36 puis 43/43 OK à chaque étape ; Q touchait en plus la factorisation LU du solveur, le point
le plus délicat rencontré depuis le Lot F — voir sa section). **Lot R peut démarrer maintenant que L
est livré** (`weather_source.py` existe, n'a plus qu'à demander `wind_speed_10m`/`WS10m` à
Open-Meteo/PVGIS) — et bénéficie maintenant du patron de factorisation-par-valeur-distincte posé par
le Lot Q pour `h_e` (généralisé à `K_global` en entier plutôt qu'au seul nœud d'air, cf. sa section).
**Lot I (cadre de fenêtre) reste à faire** : évalué le 2026-08-07 mais reporté — plus invasif que les
autres lots H→K (change la forme de `paroi_layers_by_id` et remplace le système FEM complet par un
système résistif simplifié pour les triangles concernés), a besoin d'une session dédiée plutôt que
d'être pressé en fin de créneau. Lot J et Lot R restent à cadrer avec l'utilisateur avant de coder
(voir leur section — Lot R en plus de son cadrage, cf. ci-dessus). Lots N et O (checklist de
progression, générateur de boîte) restent aussi à faire — indépendants, purement frontend, aucun
cadrage ni dépendance requis.

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
format de sortie). `vent_m_s` (Lot R) non demandé à Open-Meteo pour l'instant (`wind_speed_10m` est
disponible dans la même réponse API, en km/h — à convertir en m/s le jour où le Lot R est entrepris).
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
`vent_m_s` (Lot R) toujours pas demandé — PVGIS fournit aussi `WS10m` (à vérifier l'unité au moment du
Lot R, PVGIS et Open-Meteo n'utilisent probablement pas la même). Pas de vérification dans un
navigateur réel (même réserve qu'au Lot L).

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
