# Chantier « peripheriques » — reste à faire après déploiement (S1)

Contrat de référence : `CONTRAT.md` **v3** (les trois secteurs ont rendu `OK` sur v3).
Déploiement lancé le 2026-10-04 : `bash scripts/setup2.sh peripheriques --yes`
(log : scratchpad de session, `setup2-peripheriques.log`).

## État au 2026-10-10 — clôture partielle

Fait et vérifié en réel ce jour (contrat v6, redéployé deux fois, `grep ERROR` vide, 3 conteneurs Up) :
- 100 tests backend OK (`--settings=config.settings_test`) ;
- `cloisonnement.spec.ts` : 3/3 PASSED via `lab-runner` ;
- navigateur réel (`e2e_member`, admin) : sans droit `/api/devices/` = `[]` ; `/api/grants/devices/`
  liste la webcam ; droit à soi-même → périphérique visible avec `since` ; suppression → `[]` ;
  sans jeton 403 ; pages Droits et Matériel rendues ; polices en 200 ;
- catalogue matériel réel (12 références) copié dans `backend/api/data/materiel.json` — il n'y
  était pas, la page servait un catalogue vide ;
- `CLAUDE.md`, `README.md`, `scripts/new-app.sh` (gitignore `media/`), `.gitignore` de l'app ;
- sous-module et dépôt parent commités.

**Reste ouvert — impossible sans la caméra, débranchée depuis le 2026-10-06 environ**
(`peripheriques-media` attend le périphérique) : §2 entier, et dans §3 le direct WHEP/HLS réel, le
kick en cours de lecture, la relecture, la vidéo H.264 en vrai navigateur, le WebRTC WAN. Restent
aussi : cause racine des réinitialisations USB (§7), polices Foyer à reporter dans `_templates/`
et les autres apps, `runserver` en production dans le template (§7), mémoire (§6).

## 1. Vérifier le déploiement (setup2.sh peut afficher un faux succès)
- [ ] `grep -n ERROR` dans le log + `docker ps` : `peripheriques-backend`, `-frontend`, `-media` Up
- [ ] `docker logs peripheriques-media` : publication acceptée par le hook, chemins `webcam/{av,video,audio}` ready
- [ ] `KEYCLOAK_REQUIRED_GROUPS` et `KEYCLOAK_ADMIN_CLIENT_SECRET` bien écrits dans `peripheriques/.env`
- [ ] Labels Caddy générés pour `/peripheriques-webrtc/*` et `/peripheriques-hls/*` (préfixes `0_`/`1_`)

## 2. Essai caméra réel (5 min) — caméra déjà sur port alimenté
- [ ] Aucun `runOnInit command exited` / déconnexion USB sur 5 min
- [ ] Si coupures : demander `sudo dmesg` à l'utilisateur (cause ≠ alimentation ; pistes : autosuspend USB, firmware vidéo+micro simultanés, bande passante USB 2)
- [ ] `docker stats` ≥ 60 s : CPU réel de l'encodage (repère mire synthétique : ~30 % d'un cœur)
- [ ] Débit réel : taille du premier segment horaire complet (repère : ~480 Mo/h)

## 3. Tests de bout en bout (réels, pas de mock)
- [ ] `cloisonnement.spec.ts` via `lab-runner` (`POST /run` `{"app":"peripheriques"}` — `[]` = aucun test trouvé, pas un succès)
- [ ] Admin sans Grant : `/api/devices/` = `[]`, hook `read` refusé
- [ ] Grant à soi-même → direct WHEP réel (Location WHEP derrière `handle_path` : vérifier que le `DELETE` de fin atteint bien MediaMTX)
- [ ] Direct HLS réel (bearer transmis dans `token`)
- [ ] Révocation pendant lecture → kick WebRTC **et** kick HLS effectifs
- [ ] Relecture : liste clippée au `since`, ticket → `stream` lisible, audio seul = remux sans vidéo
- [ ] Vidéo H.264 vérifiée dans un **vrai navigateur** par l'utilisateur (`lab-runner` ne décode pas le H.264 — décision : pas de Chrome dans le runner)
- [ ] Depuis l'extérieur, une fois la redirection Bbox 8189 udp+tcp faite à la main par l'utilisateur : WebRTC WAN

## 4. Commits
- [ ] Sous-module `peripheriques` : commiter/pousser les éventuels correctifs d'intégration
- [ ] Dépôt parent `dev` : `.gitmodules`, `peripheriques` (pointeur), `infra/init/00_schemas.sql`,
      `to_do_lab_media.md`, `CLAUDE.md`, `README.md`, `_templates/…/.gitignore` — un seul commit

## 5. Documentation et corrections lab-wide (S1)
- [ ] `CLAUDE.md` : ligne `peripheriques` dans le tableau des sous-modules (Django + Angular + `media/` MediaMTX, 8101 / 4216) + note sur son service `media` (comme `robot-lab`/`engine`)
- [ ] `CLAUDE.md` : section décisions/pièges — droits par email (Grant, `since`, admins sans accès implicite), MediaMTX privé **provisoirement** (renvoi à `to_do_lab_media.md`), dérogation volume dédié vs `storage`, HLS authentifié à l'ouverture seulement (kick obligatoire), port 8189 ouvert à la main
- [ ] `CLAUDE.md` : `lab-runner` ne décode pas le H.264 (section Tests end-to-end)
- [ ] `CLAUDE.md` : leçon v4 — une page de gestion des droits ne tire jamais ses référentiels d'un endpoint filtré par les droits de l'utilisateur courant (sinon un admin sans droit ne peut accorder le premier, même à lui-même)
- [ ] Redéployer après backend v4 (`setup2.sh peripheriques --yes`), puis vérifier en réel : admin sans Grant → sélecteur Droits rempli → droit à soi-même → Direct affiche le lecteur
- [ ] `CLAUDE.md` : `to_do_ui_foyer.md` cité mais absent du dépôt — corriger la référence
- [ ] `CLAUDE.md` : chantier « huit apps sans test de cloisonnement » — `peripheriques` a bien son spec (ne pas l'ajouter à la liste)
- [ ] `README.md` : `peripheriques/` dans l'arborescence
- [ ] `_templates/django-angular` (via `new-app.sh`) : `.gitignore` ignore `media/` à la racine → ignore aussi un service `media/` d'une app Django+Angular ; restreindre à `backend/media/`
- [ ] Polices Foyer en 404 derrière Caddy : correctif `url("assets/fonts/…")` (relatif) appliqué dans `peripheriques` seulement — à reporter dans `_templates/` et les autres apps (mémoire `project_foyer_font_404`)
- [ ] `.app-descriptions` / page 404 : **ne pas** ajouter `peripheriques` (décision utilisateur : hors vitrine, comme `oauth-hub`) ; vérifier qu'elle apparaît bien dans lab-admin « Apps du lab » avec l'étiquette « hors vitrine »

## 6. Mémoire et clôture
- [ ] Mémoire : projet `peripheriques` (décisions, état) + pièges MediaMTX (HLS/kick, Location WHEP, /proc/asound, by-id figé) + `lab-runner` sans H.264 + hls.js 4xx non fatal
- [ ] Mettre à jour la mémoire `project_foyer_font_404` (cause et correctif trouvés)
- [ ] Archiver/supprimer `chantiers/peripheriques/` une fois absorbé dans `CLAUDE.md`

## 7. Correctifs v5 (après retour des secteurs media + backend)
- [x] Appliquer le bloc compose v5 puis redéployer (fait 2026-10-04 19:57)
- [x] Reprise automatique validée en réel : 5 réinitialisations USB en 1 min, reprise à chaque fois en ~6 s, conteneur jamais recréé, aucun `Not a tty`
- [x] `MEDIA_HOOK_KEY` rotée avant redéploiement (anciens logs effacés avec les conteneurs)
- [x] 0 occurrence de `key=` en clair dans les logs backend
- [ ] **Cause racine des réinitialisations USB** (toutes les 7 à 19 s, flux en ligne ~60 % du temps) : en attente de `sudo dmesg` + test `power/control=on` par l'utilisateur
- [ ] Lab-wide : le backend du template tourne en prod avec `runserver` (CMD du Dockerfile), pas gunicorn — vérifier les autres apps et décider (hors périmètre de ce chantier)
