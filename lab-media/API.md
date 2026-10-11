# lab-media — API des apps (contrat `chantiers/lab-media`, I3)

Ce document fait foi pour tout ce qu'une app échange avec `lab-media`. Il est écrit à partir de
ce que le code rend (`auth/labmediaauth/server.py`) ; chaque forme de réponse ci-dessous est
recopiée d'une exécution réelle de `verify.sh` (MediaMTX 1.21.1), pas d'une intention.

Une app a quatre points de contact avec la brique, et seulement ceux-là :

| # | Quoi | Où | Authentifié par |
|---|---|---|---|
| 1 | **API de contrôle** (état, sessions, expulsion, relecture) | `http://lab-media-auth:9100` — `dev-net` seulement | identifiants de contrôle de l'app (HTTP Basic) |
| 2 | **Hook de lecture** : `lab-media` appelle l'app à chaque demande de lecture | URL de l'app, déclarée au registre | clé de hook de l'app (`?key=`) |
| 3 | **Lecture par un navigateur** | `https://<DOMAIN>/lab-media-webrtc/<chemin>/whep` et `/lab-media-hls/<chemin>/index.m3u8` | ce que le hook de l'app accepte (un jeton `Bearer`) |
| 4 | **RTSP** (publier un flux, ou le lire depuis un backend) | `rtsp://lab-media:8554/<chemin>` — `dev-net` | publication : identifiants de publication de l'app ; lecture : le hook de l'app |

L'API et le serveur de relecture de MediaMTX (ports 9997 et 9996) ne sont pas joignables par une
app : ils n'écoutent que sur le réseau interne de la brique, et leurs identifiants n'existent
que dans la mémoire de `lab-media-auth`.

**Règle unique de cloisonnement** : une app ne voit et n'agit que sous **ses préfixes** (registre
`lab-media/registry.json`). Tout ce qui est hors de ses préfixes répond comme ce qui n'existe
pas (`404`), sans distinction possible.

---

## 1. API de contrôle

- Base : `http://lab-media-auth:9100` (nom de conteneur, réseau `dev-net`). Jamais routée par Caddy.
- Authentification : `Authorization: Basic <utilisateur:mot de passe de contrôle>`, sur **chaque**
  requête. Sans identifiants, ou avec de mauvais : `401` (après 0,5 s), corps
  `{"error": "unauthorized", "detail": "…"}`. Les identifiants de publication n'y donnent aucun accès.
- Réponses : JSON (`Cache-Control: no-store`), sauf la lecture d'une plage (flux binaire) et
  l'expulsion réussie (`204`, sans corps).
- Erreurs : `{"error": "<code>", "detail": "<phrase>"}`. Codes : `unauthorized` (401),
  `unknown_path` (404), `unknown_session` (404), `no_recording` (404), `not_found` (404, route
  inconnue), `bad_request` (400), `bad_protocol` (400), `not_a_reader` (409),
  `media_unavailable` (502 : MediaMTX injoignable ou réponse inattendue).
- `GET /healthz` → `200 {"status": "ok"}`, sans authentification (sonde de vie du conteneur ;
  ne dit rien de MediaMTX).
- Coût mesuré : 16 à 20 ms par appel (médiane, 30 appels par route).

### 1.1 État des chemins

**`GET /v1/paths`** — tous les chemins déclarés sous les préfixes de l'app.

```json
{"items": [
  {"path": "webcam/av", "ready": true, "readyTime": "2026-10-11T01:55:44.232874881Z",
   "tracks": ["H264", "Opus"], "readers": 1, "inboundBytes": 348844,
   "source": "publisher", "recorded": true},
  {"path": "webcam/video", "ready": false, "readyTime": null, "tracks": [], "readers": 0,
   "inboundBytes": 0, "source": "publisher", "recorded": false}
]}
```

**`GET /v1/paths/<chemin>`** — un seul chemin, même objet que ci-dessus (sans enveloppe).
`404 unknown_path` si le chemin n'est pas déclaré ou n'est pas sous un préfixe de l'app.

| Champ | Sens |
|---|---|
| `path` | nom du chemin |
| `ready` | un flux est publié (ou tiré) et lisible **maintenant** |
| `readyTime` | début de la publication en cours (RFC 3339, nanosecondes) ; `null` si non prêt. Ne change pas tant que la publication n'est pas coupée |
| `tracks` | codecs des pistes, ex. `["H264", "Opus"]` ; `[]` si non prêt |
| `readers` | nombre de lecteurs branchés sur le chemin, tels que MediaMTX les compte |
| `inboundBytes` | octets reçus depuis le début de la publication |
| `source` | `"publisher"` (quelqu'un publie) ou `"pull"` (flux RTSP distant tiré par la brique) |
| `recorded` | le chemin est enregistré (registre) |

### 1.2 Sessions et expulsion

**`GET /v1/sessions`** — sessions en cours sur les chemins de l'app. Filtres facultatifs :
`?protocol=webrtc|hls|rtsp` (sinon les trois) et `?path=<chemin>` (`404 unknown_path` si ce
n'est pas un chemin de l'app ; `400 bad_protocol` si le protocole est inconnu).

```json
{"items": [
  {"protocol": "hls", "id": "26e8dca8-ef59-4cf5-adf0-10530d835c41", "path": "webcam/av",
   "state": "read", "created": "2026-10-11T01:56:48.001168818Z",
   "remoteAddr": "192.168.48.3:54626", "inboundBytes": 0, "outboundBytes": 409},
  {"protocol": "webrtc", "id": "a4484d40-ca3e-4e60-b9b1-fffc5090c9f3", "path": "webcam/av",
   "state": "read", "created": "2026-10-11T01:55:46.054426274Z",
   "remoteAddr": "192.168.48.3:36276", "inboundBytes": 8186, "outboundBytes": 1774442},
  {"protocol": "rtsp", "id": "b760835d-8f03-4257-b653-96e3999c6ac4", "path": "webcam/av",
   "state": "publish", "created": "2026-10-11T01:50:28.940536725Z",
   "remoteAddr": "172.31.0.8:51046", "inboundBytes": 3702553, "outboundBytes": 0}
]}
```

| Champ | Sens |
|---|---|
| `id` | **l'`id` que le hook de l'app a reçu** quand il a autorisé cette session. Ce n'est pas l'uuid de l'en-tête `Location` d'une réponse WHEP, ni le `?session=` des URL HLS |
| `state` | `"read"` ou `"publish"` ; toujours `"read"` en HLS |
| `remoteAddr` | adresse vue par MediaMTX : celle de Caddy pour WHEP et HLS, pas celle du navigateur |

Ni `user`, ni `query`, ni `userAgent` ne sont rendus (la query peut porter un jeton).

**`POST /v1/sessions/<protocol>/<id>/kick`** — expulse une session **de lecture**. Corps vide.

| Réponse | Cas |
|---|---|
| `204` | expulsée |
| `404 unknown_session` | id inconnu, session déjà terminée, **ou session d'une autre app** |
| `409 not_a_reader` | la session est une publication : l'API ne coupe pas un flux entrant |
| `400 bad_protocol` | protocole hors `webrtc`, `hls`, `rtsp` |

Une révocation de droit **doit** expulser, dans les deux protocoles : refuser au hook ne coupe
rien de ce qui est déjà ouvert (voir §2, « quand le hook est appelé »).

### 1.3 Relecture

**`GET /v1/recordings?path=<chemin>[&start=<RFC 3339>][&end=<RFC 3339>]`** — plages enregistrées.
Les segments contigus sont fusionnés en une plage ; `start`/`end` rognent la liste.

```json
[{"start": "2026-10-11T01:54:43.036558Z", "duration": 3.001},
 {"start": "2026-10-11T01:55:44.236485Z", "duration": 73.925}]
```

`duration` en secondes. **Toujours `200`** : `[]` quand rien n'est enregistré (chemin non
enregistré, jamais publié, ou filtre hors de toute plage). `404 unknown_path` si `path` est absent
ou n'est pas un chemin de l'app ; `400 bad_request` si `start`/`end` n'est pas un horodatage
RFC 3339 **avec fuseau** (`Z` ou `±hh:mm`).

**`GET /v1/recordings/get?path=<chemin>&start=<RFC 3339>&duration=<secondes>[&format=fmp4|mp4]`** —
le média de la plage, en flux (`Content-Type: video/mp4`, longueur inconnue, la connexion se ferme
à la fin). `format` vaut `fmp4` par défaut. `404 no_recording` si aucune donnée sur cette plage ;
`400 bad_request` si `start` ou `duration` est mal formé ; `404 unknown_path` hors de ses chemins.
Le flux porte **toutes** les pistes du chemin : retirer une piste reste l'affaire de l'app.

---

## 2. Hook de lecture de l'app

Chaque demande de lecture d'un chemin sous un préfixe de l'app lui est relayée :

```
POST <read_hook de l'app au registre>?key=<clé de hook de l'app>
Content-Type: application/json
{"ip": "192.168.48.3", "user": "", "password": "", "token": "<jeton>", "action": "read",
 "path": "webcam/av", "protocol": "hls", "id": "0c0c1eba-f412-4813-ac23-ac8d84a39164",
 "query": "", "userAgent": "Mozilla/5.0 …"}
```

- Le corps est celui de MediaMTX, **octet pour octet**. `action` vaut toujours `read` : la
  publication, l'API, la relecture et les métriques de MediaMTX ne parviennent plus jamais à
  l'app (`lab-media-auth` les tranche lui-même).
- **`200` autorise. Toute autre réponse refuse** (`204` compris), de même qu'un hook injoignable
  ou qui ne répond pas en `LAB_MEDIA_READ_HOOK_TIMEOUT_S` (3 s, délai total). Échec fermé.
- `token` : le jeton du navigateur (`Authorization: Bearer …`, sans le préfixe) en WHEP et en HLS.
  En RTSP, il n'y a pas d'en-tête : le mot de passe de l'URL arrive dans `password` **et** dans
  `token` (`rtsp://x:<jeton>@lab-media:8554/<chemin>`).
- `id` : identifiant de la session. C'est lui qu'il faut garder pour l'expulser (§1.2).
- **Quand le hook est appelé** :
  - WebRTC/WHEP : à l'ouverture de la session. Une session expulsée doit repasser par le hook.
  - HLS : **à l'ouverture seulement** (playlist `index.m3u8`). Sous-playlists et segments sont
    ensuite servis sur le secret de session, sans jeton et sans appel au hook. Seule l'expulsion
    coupe un lecteur HLS ; sa requête suivante reçoit alors `401`.
  - RTSP : deux appels par connexion — le premier sans identifiants (avant le défi `401`), le
    second avec.
- Au plus 8 appels simultanés vers le hook d'une app ; au-delà, refus immédiat (protège les
  autres apps d'un hook qui pend).
- L'app doit continuer de vérifier `key` : son URL de hook reste joignable par toute app de
  `dev-net`.

## 3. Lecture par un navigateur

| Protocole | URL | Jeton |
|---|---|---|
| WebRTC (WHEP) | `POST https://<DOMAIN>/lab-media-webrtc/<chemin>/whep` (offre SDP) | `Authorization: Bearer <jeton>` |
| HLS | `GET https://<DOMAIN>/lab-media-hls/<chemin>/index.m3u8` | `Authorization: Bearer <jeton>` sur la playlist d'ouverture (`hls.js` : `xhrSetup`) |

Caddy retire le préfixe et réécrit les `Location` que MediaMTX renvoie (session WHEP ; redirection
`?cookieCheck=1` de HLS → `/lab-media-hls/<chemin>/index.m3u8?cookieCheck=1`). Média ICE : port
8189 UDP et TCP de l'hôte.

## 4. RTSP

- **Publier** (app dont l'entrée de registre porte `"publish": true`) :
  `rtsp://<utilisateur>:<mot de passe de publication>@lab-media:8554/<chemin>`, TCP seulement, sur
  un chemin déclaré au registre sous un préfixe de l'app. Tout autre cas est refusé en `401`
  (`400` pour un chemin non déclaré) : mauvais identifiants, préfixe d'une autre app, chemin
  tiré, identifiants de contrôle.
- **Publication WebRTC (WHIP) : fermée**, avec ou sans identifiants (`401`).
- **Lire depuis un backend** : `rtsp://x:<jeton>@lab-media:8554/<chemin>` — passe par le hook de
  l'app propriétaire comme toute lecture.

---

## 5. Ce que `peripheriques` appelle aujourd'hui, et ce qui le remplace

Référence : `deploiement/peripheriques/backend/api/media_client.py`, `kick.py`, `hook.py`
(contrat `chantiers/peripheriques`, I2 et I4).

| Aujourd'hui (MediaMTX en direct) | Remplacé par | À adapter côté app |
|---|---|---|
| `MEDIA_API_URL=http://peripheriques-media:9997` et `MEDIA_PLAYBACK_URL=http://peripheriques-media:9996`, Basic `MEDIA_INTERNAL_USER:PASSWORD` | une seule base `http://lab-media-auth:9100`, Basic = identifiants de contrôle de l'app | les deux clés pointent sur la même base ; `MEDIA_INTERNAL_USER/PASSWORD` peuvent garder leurs valeurs (elles deviennent les identifiants de contrôle, à recopier dans `lab-media/.env`) |
| `GET /v3/paths/get/<slug>/av` → `.ready` | `GET /v1/paths/<slug>/av` → `.ready` | chemin d'URL ; un chemin inconnu rend `404` (comme avant) |
| `GET /v3/webrtcsessions/list` et `GET /v3/hlssessions/list` (paginés, `items[].id`, `.path`) | `GET /v1/sessions?protocol=webrtc` et `?protocol=hls` → `items[].id`, `.path` | plus de pagination (`page`, `itemsPerPage`, `pageCount` disparaissent) ; la liste ne contient que les sessions de l'app |
| `POST /v3/webrtcsessions/kick/<id>`, `POST /v3/hlssessions/kick/<id>` → `200`, ou `404` si déjà terminée | `POST /v1/sessions/webrtc/<id>/kick`, `POST /v1/sessions/hls/<id>/kick` → **`204`**, ou `404` | le succès passe de `200` à `204` ; `404` garde son sens (« but atteint ») |
| `GET /list?path=<slug>/av` → `[{"start","duration","url"}]`, **`404` si vide** | `GET /v1/recordings?path=<slug>/av` → `[{"start","duration"}]`, **`200 []` si vide** | le cas `404 → []` devient inutile (un `404` signifie maintenant « pas un chemin de l'app ») ; le champ `url` n'existe plus (il n'était pas lu) ; horodatages toujours à la nanoseconde près |
| `GET /get?path=&start=&duration=&format=fmp4`, flux | `GET /v1/recordings/get?path=&start=&duration=&format=fmp4`, flux | chemin d'URL ; même corps (`stream=True` convient) |
| Hook `POST /api/media-auth/?key=` : règles 2 (`publish`), 3 (`api`/`playback`/…), 4 (`read`) | seul `read` arrive encore | les règles 2 et 3 deviennent du code mort ; `MEDIA_PUBLISH_USER/PASSWORD` ne servent plus à l'app ; la règle 4 et l'enregistrement `(id, email, path, protocol)` sont inchangés |
| URL navigateur `/peripheriques-webrtc/<slug>/<kind>/whep`, `/peripheriques-hls/<slug>/<kind>/index.m3u8` | `/lab-media-webrtc/webcam/<kind>/whep`, `/lab-media-hls/webcam/<kind>/index.m3u8` | préfixes dans `core/api.service.ts` (`whepUrl`, `hlsUrl`) |
| Volume `peripheriques-recordings` monté en lecture seule dans le backend | rien : aucun montage | aucun code de `backend/` ne lit `/recordings` (recherche dans les sources) ; le retirer |
| Service `media` et volume dans le compose de l'app | services de `lab-media/` | retirés du compose de l'app à la bascule |

Les chemins restent `webcam/av`, `webcam/video`, `webcam/audio`.

## 6. État de preuve

« Prouvé » = constaté en réel par `bash lab-media/verify.sh` (identifiant du contrôle entre
parenthèses), sur MediaMTX 1.21.1, avec deux apps fictives et des sources synthétiques.
« Codé » = écrit, non exercé par un essai.

| Fonction | État |
|---|---|
| Authentification de contrôle : sans identifiants, mauvais mot de passe, mot de passe d'une autre app, identifiants de publication → 401 | prouvé (C1–C4) |
| `GET /v1/paths` limité aux chemins de l'app | prouvé (C5, C6) |
| `GET /v1/paths/<chemin>` : prêt, pistes, source tirée ; chemin d'autrui ou inexistant → 404 identique | prouvé (C7–C10) |
| Aucune route de MediaMTX n'est relayée (`/v3/…` → 404) | prouvé (C11) |
| `GET /v1/sessions` : HLS, WebRTC, RTSP ; `id` = id reçu par le hook ; l'autre app ne les voit pas | prouvé (K1, K2, W1, W2, W4) |
| Filtres `?protocol=` et `?path=` | prouvé (K1, W1) |
| Expulsion HLS : 204, session disparue, lecteur coupé (401) ; par l'autre app → 404 | prouvé (K3, K5, K6) |
| Expulsion WebRTC : 204, session disparue, le lecteur repasse par le hook ; par l'autre app → 404 | prouvé (W4, W5, W2) |
| Expulsion d'une publication → 409 | prouvé (W6) |
| Expulsion d'une session RTSP de lecture | codé |
| `GET /v1/recordings` : plages ; vide → `[]` ; filtre `start`+`end` ; `start` mal formé → 400 ; chemin d'autrui → 404 | prouvé (E1, E6, E7, E8, E10, E11) |
| `GET /v1/recordings/get` en `fmp4` : fMP4 lisible (H.264 + Opus) ; autre app → 404 ; plage vide → 404 | prouvé (E2–E5, E9) |
| `GET /v1/recordings/get` en `format=mp4` | codé |
| Plus de 1000 sessions ou chemins (pagination interne) | codé |
| Hook de lecture : relais à l'app propriétaire seule, corps intact, clé de l'app | prouvé (L1–L3, L6) |
| Hook en panne : arrêté, `500`, suspendu (refus en 3,0 s), puis rétabli | prouvé (D1, H1, H3, H6, H5) |
| Plafond de 8 appels simultanés par app | prouvé hors réseau (test unitaire `RelayTests`) |
| Hook d'app en `https://` | codé |
| Lecture RTSP par jeton en mot de passe | prouvé (L9, L10) |
| Lecture WHEP : signalisation, ICE, média (octets émis en hausse), à travers Caddy | prouvé avec un client WHEP non navigateur (W1, W3) |
| **Image vidéo H.264 dans un vrai navigateur** | **non prouvé** : à valider par l'utilisateur à la bascule |
