#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# automatisation/tests/run.sh — essais du moteur de nuit (contrat nuit-auto v1, secteur moteur).
#
#   bash automatisation/tests/run.sh            tous les essais (≈ 10 min, un seul à la fois)
#   bash automatisation/tests/run.sh unitaires  seulement les essais sans conteneur
#   AUTO_ESSAIS_GARDER=1 …                      garde le dossier d'essai (pour lire les journaux)
#
# Ce qui est faux : Claude (image auto-essai-claude = lab-workspace + tests/faux-claude), GitHub
# (tests/faux-github.py sur 127.0.0.1), les dépôts (dépôts nus locaux, file://), le lab (un faux
# lab dont scripts/ est un lien vers le vrai), l'email (AUTO_EMAIL_DIR), la crontab
# (AUTO_CRONTAB_FILE). Ce qui est vrai : Docker, le pare-feu des ponts (préfixe d'essai « lwtq »,
# posé puis retiré), validate-app.sh, lab-lock.sh (verrou du faux lab), PostgreSQL jetable.
# Rien n'appelle Claude, GitHub ni le SMTP réels ; rien n'est poussé ailleurs que dans $T.
# Tout est nettoyé en sortie : conteneurs, réseaux, images d'essai, règles, dossiers.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
TESTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO="$(cd "$TESTS/.." && pwd)"
REAL="$(cd "$AUTO/.." && pwd)"
MODE="${1:-tout}"

exec 7> "${TMPDIR:-/tmp}/lab-auto-essais.lock"
flock -w 1800 7 || { echo "un autre essai du moteur tourne" >&2; exit 75; }

T="$(mktemp -d "${TMPDIR:-/tmp}/auto-essais.XXXXXX")"
PASS=0; FAIL=0; FAILS=()
ok() { PASS=$((PASS + 1)); echo "  ✔ $*"; }
ko() { FAIL=$((FAIL + 1)); FAILS+=("$*"); echo "  ✘ $*"; }
check() { local m="$1"; shift; if "$@" > /dev/null 2>&1; then ok "$m"; else ko "$m"; fi; }
section() { echo; echo "── $* ──"; }

GHPID=""
nettoyer() {
  [[ -n "$GHPID" ]] && kill "$GHPID" 2>/dev/null
  docker ps -aq --filter label=lab.auto=1 | xargs -r docker rm -f > /dev/null 2>&1
  docker ps -a --format '{{.Names}}' | grep -E '^auto-(securite|interface|services|verifier|test|front|fw)-' | xargs -r docker rm -f > /dev/null 2>&1
  docker network ls --format '{{.Name}}' | grep -E '^auto-(net|test|front)-' | xargs -r -n1 docker network rm > /dev/null 2>&1
  if [[ "$MODE" == tout ]]; then
    AUTO_BRIDGE_PREFIX=lwtq bash -c "source '$AUTO/lib/commun.sh'; pare_feu_cmd remove" > /dev/null 2>&1
    docker image rm -f auto-essai-claude:latest zzautoa-backend:latest zzautob-backend:latest zzautoa-backend:auto > /dev/null 2>&1
  fi
  if [[ "${AUTO_ESSAIS_GARDER:-0}" == 1 ]]; then echo "dossier gardé : $T"
  else chmod -R u+rwX "$T" 2>/dev/null; rm -rf -- "$T"; fi
}
trap nettoyer EXIT

G() { GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -c user.name=essai -c user.email=essai@example.org -c init.defaultBranch=main "$@"; }

# ── Faux lab ──────────────────────────────────────────────────────────────────
L="$T/lab"; mkdir -p "$L/deploiement" "$L/sso-lab" "$L/.git" "$T/remotes/essai" "$T/github" "$T/emails" "$T/src"
ln -s "$REAL/scripts" "$L/scripts"
cat > "$L/.env" <<EOF
LAB_SUPERUSER=sacha
LAB_STATE_DIR=$T/state
LAB_BACKUP_EMAIL=essai@ssolab.local
LAB_GIT_AUTHOR_NAME=Auteur Essai
LAB_GIT_AUTHOR_EMAIL=auteur.essai@example.org
EOF
printf 'zzautoa:9901:9902\nzzautob:9903:9904\n' > "$L/.ports"
printf '[remote "origin"]\n\turl = https://github.com/essai/racine.git\n' > "$L/.git/config"
printf '[submodule "zzautoa"]\n\tpath = deploiement/zzautoa\n\turl = https://github.com/essai/zzautoa.git\n[submodule "zzautob"]\n\tpath = deploiement/zzautob\n\turl = https://github.com/essai/zzautob.git\n' > "$L/.gitmodules"
printf 'SMTP_HOST=smtp.invalid\nSMTP_USER=u\nSMTP_PASSWORD=mot-de-passe-smtp-essai\nSMTP_FROM=lab@ssolab.local\n' > "$L/sso-lab/.env"
FERNET="$(python3 -c 'import base64,os;print(base64.urlsafe_b64encode(os.urandom(32)).decode())')"
for a in zzautoa zzautob; do
  d="$L/deploiement/$a"; mkdir -p "$d/backend"
  echo "gitdir: ../../.git/modules/$a" > "$d/.git"
  printf 'services:\n  backend:\n    build: ./backend\n    env_file: .env\n' > "$d/docker-compose.yml"
  cat > "$d/.env" <<EOF
SECRET_KEY=cle-de-service-ne-doit-pas-sortir-123
DB_HOST=postgres
DB_PASSWORD=motdepasse-de-service-xyz
KEYCLOAK_URL=http://keycloak:8080
KEYCLOAK_REQUIRED_GROUPS=famille
EMAIL_HOST_PASSWORD=mot-de-passe-email-xyz
VAULT_ENCRYPTION_KEY=$FERNET
EOF
done

# ── Dépôts « GitHub » (nus, locaux) ───────────────────────────────────────────
mk_depot() {  # mk_depot <nom> <avec frontend 0|1>
  local s="$T/src/$1"; mkdir -p "$s/backend"
  printf '# %s\n\n## Lot 1 — socle   ·   statut : livré\n\n## Commande de test\n\n`python3 check.py`\n' "$1" > "$s/FEUILLE_DE_ROUTE.md"
  printf 'services:\n  backend:\n    build: ./backend\n    env_file: .env\n' > "$s/docker-compose.yml"
  printf '.env\n' > "$s/.gitignore"
  : > "$s/backend/manage.py"; echo vert > "$s/backend/etat.txt"; echo "# vues" > "$s/backend/views.py"
  printf 'django==5.0\n' > "$s/backend/requirements.txt"
  printf 'FROM lab-workspace:latest\nWORKDIR /app\nCOPY . /app\n' > "$s/backend/Dockerfile"
  cat > "$s/backend/check.py" <<'PY'
import os, socket, sys
sk = os.environ.get("SECRET_KEY", "")
print("SECRET_KEY assaini :", "oui" if sk and sk != "cle-de-service-ne-doit-pas-sortir-123" else "NON")
print("EMAIL écarté :", "oui" if "EMAIL_HOST_PASSWORD" not in os.environ else "NON")
print("KEYCLOAK_REQUIRED_GROUPS conservé :", os.environ.get("KEYCLOAK_REQUIRED_GROUPS"))
try:
    socket.create_connection((os.environ["DB_HOST"], 5432), 5).close(); print("base : joignable")
except Exception as e:
    print("base : INJOIGNABLE", e)
try:
    socket.create_connection(("1.1.1.1", 80), 3).close(); print("réseau : OUVERT")
except Exception:
    print("réseau : fermé")
etat = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "etat.txt")).read().strip()
if etat != "vert":
    print("MARQUEUR-ROUGE etat=" + etat); sys.exit(1)
print("OK")
PY
  if [[ "$2" == 1 ]]; then
    mkdir -p "$s/frontend/e2e"; echo "test" > "$s/frontend/e2e/cloisonnement.spec.ts"
    echo '{"name":"f","version":"1.0.0"}' > "$s/frontend/package.json"; echo "initial" > "$s/frontend/src.txt"
    printf 'const s=require("fs").readFileSync("src.txt","utf8").trim(); console.log("build", s); process.exit(s ? 0 : 1);\n' > "$s/frontend/build.js"
  fi
  G -C "$s" init -q; G -C "$s" add -A; G -C "$s" commit -qm initial
  G clone -q --bare "$s" "$T/remotes/essai/$1.git"
}
mk_depot zzautoa 0; mk_depot zzautob 1
s="$T/src/racine"; mkdir -p "$s/scripts" "$s/sso-lab"
printf '#!/bin/bash\necho outil\n' > "$s/scripts/outil.sh"; echo "# lab" > "$s/CLAUDE.md"; echo x > "$s/sso-lab/a.conf"
G -C "$s" init -q; G -C "$s" add -A; G -C "$s" commit -qm initial; G clone -q --bare "$s" "$T/remotes/essai/racine.git"

# ── Réglages du moteur pour les essais ────────────────────────────────────────
export AUTO_LAB_ROOT="$L" AUTO_WORK="$T/work" AUTO_IMAGE=auto-essai-claude:latest AUTO_BRIDGE_PREFIX=lwtq \
       AUTO_DIR_PROMPTS="$TESTS/prompts" AUTO_CALENDRIER="$TESTS/calendrier.conf" AUTO_SCHEMA="$AUTO/schema-resume.json" \
       AUTO_REMOTE_BASE="file://$T/remotes/" LAB_GIT_ALLOW_FILE=1 AUTO_EMAIL_DIR="$T/emails" \
       AUTO_SMTP_ENV="$L/sso-lab/.env" AUTO_FRONT_CMD='node build.js' AUTO_CRONTAB_FILE="$T/crontab" \
       AUTO_DOCTOR_CMD="echo bilan factice 203.0.113.9 ok" AUTO_LOCK_TIMEOUT=120 AUTO_TEST_TIMEOUT=180 \
       AUTO_DISQUE_MIN_GO=1
ST="$T/state/auto"; RUNS="$ST/runs"
mkdir -p "$ST"; chmod 700 "$ST"
GHTOK="github_pat_essai$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 30)"
printf '%s\n' "$GHTOK" > "$ST/github-token"; chmod 600 "$ST/github-token"
jeton() { printf 'faux-%s-%s\n' "$1" "$(LC_ALL=C tr -dc 'a-z0-9' < /dev/urandom | head -c 16)" > "$ST/claude-token"; chmod 600 "$ST/claude-token"; }
jeton ok
AUTO_SH=(bash "$AUTO/bin/auto.sh")
OUT="$T/sortie.txt"
run() { "${AUTO_SH[@]}" "$@" > "$OUT" 2>&1; }
etatv() { python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$RUNS/$1/etat.json" "$2" 2>/dev/null; }
reste_rien() {
  local c n
  c="$(docker ps -a --format '{{.Names}}' | grep -E '^auto-' || true)"
  n="$(docker network ls --format '{{.Name}}' | grep -E '^auto-(net|test|front)-' || true)"
  [[ -z "$c" && -z "$n" ]]
}
aucun_secret() {  # aucun_secret <fichier>… : ni jeton, ni secret de service
  ! grep -qsF -e "$GHTOK" -e "$(cat "$ST/claude-token")" -e cle-de-service-ne-doit-pas-sortir -e motdepasse-de-service \
       -e mot-de-passe-smtp-essai -e "$FERNET" "$@"
}

# ══ Essais sans conteneur ═════════════════════════════════════════════════════
section "outils.py — chemins refusés (I3)"
OUTILS=(python3 -I "$AUTO/lib/outils.py")
mkdir -p "$T/arbre"
raw() { local f="$T/raw"; : > "$f"; while [[ $# -gt 0 ]]; do printf ':%s %s 0000000 0000000 M\0%s\0' "$1" "$2" "$3" >> "$f"; shift 3; done; }
refuse() { local r="$1" m="$2"; shift 2; raw "$@"; if "${OUTILS[@]}" chemins "$r" "$T/raw" "$T/arbre" > /dev/null; then ko "refus : $m"; else ok "refus : $m"; fi; }
accepte() { local r="$1" m="$2"; shift 2; raw "$@"; if "${OUTILS[@]}" chemins "$r" "$T/raw" "$T/arbre" > /dev/null; then ok "accepté : $m"; else ko "accepté : $m"; fi; }
refuse 0 ".github/workflows" 100644 100644 .github/workflows/ci.yml
refuse 0 ".env" 100644 100644 backend/.env
refuse 0 ".env.local" 000000 100644 .env.local
accepte 0 ".env.example" 100644 100644 backend/.env.example
refuse 0 ".keycloak-client-opts" 100644 100644 .keycloak-client-opts
refuse 0 "Dockerfile" 100644 100644 backend/Dockerfile
refuse 0 "Dockerfile.prod" 100644 100644 Dockerfile.prod
refuse 0 "docker-compose.override.yml" 100644 100644 docker-compose.override.yml
refuse 0 "nginx.conf" 100644 100644 frontend/nginx.conf
refuse 0 "nginx-entrypoint.sh" 100644 100644 frontend/nginx-entrypoint.sh
refuse 0 ".gitmodules" 100644 100644 .gitmodules
refuse 0 "lien symbolique" 000000 120000 backend/lien
refuse 0 "suppression d'un Dockerfile" 100644 000000 Dockerfile
refuse 1 "_racine sso-lab/**" 100644 100644 sso-lab/caddy/Caddyfile
refuse 1 "_racine infra/**" 100644 100644 infra/docker-compose.yml
refuse 1 "_racine .claude/**" 100644 100644 .claude/settings.json
refuse 1 "_racine CLAUDE.md" 100644 100644 CLAUDE.md
refuse 1 "_racine ~-relatif" 100644 100644 "~/x"
accepte 1 "_racine scripts/" 100644 100644 scripts/outil.sh
accepte 0 "sso-lab/ dans une app" 100644 100644 sso-lab/x.py
head -c 1100000 /dev/zero > "$T/arbre/gros.bin"
refuse 0 "fichier > 1 Mo" 000000 100644 gros.bin

section "outils.py — secrets, .env assaini, calendrier, resume.json"
printf 'SECRET_KEY=cle-xyz-123456789\nKEYCLOAK_URL=http://kc:8080\nKEYCLOAK_CLIENT_SECRET=abcdef1234567890\nDB_PASSWORD="pw-quoted-1234"\nVAULT_ENCRYPTION_KEY=%s\nEMAIL_HOST_PASSWORD=x12345678\nAPI_KEY=k1234567890\nSERVER_URL_WAN=http://203.0.113.50:80\n' "$FERNET" > "$T/e.env"
"${OUTILS[@]}" env-assaini "$T/e.env" "$T/e.out" DB_HOST=auto-pg
check "assaini : SECRET_KEY changé" bash -c "! grep -q cle-xyz '$T/e.out'"
check "assaini : KEYCLOAK_URL conservé (KEY = mot, pas sous-chaîne)" grep -qx 'KEYCLOAK_URL=http://kc:8080' "$T/e.out"
check "assaini : KEYCLOAK_CLIENT_SECRET changé" bash -c "! grep -q abcdef1234567890 '$T/e.out'"
check "assaini : API_KEY changé" bash -c "! grep -q k1234567890 '$T/e.out'"
check "assaini : clé Fernet remplacée par une clé Fernet" bash -c "grep -E '^VAULT_ENCRYPTION_KEY=[A-Za-z0-9_-]{43}=\$' '$T/e.out' && ! grep -qF '$FERNET' '$T/e.out'"
check "assaini : clés d'email écartées" bash -c "! grep -q EMAIL_HOST '$T/e.out'"
check "assaini : guillemets retirés, surcharge ajoutée" bash -c "grep -qE '^DB_PASSWORD=[A-Za-z0-9]+\$' '$T/e.out' && grep -qx DB_HOST=auto-pg '$T/e.out'"
check "assaini : fichier en 600" test "$(stat -c %a "$T/e.out")" = 600
printf 'tok-claude-0123456789\n' > "$T/tok"
"${OUTILS[@]}" secrets-collecter "$T/sec" "$T/e.env" -- "$T/tok"
printf 'a cle-xyz-123456789 b tok-claude-0123456789 c 203.0.113.50 d ghp_%s e\n' "$(printf 'A%.0s' {1..36})" > "$T/s.in"
"${OUTILS[@]}" scrub "$T/sec" < "$T/s.in" > "$T/s.out"
check "filtre : secret, jeton, IP publique et motif ghp_ retirés" bash -c "! grep -qE 'cle-xyz|tok-claude|203\\.0\\.113\\.50|ghp_' '$T/s.out' && grep -q '\\[retiré\\]' '$T/s.out'"
check "filtre : KEYCLOAK_URL (non secret) non collecté" bash -c "! grep -q 'http://kc' '$T/sec'"
printf '1 a rotation:2\n1 b x\n' > "$T/cal.bad"
check "calendrier : jour en double refusé (code 2)" bash -c "'${OUTILS[0]}' -I '$AUTO/lib/outils.py' calendrier '$T/cal.bad' 1; test \$? = 2"
check "calendrier : jour sans tâche → code 3" bash -c "printf '1 a rotation:2\n' > '$T/cal1'; '${OUTILS[0]}' -I '$AUTO/lib/outils.py' calendrier '$T/cal1' 2; test \$? = 3"
check "calendrier réel (secteur prompts) lisible au format I2" "${OUTILS[@]}" calendrier-taches "$AUTO/calendrier.conf"
echo '{"version":1,"statut":"fini","charge":"faible","titre_pr":"x","constats":[{"gravite":"critique","cible":"a","titre":"t","fichier":"f","corrige":false}],"tests_ajoutes":0}' > "$T/r.json"
check "resume.json : valide" "${OUTILS[@]}" resume "$T/r.json" valide
check "resume.json : brouillon si critique non corrigé" "${OUTILS[@]}" resume-brouillon "$T/r.json" a a b
check "resume.json : pas de brouillon pour une autre cible" bash -c "! python3 -I '$AUTO/lib/outils.py' resume-brouillon '$T/r.json' b a b"
echo '{"version":2}' > "$T/r2.json"
check "resume.json : non conforme détecté" bash -c "! python3 -I '$AUTO/lib/outils.py' resume '$T/r2.json' valide"
ln -s "$L/.env" "$T/lien.md"
check "rapport : lien symbolique jamais suivi" bash -c "! python3 -I '$AUTO/lib/outils.py' rapport '$T/lien.md' '$T/l.out' '$T/sec'"
check "claude-resultat : is_error → limite" bash -c "echo '{\"type\":\"result\",\"subtype\":\"error\",\"is_error\":true,\"result\":\"usage limit\",\"session_id\":\"s\"}' > '$T/c.json'; python3 -I '$AUTO/lib/outils.py' claude-resultat '$T/c.json' 1 0 | grep -q ^limite"
check "claude-resultat : délai (124) → limite" bash -c "python3 -I '$AUTO/lib/outils.py' claude-resultat /dev/null 124 0 | grep -q ^limite"

section "contrôle des timeouts (lint)"
check "le moteur passe le contrôle" bash -c "test -z \"\$(python3 -I '$AUTO/lib/outils.py' lint-timeout '$AUTO'/bin/*.sh '$AUTO'/lib/*.sh '$AUTO'/lib/*.py)\""
printf 'docker ps\nx 5 docker ps\nFOO=1 git status\n# docker commenté\necho "docker dans une chaîne"\nif true; then curl x; fi\n' > "$T/mauvais.sh"
check "un docker/git/curl nu est signalé (3 lignes)" bash -c "test \"\$(python3 -I '$AUTO/lib/outils.py' lint-timeout '$T/mauvais.sh' | wc -l)\" = 3"

section "planifier (crontab factice)"
printf 'MAILTO=""\n0 3 * * * /bin/bash /x/scripts/backup.sh > /dev/null 2>&1\n' > "$T/crontab"
run planifier --check; check "--check sur crontab sans nos lignes → code 1" test $? = 1
check "--check n'écrit rien" bash -c "! grep -q auto.sh '$T/crontab'"
run planifier; check "planifier → code 0" test $? = 0
check "ligne de 0 h posée" grep -qF "0 0 * * * /bin/bash $AUTO/bin/auto.sh lancer > /dev/null 2>&1" "$T/crontab"
check "ligne de 5 h 10 posée" grep -qF "10 5 * * * /bin/bash $AUTO/bin/auto.sh rattraper > /dev/null 2>&1" "$T/crontab"
check "autres lignes intactes" bash -c "grep -qx 'MAILTO=\"\"' '$T/crontab' && grep -q backup.sh '$T/crontab'"
cp "$T/crontab" "$T/crontab.1"; run planifier
check "planifier rejoué : rien ne change" cmp -s "$T/crontab" "$T/crontab.1"
run planifier --check; check "--check une fois planifié → code 0" test $? = 0
run planifier --retirer
check "--retirer : nos lignes parties, les autres restées" bash -c "! grep -q 'auto.sh\|lab-auto' '$T/crontab' && grep -q backup.sh '$T/crontab' && grep -qx 'MAILTO=\"\"' '$T/crontab'"

[[ "$MODE" == unitaires ]] && { echo; echo "Résultat : $PASS ✔, $FAIL ✘"; (( FAIL == 0 )); exit $?; }

# ══ Essais avec conteneurs ════════════════════════════════════════════════════
section "préparation : images d'essai, faux GitHub"
mkdir -p "$T/img"; cp "$TESTS/faux-claude" "$T/img/claude"; chmod 755 "$T/img/claude"
printf 'FROM lab-workspace:latest\nCOPY --chmod=0755 claude /usr/local/bin/claude\n' > "$T/img/Dockerfile"
docker build -q -t auto-essai-claude:latest "$T/img" > /dev/null || { echo "image d'essai non construite" >&2; exit 1; }
for a in zzautoa zzautob; do docker build -q -t "$a-backend:latest" "$T/src/$a/backend" > /dev/null || exit 1; done
export AUTO_PG_IMAGE="$(docker inspect -f '{{.Config.Image}}' dev-postgres 2>/dev/null || echo postgres:16-alpine)"
FAUX_GH_TOKEN="$GHTOK" python3 -I "$TESTS/faux-github.py" "$T/github" & GHPID=$!
for _ in $(seq 1 50); do [[ -s "$T/github/port" ]] && break; sleep 0.1; done
export AUTO_GITHUB_API="http://127.0.0.1:$(cat "$T/github/port")"
ok "images d'essai et faux GitHub prêts ($AUTO_GITHUB_API)"
export AUTO_FIN_EPOCH=$(( $(date +%s) + 3600 ))
# Emails décodés (UTF-8 ⇒ encodage de transfert) : $T/emails.txt, régénéré à chaque appel.
emails() { python3 -c '
import email,glob,sys
from email import policy
out=[]
for f in sorted(glob.glob(sys.argv[1]+"/*.eml")):
    m=email.message_from_binary_file(open(f,"rb"),policy=policy.default)
    out.append("Subject: "+m["Subject"]+"\n"+m.get_content())
open(sys.argv[2],"w").write("\n=====\n".join(out))' "$T/emails" "$T/emails.txt"; echo "$T/emails.txt"; }
npulls() { [[ -f "$T/github/pulls.jsonl" ]] && wc -l < "$T/github/pulls.jsonl" || echo 0; }
branche() { G --git-dir="$T/remotes/essai/$1.git" rev-parse -q --verify "refs/heads/$2" > /dev/null 2>&1; }

section "verifier"
run verifier; rc=$?
check "verifier → code 0 quand tout est en place" test $rc = 0
for p in jetons prompts cibles image pare-feu claude github stdin invites timeouts verrou disque smtp; do
  check "verifier contrôle [$p]" grep -qE "✔ \[$p\]" "$OUT"
done
(( rc == 0 )) || sed 's/^/      /' "$OUT"
chmod 644 "$ST/github-token"; run verifier; rc=$?; chmod 600 "$ST/github-token"
check "jeton en 644 → code 1 et ✘ [jetons]" bash -c "test $rc = 1 && grep -q '✘ \[jetons\]' '$OUT'"
echo "repo, delete_repo" > "$T/github/scopes"; run verifier; rc=$?; rm -f "$T/github/scopes"
check "jeton avec delete_repo → ✘ [github]" bash -c "test $rc = 1 && grep -q '✘ \[github\].*delete_repo' '$OUT'"
cp "$ST/github-token" "$T/gh.sav"; echo "ghp_classiqueclassiqueclassique1234" > "$ST/github-token"; run verifier; rc=$?; cp "$T/gh.sav" "$ST/github-token"
check "jeton classique (non github_pat_) → ✘ [github]" bash -c "test $rc = 1 && grep -q '✘ \[github\]' '$OUT'"
jeton noauth; run verifier; rc=$?; jeton ok
check "claude non authentifié → ✘ [claude]" bash -c "test $rc = 1 && grep -q '✘ \[claude\]' '$OUT'"
AUTO_SMTP_ENV=/nonexistent AUTO_EMAIL_DIR= run verifier; rc=$?
check "SMTP incomplet → ✘ [smtp]" bash -c "test $rc = 1 && grep -q '✘ \[smtp\]' '$OUT'"
check "verifier n'écrit aucun secret" aucun_secret "$OUT"
check "rien ne reste (conteneurs, réseaux)" reste_rien

# ── Passage nominal ───────────────────────────────────────────────────────────
section "lancer — nominal (securite, rotation:2)"
jeton ok; rm -f "$ST/rotation-securite"
run lancer --date 2031-01-06 --tache securite; rc=$?
R="$RUNS/2031-01-06-securite"
check "code 0" test $rc = 0
check "etat.json : statut fini" test "$(etatv 2031-01-06-securite statut)" = fini
check "2 PR ouvertes" test "$(npulls)" = 2
check "branche auto/2031-01-06-securite poussée (zzautoa)" branche zzautoa auto/2031-01-06-securite
check "branche poussée (zzautob)" branche zzautob auto/2031-01-06-securite
check "auteur du commit = LAB_GIT_AUTHOR_*" bash -c "GIT_CONFIG_GLOBAL=/dev/null git --git-dir='$T/remotes/essai/zzautoa.git' log -1 --format='%an <%ae>' auto/2031-01-06-securite | grep -qx 'Auteur Essai <auteur.essai@example.org>'"
check "le commit ne contient que le correctif" bash -c "test \"\$(GIT_CONFIG_GLOBAL=/dev/null git --git-dir='$T/remotes/essai/zzautoa.git' diff --name-only main auto/2031-01-06-securite)\" = backend/views.py"
check "PR : jeton présenté, titre de resume.json, base main, rapport en corps" python3 -c "
import json;l=[json.loads(x) for x in open('$T/github/pulls.jsonl')]
assert all(p['auth_ok'] and p['title']=='Essai : correctif factice' and p['base']=='main' and p['head']=='auto/2031-01-06-securite' and 'Rapport factice' in p['body'] and not p['draft'] for p in l)"
check "etat.json : 2 URL de PR" test "$(python3 -c "import json;print(len(json.load(open('$R/etat.json'))['pr']))")" = 2
check "email écrit (rapport en corps)" grep -q 'Rapport factice' "$(emails)"
check "tests : .env assaini dans le conteneur" grep -q "SECRET_KEY assaini : oui" "$R/tests/zzautoa/backend.txt"
check "tests : clés d'email écartées" grep -q "EMAIL écarté : oui" "$R/tests/zzautoa/backend.txt"
check "tests : base jetable joignable" grep -q "base : joignable" "$R/tests/zzautoa/backend.txt"
check "tests : réseau fermé (--internal)" grep -q "réseau : fermé" "$R/tests/zzautoa/backend.txt"
check "Claude : uid 1000, répertoire /work" grep -q "user=1000 cwd=/work" "$T/work/home/.faux-appels"
check "Claude : session neuve (--session-id), pas de --max-turns" bash -c "grep 'phase=principale' '$T/work/home/.faux-appels' | tail -1 | grep -qE 'sid=[0-9a-f-]{36} resume= maxt= '"
check "rotation avancée (index 0 après 2 apps sur 2)" test "$(cat "$ST/rotation-securite")" = 0
check "journal, etat, rapport, email sans secret" aucun_secret "$R/journal.txt" "$R/etat.json" "$R/rapport-publie.md" "$(emails)" "$T/emails"/*.eml "$T/github/pulls.jsonl"
check "aucun jeton sur la ligne de commande du conteneur" bash -c "! grep -rqsF '$GHTOK' '$T/work/home/.faux-appels'"
check "rien ne reste (conteneurs, réseaux)" reste_rien
run lancer --date 2031-01-06 --tache securite; rc=$?
check "relancer un passage existant est refusé (code 1)" test $rc = 1

section "lancer — fichiers parasites ignorés"
jeton parasite; run lancer --date 2031-01-07 --tache securite
check "PR faites" test "$(etatv 2031-01-07-securite statut)" = fini
check "ni __pycache__, ni *.pyc, ni node_modules dans le commit" bash -c "test \"\$(GIT_CONFIG_GLOBAL=/dev/null git --git-dir='$T/remotes/essai/zzautoa.git' diff --name-only main auto/2031-01-07-securite)\" = backend/views.py"

section "lancer — chemin refusé, puis rattrapage qui reprend la session"
jeton interdit; P0="$(npulls)"
run lancer --date 2031-01-08 --tache securite; rc=$?
R="$RUNS/2031-01-08-securite"
check "code 1, statut refuse" bash -c "test $rc = 1 && test '$(etatv 2031-01-08-securite statut)' = refuse"
check "refus motivé (Dockerfile)" grep -q "backend/Dockerfile — \*\*/Dockerfile\*" "$R/tests/zzautoa/refus.txt"
check "aucune branche pour la cible refusée" bash -c "! GIT_CONFIG_GLOBAL=/dev/null git --git-dir='$T/remotes/essai/zzautoa.git' rev-parse -q --verify refs/heads/auto/2031-01-08-securite"
check "l'autre cible a sa PR" test "$(npulls)" = $((P0 + 1))
check ".git du clone de travail en lecture seule pour Claude" bash -c "! grep -q GIT-INSCRIPTIBLE '$R/sortie/rapport.md'"
SID="$(etatv 2031-01-08-securite session_id)"
AUTO_DATE=2031-01-08 run rattraper; rc=$?
check "rattraper → code 0, statut fini" bash -c "test $rc = 0 && test '$(etatv 2031-01-08-securite statut)' = fini"
check "rattraper a repris LA session (--resume $SID)" bash -c "grep -q 'phase=reprise sid=$SID resume=$SID' '$T/work/home/.faux-appels'"
check "mission de reprise : refus listés" grep -q "Correctifs rejetés par le moteur" "$R/entree/mission.md"
check "PR de la cible corrigée" test "$(npulls)" = $((P0 + 2))
check "rien ne reste" reste_rien

section "lancer — limite d'usage, puis rattrapage"
jeton limite; P0="$(npulls)"
run lancer --date 2031-01-09 --tache securite; rc=$?
check "code 1, statut limite" bash -c "test $rc = 1 && test '$(etatv 2031-01-09-securite statut)' = limite"
check "aucune PR pendant la limite" test "$(npulls)" = "$P0"
check "pas d'email avant le rattrapage" bash -c "! grep -q 'Nuit du 2031-01-09' '$(emails)'"
SID="$(etatv 2031-01-09-securite session_id)"
AUTO_DATE=2031-01-09 run rattraper; rc=$?
check "rattraper → fini, 2 PR" bash -c "test $rc = 0 && test '$(etatv 2031-01-09-securite statut)' = fini && test $(npulls) = $((P0 + 2))"
check "reprise avec la même session" grep -q "phase=reprise sid=$SID resume=$SID" "$T/work/home/.faux-appels"
check "email envoyé après le rattrapage" grep -q 'Nuit du 2031-01-09' "$(emails)"
AUTO_DATE=2031-01-09 run rattraper; rc=$?
check "rattraper un passage fini : rien à faire (code 0)" bash -c "test $rc = 0 && grep -q 'déjà fini' '$OUT'"

section "lancer — délai dépassé (5 h 00)"
jeton delai; t0=$(date +%s)
AUTO_FIN_EPOCH=$(( $(date +%s) + 140 )) run lancer --date 2031-01-10 --tache securite; rc=$?
check "code 1, statut limite" bash -c "test $rc = 1 && test '$(etatv 2031-01-10-securite statut)' = limite"
check "arrêté au délai (< 260 s)" test $(( $(date +%s) - t0 )) -lt 260
check "conteneur de Claude supprimé" reste_rien

section "lancer — tests rouges, correction, puis vert"
jeton rouge; P0="$(npulls)"
run lancer --date 2031-01-13 --tache securite; rc=$?
R="$RUNS/2031-01-13-securite"
check "code 0, statut fini" bash -c "test $rc = 0 && test '$(etatv 2031-01-13-securite statut)' = fini"
check "phase correction jouée, tests.txt fourni" bash -c "grep -q 'phase=correction' '$T/work/home/.faux-appels' && grep -q MARQUEUR-ROUGE '$R/entree/tests.txt' && ! grep -q TESTS-TXT-ABSENT '$R/sortie/rapport.md'"
check "rapport : « ## Correction après tests » ajouté" grep -q "Correction après tests" "$R/rapport-publie.md"
check "2 PR (zzautoa corrigée)" test "$(npulls)" = $((P0 + 2))
jeton rouge2; P0="$(npulls)"
run lancer --date 2031-01-14 --tache securite; rc=$?
check "encore rouge après correction : rapport seul pour zzautoa" bash -c "grep -q '^zzautoa' '$RUNS/2031-01-14-securite/sans-pr' && test $(npulls) = $((P0 + 1))"
check "une seule correction" test "$(grep -c 'phase=correction.*scen=rouge2' "$T/work/home/.faux-appels")" = 1
check "rien ne reste" reste_rien

section "lancer — secret dans le rapport"
jeton fuite; run lancer --date 2031-01-15 --tache securite
R="$RUNS/2031-01-15-securite"
check "jeton retiré du rapport publié et des PR" aucun_secret "$R/rapport-publie.md" "$T/github/pulls.jsonl" "$(emails)" "$R/journal.txt"
check "adresse IP publique masquée, boucle locale gardée" bash -c "! grep -q 198.51.100.7 '$R/rapport-publie.md' && grep -q 127.0.0.1 '$R/rapport-publie.md'"

section "lancer — rapport.md en lien symbolique"
jeton lien; P0="$(npulls)"; run lancer --date 2031-01-16 --tache securite
check "lien non suivi : statut echec, aucune PR" bash -c "test '$(etatv 2031-01-16-securite statut)' = echec && test $(npulls) = $P0"

section "lancer — dépendances modifiées (image reconstruite), puis app .heavy-build"
jeton deps; P0="$(npulls)"; run lancer --date 2031-01-17 --tache securite
check "image <app>-backend:auto reconstruite puis tests verts" bash -c "grep -q 'reconstruction de zzautoa-backend:auto' '$RUNS/2031-01-17-securite/tests/zzautoa/tester.txt' && test $(npulls) = $((P0 + 2))"
check "image :auto supprimée après" bash -c "! docker image inspect zzautoa-backend:auto"
jeton lourd; P0="$(npulls)"; run lancer --date 2031-01-20 --tache securite
check ".heavy-build : dépendances non testées, pas de PR pour zzautoa" bash -c "grep -q 'dépendances non testées' '$RUNS/2031-01-20-securite/sans-pr' && test $(npulls) = $((P0 + 1))"

section "lancer — interface : charge faible ⇒ phase 2, frontend, dépôt racine"
jeton faible; P0="$(npulls)"; run lancer --date 2031-01-18 --tache interface; rc=$?
R="$RUNS/2031-01-18-interface"
check "code 0, 2 PR (zzautob, racine)" bash -c "test $rc = 0 && test $(npulls) = $((P0 + 2))"
check "phase suite jouée, « Pour aller plus loin » ajouté" bash -c "grep -q 'phase=suite' '$T/work/home/.faux-appels' && grep -q 'Pour aller plus loin' '$R/rapport-publie.md'"
check "frontend construit (réseau lwtq)" grep -q "frontend=ok" "$R/tests/zzautob/resultat.txt"
check "racine : contrôles de syntaxe" grep -q "syntaxe des fichiers modifiés" "$R/tests/_racine/syntaxe.txt"
check "racine montée en /work/dev" grep -q "| _racine | /work/dev |" "$R/entree/mission.md"

section "lancer — services : contexte fourni par l'hôte"
jeton services; run lancer --date 2031-01-19 --tache services
R="$RUNS/2031-01-19-services"
check "contexte/lab-doctor.txt et conteneurs.txt fournis" bash -c "test -s '$R/entree/contexte/lab-doctor.txt' && test -s '$R/entree/contexte/conteneurs.txt'"
check "adresse IP masquée dans le contexte" bash -c "grep -q 'bilan factice' '$R/entree/contexte/lab-doctor.txt' && ! grep -q 203.0.113.9 '$R/entree/contexte/lab-doctor.txt'"

section "lancer --essai"
jeton essai; echo 1 > "$ST/rotation-securite"; P0="$(npulls)"; NE="$(ls "$T/emails" | wc -l)"
run lancer --date 2031-01-21 --tache securite --essai; rc=$?
check "code 0, statut fini" bash -c "test $rc = 0 && test '$(etatv 2031-01-21-securite-essai statut)' = fini"
check "--max-turns 6 transmis" grep -q "maxt=6 scen=essai" "$T/work/home/.faux-appels"
check "ni push, ni PR, ni email" bash -c "test $(npulls) = $P0 && ! GIT_CONFIG_GLOBAL=/dev/null git --git-dir='$T/remotes/essai/zzautoa.git' rev-parse -q --verify refs/heads/auto/2031-01-21-securite && test \$(ls '$T/emails' | wc -l) = $NE"
check "tests joués quand même" grep -q "OK" "$RUNS/2031-01-21-securite-essai/tests/zzautoa/backend.txt"
check "la rotation n'avance pas pour un essai" test "$(cat "$ST/rotation-securite")" = 1

section "rattraper — passage manquant"
jeton ok; P0="$(npulls)"
AUTO_DATE=2031-01-22 run rattraper; rc=$?
check "aucun passage à 0 h : la tâche de la nuit est lancée" bash -c "test $rc = 0 && test '$(etatv 2031-01-22-securite statut)' = fini && test $(npulls) = $((P0 + 2))"
check "rien ne reste" reste_rien

echo
echo "Résultat : $PASS ✔, $FAIL ✘"
(( FAIL == 0 )) || printf '  ✘ %s\n' "${FAILS[@]}"
(( FAIL == 0 ))
