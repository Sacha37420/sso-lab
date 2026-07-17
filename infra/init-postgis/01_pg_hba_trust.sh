#!/bin/bash
# Autorise les connexions sans mot de passe depuis le réseau Docker interne (dev uniquement).
# pgAdmin peut ainsi se connecter à gisdb sans jamais demander de mot de passe.
# Doit être inséré AVANT la règle "scram-sha-256" qui est catchall.
#
# Pendant de infra/init/01_pg_hba_trust.sh pour l'instance dev-postgis.
#
# ⚠️  ENVIRONNEMENT DE DÉVELOPPEMENT UNIQUEMENT
#     Ce script désactive l'authentification PostgreSQL pour POSTGRES_USER
#     (ici gisuser) sur les réseaux Docker internes (172.16.0.0/12 et 192.168.0.0/16).
#
#     Le 'trust' ne vise QUE POSTGRES_USER. Les autres rôles — dont le rôle
#     read-only de pg_featureserv (carto_reader) — restent en scram-sha-256 et
#     doivent présenter leur mot de passe. Le cloisonnement en lecture seule
#     repose de toute façon sur les privilèges du rôle, pas sur l'auth.
#
# Pour revenir à une auth par mot de passe (ex. avant passage en prod) :
#   1. Supprimer ce fichier (infra/init-postgis/01_pg_hba_trust.sh)
#   2. Recréer le volume postgis :
#        docker compose down
#        docker volume rm infra_postgis-data
#        docker compose up -d
sed -i "s|host all all all scram-sha-256|host  all  ${POSTGRES_USER}  172.16.0.0/12  trust\nhost  all  ${POSTGRES_USER}  192.168.0.0/16  trust\nhost all all all scram-sha-256|" "$PGDATA/pg_hba.conf"
