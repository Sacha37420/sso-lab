#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# scripts/tests/modules/run.sh — modules du lab : description, état, plan, sélection,
# réglages, scripts d'installation, portes de validate-app.sh, choix d'install.sh.
# Chantier « modules », contrat v1 (I1, I2, I3, I5).
#
#   bash scripts/tests/modules/run.sh
#
# NE TOUCHE À RIEN DU LAB : un faux lab est construit dans un dossier temporaire
# (copie de scripts/, unités factices), l'état des conteneurs vient d'un fichier
# (LAB_MODULES_PS), aucun conteneur n'est lancé, aucun réseau n'est utilisé.
# Seul `install.sh --check --until 2` interroge `docker info` (lecture).
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEV="$(cd "$HERE/../../.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok()   { PASS=$((PASS + 1)); echo "  ✔ $*"; }
ko()   { FAIL=$((FAIL + 1)); echo "  ✘ $*"; }
is()   { [[ "$2" == "$3" ]] && ok "$1" || ko "$1 — attendu « $3 », obtenu « $2 »"; }
has()  { [[ "$2" == *"$3"* ]] && ok "$1" || ko "$1 — « $3 » absent de : ${2:0:400}"; }
hasnt(){ [[ "$2" != *"$3"* ]] && ok "$1" || ko "$1 — « $3 » présent"; }

# ── Faux lab ──────────────────────────────────────────────────────────────────
cp -r "$DEV/scripts" "$T/scripts"
rm -rf "$T/scripts/tests"
mkdir -p "$T/deploiement" "$T/modules" "$T/.lab-state"
printf 'LAB_SUPERUSER=sacha\nDOMAIN=lab.example.org\n' > "$T/.env"
printf 'm-dev:alice\n' > "$T/.owners"
printf 'atelier:5:4000\nc:1:1500\n' > "$T/scripts/app-priorities.conf"
unit() {  # unit <chemin relatif> [description JSON] — dossier déployable minimal
  mkdir -p "$T/$1"; printf 'services: {}\n' > "$T/$1/docker-compose.yml"
  printf 'SECRET_KEY=x\n' > "$T/$1/.env"
  [[ -n "${2:-}" ]] && printf '%s\n' "$2" > "$T/$1/lab-module.json"
  return 0
}
desc() {  # desc <nom> <requires.modules JSON> [champs en plus]
  printf '{"schema":1,"name":"%s","label":"%s","requires":{"modules":%s}%s}' "$1" "$1" "$2" "${3:+,$3}"
}
for u in sso-lab infra runner storage oauth-hub lab-admin lab-mcp; do unit "$u"; done
unit deploiement/a "$(desc a '[{"name":"b"}]')"
unit deploiement/b "$(desc b '[{"name":"c"}]')"
unit deploiement/c
desc c '[{"name":"storage","interface":"1"}]' > "$T/modules/c.json"                 # catalogue central
desc storage '[]' '"category":"cadriciel","provides":{"interface":"1"}' > "$T/modules/storage.json"
unit deploiement/d                                                                   # aucune description
printf -- '--public --port 1 --caddy-path d --require-group famille,amis\n' > "$T/deploiement/d/.keycloak-client-opts"
unit deploiement/e "$(desc e '[{"name":"f"}]')"
unit deploiement/f "$(desc f '[{"name":"e"}]')"
unit deploiement/g "$(desc g '[{"name":"zz"}]')"
unit deploiement/h "$(desc h '[]')"; touch "$T/deploiement/h/.no-autodeploy"
unit deploiement/i '{"schema":1,"name":"i","label":"i","settings":[{"key":"DB_PASSWORD","question":"q","value":"x"}]}'
unit deploiement/j "$(desc j '[]' '"requires":{"system":[{"command":"commande-qui-n-existe-pas"}]}')"
# (la clé requires en double est volontaire : JSON garde la dernière — j n'a donc aucune dépendance de module)
unit deploiement/k "$(desc k '[]' '"settings":[{"key":"API_KEY","question":"Clé ?","required":true,"secret":true},{"key":"OPT","question":"Option ?"}]')"
unit deploiement/l "$(desc l '[{"name":"storage","interface":"2"}]')"
unit deploiement/m "$(desc m '[]' '"install":{"script":"install.sh","windows":"install.bat","timeout_s":10}')"
unit deploiement/m-dev "$(desc m-dev '[]' '"install":{"script":"install.sh","windows":"install.bat"}')"
unit deploiement/n "$(desc n '[]')"
desc n '[{"name":"c"}]' > "$T/modules/n.json"     # le module porte la sienne : elle gagne, sans fusion
unit deploiement/atelier "$(desc atelier '[]')"
mkdir -p "$T/deploiement/vide"                     # sous-module non extrait
printf '[submodule "vide"]\n\tpath = deploiement/vide\n\turl = https://example.invalid/vide.git\n' > "$T/.gitmodules"
desc absent '[]' > "$T/modules/absent.json"        # catalogue sans dossier

cat > "$T/deploiement/m/install.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "--check" ]]; then [[ -f fait ]] && { echo "rien ne manque"; exit 0; }; echo "manque : fait"; exit 1; fi
[[ -z "${SECRET_DE_L_APPELANT:-}" ]] || { echo "FUITE"; exit 9; }
echo "module=$LAB_MODULE dir=$(basename "$LAB_MODULE_DIR") pwd=$(basename "$PWD")"
touch fait
EOF
printf '@echo off\r\nrem --check\r\n' > "$T/deploiement/m/install.bat"
cp "$T/deploiement/m/install.sh" "$T/deploiement/m-dev/install.sh"; cp "$T/deploiement/m/install.bat" "$T/deploiement/m-dev/install.bat"
printf '#!/usr/bin/env bash\ntouch joue\n' > "$T/deploiement/n/install.sh"   # présent mais NON déclaré

# États des conteneurs : socle et cadriciel en service, c en service, atelier arrêté.
PS="$T/ps"
{ for u in sso-lab infra runner storage oauth-hub lab-admin lab-mcp c; do printf '%s\trunning\n' "$u"; done
  printf 'atelier\texited\n'; } > "$PS"
export LAB_MODULES_PS="$PS" LAB_STATE_DIR="$T/.lab-state" LAB_SUPERUSER=sacha
LM="bash $T/scripts/lab-modules.sh"
st()   { $LM list --json | jq -r --arg n "$1" '.modules[] | select(.name == $n) | .'"$2"; }
plan() { $LM plan --json "$@"; }
steps(){ jq -r '[.steps[] | .module + ":" + .action] | join(" ")' <<< "$1"; }
cause(){ jq -r --arg m "$2" '.blocked[] | select(.module == $m) | .cause' <<< "$1"; }

echo "════ I1 — descriptions"
is "module sans description : déduite"            "$(st d source)" "deduced"
is "déduite : groupes de .keycloak-client-opts"   "$(st d 'groups | join(",")')" "famille,amis"
is "déduite : catégorie application"              "$(st d category)" "application"
is "catalogue central de repli"                   "$(st c source)" "catalogue"
is "le module prime sur le catalogue"             "$(st n source)" "module"
is "… sans fusion (dépendances du module seules)" "$(st n 'requires.modules | length')" "0"
is "description invalide : état invalid"          "$(st i state)" "invalid"
has "… clé gérée refusée"                         "$(st i 'errors | join(" ; ")')" "DB_PASSWORD est une clé gérée"
has "… valeur refusée dans une description"       "$(st i 'errors | join(" ; ")')" "« value » interdite"
is "socle obligatoire"                            "$(st infra required)" "true"
is "cadriciel obligatoire"                        "$(st lab-mcp required)" "true"
is "lab-mcp exige le domaine"                     "$(st lab-mcp requires.domain)" "true"
is "priorité lue dans app-priorities.conf"        "$(st atelier priority)" "5"
is "RAM de build de app-priorities.conf"          "$(st atelier resources.build_ram_mb)" "4000"
is "état installé"                                "$(st c state)" "installed"
is "état arrêté"                                  "$(st atelier state)" "stopped"
is "état non installé"                            "$(st a state)" "not_installed"
is "sous-module vide : inaccessible"              "$(st vide state)" "inaccessible"
is "catalogue sans dossier : absent"              "$(st absent state)" "absent"
hasnt "aucune valeur de .env sur la sortie"       "$($LM list --json)" "SECRET_KEY=x"
is "réglage non posé : set=false"                 "$(st k 'settings[0].set')" "false"

echo "════ I2 — plan"
P="$(plan a)"
is "ordre topologique (dépendances d'abord)"      "$(steps "$P")" "storage:keep c:keep b:install a:install"
is "plan réalisable"                               "$(jq -r .ok <<< "$P")" "true"
P="$(plan --reinstall a)"
is "--reinstall : le demandé seul"                 "$(steps "$P")" "storage:keep c:keep b:install a:install"
P="$(plan --reinstall c)"
is "--reinstall d'un module installé"              "$(steps "$P")" "storage:keep c:reinstall"
P="$(plan --reinstall --with-deps n)"
is "--with-deps : dépendances réinstallées"        "$(steps "$P")" "n:install"
P="$(plan e)"; rc=$?
is "cycle : refusé (code 1)"                       "$rc" "1"
is "… cause cycle"                                 "$(cause "$P" e)" "cycle"
has "… chemin du cycle"                            "$(jq -r '.blocked[0].reason' <<< "$P")" "→"
P="$(plan g)"
is "dépendance inconnue"                           "$(cause "$P" zz)" "unknown"
is "… bloque le dépendant"                         "$(cause "$P" g)" "dependency"
P="$(plan g,a)"
is "un module bloqué n'arrête pas les autres"      "$(steps "$P")" "storage:keep c:keep b:install a:install"
is "… mais le plan n'est pas « ok »"               "$(jq -r .ok <<< "$P")" "false"
P="$(plan h)";     is ".no-autodeploy"            "$(cause "$P" h)" "no_autodeploy"
P="$(plan i)";     is "description invalide"      "$(cause "$P" i)" "invalid"
P="$(plan j)";     is "prérequis système absent"  "$(cause "$P" j)" "system"
P="$(plan vide)";  is "inaccessible"              "$(cause "$P" vide)" "inaccessible"
P="$(plan absent)";is "absent"                    "$(cause "$P" absent)" "absent"
P="$(plan l)";     is "interface incompatible"    "$(cause "$P" l)" "interface"
P="$(plan infra)"; is "le socle ne se planifie pas" "$(cause "$P" infra)" "socle"
P="$(plan --reinstall --for-engine lab-mcp)"
is "le moteur ne se réinstalle pas lui-même"       "$(cause "$P" lab-mcp)" "engine_self"
P="$(plan --reinstall --with-deps --for-engine c)"
hasnt "… ni comme dépendance (lab-mcp hors plan)"  "$(steps "$P")" "lab-mcp"
P="$(plan k)"
is "réglages manquants : requis d'abord"           "$(jq -r '[.settings_missing[] | .key + ":" + (.required|tostring)] | join(" ")' <<< "$P")" "API_KEY:true OPT:false"
P="$(plan atelier,c,d)"
is "départage par priorité puis nom"               "$(steps "$P")" "atelier:install d:install storage:keep c:keep"
sed -i 's/^DOMAIN=.*/DOMAIN=CHANGE_ME/' "$T/.env"
P="$(plan --reinstall lab-mcp)"; is "sans domaine : lab-mcp bloqué" "$(cause "$P" lab-mcp)" "domain"
sed -i 's/^DOMAIN=.*/DOMAIN=lab.example.org/' "$T/.env"

echo "════ I5 — sélection mémorisée"
is "aucune sélection au départ"                    "$($LM selection --json | jq -r .memorized)" "false"
$LM selection add a,d --by sacha > /dev/null
is "sélection ajoutée"                             "$($LM selection --json | jq -r '.modules | join(",")')" "a,d"
$LM selection add c --by alice > /dev/null
is "ajout cumulatif"                               "$($LM selection --json | jq -r '.modules | join(",")')" "a,c,d"
is "… par un uid"                                  "$($LM selection --json | jq -r .by)" "alice"
is "fichier 0600"                                  "$(stat -c %a "$T/.lab-state/modules/selection.json")" "600"
$LM selection add a --by 'x@y.fr' > /dev/null 2>&1; is "un email n'est pas un uid" "$?" "1"
is "selected dans list"                            "$(st d selected)" "true"

echo "════ settings / prepare"
out="$(printf 'API_KEY=s3cr3t\nOPT=o\nAUTRE=z\n' | $LM settings k)"; rc=$?
has "clé déclarée non réglée : écrite"             "$out" "API_KEY: écrit"
has "clé non déclarée : refusée"                   "$out" "AUTRE: non déclaré"
hasnt "aucune valeur sur la sortie"                "$out" "s3cr3t"
is "code 1 si une clé est refusée"                 "$rc" "1"
is "valeur écrite dans .env"                       "$(grep '^API_KEY=' "$T/deploiement/k/.env")" "API_KEY=s3cr3t"
out="$(printf 'API_KEY=autre\n' | $LM settings k)"
has "réglage posé : jamais réécrit"                "$out" "API_KEY: déjà réglé"
is "… valeur inchangée"                            "$(grep '^API_KEY=' "$T/deploiement/k/.env")" "API_KEY=s3cr3t"
mkdir -p "$T/deploiement/p"; printf 'services: {}\n' > "$T/deploiement/p/docker-compose.yml"
printf 'DB_NAME=devdb\nDB_USER=devuser\nDB_HOST=postgres\nAPI_KEY=CHANGE_ME\nAUTRE_SECRET=CHANGE_ME\n' > "$T/deploiement/p/.env.example"
desc p '[]' '"settings":[{"key":"API_KEY","question":"Clé ?"}]' > "$T/deploiement/p/lab-module.json"
$LM prepare p > /dev/null
is "prepare : .env créé"                           "$([[ -f "$T/deploiement/p/.env" ]] && echo oui)" "oui"
is "… base du propriétaire"                        "$(grep '^DB_NAME=' "$T/deploiement/p/.env")" "DB_NAME=dev_sacha"
is "… réglage déclaré laissé à CHANGE_ME"          "$(grep '^API_KEY=' "$T/deploiement/p/.env")" "API_KEY=CHANGE_ME"
hasnt "… autre secret tiré au hasard"              "$(grep '^AUTRE_SECRET=' "$T/deploiement/p/.env")" "CHANGE_ME"
is "… 0600"                                        "$(stat -c %a "$T/deploiement/p/.env")" "600"
echo "AUTRE=1" >> "$T/deploiement/p/.env"; $LM prepare p > /dev/null
has ".env existant jamais réécrit"                 "$(cat "$T/deploiement/p/.env")" "AUTRE=1"

echo "════ I3 — scripts d'installation"
out="$(SECRET_DE_L_APPELANT=fuite bash "$T/scripts/module-hook.sh" m 2>&1)"; rc=$?
is "script déclaré : joué"                         "$rc" "0"
has "… dans son dossier, environnement du lab"     "$out" "module=m dir=m pwd=m"
hasnt "… sans l'environnement de l'appelant"       "$out" "FUITE"
bash "$T/scripts/module-hook.sh" m --check > /dev/null 2>&1; is "--check après installation" "$?" "0"
rm "$T/deploiement/m/fait"; bash "$T/scripts/module-hook.sh" m --check > /dev/null 2>&1; is "--check : quelque chose manque" "$?" "1"
is "--check ne modifie rien"                       "$([[ -f "$T/deploiement/m/fait" ]] && echo oui || echo non)" "non"
out="$(bash "$T/scripts/module-hook.sh" m-dev 2>&1)"; rc=$?
is "app d'un développeur : non joué, sans échec"   "$rc" "0"
has "… et le journal le dit"                       "$out" "NON joué"
is "… rien n'a tourné"                             "$([[ -f "$T/deploiement/m-dev/fait" ]] && echo oui || echo non)" "non"
bash "$T/scripts/module-hook.sh" n > /dev/null 2>&1
is "install.sh non déclaré : jamais joué"          "$([[ -f "$T/deploiement/n/joue" ]] && echo oui || echo non)" "non"
printf '#!/usr/bin/env bash\nsleep 30\n' > "$T/deploiement/m/install.sh"
out="$(bash "$T/scripts/module-hook.sh" m 2>&1)"; rc=$?
is "délai dépassé : échec"                         "$rc" "1"
has "… dit comme tel"                              "$out" "arrêté après 10 s"
printf '#!/usr/bin/env bash\nexit 3\n' > "$T/deploiement/m/install.sh"
out="$(bash "$T/scripts/module-hook.sh" m 2>&1)"; rc=$?
is "script en échec : code 1"                      "$rc" "1"
has "… ligne ERROR"                                "$out" "ERROR"
bash "$T/scripts/module-hook.sh" i > /dev/null 2>&1; is "description invalide : refus" "$?" "1"
printf '#!/usr/bin/env bash\n[[ "${1:-}" == --check ]] && exit 0\ntouch joue-if-new\n' > "$T/deploiement/m/install.sh"
_ps_m="$T/ps-m"
printf 'm\texited\n' > "$_ps_m"
out="$(LAB_MODULES_PS="$_ps_m" bash "$T/scripts/module-hook.sh" m --if-new 2>&1)"; rc=$?
is "--if-new, module déjà sur le serveur : non rejoué" "$rc" "0"
has "… dit « mise à jour »"                        "$out" "mise à jour"
is "… rien n'a tourné"                             "$([[ -f "$T/deploiement/m/joue-if-new" ]] && echo oui || echo non)" "non"
printf 'm\trunning\n' > "$_ps_m"
LAB_MODULES_PS="$_ps_m" bash "$T/scripts/module-hook.sh" m --if-new > /dev/null 2>&1
is "--if-new, module en service : non rejoué"      "$([[ -f "$T/deploiement/m/joue-if-new" ]] && echo oui || echo non)" "non"
: > "$_ps_m"
LAB_MODULES_PS="$_ps_m" bash "$T/scripts/module-hook.sh" m --if-new > /dev/null 2>&1; rc=$?
is "--if-new, module absent du serveur : joué"     "$rc/$([[ -f "$T/deploiement/m/joue-if-new" ]] && echo oui || echo non)" "0/oui"
rm -f "$T/deploiement/m/joue-if-new"
out="$(LAB_MODULES_PS="$_ps_m" bash "$T/scripts/module-hook.sh" m-dev --if-new 2>&1)"
has "--if-new, app d'un développeur : jamais"      "$out" "NON joué"

echo "════ validate-app.sh — portes du module"
printf '## Lot 1 — x   ·   statut : à faire\n' > "$T/deploiement/m/FEUILLE_DE_ROUTE.md"
printf '#!/usr/bin/env bash\n[[ "${1:-}" == --check ]] && exit 0\nexit 0\n' > "$T/deploiement/m/install.sh"
out="$(bash "$T/scripts/validate-app.sh" m --quality-only 2>&1)"; is "description et scripts conformes" "$?" "0"
rm "$T/deploiement/m/install.bat"
out="$(bash "$T/scripts/validate-app.sh" m --quality-only 2>&1)"; rc=$?
is "install.bat déclaré absent : refus"            "$rc" "1"
has "… code [module-install]"                      "$out" "[module-install]"
printf '## Lot 1 — x   ·   statut : à faire\n' > "$T/deploiement/i/FEUILLE_DE_ROUTE.md"
out="$(bash "$T/scripts/validate-app.sh" i --quality-only 2>&1)"; rc=$?
is "description invalide : refus"                  "$rc" "1"
has "… code [module]"                              "$out" "[module]"
printf '## Lot 1 — x   ·   statut : à faire\n' > "$T/deploiement/d/FEUILLE_DE_ROUTE.md"
bash "$T/scripts/validate-app.sh" d --quality-only > /dev/null 2>&1; is "sans description : accepté" "$?" "0"

echo "════ gabarit (_templates/module, rendu comme par new-app.sh)"
mkdir -p "$T/deploiement/neuve"; printf 'services: {}\n' > "$T/deploiement/neuve/docker-compose.yml"
printf '## Lot 1 — x   ·   statut : à faire\n' > "$T/deploiement/neuve/FEUILLE_DE_ROUTE.md"
_gj="$(printf '%s' "famille,amis" | python3 -c 'import json,sys; print(json.dumps([g for g in sys.stdin.read().split(",") if g]))')"
sed -e "s|__APP_NAME__|neuve|g" -e "s|__APP_TITLE__|Neuve|g" -e "s|__GROUPS_JSON__|${_gj}|g" "$DEV/_templates/module/lab-module.json" > "$T/deploiement/neuve/lab-module.json"
for f in install.sh install.bat; do sed -e "s|__APP_NAME__|neuve|g" "$DEV/_templates/module/$f" > "$T/deploiement/neuve/$f"; done
is "description du gabarit valide"                 "$(st neuve valid)" "true"
is "… groupes repris"                              "$(st neuve 'groups | join(",")')" "famille,amis"
bash "$T/scripts/validate-app.sh" neuve --quality-only > /dev/null 2>&1; is "gabarit : portes de qualité vertes" "$?" "0"
out="$(bash "$T/scripts/module-hook.sh" neuve 2>&1)"; rc=$?
is "squelette install.sh : joué sans effet"        "$rc" "0"
has "… « rien à faire »"                           "$out" "rien à faire"
bash "$T/scripts/module-hook.sh" neuve --check > /dev/null 2>&1; is "squelette : --check vert" "$?" "0"

echo "════ install.sh --check --until 2 (choix et plan, avant tout conteneur)"
rm -f "$T/.lab-state/modules/selection.json"
I="bash $T/scripts/install.sh --check --until 2"
clean() { sed 's/\x1b\[[0-9;]*m//g'; }
out="$($I --modules a 2>&1 | clean)"
has "--modules : dépendances dans l'ordre"         "$out" "seront installés après le cadriciel, dans cet ordre : b, a"
out="$($I --yes 2>&1 | clean)"
has "--yes sans sélection : tous (comme avant)"    "$out" "tous les modules disponibles (comportement d'avant)"
has "… le défaut couvre les non installés"         "$out" "a, atelier, b, c, d"
has "… modules bloqués signalés (cycle)"           "$out" "dépendances circulaires"
has "… .no-autodeploy : noté"                      "$out" "h ignoré (.no-autodeploy)"
out="$($I --all-modules 2>&1 | clean)"
has "--all-modules"                                "$out" "--all-modules : tous les modules disponibles"
$LM selection add d --by sacha > /dev/null
out="$($I --yes 2>&1 | clean)"
has "sélection mémorisée : utilisée"               "$out" "sélection mémorisée"
has "… elle seule"                                 "$out" "seront installés après le cadriciel, dans cet ordre : d"
out="$($I --no-apps 2>&1 | clean)"
has "--no-apps : aucun module"                     "$out" "--no-apps : aucun module facultatif"
bash "$T/scripts/install.sh" --check --no-apps --modules a > /dev/null 2>&1; is "--no-apps et --modules s'excluent" "$?" "2"
unit deploiement/q "$(desc q '[]' '"settings":[{"key":"JETON","question":"Jeton ?","required":true}]')"
out="$($I --modules q 2>&1 | clean)"
has "réglage requis non fourni : signalé"          "$out" "réglage requis JETON non fourni"
is "--check n'a rien mémorisé de plus"             "$($LM selection --json | jq -r '.modules | join(",")')" "d"

echo "════ catalogue réel du lab (modules/*.json)"
real="$(LAB_MODULES_PS=/dev/null python3 -B "$DEV/scripts/lib/modules.py" "$DEV" list)"
is "toutes les descriptions du catalogue sont valides" "$(jq -r '[.modules[] | select(.valid | not) | .name] | join(",")' <<< "$real")" ""
is "13 apps de deploiement/ + app-builder et lab-media : facultatives" "$(jq -r '[.modules[] | select((.required|not) and .category != "socle")] | length' <<< "$real")" "15"
is "aucun cycle ni dépendance inconnue dans le catalogue" \
   "$(LAB_MODULES_PS=/dev/null python3 -B "$DEV/scripts/lib/modules.py" "$DEV" plan "$(jq -r '[.modules[] | select(.category != "socle") | .name] | join(",")' <<< "$real")" | jq -r '[.blocked[] | select(.cause != "domain") | .module] | join(",")')" ""

echo ""
echo "Résultat : $PASS réussi(s), $FAIL échoué(s)"
[[ $FAIL -eq 0 ]]
