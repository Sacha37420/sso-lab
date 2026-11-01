#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# nonce-keycloak-js-22.sh — compatibilité keycloak-js 22 ↔ Keycloak ≥ 25.
#
# POURQUOI : depuis Keycloak 25, le claim `nonce` n'est plus mis que dans
# l'id_token. keycloak-js 22.0.5 (tous les frontends du lab) le compare AUSSI
# dans l'access_token ; absent ⇒ « Invalid nonce, clearing token », init()
# rejeté, et avec onLoad 'login-required' la page repart vers Keycloak, qui
# la renvoie aussitôt (session SSO) : BOUCLE INFINIE de connexion. Constaté
# dans le bac à sable (chantier failles, secteur A), corrigé par ce scope.
#
# Ce que fait le script (idempotent, API d'administration seulement) :
#   1. crée le client scope `nonce-keycloak-js-22` (mapper « Nonce backwards
#      compatible ») s'il n'existe pas ;
#   2. le met en scope par défaut du realm (clients créés ensuite) ;
#   3. l'ajoute aux scopes par défaut de CHAQUE client public à flux standard.
# À retirer quand tous les frontends seront passés à keycloak-js ≥ 25.
#
# Usage : bash nonce-keycloak-js-22.sh            (Keycloak de l'hôte, sso-lab/.env)
#         KC_URL=http://localhost:18080 SSO_ENV=/chemin/.env bash nonce-keycloak-js-22.sh
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SSO_ENV="${SSO_ENV:-$ROOT/sso-lab/.env}"
_v() { grep -E "^$1=" "$SSO_ENV" | head -1 | cut -d= -f2- | sed -e 's/[[:space:]]*#.*//' -e "s/^['\"]//" -e "s/['\"]\$//"; }
KC_URL="${KC_URL:-http://localhost:$(_v PORT_KEYCLOAK)}"
REALM=ssolab SCOPE=nonce-keycloak-js-22
# Juste après un démarrage, Keycloak peut répondre avant d'être prêt : sous `set -e`, un
# `curl -sf` raté dans une substitution arrêtait le script SANS AUCUN MESSAGE (vu le
# 2026-11-01). D'où l'attente du realm, et un message pour toute sortie sur erreur.
trap 'echo "✗ échec à la ligne $LINENO (Keycloak pas prêt ?) — relancer le script" >&2' ERR
for _ in $(seq 1 60); do
  curl -sf -o /dev/null "$KC_URL/realms/$REALM/.well-known/openid-configuration" && break
  sleep 2
done
TOKEN="$(curl -sf --data-urlencode client_id=admin-cli --data-urlencode grant_type=password \
  --data-urlencode "username=$(_v KEYCLOAK_ADMIN)" --data-urlencode "password@/dev/fd/3" \
  "$KC_URL/realms/master/protocol/openid-connect/token" 3< <(printf '%s' "$(_v KEYCLOAK_ADMIN_PASSWORD)") | jq -r '.access_token // empty')"
[[ -n "$TOKEN" ]] || { echo "✗ authentification admin refusée ($KC_URL)" >&2; exit 1; }
AUTH="$(umask 077; mktemp)"; trap 'rm -f "$AUTH"' EXIT
printf 'header = "Authorization: Bearer %s"\nheader = "Content-Type: application/json"\n' "$TOKEN" > "$AUTH"
K="$KC_URL/admin/realms/$REALM"
SID="$(curl -sf -K "$AUTH" "$K/client-scopes" | jq -r --arg s "$SCOPE" '.[] | select(.name == $s) | .id')"
if [[ -z "$SID" ]]; then
  code="$(curl -s -o /dev/null -w '%{http_code}' -K "$AUTH" -X POST "$K/client-scopes" -d "$(jq -n --arg s "$SCOPE" '{
    name: $s, protocol: "openid-connect",
    attributes: {"include.in.token.scope": "false", "display.on.consent.screen": "false"},
    protocolMappers: [{name: "nonce backwards compatible", protocol: "openid-connect",
                       protocolMapper: "oidc-nonce-backwards-compatible-mapper", config: {}}]}')")"
  [[ "$code" == "201" ]] || { echo "✗ création du scope : HTTP $code" >&2; exit 1; }
  SID="$(curl -sf -K "$AUTH" "$K/client-scopes" | jq -r --arg s "$SCOPE" '.[] | select(.name == $s) | .id')"
  echo "✓ scope $SCOPE créé"
fi
if curl -sf -K "$AUTH" "$K/default-default-client-scopes" | jq -e --arg s "$SID" 'any(.[]; .id == $s)' > /dev/null; then
  echo "✓ déjà scope par défaut du realm"
else
  code="$(curl -s -o /dev/null -w '%{http_code}' -K "$AUTH" -X PUT "$K/default-default-client-scopes/$SID")"
  [[ "$code" == "204" ]] || { echo "✗ scope par défaut du realm : HTTP $code" >&2; exit 1; }
  echo "✓ scope par défaut du realm"
fi
n=0
while IFS=$'\t' read -r id cid; do
  curl -sf -o /dev/null -K "$AUTH" -X PUT "$K/clients/$id/default-client-scopes/$SID" || { echo "✗ $cid" >&2; exit 1; }
  n=$((n + 1))
done < <(curl -sf -K "$AUTH" "$K/clients?max=500" \
         | jq -r '.[] | select(.publicClient == true and .standardFlowEnabled == true and .protocol == "openid-connect") | [.id, .clientId] | @tsv')
echo "✓ $n client(s) public(s) portent $SCOPE"
