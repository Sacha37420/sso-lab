#!/bin/sh
set -e

# ── 1. pgpass (connexion PostgreSQL sans mot de passe côté libpq) ──
mkdir -p /var/lib/pgadmin
{
  echo "postgres:5432:*:${POSTGRES_USER}:${POSTGRES_PASSWORD}"
  echo "postgis:5432:*:${POSTGIS_USER}:${POSTGIS_PASSWORD}"
} > /var/lib/pgadmin/.pgpass
chmod 600 /var/lib/pgadmin/.pgpass

# ── 2. servers.json (serveurs pré-configurés, partagés entre tous les users) ──
cat > /var/lib/pgadmin/servers.json << EOF
{
  "Servers": {
    "1": {
      "Name": "dev-postgres",
      "Group": "Servers",
      "Host": "postgres",
      "Port": 5432,
      "MaintenanceDB": "${POSTGRES_DB}",
      "Username": "${POSTGRES_USER}",
      "SharedUsername": "${POSTGRES_USER}",
      "SSLMode": "prefer",
      "Shared": true,
      "PassFile": "/var/lib/pgadmin/.pgpass"
    },
    "2": {
      "Name": "dev-postgis",
      "Group": "Servers",
      "Host": "postgis",
      "Port": 5432,
      "MaintenanceDB": "${POSTGIS_DB}",
      "Username": "${POSTGIS_USER}",
      "SharedUsername": "${POSTGIS_USER}",
      "SSLMode": "prefer",
      "Shared": true,
      "PassFile": "/var/lib/pgadmin/.pgpass"
    }
  }
}
EOF

# ── 3. Watchdog : corrige les records sharedserver créés par les users OAuth2 ──
# save_password=1 avec username=devuser → pgAdmin ne demande pas de mot de passe
(while true; do
  python3 - << 'PYEOF'
import sqlite3, os
try:
    c = sqlite3.connect('/var/lib/pgadmin/pgadmin4.db')
    c.execute("""
        UPDATE sharedserver
        SET save_password = 1,
            username = COALESCE(username, (
                SELECT username FROM server WHERE server.name = sharedserver.name
            ))
        WHERE save_password = 0 OR save_password IS NULL OR username IS NULL
    """)
    c.commit()
    c.close()
except Exception:
    pass
PYEOF
  sleep 5
done) &

# ── 4. Démarrage pgAdmin ──
exec /entrypoint.sh
