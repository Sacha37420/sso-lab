#!/bin/bash
# Autorise les connexions sans mot de passe depuis le réseau Docker interne (dev uniquement).
# pgAdmin peut ainsi se connecter sans jamais demander de mot de passe.
# Doit être inséré AVANT la règle "scram-sha-256" qui est catchall.
#
# ⚠️  ENVIRONNEMENT DE DÉVELOPPEMENT UNIQUEMENT
#     Ce script désactive l'authentification PostgreSQL pour POSTGRES_USER
#     sur les réseaux Docker internes (172.16.0.0/12 et 192.168.0.0/16).
#
# Pour revenir à une auth par mot de passe (ex. avant passage en prod) :
#   1. Supprimer ce fichier (infra/init/01_pg_hba_trust.sh)
#   2. Recréer le volume postgres :
#        docker compose down
#        docker volume rm infra_postgres-data
#        docker compose up -d
#   3. Dans pgAdmin, la boîte de dialogue "Enter password" réapparaîtra ;
#      entrer POSTGRES_PASSWORD défini dans infra/.env et cocher "Save password".
sed -i "s|host all all all scram-sha-256|host  all  ${POSTGRES_USER}  172.16.0.0/12  trust\nhost  all  ${POSTGRES_USER}  192.168.0.0/16  trust\nhost all all all scram-sha-256|" "$PGDATA/pg_hba.conf"
