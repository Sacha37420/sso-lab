# lab-backup — client SMB de la sauvegarde (scripts/backup.sh). Rien d'autre : pas de montage
# CIFS sur l'hôte (il demanderait root), le dépôt vers le NAS passe par smbclient en conteneur.
FROM alpine:3.20
RUN apk add --no-cache samba-client
