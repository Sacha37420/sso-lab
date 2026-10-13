#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# scripts/tests/preview/run.sh — essais rejouables de scripts/app-preview.sh
# (chantier « essai-dev », contrat v1, I1) : tout ce qui se prouve SANS monter
# un essai — copie hostile, réécriture, refus du contrôle de sûreté, forme de
# RESULTAT, réservation du préfixe « dev- ».
#
#   bash scripts/tests/preview/run.sh            (sur l'hôte)
#   docker exec lab-mcp bash <racine>/scripts/tests/preview/run.sh   (dans le moteur)
#
# NE TOUCHE À RIEN DU LAB : les scripts sont copiés dans une racine jetable
# (registre, .env, dossier d'état, dossiers de travail à elle) ; l'instance
# PostgreSQL désignée n'existe pas, si bien qu'un essai accepté s'arrête à
# l'étape `schema` — avant tout build, tout client Keycloak, tout conteneur.
# Docker n'est lu qu'en lecture (`docker ps`, `docker compose config`).
# Code : 0 = tout passe ; 1 = au moins un échec.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

REAL="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
T="$(mktemp -d)"
trap 'chmod -R u+rwX "$T" 2>/dev/null; rm -rf "$T"' EXIT
R="$T/lab"; WORKS="$T/work"; STATE="$T/state"
U="zzessai"; N="dev-$U"

PASS=0; FAIL=0
ok()   { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
ko()   { FAIL=$((FAIL + 1)); printf '  ÉCHEC %s\n' "$1"; [[ -z "${2:-}" ]] || printf '        %s\n' "$2"; }
check() { if eval "$2"; then ok "$1"; else ko "$1" "${3:-}"; fi; }
section() { printf '\n── %s\n' "$1"; }

# ── Racine jetable ────────────────────────────────────────────────────────────
mkdir -p "$R/scripts" "$R/deploiement" "$WORKS/$U" "$STATE"
cp "$REAL"/scripts/{app-preview.sh,lab-lock.sh,app-remove.sh,check-app-name.sh,create-app-client.sh,validate-app.sh} "$R/scripts/"
cp -r "$REAL/scripts/lib" "$R/scripts/lib"
cat > "$R/.env" <<EOF
DOMAIN=essai.test
LAB_SUPERUSER=zzsuper
LAB_STATE_DIR=$STATE
LAB_WORK_DIR=$WORKS
EOF
: > "$R/.ports"; : > "$R/.owners"

# Lancement : environnement réduit, instance PostgreSQL inexistante.
RUNENV=(env -i "PATH=$PATH" "HOME=$T" PG_CONTAINER=lab-essai-test-absent GIS_CONTAINER=lab-essai-test-absent
        LAB_PREVIEW_KEEP_FAILED=1 LAB_LOCK_TIMEOUT=30)
OUT=""; RC=0; RES=""
pv() {   # pv <args de app-preview.sh…>  — sous le verrou (de la racine jetable)
  OUT="$("${RUNENV[@]}" "${EXTRA[@]}" bash "$R/scripts/lab-lock.sh" bash "$R/scripts/app-preview.sh" "$@" 2>&1)"; RC=$?
  RES="$(printf '%s\n' "$OUT" | tail -1 | sed -n 's/^RESULTAT=//p')"
}
EXTRA=()
step()    { jq -r '.step // empty' <<< "$RES" 2>/dev/null; }
reasons() { jq -r '.reasons[]?' <<< "$RES" 2>/dev/null; }
last_build() { ls -d "$STATE/preview/$U/builds"/*/ 2>/dev/null | tail -1 | sed 's|/$||'; }
reset_state() { chmod -R u+rwX "$STATE/preview" 2>/dev/null; rm -rf "$STATE/preview"; }

# mkapp <app> <chemin caddy> <groupes> — un projet à la forme du gabarit :
# dossier de service (deploiement/, .env, .keycloak-client-opts) et dossier de travail.
mkapp() {
  local app="$1" cp="$2" groups="$3" svc="$R/deploiement/$1" w="$WORKS/$U/$1" slug="${1//-/_}"
  rm -rf "$svc" "$w"; mkdir -p "$svc" "$w/backend" "$w/frontend"
  grep -q "^$app:" "$R/.ports" || echo "$app:18000:14000" >> "$R/.ports"
  grep -q "^$app:" "$R/.owners" || echo "$app:$U" >> "$R/.owners"
  echo "--public --port 14000 --caddy-path $cp --require-group $groups" > "$svc/.keycloak-client-opts"
  cat > "$svc/.env" <<EOF
# .env de SERVICE (jamais lu dans le dossier de travail)
PORT_BACKEND=18000
BACKEND_URL=http://localhost:18000
DB_HOST=postgres
DB_NAME=dev_$U
DB_SCHEMA=$slug
DB_USER=dev_$U
DB_PASSWORD=SENTINELLE_MDP_BASE_0123456789
SECRET_KEY=SENTINELLE_CLE_DJANGO_0123456789
DOMAIN=CHANGE_ME
KEYCLOAK_CLIENT_ID=$app
KEYCLOAK_REQUIRED_GROUPS=$groups
KEYCLOAK_ADMIN_CLIENT_ID=$app-admin
KEYCLOAK_ADMIN_CLIENT_SECRET=SENTINELLE_COMPTE_SERVICE_0123456789
SCRIPT_NAME=/$cp-api
EMAIL_HOST=smtp.exemple.test
EMAIL_HOST_PASSWORD=SENTINELLE_SMTP_0123456789
DEFAULT_FROM_EMAIL=app@exemple.test
LAB_SMTP_PROFILE=p1
COMPOSE_FILE=/etc/passwd
API_TIERCE_KEY=SENTINELLE_CLE_LIBRE_0123456789
EOF
  cp "$svc/.env" "$svc/.env.orig"
  cat > "$svc/docker-compose.yml" <<EOF
services:
  backend:
    build: ./backend
EOF
  cat > "$w/docker-compose.yml" <<EOF
version: "3.9"
networks:
  sso-net:
    external: true
    name: sso-lab_sso-net
  dev-net:
    external: true
    name: dev-net
services:
  backend:
    build: ./backend
    container_name: $app-backend
    restart: unless-stopped
    env_file: .env
    ports:
      - "18000:8000"
    networks: [sso-net, dev-net]
    labels:
      caddy: "\${DOMAIN}"
      caddy.handle_path: "/$cp-api/*"
      caddy.handle_path.reverse_proxy: "{{upstreams 8000}}"
  frontend:
    build: ./frontend
    container_name: $app-frontend
    restart: unless-stopped
    environment:
      DOMAIN: \${DOMAIN:-}
      KEYCLOAK_CLIENT_ID: \${KEYCLOAK_CLIENT_ID:-}
    ports:
      - "14000:80"
    networks: [sso-net]
    labels:
      caddy: "\${DOMAIN}"
      caddy.handle_path: "/$cp/*"
      caddy.handle_path.reverse_proxy: "{{upstreams 80}}"
EOF
  cat > "$w/frontend/nginx.conf" <<EOF
server {
    listen 80;
    location / {
        try_files \$uri \$uri/ /index.html;
        sub_filter '<base href="/">' '<base href="/$cp/">';
        sub_filter_once on;
    }
}
EOF
  cat > "$w/frontend/nginx-entrypoint.sh" <<EOF
#!/bin/sh
cat > /usr/share/nginx/html/assets/env.js << JSEOF
window.__env = {
  keycloakClientId: "\${KEYCLOAK_CLIENT_ID}",
  apiUrl:           "https://\${DOMAIN}/$cp-api",
  appUrl:           "https://\${DOMAIN}/$cp/"
};
JSEOF
EOF
  echo "FROM scratch" > "$w/backend/Dockerfile"; echo "FROM scratch" > "$w/frontend/Dockerfile"
  printf '.env\n*.env\nnode_modules/\nignore-moi.txt\n' > "$w/.gitignore"
  echo "version commitée" > "$w/backend/app.py"
  ( cd "$w" && git init -q -b main && git add -A && git -c user.name=t -c user.email=t@t commit -q -m init ) > /dev/null 2>&1
}
tree_sum() { ( cd "$1" && find . -path ./.git -prune -o \( -type f -o -type l \) -print0 | sort -z | xargs -0 sha256sum 2>/dev/null; find . -path ./.git -prune -o -print | sort ) | sha256sum; }
compose() { jq "$@" "$(last_build)/.lab-essai.compose.json" 2>/dev/null; }
has_reason() { reasons | grep -q -- "$1"; }

# ══════════════════════════════════════════════════════════════════════════════
section "1. Chemin nominal (arrêt voulu à l'étape schema : aucune base, aucun build)"
mkapp mon-app lora "developers,amis"
W="$WORKS/$U/mon-app"
echo "MODIFIÉ, NON COMMITÉ" > "$W/backend/app.py"
echo "nouveau fichier jamais ajouté" > "$W/backend/nouveau.py"
echo "ignoré" > "$W/ignore-moi.txt"; mkdir -p "$W/node_modules/x"; echo x > "$W/node_modules/x/y.js"
echo "SECRET_KEY=SENTINELLE_ENV_DU_DOSSIER_DE_TRAVAIL" > "$W/.env"
echo "--public --require-group admins" > "$W/.keycloak-client-opts"
echo "manage-users" > "$W/.keycloak-service-account-roles"
printf 'un nom\navec retour à la ligne' > "$T/nl"; echo "espaces" > "$W/backend/un fichier à espaces é.txt"
echo "retour" > "$W/backend/$(cat "$T/nl")"
chmod +x "$W/frontend/nginx-entrypoint.sh"
SUM_W="$(tree_sum "$W")"; SUM_S="$(tree_sum "$R/deploiement/mon-app")"; GIT_W="$(git -C "$W" status --porcelain | sha256sum)"
pv up "$U" mon-app
B="$(last_build)"
check "code 1, arrêt à l'étape schema (tout ce qui précède est passé)" '[[ $RC -eq 1 && "$(step)" == "schema" ]]' "rc=$RC step=$(step) : $(printf '%s' "$OUT" | tail -3)"
check "dernière ligne = RESULTAT=<JSON> {ok:false, step, error, reasons[]}" 'jq -e ".ok == false and (.step|type==\"string\") and (.error|type==\"string\") and (.reasons|type==\"array\")" <<< "$RES" > /dev/null'
check "modification non commitée dans la copie" 'grep -q "MODIFIÉ, NON COMMITÉ" "$B/backend/app.py"'
check "fichier jamais ajouté à git dans la copie" '[[ -f "$B/backend/nouveau.py" ]]'
check "fichiers ignorés absents (ignore-moi.txt, node_modules)" '[[ ! -e "$B/ignore-moi.txt" && ! -e "$B/node_modules" ]]'
check ".git, .keycloak-client-opts, .keycloak-service-account-roles absents de la copie" '[[ ! -e "$B/.git" && ! -e "$B/.keycloak-client-opts" && ! -e "$B/.keycloak-service-account-roles" ]]'
check "le .env du dossier de travail n'est pas copié (celui de la copie vient du service)" '! grep -q SENTINELLE_ENV_DU_DOSSIER_DE_TRAVAIL "$B/.env"'
check "noms de fichiers quelconques (espaces, accent, retour à la ligne)" '[[ -f "$B/backend/un fichier à espaces é.txt" && -f "$B/backend/$(cat "$T/nl")" ]]'
check "bit exécutable gardé, rien d'autre" '[[ "$(stat -c %a "$B/frontend/nginx-entrypoint.sh")" == "755" && "$(stat -c %a "$B/backend/app.py")" == "644" ]]'
check "aucune section ports" '[[ "$(compose "[.services[] | has(\"ports\")] | any")" == "false" ]]'
check "container_name = dev-<uid>-<service>" '[[ "$(compose -c "[.services[].container_name]")" == "[\"$N-backend\",\"$N-frontend\"]" ]]'
check "étiquettes Caddy : /lora-api → /dev-<uid>-api, /lora → /dev-<uid>" '[[ "$(compose -r ".services.backend.labels[\"caddy.handle_path\"]")" == "/$N-api/*" && "$(compose -r ".services.frontend.labels[\"caddy.handle_path\"]")" == "/$N/*" ]]'
check "projet Compose nommé dev-<uid>, plafonds posés, pas de redémarrage" '[[ "$(compose -r ".name")" == "$N" && "$(compose -r ".services.backend.mem_limit")" == "1g" && "$(compose -r ".services.backend.restart")" == "no" ]]'
check "nginx.conf : <base href=\"/dev-<uid>/\">" 'grep -qF "<base href=\"/$N/\">" "$B/frontend/nginx.conf" && ! grep -q "/lora" "$B/frontend/nginx.conf"'
check "nginx-entrypoint.sh : apiUrl /dev-<uid>-api, appUrl /dev-<uid>/" 'grep -qF "\${DOMAIN}/$N-api\"" "$B/frontend/nginx-entrypoint.sh" && grep -qF "\${DOMAIN}/$N/\"" "$B/frontend/nginx-entrypoint.sh" && ! grep -q "/lora" "$B/frontend/nginx-entrypoint.sh"'
E="$B/.env"
check ".env de l'essai en mode 600" '[[ "$(stat -c %a "$E")" == "600" ]]'
check "KEYCLOAK_CLIENT_ID, DB_SCHEMA, SCRIPT_NAME, DOMAIN de l'essai" 'grep -qx "KEYCLOAK_CLIENT_ID=$N" "$E" && grep -qx "DB_SCHEMA=mon_app__essai" "$E" && grep -qx "SCRIPT_NAME=/$N-api" "$E" && grep -qx "DOMAIN=essai.test" "$E"'
check "le schéma de l'app en service n'est nulle part dans le .env de l'essai" '! grep -qE "=mon_app\$" "$E"'
check "SECRET_KEY propre à l'essai" 'grep -q "^SECRET_KEY=" "$E" && ! grep -q SENTINELLE_CLE_DJANGO "$E"'
check "compte de service, email, marqueur SMTP, COMPOSE_* retirés" '! grep -qE "^(KEYCLOAK_ADMIN_CLIENT_ID|KEYCLOAK_ADMIN_CLIENT_SECRET|EMAIL_|DEFAULT_FROM_EMAIL|LAB_SMTP_PROFILE|COMPOSE_)" "$E"'
check "groupes requis de l'app dans le .env de l'essai" 'grep -qx "KEYCLOAK_REQUIRED_GROUPS=developers,amis" "$E"'
check "une clé libre du développeur est gardée" 'grep -q "^API_TIERCE_KEY=SENTINELLE_CLE_LIBRE" "$E"'
check "aucun secret ni contenu de .env sur stdout" '! grep -q SENTINELLE <<< "$OUT" && ! grep -qE "^[[:space:]]*(DB_PASSWORD|SECRET_KEY)=" <<< "$OUT"'
check "rien d'écrit dans le dossier de travail" '[[ "$(tree_sum "$W")" == "$SUM_W" && "$(git -C "$W" status --porcelain | sha256sum)" == "$GIT_W" ]]'
check "rien d'écrit dans deploiement/<app>" '[[ "$(tree_sum "$R/deploiement/mon-app")" == "$SUM_S" ]]'
check "aucun état d'essai « en service » laissé par un échec avant client" '[[ ! -e "$STATE/preview/$U/state.json" ]]'
unset 'RUNENV[6]'; RUNENV=("${RUNENV[@]}")
reset_state; pv up "$U" mon-app
check "sans LAB_PREVIEW_KEEP_FAILED, le dossier d'un essai refusé est retiré" '[[ -z "$(last_build)" ]]'
RUNENV+=(LAB_PREVIEW_KEEP_FAILED=1)

# ══════════════════════════════════════════════════════════════════════════════
section "2. La copie est lue comme une donnée hostile"
reset_state; mkapp mon-app mon-app developers
ln -s /etc/passwd "$W/backend/lien.txt"
pv up "$U" mon-app
check "lien symbolique vers un fichier : refus à l'étape source" '[[ $RC -eq 1 && "$(step)" == "source" ]] && has_reason "lien symbolique refusé"' "step=$(step) $(reasons | head -2)"
rm "$W/backend/lien.txt"; mkdir "$T/dehors"; echo "SENTINELLE_HORS_DOSSIER" > "$T/dehors/secret.txt"
( cd "$W" && git add -A && git -c user.name=t -c user.email=t@t commit -qm x ) > /dev/null 2>&1
mv "$W/backend" "$W/backend.vrai"; ln -s "$T/dehors" "$W/backend"
# l'index nomme encore backend/app.py : le chemin traverse maintenant un lien
pv up "$U" mon-app
check "dossier remplacé par un lien (chemin d'index traversant) : refus, rien n'est lu de l'autre côté" '[[ "$(step)" == "source" ]] && ! grep -rq SENTINELLE_HORS_DOSSIER "$STATE/preview" 2>/dev/null' "step=$(step)"
rm "$W/backend"; mv "$W/backend.vrai" "$W/backend"
mkfifo "$W/backend/tube"
reset_state; pv up "$U" mon-app
check "tube nommé jamais ajouté à git : pas listé, pas copié, pas de blocage" '[[ "$(step)" == "schema" && ! -e "$(last_build)/backend/tube" ]]' "step=$(step)"
rm "$W/backend/tube"; rm "$W/backend/app.py"; mkfifo "$W/backend/app.py"
pv up "$U" mon-app
check "fichier suivi remplacé par un tube nommé : refus à l'étape source (pas de blocage)" '[[ "$(step)" == "source" ]] && has_reason "fichier spécial"' "step=$(step)"
rm "$W/backend/app.py"; echo "version commitée" > "$W/backend/app.py"
EXTRA=(LAB_PREVIEW_MAX_FILES=3); pv up "$U" mon-app; EXTRA=()
check "plafond du nombre de fichiers" '[[ "$(step)" == "source" ]] && has_reason "plafond"'
head -c 300000 /dev/zero > "$W/backend/gros.bin"
EXTRA=(LAB_PREVIEW_MAX_BYTES=100000); pv up "$U" mon-app; EXTRA=()
check "plafond de taille" '[[ "$(step)" == "source" ]] && has_reason "Mo — plafond"'
rm "$W/backend/gros.bin"

# Configuration git hostile : core.fsmonitor lance une commande à chaque `git status`.
cat > "$T/piege.sh" <<EOF
#!/bin/sh
touch "$T/PIEGE_EXECUTE"
EOF
chmod +x "$T/piege.sh"
git -C "$W" config core.fsmonitor "$T/piege.sh"
git -C "$W" config core.hooksPath "$T"
git -C "$W" status > /dev/null 2>&1
check "(témoin) ce piège s'exécute bien avec un git lancé naïvement dans le dossier" '[[ -e "$T/PIEGE_EXECUTE" ]]'
rm -f "$T/PIEGE_EXECUTE"
reset_state; pv up "$U" mon-app
check "configuration git hostile (core.fsmonitor) : jamais exécutée par l'essai" '[[ ! -e "$T/PIEGE_EXECUTE" && "$(step)" == "schema" ]]' "step=$(step)"
git -C "$W" config --unset core.fsmonitor; git -C "$W" config --unset core.hooksPath
echo "x" > "$W/.lab-essai.compose.json"
reset_state; pv up "$U" mon-app
check "un fichier nommé comme le compose de l'essai n'est pas pris au dépôt" '[[ "$(step)" == "schema" ]] && jq -e ".name == \"$N\"" "$(last_build)/.lab-essai.compose.json" > /dev/null'
rm -f "$W/.lab-essai.compose.json"

# ══════════════════════════════════════════════════════════════════════════════
section "3. Réécriture entière ou refusée"
# rw <description> <motif attendu dans les raisons> — le compose du dossier de travail vient d'être modifié
rw() { reset_state; pv up "$U" mon-app; local motif="$2"; check "$1 → refus à l'étape rewrite" '[[ $RC -eq 1 && "$(step)" == "rewrite" ]] && has_reason "$motif"' "step=$(step) : $(reasons | head -2)"; check "   … et rien n'est réécrit à moitié (aucun compose d'essai produit)" '[[ ! -e "$(last_build)/.lab-essai.compose.json" ]]'; }
for cible in "/storage/*" "/*" "/dev-autre/*" "/mon-app-admin/*" "/mon-appX/*"; do
  mkapp mon-app mon-app developers
  sed -i "s|caddy.handle_path: \"/mon-app-api/\*\"|caddy.handle_path: \"$cible\"|" "$W/docker-compose.yml"
  rw "étiquette Caddy vers $cible" "ne sait déplacer que"
done
mkapp mon-app mon-app developers
sed -i 's|caddy.handle_path: "/mon-app/\*"|caddy.handle_path: "/${CHEMIN}/*"|' "$W/docker-compose.yml"
rw "chemin Caddy par variable" "ne sait déplacer que"
mkapp mon-app mon-app developers
sed -i 's|<base href="/mon-app/">|<base href="/ailleurs/">|' "$W/frontend/nginx.conf"
rw "nginx.conf qui s'écarte du gabarit" "nginx.conf"
check "   … nginx-entrypoint.sh n'a pas été réécrit alors que nginx.conf est refusé" 'grep -q "/mon-app-api" "$(last_build)/frontend/nginx-entrypoint.sh"'
mkapp mon-app mon-app developers
rm "$W/frontend/nginx-entrypoint.sh"
rw "nginx-entrypoint.sh absent" "nginx-entrypoint.sh absent"
mkapp mon-app mon-app developers
printf 'volumes:\n  media:\n    name: storage-media\n' >> "$W/docker-compose.yml"
rw "volume au nom imposé d'une autre app" "nom imposé"
mkapp mon-app mon-app developers
echo "  ceci: [n'est pas du YAML" >> "$W/docker-compose.yml"
rw "docker-compose.yml illisible" "illisible"

# ══════════════════════════════════════════════════════════════════════════════
section "4. Contournements : la copie RÉÉCRITE passe le contrôle de sûreté complet"
# vd <description> <code de raison attendu> — refus à l'étape validate
vd() { reset_state; pv up "$U" mon-app; local code="$2"; check "$1 → refus [$2]" '[[ $RC -eq 1 && "$(step)" == "validate" ]] && has_reason "^\[$code\]"' "step=$(step) : $(reasons | head -3)"; }
# inj <lignes YAML ajoutées au service backend>
inj() { mkapp mon-app mon-app developers; python3 - "$W/docker-compose.yml" "$1" <<'PY'
import sys
p, extra = sys.argv[1], sys.argv[2]
s = open(p).read()
s = s.replace("    container_name: mon-app-backend\n", "    container_name: mon-app-backend\n" + extra + "\n", 1)
open(p, "w").write(s)
PY
}
inj '    privileged: true';                           vd "privileged" privileged
inj '    cap_add: [SYS_ADMIN]';                       vd "cap_add" cap_add
inj '    volumes: ["/etc:/hote"]';                    vd "montage hors du dossier (/etc)" bind
inj '    volumes: ["../../..:/hote"]';                vd "montage hors du dossier (../../..)" bind
inj '    volumes: ["/var/run/docker.sock:/var/run/docker.sock"]'; vd "docker.sock" docker.sock
mkapp mon-app mon-app developers
printf '  hote:\n    image: nginx:alpine\n    network_mode: host\n' >> "$W/docker-compose.yml"
vd "network_mode: host" network_mode
inj '    pid: host';                                  vd "pid: host" pid
inj '    devices: ["/dev/sda:/dev/sda"]';             vd "devices" devices
inj '    security_opt: ["seccomp:unconfined"]';       vd "security_opt" "clé"
mkapp mon-app mon-app developers
sed -i 's|    env_file: .env|    env_file: ["../../../../.env"]|' "$W/docker-compose.yml"
vd "env_file pointant ailleurs" env_file
mkapp mon-app mon-app developers
python3 - "$W/docker-compose.yml" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
s = s.replace("networks:\n", "networks:\n  autre:\n    external: true\n    name: infra_default\n", 1)
s = s.replace("    networks: [sso-net, dev-net]", "    networks: [sso-net, dev-net, autre]", 1)
open(p, "w").write(s)
PY
vd "réseau externe autre que dev-net/sso-net" network
mkapp mon-app mon-app developers
python3 - "$W/docker-compose.yml" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
s += "  keycloak:\n    image: nginx:alpine\n    networks: [sso-net]\n"
open(p, "w").write(s)
PY
vd "service nommé keycloak sur sso-net (usurpation DNS)" service
inj '    labels:
      caddy: "autre.exemple.test"
      caddy.handle_path: "/mon-app-api/*"
      caddy.handle_path.reverse_proxy: "{{upstreams 8000}}"'
python3 - "$W/docker-compose.yml" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
i = s.index("    labels:\n      caddy: \"${DOMAIN}\"")
j = s.index("  frontend:")
s = s[:i] + s[j:]
open(p, "w").write(s)
PY
vd "étiquette caddy: autre site" caddy
inj '    labels:
      caddy: "${DOMAIN}"
      caddy.handle_path: "/mon-app-api/*"
      caddy.handle_path.reverse_proxy: "http://storage-backend:8000"'
python3 - "$W/docker-compose.yml" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
i = s.index("    labels:\n      caddy: \"${DOMAIN}\"\n      caddy.handle_path: \"/mon-app-api/*\"\n      caddy.handle_path.reverse_proxy: \"{{")
j = s.index("  frontend:")
s = s[:i] + s[j:]
open(p, "w").write(s)
PY
vd "reverse_proxy vers le conteneur d'une autre app" caddy
inj '    labels:
      caddy: "${DOMAIN}"
      caddy.handle_path: "/mon-app-api/*"
      caddy.handle_path.reverse_proxy: "{{upstreams 8000}}"
      caddy.respond: "/storage/* 200"'
python3 - "$W/docker-compose.yml" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
i = s.index("    labels:\n      caddy: \"${DOMAIN}\"\n      caddy.handle_path: \"/mon-app-api/*\"\n      caddy.handle_path.reverse_proxy: \"{{upstreams 8000}}\"\n  frontend:")
j = s.index("  frontend:")
s = s[:i] + s[j:]
open(p, "w").write(s)
PY
vd "directive Caddy au niveau du site" caddy

# include: d'un second fichier qui porte un service privilégié
mkapp mon-app mon-app developers
printf 'services:\n  intrus:\n    image: alpine\n    privileged: true\n    ports: ["19999:80"]\n' > "$W/second.yml"
sed -i '1a include:\n  - second.yml' "$W/docker-compose.yml"
vd "second fichier amené par include:" privileged
# include: d'un fichier HORS du dossier (le compose d'une autre app)
mkapp mon-app mon-app developers
printf 'services:\n  intrus:\n    image: alpine\n    volumes: ["./donnees:/d"]\n' > "$T/dehors/docker-compose.yml"
sed -i "1a include:\n  - $T/dehors/docker-compose.yml" "$W/docker-compose.yml"
vd "include: d'un fichier hors du dossier" bind

# Ce qui doit être NEUTRALISÉ par la réécriture, et l'essai accepté quand même
# acc <description> <test>
acc() { reset_state; pv up "$U" mon-app; check "$1" '[[ "$(step)" == "schema" ]] && '"$2" "step=$(step) : $(reasons | head -3)"; }
NO_PORT='[[ "$(compose "[.services[] | has(\"ports\")] | any")" == "false" ]]'
mkapp mon-app mon-app developers
python3 - "$W/docker-compose.yml" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
s = s.replace("services:\n", "x-pub: &pub\n  ports:\n    - \"19998:8000\"\nservices:\n", 1)
s = s.replace("    container_name: mon-app-backend\n", "    container_name: mon-app-backend\n    <<: *pub\n", 1)
s = s.replace("    ports:\n      - \"18000:8000\"\n", "", 1)
open(p, "w").write(s)
PY
acc "port publié réintroduit par une ancre YAML : retiré" "$NO_PORT"
mkapp mon-app mon-app developers
printf 'services:\n  socle:\n    ports: ["19997:8000"]\n' > "$W/socle.yml"
python3 - "$W/docker-compose.yml" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
s = s.replace("    container_name: mon-app-backend\n", "    container_name: mon-app-backend\n    extends:\n      file: socle.yml\n      service: socle\n", 1)
open(p, "w").write(s)
PY
acc "port publié réintroduit par extends : retiré" "$NO_PORT"
mkapp mon-app mon-app developers
printf 'services:\n  backend:\n    privileged: true\n    ports: ["19996:8000"]\n' > "$W/docker-compose.override.yml"
acc "docker-compose.override.yml (second fichier implicite) : jamais lu" "$NO_PORT"' && [[ "$(compose ".services.backend.privileged")" == "null" ]]'
mkapp mon-app mon-app developers
sed -i 's|container_name: mon-app-backend|container_name: storage-backend|' "$W/docker-compose.yml"
acc "container_name usurpant un conteneur existant : remplacé par dev-<uid>-backend" '[[ "$(compose -r ".services.backend.container_name")" == "'"$N"'-backend" ]]'
inj '    image: storage-backend'
acc "image: <app en service> sur un service construit : retirée (l'essai ne reconstruit pas l'image d'une app)" '[[ "$(compose ".services.backend.image")" == "null" ]]'
inj '    build:
      context: ./backend
      tags: ["lab-admin-backend:latest"]'
sed -i '0,/    build: .\/backend/{/    build: .\/backend/d}' "$W/docker-compose.yml"
acc "build.tags vers l'image d'une autre app : retiré" '[[ "$(compose ".services.backend.build.tags")" == "null" ]]'
inj '    deploy:
      resources:
        limits:
          memory: 64g'
acc "plafond mémoire du dépôt remplacé par celui de l'essai" '[[ "$(compose -r ".services.backend.mem_limit")" == "1g" && "$(compose ".services.backend.deploy")" == "null" ]]'
mkapp mon-app mon-app developers
printf 'volumes:\n  media:\n    name: mon-app-media\n' >> "$W/docker-compose.yml"
acc "volume nommé « <app>-… » : l'essai a le sien (dev-<uid>-…), pas les données de l'app" '[[ "$(compose -r ".volumes.media.name")" == "'"$N"'-media" ]]'

# ══════════════════════════════════════════════════════════════════════════════
section "5. Étape arguments, usage, verrou"
reset_state; mkapp mon-app mon-app developers
pv up "Pas_Un_Uid" mon-app;      check "uid malformé → arguments" '[[ $RC -eq 1 && "$(step)" == "arguments" ]]'
pv up "$U" "../x";               check "nom d'app malformé → arguments" '[[ $RC -eq 1 && "$(step)" == "arguments" ]]'
pv up "$U" inconnue;             check "projet inconnu → arguments" '[[ $RC -eq 1 && "$(step)" == "arguments" ]]'
pv up autre mon-app;             check "app d'un autre propriétaire → arguments" '[[ $RC -eq 1 && "$(step)" == "arguments" ]] && grep -q "appartient pas" <<< "$OUT"'
mv "$W" "$W.parti"; pv up "$U" mon-app; mv "$W.parti" "$W"
check "pas de dossier de travail → arguments" '[[ $RC -eq 1 && "$(step)" == "arguments" ]] && grep -q "dossier de travail" <<< "$OUT"'
sed -i 's/^DOMAIN=.*/DOMAIN=CHANGE_ME/' "$R/.env"; pv up "$U" mon-app; sed -i 's/^DOMAIN=.*/DOMAIN=essai.test/' "$R/.env"
check "lab sans domaine → arguments (pas d'essai en HTTP local)" '[[ $RC -eq 1 && "$(step)" == "arguments" ]] && grep -q "domaine" <<< "$OUT"'
sed -i 's/^DB_NAME=.*/DB_NAME=dev_quelquunautre/' "$R/deploiement/mon-app/.env"; pv up "$U" mon-app
check "le .env de service désigne la base d'un autre → refus à l'étape env" '[[ $RC -eq 1 && "$(step)" == "env" ]]' "step=$(step)"
OUT="$("${RUNENV[@]}" bash "$R/scripts/app-preview.sh" up "$U" mon-app 2>&1)"; RC=$?
check "up sans le verrou → code 2, rien n'est fait" '[[ $RC -eq 2 ]] && grep -q "verrou" <<< "$OUT" && [[ "$(tail -1 <<< "$OUT")" == RESULTAT=* ]]'
OUT="$("${RUNENV[@]}" bash "$R/scripts/app-preview.sh" down "$U" 2>&1)"; RC=$?
check "down sans le verrou → code 2" '[[ $RC -eq 2 ]]'
pv; check "sans argument → code 2" '[[ $RC -eq 2 ]]'
pv up "$U"; check "up sans app → code 2" '[[ $RC -eq 2 ]]'
pv redeploie "$U"; check "sous-commande inconnue → code 2" '[[ $RC -eq 2 ]]'

section "6. status et down sans essai"
reset_state
OUT="$("${RUNENV[@]}" bash "$R/scripts/app-preview.sh" status "$U" 2>&1)"; RC=$?
check "status (sans verrou) : forme « absent » exacte" '[[ $RC -eq 0 && "$OUT" == "RESULTAT={\"uid\":\"'"$U"'\",\"state\":\"absent\",\"app\":null,\"url\":null,\"api_url\":null,\"groups\":[],\"built_at\":null,\"services\":[]}" ]]' "$OUT"
pv down "$U"
check "down sans essai : {ok:true, uid, stopped:false}" '[[ $RC -eq 0 && "$RES" == "{\"ok\":true,\"uid\":\"'"$U"'\",\"stopped\":false}" ]]' "$RES"

# ══════════════════════════════════════════════════════════════════════════════
section "7. validate_compose.py — règle [image] (ajoutée) et non-régression"
vc() { python3 -B "$REAL/scripts/lib/validate_compose.py" appli "$T/vc" exemple.test "8000,4000" /dev/null <<< "$1" || true; }
mkdir -p "$T/vc/backend"
BASE='{"name":"appli","networks":{"dev-net":{"external":true,"name":"dev-net"}},"services":{"backend":{"build":{"context":"'"$T"'/vc/backend","dockerfile":"Dockerfile"},"container_name":"appli-backend","networks":{"dev-net":null},"ports":[{"mode":"ingress","target":8000,"published":"8000","protocol":"tcp"}],"labels":{"caddy":"exemple.test","caddy.handle_path":"/appli-api/*","caddy.handle_path.reverse_proxy":"{{upstreams 8000}}"}}}}'
check "modèle du gabarit toujours accepté (aucune raison)" '[[ -z "$(vc "$BASE")" ]]' "$(vc "$BASE")"
check "image: storage-backend + build → [image]" 'vc "$(jq -c ".services.backend.image = \"storage-backend\"" <<< "$BASE")" | grep -q "^\[image\]"'
check "build.tags: lab-mcp-lab-mcp:latest → [image]" 'vc "$(jq -c ".services.backend.build.tags = [\"lab-mcp-lab-mcp:latest\"]" <<< "$BASE")" | grep -q "^\[image\]"'
check "image: appli-backend:v2 + build → accepté" '[[ -z "$(vc "$(jq -c ".services.backend.image = \"appli-backend:v2\"" <<< "$BASE")")" ]]'
check "image tierce SANS build (redis:7-alpine) → accepté, comme avant" '[[ -z "$(vc "$(jq -c ".services[\"appli-cache\"] = {image: \"redis:7-alpine\"}" <<< "$BASE")")" ]]'
check "port hors .ports toujours refusé [ports]" 'vc "$(jq -c ".services.backend.ports[0].published = \"9\"" <<< "$BASE")" | grep -q "^\[ports\]"'

section "8. Réservation du préfixe « dev- » (scripts/check-app-name.sh du dépôt)"
for n in dev-quelquechose "dev-$U" dev-api dev; do
  O="$(bash "$REAL/scripts/check-app-name.sh" "$n" 2>&1)"; C=$?
  check "« $n » refusé avec la raison du préfixe réservé" '[[ $C -eq 1 ]] && grep -q "préfixe réservé aux adresses d.essai des développeurs" <<< "$O"' "$O"
done
for n in device-lab zz-essai-nom-libre developpement; do
  O="$(bash "$REAL/scripts/check-app-name.sh" "$n" 2>&1)"; C=$?
  check "« $n » : la règle du préfixe ne s'applique pas" '! grep -q "règle 8" <<< "$O"' "$O"
  if grep -q "non vérifiable" <<< "$O"; then printf '        (Keycloak injoignable d'"'"'ici : acceptation complète non vérifiée pour « %s »)\n' "$n"
  else check "« $n » accepté comme avant (code 0, rien sur stdout)" '[[ $C -eq 0 && -z "$O" ]]' "$O"; fi
done

section "9. Retrait d'une app (scripts/app-remove.sh) : l'essai qui la montre est démonté"
# Racine jetable : ni Keycloak (pas de sso-lab/.env), ni base « dev_$U » — rien du lab n'est modifié.
reset_state; mkapp mon-app mon-app developers; mkapp autre-app autre-app developers
mkdir -p "$STATE/preview/$U/builds/ancien"; echo reste > "$STATE/preview/$U/builds/ancien/f"
jq -cn --arg u "$U" '{uid: $u, app: "mon-app", url: null, api_url: null, groups: [], built_at: null, services: []}' > "$STATE/preview/$U/state.json"
O="$("${RUNENV[@]}" bash "$R/scripts/app-remove.sh" autre-app --yes 2>&1)"
check "retrait d'un AUTRE projet du même développeur : son essai n'est pas touché" '[[ -s "$STATE/preview/$U/state.json" && -e "$STATE/preview/$U/builds/ancien/f" ]]' "$(tail -3 <<< "$O")"
O="$("${RUNENV[@]}" bash "$R/scripts/app-remove.sh" mon-app --yes 2>&1)"
check "retrait du projet que montre l'essai : essai démonté (état et dossiers retirés)" '[[ ! -e "$STATE/preview/$U/state.json" && ! -e "$STATE/preview/$U/builds/ancien" ]] && grep -q "adresse d.essai dev-$U montre" <<< "$O"' "$(tail -5 <<< "$O")"
check "   … et le retrait va au bout (dossier et registre)" '[[ ! -d "$R/deploiement/mon-app" ]] && ! grep -qs "^mon-app:" "$R/.owners"' "$(tail -5 <<< "$O")"

section "10. Divers"
check "redact : masque les valeurs secrètes d'un .env, garde le reste" '[[ "$(printf "mdp=SENTINELLE_MDP_BASE_0123456789 base=dev_x\n" | python3 -B "$REAL/scripts/lib/preview.py" redact <(printf "DB_PASSWORD=SENTINELLE_MDP_BASE_0123456789\nKEYCLOAK_URL=https://exemple.test/auth\n"))" == "mdp=(masqué) base=dev_x" ]]'
check "create-app-client.sh documente --exact-groups" 'grep -q -- "--exact-groups" <(bash "$REAL/scripts/create-app-client.sh" --help 2>&1)'
for f in app-preview.sh check-app-name.sh app-remove.sh validate-app.sh create-app-client.sh; do
  check "bash -n scripts/$f" 'bash -n "$REAL/scripts/$f"'
done
check "aucun conteneur, volume ni image $N laissé par ces essais" '[[ -z "$(docker ps -aq --filter "label=com.docker.compose.project=$N" 2>/dev/null)$(docker image ls -q --filter "reference=$N-*" 2>/dev/null)" ]]'

printf '\n%d contrôle(s) passé(s), %d en échec.\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
