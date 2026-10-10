# Chantier « peripheriques » — CONTRAT  ·  **version v6**

> Fichier **possédé par S1 (l'architecte) seul**. Aucun S2/S3 ne l'édite jamais — un besoin de
> changement passe par un amendement (`../amendements/`), voir la skill `chantier`.

## Journal des versions
| Version | Date | Ce qui change | Secteurs à re-notifier |
|---|---|---|---|
| v1 | 2026-10-04 | rédaction initiale | — |
| v2 | 2026-10-04 | amendement media-01 accepté (option A) : HLS n'appelle le hook qu'à l'ouverture de session → I4 gagne `hlssessions/list` + `hlssessions/kick`, le kick choisit l'endpoint selon le `protocol` enregistré ; I2-(d) remplacé ; frontend : 401/404 HLS en cours de lecture = fin, pas de boucle de reconnexion | backend, frontend, media |
| v3 | 2026-10-04 | décision utilisateur : **les admins n'ont plus d'accès implicite** aux flux ni à l'historique ; ils gèrent les droits, mais voient/écoutent uniquement via un Grant explicite (à leur propre email), soumis au même `since`. `since` n'est plus jamais null pour un droit accordé. | backend, frontend |
| v4 | 2026-10-04 | trou de v3 constaté en réel : la page Droits alimentait son sélecteur avec `/api/devices/` (= périphériques où j'ai un droit) → un admin sans Grant ne pouvait accorder aucun droit, même à lui-même. Ajout de `GET /api/grants/devices/` (admin) = **tous** les périphériques ; `/api/devices/` inchangé. | backend, frontend |
| v5 | 2026-10-04 | constaté en prod : (1) une ré-énumération USB a interverti video0/video1 → le `devices:` figé à la création du conteneur pointait sur le nœud **métadonnées** (`Not a tty`), `wait-devices.sh` ne l'a pas vu (il ne compare que major:minor). I6 : plus de `devices:` figé ; `/dev` de l'hôte monté **en lecture seule** sous `/hostdev` + `device_cgroup_rules` (81 = video4linux, 116 = ALSA) ; ffmpeg ouvre `MEDIA_DEVICE_VIDEO` réécrit sous `/hostdev`. (2) `MEDIA_HOOK_KEY` apparaissait en clair dans le log d'accès gunicorn (`?key=`) → le backend ne doit jamais journaliser la query de `/api/media-auth/`. | media, backend |

| v6 | 2026-10-04 | demande utilisateur : page « Matériel conseillé » réservée aux admins (références de caméras sans fil + où les acheter). Nouvel endpoint I3 `GET /api/admin/materiel/` + contenu versionné `backend/api/data/materiel.json` (format I7). | backend, frontend |
---

## 1. Objectif — formulation d'origine, à respecter à la lettre

> « Ce que je voudrait c'est ajouter à dev un service controle des périphérques.
> Celui-ci permet aux admin de donner les droits aux utiliseteurs par email d'accédert aux
> perifériques (vidéo, micro ou les deux a la fois ) qui sont connectés à cet hote.
> Pour leurs usage un enregistrement conrtinu (heure par heure sinon ce serait trop lourd) doit
> être utilisable en plus de la visualisation+ écoute en firecte. »

Décisions utilisateur actées (2026-10-04) :
- rétention des enregistrements : **7 jours** ;
- stockage : **volume Docker dédié** `external` (dérogation assumée à la règle « tout fichier
  utilisateur passe par `storage` » : flux machine de ~11 Go/jour, écrit directement par MediaMTX) ;
- bénéficiaires : **comptes du realm `ssolab` existants uniquement** (pas de création de compte) ;
- un droit ne donne accès qu'aux enregistrements **postérieurs à son octroi**.

## 2. Constat vérifié le 2026-10-04 (à revérifier rapidement au démarrage)

- Hôte : 2 vCPU, 15 Gi RAM, 358 Go libres sur `/` (`nproc`, `free -h`, `df -h /`).
- Webcam : Jieli Technology `1224:2a25` « USB PHY 2.0: USB CAMERA ».
  - Vidéo : `/dev/v4l/by-id/usb-Jieli_Technology_USB_PHY_2.0-video-index0` (→ `/dev/video0` ;
    `video-index1` est le nœud métadonnées, pas une 2ᵉ caméra).
  - Micro : carte ALSA `U20` (`/proc/asound/cards`, actuellement n°2) → toujours désigner par
    nom : `hw:CARD=U20,DEV=0`, jamais par index.
  - Groupes hôte : `video` (gid via `getent group video`), `audio` (idem).
  - **Formats natifs de la caméra non encore relevés** (MJPEG/YUYV/H.264 ?) : à établir par le
    secteur media (`ffmpeg -f v4l2 -list_formats all -i …`).
- ffmpeg absent de l'hôte ; présent dans plusieurs images du lab. Image retenue pour le média :
  `bluenviron/mediamtx:<version>-ffmpeg` (alpine + ffmpeg), version épinglée par le secteur media.
- Scaffold fait par S1 : `peripheriques/` (template Django+Angular), backend 8101, frontend 4216,
  schéma `peripheriques` dans `infra/init/00_schemas.sql`, `.ports` : `peripheriques:8101:4216`,
  `.keycloak-client-opts` = mêmes groupes qu'`oauth-hub` (« au moins un groupe »),
  `frontend/e2e/cloisonnement.spec.ts` présent (copié du template).
- `scripts/open-bbox-ports2.sh` n'ouvre que du **TCP** (`protocol=tcp`, ligne ~102).
- Aucune app du lab ne publie encore d'UDP ni ne passe un périphérique (`devices:`) à un conteneur.

## 3. Carte des secteurs

| # | Secteur | Périmètre exclusif (chemins) | Critère d'acceptation |
|---|---|---|---|
| 1 | media | `peripheriques/media/**` | Conteneur MediaMTX seul détenteur des périphériques ; 3 chemins publiés (I1) ; segments horaires fMP4 écrits dans `/recordings`, purgés à 7 j ; WHEP + HLS servis ; **chaque** lecture/relecture/API passe par le hook I2 (vérifié avec un stub de hook qui refuse → la lecture échoue) ; kick de session WebRTC fonctionnel via API (I4) ; CPU mesuré en régime établi rapporté |
| 2 | backend | `peripheriques/backend/**` | Endpoints I3 + hook I2 implémentés et testés (tests Django) ; cas négatifs : token `admin-cli`, non-membre, sans droit, droit audio demandant `av`, ticket expiré, relecture avant `since`, hook sans `key` → tous refusés |
| 3 | frontend | `peripheriques/frontend/**` | Pages Direct / Enregistrements / Droits (admin) sur Foyer ; lecture WHEP réelle dans Chromium (`lab-runner`) ; page Droits masquée et inaccessible aux non-admins ; `cloisonnement.spec.ts` inchangé et passant |

Test à 3 critères : périmètre disjoint ☑ · ne parle aux autres que par I1–I5 ☑ · testable seul ☑
(media avec un hook stub ; backend avec tests Django + MediaMTX mocké **uniquement** pour l'API
de kick/playback ; frontend contre le backend réel une fois déployé, `page.route()` sinon).

## 4. Interfaces figées — **v6**

Conventions communes : horodatages **ISO 8601 UTC avec `Z`** dans toutes les API ; l'affichage
Europe/Paris est l'affaire du frontend. Un périphérique s'identifie par un **slug** `[a-z0-9-]+`.
Un seul périphérique pour l'instant : `webcam`.

### I1 — Chemins MediaMTX · producteur : media · consommateurs : backend, frontend
```
<slug>/video   H.264 seul
<slug>/audio   Opus seul
<slug>/av      H.264 + Opus   ← le SEUL chemin enregistré
```
- Un **unique** processus ffmpeg (`runOnInit` du chemin de publication, `runOnInitRestart: yes`)
  ouvre caméra + micro, encode une seule fois, publie les 3 chemins (muxer `tee` ou équivalent —
  jamais 3 encodages).
- Cible d'encodage : 1280×720, 15 i/s, H.264 ~1 Mbit/s, GOP 2 s ; Opus 48 kHz mono ~32 kbit/s.
  (Le secteur peut descendre en résolution si le CPU l'exige — à rapporter, pas un amendement.)
- Publication authentifiée : ffmpeg publie avec `MEDIA_PUBLISH_USER`/`MEDIA_PUBLISH_PASSWORD` (I5).
- Enregistrement de `<slug>/av` : `recordFormat: fmp4`, `recordSegmentDuration: 1h`,
  `recordDeleteAfter: 7d`, `recordPath` sous `/recordings/` (volume I6).

### I2 — Hook d'autorisation MediaMTX · producteur : backend · consommateur : media
```
POST http://peripheriques-backend:8000/api/media-auth/?key=<MEDIA_HOOK_KEY>
Content-Type: application/json
Corps : JSON natif MediaMTX (authMethod: http) —
  {"user","password","token","ip","action","path","protocol","id","query"}
Réponse : 200 = autorisé · 401 = refusé (corps ignoré)
```
(v5) Le backend ne journalise **jamais** la query string de cette URL (log d'accès gunicorn
compris) : `MEDIA_HOOK_KEY` ne doit apparaître dans aucun log.

Règles (backend), dans cet ordre :
1. `key` absent ou ≠ `MEDIA_HOOK_KEY` → 401 (l'URL est routée publiquement par Caddy : sans la
   clé, l'endpoint ne doit rien révéler).
2. `action == "publish"` → 200 ssi `user/password` == `MEDIA_PUBLISH_USER/PASSWORD` **et**
   `path` ∈ chemins I1 d'un périphérique connu.
3. `action ∈ {"playback","api","metrics","pprof"}` → 200 ssi `user/password` ==
   `MEDIA_INTERNAL_USER/PASSWORD` (seul le backend appelle playback/API ; le navigateur jamais).
4. `action == "read"` → `token` (JWT Keycloak, sans le préfixe `Bearer`) validé **exactement**
   comme `api/authentication.py` (signature, exp, `azp == KEYCLOAK_CLIENT_ID`, groupes requis,
   claim `email`) ; puis droit sur le chemin : `/video` ⇒ droit vidéo, `/audio` ⇒ droit audio,
   `/av` ⇒ les deux. **(v3) Être admin ne donne aucun droit de lecture** : seul un Grant compte. Sinon 401. Si 200 : enregistrer `(id, email, path, protocol)`
   pour le kick (I4).
5. Toute autre action → 401.

**À vérifier par media, sinon AMENDEMENT** : (a) la version épinglée transmet bien le bearer du
navigateur dans `token` pour WebRTC/WHEP **et** HLS ; (b) la query `?key=` de `authHTTPAddress`
est conservée ; (c) `id` du hook == id de session listé par `/v3/webrtcsessions/list` ;
(d) ~~HLS ré-interroge le hook à chaque requête~~ — **FAUX, constaté sur 1.21.1 (amendement
media-01)** : le hook n'est appelé qu'à l'ouverture de la session HLS ; la suite est servie sur
secret de session. La révocation HLS passe donc par `hlssessions/kick` (I4, v2).

Précision v2 : l'`id` reçu par le hook == `id` de `/v3/webrtcsessions/list` (protocol `webrtc`)
ou de `/v3/hlssessions/list` (protocol `hls`). Ce n'est **pas** l'uuid de l'en-tête `Location`
WHEP (ce dernier ne sert qu'au `DELETE` de fin de lecture côté navigateur).

### I3 — API REST du backend · producteur : backend · consommateur : frontend
Base publique : `/peripheriques-api` (Caddy, `SCRIPT_NAME`). Auth : `Authorization: Bearer`
Keycloak (template), sauf `stream` (ticket). Admin = groupe ∈ `PERIPHERIQUES_ADMIN_GROUPS`.

```
GET  /api/me/
  → {"email": str, "is_admin": bool}

GET  /api/devices/
  → [{"slug": "webcam", "label": str, "online": bool,
      "video": {"allowed": bool, "since": iso|null},
      "audio": {"allowed": bool, "since": iso|null}}]
  · since = début de la fenêtre de relecture ; null ⇔ allowed=false (v3 : plus de cas admin)
  · chacun (admin compris, v3) ne voit que les périphériques où il a au moins un droit
  · online = le chemin <slug>/av est "ready" côté MediaMTX (API I4)

GET    /api/grants/devices/         (admin)  → [{"slug", "label", "online": bool}]   (v4)
       · TOUS les périphériques connus, indépendamment de tout Grant — sert UNIQUEMENT à la
         gestion des droits (sélecteur de la page Droits). Ne donne aucun accès aux flux.
       · non-admin → 403
GET    /api/grants/                 (admin)  → [Grant]
POST   /api/grants/                 (admin)  {"email", "device", "video": bool, "audio": bool} → 201 Grant
       400 {"email": ["Aucun compte du lab avec cet email."]}   si absent du realm
       400 {"non_field_errors": ["Au moins un droit (vidéo ou micro) est requis."]}
       400 si (email, device) existe déjà → utiliser PATCH
PATCH  /api/grants/<id>/            (admin)  {"video"?: bool, "audio"?: bool} → 200 Grant
       false→true : <cap>_since = maintenant · true→false : <cap>_since = null + kick (I4)
       les deux à false → 400 (utiliser DELETE)
DELETE /api/grants/<id>/            (admin)  → 204 + kick (I4)
  Grant = {"id", "email", "device", "video": bool, "audio": bool,
           "video_since": iso|null, "audio_since": iso|null,
           "granted_by": email, "updated_at": iso}
  · email normalisé en minuscules ; comparé au claim email en minuscules

GET  /api/admin/materiel/                       (admin)  (v6)
  → contenu de backend/api/data/materiel.json, tel quel (format I7)
  · non-admin → 403 ; le contenu n'est JAMAIS embarqué dans le bundle Angular (sinon lisible
    par tout utilisateur de l'app) — c'est la raison d'être de cet endpoint
  · fichier absent/illisible → 503 {"detail": "Catalogue matériel indisponible."}

GET  /api/recordings/?device=<slug>&date=YYYY-MM-DD      (date en Europe/Paris)
  → [{"start": iso, "end": iso, "duration_s": int, "tracks": ["video","audio"]}]
  · segments de <slug>/av intersectant la journée, CLIPPÉS au plus tardif des `since`
    applicables (une piste dont le since est postérieur au segment n'apparaît pas dans tracks)
  · segment sans aucune piste autorisée → omis ; aucun droit sur device → 403

POST /api/recordings/ticket/  {"device", "start": iso, "duration_s": int (1..3600)}
  → {"url": "/peripheriques-api/api/recordings/stream/?ticket=<signé>", "expires_in": 300,
     "tracks": [...]}
  · 403 si start < since applicable ou aucune piste autorisée

GET  /api/recordings/stream/?ticket=<signé>         (pas de Bearer : <video src> ne peut pas en porter)
  → fMP4 progressif (Content-Type video/mp4, ou audio/mp4 si audio seul)
  · ticket : django.core.signing, 300 s, lie email+device+start+duration
  · les droits sont RE-vérifiés à l'ouverture (révocation après émission du ticket ⇒ 403)
  · pistes non autorisées retirées par remux `ffmpeg -c copy` (jamais de ré-encodage)
```

### I4 — API MediaMTX consommée par le backend · producteur : media · consommateur : backend
```
MEDIA_API_URL      = http://peripheriques-media:9997    (Basic MEDIA_INTERNAL_USER:PASSWORD)
  GET  /v3/paths/get/<slug>/av                → .ready
  GET  /v3/webrtcsessions/list                → items[].id, .path
  POST /v3/webrtcsessions/kick/<id>
  GET  /v3/hlssessions/list                   → items[].id, .path        (v2)
  POST /v3/hlssessions/kick/<id>                                         (v2)
  Kick (backend) : endpoint choisi selon le `protocol` enregistré par le hook
  (`webrtc` → webrtcsessions, `hls` → hlssessions) ; autre protocole → rien à couper.
MEDIA_PLAYBACK_URL = http://peripheriques-media:9996    (Basic idem)
  GET  /list?path=<slug>/av                   → [{"start","duration"}]
  GET  /get?path=<slug>/av&start=<iso>&duration=<s>&format=fmp4
```
Ports 9997/9996 **jamais** publiés sur l'hôte ni routés par Caddy.

### I5 — Clés `.env` (`peripheriques/.env`, lu par backend ET media — propriété S1)
```
MEDIA_PUBLISH_USER / MEDIA_PUBLISH_PASSWORD      ffmpeg → MediaMTX
MEDIA_INTERNAL_USER / MEDIA_INTERNAL_PASSWORD    backend → MediaMTX API/playback
MEDIA_HOOK_KEY                                   MediaMTX → backend (I2)
MEDIA_API_URL / MEDIA_PLAYBACK_URL               cf. I4
PERIPHERIQUES_ADMIN_GROUPS=developers
MEDIA_DEVICE_VIDEO=/dev/v4l/by-id/usb-Jieli_Technology_USB_PHY_2.0-video-index0
MEDIA_DEVICE_AUDIO=hw:CARD=U20,DEV=0
MEDIA_WEBRTC_PORT=8189                           UDP + TCP (ICE), publié sur l'hôte
MEDIA_WEBRTC_HOSTS=<WAN>,<LAN>                   webrtcAdditionalHosts (S1 le renseigne)
KEYCLOAK_ADMIN_CLIENT_ID / _SECRET               compte de service peripheriques-admin (view/query-users)
```
Le secteur media lit ces clés via `env_file` (substitution `MTX_*`/`${…}` dans sa config à sa
convenance) ; il **ne** les renomme pas.

### I6 — Composition Docker (`peripheriques/docker-compose.yml` — propriété S1)
S1 ajoute le service suivant (le secteur media fournit `media/Dockerfile` ou utilise l'image
directement, et `media/mediamtx.yml` ; il rapporte toute option compose manquante) :
```
media:
  build: ./media                     # ou image épinglée — media tranche, S1 recopie
  container_name: peripheriques-media
  env_file: .env
  devices: (v5) AUCUN — tout `devices:` est figé à la création du conteneur
  volumes (v5) : [ "/dev:/hostdev:ro",        # vidéo : suit les ré-énumérations USB en direct
                   "/dev/snd:/dev/snd" ]      # son : ALSA ne cherche que /dev/snd ; bind = vue live
  device_cgroup_rules (v5) : [ "c 81:* rmw", "c 116:* rmw" ]
  ffmpeg ouvre "/hostdev${MEDIA_DEVICE_VIDEO#/dev}" (lien by-id, résolu à CHAQUE lancement)
  group_add: [ <gid video>, <gid audio> ]
  volumes: [ "peripheriques-recordings:/recordings" ]
  ports: [ "8189:8189/udp", "8189:8189/tcp" ]
  networks: [ sso-net, dev-net ]
  labels (Caddy) :
    /peripheriques-webrtc/*  → 8889   (WHEP : POST /<slug>/<kind>/whep)
    /peripheriques-hls/*     → 8888   (HLS  : /<slug>/<kind>/index.m3u8)
volumes:
  peripheriques-recordings: { external: true, name: peripheriques-recordings }
backend: + volumes [ "peripheriques-recordings:/recordings:ro" ] (affichage espace disque)
```
URLs navigateur (frontend) : `/peripheriques-webrtc/<slug>/<kind>/whep` et
`/peripheriques-hls/<slug>/<kind>/index.m3u8`, bearer dans `Authorization`
(WHEP : fetch ; HLS : `hls.js` `xhrSetup`). `<kind>` ∈ `video|audio|av` choisi selon `/api/devices/`.
**v2** : en cours de lecture HLS, un 401/404 (session coupée par kick) = fin de lecture,
message « Le direct a été interrompu », **aucune** reconnexion automatique en boucle.

### I7 — Catalogue matériel (v6) · producteur : S1 (contenu) + backend (service) · consommateur : frontend
```
{"updated": "YYYY-MM-DD",
 "summary": [str, ...],                       // paragraphes de synthèse
 "items": [{
   "name": str, "brand": str,
   "family": "A" | "B" | "C",                 // A = sans fil via récepteur USB (UVC)
                                              // B = caméra IP Wi-Fi RTSP ; C = solution intermédiaire
   "connection": str, "power": str, "battery": bool,
   "night_vision": str|null, "tracking": str|null, "audio": str|null,
   "rtsp_or_uvc": str,
   "continuous_24_7": "oui" | "non" | "seulement sur secteur" | "non confirmé",
   "codec": str, "price_eur": str|null,
   "links":   [{"label": str, "url": str}],   // où acheter
   "sources": [str],                          // doc consultée
   "caveats": [str],
   "verdict": "recommandé" | "possible" | "déconseillé pour ce service"}]}
```
Le contenu est fourni par S1 (recherche vérifiée) ; le backend le copie tel quel dans
`backend/api/data/materiel.json` et le sert sans transformation. Le frontend ne présume d'aucun
modèle précis : il affiche ce que l'endpoint renvoie. Liens : `target="_blank"`,
`rel="noopener noreferrer"`, et seuls les schémas `https:` sont rendus cliquables.

## 5. Fichiers partagés — propriété exclusive de S1
`CLAUDE.md` · `README.md` · `.ports` · `.gitignore` · `.app-descriptions` · `infra/**` ·
`sso-lab/**` · `runner/**` · `scripts/**` · **`peripheriques/docker-compose.yml`** ·
**`peripheriques/.env`** · **`peripheriques/.env.example`** · **`peripheriques/.keycloak-*`** ·
`chantiers/peripheriques/CONTRAT.md`.

## 6. Ressources sérialisées (jamais deux en parallèle — 2 vCPU / 16 Go)
Builds Docker · `setup2.sh` / `recompose_docker.sh` · migrations · Playwright (`lab-runner`).
**Les S2 ne déploient pas** : ils rapportent la commande, S1 séquence.
**Exception encadrée** : le secteur media peut lancer **un** conteneur MediaMTX de test jetable
(`docker run --rm`, nom `peripheriques-media-test`, aucun port publié hors 127.0.0.1) pour
valider sa config ; jamais en même temps qu'un build. La caméra ne peut être ouverte que par un
seul processus : arrêter le conteneur de test avant de rendre la main.

## 7. Questions déjà tranchées (ne pas rouvrir)
- MediaMTX seul détenteur des périphériques — un V4L2 ne s'ouvre qu'une fois ; direct et
  enregistrement doivent consommer le même flux. Alternative écartée : ffmpeg par usage.
- Un seul encodage, 3 chemins — 2 vCPU. Alternative écartée : transcodage par lecteur.
- Seul `av` est enregistré ; la relecture audio-seul/vidéo-seul est un remux à la volée —
  évite de tripler le disque.
- ~~Admins : accès total sans Grant~~ — **remplacé en v3 (décision utilisateur)** : les admins
  gèrent les Grants (`/api/grants/`) mais n'ont aucun accès implicite aux flux ni à l'historique ;
  un admin qui veut voir/écouter se donne un Grant, qui ne vaut qu'à partir de son octroi.
- Cloisonnement d'accès à l'app = « au moins un groupe » (comme `oauth-hub`) ; les droits fins
  sont par email, en base.
- Vérification d'existence de l'email : API Admin Keycloak via compte de service
  `peripheriques-admin` (rôles `view-users`, `query-users`), même code que
  `lab-admin/backend/api/keycloak_admin.py:find_user_by_email`.
- Relecture servie par ticket signé court (300 s), pas de JWT en query string.
- Aucune dépendance à Celery : kick synchrone dans la requête PATCH/DELETE.
- (v2) HLS conservé comme repli (option A de media-01) ; options écartées : supprimer HLS (perte
  du repli si 8189 injoignable), accepter une révocation sans effet sur HLS (trou de sécurité).
- (v2) Image media : `bluenviron/mediamtx:1.21.1-ffmpeg@sha256:00ef3d1a…` ; caméra sans H.264
  natif → MJPEG décodé + x264 ; `group_add` 44 (video), 29 (audio).

## 8. Questions volontairement ouvertes (le secteur tranche et documente)
- Version MediaMTX épinglée, preset x264, profil H.264 compatible WebRTC — media.
- Format natif lu sur la caméra (MJPEG → décodage, ou H.264 natif → `-c:v copy` si possible) — media.
- Stockage de la table des sessions autorisées (I2 §4) et sa purge — backend.
- Ergonomie des pages (frise horaire, sélection de journée…) — frontend, dans les règles Foyer.
