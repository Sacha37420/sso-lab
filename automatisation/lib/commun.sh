# shellcheck shell=bash
# ─────────────────────────────────────────────────────────────────────────────
# automatisation/lib/commun.sh — réglages et outils communs du moteur de nuit (à SOURCER).
# Contrat chantiers/nuit-auto/CONTRAT.md v1.
#
# RÈGLES QUI TIENNENT TOUT LE RESTE :
#   • toute commande externe (docker, git, python3, crontab, scripts du lab) passe par
#     `x <secondes> …` (timeout, entrée standard sur /dev/null) ou par `gx` (git isolé) ;
#     `auto.sh verifier` le contrôle ligne à ligne (marqueur « # x-ok » pour les seules
#     définitions de ces enveloppes) ;
#   • GIT_TERMINAL_PROMPT=0, GH_PROMPT_DISABLED=1, entrée standard du processus sur /dev/null :
#     rien ne peut attendre une saisie ;
#   • un jeton n'est jamais sur une ligne de commande : il est lu par le shell (`$(<fichier)`,
#     intégré, sans processus) et passé dans l'ENVIRONNEMENT de la seule commande qui en a
#     besoin (`-e NOM` de docker, GIT_ASKPASS de git, AUTO_GH_TOKEN de outils.py) ;
#   • tout ce qui part au journal passe par le filtre de secrets.
# ─────────────────────────────────────────────────────────────────────────────

AUTO_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_DIR="$(cd "$AUTO_LIB/.." && pwd)"
# Racine du lab : celle qui contient ce dossier. AUTO_LAB_ROOT ne sert qu'aux essais (un faux
# lab dont scripts/ est un lien vers le vrai) : registry.sh calcule sa racine d'après son
# chemin LOGIQUE, il voit donc le faux lab.
LAB_ROOT="${AUTO_LAB_ROOT:-$(cd "$AUTO_DIR/.." && pwd)}"
# shellcheck source=../../scripts/lib/registry.sh
source "$LAB_ROOT/scripts/lib/registry.sh"

exec < /dev/null
export GIT_TERMINAL_PROMPT=0 GH_PROMPT_DISABLED=1
umask 077

# ── Réglages (tous surchargeables par l'environnement, pour les essais) ───────
: "${AUTO_DIR_PROMPTS:=$AUTO_DIR/prompts}"
: "${AUTO_CALENDRIER:=$AUTO_DIR/calendrier.conf}"
: "${AUTO_SCHEMA:=$AUTO_DIR/schema-resume.json}"
: "${AUTO_STATE:=$(registry_state_dir)/auto}"
: "${AUTO_WORK:=$HOME/lab-work/auto}"
: "${AUTO_IMAGE:=lab-workspace:latest}"
: "${AUTO_MODEL:=opus}"
: "${AUTO_BRIDGE_PREFIX:=lws}"
: "${AUTO_FIN:=05:00}"
: "${AUTO_FIN_RATTRAPAGE:=08:00}"
: "${AUTO_REMOTE_BASE:=https://github.com/}"
: "${AUTO_GITHUB_API:=https://api.github.com}"
: "${AUTO_SMTP_ENV:=$LAB_ROOT/sso-lab/.env}"
: "${AUTO_TEST_TIMEOUT:=900}"
: "${AUTO_BUILD_TIMEOUT:=3600}"
: "${AUTO_FRONT_TIMEOUT:=1800}"
: "${AUTO_FRONT_CMD:=npm ci --no-audit --no-fund && npx ng build}"  # x-ok (chaîne lancée par sh dans le conteneur, sous timeout)
: "${AUTO_LOCK_TIMEOUT:=1800}"
: "${AUTO_DISQUE_MIN_GO:=10}"
: "${AUTO_TACHES_CONTEXTE:=services}"
: "${AUTO_DOCTOR_CMD:=bash $LAB_ROOT/scripts/lab-doctor.sh --quick}"
export AUTO_DIR_PROMPTS AUTO_CALENDRIER AUTO_SCHEMA AUTO_STATE AUTO_WORK AUTO_IMAGE AUTO_MODEL \
       AUTO_BRIDGE_PREFIX AUTO_FIN AUTO_FIN_RATTRAPAGE AUTO_REMOTE_BASE AUTO_GITHUB_API AUTO_SMTP_ENV \
       AUTO_TEST_TIMEOUT AUTO_BUILD_TIMEOUT AUTO_FRONT_TIMEOUT AUTO_FRONT_CMD AUTO_LOCK_TIMEOUT \
       AUTO_DISQUE_MIN_GO AUTO_TACHES_CONTEXTE AUTO_DOCTOR_CMD

AUTO_TOKEN_CLAUDE="$AUTO_STATE/claude-token"
AUTO_TOKEN_GITHUB="$AUTO_STATE/github-token"
AUTO_RUNS="$AUTO_STATE/runs"

# ── Enveloppes des commandes externes ─────────────────────────────────────────
x() { local s="$1"; shift; timeout --signal=TERM --kill-after=15 "$s" "$@" < /dev/null; }  # x-ok
py() { timeout --signal=TERM --kill-after=10 "${AUTO_PY_TIMEOUT:-120}" python3 -I "$AUTO_LIB/outils.py" "$@" < /dev/null; }  # x-ok
# Filtre : seule commande du moteur qui lit une entrée (un fichier, jamais un terminal).
py_scrub() { timeout --signal=TERM --kill-after=10 60 python3 -I "$AUTO_LIB/outils.py" scrub "$AUTO_SECRETS" < "$1"; }  # x-ok

# git « isolé » (même réglage que scripts/lib/git.sh, mode isolé) : aucune configuration de
# l'hôte, aucun assistant d'identifiants, aucun hook, pas de fsmonitor ; jeton par
# GIT_ASKPASS ← LAB_GIT_TOKEN (environnement de la seule commande qui pousse ou clone).
# N'est JAMAIS lancé dans un dossier monté en écriture dans un conteneur : seulement dans les
# clones propres (propre/) et, avant tout montage, dans les clones de travail (work/).
#   gx <secondes> <dossier> <args git…>     (AUTO_GX_LOCAL=1 : autorise un clone local)
gx() {
  local s="$1" d="$2"; shift 2
  local proto="https" fileok="never"
  if [[ "${LAB_GIT_ALLOW_FILE:-}" == "1" || "${AUTO_GX_LOCAL:-}" == "1" ]]; then proto="https:file"; fileok="always"; fi
  GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0 \
  GIT_ASKPASS="$LAB_ROOT/scripts/lib/git-askpass.sh" SSH_ASKPASS="" GIT_ALLOW_PROTOCOL="$proto" \
  timeout --signal=TERM --kill-after=15 "$s" git -C "$d" \
    -c credential.helper= -c core.hooksPath=/dev/null -c core.fsmonitor=false \
    -c "protocol.file.allow=$fileok" -c advice.detachedHead=false -c init.defaultBranch=main \
    -c user.name=lab-auto -c user.email=lab-auto@localhost "$@" < /dev/null  # x-ok
}

# ── Journal ───────────────────────────────────────────────────────────────────
AUTO_SECRETS="${AUTO_SECRETS:-/dev/null}"
JOURNAL="${JOURNAL:-}"
log() {
  local m; m="[$(date '+%F %T')] $*"
  printf '%s\n' "$m" >&2
  if [[ -n "$JOURNAL" ]]; then
    local t; t="$(mktemp "${AUTO_PRIV:-/tmp}/log.XXXXXX")"
    printf '%s\n' "$m" > "$t"; py_scrub "$t" >> "$JOURNAL" 2>/dev/null; rm -f "$t"
  fi
}
# Ajoute au journal un fichier de sortie de commande (filtré, 200 dernières lignes).
journal_fichier() {
  [[ -n "$JOURNAL" && -s "$1" ]] || return 0
  local t; t="$(mktemp "${AUTO_PRIV:-/tmp}/log.XXXXXX")"
  tail -n 200 "$1" > "$t"; py_scrub "$t" | sed 's/^/    │ /' >> "$JOURNAL" 2>/dev/null; rm -f "$t"
}
# Remplace un fichier par sa version filtrée (sorties de tests, réponses de claude).
filtrer_fichier() {
  [[ -f "$1" && ! -L "$1" ]] || return 0
  local t; t="$(mktemp "${AUTO_PRIV:-/tmp}/flt.XXXXXX")"
  py_scrub "$1" > "$t" 2>/dev/null && cat "$t" > "$1"; rm -f "$t"
}

# Valeurs à ne jamais publier ni journaliser (outils.py secrets-collecter) : clés secrètes et
# adresses de tous les .env du lab, et les deux jetons. AUTO_PRIV : dossier privé (700) du
# processus, supprimé en sortie.
secrets_preparer() {
  AUTO_PRIV="$(mktemp -d "${TMPDIR:-/tmp}/lab-auto.XXXXXX")"
  AUTO_SECRETS="$AUTO_PRIV/secrets.jsonl"
  local fichiers=() d
  for d in "$LAB_ROOT/.env" "$LAB_ROOT/bbox.env" "$LAB_ROOT/sso-lab/.env" "$LAB_ROOT/infra/.env" \
           "$LAB_ROOT/infra/dev-roles.env" "$AUTO_SMTP_ENV"; do
    [[ -f "$d" ]] && fichiers+=("$d")
  done
  while IFS= read -r d; do fichiers+=("$d/.env"); done < <(registry_dirs_with .env)
  py secrets-collecter "$AUTO_SECRETS" "${fichiers[@]}" -- "$AUTO_TOKEN_CLAUDE" "$AUTO_TOKEN_GITHUB" \
    || : > "$AUTO_SECRETS"
  export AUTO_SECRETS AUTO_PRIV
}
secrets_nettoyer() { [[ -n "${AUTO_PRIV:-}" && -d "$AUTO_PRIV" ]] && rm -rf -- "$AUTO_PRIV"; return 0; }

# ── Cibles ────────────────────────────────────────────────────────────────────
# Dépôt GitHub (« propriétaire/dépôt ») d'une cible, lu dans des FICHIERS de configuration
# (`git config --file`, qui ne lance rien) : .gitmodules du dépôt racine, à défaut la
# configuration du dépôt de l'app. Jamais de git « vivant » dans le dossier d'une app.
cible_depot() {
  local c="$1" url="" rel dir k v gd
  if [[ "$c" == "_racine" ]]; then
    url="$(x 10 git config --file "$LAB_ROOT/.git/config" --get remote.origin.url 2>/dev/null)"
  else
    rel="$(registry_app_relpath "$c")" || return 1
    if [[ -f "$LAB_ROOT/.gitmodules" ]]; then
      while read -r k v; do
        if [[ "$v" == "$rel" ]]; then
          url="$(x 10 git config --file "$LAB_ROOT/.gitmodules" --get "${k%.path}.url" 2>/dev/null)"; break
        fi
      done < <(x 10 git config --file "$LAB_ROOT/.gitmodules" --get-regexp '^submodule\..*\.path$' 2>/dev/null)
    fi
    if [[ -z "$url" ]]; then
      dir="$(registry_app_dir "$c")"
      if [[ -f "$dir/.git" ]]; then
        gd="$(sed -n 's/^gitdir: //p' "$dir/.git" | head -1)"; [[ "$gd" == /* ]] || gd="$dir/$gd"
      else gd="$dir/.git"; fi
      [[ -f "$gd/config" ]] && url="$(x 10 git config --file "$gd/config" --get remote.origin.url 2>/dev/null)"
    fi
  fi
  [[ -n "$url" ]] || return 1
  py lien-github "$url"
}

# Apps de la rotation (I6) : apps du superutilisateur, triées, qui ont leur propre dépôt git
# (une entrée .git dans leur dossier) et un origin GitHub.
rotation_liste() {
  local a
  while IFS= read -r a; do
    [[ -e "$(registry_app_dir "$a")/.git" ]] || continue
    cible_depot "$a" > /dev/null 2>&1 || continue
    printf '%s\n' "$a"
  done < <(registry_apps_of "$(registry_superuser)" | LC_ALL=C sort)
}

# Nom du dossier de montage d'une cible : /work/<nom> (_racine ⇒ dev).
cible_montage() { [[ "$1" == "_racine" ]] && echo dev || echo "$1"; }

# ── Pare-feu des ponts (I3) ───────────────────────────────────────────────────
# Même conteneur jetable que le moteur lab-mcp (lab-mcp/labmcp/firewall.py) : son image, réseau
# hôte, NET_ADMIN seul ; `lab-ws-firewall apply` est idempotent. Nom distinct de celui du
# moteur (il fait un `rm -f` du sien avant chaque pose).
pare_feu_image() {
  [[ -n "${AUTO_FIREWALL_IMAGE:-}" ]] && { echo "$AUTO_FIREWALL_IMAGE"; return 0; }
  local i; i="$(x 20 docker inspect -f '{{.Image}}' lab-mcp 2>/dev/null)"
  [[ "$i" == sha256:* ]] && echo "$i"
}
pare_feu_cmd() {  # pare_feu_cmd apply|show|remove
  local img; img="$(pare_feu_image)" || true
  [[ -n "$img" ]] || { echo "image du moteur lab-mcp introuvable" >&2; return 1; }
  [[ "$AUTO_BRIDGE_PREFIX" =~ ^lw[a-z]{1,5}$ ]] || { echo "préfixe de pont invalide : $AUTO_BRIDGE_PREFIX" >&2; return 1; }
  x 20 docker rm -f "auto-fw-$AUTO_BRIDGE_PREFIX" > /dev/null 2>&1
  x 90 docker run --rm --name "auto-fw-$AUTO_BRIDGE_PREFIX" --network host --user 0 --read-only \
    --label com.docker.compose.project= --label com.docker.compose.service= \
    --cap-drop ALL --cap-add NET_ADMIN --security-opt no-new-privileges \
    "$img" lab-ws-firewall "$1" $([[ "$1" != show ]] && echo "$AUTO_BRIDGE_PREFIX")
}
pare_feu() { pare_feu_cmd apply > /dev/null; }

# Réseau dédié dont l'interface commence par le préfixe filtré (sans étiquette lab.ws : le
# moteur supprime à son démarrage tout réseau ainsi étiqueté qu'il ne connaît pas).
reseau_creer() {
  local net="$1" h n
  n=$((15 - ${#AUTO_BRIDGE_PREFIX} - 1))
  h="$(printf '%s' "$net" | sha256sum | cut -c1-"$n")"
  x 20 docker network rm "$net" > /dev/null 2>&1
  x 30 docker network create --label lab.auto=1 -o "com.docker.network.bridge.name=${AUTO_BRIDGE_PREFIX}a${h}" "$net" > /dev/null
}
reseau_retirer() { x 30 docker network rm "$1" > /dev/null 2>&1; return 0; }

# Suppression d'un dossier de travail (des fichiers posés par Claude peuvent être sans droit
# d'écriture). Refuse tout chemin hors de AUTO_WORK.
supprimer_travail() {
  local d="$1"
  [[ -n "$d" && -e "$d" ]] || return 0
  case "$(realpath -m -- "$d")" in "$(realpath -m -- "$AUTO_WORK")"/*) ;; *) log "refus de supprimer $d (hors $AUTO_WORK)"; return 1 ;; esac
  chmod -R u+rwX -- "$d" 2>/dev/null
  rm -rf -- "$d"
}
