#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# backup.sh — sauvegarde du lab : bases, annuaire, fichiers de storage, et tout ce
#             qui n'est dans aucun dépôt. Une copie locale, une copie sur le NAS.
#
# Usage :
#   bash scripts/backup.sh            fait une sauvegarde complète, applique la rétention
#   bash scripts/backup.sh --local    sans dépôt sur le NAS
#   bash scripts/backup.sh --list     liste les sauvegardes locales et celles du NAS
#   bash scripts/backup.sh --check    vérifie l'accès au NAS et ce qui serait sauvegardé, n'écrit rien
#
# Programmé par cron (voir README, « Sauvegardes ») : chaque nuit à 3 h.
# Code : 0 = sauvegarde complète et vérifiée ; 1 = au moins une pièce manque (un email part).
#
# CE QUI EST SAUVEGARDÉ (un dossier <AAAA-MM-JJ-HHMM>/ par passage) :
#   pg-<instance>-globals.sql.gz      rôles des deux instances PostgreSQL (mots de passe compris)
#   pg-<instance>-<base>.dump         chaque base, format `pg_dump -Fc` (restaurable base par base)
#   ldap-data.ldif.gz, ldap-config…   l'annuaire (comptes, groupes, mots de passe), par slapcat
#   vol-<volume>.tar.gz               volumes : fichiers de storage, données Keycloak, certificats
#                                     Caddy, configuration de lab-media
#   config.tar.gz                     tout ce qui n'est dans aucun dépôt : .env, registres, état du
#                                     lab (clés de déploiement), annuaire initial, ~/edge-router
#   MANIFEST.sha256, RAPPORT.txt      empreintes et compte rendu
# PAS SAUVEGARDÉ, à dessein : les enregistrements de lab-media (flux machine, 7 jours glissants),
# les caches et volumes de travail (recalculables), les dépôts git (sur GitHub), ~/lab-work
# (clones de travail : ce qui compte est poussé).
#
# ⚠ NON CHIFFRÉ pour l'instant (décision du propriétaire du 2026-10-12, à reprendre) : ces archives
# contiennent TOUS les secrets du lab. Le partage du NAS ne doit être lisible que par le compte de
# sauvegarde et par le propriétaire. Le chiffrement se branchera dans `seal()` ci-dessous.
#
# RÉTENTION, locale et NAS : 14 jours, plus la première sauvegarde de chaque mois pendant 6 mois.
# Sur le NAS, la vraie protection contre un effacement est la tâche d'instantanés ZFS du jeu de
# données : ce script peut supprimer ses propres dossiers, pas les instantanés.
#
# NAS : partage SMB joint par smbclient dans un conteneur jetable (image lab-backup), SMB 3 et
# chiffrement de transport EXIGÉS côté client. Réglages dans le .env racine :
#   LAB_BACKUP_NAS=//<adresse du NAS>/<partage>   LAB_BACKUP_NAS_USER=<compte dédié>   LAB_BACKUP_DIR=~/sauvegardes/lab
#   LAB_BACKUP_EMAIL=   (destinataire des alertes ; vide = l'adresse d'envoi du lab)
# Mot de passe du compte : ~/.lab-backup-nas (600), jamais dans un .env ni sur une ligne de commande.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/registry.sh
source "$SCRIPT_DIR/lib/registry.sh"
ROOT="$(registry_root)"

_env() { grep -E "^$1=" "$ROOT/.env" 2>/dev/null | tail -1 | cut -d= -f2- | sed -e "s/^['\"]//" -e "s/['\"]\$//"; }
NAS="$(_env LAB_BACKUP_NAS)"
NAS_USER="$(_env LAB_BACKUP_NAS_USER)"
DEST="$(_env LAB_BACKUP_DIR)";           DEST="${DEST:-$HOME/sauvegardes/lab}"; DEST="${DEST/#\~/$HOME}"
ALERT_TO="$(_env LAB_BACKUP_EMAIL)"
PWFILE="$HOME/.lab-backup-nas"
NAS_SUBDIR="lab"
KEEP_DAYS=14; KEEP_MONTHS=6
IMAGE="lab-backup:latest"
VOLUMES=(infra_storage-media sso-lab_keycloak-data sso-lab_caddy-data lab-media_config)

MODE="full"
case "${1:-}" in
  '') ;; --local) MODE="local" ;; --list) MODE="list" ;; --check) MODE="check" ;;
  *) echo "Usage : bash scripts/backup.sh [--local|--list|--check]" >&2; exit 2 ;;
esac

log()  { printf '%s %s\n' "$(date +%H:%M:%S)" "$*"; }
FAILS=()
fail() { FAILS+=("$*"); log "✗ $*"; }

# ── NAS : smbclient en conteneur ──────────────────────────────────────────────
ensure_image() {
  docker image inspect "$IMAGE" > /dev/null 2>&1 && return 0
  docker build -q -t "$IMAGE" "$SCRIPT_DIR/backup" > /dev/null 2>&1
}
# smb <dossier local à monter sur /data, ou ''> <commandes smbclient>
smb() {
  local mount=(); [[ -n "$1" ]] && mount=(-v "$1:/data:ro")
  # Sous l'identité de l'appelant : sans capacité (cap-drop ALL), root ne lirait ni le fichier de
  # mot de passe (600) ni les archives (umask 077).
  docker run --rm --network bridge --cap-drop ALL --security-opt no-new-privileges \
    --user "$(id -u):$(id -g)" -e HOME=/tmp \
    -v "$PWFILE:/pw:ro" -e PASSWD_FILE=/pw "${mount[@]}" "$IMAGE" \
    smbclient "$NAS" -U "$NAS_USER" -m SMB3 --option='client smb encrypt=required' -c "$2" 2>&1 \
    | grep -vE '^(Unable to initialize messaging|lpcfg_do_global|rlimit_max|WARNING: no network|Can.t load /etc/samba)'
}
nas_ready() { [[ -n "$NAS" && -n "$NAS_USER" && -r "$PWFILE" ]] && ensure_image && smb '' 'ls' | grep -q 'blocks available'; }
nas_dirs()  { smb '' "cd $NAS_SUBDIR; ls" | awk '$2 == "D" && $1 ~ /^[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{4}$/ { print $1 }' | sort; }

# ── Rétention : rend, sur stdin une liste de dossiers datés, ceux à SUPPRIMER ─
to_prune() {
  local limit month_limit name day month kept_months=""
  limit="$(date -d "-$KEEP_DAYS days" +%Y-%m-%d)"; month_limit="$(date -d "-$KEEP_MONTHS months" +%Y-%m)"
  sort | while IFS= read -r name; do
    day="${name:0:10}"; month="${name:0:7}"
    if [[ "$day" > "$limit" || "$day" == "$limit" ]]; then continue; fi          # dans les 14 jours
    if [[ ( "$month" > "$month_limit" || "$month" == "$month_limit" ) && "$kept_months" != *"$month"* ]]; then
      kept_months+=" $month"; continue                                           # première du mois
    fi
    printf '%s\n' "$name"
  done
}

if [[ "$MODE" == "list" ]]; then
  echo "Locales ($DEST) :"; ls -1 "$DEST" 2>/dev/null | grep -E '^[0-9]{4}-' | while read -r d; do printf '  %s  %s\n' "$d" "$(du -sh "$DEST/$d" | cut -f1)"; done
  echo "NAS ($NAS/$NAS_SUBDIR) :"; if nas_ready; then nas_dirs | sed 's/^/  /'; else echo "  (NAS injoignable)"; fi
  exit 0
fi

# ── Ce qui n'est dans aucun dépôt ─────────────────────────────────────────────
config_list() {
  cd "$ROOT" || return 1
  {
    find . -maxdepth 3 -name '.env' -not -path './.git/*' -not -path '*/node_modules/*' 2>/dev/null
    for f in infra/dev-roles.env sso-lab/ldap/init.ldif .ports .devs .owners bbox.env ports.env \
             lab-media/registry.json .app-descriptions; do [[ -e "$f" ]] && echo "./$f"; done
    find . -maxdepth 3 \( -name '.keycloak-client-opts' -o -name '.keycloak-service-account-roles' -o -name '.no-autodeploy' \) \
         -not -path './.git/*' 2>/dev/null
    [[ -d .lab-state ]] && find .lab-state -type f -not -name '*.log' -not -name 'deploy.lock*' 2>/dev/null
    # Contrats et rapports de chantier : en grande partie hors dépôt (.git/info/exclude).
    [[ -d chantiers ]] && find chantiers -type f 2>/dev/null
  } | sort -u
}

if [[ "$MODE" == "check" ]]; then
  echo "Destination locale : $DEST"
  if nas_ready; then echo "NAS : $NAS joignable en SMB 3 chiffré, compte $NAS_USER — $(nas_dirs | wc -l) sauvegarde(s)"; else echo "NAS : INJOIGNABLE ($NAS)"; fi
  echo "Bases : $(docker exec dev-postgres psql -X -U devuser -d postgres -Atc "select string_agg(datname, ' ') from pg_database where not datistemplate") · $(docker exec dev-postgis psql -X -U gisuser -d postgres -Atc "select string_agg(datname, ' ') from pg_database where not datistemplate")"
  echo "Volumes : ${VOLUMES[*]}"
  echo "Configuration : $(config_list | wc -l) fichiers, plus ~/edge-router"
  exit 0
fi

# ── Sauvegarde ────────────────────────────────────────────────────────────────
exec 9> "$(registry_state_dir)/backup.lock"
flock -n 9 || { echo "une sauvegarde tourne déjà" >&2; exit 1; }
umask 077
STAMP="$(date +%Y-%m-%d-%H%M)"
RUN="$DEST/$STAMP"
mkdir -p "$RUN" || { echo "impossible de créer $RUN" >&2; exit 1; }
exec > >(tee "$RUN/RAPPORT.txt") 2>&1
log "Sauvegarde du lab → $RUN"

# Point unique où brancher le chiffrement (voir l'en-tête) : aujourd'hui, ne fait rien.
seal() { :; }

pg_backup() {  # <instance> <conteneur> <rôle d'administration>
  local inst="$1" c="$2" admin="$3" db
  if ! docker exec "$c" pg_dumpall -U "$admin" --globals-only 2>/dev/null | gzip > "$RUN/pg-$inst-globals.sql.gz" \
     || [[ ! -s "$RUN/pg-$inst-globals.sql.gz" ]]; then fail "rôles de l'instance $inst"; fi
  while IFS= read -r db; do
    [[ -n "$db" ]] || continue
    if docker exec "$c" pg_dump -U "$admin" -Fc -d "$db" > "$RUN/pg-$inst-$db.dump" 2>"$RUN/.err" && [[ -s "$RUN/pg-$inst-$db.dump" ]]; then
      log "  base $inst/$db : $(du -h "$RUN/pg-$inst-$db.dump" | cut -f1)"
    else fail "base $inst/$db ($(head -c 200 "$RUN/.err"))"; fi
  done < <(docker exec "$c" psql -X -U "$admin" -d postgres -Atc "select datname from pg_database where not datistemplate order by 1" 2>/dev/null)
}
log "PostgreSQL"
pg_backup postgres dev-postgres "$(grep -E '^POSTGRES_USER=' "$ROOT/infra/.env" | cut -d= -f2-)"
pg_backup postgis  dev-postgis  "$(grep -E '^POSTGIS_USER=' "$ROOT/infra/.env" | cut -d= -f2-)"

log "Annuaire LDAP"
for n in 1:data 0:config; do
  if docker exec openldap slapcat -n "${n%%:*}" 2>/dev/null | gzip > "$RUN/ldap-${n##*:}.ldif.gz" && [[ "$(zcat "$RUN/ldap-${n##*:}.ldif.gz" | grep -c '^dn: ')" -gt 0 ]]; then
    log "  ${n##*:} : $(zcat "$RUN/ldap-${n##*:}.ldif.gz" | grep -c '^dn: ') entrées"
  else fail "annuaire LDAP (${n##*:})"; fi
done

log "Volumes"
for v in "${VOLUMES[@]}"; do
  if ! docker volume inspect "$v" > /dev/null 2>&1; then fail "volume $v introuvable"; continue; fi
  if docker run --rm --network none -v "$v:/src:ro" alpine:3.20 tar -C /src -czf - . > "$RUN/vol-$v.tar.gz" 2>"$RUN/.err" \
     && tar -tzf "$RUN/vol-$v.tar.gz" > /dev/null 2>&1; then
    log "  $v : $(du -h "$RUN/vol-$v.tar.gz" | cut -f1), $(tar -tzf "$RUN/vol-$v.tar.gz" | grep -vc '/$') fichiers"
  else fail "volume $v ($(head -c 200 "$RUN/.err"))"; fi
done

log "Configuration hors dépôt"
if (cd "$ROOT" && config_list | tar -czf "$RUN/config.tar.gz" --ignore-failed-read -T - 2>"$RUN/.err") \
   && tar -C "$HOME" -czf "$RUN/config-edge-router.tar.gz" edge-router 2>>"$RUN/.err"; then
  log "  $(tar -tzf "$RUN/config.tar.gz" | wc -l) fichiers, plus ~/edge-router"
else fail "configuration ($(head -c 200 "$RUN/.err"))"; fi
rm -f "$RUN/.err"

seal "$RUN"
(cd "$RUN" && sha256sum -- pg-* ldap-* vol-* config* > MANIFEST.sha256)
log "Copie locale : $(du -sh "$RUN" | cut -f1), $(ls "$RUN" | wc -l) fichiers"

# ── Dépôt sur le NAS ──────────────────────────────────────────────────────────
if [[ "$MODE" == "full" ]]; then
  log "NAS $NAS"
  if ! nas_ready; then
    fail "NAS injoignable — la copie locale existe, rien n'a été déposé"
  else
    sync; sleep 1
    smb "$RUN" "mkdir $NAS_SUBDIR; cd $NAS_SUBDIR; mkdir $STAMP; cd $STAMP; lcd /data; prompt; mput *" > /dev/null
    # Contrôle : chaque fichier doit être sur le NAS, à la même taille.
    remote="$(smb '' "cd $NAS_SUBDIR/$STAMP; ls" | awk 'NF >= 3 && $1 !~ /^\.+$/ { print $1 "\t" $3 }' | sort)"
    local_list="$(cd "$RUN" && for f in *; do [[ "$f" == RAPPORT.txt ]] && continue; printf '%s\t%s\n' "$f" "$(stat -c %s "$f")"; done | sort)"
    missing="$(comm -23 <(printf '%s\n' "$local_list") <(printf '%s\n' "$remote" | grep -v '^RAPPORT.txt'))"
    if [[ -z "$missing" ]]; then log "  déposé et vérifié : $(printf '%s\n' "$local_list" | wc -l) fichiers, tailles identiques"
    else fail "dépôt NAS incomplet : $(printf '%s' "$missing" | cut -f1 | tr '\n' ' ')"; fi
    # Rétention NAS — seulement après un dépôt réussi.
    if [[ ${#FAILS[@]} -eq 0 ]]; then
      while IFS= read -r old; do [[ -n "$old" ]] && { smb '' "cd $NAS_SUBDIR; deltree $old" > /dev/null; log "  rétention NAS : $old supprimée"; }; done < <(nas_dirs | to_prune)
    fi
  fi
fi

# ── Rétention locale — seulement après une sauvegarde sans défaut ─────────────
if [[ ${#FAILS[@]} -eq 0 ]]; then
  while IFS= read -r old; do
    [[ "$old" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{4}$ && -d "$DEST/$old" ]] || continue
    find "$DEST/$old" -type f -delete && rmdir "$DEST/$old" && log "rétention locale : $old supprimée"
  done < <(ls -1 "$DEST" | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{4}$' | to_prune)
  log "✓ Sauvegarde complète."
  exit 0
fi

log "✗ Sauvegarde INCOMPLÈTE : ${#FAILS[@]} défaut(s)."
# Alerte par email, par le SMTP du lab (sso-lab/.env). Best-effort.
E() { grep -E "^$1=" "$ROOT/sso-lab/.env" 2>/dev/null | tail -1 | cut -d= -f2-; }
SMTP_HOST="$(E SMTP_HOST)" SMTP_PORT="$(E SMTP_PORT)" SMTP_USER="$(E SMTP_USER)" SMTP_PASSWORD="$(E SMTP_PASSWORD)" \
SMTP_FROM="$(E SMTP_FROM)" SMTP_SSL="$(E SMTP_SSL)" SMTP_STARTTLS="$(E SMTP_STARTTLS)" \
ALERT_TO="$ALERT_TO" ALERT_BODY="$(printf 'Sauvegarde du %s incomplète :\n\n' "$STAMP"; printf -- '- %s\n' "${FAILS[@]}"; printf '\nCompte rendu : %s/RAPPORT.txt\n' "$RUN")" \
python3 - <<'PY' 2>/dev/null || log "  (alerte email non envoyée)"
import os, smtplib, ssl
from email.message import EmailMessage
h, u, p, f = (os.environ.get(k, "") for k in ("SMTP_HOST", "SMTP_USER", "SMTP_PASSWORD", "SMTP_FROM"))
if not (h and u and p and f): raise SystemExit(1)
m = EmailMessage(); m["From"] = f; m["To"] = os.environ.get("ALERT_TO") or f
m["Subject"] = "[lab] Sauvegarde incomplète"; m.set_content(os.environ["ALERT_BODY"])
port = int(os.environ.get("SMTP_PORT") or 587)
if (os.environ.get("SMTP_SSL") or "").lower() == "true":
    s = smtplib.SMTP_SSL(h, port, context=ssl.create_default_context(), timeout=30)
else:
    s = smtplib.SMTP(h, port, timeout=30)
    if (os.environ.get("SMTP_STARTTLS") or "true").lower() != "false": s.starttls(context=ssl.create_default_context())
s.login(u, p); s.send_message(m); s.quit()
PY
exit 1
