#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# verify.sh — vérification réelle et rejouable de l'image lab-workspace (I7).
#
#   bash workspace/verify.sh [--sans-navigateur] [--conversation] [--garder]
#
#   --conversation : ne joue que la section 10 (service de conversation avec le faux agent).
#
# Couvre l'éditeur (code-server, :8080) ET le service de conversation (:8090, chantier
# « espace-chat ») : vrais agents ACP sans identifiants réels, puis conversation complète avec
# le faux agent de tests/faux_agent_acp.js, au niveau du protocole et en navigateur réel.
#
# Ne construit PAS l'image (un build passe par le verrou du lab) :
#   bash scripts/lab-lock.sh docker build -t lab-workspace:dev workspace
#
# Tout tourne dans des conteneurs jetables `<préfixe>-*`, sur des réseaux
# jetables `<préfixe>-net*` créés ici — jamais dev-net ni sso-net — et sous
# les options d'enfermement d'I3. Aucun identifiant réel n'est utilisé : les
# jetons sont des chaînes factices, le serveur MCP est un faux (tests/faux_mcp.py).
# Tout est supprimé à la sortie (sauf --garder).
#
# Réglages : WS_IMAGE (lab-workspace:dev) · WS_VERIFY_NAV_IMAGE (runner-runner:latest,
# toute image portant Playwright dans /app/node_modules) · WS_VERIFY_PROXY_IMAGE
# (image portant le binaire `caddy`) · WS_MEM (2g) · WS_CPUS (1) · WS_PIDS (512) ·
# WS_VERIFY_PREFIX (ws-test-image : préfixe des conteneurs et réseaux jetables) ·
# WS_VERIFY_CAPTURES (dossier où garder les captures d'écran de la conversation ; aucune sinon).
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
P="${WS_VERIFY_PREFIX:-ws-test-image}"
[[ "$P" =~ ^[a-z][a-z0-9-]{2,30}$ && "$P" != lab* ]] || { echo "WS_VERIFY_PREFIX invalide" >&2; exit 2; }
CAPTURES="${WS_VERIFY_CAPTURES:-}"
NAVIGATEUR=1; GARDER=0; CONV_SEULE=0
for a in "$@"; do
  case "$a" in
    --sans-navigateur) NAVIGATEUR=0 ;;
    --garder) GARDER=1 ;;
    --conversation) CONV_SEULE=1 ;;      # section 10 seule (service de conversation, faux agent)
    *) echo "Usage : bash workspace/verify.sh [--sans-navigateur] [--conversation] [--garder]" >&2; exit 2 ;;
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
# attend_sante <conteneur> <secondes max> [port, défaut 8080] → affiche le délai en dixièmes de seconde
attend_sante() {
  local c="$1" max="$2" port="${3:-8080}" t0 t; t0=$(date +%s%N)
  while :; do
    dx "$c" curl -sf -o /dev/null -m 2 "http://127.0.0.1:$port/healthz" 2>/dev/null && break
    t=$(( ($(date +%s%N) - t0) / 1000000 ))
    (( t > max * 1000 )) && return 1
    docker ps -q --filter "name=^${c}$" | grep -q . || return 1
    sleep 0.2
  done
  echo $(( ($(date +%s%N) - t0) / 100000000 ))
}
dixiemes() { printf '%d,%d s' $(( $1 / 10 )) $(( $1 % 10 )); }
# Client d'essai du service de conversation, lancé DANS l'espace : chat <conteneur> <args…> → JSON
chat() { local c="$1"; shift; dx -e NODE_PATH=/opt/lab/chat/node_modules "$c" node /t/chat_client.js "$@" 2>&1 | grep '^RESULTAT ' | tail -1 | cut -d' ' -f2-; }
# Un seul navigateur à la fois sur l'hôte : attend que le runner du lab soit libre (5 min au plus).
runner_libre() {
  local i
  for i in $(seq 1 60); do
    if ! docker ps -q --filter name='^lab-runner$' | grep -q .; then return 0; fi
    if docker exec lab-runner node -e "fetch('http://localhost:4300/healthz').then(r=>r.json()).then(j=>process.exit(j.busy?1:0)).catch(()=>process.exit(0))" 2>/dev/null \
       && ! docker exec lab-runner sh -c 'ps -eo stat,args | grep -i "[c]hrom" | grep -qv "^Z"' 2>/dev/null; then return 0; fi
    sleep 5
  done
  return 1
}

# ═════════════════════════════════════════════════════════════════════════════
titre "0. Image : versions épinglées, rien de secret"
verifie "Dockerfile : aucune image ni version « latest »" bash -c "! grep -nE '(:latest|@latest)\\b' '$ICI/Dockerfile'"
verifie "Dockerfile : aucun « curl | bash »" bash -c "! grep -vE '^[[:space:]]*#' '$ICI/Dockerfile' | grep -nE 'curl[^|]*\\|[[:space:]]*(ba)?sh'"
verifie "contexte de build fermé (.dockerignore en liste blanche)" bash -c "head -3 '$ICI/.dockerignore' | grep -qx '\\*'"
verifie "chat/package.json : dépendances en versions exactes" jq -e '[.dependencies[]] | length > 0 and all(test("^[0-9]+\\.[0-9]+\\.[0-9]+$"))' "$ICI/chat/package.json"
verifie "chat/package-lock.json : chaque paquet du verrou porte son adresse et sa somme d'intégrité" jq -e '[.packages | to_entries[] | select(.key != "") | .value | (has("integrity") and has("resolved"))] | length > 50 and all' "$ICI/chat/package-lock.json"
TAILLE=$(docker image inspect "$IMAGE" --format '{{.Size}}')
mesure "taille de l'image : $(( TAILLE / 1048576 )) Mo (contenu, compressé) — $(docker images --format '{{.Size}}' "$IMAGE" | head -1) sur disque"
ENVIMG="$(docker image inspect "$IMAGE" --format '{{range .Config.Env}}{{println .}}{{end}}')"
refuse "aucune variable de l'image ne ressemble à un secret" grep -qiE '^(.*TOKEN|.*SECRET|.*PASSWORD|.*API_KEY)=' <<<"$ENVIMG"
info "versions annoncées par l'image : $(grep '^LAB_WORKSPACE_VERSIONS=' <<<"$ENVIMG" | cut -d= -f2-)"

# Préparation commune : dossiers, réseaux jetables, proxy (lancé plus bas, là où il sert).
H="$TMP/maison-alice"; W="$TMP/work/demo-app"; mkdir -p "$W"
docker network create "$P-net" >/dev/null && docker network create "$P-net2" >/dev/null || { ko "création des réseaux jetables"; exit 1; }
PX="http://$P-proxy"
cat > "$TMP/Caddyfile" <<EOF
{
	auto_https off
	admin off
}
# :8081 — le proxy RETIRE le préfixe (ce qu'il faut) : /ws/<uid>/_chat/ → service de
# conversation (:8090), le reste de /ws/<uid>/ → éditeur (:8080)
:8081 {
	redir /ws/alice /ws/alice/ 308
	handle_path /ws/alice/_chat/* {
		reverse_proxy $P-a:8090
	}
	handle_path /ws/alice/* {
		reverse_proxy $P-a:8080
	}
	handle_path /ws/carol/_chat/* {
		reverse_proxy $P-c:8090
	}
	respond 404
}
# :8082 — le proxy NE retire PAS le préfixe (ce qui casse)
:8082 {
	handle /ws/alice/* {
		reverse_proxy $P-a:8080
	}
	respond 404
}
# :8083 — retire le préfixe mais RÉÉCRIT Host (ce qui casse les WebSockets)
:8083 {
	handle_path /ws/alice/_chat/* {
		reverse_proxy $P-a:8090 {
			header_up Host $P-a:8090
			header_up -X-Forwarded-Host
		}
	}
	handle_path /ws/alice/* {
		reverse_proxy $P-a:8080 {
			header_up Host $P-a:8080
			header_up -X-Forwarded-Host
		}
	}
}
EOF
chmod 644 "$TMP/Caddyfile"

if [[ $CONV_SEULE -eq 0 ]]; then
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
  echo "second_claude=$(ls -d /opt/lab/chat/node_modules/@anthropic-ai/claude-agent-sdk-* 2>/dev/null | tr "\n" " ")"
  echo "chat_deps=$(cd /opt/lab/chat && node -p "[\"ws\",\"@agentclientprotocol/claude-agent-acp\"].map(p=>p+\"@\"+require(\"./node_modules/\"+p+\"/package.json\").version).join(\" \")" 2>&1)"
  echo "vibe_acp=$(command -v vibe-acp)"
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
[[ "$(val chat_deps)" == "ws@$(jq -r .dependencies.ws "$ICI/chat/package.json") @agentclientprotocol/claude-agent-acp@$(jq -r '.dependencies["@agentclientprotocol/claude-agent-acp"]' "$ICI/chat/package.json")" ]] && ok "service de conversation : dépendances installées = versions du verrou ($(val chat_deps))" || ko "dépendances du service de conversation inattendues : $(val chat_deps)"
[[ -z "$(val second_claude)" && -n "$(val vibe_acp)" ]] && ok "pas de second binaire claude embarqué par l'agent ACP (il pilote celui de l'image) ; vibe-acp présent" || ko "second binaire claude embarqué ($(val second_claude)) ou vibe-acp absent"
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

URL_MCP=http://127.0.0.1:9000/mcp      # faux serveur MCP, lancé DANS le conteneur (boucle locale)
lance_a() {
  docker run -d --name "$P-a" --network "$P-net" "${ENFERME[@]}" \
    -v "$H:/home/coder" -v "$W:/work/demo-app" -v "$ICI/tests:/t:ro" \
    -e LAB_UID=alice -e LAB_APP=demo-app -e LAB_MCP_URL="$1" -e LAB_MCP_TOKEN="$JETON_MCP" -e GH_TOKEN="$JETON_GH" \
    -e LAB_GIT_AUTHOR_NAME="Alice Essai" -e LAB_GIT_AUTHOR_EMAIL=alice@example.org "$IMAGE" >/dev/null
}
lance_a "$URL_MCP"
if D1=$(attend_sante "$P-a" 90); then
  ok "code-server répond sur 8080 (/healthz) sous cap_drop ALL + no-new-privileges + $MEM / $CPUS vCPU / $PIDS pids"
  mesure "premier démarrage (règles + 2 déclarations MCP + copie des extensions + éditeur) : $(dixiemes "$D1")"
  if DC=$(attend_sante "$P-a" 30 8090); then ok "le service de conversation répond sur 8090 (/healthz) sous les mêmes options"; mesure "… service de conversation prêt $(dixiemes "$DC") après l'éditeur"
  else ko "le service de conversation ne répond pas sur 8090"; fi
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

titre "3f. Service de conversation : vrais agents ACP à travers le service (aucun identifiant réel)"
[[ "$(dx "$P-a" curl -s -m 5 http://127.0.0.1:8090/healthz)" == '{"ok":true}' ]] && ok 'GET /healthz → 200 {"ok":true}' || ko "/healthz inattendu"
[[ "$(dx "$P-a" curl -s -m 5 http://127.0.0.1:8090/activity)" == '{"last_activity_ms":0}' ]] && ok 'GET /activity → {"last_activity_ms":0} tant que personne ne s'"'"'est connecté' || ko "/activity inattendu : $(dx "$P-a" curl -s -m 5 http://127.0.0.1:8090/activity)"
EP="$(dx "$P-a" sh -c 'a=$(pgrep -o -f "code-server --config"); b=$(pgrep -o -f "chat/server.js"); [ -n "$a" ] && [ -n "$b" ] && [ "$(stat -c %u /proc/$a)" = "$(stat -c %u /proc/$b)" ] && [ "$(tr "\0" "\n" < /proc/$a/environ | grep -v "^_=" | sort | sha256sum)" = "$(tr "\0" "\n" < /proc/$b/environ | grep -v "^_=" | sort | sha256sum)" ] && echo memes; readlink /proc/$b/cwd')"
contient "$EP" "memes" && ok "même utilisateur et même environnement que l'éditeur (donc que son terminal) — comparés sans les afficher" || ko "le service de conversation n'a pas l'environnement de l'éditeur"
contient "$EP" "/work/demo-app" && ok "le service tourne dans /work/demo-app" || ko "dossier du service inattendu : $EP"
HP="$(dx "$P-a" curl -s -m 5 -D - -o /dev/null http://127.0.0.1:8090/ | tr -d '\r')"
grep -qi "^content-security-policy: default-src 'none'" <<<"$HP" && ok "la page est servie avec une politique de contenu fermée (default-src 'none', scripts et styles du service seul)" || ko "politique de contenu absente"
PG="$(dx "$P-a" sh -c 'curl -s -m 5 http://127.0.0.1:8090/; curl -s -m 5 http://127.0.0.1:8090/app.js; curl -s -m 5 http://127.0.0.1:8090/style.css')"
grep -oE '(href|src)="[^"]*"' <<<"$PG" | grep -vE '="(style\.css|app\.js|\.\./|data:,)"' | grep -q . && ko "la page référence autre chose que ses propres fichiers" || ok "la page ne référence que style.css, app.js et ../ (l'éditeur) : URL relatives, aucun CDN"
grep -vE '^[[:space:]]*(//|\*|/\*)' <<<"$PG" | grep -qE '(https?:)?//[a-z0-9-]+(\.[a-z0-9-]+)+' && ko "une adresse externe figure dans la page ou ses scripts" || ok "aucune adresse externe dans la page, son script ni sa feuille de style"
N1=$(dx "$P-a" sh -c 'grep -c "^tools/list auth=OK agent=claude-code/.*sdk-ts" /tmp/faux-mcp.log'); N2=$(dx "$P-a" sh -c 'grep -c "^tools/list auth=OK agent=MistralAI-VibeCLI/" /tmp/faux-mcp.log')
RC="$(chat "$P-a" ouvre claude)"; qc() { jq -r "$1" <<<"$RC"; }
[[ "$(qc '.agent.state + " " + .agent.info.name')" == "ready @agentclientprotocol/claude-agent-acp" ]] \
  && ok "Claude : « initialize » ACP v1 à travers le service → $(qc '.agent.info.name')@$(qc '.agent.info.version') (en $(qc .ms) ms, session comprise)" || { ko "Claude : l'agent ACP ne démarre pas à travers le service"; info "$RC"; }
[[ "$(qc '.session.mode.current')" == default ]] && ok "Claude : conversation ouverte dans /work/demo-app, mode « default » (demander avant d'agir)" || { ko "Claude : conversation non ouverte ou mode inattendu"; info "$RC"; }
[[ "$(dx "$P-a" sh -c 'grep -c "^tools/list auth=OK agent=claude-code/.*sdk-ts" /tmp/faux-mcp.log')" -gt "$N1" ]] \
  && ok "Claude : en mode ACP, il joint le MCP « lab » déclaré dans la maison avec le jeton de l'environnement (vu par le faux serveur)" || ko "Claude en mode ACP n'a pas joint le MCP du lab"
RV="$(chat "$P-a" ouvre vibe)"; qv() { jq -r "$1" <<<"$RV"; }
[[ "$(qv '.agent.state + " " + .agent.info.name')" == "ready @mistralai/mistral-vibe" ]] \
  && ok "Vibe : « initialize » ACP v1 à travers le service → $(qv '.agent.info.name')@$(qv '.agent.info.version') (en $(qv .ms) ms, session comprise)" || { ko "Vibe : l'agent ACP ne démarre pas à travers le service"; info "$RV"; }
[[ "$(qv '.session.mode.current')" == ask ]] && ok "Vibe (clé factice) : conversation ouverte, mode ramené à « ask » — Vibe démarre de lui-même en « accept-edits »" || { ko "Vibe : mode strict non imposé"; info "$RV"; }
[[ "$(qv '.session.trust')" == untrusted ]] && ok "Vibe : dossier « non approuvé » signalé à la page (elle propose de lui faire confiance, comme le terminal)" || info "Vibe : état de confiance du dossier = $(qv '.session.trust')"
[[ "$(dx "$P-a" sh -c 'grep -c "^tools/list auth=OK agent=MistralAI-VibeCLI/" /tmp/faux-mcp.log')" -gt "$N2" ]] \
  && ok "Vibe : en mode ACP, il joint le MCP « lab » déclaré dans la maison avec le jeton de l'environnement" || ko "Vibe en mode ACP n'a pas joint le MCP du lab"
[[ "$(qc .activite)$(qv .activite)" == 00 ]] && ok "ouvrir une conversation sans rien échanger ne compte pas comme activité (/activity reste à 0)" || ko "l'ouverture seule a compté comme activité"
JS="$(docker logs "$P-a" 2>&1 | grep -F '[lab-chat]')"
FUITE=0; for motif in "$JETON_MCP" "$JETON_GH" identifiant-factice; do contient "$JS$RC$RV" "$motif" && { FUITE=1; ko "« $motif » apparaît dans le journal du service ou dans ce qu'il envoie à la page"; }; done
[[ $FUITE -eq 0 ]] && ok "ni jeton ni identifiant factice dans le journal du service, ni dans ce qu'il envoie à la page"
[[ "$(sommes)" == "$AVANT" ]] && ok "identifiants factices de la maison inchangés après le passage des deux agents (sha256)" || ko "un fichier d'identifiants a changé"
mesure "deux agents ACP lancés, une conversation ouverte chacun : $(mem_mo "$P-a") Mo (RSS : $(dx "$P-a" ps -eo rss,args --sort=-rss | awk '/claude-agent-acp/{a+=$1} $2=="/usr/local/bin/claude"{c+=$1} /vibe-acp/{v+=$1} /chat\/server.js/{s+=$1} END{printf "service %d Mo, agent Claude %d + claude %d Mo, vibe-acp %d Mo", s/1024, a/1024, c/1024, v/1024}'))"
# Les mesures « au repos » de la section 6 se font sans agent : le service est tué, ses agents
# s'arrêtent avec lui (entrée fermée), l'entrée le relance.
dx "$P-a" sh -c 'pkill -KILL -f "^node /opt/lab/chat/server.js"'; sleep 4
RESTES="$(dx "$P-a" sh -c 'ps -eo args | grep -E "claude-agent-acp|vibe-acp|^/usr/local/bin/claude " | grep -v grep')"
[[ -z "$RESTES" ]] && ok "service tué : aucun processus d'agent ne lui survit (ni l'agent ACP, ni le claude qu'il pilote, ni vibe-acp)" || { ko "des agents survivent à l'arrêt du service"; info "$RESTES"; }
attend_sante "$P-a" 30 8090 >/dev/null && ok "… et l'entrée relance le service" || ko "service de conversation non relancé"

# ═════════════════════════════════════════════════════════════════════════════
titre "4. Préfixe /ws/<uid>/ : ce que le proxy doit faire (proxy Caddy jetable)"
docker run -d --name "$P-proxy" --network "$P-net" --memory 128m --cpus 0.5 -v "$TMP/Caddyfile:/Caddyfile:ro" \
  --entrypoint caddy "$PROXY_IMAGE" run --config /Caddyfile --adapter caddyfile >/dev/null
sleep 3
code() { dx "$P-a" curl -s -o /dev/null -m 8 -w '%{http_code}' "$@"; }
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

# Le service de conversation derrière le même proxy, sous /ws/alice/_chat/
[[ "$(code "$PX:8081/ws/alice/_chat/?agent=vibe")" == 200 && "$(code "$PX:8081/ws/alice/_chat/app.js")" == 200 && "$(code "$PX:8081/ws/alice/_chat/healthz")" == 200 ]] \
  && ok "conversation : page, script et /healthz servis sous /ws/alice/_chat/ (préfixe retiré par le proxy)" || ko "conversation : page KO derrière le proxy"
wschat() { dx "$P-a" curl -s -o /dev/null -m 5 -w '%{http_code}' -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
  -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' "${@:2}" "$1"; }
[[ "$(wschat "$PX:8081/ws/alice/_chat/ws" -H "Origin: $PX:8081")" == 101 ]] && ok "conversation : WebSocket 101 à travers le proxy, Origin = hôte public" || ko "conversation : WebSocket KO à travers le proxy"
[[ "$(wschat "$PX:8081/ws/alice/_chat/ws" -H 'Origin: https://ailleurs.example')" == 403 ]] && ok "négatif — conversation : WebSocket avec une Origin étrangère : 403" || ko "conversation : WebSocket d'origine étrangère accepté"
[[ "$(wschat "$PX:8081/ws/alice/_chat/ws")" == 403 ]] && ok "négatif — conversation : WebSocket sans Origin : 403" || ko "conversation : WebSocket sans Origin accepté"
[[ "$(wschat "$PX:8081/ws/alice/_chat/ws" -H "Origin: http://$P-a:8090")" == 403 ]] && ok "négatif — conversation : Origin = adresse interne du service alors que l'hôte public est le proxy : 403 (X-Forwarded-Host fait foi)" || ko "conversation : Origin interne acceptée derrière le proxy"
[[ "$(wschat "$PX:8083/ws/alice/_chat/ws" -H "Origin: $PX:8083")" == 403 ]] && ok "négatif — conversation : proxy qui réécrit Host sans X-Forwarded-Host : WebSocket 403 (le proxy doit transmettre l'hôte public)" || ko "conversation : un proxy réécrivant Host devrait casser le WebSocket"
[[ "$(wschat "http://127.0.0.1:8090/ws" -H 'Origin: http://127.0.0.1:8090')" == 101 && "$(wschat "http://127.0.0.1:8090/autre" -H 'Origin: http://127.0.0.1:8090')" == 404 ]] \
  && ok "conversation : sans proxy, l'Origin est comparée à Host ; le WebSocket n'existe que sur /ws" || ko "conversation : contrôle d'Origin direct inattendu"
[[ "$(dx "$P-a" curl -s -o /dev/null -m 5 -w '%{http_code}' -X POST http://127.0.0.1:8090/)$(code http://127.0.0.1:8090/server.js)$(code http://127.0.0.1:8090/public/app.js)" == 405404404 ]] \
  && ok "négatif — conversation : aucune écriture par HTTP (POST → 405), aucun fichier servi hors de la page (404)" || ko "conversation : réponses HTTP inattendues"
[[ "$(dx "$P-a" curl -s -m 5 http://127.0.0.1:8090/activity)" == '{"last_activity_ms":0}' ]] && ok "des poignées de main WebSocket sans message n'ont pas compté comme activité" || ko "une simple connexion a compté comme activité"

# ═════════════════════════════════════════════════════════════════════════════
titre "5. Réseau vu de l'espace (réseau jetable ; le réseau réel est l'affaire du moteur)"
mkdir -p "$TMP/maison-bob" "$TMP/work/autre-app"
docker run -d --name "$P-b" --network "$P-net2" "${ENFERME[@]}" -v "$TMP/maison-bob:/home/coder" -v "$TMP/work/autre-app:/work/autre-app" -v "$ICI/tests:/t:ro" \
  -e LAB_UID=bob -e LAB_APP=autre-app -e LAB_CHAT_AGENT_IDLE_S=5 "$IMAGE" >/dev/null
if attend_sante "$P-b" 90 >/dev/null; then ok "second espace (bob), maison vide, sans LAB_MCP_URL ni jetons : l'éditeur démarre quand même"; else ko "second espace KO"; fi
contient "$(docker logs "$P-b" 2>&1)" "LAB_MCP_URL absente" && ok "… et l'absence de LAB_MCP_URL est signalée dans le journal" || ko "absence de LAB_MCP_URL non signalée"
[[ ! -e "$TMP/maison-bob/.claude.json" && ! -e "$TMP/maison-bob/.vibe/config.toml" ]] && ok "… sans déclaration MCP écrite (rien à déclarer)" || ko "déclaration MCP écrite sans URL"
# Maison vide, donc AUCUN identifiant d'assistant : ce que le service en dit à la page.
if attend_sante "$P-b" 30 8090 >/dev/null; then
  RB="$(chat "$P-b" ouvre claude)"
  [[ "$(jq -r '.agent.state + " " + .agent.auth + " " + (.session != null | tostring)' <<<"$RB")" == "ready none true" ]] \
    && ok "sans identifiants — Claude : l'agent annonce « non connecté », le service le transmet à la page (auth = none), sans rien inventer" || { ko "sans identifiants — Claude : état inattendu"; info "$RB"; }
  RB="$(chat "$P-b" ouvre vibe)"
  [[ "$(jq -r '.agent.state + " " + .agent.auth + " " + (.session == null | tostring) + " " + .erreurs[0].code' <<<"$RB")" == "ready none true auth" ]] \
    && ok "sans identifiants — Vibe : conversation refusée par l'agent (clé absente), le service le transmet à la page (auth = none)" || { ko "sans identifiants — Vibe : état inattendu"; info "$RB"; }
  # Plus aucune page ouverte : les agents inoccupés sont arrêtés (délai ramené à 5 s pour l'essai).
  for _ in $(seq 1 25); do dx "$P-b" sh -c 'ps -eo args | grep -E "claude-agent-acp|vibe-acp|^/usr/local/bin/claude " | grep -qv grep' || break; sleep 2; done
  RESTES="$(dx "$P-b" sh -c 'ps -eo args | grep -E "claude-agent-acp|vibe-acp|^/usr/local/bin/claude " | grep -v grep')"
  [[ -z "$RESTES" && "$(docker logs "$P-b" 2>&1 | grep -c 'inactif, arrêté')" -ge 2 ]] && ok "agents sans page ouverte ni tour en cours : arrêtés par le service, aucun processus ne reste (la mémoire est rendue à l'espace)" || { ko "agents inoccupés non arrêtés"; info "$RESTES"; }
else ko "second espace : le service de conversation ne répond pas"; fi
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
if attend_sante "$P-a" 90 >/dev/null && attend_sante "$P-a" 30 8090 >/dev/null; then ok "l'espace (éditeur et service de conversation) démarre aussi avec --read-only --tmpfs /tmp"; else ko "l'espace ne démarre pas en --read-only --tmpfs /tmp"; docker logs "$P-a" 2>&1 | tail -8; fi
[[ "$(jq -r '.mcpServers.lab.url' "$H/.claude.json")" == "https://lab.exemple.test/mcp" && "$(jq -r '.mcpServers | keys | join(",")' "$H/.claude.json")" == "lab,perso" ]] \
  && ok "Claude Code : déclaration mise à jour vers la nouvelle LAB_MCP_URL, sans doublon" || ko "Claude Code : URL non mise à jour"
[[ "$(grep -c '^name = "lab"$' "$H/.vibe/config.toml")" == 1 ]] && grep -q '^url = "https://lab.exemple.test/mcp"$' "$H/.vibe/config.toml" \
  && ok "Vibe : déclaration mise à jour vers la nouvelle LAB_MCP_URL, sans doublon" || ko "Vibe : URL non mise à jour"
[[ "$(sommes)" == "$AVANT" ]] && ok "identifiants factices et réglages d'éditeur toujours inchangés (sha256)" || ko "un fichier protégé a changé"
T="$(grep -rlF -- "$JETON_MCP" "$H" 2>/dev/null)"; [[ -z "$T" ]] && ok "le jeton n'est toujours dans aucun fichier de la maison" || ko "jeton écrit dans : $T"

docker rm -f "$P-a" >/dev/null 2>&1
fi   # fin des sections 1 à 9 (sautées avec --conversation)

# ═════════════════════════════════════════════════════════════════════════════
titre "10. Service de conversation : conversation complète avec le faux agent ACP"
# Espace « carol » : les deux assistants sont remplacés par tests/faux_agent_acp.js (aucun
# identifiant, aucun appel à un fournisseur). Espace « dan » : le service de conversation ne
# peut pas démarrer (port invalide) — l'éditeur doit démarrer quand même.
HC="$TMP/maison-carol"; mkdir -p "$HC" "$TMP/maison-dan" "$TMP/work/autre-app"
rm -f "$W/essai-chat.txt"
docker run -d --name "$P-c" --network "$P-net" "${ENFERME[@]}" -v "$HC:/home/coder" -v "$W:/work/demo-app" -v "$ICI/tests:/t:ro" \
  -e LAB_UID=carol -e LAB_APP=demo-app -e LAB_MCP_URL=https://lab.exemple.test/mcp -e LAB_MCP_TOKEN="$JETON_MCP" -e GH_TOKEN="$JETON_GH" \
  -e FAUX_AGENT_DIR=/tmp/faux-agent -e 'LAB_CHAT_CMD_CLAUDE=["node","/t/faux_agent_acp.js","claude"]' -e 'LAB_CHAT_CMD_VIBE=["node","/t/faux_agent_acp.js","vibe"]' "$IMAGE" >/dev/null
docker run -d --name "$P-d" --network "$P-net2" "${ENFERME[@]}" -v "$TMP/maison-dan:/home/coder" -v "$TMP/work/autre-app:/work/autre-app" \
  -e LAB_UID=dan -e LAB_APP=autre-app -e LAB_CHAT_PORT=70000 "$IMAGE" >/dev/null
if attend_sante "$P-c" 90 8090 >/dev/null && attend_sante "$P-c" 90 >/dev/null; then ok "espace carol : éditeur (8080) et service de conversation (8090) répondent"; else ko "espace carol : un des deux services ne répond pas"; docker logs "$P-c" 2>&1 | tail -8; fi

titre "10a. Indépendance des deux services"
pids() { dx "$P-c" sh -c 'echo "$(pgrep -o -f "code-server --config") $(pgrep -o -f "chat/server.js")"'; }
read -r ED1 CH1 <<<"$(pids)"
dx "$P-c" sh -c 'pkill -KILL -f "^node /opt/lab/chat/server.js"'; sleep 1
[[ "$(dx "$P-c" curl -s -o /dev/null -m 3 -w '%{http_code}' http://127.0.0.1:8080/healthz)" == 200 ]] && ok "service de conversation tué : l'éditeur continue de répondre" || ko "l'éditeur ne répond plus quand le service de conversation tombe"
if attend_sante "$P-c" 30 8090 >/dev/null; then read -r ED2 CH2 <<<"$(pids)"
  [[ "$ED2" == "$ED1" && -n "$CH2" && "$CH2" != "$CH1" ]] && ok "… et l'entrée relance le service de conversation (nouveau processus, éditeur inchangé)" || ko "relance du service de conversation inattendue ($ED1/$CH1 → $ED2/$CH2)"
else ko "le service de conversation n'est pas relancé"; fi
dx "$P-c" sh -c 'kill -KILL $(pgrep -o -f "code-server --config")'; sleep 1
[[ "$(dx "$P-c" curl -s -m 3 http://127.0.0.1:8090/healthz)" == '{"ok":true}' ]] && ok "éditeur tué : le service de conversation continue de répondre" || ko "le service de conversation ne répond plus quand l'éditeur tombe"
if attend_sante "$P-c" 60 >/dev/null; then read -r ED3 CH3 <<<"$(pids)"
  [[ "$CH3" == "$CH2" && -n "$ED3" && "$ED3" != "$ED2" ]] && ok "… et l'entrée relance l'éditeur (nouveau processus, service de conversation inchangé)" || ko "relance de l'éditeur inattendue ($ED2/$CH2 → $ED3/$CH3)"
else ko "l'éditeur n'est pas relancé"; fi
if attend_sante "$P-d" 90 >/dev/null; then
  ok "espace dan, service de conversation incapable de démarrer : l'éditeur démarre quand même"
  sleep 3; ND=$(docker logs "$P-d" 2>&1 | grep -c "le service de conversation s'est arrêté")
  AGE=$(( $(date +%s) - $(date -d "$(docker inspect "$P-d" --format '{{.State.StartedAt}}')" +%s) ))
  (( ND >= 1 && ND <= AGE / 3 + 2 )) && ok "… l'échec est écrit dans le journal et la relance s'espace ($ND tentative(s) en $AGE s : pas de boucle serrée)" || ko "relances du service de conversation : $ND en $AGE s"
else ko "espace dan : l'éditeur ne démarre pas quand le service de conversation échoue"; fi
T0=$(date +%s%N); docker stop -t 10 "$P-d" >/dev/null; T1=$(( ($(date +%s%N) - T0) / 1000000 ))
(( T1 < 8000 )) && ok "arrêt de l'espace : SIGTERM transmis aux deux services, conteneur arrêté en ${T1} ms (sans attendre le SIGKILL)" || ko "l'espace met ${T1} ms à s'arrêter"
docker rm -f "$P-d" >/dev/null 2>&1

titre "10b. Protocole : flux, outil, autorisations, arrêt, coupure, reprise, bascule — et /activity"
remise_a_zero() {   # état neuf : plus de conversation gardée, service relancé par l'entrée
  dx "$P-c" sh -c 'rm -rf /tmp/faux-agent /work/demo-app/essai-chat.txt; pkill -KILL -f "^node /opt/lab/chat/server.js"'; sleep 1
  attend_sante "$P-c" 30 8090 >/dev/null
}
remise_a_zero
RS="$(chat "$P-c" conversation)"; q() { jq -r "$1" <<<"$RS"; }
vrai() { if [[ "$(q "$2")" == true ]]; then ok "$1"; else ko "$1"; info "$(jq -c "$3" <<<"$RS")"; fi; }
if [[ -z "$RS" || "$(q 'has("fatal")')" == true ]]; then ko "le scénario de conversation n'a pas abouti"; info "$RS"
else
  vrai "I1 /activity — avant toute connexion : 0 ; page ouverte sans échange : toujours 0" '.activite_avant == 0 and .activite_apres_ouverture == 0' '{activite_avant, activite_apres_ouverture}'
  vrai "I1 /activity — cas 1, client connecté et échange : la valeur avance" '.activite_echange' '.activite_echange'
  vrai "I1 /activity — cas 2, tour en cours : activité continue (écart avec l'instant présent : $(q .activite_tour.ecart_ms) ms)" '.activite_tour.ecart_ms < 300' '.activite_tour'
  vrai "I1 /activity — cas 3, client connecté sans échange : la valeur ne bouge plus (figée depuis $(q .activite_fige.retard_ms) ms)" '.activite_fige.identique and .activite_fige.retard_ms >= 2400' '.activite_fige'
  vrai "I1 /activity — tour en cours mais plus aucun client : la valeur ne bouge plus (un tour ne tient pas l'espace ouvert sans personne)" '.activite_sans_client' '.activite_sans_client'
  vrai "conversation ouverte en mode strict, « tout accepter » inactif" '.mode_initial.current == "default" and .auto_initial == false' '{mode_initial, auto_initial}'
  vrai "texte au fil de l'eau ($(q .flux.morceaux) morceaux), réflexion, fin de tour" '.flux.morceaux >= 5 and (.flux.texte | endswith("Voilà.")) and .flux.fin == "end_turn" and .flux.reflexion' '.flux'
  vrai "appel d'outil : titre, genre, états successifs pending → in_progress → completed, contenu" '.outil.genre == "read" and .outil.etat == "completed" and (.outil.etats_vus | index("in_progress") != null) and (.outil.contenu | contains("Feuille de route"))' '.outil'
  vrai "demande d'autorisation présentée (options de l'agent, modification lisible) et en attente tant qu'on ne répond pas" '.perm_demandee and .perm_attend and .perm.outil_diff == "diff" and .perm.options == ["allow_once","allow_always","reject_once"]' '{perm, perm_attend}'
  vrai "autorisation accordée : l'agent écrit, l'outil passe à « completed »" '.perm_accordee.etat == "selected" and .perm_accordee.choix == "oui" and .perm_accordee.outil == "completed"' '.perm_accordee'
  vrai "autorisation refusée : l'agent n'écrit pas, l'outil passe à « failed »" '.perm_refusee.choix == "non" and .perm_refusee.outil == "failed" and (.perm_refusee.texte | contains("refusée"))' '.perm_refusee'
  vrai "arrêt du tour : session/cancel, fin « cancelled », texte interrompu" '.arret.fin == "cancelled" and .arret.texte_coupe' '.arret'
  vrai "coupure du WebSocket pendant un tour : le tour continue, la reconnexion rejoue l'état ($(q .reconnexion.rejoue) éléments) et le tour se termine" '.reconnexion.meme and .reconnexion.en_cours and .reconnexion.texte_garde and .reconnexion.complet and .reconnexion.fin == "end_turn"' '.reconnexion'
  vrai "coupure pendant une demande d'autorisation : elle reste en attente, la réponse donnée après reconnexion est transmise" '.perm_survit.etat == "pending" and .perm_survit.en_cours and .perm_survit.apres.choix == "toujours" and .perm_survit.apres.outil == "completed"' '.perm_survit'
  vrai "plan : un seul plan, mis à jour sur place" '.plan.plans == 1 and .plan.etats == ["completed","completed","completed"]' '.plan'
  vrai "« tout accepter » : activé pour la conversation, l'accord est donné pour cette fois seulement et marqué automatique ; désactivé, on redemande" '.auto.etat == "selected" and .auto.auto and .auto.choix == "oui" and .auto.redemande' '.auto'
  vrai "arrêt pendant une demande : la demande reçoit « cancelled » (règle ACP)" '.auto.arret_annule_demande.perm == "cancelled" and .auto.arret_annule_demande.fin == "cancelled"' '.auto.arret_annule_demande'
  vrai "nouvelle conversation : vide, mode strict, « tout accepter » NON repris" '.nouvelle.vide and .nouvelle.auto == false and .nouvelle.mode == "default"' '.nouvelle'
  vrai "conversations précédentes du projet listées, la plus récente d'abord" '(.liste | length) == 2 and .liste[0].titre == "seconde conversation" and .liste[1].premiere' '.liste'
  vrai "reprise d'une conversation : historique rejoué par l'agent ($(q '.reprise.messages_utilisateur | length') messages, $(q .reprise.outils) outils), mode strict réimposé, « tout accepter » non repris, suite possible" '(.reprise.messages_utilisateur | length) == 10 and .reprise.outils == 6 and .reprise.auto == false and .reprise.mode == "default" and .reprise.suite == "end_turn" and .reprise.inconnue_donne_neuve' '.reprise'
  vrai "bascule vers l'autre assistant : conversation Vibe en mode « ask »" '.bascule.agent == "vibe" and .bascule.mode == "ask" and (.bascule.texte | contains("faux agent **vibe**"))' '.bascule'
fi
JA="$(dx "$P-c" cat /tmp/faux-agent/journal.log 2>/dev/null)"
grep -qx "claude env cwd=/work/demo-app LAB_APP=demo-app LAB_UID=carol jeton_mcp=present claude_exe=/usr/local/bin/claude" <<<"$JA" \
  && ok "vu par l'agent : lancé dans /work/demo-app avec l'environnement de l'espace (jeton présent) et CLAUDE_CODE_EXECUTABLE = le claude de l'image" || { ko "environnement de l'agent inattendu"; info "$(grep ' env ' <<<"$JA")"; }
grep -q "^claude new cwd=/work/demo-app mcpServers=0" <<<"$JA" && ok "vu par l'agent : session/new avec cwd = /work/demo-app, sans serveur MCP ajouté (ceux de la maison s'appliquent)" || ko "session/new inattendu"
if [[ "$(grep -c '^claude set_mode default$' <<<"$JA")" -ge 3 && "$(grep -c '^vibe set_mode ask$' <<<"$JA")" -ge 1 ]] && ! grep -q "SANS demande" <<<"$JA"; then
  ok "vu par l'agent : mode strict imposé à chaque ouverture et reprise (le faux agent démarre en mode permissif, comme Vibe) ; aucune modification sans demande"
else ko "mode strict non imposé"; info "$(grep -E 'set_mode|SANS' <<<"$JA" | sort | uniq -c | tr '\n' ' ')"; fi
[[ "$(grep -c 'ajout du faux agent (claude)' "$W/essai-chat.txt" 2>/dev/null)" == 2 ]] && ok "le fichier du projet n'a été modifié que pour les deux accords donnés (essai-chat.txt, 2 ajouts ; refus et arrêt n'écrivent rien)" || ko "essai-chat.txt inattendu : $(tr '\n' '|' < "$W/essai-chat.txt" 2>/dev/null)"
JS="$(docker logs "$P-c" 2>&1 | grep -F '[lab-chat]')"
FUITE=0; for motif in morceau Bonjour "faux agent" essai-chat "git status" "seconde conversation" "$JETON_MCP" "$JETON_GH"; do contient "$JS" "$motif" && { FUITE=1; ko "le journal du service contient « $motif »"; }; done
[[ $FUITE -eq 0 ]] && ok "journal du service : cycle de vie seulement ($(wc -l <<<"$JS") lignes), aucun contenu de conversation, aucun jeton"
T="$(grep -rlF -e "$JETON_MCP" -e "$JETON_GH" "$HC" "$W" 2>/dev/null)"; [[ -z "$T" ]] && ok "les jetons de l'espace ne sont écrits dans aucun fichier de la maison ni du projet" || ko "jeton écrit dans : $T"
mesure "service de conversation + faux agents, après le scénario : $(mem_mo "$P-c") Mo pour le conteneur (service : $(dx "$P-c" ps -eo rss,args | awk '/chat\/server.js/{s+=$1} END{printf "%d", s/1024}') Mo de RSS)"

if [[ $NAVIGATEUR -eq 1 ]] && docker image inspect "$NAV_IMAGE" >/dev/null 2>&1; then
  titre "10c. Navigateur réel (Chromium) : la conversation jouée à l'écran, à 390 px et 1280 px"
  docker run -d --name "$P-proxy" --network "$P-net" --memory 128m --cpus 0.5 -v "$TMP/Caddyfile:/Caddyfile:ro" \
    --entrypoint caddy "$PROXY_IMAGE" run --config /Caddyfile --adapter caddyfile >/dev/null
  sleep 3
  [[ -n "$CAPTURES" ]] && mkdir -p "$CAPTURES"
  for LARG in 390 1280; do
    runner_libre || { ko "le runner du lab est occupé depuis 5 min : navigateur non lancé"; continue; }
    remise_a_zero
    docker rm -f "$P-nav" >/dev/null 2>&1
    docker run -d --name "$P-nav" --network "$P-net" --memory 1500m --cpus 1 --user "$(id -u):$(id -g)" -e HOME=/tmp \
      -v "$ICI/tests:/t:ro" ${CAPTURES:+-v "$CAPTURES:/captures"} ${CAPTURES:+-e CAPTURES=/captures} \
      -e NODE_PATH=/app/node_modules -e CHAT_URL="$PX:8081/ws/carol/_chat/" -e LARGEUR="$LARG" "$NAV_IMAGE" node /t/chat_navigateur.js >/dev/null
    FAITES=0
    for _ in $(seq 1 900); do       # 4 min 30 au plus
      SORTIE_NAV="$(docker logs "$P-nav" 2>&1)"
      mapfile -t ACTIONS < <(grep '^ACTION ' <<<"$SORTIE_NAV" | cut -d' ' -f2)
      while (( FAITES < ${#ACTIONS[@]} )); do
        case "${ACTIONS[$FAITES]}" in
          coupe) docker restart -t 0 "$P-proxy" >/dev/null ;;                      # vraie coupure réseau
          sans-identifiants) dx "$P-c" touch /tmp/faux-agent/sans-identifiants ;;
          avec-identifiants) dx "$P-c" rm -f /tmp/faux-agent/sans-identifiants ;;
        esac
        FAITES=$((FAITES+1))
      done
      grep -q '^RESULTAT ' <<<"$SORTIE_NAV" && break
      docker ps -q --filter "name=^$P-nav$" | grep -q . || break
      sleep 0.3
    done
    RN="$(docker logs "$P-nav" 2>&1 | grep '^RESULTAT ' | tail -1 | cut -d' ' -f2-)"
    if [[ -z "$RN" || "$(jq -r 'has("fatal")' <<<"$RN")" == true ]]; then ko "$LARG px : le navigateur n'a rendu aucun résultat"; docker logs "$P-nav" 2>&1 | tail -5
    else
      n() { jq -r "$1" <<<"$RN"; }
      ECHECS="$(n '.etapes | to_entries[] | select(.value != "ok") | "\(.key) : \(.value)"')"
      if [[ -z "$ECHECS" ]]; then ok "$LARG px : $(n '.etapes | length') étapes jouées à l'écran — $(n '.etapes | keys_unsorted | join(", ")')"; else ko "$LARG px : étapes en échec"; info "$ECHECS"; fi
      if [[ "$(n '.debordements | length')" == 0 ]]; then ok "$LARG px : aucun défilement horizontal, à aucune étape"; else ko "$LARG px : défilement horizontal"; info "$(n '.debordements | join(" ; ")')"; fi
      if [[ "$(n '.cibles | length')" == 0 ]]; then ok "$LARG px : toutes les cibles tactiles visibles font au moins 44 px"; else ko "$LARG px : cibles tactiles trop petites"; info "$(n '.cibles | join(" ; ")')"; fi
      if [[ "$(n '.externes | length')" == 0 && "$(n '.horsPrefixe | length')" == 0 ]]; then ok "$LARG px : aucune requête vers un autre hôte ni hors de /ws/carol/"; else ko "$LARG px : requêtes inattendues"; info "$(n '(.externes + .horsPrefixe) | join(" ")')"; fi
      # Pendant le redémarrage du proxy (la coupure provoquée), les tentatives de reconnexion échouent : attendu.
      PARASITES="$(n '(.erreurs + .console)[]' | grep -vE 'WebSocket connection to .* failed|ERR_CONNECTION_REFUSED|ERR_NAME_NOT_RESOLVED|^50[234] ' || true)"
      if [[ -z "$PARASITES" ]]; then ok "$LARG px : aucune erreur de page ni de politique de contenu (hors tentatives de reconnexion pendant la coupure provoquée)"; else ko "$LARG px : erreurs dans la page"; info "$PARASITES"; fi
      [[ "$(n .sockets)" -ge 3 ]] && ok "$LARG px : $(n .sockets) WebSockets ouverts au fil des coupures et rechargements, tous sous le préfixe" || ko "$LARG px : reconnexions non observées"
      [[ "$(n .dernierAgent)" == "?agent=claude" ]] && ok "$LARG px : sans ?agent=, la page rouvre le dernier assistant utilisé" || ko "$LARG px : dernier assistant non repris ($(n .dernierAgent))"
    fi
    docker rm -f "$P-nav" >/dev/null 2>&1
  done
  [[ -n "$CAPTURES" ]] && info "captures : $CAPTURES ($(ls "$CAPTURES" 2>/dev/null | wc -l) fichiers)"
  docker rm -f "$P-proxy" >/dev/null 2>&1
else
  titre "10c. Navigateur réel"
  info "non lancé (--sans-navigateur, ou image $NAV_IMAGE absente) : la conversation n'est prouvée qu'au niveau du protocole"
fi

# ═════════════════════════════════════════════════════════════════════════════
printf '\n\033[1m── Bilan\033[0m\n'
printf '  %d vérifications vertes, %d rouges\n' "$OK" "$KO"
printf '  Mesures :\n'; for m in "${MESURES[@]}"; do printf '    - %s\n' "$m"; done
[[ $KO -eq 0 ]]
