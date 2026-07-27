# Vérification du routage setup2.sh / setup_unit.sh / .heavy-build

Vérifier le nouveau routage setup2.sh/setup_unit.sh/.heavy-build (dev/scripts/)
sur le lab réel, en 4 tests. Lire scripts/setup2.sh, scripts/setup_unit.sh,
scripts/clean2.sh, scripts/recompose_docker.sh et scripts/app-priorities.conf
avant de commencer pour avoir le contexte exact. Rapporter le résultat de
chaque test (pass/fail + logs pertinents), s'arrêter et signaler si un test
échoue avant de passer au suivant. Tests 3 et 4b ont un impact large (tout le
lab / sessions de tous les utilisateurs) — ne les lancer qu'avec l'accord
explicite de l'utilisateur, à un moment de faible usage si possible ; les
autres (1, 2, 4a) ont un impact limité et peuvent être lancés directement.

Ordre recommandé : 1 → 2 → 3 → 4a → 4b (le Test 2 enregistre le hash
"sûr" d'atelier-3d une bonne fois, donc le Test 3 ne repaie pas sa
recompilation COLMAP/OpenMVS).

## Test 1 — chemin rapide (une app, cas courant)

```
bash scripts/setup2.sh lab-admin --yes
```

Vérifier : le log affiche "délégué à setup_unit.sh" à l'étape 1 (pas de
clean2.sh en double), les étapes 4-7 apparaissent groupées sous
setup_unit.sh, le container lab-admin-backend est up à la fin (docker ps),
et l'app répond (curl sur son port depuis .ports).

Durée estimée : ~2-4 min.

## Test 2 — cache .heavy-build (atelier-3d, le seul avec ce marqueur)

a) Confirmer l'état de départ :
```
cat atelier-3d/backend/.heavy-build.sha256 2>/dev/null
sha256sum atelier-3d/backend/Dockerfile
```
Les deux doivent différer (ou le fichier .sha256 n'existe pas encore).

b) Première passe (hash absent → le nettoyage du cache doit s'exécuter) :
```
bash scripts/setup2.sh atelier-3d --yes
```
Vérifier : "docker builder prune -f" s'exécute dans les logs de clean2.sh
(Dockerfile jamais marqué "sûr"). Une fois terminé, `.heavy-build.sha256`
doit exister et correspondre exactement au sha256sum du Dockerfile.
Durée estimée : ~20-25 min (recompilation COLMAP/OpenMVS from scratch).

c) Deuxième passe, sans rien changer :
```
bash scripts/setup2.sh atelier-3d --yes
```
Vérifier : le message "Dockerfile(s) lourd(s) inchangé(s)... nettoyage du
cache ignoré" apparaît, et l'étape "exporting layers" est nettement plus
rapide qu'au premier passage (pas de recompilation).
Durée estimée : ~1-3 min.

d) Validation du cas "Dockerfile modifié" — EN LOGIQUE ISOLÉE plutôt qu'un
   vrai rebuild (évite de repayer ~20-25 min de recompilation pour un test
   qui ne vérifie qu'un test bash) :
```bash
TMPD="$(mktemp -d)"
mkdir -p "$TMPD/appX/backend"
echo "FROM ubuntu:24.04" > "$TMPD/appX/backend/Dockerfile"
touch "$TMPD/appX/backend/.heavy-build"

test_skip() {
  local _PRUNE_SEARCH_ROOT="$1"
  local _HEAVY_FOUND=false _HEAVY_CHANGED=false
  while IFS= read -r _marker; do
    _HEAVY_FOUND=true
    _mdir="$(dirname "$_marker")"
    _dockerfile="$_mdir/Dockerfile"
    if [[ ! -f "$_dockerfile" ]]; then _HEAVY_CHANGED=true; continue; fi
    _current_hash="$(sha256sum "$_dockerfile" | cut -d' ' -f1)"
    _stored_hash="$(cat "$_mdir/.heavy-build.sha256" 2>/dev/null || true)"
    [[ "$_current_hash" != "$_stored_hash" ]] && _HEAVY_CHANGED=true
  done < <(find "$_PRUNE_SEARCH_ROOT" -maxdepth 4 -name ".heavy-build" 2>/dev/null)
  if $_HEAVY_FOUND && ! $_HEAVY_CHANGED; then echo "SKIP prune"; else echo "RUN prune"; fi
}

sha256sum "$TMPD/appX/backend/Dockerfile" | cut -d' ' -f1 > "$TMPD/appX/backend/.heavy-build.sha256"
test_skip "$TMPD"   # attendu: SKIP prune
echo "RUN echo changed" >> "$TMPD/appX/backend/Dockerfile"
test_skip "$TMPD"   # attendu: RUN prune (Dockerfile modifié)
rm -rf "$TMPD"
```
Durée estimée : quelques secondes.

## Test 3 — dispatch parallèle (mode tout le lab)

⚠ Impact large : redémarre TOUTES les apps du lab d'un coup. Confirmer avec
l'utilisateur avant de lancer.
```
bash scripts/setup2.sh --yes
```
Vérifier, dans les logs de l'étape 7 :
- "Ignoré ici — géré par app..." apparaît aux étapes 6/6bis (pas de double
  appel create-app-client/ensure-schemas en boucle globale)
- atelier-3d démarre en premier (priorité 5, cf. app-priorities.conf)
- jamais plus de 2 apps "démarrage" simultanément sans qu'une autre soit
  déjà terminée entre-temps (comparer les horodatages des lignes
  "▶ <app> — démarrage")
- toutes les apps attendues finissent up (docker ps)
- si une app échoue, "échec... les autres apps continuent" apparaît sans
  stopper le reste du dispatch

Durée estimée : ~8-12 min (si le Test 2 a déjà été fait, sinon +20-25 min).

## Test 4 — rotate-secrets et restart-sso-lab (chemin séquentiel préservé)

### 4a. --rotate-secrets (aucun risque pour les comptes utilisateurs)

```
bash scripts/setup2.sh lab-admin --rotate-secrets --yes
```
Vérifier : le log NE affiche PAS "délégué à setup_unit.sh" (chemin
séquentiel d'origine emprunté), rotate-db-password.sh puis
rotate-app-secret.sh lab-admin s'exécutent dans cet ordre, le service
redémarre avec les nouveaux secrets.

Durée estimée : ~2-4 min.

### 4b. --restart-sso-lab avec rotation ciblée sur un NOUVEL utilisateur test

⚠ Impact large : --restart-sso-lab recrée tout le realm Keycloak →
déconnecte TOUS les utilisateurs actuellement connectés à N'IMPORTE QUELLE
app du lab (coupure de session pour tout le monde, pas seulement un
changement de mot de passe). Ne lancer qu'avec l'accord explicite de
l'utilisateur.

1. Ajouter une entrée de test dans `sso-lab/ldap/init.ldif`, sur le modèle
   d'une entrée existante (dn/uid/cn distincts, ex. `uid=claude-test-verif`),
   avec un `userPassword` placeholder quelconque (régénéré de toute façon à
   l'étape 3).
2. Sauvegarder une copie de `sso-lab/ldap/init.ldif` AVANT l'étape 3 (pour
   comparer après, et pouvoir restaurer en cas de souci).
3. ```
   bash scripts/setup2.sh --restart-sso-lab --yes \
     --keep-password sacha,Carpeta,hassan,lea,elodie,naty,sabrina,bruno,marie
   ```
4. Comparer `sso-lab/ldap/init.ldif` avant/après (diff) :
   - les 9 lignes `userPassword` des comptes réels doivent être
     STRICTEMENT IDENTIQUES avant/après ;
   - la ligne `userPassword` de `claude-test-verif` doit avoir CHANGÉ par
     rapport au placeholder de l'étape 1.
5. Vérifier qu'un compte réel (ex. sacha) se connecte toujours normalement
   à une app du lab (son mot de passe n'a pas bougé).
6. Nettoyage : retirer l'entrée `claude-test-verif` de `init.ldif`. Le
   compte restera présent dans l'annuaire LDAP / le realm Keycloak EN COURS
   tant qu'un nouveau `--restart-sso-lab` n'est pas relancé — aucun script
   du lab ne fait de suppression ciblée d'un compte. Le supprimer
   manuellement via phpLDAPadmin ou la console Admin Keycloak pour qu'il
   disparaisse immédiatement plutôt qu'au prochain restart.

Durée estimée : ~12-30 min (sso-lab redémarre à froid + recompose --force
séquentiel sur les 8 apps une par une — comportement déjà existant du
chemin legacy, pas introduit par ce refactor).

## Rapport final

Nombre de tests passés/échoués, et pour chaque échec la ligne de log ou le
comportement qui ne correspond pas à l'attendu.
