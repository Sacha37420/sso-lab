# shellcheck shell=bash
# ─────────────────────────────────────────────────────────────────────────────
# scripts/lib/kcprobe.sh — « sso-lab tourne-t-il ? » (à SOURCER).
#
# POURQUOI UNE FONCTION : la sonde historique visait http://localhost:<port>.
# Juste sur l'hôte, FAUX depuis un conteneur (le serveur MCP lance setup2.sh
# depuis le sien) : localhost y désigne le conteneur lui-même, la sonde échoue,
# et le script concluait « sso-lab est arrêté », lançait
# `recompose_docker.sh --app sso-lab` puis affichait « sso-lab démarré ».
#
#   kc_probe_url <port>        URL de sonde valable d'où l'on est :
#                              keycloak:<port> dans un conteneur (réseau sso-net),
#                              localhost:<port> sur l'hôte — même règle que
#                              create-app-client.sh et check-app-name.sh.
#   kc_probe_in_container      code 0 si l'on tourne dans un conteneur.
#   kc_probe_sso_state <port>  imprime :
#       up        Keycloak répond ;
#       starting  Keycloak ne répond pas (encore), mais son conteneur tourne ;
#       down      son conteneur n'existe pas ou est arrêté ;
#       unknown   Keycloak ne répond pas et Docker n'a pas pu dire pourquoi.
# ─────────────────────────────────────────────────────────────────────────────

kc_probe_in_container() { [[ -f /.dockerenv ]]; }

kc_probe_url() {
  local port="${1:-8080}"
  if kc_probe_in_container; then echo "http://keycloak:${port}/realms/master"
  else echo "http://localhost:${port}/realms/master"; fi
}

kc_probe_sso_state() {
  local port="${1:-8080}" running
  if curl -sf --max-time 10 "$(kc_probe_url "$port")" > /dev/null 2>&1; then
    echo up; return 0
  fi
  # L'état du conteneur, lui, se lit pareil des deux côtés (même démon Docker).
  if running="$(docker inspect -f '{{.State.Running}}' keycloak 2>/dev/null)"; then
    if [[ "$running" == "true" ]]; then echo starting; else echo down; fi
  elif docker info > /dev/null 2>&1; then
    echo down       # Docker répond, le conteneur n'existe pas
  else
    echo unknown    # pas d'accès à Docker d'ici
  fi
}
