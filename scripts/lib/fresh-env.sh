# shellcheck shell=bash
# ─────────────────────────────────────────────────────────────────────────────
# scripts/lib/fresh-env.sh — premier .env d'une unité, depuis son .env.example
# (à SOURCER, après registry.sh). Sorti d'install.sh le 2026-11-14 (chantier
# « modules ») pour servir aussi à `lab-modules.sh prepare` : le même .env, que
# le module soit installé par install.sh ou plus tard depuis lab-admin.
#
#   lab_fresh_env <dossier de l'unité>   → crée <dossier>/.env (600) ; code ≠ 0 en échec
#
# Ne s'applique qu'à un .env ABSENT : l'appelant le vérifie. Ajustements :
#   • base : une unité de la racine (service du cadriciel) reçoit la base `lab` ;
#     une app de deploiement/ la base de son propriétaire (dev_<uid>, ou
#     gis_<uid> sur l'instance PostGIS). Le mot de passe est propagé par
#     reset_url.sh ;
#   • secrets : toute clé *KEY*/*SECRET*/*PASSWORD* encore à CHANGE_ME reçoit
#     une valeur aléatoire — sauf celles que d'autres scripts posent (base,
#     Keycloak, coffre d'oauth-hub) ET celles que la description du module
#     déclare comme réglages à demander (une clé d'API tirée au hasard n'est pas
#     une clé d'API : elle doit rester à CHANGE_ME pour être demandée) ;
#   • oauth-hub : la liste de confiance de départ inclut le moteur et lab-admin ;
#   • lab-mcp : identités de CET hôte (id -u, id -g, GID du groupe docker) ;
#   • infra : mot de passe de pgAdmin.
# ─────────────────────────────────────────────────────────────────────────────

_FE_LAB_SERVICES=" lab-admin storage oauth-hub app-builder "

_fe_get() {  # _fe_get <fichier> <clé>
  [[ -f "$1" ]] || return 0
  grep -E "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2- | sed -e 's/[[:space:]]*#.*$//' -e "s/^['\"]//" -e "s/['\"]\$//" || true
}
_fe_set() {  # _fe_set <fichier> <clé> <valeur> — valeurs non secrètes, ou passées par variable
  local file="$1" key="$2" val="$3" tmp line found=false
  tmp="$(umask 077; mktemp "$file.XXXXXX")"
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" == "$key="* ]]; then $found || printf '%s=%s\n' "$key" "$val"; found=true
    else printf '%s\n' "$line"; fi
  done < "$file" > "$tmp"
  $found || printf '%s=%s\n' "$key" "$val" >> "$tmp"
  chmod --reference="$file" "$tmp"; mv "$tmp" "$file"
}

lab_fresh_env() {
  local dir="$1" unit env owner host key val tmp line asked root
  root="$(registry_root)"
  unit="$(basename "$dir")"; env="$dir/.env"
  cp "$dir/.env.example" "$env" && chmod 600 "$env" || return 1
  # Réglages déclarés par la description du module : jamais tirés au hasard.
  asked=" $(python3 -B "$root/scripts/lib/modules.py" "$root" declared-settings "$unit" 2>/dev/null | tr '\n' ' ') "
  # Base
  if grep -qE '^DB_NAME=' "$env"; then
    host="$(_fe_get "$env" DB_HOST)"
    if [[ "$dir" == "$root/deploiement/"* ]]; then
      owner="$(registry_app_owner "$unit")"
      if [[ "$host" == "postgis" ]]; then _fe_set "$env" DB_NAME "gis_${owner}"; else _fe_set "$env" DB_NAME "dev_${owner}"; fi
      _fe_set "$env" DB_USER "dev_${owner}"
    elif [[ "$_FE_LAB_SERVICES" == *" $unit "* ]]; then
      _fe_set "$env" DB_NAME lab; _fe_set "$env" DB_USER lab
    fi
  fi
  # Secrets à CHANGE_ME (réécriture sans passer la valeur à une commande externe)
  tmp="$(umask 077; mktemp "$env.XXXXXX")"
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ ^([A-Z][A-Z0-9_]*)=CHANGE_ME[[:space:]]*$ ]]; then
      key="${BASH_REMATCH[1]}"
      if [[ "$asked" == *" $key "* ]]; then printf '%s\n' "$line"; continue; fi
      case "$key" in
        DB_PASSWORD|POSTGIS_PASSWORD|KEYCLOAK_*|OAUTH_HUB_ENCRYPTION_KEY|CODE_SERVER_*|LDAP_*|POSTGRES_PASSWORD|PGADMIN_*|BBOX_*|SMTP_*) ;;
        VAULT_ENCRYPTION_KEY)
          # Clé Fernet (32 octets en base64 urlsafe) : une chaîne alphanumérique ne
          # serait pas acceptée par cryptography et l'app ne démarrerait pas.
          val="$(python3 -c 'import base64,os;print(base64.urlsafe_b64encode(os.urandom(32)).decode())')"
          line="${key}=${val}" ;;
        *KEY*|*SECRET*|*PASSWORD*)
          val="$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 50 || true)"
          line="${key}=${val}" ;;
      esac
    fi
    printf '%s\n' "$line"
  done < "$env" > "$tmp"
  chmod 600 "$tmp"; mv "$tmp" "$env"
  case "$unit" in
    oauth-hub) grep -qE '^KEYCLOAK_TRUSTED_CLIENTS=' "$env" && _fe_set "$env" KEYCLOAK_TRUSTED_CLIENTS "oauth-hub,lab-mcp,lab-admin" ;;
    lab-mcp)   _fe_set "$env" LAB_UID "$(id -u)"; _fe_set "$env" LAB_GID "$(id -g)"
               _fe_set "$env" DOCKER_GID "$(getent group docker | cut -d: -f3)" ;;
    infra)     _fe_set "$env" PGADMIN_DEFAULT_PASSWORD "$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 32 || true)" ;;
  esac
}
