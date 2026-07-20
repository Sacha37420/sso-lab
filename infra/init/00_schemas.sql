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

CREATE SCHEMA IF NOT EXISTS google_agenda;

CREATE SCHEMA IF NOT EXISTS analyse_lora;

CREATE SCHEMA IF NOT EXISTS app_builder;

CREATE SCHEMA IF NOT EXISTS restauration;

CREATE SCHEMA IF NOT EXISTS traitement_de_fichiers_compils;

CREATE SCHEMA IF NOT EXISTS arbre_genealogique;

CREATE SCHEMA IF NOT EXISTS lab_admin;

CREATE SCHEMA IF NOT EXISTS conciergerie;

CREATE SCHEMA IF NOT EXISTS atelier_3d;
