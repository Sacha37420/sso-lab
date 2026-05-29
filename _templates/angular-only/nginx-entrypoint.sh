#!/bin/sh
# Généré par new-app.sh — injecte la configuration Keycloak dans env.js
set -e

ASSETS=/usr/share/nginx/html/assets
mkdir -p "$ASSETS"

cat > "$ASSETS/env.js" << JSEOF
window.__env = {
  keycloakUrl:      "${KEYCLOAK_PUBLIC_URL:-http://localhost:8080}",
  keycloakRealm:    "${KEYCLOAK_REALM:-ssolab}",
  keycloakClientId: "${KEYCLOAK_CLIENT_ID:-__APP_NAME__}",
  appUrl:           "${SERVER_URL_WAN:-http://localhost}:${PORT_FRONTEND:-4200}",
};
JSEOF

chmod 644 "$ASSETS/env.js"
echo "[nginx] env.js généré."
