#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# new-app.sh — Initialise une nouvelle application dans dev/
#
# Types supportés :
#   1) Spring Boot seul
#   2) Spring Boot + Angular
#   3) Django seul
#   4) Django + Angular
#   5) Angular seul
#
# Prérequis : docker, curl, unzip
# Usage     : bash new-app.sh
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

# ── Couleurs ──────────────────────────────────────────────────────────────────
BOLD='\033[1m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; RED='\033[0;31m'; CYAN='\033[0;36m'; NC='\033[0m'

step() { echo -e "\n${BOLD}${BLUE}▶ $*${NC}"; }
ok()   { echo -e "  ${GREEN}✔ $*${NC}"; }
warn() { echo -e "  ${YELLOW}⚠ $*${NC}"; }
err()  { echo -e "\n${RED}${BOLD}✘ Erreur : $*${NC}\n" >&2; exit 1; }
info() { echo -e "  ${CYAN}→ $*${NC}"; }

DEV_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_SCHEMAS="$DEV_DIR/infra/init/00_schemas.sql"
DOCKER_UID="$(id -u):$(id -g)"
PORTS_REGISTRY="$DEV_DIR/.ports"

# ── Initialisation du registre des ports ─────────────────────────────────────
# Créé au premier lancement avec les ports déjà réservés par l'infrastructure.
if [[ ! -f "$PORTS_REGISTRY" ]]; then
  cat > "$PORTS_REGISTRY" << 'PORTS_EOF'
# Registre des ports — géré automatiquement par new-app.sh
# Format : nom-app:port-backend:port-frontend  (vide si non applicable)
# ── Ports réservés par l'infrastructure ──────────────────────────────────────
__keycloak__:8080:
__phpldapadmin__:8081:
spring-app:8082:
PORTS_EOF
fi

# ── Gestion des ports ─────────────────────────────────────────────────────────

# Retourne tous les numéros de port déjà enregistrés
_registered_ports() {
  grep -v '^#\|^$' "$PORTS_REGISTRY" 2>/dev/null \
    | awk -F: '{print $2; print $3}' \
    | grep -E '^[0-9]+$' || true
}

# Retourne 0 si le port est actuellement actif sur la machine
port_in_use() {
  ss -tlnp 2>/dev/null | grep -qE ":$1\b"
}

# Retourne le premier port libre >= $1 (non dans le registre, non actif)
next_port() {
  local port="$1"
  local taken
  taken="$(_registered_ports)"
  while true; do
    if ! echo "$taken" | grep -qx "$port" && ! port_in_use "$port"; then
      echo "$port"; return
    fi
    (( port++ ))
  done
}

# Enregistre les ports dans le registre
register_ports() {
  local name="$1" bport="${2:-}" fport="${3:-}"
  echo "${name}:${bport}:${fport}" >> "$PORTS_REGISTRY"
  ok "Ports enregistrés dans .ports (backend: ${bport:-—}  frontend: ${fport:-—})"
}

# ──────────────────────────────────────────────────────────────────────────────
# SAISIE INTERACTIVE
# ──────────────────────────────────────────────────────────────────────────────
echo -e "\n${BOLD}╔════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║    Nouvelle application — dev/         ║${NC}"
echo -e "${BOLD}╚════════════════════════════════════════╝${NC}\n"

read -rp "Nom de l'application (ex: my-app) : " APP_NAME
[[ -z "$APP_NAME" ]] && err "Le nom ne peut pas être vide."
[[ ! "$APP_NAME" =~ ^[a-z][a-z0-9-]*$ ]] \
  && err "Nom invalide. Minuscules, chiffres et tirets uniquement (ex: my-app)."

APP_DIR="$DEV_DIR/$APP_NAME"
[[ -d "$APP_DIR" ]] && err "Le dossier '$APP_NAME' existe déjà dans dev/."

DB_SCHEMA="${APP_NAME//-/_}"   # my-app → my_app  (nom de schéma SQL valide)

echo -e "\n  Type d'application :"
echo -e "    ${BOLD}1${NC}) Spring Boot seul"
echo -e "    ${BOLD}2${NC}) Spring Boot + Angular"
echo -e "    ${BOLD}3${NC}) Django seul"
echo -e "    ${BOLD}4${NC}) Django + Angular"
echo -e "    ${BOLD}5${NC}) Angular seul"
echo ""
read -rp "Choix [1-5] : " APP_TYPE
[[ ! "$APP_TYPE" =~ ^[1-5]$ ]] && err "Choix invalide."

BACKEND_PORT=""
ANGULAR_PORT=""

if [[ "$APP_TYPE" =~ ^[1234]$ ]]; then
  _suggest_b=$(next_port 8083)
  read -rp "Port backend  [suggéré : ${_suggest_b}, Entrée pour confirmer] : " BACKEND_PORT
  BACKEND_PORT="${BACKEND_PORT:-$_suggest_b}"
  [[ ! "$BACKEND_PORT" =~ ^[0-9]+$ ]] && err "Port invalide."
fi

if [[ "$APP_TYPE" =~ ^[245]$ ]]; then
  _suggest_f=$(next_port 4200)
  read -rp "Port frontend [suggéré : ${_suggest_f}, Entrée pour confirmer] : " ANGULAR_PORT
  ANGULAR_PORT="${ANGULAR_PORT:-$_suggest_f}"
  [[ ! "$ANGULAR_PORT" =~ ^[0-9]+$ ]] && err "Port invalide."
fi

echo ""
read -rp "Scaffolder le projet (télécharge Django / Angular / Spring) ? [O/n] : " DO_SCAFFOLD
DO_SCAFFOLD="${DO_SCAFFOLD:-O}"

# ──────────────────────────────────────────────────────────────────────────────
# FONCTIONS COMMUNES
# ──────────────────────────────────────────────────────────────────────────────

# Ajoute CREATE SCHEMA dans infra/init/00_schemas.sql
add_schema() {
  local schema="$1"
  if grep -q "CREATE SCHEMA IF NOT EXISTS ${schema};" "$INFRA_SCHEMAS" 2>/dev/null; then
    warn "Schéma '${schema}' déjà présent dans infra/init/00_schemas.sql"
  else
    printf '\nCREATE SCHEMA IF NOT EXISTS %s;\n' "${schema}" >> "$INFRA_SCHEMAS"
    ok "Schéma '${schema}' ajouté dans infra/init/00_schemas.sql"
  fi
}

# Crée .env.example + .env (copie) dans $dir
# $3 = "true" si l'app se connecte à la BDD, "false" sinon
# $5 = port backend (optionnel), $6 = port frontend (optionnel)
# $7 = framework : "django" | "spring" (défaut spring)
write_env_files() {
  local dir="$1" schema="$2" has_db="$3" client_id="$4"
  local bport="${5:-}" fport="${6:-}" framework="${7:-spring}"
  {
    echo "# ── Adresses ─────────────────────────────────────────────────────"
    [[ -n "$bport" ]] && echo "PORT_BACKEND=${bport}"
    [[ -n "$bport" ]] && echo "BACKEND_URL=http://localhost:${bport}"
    [[ -n "$fport" ]] && echo "PORT_FRONTEND=${fport}"
    [[ -n "$fport" ]] && echo "FRONTEND_URL=http://localhost:${fport}"
    echo ""
    if [[ "$has_db" == "true" ]]; then
      echo "# ── Base de données ──────────────────────────────────────────────"
      echo "DB_HOST=postgres"
      echo "DB_PORT=5432"
      echo "DB_NAME=devdb"
      echo "DB_SCHEMA=${schema}"
      echo "DB_USER=devuser"
      echo "DB_PASSWORD=devpassword"
      echo ""
    fi
    if [[ "$framework" == "django" ]]; then
      local _secret
      _secret="$(python3 -c 'import secrets; print(secrets.token_hex(32))' 2>/dev/null || echo 'change-this-in-production')"
      echo "# ── Django ───────────────────────────────────────────────────────"
      echo "SECRET_KEY=${_secret}"
      echo "DEBUG=False"
      echo "ALLOWED_HOSTS=*"
      echo ""
    fi
    echo "# ── SSO Keycloak ─────────────────────────────────────────────────"
    echo "KEYCLOAK_CLIENT_ID=${client_id}"
    if [[ "$framework" != "django" ]]; then
      echo "KEYCLOAK_CLIENT_SECRET=<secret-depuis-keycloak>"
    fi
    echo "KEYCLOAK_ISSUER_URI=http://keycloak:8080/realms/ssolab"
    if [[ "$framework" == "django" && -n "$fport" ]]; then
      echo "# Client public (SPA Angular) — Keycloak → Clients → ${client_id} → Access type : Public"
      echo "# Valid redirect URIs : http://localhost:${fport}/*"
    elif [[ -n "$bport" && "$framework" != "django" ]]; then
      echo "# À configurer dans Keycloak → Clients → ${client_id} → Valid redirect URIs"
      echo "# KEYCLOAK_REDIRECT_URI=http://localhost:${bport}/login/oauth2/code/keycloak"
    elif [[ -n "$fport" ]]; then
      echo "# À configurer dans Keycloak → Clients → ${client_id} → Valid redirect URIs"
      echo "# KEYCLOAK_REDIRECT_URI=http://localhost:${fport}/*"
    fi
    echo ""
    echo "# ── URLs (propagées automatiquement par reset_url.sh) ────────────"
    echo "PORT_KEYCLOAK=8080"
    echo "SERVER_URL_LAN=http://192.168.1.X"
    echo "SERVER_URL_WAN=http://VOTRE_IP_WAN"
    echo "KEYCLOAK_URL=http://192.168.1.X:8080"
    echo "KEYCLOAK_PUBLIC_URL=http://VOTRE_IP_WAN:8080"
  } > "${dir}/.env.example"
  cp "${dir}/.env.example" "${dir}/.env"
  ok ".env et .env.example créés"
}

# ──────────────────────────────────────────────────────────────────────────────
# GÉNÉRATEURS : DOCKERFILES
# ──────────────────────────────────────────────────────────────────────────────

dockerfile_spring() {
  cat > "$1/Dockerfile" << 'EOF'
# ── Stage 1 : compilation ──────────────────────────────────────────
FROM maven:3.9-eclipse-temurin-21 AS builder
WORKDIR /build
COPY pom.xml .
RUN mvn dependency:go-offline -q
COPY src ./src
RUN mvn package -DskipTests -q

# ── Stage 2 : image finale légère ─────────────────────────────────
FROM eclipse-temurin:21-jre-alpine
WORKDIR /app
COPY --from=builder /build/target/*.jar app.jar
EXPOSE 8080
ENTRYPOINT ["java", "-jar", "app.jar"]
EOF
  ok "Dockerfile Spring Boot"
}

dockerfile_django() {
  cat > "$1/Dockerfile" << 'EOF'
FROM python:3.12-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
EXPOSE 8000
CMD ["sh", "-c", "python manage.py migrate --no-input && python manage.py runserver 0.0.0.0:8000"]
EOF
  ok "Dockerfile Django"
}

dockerfile_angular() {
  local dir="$1" name="$2"
  cat > "${dir}/Dockerfile" << EOF
# ── Stage 1 : compilation ─────────────────────────────────
FROM node:20-alpine AS build
WORKDIR /app
COPY package*.json ./
RUN npm ci --silent
COPY . .
RUN npm run build

# ── Stage 2 : servir avec nginx ──────────────────────────────
FROM nginx:alpine
COPY --from=build /app/dist/${name}/browser /usr/share/nginx/html
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY nginx-entrypoint.sh /docker-entrypoint.d/40-env-config.sh
RUN chmod +x /docker-entrypoint.d/40-env-config.sh
EXPOSE 80
EOF
  ok "Dockerfile Angular (nginx)"
}

requirements_django() {
  cat > "$1/requirements.txt" << 'EOF'
Django>=5.0,<6.0
psycopg2-binary>=2.9
python-decouple>=3.8
djangorestframework>=3.15
django-cors-headers>=4.3
PyJWT>=2.8
cryptography>=42.0
EOF
  ok "requirements.txt Django"
}

nginx_conf_angular() {
  local dir="$1"
  cat > "${dir}/nginx.conf" << 'EOF'
server {
    listen 80;
    server_name _;
    root /usr/share/nginx/html;
    index index.html;

    location / {
        try_files $uri $uri/ /index.html;
    }

    location = /assets/env.js {
        expires 0;
        add_header Cache-Control "no-cache, no-store, must-revalidate";
    }

    location ~* \.(js|css|woff2?|ttf|eot|svg|png|ico)$ {
        expires 7d;
        add_header Cache-Control "public, no-transform";
    }

    add_header X-Frame-Options SAMEORIGIN;
    add_header X-Content-Type-Options nosniff;
    add_header Referrer-Policy strict-origin-when-cross-origin;
}
EOF
  ok "nginx.conf"
}

nginx_entrypoint_angular() {
  local dir="$1" has_backend="${2:-false}"
  {
    printf '#!/bin/sh\n'
    printf '# Généré par new-app.sh — injecte la configuration Keycloak dans env.js\n'
    printf 'set -e\n\n'
    printf 'ASSETS=/usr/share/nginx/html/assets\n'
    printf 'mkdir -p "$ASSETS"\n\n'
    printf 'cat > "$ASSETS/env.js" << JSEOF\n'
    printf 'window.__env = {\n'
    printf '  keycloakUrl:      "${KEYCLOAK_PUBLIC_URL:-http://localhost:8080}",\n'
    printf '  keycloakRealm:    "${KEYCLOAK_REALM:-ssolab}",\n'
    printf '  keycloakClientId: "${KEYCLOAK_CLIENT_ID}",\n'
    if [[ "$has_backend" == "true" ]]; then
      printf '  apiUrl:           "${SERVER_URL_WAN:-http://localhost}:${PORT_BACKEND:-8000}",\n'
    fi
    printf '  appUrl:           "${SERVER_URL_WAN:-http://localhost}:${PORT_FRONTEND:-4200}"\n'
    printf '};\n'
    printf 'JSEOF\n\n'
    printf 'echo "[nginx] env.js généré."\n'
  } > "${dir}/nginx-entrypoint.sh"
  chmod +x "${dir}/nginx-entrypoint.sh"
  ok "nginx-entrypoint.sh"
}

# ──────────────────────────────────────────────────────────────────────────────
# GÉNÉRATEURS : DOCKER-COMPOSE
# ──────────────────────────────────────────────────────────────────────────────

dc_spring_only() {
  local dir="$1" name="$2" port="$3"
  cat > "${dir}/docker-compose.yml" << EOF
version: "3.9"

networks:
  sso-net:
    external: true
    name: sso-lab_sso-net
  dev-net:
    external: true
    name: dev-net

services:
  ${name}:
    build: .
    container_name: ${name}
    restart: unless-stopped
    env_file: .env
    ports:
      - "${port}:8080"
    networks:
      - sso-net
      - dev-net
EOF
  ok "docker-compose.yml"
}

dc_django_only() {
  local dir="$1" name="$2" port="$3"
  cat > "${dir}/docker-compose.yml" << EOF
version: "3.9"

networks:
  sso-net:
    external: true
    name: sso-lab_sso-net
  dev-net:
    external: true
    name: dev-net

services:
  ${name}:
    build: .
    container_name: ${name}
    restart: unless-stopped
    env_file: .env
    ports:
      - "${port}:8000"
    networks:
      - sso-net
      - dev-net
    volumes:
      - .:/app   # hot-reload : les modifications du code sont prises en compte sans rebuild
EOF
  ok "docker-compose.yml"
}

dc_angular_only() {
  local dir="$1" name="$2" port="$3"
  cat > "${dir}/docker-compose.yml" << EOF
version: "3.9"

# Angular SPA servie par nginx.
# Les appels vers Keycloak et l'API sont effectués par le navigateur.
# Aucun réseau Docker interne n'est nécessaire.

services:
  ${name}:
    build: .
    container_name: ${name}
    restart: unless-stopped
    env_file: .env
    ports:
      - "${port}:80"
EOF
  ok "docker-compose.yml"
}

dc_spring_angular() {
  local dir="$1" name="$2" bport="$3" fport="$4"
  cat > "${dir}/docker-compose.yml" << EOF
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
    container_name: ${name}-backend
    restart: unless-stopped
    env_file: .env
    ports:
      - "${bport}:8080"
    networks:
      - sso-net
      - dev-net

  frontend:
    build: ./frontend
    container_name: ${name}-frontend
    restart: unless-stopped
    env_file: .env
    ports:
      - "${fport}:80"
EOF
  ok "docker-compose.yml (backend + frontend)"
}

dc_django_angular() {
  local dir="$1" name="$2" bport="$3" fport="$4"
  cat > "${dir}/docker-compose.yml" << EOF
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
    container_name: ${name}-backend
    restart: unless-stopped
    env_file: .env
    ports:
      - "${bport}:8000"
    networks:
      - sso-net
      - dev-net
    volumes:
      - ./backend:/app

  frontend:
    build: ./frontend
    container_name: ${name}-frontend
    restart: unless-stopped
    env_file: .env
    ports:
      - "${fport}:80"
EOF
  ok "docker-compose.yml (backend + frontend)"
}

# ──────────────────────────────────────────────────────────────────────────────
# SCAFFOLDING : SPRING BOOT (via Spring Initializr)
# ──────────────────────────────────────────────────────────────────────────────
scaffold_spring() {
  local dir="$1" name="$2" schema="$3"
  step "Spring Boot — téléchargement via start.spring.io (connexion internet requise)..."

  local tmpdir
  tmpdir="$(mktemp -d)"

  if ! curl -sf "https://start.spring.io/starter.zip" \
      -d type=maven-project \
      -d language=java \
      -d bootVersion=3.2.5 \
      -d baseDir="${name}" \
      -d groupId=com.dev \
      -d artifactId="${name}" \
      -d name="${name}" \
      -d dependencies=web,security,oauth2-client,data-jpa,postgresql \
      -o "${tmpdir}/starter.zip"; then
    rm -rf "$tmpdir"
    warn "Échec de Spring Initializr — vérifier la connexion internet."
    info  "Créer manuellement sur https://start.spring.io"
    return
  fi

  unzip -q "${tmpdir}/starter.zip" -d "${tmpdir}"
  cp -r "${tmpdir}/${name}/." "${dir}/"
  rm -rf "$tmpdir"

  # Remplacer application.properties par application.yml configuré
  rm -f "${dir}/src/main/resources/application.properties"
  cat > "${dir}/src/main/resources/application.yml" << EOF
server:
  port: 8080

spring:
  application:
    name: ${name}

  datasource:
    url: jdbc:postgresql://\${DB_HOST:postgres}:\${DB_PORT:5432}/\${DB_NAME:devdb}?currentSchema=\${DB_SCHEMA:${schema}}
    username: \${DB_USER:devuser}
    password: \${DB_PASSWORD:devpassword}
    driver-class-name: org.postgresql.Driver

  jpa:
    hibernate:
      ddl-auto: update
    properties:
      hibernate:
        default_schema: \${DB_SCHEMA:${schema}}
    show-sql: false

  security:
    oauth2:
      client:
        registration:
          keycloak:
            client-id: \${KEYCLOAK_CLIENT_ID:${name}}
            client-secret: \${KEYCLOAK_CLIENT_SECRET}
            scope: openid, profile, email
            authorization-grant-type: authorization_code
            redirect-uri: "{baseUrl}/login/oauth2/code/{registrationId}"
        provider:
          keycloak:
            issuer-uri: \${KEYCLOAK_ISSUER_URI:http://keycloak:8080/realms/ssolab}
            user-name-attribute: preferred_username

logging:
  level:
    org.springframework.security.oauth2: DEBUG
EOF
  ok "Projet Spring Boot scaffoldé + application.yml configuré"
}

# ──────────────────────────────────────────────────────────────────────────────
# SCAFFOLDING : DJANGO (via Docker)
# ──────────────────────────────────────────────────────────────────────────────
scaffold_django() {
  local dir="$1" name="$2" schema="$3" tmpl_name="${4:-django-angular/backend}"
  step "Django — scaffold via Docker (image python:3.12-slim)..."

  # Exécution en root pour éviter les problèmes de permissions pip ; chown ensuite
  if ! docker run --rm \
      -v "${dir}:/app" -w /app \
      python:3.12-slim \
      sh -c "pip install django -q 2>/dev/null && django-admin startproject config ."; then
    warn "Échec du scaffold Django."
    return
  fi

  chown -R "$(id -u):$(id -g)" "${dir}" 2>/dev/null || true

  ok "Projet Django scaffoldé (config/ + manage.py)"
  _configure_django_project "${dir}" "${name}" "${schema}" "${tmpl_name}"
}

# ──────────────────────────────────────────────────────────────────────────────
# SCAFFOLDING : ANGULAR (via Docker)
# ──────────────────────────────────────────────────────────────────────────────
scaffold_angular() {
  local dir="$1" name="$2" port="$3" bport="${4:-}" tmpl_name="${5:-django-angular/frontend}"
  step "Angular — scaffold via Docker (~2-3 min selon la connexion, télécharge les packages npm)..."

  local tmpdir
  tmpdir="$(mktemp -d)"
  chmod 777 "$tmpdir"

  # Exécution en root (sans --user) — npm install -g nécessite root dans Alpine
  if ! docker run --rm \
      -v "${tmpdir}:/workspace" \
      node:20-alpine \
      sh -c "npm install -g @angular/cli --silent 2>/dev/null \
             && ng new ${name} \
                  --directory /workspace/app \
                  --skip-git \
                  --style=scss \
                  --routing=true \
                  --skip-tests \
                  --no-ssr \
                  --defaults 2>/dev/null \
             && cd /workspace/app \
             && npm install keycloak-js@22.0.5 --save --silent 2>/dev/null"; then
    rm -rf "$tmpdir"
    warn "Échec du scaffold Angular."
    info  "Créer manuellement : ng new ${name}"
    return
  fi

  chown -R "$(id -u):$(id -g)" "$tmpdir" 2>/dev/null || true
  cp -r "${tmpdir}/app/." "${dir}/"
  rm -rf "$tmpdir"

  ok "Projet Angular scaffoldé (ng new + keycloak-js@22.0.5)"
  _apply_angular_template "${dir}" "${name}" "${bport}" "${port}" "${tmpl_name}"
}

# ──────────────────────────────────────────────────────────────────────────────
# CONFIGURATION POST-SCAFFOLD : DJANGO (template django-angular)
# ──────────────────────────────────────────────────────────────────────────────
_configure_django_project() {
  local dir="$1" name="$2" schema="$3" tmpl_name="${4:-django-angular/backend}"
  local tmpl="${DEV_DIR}/_templates/${tmpl_name}"

  if [[ ! -d "$tmpl" ]]; then
    warn "Template Django introuvable dans _templates/django-angular/backend/ — projet minimal conservé."
    return
  fi

  step "Application du template Django (modèles, migrations, Keycloak)..."

  # Calcul du titre (mon-app → Mon App)
  local title
  title="$(echo "${name}" | sed 's/-/ /g' | awk '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) substr($i,2); print}')"

  # Copie du template par-dessus le scaffold (remplace config/, ajoute api/)
  cp -r "${tmpl}/." "${dir}/"

  # Remplacement des placeholders dans tous les fichiers Python
  find "${dir}" -type f -name "*.py" | while IFS= read -r f; do
    sed -i \
      -e "s|__APP_NAME__|${name}|g" \
      -e "s|__APP_SLUG__|${schema}|g" \
      -e "s|__APP_TITLE__|${title}|g" \
      "${f}"
  done

  ok "Template Django appliqué — Departments + UserRecords + migrations d'exemple"
}

# ──────────────────────────────────────────────────────────────────────────────
# CONFIGURATION POST-SCAFFOLD : ANGULAR (template django-angular)
# ──────────────────────────────────────────────────────────────────────────────
_apply_angular_template() {
  local dir="$1" name="$2" bport="${3:-8000}" fport="$4" tmpl_name="${5:-django-angular/frontend}"
  local tmpl="${DEV_DIR}/_templates/${tmpl_name}"

  if [[ ! -d "$tmpl" ]]; then
    warn "Template Angular introuvable dans _templates/django-angular/frontend/ — projet minimal conservé."
    return
  fi

  step "Application du template Angular (Keycloak + composants d'exemple)..."

  # Nom de l'app sans suffixe -frontend (utilisé comme clientId Keycloak)
  local appname="${name%-frontend}"
  local title
  title="$(echo "${appname}" | sed 's/-/ /g' | awk '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) substr($i,2); print}')"

  # Copie des fichiers de template par-dessus le projet ng new
  cp -r "${tmpl}/." "${dir}/"

  # Remplacement des placeholders
  find "${dir}/src" -type f | while IFS= read -r f; do
    sed -i \
      -e "s|__APP_NAME__|${appname}|g" \
      -e "s|__APP_TITLE__|${title}|g" \
      -e "s|__BACKEND_PORT__|${bport}|g" \
      -e "s|__FRONTEND_PORT__|${fport}|g" \
      "${f}"
  done

  # Mise à jour de angular.json : ajout de src/assets comme répertoire de ressources
  python3 - "${dir}/angular.json" << 'PYEOF'
import json, sys
path = sys.argv[1]
try:
    with open(path) as f:
        d = json.load(f)
    proj = list(d['projects'].values())[0]
    opts = proj['architect']['build']['options']
    current = opts.get('assets', [])
    extra = {'glob': '**/*', 'input': 'src/assets', 'output': 'assets'}
    if extra not in current:
        opts['assets'] = current + [extra]
    with open(path, 'w') as f:
        json.dump(d, f, indent=2)
    print('  → angular.json mis à jour (src/assets ajouté)')
except Exception as e:
    print(f'  ⚠ angular.json non modifié : {e}', file=sys.stderr)
PYEOF

  ok "Template Angular appliqué → ${title} (Keycloak + Accueil + Profil)"
}

# ──────────────────────────────────────────────────────────────────────────────
# ORCHESTRATION PRINCIPALE
# ──────────────────────────────────────────────────────────────────────────────
mkdir -p "$APP_DIR"
step "Création de $APP_DIR"

case "$APP_TYPE" in

  # ── 1) Spring Boot seul ──────────────────────────────────────────────────────
  1)
    dockerfile_spring  "$APP_DIR"
    dc_spring_only     "$APP_DIR" "$APP_NAME" "$BACKEND_PORT"
    write_env_files    "$APP_DIR" "$DB_SCHEMA" "true" "$APP_NAME" "$BACKEND_PORT" ""
    add_schema         "$DB_SCHEMA"
    register_ports     "$APP_NAME" "$BACKEND_PORT" ""
    [[ "$DO_SCAFFOLD" =~ ^[Oo]$ ]] && scaffold_spring "$APP_DIR" "$APP_NAME" "$DB_SCHEMA"
    ;;

  # ── 2) Spring Boot + Angular ─────────────────────────────────────────────────
  2)
    mkdir -p "$APP_DIR/backend" "$APP_DIR/frontend"
    dockerfile_spring        "$APP_DIR/backend"
    dockerfile_angular       "$APP_DIR/frontend" "${APP_NAME}-frontend"
    nginx_conf_angular       "$APP_DIR/frontend"
    nginx_entrypoint_angular "$APP_DIR/frontend" "true"
    dc_spring_angular        "$APP_DIR" "$APP_NAME" "$BACKEND_PORT" "$ANGULAR_PORT"
    write_env_files          "$APP_DIR" "$DB_SCHEMA" "true" "$APP_NAME" "$BACKEND_PORT" "$ANGULAR_PORT"
    add_schema               "$DB_SCHEMA"
    register_ports           "$APP_NAME" "$BACKEND_PORT" "$ANGULAR_PORT"
    if [[ "$DO_SCAFFOLD" =~ ^[Oo]$ ]]; then
      scaffold_spring  "$APP_DIR/backend"  "$APP_NAME"              "$DB_SCHEMA"
      scaffold_angular "$APP_DIR/frontend" "${APP_NAME}-frontend"   "$ANGULAR_PORT" "$BACKEND_PORT"
    fi
    ;;

  # ── 3) Django seul ───────────────────────────────────────────────────────────
  3)
    dockerfile_django   "$APP_DIR"
    requirements_django "$APP_DIR"
    dc_django_only      "$APP_DIR" "$APP_NAME" "$BACKEND_PORT"
    write_env_files     "$APP_DIR" "$DB_SCHEMA" "true" "$APP_NAME" "$BACKEND_PORT" "" "django"
    add_schema          "$DB_SCHEMA"
    register_ports      "$APP_NAME" "$BACKEND_PORT" ""
    [[ "$DO_SCAFFOLD" =~ ^[Oo]$ ]] && scaffold_django "$APP_DIR" "$APP_NAME" "$DB_SCHEMA" "django-only"
    ;;

  # ── 4) Django + Angular ──────────────────────────────────────────────────────
  4)
    mkdir -p "$APP_DIR/backend" "$APP_DIR/frontend"
    dockerfile_django        "$APP_DIR/backend"
    requirements_django      "$APP_DIR/backend"
    dockerfile_angular       "$APP_DIR/frontend" "${APP_NAME}-frontend"
    nginx_conf_angular       "$APP_DIR/frontend"
    nginx_entrypoint_angular "$APP_DIR/frontend" "true"
    dc_django_angular        "$APP_DIR" "$APP_NAME" "$BACKEND_PORT" "$ANGULAR_PORT"
    write_env_files          "$APP_DIR" "$DB_SCHEMA" "true" "$APP_NAME" "$BACKEND_PORT" "$ANGULAR_PORT" "django"
    add_schema               "$DB_SCHEMA"
    register_ports           "$APP_NAME" "$BACKEND_PORT" "$ANGULAR_PORT"
    printf -- '--public --port %s\n' "$ANGULAR_PORT" > "${APP_DIR}/.keycloak-client-opts"
    ok ".keycloak-client-opts créé (client public Angular, port ${ANGULAR_PORT})"
    if [[ "$DO_SCAFFOLD" =~ ^[Oo]$ ]]; then
      scaffold_django  "$APP_DIR/backend"  "$APP_NAME"            "$DB_SCHEMA"
      scaffold_angular "$APP_DIR/frontend" "${APP_NAME}-frontend" "$ANGULAR_PORT" "$BACKEND_PORT"
    fi
    ;;

  # ── 5) Angular seul ──────────────────────────────────────────────────────────
  5)
    dockerfile_angular       "$APP_DIR" "$APP_NAME"
    nginx_conf_angular       "$APP_DIR"
    nginx_entrypoint_angular "$APP_DIR" "false"
    dc_angular_only          "$APP_DIR" "$APP_NAME" "$ANGULAR_PORT"
    write_env_files          "$APP_DIR" "$DB_SCHEMA" "false" "$APP_NAME" "" "$ANGULAR_PORT"
    # Pas de schéma BDD : Angular est un frontend, il ne se connecte pas à PostgreSQL
    register_ports           "$APP_NAME" "" "$ANGULAR_PORT"
    printf -- '--public --port %s\n' "$ANGULAR_PORT" > "${APP_DIR}/.keycloak-client-opts"
    ok ".keycloak-client-opts créé (client public Angular, port ${ANGULAR_PORT})"
    [[ "$DO_SCAFFOLD" =~ ^[Oo]$ ]] && scaffold_angular "$APP_DIR" "$APP_NAME" "$ANGULAR_PORT" "" "angular-only"
    ;;

esac

# ──────────────────────────────────────────────────────────────────────────────
# RÉSUMÉ
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${GREEN}════════════════════════════════════════${NC}"
echo -e "${BOLD}${GREEN}  '$APP_NAME' prête !${NC}"
echo -e "${BOLD}${GREEN}════════════════════════════════════════${NC}"
echo ""
echo -e "  ${BOLD}Dossier  ${NC}: $APP_DIR"
[[ -n "$BACKEND_PORT" ]] && echo -e "  ${BOLD}Backend  ${NC}: http://localhost:${BACKEND_PORT}"
[[ -n "$ANGULAR_PORT" ]] && echo -e "  ${BOLD}Frontend ${NC}: http://localhost:${ANGULAR_PORT}"
echo ""
echo -e "  ${YELLOW}${BOLD}Étapes suivantes :${NC}"
echo -e "  ${BOLD}1.${NC} Remplir ${CYAN}${APP_NAME}/.env${NC}"
echo -e "     → KEYCLOAK_CLIENT_SECRET (copier depuis Keycloak)"
echo -e "  ${BOLD}2.${NC} Créer le client '${APP_NAME}' dans Keycloak"
echo -e "     → ${CYAN}http://localhost:8080${NC} — realm ssolab — Clients — Create client"
if [[ -n "$BACKEND_PORT" ]]; then
  echo -e "     Valid redirect URIs : ${CYAN}http://localhost:${BACKEND_PORT}/*${NC}"
elif [[ -n "$ANGULAR_PORT" ]]; then
  echo -e "     Valid redirect URIs : ${CYAN}http://localhost:${ANGULAR_PORT}/*${NC}"
fi
if [[ "$APP_TYPE" != "5" ]]; then
  echo -e "  ${BOLD}3.${NC} Si le container postgres tourne déjà (schéma absent du volume) :"
  echo -e "     ${CYAN}docker exec -it dev-postgres psql -U devuser -d devdb \\"
  echo -e "       -c \"CREATE SCHEMA IF NOT EXISTS ${DB_SCHEMA};\"${NC}"
fi
echo ""
echo -e "  ${BOLD}Lancer :${NC} ${CYAN}cd dev/${APP_NAME} && docker compose up -d${NC}"
echo ""
