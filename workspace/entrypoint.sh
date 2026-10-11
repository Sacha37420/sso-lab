#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# lab-entrypoint — entrée de l'image lab-workspace (contrat multi-dev, I7).
#
# Sans argument : prépare la maison du dev puis lance code-server.
# Avec arguments : exécute la commande telle quelle, SANS rien préparer
#                  (diagnostic : `docker run --rm lab-workspace claude --version`).
#
# Variables lues (I3) — voir README.md pour le détail :
#   LAB_UID        obligatoire   identifiant du dev, sert au préfixe /ws/<uid>/
#   LAB_APP        obligatoire   projet ouvert, monté sur /work/<app>
#   LAB_MCP_URL    attendue      adresse du MCP du lab (https://<DOMAIN>/mcp)
#   LAB_MCP_TOKEN  attendue      jeton d'espace — JAMAIS lu ni écrit ici : seul son
#                                NOM est posé dans les configurations des outils
#   GH_TOKEN       attendue      jeton GitHub du dev — idem, jamais écrit
#   LAB_GIT_AUTHOR_NAME / LAB_GIT_AUTHOR_EMAIL   facultatives, auteur des commits
#
# Ce que l'entrée écrit dans /home/coder, et rien d'autre :
#   ~/.claude/CLAUDE.md   bloc balisé des règles du lab (le reste du fichier est au dev)
#   ~/.vibe/AGENTS.md     idem
#   ~/.claude.json        clé mcpServers.lab uniquement, par `claude mcp add`
#   ~/.vibe/config.toml   entrée [[mcp_servers]] « lab » uniquement, par `vibe mcp add`
#   ~/.local/share/code-server/extensions   au PREMIER démarrage seulement
#
# Ce qu'elle ne touche jamais : ~/.claude/.credentials.json, le reste de
# ~/.claude.json, ~/.vibe/.env, ~/.gitconfig, ~/.config/gh, ~/.ssh, les
# réglages de l'éditeur (~/.local/share/code-server/User).
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

if [[ $# -gt 0 ]]; then
  exec "$@"
fi

LAB_DIR=/opt/lab
MCP_NAME=lab                      # nom du serveur MCP dans les deux outils
TOKEN_VAR=LAB_MCP_TOKEN           # NOM de la variable ; sa valeur n'est jamais manipulée ici

log()  { printf '[lab-workspace] %s\n' "$*"; }
warn() { printf '[lab-workspace] ATTENTION : %s\n' "$*" >&2; }
err()  { printf '[lab-workspace] ERROR : %s\n' "$*" >&2; }
die()  { err "$*"; exit 64; }

# ── 1. Variables d'I3 ────────────────────────────────────────────────────────
# Validées strictement : elles finissent dans un chemin et dans une ligne de
# commande. Mêmes formes que le registre du lab (contrat I1).
[[ "${LAB_UID:-}" =~ ^[a-z][a-z0-9]{1,30}$ ]] \
  || die "LAB_UID absent ou invalide (attendu : ^[a-z][a-z0-9]{1,30}\$)"
[[ "${LAB_APP:-}" =~ ^[a-z][a-z0-9-]{1,38}[a-z0-9]$ && "$LAB_APP" != *--* ]] \
  || die "LAB_APP absent ou invalide (attendu : ^[a-z][a-z0-9-]{1,38}[a-z0-9]\$, sans « -- »)"
WORK="/work/$LAB_APP"
[[ -d "$WORK" ]] || die "$WORK n'existe pas : le projet doit être monté sur /work/$LAB_APP"
[[ -w "$HOME" ]] || die "$HOME n'est pas inscriptible par l'uid $(id -u) : la maison doit appartenir à l'uid 1000"

MCP_URL="${LAB_MCP_URL:-}"
if [[ -n "$MCP_URL" ]]; then
  # https obligatoire hors boucle locale : le jeton voyage dans un en-tête.
  [[ "$MCP_URL" =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?(/[A-Za-z0-9._~/-]*)?$ \
     || "$MCP_URL" =~ ^http://(127\.0\.0\.1|localhost)(:[0-9]+)?(/[A-Za-z0-9._~/-]*)?$ ]] \
    || die "LAB_MCP_URL invalide (https://… attendu ; http:// admis seulement en boucle locale)"
else
  warn "LAB_MCP_URL absente : le MCP du lab ne sera pas déclaré."
fi
[[ -n "${!TOKEN_VAR:+x}" ]] || warn "$TOKEN_VAR absente : le MCP du lab refusera les appels."
[[ -n "${GH_TOKEN:+x}" ]]   || warn "GH_TOKEN absente : git push et gh demanderont une authentification."

echec=0

# ── 2. Règles du lab (I8) ────────────────────────────────────────────────────
for cible in "$HOME/.claude/CLAUDE.md" "$HOME/.vibe/AGENTS.md"; do
  if etat="$(python3 "$LAB_DIR/lib/bloc_regles.py" "$cible" "$LAB_DIR/regles-lab.md" 2>&1)"; then
    log "règles : $cible ($etat)"
  else
    err "règles non posées dans $cible : $etat"; echec=1
  fi
done

# ── 3. Déclaration du MCP du lab ─────────────────────────────────────────────
# Les deux outils savent référencer une variable d'environnement (vérifié sur
# les versions épinglées, voir README) : le fichier ne porte que le NOM
# LAB_MCP_TOKEN, la valeur est lue dans l'environnement à chaque appel.
# On passe par la commande de chaque outil — c'est lui qui fusionne dans SON
# fichier — et seulement si la déclaration diffère de celle voulue.

mcp_claude() {
  local fichier="$HOME/.claude.json" voulu actuel
  # shellcheck disable=SC2016  # ${LAB_MCP_TOKEN} doit rester littéral : c'est Claude Code qui le développe
  local entete='Bearer ${'"$TOKEN_VAR"'}'
  actuel="$(jq -r --arg n "$MCP_NAME" \
      '.mcpServers[$n] // empty | "\(.type)|\(.url)|\(.headers.Authorization)|\(.headers|length)"' \
      "$fichier" 2>/dev/null || true)"
  if [[ -z "$MCP_URL" ]]; then
    [[ -z "$actuel" ]] || claude mcp remove "$MCP_NAME" -s user >/dev/null 2>&1 || true
    return 0
  fi
  voulu="http|$MCP_URL|$entete|1"
  if [[ "$actuel" == "$voulu" ]]; then log "MCP Claude Code : inchangé"; return 0; fi
  [[ -z "$actuel" ]] || claude mcp remove "$MCP_NAME" -s user >/dev/null 2>&1 || true
  claude mcp add --scope user --transport http "$MCP_NAME" "$MCP_URL" \
      --header "Authorization: $entete" >/dev/null || return 1
  log "MCP Claude Code : déclaré ($MCP_URL)"
}

mcp_vibe() {
  local fichier="$HOME/.vibe/config.toml" actuel voulu
  actuel="$(python3 - "$fichier" "$MCP_NAME" <<'PY' 2>/dev/null || true
import sys, tomllib
try:
    with open(sys.argv[1], "rb") as f:
        serveurs = tomllib.load(f).get("mcp_servers", [])
except FileNotFoundError:
    serveurs = []
for s in serveurs:
    if isinstance(s, dict) and s.get("name") == sys.argv[2]:
        a = s.get("auth", {})
        print("|".join(str(x) for x in (
            s.get("transport"), s.get("url"), a.get("type"), a.get("api_key_env"),
            a.get("api_key_header", "Authorization"), a.get("api_key_format", "Bearer {token}"),
            len(a.get("headers", {})) + len(s.get("headers", {})))))
        break
PY
)"
  # VIBE_CLI=python : la commande `mcp add` à en-tête statique n'existe que dans ce client.
  if [[ -z "$MCP_URL" ]]; then
    [[ -z "$actuel" ]] || VIBE_CLI=python vibe mcp remove "$MCP_NAME" >/dev/null 2>&1 || true
    return 0
  fi
  voulu="streamable-http|$MCP_URL|static|$TOKEN_VAR|Authorization|Bearer {token}|0"
  if [[ "$actuel" == "$voulu" ]]; then log "MCP Vibe : inchangé"; return 0; fi
  [[ -z "$actuel" ]] || VIBE_CLI=python vibe mcp remove "$MCP_NAME" >/dev/null 2>&1 || true
  VIBE_CLI=python vibe mcp add "$MCP_NAME" --url "$MCP_URL" --transport streamable-http \
      --api-key-env "$TOKEN_VAR" --api-key-header Authorization \
      --api-key-format 'Bearer {token}' >/dev/null || return 1
  log "MCP Vibe : déclaré ($MCP_URL)"
}

# Un échec ici n'empêche pas l'éditeur de démarrer (le dev garde son espace),
# mais il est écrit en ERROR dans le journal du conteneur.
mcp_claude || { err "déclaration du MCP pour Claude Code impossible"; echec=1; }
mcp_vibe   || { err "déclaration du MCP pour Mistral Vibe impossible"; echec=1; }

# ── 4. Auteur git ────────────────────────────────────────────────────────────
# Par l'environnement, rien sur disque. Le ~/.gitconfig du dev garde la main :
# s'il y a mis un nom ou un email, on n'impose rien.
if [[ -n "${LAB_GIT_AUTHOR_NAME:-}" && -z "$(git config --global user.name 2>/dev/null)" ]]; then
  export GIT_AUTHOR_NAME="$LAB_GIT_AUTHOR_NAME" GIT_COMMITTER_NAME="$LAB_GIT_AUTHOR_NAME"
fi
if [[ -n "${LAB_GIT_AUTHOR_EMAIL:-}" && -z "$(git config --global user.email 2>/dev/null)" ]]; then
  export GIT_AUTHOR_EMAIL="$LAB_GIT_AUTHOR_EMAIL" GIT_COMMITTER_EMAIL="$LAB_GIT_AUTHOR_EMAIL"
fi

# ── 5. Extensions fournies par l'image ───────────────────────────────────────
# Au premier démarrage seulement : ensuite le dossier appartient au dev
# (il installe, retire et met à jour ses extensions comme il veut).
EXT_DIR="$HOME/.local/share/code-server/extensions"
if [[ ! -e "$EXT_DIR" ]]; then
  if mkdir -p "$EXT_DIR" && cp -a "$LAB_DIR/extensions/." "$EXT_DIR/"; then
    log "extensions de l'image recopiées dans la maison (premier démarrage)"
  else
    err "extensions de l'image non recopiées"; echec=1
  fi
fi

[[ $echec -eq 0 ]] || err "préparation incomplète (voir ci-dessus) — l'éditeur démarre quand même"

# ── 6. Éditeur ───────────────────────────────────────────────────────────────
# code-server n'a pas d'option de préfixe : toutes ses URL sont RELATIVES. Il
# est donc servi à la racine, et c'est le proxy qui RETIRE /ws/<uid> (voir
# README, « Ce que le proxy doit faire »). --abs-proxy-base-path ne concerne
# que la redirection de ports /absproxy/<port>/.
cd "$WORK" || die "impossible d'entrer dans $WORK"
log "code-server sur :8080, dossier $WORK, à servir sous /ws/$LAB_UID/"
# --ignore-last-opened : la maison du dev (~/.local/share/code-server) est
# commune à tous ses projets, et code-server y retient le dernier dossier
# ouvert — qu'il préfère au dossier donné ici. Or l'espace ne monte que le
# projet en cours : sans cette option, ouvrir un second projet affichait
# « Workspace does not exist » sur le dossier du précédent.
exec code-server \
  --config "$LAB_DIR/code-server.yaml" \
  --abs-proxy-base-path "/ws/$LAB_UID" \
  --ignore-last-opened \
  "$WORK"
