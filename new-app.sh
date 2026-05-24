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
  ok "Ports enregistrés dans .ports (backend: ${bport:—}  frontend: ${fport:—})"
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
write_env_files() {
  local dir="$1" schema="$2" has_db="$3" client_id="$4"
  local bport="${5:-}" fport="${6:-}"
  {
    echo "# ── Adresses ─────────────────────────────────────────────────────"
    [[ -n "$bport" ]] && echo "BACKEND_PORT=${bport}"
    [[ -n "$bport" ]] && echo "BACKEND_URL=http://localhost:${bport}"
    [[ -n "$fport" ]] && echo "FRONTEND_PORT=${fport}"
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
    echo "# ── SSO Keycloak ─────────────────────────────────────────────────"
    echo "KEYCLOAK_CLIENT_ID=${client_id}"
    echo "KEYCLOAK_CLIENT_SECRET=<secret-depuis-keycloak>"
    echo "KEYCLOAK_ISSUER_URI=http://keycloak:8080/realms/ssolab"
    if [[ -n "$bport" ]]; then
      echo "# À configurer dans Keycloak → Clients → ${client_id} → Valid redirect URIs"
      echo "# KEYCLOAK_REDIRECT_URI=http://localhost:${bport}/login/oauth2/code/keycloak"
    elif [[ -n "$fport" ]]; then
      echo "# À configurer dans Keycloak → Clients → ${client_id} → Valid redirect URIs"
      echo "# KEYCLOAK_REDIRECT_URI=http://localhost:${fport}/*"
    fi
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
CMD ["python", "manage.py", "runserver", "0.0.0.0:8000"]
EOF
  ok "Dockerfile Django"
}

dockerfile_angular() {
  local dir="$1" port="$2"
  cat > "${dir}/Dockerfile" << EOF
FROM node:20-alpine
WORKDIR /app
COPY package*.json ./
RUN npm ci --silent
COPY . .
EXPOSE ${port}
CMD ["npx", "ng", "serve", "--host", "0.0.0.0", "--port", "${port}", "--poll=2000"]
EOF
  ok "Dockerfile Angular"
}

requirements_django() {
  cat > "$1/requirements.txt" << 'EOF'
Django>=5.0,<6.0
psycopg2-binary>=2.9
python-decouple>=3.8
djangorestframework>=3.15
django-cors-headers>=4.3
EOF
  ok "requirements.txt Django"
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

# Angular SPA : les appels vers Keycloak et l'API sont effectués
# par le navigateur (via localhost), pas par le container.
# Aucun réseau Docker interne n'est nécessaire.

services:
  ${name}:
    build: .
    container_name: ${name}
    restart: unless-stopped
    env_file: .env
    ports:
      - "${port}:${port}"
    volumes:
      - .:/app
      - /app/node_modules   # isole node_modules du container de celui de l'hôte
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
      - "${fport}:${fport}"
    volumes:
      - ./frontend:/app
      - /app/node_modules
    environment:
      # Appelée par le navigateur — utiliser localhost, pas le nom du service Docker
      API_URL: http://localhost:${bport}
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
      - "${fport}:${fport}"
    volumes:
      - ./frontend:/app
      - /app/node_modules
    environment:
      API_URL: http://localhost:${bport}
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
  local dir="$1"
  step "Django — scaffold via Docker (télécharge l'image python:3.12-slim si absente)..."

  if ! docker run --rm \
      --user "${DOCKER_UID}" \
      -v "${dir}:/app" -w /app \
      python:3.12-slim \
      sh -c "pip install django -q 2>/dev/null && django-admin startproject config ."; then
    warn "Échec du scaffold Django."
    return
  fi

  ok "Projet Django scaffoldé"
  info "config/settings.py créé — configurer la BDD avec python-decouple et les variables du .env"
}

# ──────────────────────────────────────────────────────────────────────────────
# SCAFFOLDING : ANGULAR (via Docker)
# ──────────────────────────────────────────────────────────────────────────────
scaffold_angular() {
  local dir="$1" name="$2" port="$3"
  step "Angular — scaffold via Docker (~2-3 min selon la connexion, télécharge npm packages)..."

  local tmpdir
  tmpdir="$(mktemp -d)"
  chmod 777 "$tmpdir"

  if ! docker run --rm \
      --user "${DOCKER_UID}" \
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
                  --defaults 2>/dev/null"; then
    rm -rf "$tmpdir"
    warn "Échec du scaffold Angular."
    info  "Créer manuellement : ng new ${name}"
    return
  fi

  cp -r "${tmpdir}/app/." "${dir}/"
  rm -rf "$tmpdir"

  ok "Projet Angular scaffoldé"
  info "Hot-reload actif via le volume monté dans docker-compose.yml"
  info "Pour injecter les variables d'env dans l'app : src/environments/environment.ts"
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
    dockerfile_spring   "$APP_DIR/backend"
    dockerfile_angular  "$APP_DIR/frontend" "$ANGULAR_PORT"
    dc_spring_angular   "$APP_DIR" "$APP_NAME" "$BACKEND_PORT" "$ANGULAR_PORT"
    write_env_files     "$APP_DIR" "$DB_SCHEMA" "true" "$APP_NAME" "$BACKEND_PORT" "$ANGULAR_PORT"
    add_schema          "$DB_SCHEMA"
    register_ports      "$APP_NAME" "$BACKEND_PORT" "$ANGULAR_PORT"
    if [[ "$DO_SCAFFOLD" =~ ^[Oo]$ ]]; then
      scaffold_spring  "$APP_DIR/backend"  "$APP_NAME"              "$DB_SCHEMA"
      scaffold_angular "$APP_DIR/frontend" "${APP_NAME}-frontend"   "$ANGULAR_PORT"
    fi
    ;;

  # ── 3) Django seul ───────────────────────────────────────────────────────────
  3)
    dockerfile_django   "$APP_DIR"
    requirements_django "$APP_DIR"
    dc_django_only      "$APP_DIR" "$APP_NAME" "$BACKEND_PORT"
    write_env_files     "$APP_DIR" "$DB_SCHEMA" "true" "$APP_NAME" "$BACKEND_PORT" ""
    add_schema          "$DB_SCHEMA"
    register_ports      "$APP_NAME" "$BACKEND_PORT" ""
    [[ "$DO_SCAFFOLD" =~ ^[Oo]$ ]] && scaffold_django "$APP_DIR"
    ;;

  # ── 4) Django + Angular ──────────────────────────────────────────────────────
  4)
    mkdir -p "$APP_DIR/backend" "$APP_DIR/frontend"
    dockerfile_django    "$APP_DIR/backend"
    requirements_django  "$APP_DIR/backend"
    dockerfile_angular   "$APP_DIR/frontend" "$ANGULAR_PORT"
    dc_django_angular    "$APP_DIR" "$APP_NAME" "$BACKEND_PORT" "$ANGULAR_PORT"
    write_env_files      "$APP_DIR" "$DB_SCHEMA" "true" "$APP_NAME" "$BACKEND_PORT" "$ANGULAR_PORT"
    add_schema           "$DB_SCHEMA"
    register_ports       "$APP_NAME" "$BACKEND_PORT" "$ANGULAR_PORT"
    if [[ "$DO_SCAFFOLD" =~ ^[Oo]$ ]]; then
      scaffold_django  "$APP_DIR/backend"
      scaffold_angular "$APP_DIR/frontend" "${APP_NAME}-frontend" "$ANGULAR_PORT"
    fi
    ;;

  # ── 5) Angular seul ──────────────────────────────────────────────────────────
  5)
    dockerfile_angular "$APP_DIR" "$ANGULAR_PORT"
    dc_angular_only    "$APP_DIR" "$APP_NAME" "$ANGULAR_PORT"
    write_env_files    "$APP_DIR" "$DB_SCHEMA" "false" "$APP_NAME" "" "$ANGULAR_PORT"
    # Pas de schéma BDD : Angular est un frontend, il ne se connecte pas à PostgreSQL
    register_ports     "$APP_NAME" "" "$ANGULAR_PORT"
    [[ "$DO_SCAFFOLD" =~ ^[Oo]$ ]] && scaffold_angular "$APP_DIR" "$APP_NAME" "$ANGULAR_PORT"
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
