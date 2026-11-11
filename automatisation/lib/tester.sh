#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# automatisation/lib/tester.sh — tests d'un correctif (contrat nuit-auto v1, I5.3).
# Lancé par passage.sh SOUS LE VERROU DE DÉPLOIEMENT :
#   bash scripts/lab-lock.sh bash automatisation/lib/tester.sh <app> <arbre> <dossier tests> <req 0|1> <front 0|1>
#
#   <arbre>         arbre corrigé, exporté du clone propre (jamais monté en écriture ici)
#   <dossier tests> commande.txt (lue par l'appelant dans la feuille de route du commit de
#                   base) ; reçoit backend.txt, front.txt, build.txt, resultat.txt
# Code : 0 vert (ou rien à tester) · 1 rouge · 3 dépendances modifiées et app à .heavy-build
#        (non testées) · 4 erreur du moteur.
#
# Ce qui diffère de chantiers/tests/essai.sh (non réutilisable tel quel, constat du contrat §2) :
# le code testé est l'arbre CORRIGÉ, pas le dossier en service ; le .env est ASSAINI (valeurs
# des clés secrètes remplacées par de l'aléa : le code testé est écrit par une IA et ses
# sorties vont dans un rapport public) ; l'image est reconstruite (<image>:auto) si un
# requirements*.txt a changé.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
# shellcheck source=commun.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/commun.sh"

APP="$1"; ARBRE="$2"; TD="$3"; REQ="$4"; FRONT="$5"
APP_DIR="$(registry_app_dir "$APP")" || exit 4
TMPD="$(mktemp -d "${TMPDIR:-/tmp}/lab-auto-test.XXXXXX")"
ID="auto-test-$$"; NET_T="$ID-net"; PG="$ID-pg"; NET_F="auto-front-$$"; IMG_AUTO=""
nettoyer() {
  x 30 docker rm -f "$ID" "$PG" "auto-front-$$" > /dev/null 2>&1
  x 30 docker network rm "$NET_T" > /dev/null 2>&1
  x 30 docker network rm "$NET_F" > /dev/null 2>&1
  [[ -n "$IMG_AUTO" ]] && x 60 docker image rm -f "$IMG_AUTO" > /dev/null 2>&1
  chmod -R u+rwX "$TMPD" 2>/dev/null; rm -rf -- "$TMPD"
}
trap nettoyer EXIT
say() { echo "$*"; }
BACK="absent"; FRT="absent"

# ── Backend ───────────────────────────────────────────────────────────────────
MODEL="$(x 60 docker compose --project-directory "$APP_DIR" -f "$APP_DIR/docker-compose.yml" config --format json --no-env-resolution 2>/dev/null)" \
  || { say "docker-compose.yml de $APP illisible"; exit 4; }
SERVICE=""; CTX=""; DF=""
while IFS=$'\t' read -r s ctx df; do
  rel="${ctx#"$APP_DIR"}"; rel="${rel#/}"
  if [[ -f "$ARBRE/${rel:+$rel/}manage.py" ]]; then SERVICE="$s"; CTX="$rel"; DF="${df:-Dockerfile}"; break; fi
done < <(jq -r '.services | to_entries[] | select(.value.build != null)
               | [.key, (.value.build.context // ""), (.value.build.dockerfile // "Dockerfile")] | @tsv' <<< "$MODEL")

if [[ -n "$SERVICE" ]]; then
  CMD="$(head -1 "$TD/commande.txt" 2>/dev/null)"; CMD="${CMD:-python manage.py test}"
  if [[ "${CMD,,}" == "aucune" || "${CMD,,}" == "aucun" ]]; then
    say "feuille de route : pas de test backend"
  else
    IMAGE="$(jq -r --arg s "$SERVICE" --arg p "$APP" '.services[$s].image // ($p + "-" + $s)' <<< "$MODEL")"
    if [[ "$REQ" == 1 ]]; then
      if [[ -n "$(find "$ARBRE" -maxdepth 3 -name .heavy-build -print -quit 2>/dev/null)" ]]; then
        say "dépendances modifiées, app à .heavy-build : pas de reconstruction, dépendances non testées"
        echo "backend=non-testé" > "$TD/resultat.txt"; exit 3
      fi
      IMG_AUTO="${IMAGE%%:*}:auto"
      say "requirements modifiés : reconstruction de $IMG_AUTO"
      if ! x "$AUTO_BUILD_TIMEOUT" docker build -t "$IMG_AUTO" -f "$ARBRE/${CTX:+$CTX/}$DF" "$ARBRE/${CTX:-.}" > "$TD/build.txt" 2>&1; then
        say "reconstruction de l'image impossible"; tail -n 40 "$TD/build.txt"; cp "$TD/build.txt" "$TD/backend.txt"
        echo "backend=ko(build)" > "$TD/resultat.txt"; exit 1
      fi
      IMAGE="$IMG_AUTO"
    fi
    x 20 docker image inspect "$IMAGE" > /dev/null 2>&1 || { say "image $IMAGE absente"; exit 4; }
    WD="$(x 20 docker image inspect -f '{{.Config.WorkingDir}}' "$IMAGE")"; WD="${WD:-/app}"
    DB_HOST_SVC="$(grep -E '^DB_HOST=' "$APP_DIR/.env" 2>/dev/null | tail -1 | cut -d= -f2-)"
    if [[ "$DB_HOST_SVC" == postgis ]]; then PGIMG="${AUTO_PGIS_IMAGE:-$(x 20 docker inspect -f '{{.Config.Image}}' dev-postgis 2>/dev/null)}"
    else PGIMG="${AUTO_PG_IMAGE:-$(x 20 docker inspect -f '{{.Config.Image}}' dev-postgres 2>/dev/null)}"; fi
    [[ -n "$PGIMG" ]] || { say "image PostgreSQL introuvable"; exit 4; }
    # Base jetable, réseau fermé (--internal) : le conteneur de test ne joint que sa base.
    PW="$(LC_ALL=C tr -dc 'a-z0-9' < /dev/urandom | head -c 24)"
    x 30 docker network create --internal --label lab.auto=1 "$NET_T" > /dev/null || exit 4
    POSTGRES_PASSWORD="$PW" x 60 docker run -d --name "$PG" --network "$NET_T" --network-alias auto-pg \
      --label lab.auto=1 -e POSTGRES_USER=admin -e POSTGRES_PASSWORD -e POSTGRES_DB=essai \
      --tmpfs /var/lib/postgresql/data "$PGIMG" > /dev/null || { say "base jetable non démarrée"; exit 4; }
    ok=0; for _ in $(seq 1 60); do x 10 docker exec "$PG" psql -U admin -d essai -c 'select 1' > /dev/null 2>&1 && { ok=1; break; }; sleep 1; done
    (( ok )) || { say "base jetable injoignable"; exit 4; }
    x 30 docker exec "$PG" psql -q -U admin -d essai \
      -c "CREATE ROLE essai LOGIN CREATEDB NOSUPERUSER PASSWORD '$PW'" -c "ALTER DATABASE essai OWNER TO essai" \
      -c "REVOKE CONNECT ON DATABASE postgres FROM PUBLIC" -c "GRANT CONNECT ON DATABASE postgres TO essai" > /dev/null \
      || { say "rôle de test non créé"; exit 4; }
    py env-assaini "$APP_DIR/.env" "$TMPD/env" \
      DB_HOST=auto-pg DB_PORT=5432 DB_NAME=essai DB_USER=essai "DB_PASSWORD=$PW" \
      POSTGIS_HOST=auto-pg POSTGIS_DB=essai POSTGIS_USER=essai "POSTGIS_PASSWORD=$PW" \
      "LAB_TEST_CMD=$CMD" || exit 4
    say "▶ tests backend : $CMD (image $IMAGE)"
    x "$AUTO_TEST_TIMEOUT" docker run --rm --name "$ID" --network "$NET_T" --env-file "$TMPD/env" \
      --label lab.auto=1 --cap-drop ALL --security-opt no-new-privileges \
      --memory 1g --memory-swap 1g --cpus 1 --pids-limit 512 --user "$(id -u):$(id -g)" \
      -e HOME=/tmp -e PYTHONDONTWRITEBYTECODE=1 -v "$ARBRE/${CTX:-.}:$WD:ro" -w "$WD" \
      --entrypoint sh "$IMAGE" -c 'exec sh -c "$LAB_TEST_CMD"' > "$TD/backend.txt" 2>&1
    rc=$?
    if (( rc == 0 )); then BACK=ok; say "✓ backend vert"; else BACK=ko; say "✗ backend rouge (code $rc)"; tail -n 30 "$TD/backend.txt"; fi
  fi
fi

# ── Frontend ──────────────────────────────────────────────────────────────────
if [[ "$FRONT" == 1 && -f "$ARBRE/frontend/package.json" ]]; then
  cp -a "$ARBRE/frontend" "$TMPD/front"; chmod -R u+rwX "$TMPD/front"; chmod 755 "$TMPD"
  if pare_feu 2> "$TMPD/fw.txt" && reseau_creer "$NET_F"; then
    say "▶ frontend : $AUTO_FRONT_CMD"
    x "$AUTO_FRONT_TIMEOUT" docker run --rm --init --name "auto-front-$$" --network "$NET_F" \
      --label lab.auto=1 --cap-drop ALL --security-opt no-new-privileges \
      --memory 2g --memory-swap 2g --cpus 1 --pids-limit 512 --user 1000:1000 \
      -e HOME=/tmp -e AUTO_FRONT_CMD -v "$TMPD/front:/src" -w /src \
      --entrypoint sh "$AUTO_IMAGE" -c 'exec sh -c "$AUTO_FRONT_CMD"' > "$TD/front.txt" 2>&1
    rc=$?
    if (( rc == 0 )); then FRT=ok; say "✓ frontend construit"; else FRT=ko; say "✗ frontend : construction en échec (code $rc)"; tail -n 30 "$TD/front.txt"; fi
  else
    say "pare-feu ou réseau du build frontend indisponible"; cat "$TMPD/fw.txt"; exit 4
  fi
fi

echo "backend=$BACK frontend=$FRT" > "$TD/resultat.txt"
[[ "$BACK" != ko && "$FRT" != ko ]] && exit 0
exit 1
