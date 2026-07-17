# MISSION — Nouveau sous-module « traitement cartographique » dans dev/

Tu construis une nouvelle application du lab : une plateforme de traitement
cartographique et géographique (SIG web). Elle vit comme sous-module git dans
dev/, suit exactement le workflow de création d'app décrit dans dev/CLAUDE.md
(new-app.sh → repo GitHub → sous-module → .env → --require-group → setup2.sh)
et respecte les DEUX verrous de cloisonnement (flow Keycloak + serrure API azp/groups).

Nom d'app suggéré : `carto-lab` (slug kebab-case). Type : Django + Angular.

--------------------------------------------------------------------------------
CONTRAINTE FONDAMENTALE — PostGIS (déviation par rapport au template standard)
--------------------------------------------------------------------------------
Le template django-angular utilise Postgres nu. Cette app EXIGE PostGIS :
  - image DB : `postgis/postgis` (pas `postgres`)
  - moteur Django : `django.contrib.gis.db.backends.postgis` + app `django.contrib.gis`
  - Dockerfile backend : installer GDAL, GEOS, PROJ, libgdal-dev (et exposer
    GDAL_LIBRARY_PATH / GEOS_LIBRARY_PATH si besoin)
  - dépendances Python : GeoDjango, gdal, shapely, pyproj, geopandas, rasterio,
    fiona, scipy (Voronoi), numpy
Adapte le docker-compose, le Dockerfile et settings.py en conséquence dès le scaffold.
Ne casse pas le reste du template (auth Keycloak JWT, drf-spectacular, nginx).

--------------------------------------------------------------------------------
STACK IMPOSÉE
--------------------------------------------------------------------------------
Backend : Django REST + GeoDjango + PostGIS ; GDAL/OGR pour les I/O de formats ;
          pyproj pour les projections ; shapely/geopandas/scipy pour le calcul.
Frontend : Angular + OpenLayers (+ proj4 pour les reprojections côté client).
           OpenLayers est choisi pour son support natif multi-projections.
Accès QGIS : pg_featureserv (OGC API – Features) derrière Caddy + oauth2-proxy
           (voir point 5). PAS de port PostGIS brut exposé.
Jobs longs : les imports Météo-France et certains calculs sont asynchrones →
          prévoir une file de tâches (Celery + Redis, ou Django-Q) avec suivi
          d'état (PENDING/RUNNING/DONE/ERROR) exposé au frontend.

--------------------------------------------------------------------------------
FONCTIONNALITÉS
--------------------------------------------------------------------------------

1. IMPORT DE CARTES (formats classiques)
   - Upload de couches vectorielles ET raster. Formats vectoriels au minimum :
     GeoJSON, Shapefile (.zip du .shp/.shx/.dbf/.prj), GeoPackage (.gpkg),
     KML/KMZ, GML, CSV avec colonnes lat/lon. Raster : GeoTIFF (au moins).
   - Détection automatique du SRID/CRS d'origine (via .prj / métadonnées GDAL),
     avec possibilité de le forcer manuellement si absent.
   - Chaque import devient une « couche » persistée en PostGIS (une table ou une
     table générique geometry + attributs JSONB), reprojetée/stockée en 4326 par
     défaut mais conservant la trace du CRS source.
   - Validation, taille max, feedback d'erreur clair, aperçu du nombre d'entités.

2. SYSTÈMES DE COORDONNÉES (quasi-totalité)
   - Support de tout code EPSG via pyproj/PROJ côté backend et proj4/OpenLayers
     côté frontend. Reprojection à la volée d'une couche d'un CRS vers un autre.
   - Cas français prioritaires : Lambert-93 (EPSG:2154), les 9 zones CC (EPSG:3942-3950),
     WGS84 (4326), Web Mercator (3857), UTM. Mais l'UI doit accepter n'importe quel EPSG.
   - Fonctions exposées : reprojeter une couche, afficher/convertir des coordonnées
     ponctuelles entre CRS, choisir le CRS d'affichage de la carte.

3. MOTEUR DE CALCULS GÉO/CARTO
   - Bibliothèque de traitements composables (chaque traitement = un « nœud » avec
     entrées/sorties typées) : reprojection, buffer, clip/intersection, union,
     différence, centroïdes, simplification, calcul de distances/aires/périmètres
     (avec gestion géodésique), jointure spatiale, jointure attributaire,
     agrégation, diagramme de Voronoï/Thiessen, enveloppe convexe, grille.
   - Les traitements s'exécutent en base (fonctions PostGIS ST_*) quand c'est
     possible, sinon en Python (shapely/geopandas). Résultat = nouvelle couche.
   - Objectif : ces briques servent à « construire des cartographies » (cf. point 6).

4. INTÉGRATION MÉTÉO-FRANCE (clé d'API saisie CÔTÉ FRONTEND)
   La clé d'API est fournie par l'utilisateur dans le frontend (champ dédié, stockée
   uniquement en mémoire/session côté client). Le frontend transmet la clé au backend
   à chaque appel (header dédié) ; le backend NE persiste PAS la clé et l'utilise pour
   appeler l'API Météo-France. Utilise l'« API Données Climatologiques » du portail
   Météo-France (portail-api.meteofrance.fr). ATTENTION : cette API est ASYNCHRONE
   (commande → identifiant → polling du statut → téléchargement du fichier CSV).
   Consulte la doc live pour les endpoints/paramètres exacts avant de coder.

   4.1 Pour une GRANDEUR donnée (température, précipitations, vent, etc.) et une
       ANNÉE donnée, récupérer TOUTES les stations françaises fournissant cette
       grandeur (parcours des départements / liste des stations, filtrage sur la
       disponibilité de la grandeur pour l'année). Résultat : couche ponctuelle des
       stations (géométrie = position station, attributs = métadonnées).
   4.2 Pour chacune de ces stations, calculer des INDICATEURS à partir des données
       récupérées : moteur d'indicateurs paramétrable/extensible (ex. moyenne
       annuelle, min/max, cumul, nombre de jours au-dessus/en-dessous d'un seuil,
       jours de gel, écart-type…). L'utilisateur choisit le/les indicateur(s).
   4.3 Construire les POLYGONES DE VORONOÏ (Thiessen) des stations, chaque polygone
       porte la valeur de l'indicateur de sa station. Découper (clip) les polygones
       sur l'emprise de la France métropolitaine (frontière fournie ou couche de ref).
   4.4 Produire la CARTOGRAPHIE FINALE : choroplèthe sur les polygones de Voronoï,
       classification (quantiles/Jenks/intervalles égaux), rampe de couleurs, légende,
       titre, et export (image + couche téléchargeable). Cette carte est persistée
       comme couche calculée (réutilisable aux points 5 et 6).

5. ACCÈS QGIS — via OGC API – Features (PAS de PostGIS brut)
   Certaines cartes calculées doivent être ouvrables dans QGIS. On NE PUBLIE PAS le
   port PostGIS sur Internet : PostgreSQL est du TCP brut, Caddy ne le protège pas, et
   un port 5432 ouvert court-circuiterait les deux verrous du lab (aucun SSO, aucun
   cloisonnement par groupe). À la place :

   - Matérialiser les couches « publiables » comme de vraies tables PostGIS avec
     géométrie indexée (GIST) et SRID renseigné, dans un SCHÉMA DÉDIÉ.
   - Créer un rôle Postgres DÉDIÉ EN LECTURE SEULE strictement scopé à ce schéma
     (REVOKE sur PUBLIC / autres schémas / autres bases ; statement_timeout ;
     CONNECTION LIMIT).
   - Exposer ce schéma via `pg_featureserv` (OGC API – Features, read-only par nature),
     placé DERRIÈRE Caddy + oauth2-proxy — exactement comme code-server — donc protégé
     par le même cloisonnement de groupe que le reste du lab. Aucun port DB ouvert.
   - QGIS consomme ces couches via une connexion « OGC API – Features » (ou WFS) : il
     récupère géométrie + attributs, style côté client, table attributaire, filtres.
   - AUTH : le service étant derrière oauth2-proxy (cookie OIDC), documenter la
     configuration d'authentification OAuth2 côté QGIS (Gestionnaire d'authentification
     → configuration OAuth2/bearer token), ou une alternative jeton/passerelle. C'est
     le seul vrai point de réglage.
   - Fournir à l'utilisateur, pour chaque couche publiée : l'URL du service OGC API –
     Features et le nom de la collection, + la marche à suivre de connexion QGIS.
   - OPTIONNEL : `pg_tileserv` (vector tiles / MVT) pour le rendu rapide des grosses
     couches, sous la même protection Caddy + oauth2-proxy.

6. VISUALISATION & CONSTRUCTEUR DE CARTES
   - Vue liste/galerie de toutes les couches et cartes (importées + calculées) avec
     leur CRS, type (vecteur/raster), nombre d'entités, date.
   - Visualiseur OpenLayers : afficher plusieurs couches empilées, styles, légende,
     zoom, sélection, popup d'attributs, changement de CRS d'affichage.
   - CONSTRUCTEUR : à partir d'un upload de carte + des traitements du point 3,
     enchaîner des opérations (pipeline/recette) pour produire une nouvelle carte.
     Sauvegarde de la recette pour rejouer, et de la carte résultat.
   - Bouton « publier vers QGIS » sur une couche calculée → la matérialise dans le
     schéma dédié exposé par pg_featureserv (cf. point 5).

--------------------------------------------------------------------------------
MODÈLE DE DONNÉES (indicatif)
--------------------------------------------------------------------------------
- Layer : id, nom, type (vector/raster), srid_source, geom_type, bbox, nb_entités,
  origine (upload/meteofrance/calcul), schéma/table PostGIS matérialisée,
  publié_qgis (bool), métadonnées JSONB.
- Feature/attributs : selon stratégie (table dédiée par couche, ou table générique
  geometry(Geometry,4326) + properties JSONB). Justifie ton choix.
- Processing / PipelineStep : type de traitement, paramètres, entrées, sortie.
- MeteoImport : grandeur, année, statut du job, stations trouvées, indicateurs demandés.
- Job async : statut, progression, message d'erreur, lien vers le résultat.

--------------------------------------------------------------------------------
SÉCURITÉ (rappel dev/CLAUDE.md — obligatoire)
--------------------------------------------------------------------------------
- Verrou 1 (navigateur) : `--require-group <groupe>` dans .keycloak-client-opts →
  flow require-<client> posé par create-app-client.sh. Ne jamais improviser le flow.
- Verrou 2 (API) : garder le contrôle azp == KEYCLOAK_CLIENT_ID ET intersection du
  claim `groups` avec KEYCLOAK_REQUIRED_GROUPS dans api/authentication.py. Ne PAS retirer.
- Accès QGIS : JAMAIS de port PostGIS brut exposé. Uniquement pg_featureserv (rôle
  read-only scopé) derrière Caddy + oauth2-proxy, même cloisonnement que le lab (point 5).
- Uploads : valider strictement (type, taille, contenu) — les fichiers SIG (Shapefile,
  KML, GeoTIFF via GDAL) sont un vecteur d'attaque. Pas d'exécution, pas de path traversal.
- Clé Météo-France : jamais persistée, jamais loggée.

--------------------------------------------------------------------------------
DÉROULÉ ATTENDU
--------------------------------------------------------------------------------
1. Lancer le scaffold (bash scripts/new-app.sh), type Django+Angular, définir un
   --require-group (ex : la même politique que les autres apps du lab).
2. Adapter le scaffold pour PostGIS + GDAL/GEOS/PROJ (contrainte fondamentale ci-dessus).
3. Repo GitHub + sous-module (Étape 2 de CLAUDE.md), remplir .env.
4. Implémenter les fonctionnalités 1→6 de façon incrémentale, testable à chaque lot.
5. Déployer avec `bash scripts/setup2.sh carto-lab --yes` (jamais recompose_docker seul).

Avant de coder : propose un découpage en LOTS livrables (ex. Lot 1 = scaffold PostGIS +
import + CRS + visualiseur ; Lot 2 = moteur de calculs + constructeur ; Lot 3 = Météo-France
Voronoï ; Lot 4 = publication OGC API – Features / accès QGIS), et attends validation sur
le premier lot. Vérifie la doc live de l'API Météo-France (endpoints, format async) avant
le Lot 3, et la doc pg_featureserv (déploiement Docker, config OGC API – Features) avant le Lot 4.
