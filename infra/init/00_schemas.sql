-- ─────────────────────────────────────────────────────────────────
-- Schémas applicatifs dans la base devdb.
-- Ce fichier est exécuté automatiquement par PostgreSQL
-- au premier démarrage du container (initdb).
--
-- Convention : un schéma par application.
-- Les tables, séquences et index de chaque app vivent dans
-- leur propre espace de noms, sans risque de collision.
--
-- Pour ajouter une nouvelle app :
--   CREATE SCHEMA IF NOT EXISTS nom_de_lapp;
-- ─────────────────────────────────────────────────────────────────

CREATE SCHEMA IF NOT EXISTS spring_app;

-- CREATE SCHEMA IF NOT EXISTS future_app;

CREATE SCHEMA IF NOT EXISTS table_manager;

CREATE SCHEMA IF NOT EXISTS test_django_angular;

CREATE SCHEMA IF NOT EXISTS test_django;

CREATE SCHEMA IF NOT EXISTS test_angular_django;

CREATE SCHEMA IF NOT EXISTS test_bots;
