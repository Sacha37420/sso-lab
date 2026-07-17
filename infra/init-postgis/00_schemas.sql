-- ─────────────────────────────────────────────────────────────────
-- Schémas applicatifs dans la base gisdb (instance dev-postgis).
-- Pendant de infra/init/00_schemas.sql, pour les apps SIG.
--
-- Ce fichier est exécuté automatiquement par PostgreSQL au premier
-- démarrage du container (initdb) — donc PAS sur un volume existant.
-- new-app.sh crée aussi le schéma à chaud pour les apps ajoutées ensuite.
--
-- Convention : un schéma par application, comme sur devdb.
--
-- NB : l'extension PostGIS elle-même est créée par le script 10_postgis.sh
-- embarqué dans l'image postgis/postgis. Les fichiers de ce dossier sont
-- montés UN PAR UN dans /docker-entrypoint-initdb.d/ pour ne pas le masquer.
-- ─────────────────────────────────────────────────────────────────

-- carto-lab : plateforme de traitement cartographique.
CREATE SCHEMA IF NOT EXISTS carto_lab;

-- Schéma des couches publiées en OGC API – Features (pg_featureserv).
-- Séparé de carto_lab : le rôle read-only de pg_featureserv n'a de droits
-- que sur celui-ci, jamais sur les tables applicatives.
CREATE SCHEMA IF NOT EXISTS carto_public;
