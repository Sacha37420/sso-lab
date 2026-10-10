#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# verify.sh — vérification réelle et rejouable de l'image lab-workspace (I7).
#
#   bash workspace/verify.sh [--sans-navigateur] [--garder]
#
# Ne construit PAS l'image (un build passe par le verrou du lab) :
#   bash scripts/lab-lock.sh docker build -t lab-workspace:dev workspace
#
# Tout tourne dans des conteneurs jetables `ws-test-image-*`, sur des réseaux
# jetables `ws-test-image-net*` créés ici — jamais dev-net ni sso-net — et sous
# les options d'enfermement d'I3. Aucun identifiant réel n'est utilisé : les
# jetons sont des chaînes factices, le serveur MCP est un faux (tests/faux_mcp.py).
# Tout est supprimé à la sortie (sauf --garder).
#
# Réglages : WS_IMAGE (lab-workspace:dev) · WS_VERIFY_NAV_IMAGE (runner-runner:latest,
# toute image portant Playwright dans /app/node_modules) · WS_VERIFY_PROXY_IMAGE
# (image portant le binaire `caddy`) · WS_MEM (2g) · WS_CPUS (1) · WS_PIDS (512).
#
# À lancer par l'uid 1000 (les maisons de test sont montées en écriture pour `coder`).
# Code de sortie : 0 si tout est vert, 1 sinon.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

ICI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE="${WS_IMAGE:-lab-workspace:dev}"
NAV_IMAGE="${WS_VERIFY_NAV_IMAGE:-runner-runner:latest}"
PROXY_IMAGE="${WS_VERIFY_PROXY_IMAGE:-lucaslorentz/caddy-docker-proxy:ci-alpine}"
MEM="${WS_MEM:-2g}"; CPUS="${WS_CPUS:-1}"; PIDS="${WS_PIDS:-512}"
P=ws-test-image
NAVIGATEUR=1; GARDER=0
for a in "$@"; do
  case "$a" in
    --sans-navigateur) NAVIGATEUR=0 ;;
    --garder) GARDER=1 ;;
    *) echo "Usage : bash workspace/verify.sh [--sans-navigateur] [--garder]" >&2; exit 2 ;;
  esac
done

# Options d'enfermement d'I3 — celles sous lesquelles l'image DOIT fonctionner.
ENFERME=(--cap-drop ALL --security-opt no-new-privileges --memory "$MEM" --cpus "$CPUS" --pids-limit "$PIDS")

# Jetons factices, reconnaissables : on les cherchera partout où ils ne doivent pas être.
JETON_MCP="jeton-factice-mcp-$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n')"
JETON_GH="ghp_factice$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n')"

OK=0; KO=0; MESURES=()
titre()  { printf '\n\033[1m── %s\033[0m\n' "$*"; }
ok()     { OK=$((OK+1)); printf '  \033[32m✓\033[0m %s\n' "$*"; }
ko()     { KO=$((KO+1)); printf '  \033[31m✗ %s\033[0m\n' "$*"; }
info()   { printf '    · %s\n' "$*"; }
mesure() { MESURES+=("$*"); printf '  ⏱ %s\n' "$*"; }
# verifie "<libellé>" <commande…>   — vert si la commande réussit
verifie() { local l="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$l"; else ko "$l"; fi; }
# refuse "<libellé>" <commande…>    — vert si la commande ÉCHOUE (cas négatif)
refuse()  { local l="$1"; shift; if "$@" >/dev/null 2>&1; then ko "$l"; else ok "$l"; fi; }
contient() { grep -qF -- "$2" <<<"$1"; }

nettoie() {
  [[ $GARDER -eq 1 ]] && { echo; echo "(--garder : conteneurs/réseaux $P-* et $TMP laissés en place)"; return; }
  local c; c="$(docker ps -aq --filter "name=^${P}-" 2>/dev/null)"
  [[ -n "$c" ]] && docker rm -f $c >/dev/null 2>&1
  docker network rm "$P-net" "$P-net2" >/dev/null 2>&1
  # Vibe pose des dossiers en lecture seule dans sa maison : rendre inscriptible avant d'effacer.
  [[ -n "${TMP:-}" && -d "$TMP" ]] && { chmod -R u+rwX "$TMP" 2>/dev/null; rm -rf "$TMP"; }
}
trap nettoie EXIT

docker image inspect "$IMAGE" >/dev/null 2>&1 || {
  echo "Image $IMAGE absente. Construire d'abord : bash scripts/lab-lock.sh docker build -t lab-workspace:dev workspace" >&2; exit 2; }
[[ -n "$(docker ps -aq --filter "name=^${P}-")" ]] && {
  echo "Des conteneurs $P-* existent déjà (autre vérification en cours ?). Les supprimer puis relancer." >&2; trap - EXIT; exit 2; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/$P.XXXXXX")"; chmod 755 "$TMP"
dx() { docker exec "$@"; }
mem_mo() { dx "$1" sh -c 'echo $(( $(cat /sys/fs/cgroup/memory.current) / 1048576 ))'; }
anon_mo() { dx "$1" sh -c 'echo $(( $(awk "\$1==\"anon\"{print \$2}" /sys/fs/cgroup/memory.stat) / 1048576 ))'; }
# attend_sante <conteneur> <secondes max> → affiche le délai en dixièmes de seconde
attend_sante() {
  local c="$1" max="$2" t0 t; t0=$(date +%s%N)
  while :; do
    dx "$c" curl -sf -o /dev/null -m 2 http://127.0.0.1:8080/healthz 2>/dev/null && break
    t=$(( ($(date +%s%N) - t0) / 1000000 ))
    (( t > max * 1000 )) && return 1
    docker ps -q --filter "name=^${c}$" | grep -q . || return 1
    sleep 0.2
  done
  echo $(( ($(date +%s%N) - t0) / 100000000 ))
}
dixiemes() { printf '%d,%d s' $(( $1 / 10 )) $(( $1 % 10 )); }

# ═════════════════════════════════════════════════════════════════════════════
titre "0. Image : versions épinglées, rien de secret"
verifie "Dockerfile : aucune image ni version « latest »" bash -c "! grep -nE '(:latest|@latest)\\b' '$ICI/Dockerfile'"
verifie "Dockerfile : aucun « curl | bash »" bash -c "! grep -vE '^[[:space:]]*#' '$ICI/Dockerfile' | grep -nE 'curl[^|]*\\|[[:space:]]*(ba)?sh'"
verifie "contexte de build fermé (.dockerignore en liste blanche)" bash -c "head -3 '$ICI/.dockerignore' | grep -qx '\\*'"
TAILLE=$(docker image inspect "$IMAGE" --format '{{.Size}}')
mesure "taille de l'image : $(( TAILLE / 1048576 )) Mo (contenu, compressé) — $(docker images --format '{{.Size}}' "$IMAGE" | head -1) sur disque"
ENVIMG="$(docker image inspect "$IMAGE" --format '{{range .Config.Env}}{{println .}}{{end}}')"
refuse "aucune variable de l'image ne ressemble à un secret" grep -qiE '^(.*TOKEN|.*SECRET|.*PASSWORD|.*API_KEY)=' <<<"$ENVIMG"
info "versions annoncées par l'image : $(grep '^LAB_WORKSPACE_VERSIONS=' <<<"$ENVIMG" | cut -d= -f2-)"

# ═════════════════════════════════════════════════════════════════════════════
titre "1. Outils et enfermement (conteneur sans réseau, options d'I3)"
SORTIE="$(docker run --rm --name "$P-outils" --network none "${ENFERME[@]}" "$IMAGE" bash -c '
  echo "uid=$(id -u) gid=$(id -g) groupes=$(id -Gn | tr " " ,)"
  echo "maison_image=$(ls -A /home/coder | tr "\n" " ")"
  echo "code-server=$(code-server --version 2>/dev/null | tail -1 | cut -d" " -f1)"
  echo "claude=$(claude --version 2>&1 | head -1)"
  echo "vibe=$(vibe --version 2>&1 | head -1)"
  echo "git=$(git --version)"
  echo "gh=$(gh --version | head -1)"
  echo "python=$(python3 --version)"
  echo "node=$(node --version)"
  echo "uv=$(uv --version)"
  for b in sudo docker dockerd podman su-exec gosu doas; do command -v $b >/dev/null && echo "present=$b"; done
  getent group docker >/dev/null && echo "present=groupe-docker"
  [ -e /var/run/docker.sock ] && echo "present=docker.sock"
  echo "capeff=$(awk "/^CapEff/{print \$2}" /proc/self/status)"
  echo "nonewprivs=$(awk "/^NoNewPrivs/{print \$2}" /proc/self/status)"
  echo "fichiers_sensibles=$(find / -xdev \( -name .credentials.json -o -name .git-credentials -o -name "id_rsa*" -o -name "id_ed25519*" -o -name "*.pem" -o -name ".env" -o -name hosts.yml \) -not -path "/proc/*" -not -path "/usr/lib/code-server/*" -not -path "/usr/local/lib/node_modules/*" -not -path "/opt/uv-tools/*" -not -path "/usr/local/lib/python3*" -not -path "/etc/ssl/*" -not -path "/usr/lib/ssl/*" -not -path "/usr/share/*" -not -path "/opt/lab/extensions/*" 2>/dev/null | tr "\n" " ")"
  echo "ecrit_hors_maison=$( (touch /usr/local/bin/x 2>/dev/null && echo oui) || echo non)"
' 2>&1)"
val() { grep -m1 "^$1=" <<<"$SORTIE" | cut -d= -f2-; }
[[ "$(val uid)" == "1000 gid=1000 groupes=coder" ]] && ok "utilisateur uid 1000, gid 1000, seul groupe « coder »" || ko "utilisateur inattendu : uid=$(val uid)"
for o in code-server claude vibe git gh python node uv; do
  v="$(val "$o")"; [[ -n "$v" && "$v" != *"not found"* && "$v" != *rror* ]] && ok "$o répond : $v" || ko "$o ne répond pas : $v"
done
contient "$(val python)" "Python 3.12." && ok "Python est bien 3.12" || ko "Python n'est pas 3.12"
contient "$(val node)" "v20." && ok "Node est bien 20" || ko "Node n'est pas 20"
grep -q '^present=' <<<"$SORTIE" && ko "présent dans l'image alors qu'interdit : $(grep '^present=' <<<"$SORTIE" | cut -d= -f2 | tr '\n' ' ')" || ok "ni sudo, ni docker, ni groupe docker, ni docker.sock dans l'image"
[[ "$(val capeff)" == "0000000000000000" ]] && ok "aucune capacité effective (cap_drop ALL)" || ko "capacités effectives : $(val capeff)"
[[ "$(val nonewprivs)" == "1" ]] && ok "no-new-privileges actif" || ko "no-new-privileges inactif"
[[ -z "$(val maison_image)" ]] && ok "la maison de l'image est vide (rien à masquer par le montage)" || ko "la maison de l'image contient : $(val maison_image)"
[[ -z "$(val fichiers_sensibles)" ]] && ok "aucun fichier d'identifiants dans l'image" || ko "fichiers suspects dans l'image : $(val fichiers_sensibles)"
[[ "$(val ecrit_hors_maison)" == "non" ]] && ok "coder ne peut pas écrire dans /usr/local/bin" || ko "coder peut écrire dans /usr/local/bin"

# ═════════════════════════════════════════════════════════════════════════════
titre "2. L'entrée refuse des variables absentes ou invalides (code 64)"
mkdir -p "$TMP/vide" "$TMP/work/demo-app"
essai() { # essai "<libellé>" <options docker run…>  → attend le code 64
  local l="$1"; shift
  docker run --rm --name "$P-refus" --network none "${ENFERME[@]}" -v "$TMP/vide:/home/coder" -v "$TMP/work/demo-app:/work/demo-app" "$@" "$IMAGE" >/dev/null 2>&1
  local rc=$?; [[ $rc -eq 64 ]] && ok "$l" || ko "$l (code $rc au lieu de 64)"
}
essai "LAB_UID absent"                       -e LAB_APP=demo-app
essai "LAB_UID invalide (« e2e_member »)"     -e LAB_UID=e2e_member -e LAB_APP=demo-app
essai "LAB_APP invalide (« ../etc »)"         -e LAB_UID=alice -e LAB_APP=../etc
essai "projet non monté sur /work/<app>"     -e LAB_UID=alice -e LAB_APP=autre-app
essai "LAB_MCP_URL en http hors boucle locale" -e LAB_UID=alice -e LAB_APP=demo-app -e LAB_MCP_URL=http://exemple.test/mcp
essai "LAB_MCP_URL avec caractères de commande" -e LAB_UID=alice -e LAB_APP=demo-app -e 'LAB_MCP_URL=https://x.test/mcp;id'
[[ -z "$(ls -A "$TMP/vide")" ]] && ok "un refus n'écrit rien dans la maison" || ko "un refus a écrit dans la maison : $(ls -A "$TMP/vide" | tr '\n' ' ')"

# ═════════════════════════════════════════════════════════════════════════════
titre "3. Espace complet : maison déjà habitée, variables d'I3 posées"
H="$TMP/maison-alice"; W="$TMP/work/demo-app"
mkdir -p "$H/.claude" "$H/.vibe" "$H/.config/gh" "$H/.local/share/code-server/User" "$H/.ssh"
echo 'print("bonjour")' > "$W/main.py"
# Ce qui appartient au dev et ne doit JAMAIS bouger :
echo '{"claudeAiOauth":{"accessToken":"identifiant-factice-claude"}}' > "$H/.claude/.credentials.json"
echo 'MISTRAL_API_KEY=identifiant-factice-mistral'                      > "$H/.vibe/.env"
printf 'github.com:\n    oauth_token: identifiant-factice-gh\n'         > "$H/.config/gh/hosts.yml"
echo '{"editor.fontSize": 17}'                                          > "$H/.local/share/code-server/User/settings.json"
echo 'cle-privee-factice'                                               > "$H/.ssh/id_ed25519"
PROTEGES=(.claude/.credentials.json .vibe/.env .config/gh/hosts.yml .local/share/code-server/User/settings.json .ssh/id_ed25519)
# Ce que l'entrée complète sans écraser :
echo '{"oauthAccount":{"emailAddress":"factice@example.org"},"mcpServers":{"perso":{"type":"http","url":"https://perso.example/mcp"}}}' > "$H/.claude.json"
printf 'theme = "dracula"\n\n[[mcp_servers]]\nname = "autre"\ntransport = "stdio"\ncommand = "true"\n' > "$H/.vibe/config.toml"
echo 'Mes consignes personnelles à moi.' > "$H/.claude/CLAUDE.md"
sommes() { (cd "$H" && sha256sum "${PROTEGES[@]}"); }
AVANT="$(sommes)"

docker network create "$P-net" >/dev/null && docker network create "$P-net2" >/dev/null || { ko "création des réseaux jetables"; exit 1; }
URL_MCP=http://127.0.0.1:9000/mcp      # faux serveur MCP, lancé DANS le conteneur (boucle locale)
lance_a() {
  docker run -d --name "$P-a" --network "$P-net" "${ENFERME[@]}" \
    -v "$H:/home/coder" -v "$W:/work/demo-app" \
    -e LAB_UID=alice -e LAB_APP=demo-app -e LAB_MCP_URL="$1" -e LAB_MCP_TOKEN="$JETON_MCP" -e GH_TOKEN="$JETON_GH" \
    -e LAB_GIT_AUTHOR_NAME="Alice Essai" -e LAB_GIT_AUTHOR_EMAIL=alice@example.org "$IMAGE" >/dev/null
}
lance_a "$URL_MCP"
if D1=$(attend_sante "$P-a" 90); then
  ok "code-server répond sur 8080 (/healthz) sous cap_drop ALL + no-new-privileges + $MEM / $CPUS vCPU / $PIDS pids"
  mesure "premier démarrage (règles + 2 déclarations MCP + copie des extensions + éditeur) : $(dixiemes "$D1")"
else
  ko "code-server ne démarre pas sous les options d'enfermement"; docker logs "$P-a" 2>&1 | tail -20; exit 1
fi
JOURNAL="$(docker logs "$P-a" 2>&1)"
refuse "aucune ligne ERROR dans le journal de l'entrée" grep -q 'ERROR' <<<"$JOURNAL"
contient "$JOURNAL" "Authentication is disabled" && ok "éditeur en --auth none (contrôle d'accès en amont, I3)" || ko "l'éditeur n'est pas en auth none"
contient "$JOURNAL" "Using config file /opt/lab/code-server.yaml" && ok "configuration de l'éditeur lue dans l'image, pas dans la maison" || ko "configuration de l'éditeur inattendue"
[[ ! -e "$H/.config/code-server/config.yaml" ]] && ok "aucun config.yaml (mot de passe généré) écrit dans la maison" || ko "config.yaml écrit dans la maison"

titre "3a. Règles d'I8"
for f in .claude/CLAUDE.md .vibe/AGENTS.md; do
  if grep -q 'LAB:REGLES:DEBUT' "$H/$f" && grep -q 'LAB:REGLES:FIN' "$H/$f" && grep -q 'FEUILLE_DE_ROUTE.md' "$H/$f"; then ok "règles en place dans ~/$f"; else ko "règles absentes de ~/$f"; fi
done
grep -qx 'Mes consignes personnelles à moi.' "$H/.claude/CLAUDE.md" && ok "le texte du dev dans ~/.claude/CLAUDE.md est conservé" || ko "le texte du dev a été écrasé"
BLOC() { sed -n '/LAB:REGLES:DEBUT/,/LAB:REGLES:FIN/p' "$1" | sed '1d;$d'; }
[[ "$(BLOC "$H/.vibe/AGENTS.md")" == "$(cat "$ICI/regles-lab.md")" ]] && ok "le bloc est exactement workspace/regles-lab.md (source unique)" || ko "le bloc diffère de regles-lab.md"
[[ "$(BLOC "$H/.vibe/AGENTS.md")" == "$(BLOC "$H/.claude/CLAUDE.md")" ]] && ok "même contenu pour Claude Code et pour Vibe" || ko "contenus différents entre les deux outils"

titre "3b. Déclarations MCP : présentes, pointent sur LAB_MCP_URL, sans jeton"
[[ "$(jq -r '.mcpServers.lab | "\(.type) \(.url) \(.headers.Authorization)"' "$H/.claude.json")" == "http $URL_MCP Bearer \${LAB_MCP_TOKEN}" ]] \
  && ok "Claude Code : ~/.claude.json → mcpServers.lab = http, $URL_MCP, en-tête « Bearer \${LAB_MCP_TOKEN} » (référence, pas valeur)" || ko "Claude Code : déclaration inattendue : $(jq -c .mcpServers.lab "$H/.claude.json")"
VT="$(python3 - "$H/.vibe/config.toml" <<'PY'
import sys, tomllib
c = tomllib.load(open(sys.argv[1], "rb"))
labs = [s for s in c["mcp_servers"] if s["name"] == "lab"]
s = labs[0]
print(len(labs), s["transport"], s["url"], s["auth"]["type"], s["auth"]["api_key_env"], c.get("theme"), [x["name"] for x in c["mcp_servers"]])
PY
)"
[[ "$VT" == "1 streamable-http $URL_MCP static LAB_MCP_TOKEN dracula ['autre', 'lab']" ]] \
  && ok "Vibe : ~/.vibe/config.toml → [[mcp_servers]] lab = streamable-http, $URL_MCP, api_key_env = LAB_MCP_TOKEN" || ko "Vibe : déclaration inattendue : $VT"
[[ "$(jq -r '.oauthAccount.emailAddress + " " + .mcpServers.perso.url' "$H/.claude.json")" == "factice@example.org https://perso.example/mcp" ]] \
  && ok "Claude Code : compte et serveur MCP personnels du dev conservés dans ~/.claude.json" || ko "~/.claude.json : contenu du dev perdu"
contient "$VT" "dracula ['autre', 'lab']" && ok "Vibe : réglage (theme) et serveur MCP personnels du dev conservés" || ko "Vibe : contenu du dev perdu"

titre "3c. Le jeton n'est écrit nulle part"
for nom in "LAB_MCP_TOKEN:$JETON_MCP" "GH_TOKEN:$JETON_GH"; do
  j="${nom#*:}"; n="${nom%%:*}"
  T="$(grep -rlF -- "$j" "$H" "$W" 2>/dev/null)"
  [[ -z "$T" ]] && ok "$n : absent de tout fichier de la maison et du projet (grep -r)" || ko "$n écrit dans : $T"
  T="$(dx "$P-a" sh -c "grep -rlF -- '$j' /tmp /opt/lab /etc 2>/dev/null")"
  [[ -z "$T" ]] && ok "$n : absent de /tmp, /opt/lab et /etc du conteneur" || ko "$n écrit dans : $T"
  contient "$(docker logs "$P-a" 2>&1)" "$j" && ko "$n apparaît dans le journal du conteneur" || ok "$n : absent du journal du conteneur"
done
contient "$(docker image history --no-trunc "$IMAGE")" "$JETON_MCP" && ko "jeton dans l'historique de l'image" || ok "rien dans l'historique de l'image"

titre "3d. MCP : preuve par l'appel réel (faux serveur qui exige le jeton)"
dx -i "$P-a" sh -c 'cat > /tmp/faux_mcp.py' < "$ICI/tests/faux_mcp.py"
dx -i "$P-a" sh -c 'cat > /tmp/vibe_mcp.py' < "$ICI/tests/vibe_mcp.py"
dx -d -e FAUX_MCP_JETON="$JETON_MCP" "$P-a" python3 /tmp/faux_mcp.py 9000 /tmp/faux-mcp.log
sleep 2
R="$(dx "$P-a" claude mcp get lab 2>&1)"
contient "$R" "Connected" && ok "Claude Code : « claude mcp get lab » → Connected (il lit sa déclaration et envoie le jeton de l'environnement)" || { ko "Claude Code ne se connecte pas au MCP"; info "$R"; }
contient "$R" "$JETON_MCP" && ko "« claude mcp get » affiche le jeton" || ok "Claude Code : l'affichage de la déclaration ne montre pas le jeton"
R="$(dx -e LAB_MCP_TOKEN=mauvais-jeton "$P-a" claude mcp get lab 2>&1)"
contient "$R" "401" && ok "négatif — Claude Code avec un autre jeton dans l'environnement : refusé (401)" || { ko "négatif Claude Code : pas de refus"; info "$R"; }
R="$(dx "$P-a" /opt/uv-tools/mistral-vibe/bin/python /tmp/vibe_mcp.py 2>&1 | tail -1)"
contient "$R" "outils=['whoami']" && ok "Vibe : son client MCP liste les outils du serveur avec sa déclaration ($R)" || { ko "Vibe ne joint pas le MCP"; info "$R"; }
R="$(dx -e LAB_MCP_TOKEN= "$P-a" /opt/uv-tools/mistral-vibe/bin/python /tmp/vibe_mcp.py 2>&1 | tail -1)"
contient "$R" "ECHEC" && ok "négatif — Vibe sans jeton dans l'environnement : refusé" || { ko "négatif Vibe : pas de refus"; info "$R"; }
LOGMCP="$(dx "$P-a" cat /tmp/faux-mcp.log 2>/dev/null)"
grep -q '^tools/list auth=OK agent=claude-code/' <<<"$LOGMCP" && ok "vu par le serveur : tools/list de claude-code avec le bon jeton" || ko "le serveur n'a pas vu Claude Code authentifié"
grep -q '^tools/list auth=OK agent=MistralAI-VibeCLI/' <<<"$LOGMCP" && ok "vu par le serveur : tools/list de MistralAI-VibeCLI avec le bon jeton" || ko "le serveur n'a pas vu Vibe authentifié"
grep -q 'auth=KO agent=claude-code/' <<<"$LOGMCP" && grep -q 'auth=ABSENT agent=MistralAI-VibeCLI/' <<<"$LOGMCP" && ok "vu par le serveur : les deux essais négatifs (jeton faux, jeton absent)" || ko "essais négatifs non vus par le serveur"
info "non prouvable ici : une conversation réelle avec Claude ou Mistral (aucun identifiant, aucun n'est emprunté à l'hôte)"

titre "3e. git et gh : jeton lu dans l'environnement, auteur par variables"
R="$(dx "$P-a" sh -c 'printf "protocol=https\nhost=github.com\n\n" | GIT_TERMINAL_PROMPT=0 git credential fill' 2>&1)"
contient "$R" "password=$JETON_GH" && ok "git : l'assistant d'identifiants rend GH_TOKEN pour github.com" || { ko "git ne rend pas GH_TOKEN"; info "$R"; }
R="$(dx -e GH_TOKEN= "$P-a" sh -c 'printf "protocol=https\nhost=github.com\n\n" | GIT_TERMINAL_PROMPT=0 git credential fill' 2>&1)"
! contient "$R" "$JETON_GH" && contient "$R" "password=identifiant-factice-gh" && ok "sans GH_TOKEN : repli sur la connexion gh du dev (~/.config/gh), le jeton du lab n'est stocké nulle part" || { ko "sans GH_TOKEN : comportement inattendu"; info "$R"; }
R="$(dx -e GH_TOKEN= -e GH_CONFIG_DIR=/tmp/gh-vide "$P-a" sh -c 'printf "protocol=https\nhost=github.com\n\n" | GIT_TERMINAL_PROMPT=0 git credential fill' 2>&1)"
contient "$R" "password=" && { ko "négatif — sans GH_TOKEN ni connexion gh, git trouve quand même un identifiant"; info "$R"; } || ok "négatif — sans GH_TOKEN ni connexion gh : git n'a aucun identifiant"
R="$(dx "$P-a" sh -c 'printf "protocol=https\nhost=exemple.test\n\n" | GIT_TERMINAL_PROMPT=0 git credential fill' 2>&1)"
contient "$R" "$JETON_GH" && ko "git envoie GH_TOKEN à un hôte autre que GitHub" || ok "négatif — git ne donne pas GH_TOKEN à un autre hôte que github.com"
contient "$(dx "$P-a" gh auth status 2>&1)" "GH_TOKEN" && ok "gh : utilise GH_TOKEN (jeton factice, donc refusé par GitHub — attendu)" || ko "gh n'utilise pas GH_TOKEN"
[[ ! -e "$H/.git-credentials" && ! -e "$H/.gitconfig" ]] && ok "ni ~/.git-credentials ni ~/.gitconfig créés" || ko "un fichier git a été créé dans la maison"
ENVCS="$(dx "$P-a" sh -c 'tr "\0" "\n" < /proc/$(pgrep -o -f "code-server --config")/environ')"
grep -qx 'GIT_AUTHOR_NAME=Alice Essai' <<<"$ENVCS" && grep -qx 'GIT_COMMITTER_EMAIL=alice@example.org' <<<"$ENVCS" \
  && ok "l'éditeur (donc son terminal) porte GIT_AUTHOR_*/GIT_COMMITTER_* tirés de LAB_GIT_AUTHOR_NAME/_EMAIL" || ko "auteur git non transmis à l'éditeur"

# ═════════════════════════════════════════════════════════════════════════════
titre "4. Préfixe /ws/<uid>/ : ce que le proxy doit faire (proxy Caddy jetable)"
cat > "$TMP/Caddyfile" <<'EOF'
{
	auto_https off
	admin off
}
# :8081 — le proxy RETIRE /ws/alice (ce qu'il faut)
:8081 {
	redir /ws/alice /ws/alice/ 308
	handle_path /ws/alice/* {
		reverse_proxy ws-test-image-a:8080
	}
	respond 404
}
# :8082 — le proxy NE retire PAS le préfixe (ce qui casse)
:8082 {
	handle /ws/alice/* {
		reverse_proxy ws-test-image-a:8080
	}
	respond 404
}
# :8083 — retire le préfixe mais RÉÉCRIT Host (ce qui casse les WebSockets)
:8083 {
	handle_path /ws/alice/* {
		reverse_proxy ws-test-image-a:8080 {
			header_up Host ws-test-image-a:8080
			header_up -X-Forwarded-Host
		}
	}
}
EOF
chmod 644 "$TMP/Caddyfile"
docker run -d --name "$P-proxy" --network "$P-net" --memory 128m --cpus 0.5 -v "$TMP/Caddyfile:/Caddyfile:ro" \
  --entrypoint caddy "$PROXY_IMAGE" run --config /Caddyfile --adapter caddyfile >/dev/null
sleep 3
code() { dx "$P-a" curl -s -o /dev/null -m 8 -w '%{http_code}' "$@"; }
PX="http://$P-proxy"
[[ "$(code "$PX:8081/ws/alice/?folder=/work/demo-app")" == 200 ]] && ok "préfixe retiré : la page de l'éditeur répond 200 sous /ws/alice/" || ko "page KO derrière le proxy qui retire le préfixe"
LOC="$(dx "$P-a" curl -s -o /dev/null -m 8 -D - "$PX:8081/ws/alice/" | tr -d '\r' | awk 'tolower($1)=="location:"{print $2}')"
[[ "$LOC" == "./?folder=/work/demo-app" ]] && ok "redirection RELATIVE vers le dossier du projet (Location: $LOC)" || ko "redirection inattendue : $LOC"
[[ "$(code "$PX:8081/ws/alice")" == 308 ]] && ok "sans barre finale : c'est au proxy de rediriger /ws/alice → /ws/alice/ (308 ici)" || ko "pas de redirection sans barre finale"
PAGE="$(dx "$P-a" curl -s -m 8 "$PX:8081/ws/alice/?folder=/work/demo-app")"
grep -oE '(href|src)="/[^"]*"' <<<"$PAGE" | grep -q . && ko "la page contient des chemins absolus" || ok "la page ne contient aucun chemin absolu (href/src tous relatifs)"
COMMIT="$(grep -oE 'stable-[0-9a-f]{40}' <<<"$PAGE" | head -1)"
[[ "$(code "$PX:8081/ws/alice/$COMMIT/static/out/vs/code/browser/workbench/workbench.js")" == 200 ]] && ok "ressource statique servie sous le préfixe (workbench.js)" || ko "ressource statique KO sous le préfixe"
[[ "$(code "$PX:8082/ws/alice/?folder=/work/demo-app")" == 404 ]] && ok "négatif — préfixe NON retiré : 404 (code-server n'a aucune option de préfixe, il sert à la racine)" || ko "le proxy sans retrait devrait donner 404"
wsup() { dx "$P-a" curl -s -o /dev/null -m 5 -w '%{http_code}' -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
  -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' "${@:2}" \
  "$1/ws/alice/$COMMIT?reconnectionToken=11111111-1111-4111-8111-111111111111&reconnection=false&skipWebSocketFrames=false"; }
[[ "$(wsup "$PX:8081" -H "Origin: $PX:8081")" == 101 ]] && ok "WebSocket : 101 Switching Protocols à travers le proxy, Origin = hôte public" || ko "WebSocket KO à travers le proxy"
[[ "$(wsup "$PX:8081" -H 'Origin: https://ailleurs.example')" == 403 ]] && ok "négatif — WebSocket avec une Origin étrangère : 403 (code-server compare Origin à Host)" || ko "WebSocket d'origine étrangère accepté"
[[ "$(wsup "$PX:8083" -H "Origin: $PX:8083")" == 403 ]] && ok "négatif — proxy qui réécrit Host sans X-Forwarded-Host : WebSocket 403 (le proxy doit transmettre l'hôte public)" || ko "un proxy réécrivant Host devrait casser le WebSocket"

# ═════════════════════════════════════════════════════════════════════════════
titre "5. Réseau vu de l'espace (réseau jetable ; le réseau réel est l'affaire du moteur)"
mkdir -p "$TMP/maison-bob" "$TMP/work/autre-app"
docker run -d --name "$P-b" --network "$P-net2" "${ENFERME[@]}" -v "$TMP/maison-bob:/home/coder" -v "$TMP/work/autre-app:/work/autre-app" \
  -e LAB_UID=bob -e LAB_APP=autre-app "$IMAGE" >/dev/null
if attend_sante "$P-b" 90 >/dev/null; then ok "second espace (bob), maison vide, sans LAB_MCP_URL ni jetons : l'éditeur démarre quand même"; else ko "second espace KO"; fi
contient "$(docker logs "$P-b" 2>&1)" "LAB_MCP_URL absente" && ok "… et l'absence de LAB_MCP_URL est signalée dans le journal" || ko "absence de LAB_MCP_URL non signalée"
[[ ! -e "$TMP/maison-bob/.claude.json" && ! -e "$TMP/maison-bob/.vibe/config.toml" ]] && ok "… sans déclaration MCP écrite (rien à déclarer)" || ko "déclaration MCP écrite sans URL"
IPB="$(docker inspect "$P-b" --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')"
joint() { dx "$P-a" timeout 4 bash -c "exec 3<>/dev/tcp/$1/$2" 2>/dev/null; }
verifie "l'espace se joint lui-même (127.0.0.1:8080)" joint 127.0.0.1 8080
refuse "négatif — un espace ne joint pas l'éditeur d'un autre espace placé sur un autre réseau ($IPB:8080)" joint "$IPB" 8080
for cible in dev-postgres dev-postgis keycloak; do
  ipc="$(docker inspect "$cible" --format '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' 2>/dev/null | awk '{print $1}')"
  [[ -z "$ipc" ]] && { info "$cible : conteneur absent sur cet hôte, non testé"; continue; }
  port=5432; [[ "$cible" == keycloak ]] && port=8080
  refuse "négatif — $cible ($ipc:$port, dev-net/sso-net) injoignable et son nom non résolu" bash -c "docker exec $P-a getent hosts $cible || docker exec $P-a timeout 4 bash -c 'exec 3<>/dev/tcp/$ipc/$port'"
done
for u in https://github.com https://api.anthropic.com https://api.mistral.ai https://registry.npmjs.org https://pypi.org/simple/; do
  c="$(code "$u")"; [[ "$c" =~ ^[2-4][0-9][0-9]$ ]] && ok "Internet : $u joignable (HTTP $c)" || ko "Internet : $u injoignable ($c)"
done
DOMAINE="$(grep -E '^DOMAIN=' "$ICI/../sso-lab/.env" 2>/dev/null | cut -d= -f2)"
if [[ -n "$DOMAINE" && "$DOMAINE" != CHANGE_ME ]]; then
  c="$(code "https://$DOMAINE/")"; [[ "$c" =~ ^[2-4][0-9][0-9]$ ]] && ok "URL publique du lab joignable depuis l'espace (https://<DOMAIN>/ → HTTP $c)" || ko "URL publique du lab injoignable depuis l'espace ($c)"
else
  info "DOMAIN non renseigné : URL publique du lab non testée"
fi
GW="$(docker network inspect "$P-net" --format '{{(index .IPAM.Config 0).Gateway}}')"
OUVERTS=""; for p in 22 389 5050 5432 8083 8093; do joint "$GW" "$p" && OUVERTS+="$p "; done
[[ -n "$OUVERTS" ]] && info "À SAVOIR (hors image, pour le moteur) : depuis un pont Docker ordinaire, la passerelle de l'hôte ($GW) répond sur les ports : $OUVERTS" \
                    || info "passerelle de l'hôte ($GW) : aucun des ports sondés ne répond"

# ═════════════════════════════════════════════════════════════════════════════
titre "6. Mesures (espace alice)"
mesure "au repos, personne de connecté : $(mem_mo "$P-a") Mo (dont $(anon_mo "$P-a") Mo anonymes, le reste est du cache de fichiers récupérable) · $(dx "$P-a" cat /sys/fs/cgroup/pids.current) processus/fils"

if [[ $NAVIGATEUR -eq 1 ]] && docker image inspect "$NAV_IMAGE" >/dev/null 2>&1; then
  titre "7. Navigateur réel (Chromium) à travers le proxy, sous /ws/alice/"
  dx -i "$P-a" sh -c 'cat > /tmp/preuve_terminal.sh' < "$ICI/tests/preuve_terminal.sh"
  docker run -d --name "$P-nav" --network "$P-net" --memory 1500m --cpus 1 -v "$ICI/tests:/t:ro" \
    -e NODE_PATH=/app/node_modules -e WS_URL="$PX:8081/ws/alice" -e TENIR_S=75 "$NAV_IMAGE" node /t/navigateur.js >/dev/null
  for _ in $(seq 1 240); do docker logs "$P-nav" 2>&1 | grep -q '^PRET' && break; docker ps -q --filter "name=^$P-nav$" | grep -q . || break; sleep 2; done
  RES="$(docker logs "$P-nav" 2>&1 | grep '^RESULTAT ' | tail -1 | cut -d' ' -f2-)"
  if [[ -z "$RES" ]]; then ko "le navigateur n'a rendu aucun résultat"; docker logs "$P-nav" 2>&1 | tail -5
  else
    q() { jq -r "$1" <<<"$RES"; }
    [[ "$(q .urlFinale)" == "$PX:8081/ws/alice/?folder=/work/demo-app" ]] && ok "arrivée par /ws/alice → URL finale $(q .urlFinale)" || ko "URL finale inattendue : $(q .urlFinale)"
    for e in page fichier_python extension_python terminal; do
      [[ "$(q ".etapes.$e")" == ok ]] && ok "étape « $e »" || ko "étape « $e » : $(q ".etapes.$e")"
    done
    # vsda : module propriétaire de Microsoft absent de toute distribution libre de VS Code — 404 attendu, même en accès direct.
    ERR="$(q '.erreurs[]' | grep -v '/node_modules/vsda/' || true)"
    [[ -z "$ERR" ]] && ok "aucune ressource en erreur côté proxy (hors vsda, absent de code-server par construction)" || { ko "ressources en erreur"; info "$ERR"; }
    [[ "$(q '.horsPrefixe | length')" == 0 ]] && ok "aucune requête hors du préfixe /ws/alice/" || ko "requêtes hors préfixe : $(q '.horsPrefixe | join(" ")')"
    [[ "$(q '[.sockets[] | select((.chemin | startswith("/ws/alice/")) and .recues > 10 and (.fermee | not))] | length')" -ge 2 ]] \
      && ok "WebSockets ouverts sous le préfixe, trames reçues, restés ouverts : $(q '[.sockets[] | "\(.recues) trames"] | join(", ")')" || ko "WebSockets : $(q '.sockets | tostring')"
    contient "$(q '.barreEtat | join(" | ")')" "3.12." && ok "extension Python active (interpréteur 3.12 dans la barre d'état)" || ko "extension Python inactive : $(q '.barreEtat | join(" | ")')"
    PT="$(dx "$P-a" cat /tmp/preuve-terminal.out 2>/dev/null)"
    if contient "$PT" "fin"; then
      contient "$PT" "pwd=/work/demo-app" && ok "terminal intégré : s'ouvre dans /work/demo-app" || ko "terminal : dossier inattendu"
      grep -q '^claude=.*Claude Code' <<<"$PT" && grep -q '^vibe=vibe ' <<<"$PT" && ok "terminal intégré : claude et vibe répondent ($(grep '^claude=' <<<"$PT" | cut -d= -f2) · $(grep '^vibe=' <<<"$PT" | cut -d= -f2))" || ko "terminal : claude/vibe ne répondent pas"
      grep -qx 'jeton_mcp=present' <<<"$PT" && grep -qx 'LAB_APP=demo-app' <<<"$PT" && ok "terminal intégré : variables d'I3 héritées (LAB_APP, LAB_MCP_TOKEN présent)" || ko "terminal : variables non héritées"
      grep -qx 'auteur=Alice Essai <alice@example.org>' <<<"$PT" && ok "terminal intégré : un commit porte l'auteur de LAB_GIT_AUTHOR_NAME/_EMAIL" || ko "terminal : auteur de commit inattendu ($(grep '^auteur=' <<<"$PT"))"
    else ko "la commande tapée dans le terminal intégré ne s'est pas exécutée"; fi
    mesure "éditeur ouvert + fichier Python + extension Python active + un terminal : $(mem_mo "$P-a") Mo (dont $(anon_mo "$P-a") Mo anonymes) · $(dx "$P-a" cat /sys/fs/cgroup/pids.current) processus/fils"
    # Les deux IA à leur premier écran (aucun identifiant : pas de conversation possible).
    dx -d -t -w /work/demo-app "$P-a" claude; dx -d -t -w /work/demo-app "$P-a" vibe; sleep 25
    RSS="$(dx "$P-a" ps -eo rss,args --sort=-rss | awk '$2=="claude"{c=$1} /Vibe CLI|bin\/vibe/{if(!v)v=$1} END{printf "claude %d Mo, vibe %d Mo", c/1024, v/1024}')"
    mesure "… + Claude Code et Vibe lancés, à leur premier écran : $(mem_mo "$P-a") Mo (dont $(anon_mo "$P-a") Mo anonymes ; RSS $RSS) · $(dx "$P-a" cat /sys/fs/cgroup/pids.current) processus/fils"
  fi
  dx "$P-a" pkill -x claude; dx "$P-a" pkill -f 'Vibe CLI'; sleep 2
  mesure "pics depuis le démarrage : mémoire $(dx "$P-a" sh -c 'echo $(( $(cat /sys/fs/cgroup/memory.peak) / 1048576 ))') Mo sur $MEM · $(dx "$P-a" cat /sys/fs/cgroup/pids.peak) processus/fils sur $PIDS · OOM : $(dx "$P-a" awk '$1=="oom_kill"{print $2}' /sys/fs/cgroup/memory.events)"
  docker rm -f "$P-nav" >/dev/null 2>&1
else
  titre "7. Navigateur réel"
  info "non lancé (--sans-navigateur, ou image $NAV_IMAGE absente) : page, WebSocket et terminal ne sont prouvés que par curl"
fi
docker rm -f "$P-proxy" "$P-b" >/dev/null 2>&1

# ═════════════════════════════════════════════════════════════════════════════
titre "8. Relance : rien de ce qui appartient au dev ne bouge"
[[ "$(sommes)" == "$AVANT" ]] && ok "après le premier démarrage et tous les essais : identifiants factices et réglages d'éditeur inchangés (sha256)" || ko "un fichier protégé a changé"
M1="$(cd "$H" && sha256sum .claude.json .vibe/config.toml .claude/CLAUDE.md .vibe/AGENTS.md)"
docker restart "$P-a" >/dev/null
if D2=$(attend_sante "$P-a" 90); then mesure "redémarrage (tout déjà en place) : $(dixiemes "$D2")"; else ko "l'espace ne redémarre pas"; fi
J2="$(docker logs "$P-a" 2>&1 | tail -n +"$(( $(wc -l <<<"$JOURNAL") + 1 ))")"
[[ "$(grep -c 'inchangé' <<<"$J2")" -ge 4 ]] && ok "relance : règles et déclarations MCP reconnues « inchangé » (aucune réécriture)" || { ko "la relance a réécrit quelque chose"; info "$(grep lab-workspace <<<"$J2")"; }
contient "$J2" "extensions de l'image recopiées" && ko "la relance a recopié les extensions" || ok "relance : les extensions du dev ne sont pas retouchées"
[[ "$(sommes)" == "$AVANT" ]] && ok "relance : identifiants factices et réglages d'éditeur inchangés (sha256)" || ko "la relance a modifié un fichier protégé"
[[ "$(cd "$H" && sha256sum .claude.json .vibe/config.toml .claude/CLAUDE.md .vibe/AGENTS.md)" == "$M1" ]] && ok "relance : fichiers de configuration identiques à l'octet" || ko "la relance a modifié un fichier de configuration"
docker rm -f "$P-a" >/dev/null 2>&1

titre "9. Autre adresse de MCP, système de fichiers en lecture seule"
# Même maison, LAB_MCP_URL différente, et --read-only + tmpfs /tmp (durcissement que le moteur PEUT ajouter).
docker run -d --name "$P-a" --network "$P-net" "${ENFERME[@]}" --read-only --tmpfs /tmp \
  -v "$H:/home/coder" -v "$W:/work/demo-app" \
  -e LAB_UID=alice -e LAB_APP=demo-app -e LAB_MCP_URL=https://lab.exemple.test/mcp -e LAB_MCP_TOKEN="$JETON_MCP" "$IMAGE" >/dev/null
if attend_sante "$P-a" 90 >/dev/null; then ok "l'espace démarre aussi avec --read-only --tmpfs /tmp"; else ko "l'espace ne démarre pas en --read-only --tmpfs /tmp"; docker logs "$P-a" 2>&1 | tail -8; fi
[[ "$(jq -r '.mcpServers.lab.url' "$H/.claude.json")" == "https://lab.exemple.test/mcp" && "$(jq -r '.mcpServers | keys | join(",")' "$H/.claude.json")" == "lab,perso" ]] \
  && ok "Claude Code : déclaration mise à jour vers la nouvelle LAB_MCP_URL, sans doublon" || ko "Claude Code : URL non mise à jour"
[[ "$(grep -c '^name = "lab"$' "$H/.vibe/config.toml")" == 1 ]] && grep -q '^url = "https://lab.exemple.test/mcp"$' "$H/.vibe/config.toml" \
  && ok "Vibe : déclaration mise à jour vers la nouvelle LAB_MCP_URL, sans doublon" || ko "Vibe : URL non mise à jour"
[[ "$(sommes)" == "$AVANT" ]] && ok "identifiants factices et réglages d'éditeur toujours inchangés (sha256)" || ko "un fichier protégé a changé"
T="$(grep -rlF -- "$JETON_MCP" "$H" 2>/dev/null)"; [[ -z "$T" ]] && ok "le jeton n'est toujours dans aucun fichier de la maison" || ko "jeton écrit dans : $T"

# ═════════════════════════════════════════════════════════════════════════════
printf '\n\033[1m── Bilan\033[0m\n'
printf '  %d vérifications vertes, %d rouges\n' "$OK" "$KO"
printf '  Mesures :\n'; for m in "${MESURES[@]}"; do printf '    - %s\n' "$m"; done
[[ $KO -eq 0 ]]
