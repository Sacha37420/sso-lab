# lab-media — la brique des flux audio/vidéo du lab

`lab-media` est le point d'entrée unique des flux audio et vidéo du lab, comme `postgres` l'est pour les données et `storage` pour les fichiers. Il reçoit des flux, les diffuse (WebRTC et HLS) et les enregistre. Il ne décide jamais qui peut lire : cette décision reste à l'app qui possède le flux.

- Contrats : `chantiers/lab-media/CONTRAT.md` ; webcams : `chantiers/webcams/CONTRAT.md`.
- API des apps (fait foi) : [`API.md`](API.md).
- Bascule depuis `peripheriques` : [`BASCULE.md`](BASCULE.md).
- Preuve rejouable : `bash lab-media/verify.sh` (environ 7 minutes, pile isolée `lmt-*`, faux matériel, la vraie caméra n'est ni montée ni ouverte).

## Les pièces

```
                         réseau « internal » (créé ici, sans sortie)
  capture ──RTSP──▶  MediaMTX (lab-media)  ──hook──▶  lab-media-auth ── lit /sys : webcams
 (un ffmpeg par        │  ▲   API 9997, relecture 9996 ◀── (identifiants en mémoire)
  webcam, d'après ◀────┼──┼──────────── /state/plan ◀──────── (inventaire, plan, mediamtx.yml)
  le plan)             │  │
                       │  │
   sso-net : Caddy ────┘  └──── dev-net : apps (RTSP 8554)
   /lab-media-webrtc/*, /lab-media-hls/*          apps ──▶ lab-media-auth:9100 (API de contrôle)
                                                  lab-media-auth ──▶ hook de lecture de chaque app
```

| Conteneur | Rôle |
|---|---|
| `lab-media` | MediaMTX 1.21.1, épinglé par digest. `authMethod: http`, `authHTTPExclude` vide : chaque action passe par `lab-media-auth`. |
| `lab-media-auth` | Python, bibliothèque standard seule. Répond au hook de MediaMTX, expose l'API de contrôle des apps, découvre les webcams (sysfs), tient leur inventaire et le plan de capture, et écrit la configuration de MediaMTX à partir du registre et de l'inventaire. |
| `lab-media-capture` | Superviseur + un ffmpeg par webcam du plan (au plus `MEDIA_CAPTURE_MAX`) : ouvre la webcam (et son micro s'il y en a un), encode une fois, publie `webcam/<id>/{av,video[,audio]}`. Profil Compose `capture` : la brique tourne sans lui. |

| Fichier | Rôle |
|---|---|
| `docker-compose.yml` | Les trois services, leurs trois réseaux, les volumes `config` et `state`. |
| `registry.json` | Le registre : apps, préfixes, sources, chemins, section `devices` (préfixe des webcams, rétention, entrée héritée). Aucun secret. |
| `.env` (non versionné) | Secrets et réglages ; modèle : `.env.example`. |
| `auth/labmediaauth/` | `registry.py` (registre, génération de `mediamtx.yml`), `server.py` (hook et API), `devices.py` (découverte des webcams, inventaire, plan). |
| `auth/mediamtx.base.yml` | Partie fixe de la configuration de MediaMTX. |
| `mediamtx/` | Image commune à MediaMTX et à la capture : `entrypoint.sh`, `capture.sh` (superviseur), `capture-one.sh` (une webcam). |
| `verify.sh`, `verify/` | La preuve rejouable : apps fictives, sources synthétiques, faux matériel (`fakehw.py`, `compose.test.yml`). |

## Qui décide quoi

| Action | Décidée par | Règle |
|---|---|---|
| `publish` | `lab-media-auth` | Identifiants de publication de l'app propriétaire du préfixe, ou d'une source interne sur ses chemins. RTSP seulement. Chemin déclaré au registre. |
| `read` | **l'app propriétaire du préfixe** | `lab-media-auth` relaie le corps de MediaMTX à son hook. Seul un `200` reçu en moins de 3 s autorise. |
| `api`, `playback`, `metrics`, `pprof` | `lab-media-auth` | Identifiants internes, tirés au hasard à chaque démarrage, jamais écrits nulle part. |
| Toute autre action | — | Refusée. |

**Ne jamais utiliser `authHTTPExclude`.** Sur MediaMTX 1.21.1, une action exclue est autorisée sans aucun contrôle, WHIP compris (essai réel du 2026-10-11). Le générateur de configuration refuse de démarrer si la base en contient.

## Ajouter une app

1. Dans `registry.json`, une entrée sous `apps` :
   ```json
   "mon-app": {"prefixes": ["mon-app"], "read_hook": "http://mon-app-backend:8000/api/media-auth/", "publish": true}
   ```
   - `prefixes` : un chemin appartient à l'app s'il est égal à un préfixe ou s'il commence par `<préfixe>/`. Deux apps ne peuvent pas avoir de préfixes emboîtés.
   - `read_hook` : URL du hook de lecture, sans query (forme : `API.md` §2).
   - `publish` : `true` seulement si l'app pousse elle-même des flux.
2. Dans `registry.json`, ses chemins sous `paths` (tout chemin non déclaré est refusé) :
   ```json
   "mon-app/cam": {"record": true, "segment": "1h", "delete_after": "7d"},
   "mon-app/ip":  {"source_env": "LAB_MEDIA_PULL_MON_APP_IP"}
   ```
   - `record`, `segment`, `delete_after` : enregistrement en fMP4 sous `/recordings/<chemin>/`.
   - `source_env` : le chemin est **tiré** depuis une caméra IP ; la clé nommée porte l'URL `rtsp://…` dans `.env`. `on_demand: true` ne tire que lorsqu'un lecteur est là.
3. Dans `.env`, ses secrets, sous des noms dérivés du nom de l'app (majuscules, `-` devient `_`) :
   ```
   LAB_MEDIA_APP_MON_APP_HOOK_KEY=…            clé présentée au hook de l'app (?key=)
   LAB_MEDIA_APP_MON_APP_CONTROL_USER=…        identifiants de l'API de contrôle
   LAB_MEDIA_APP_MON_APP_CONTROL_PASSWORD=…
   LAB_MEDIA_APP_MON_APP_PUBLISH_USER=…        seulement si "publish": true
   LAB_MEDIA_APP_MON_APP_PUBLISH_PASSWORD=…
   ```
   Secrets : `[A-Za-z0-9_-]`, 16 caractères au moins. Un nom d'utilisateur ne sert qu'à une entrée.
4. Appliquer : `docker compose -f lab-media/docker-compose.yml up -d --no-build --force-recreate --no-deps auth` (seul `lab-media-auth` est recréé). MediaMTX recharge sa configuration à chaud ; les publications et l'enregistrement en cours ne sont pas coupés (prouvé : contrôles G1 à G3).

`lab-media-auth` refuse de démarrer, en disant pourquoi dans son journal, si le registre est incohérent : chemin sans propriétaire, préfixes en conflit, secret absent, trop court ou resté à `CHANGE_ME`, clé inconnue.

## Sources

- **Webcams de l'hôte** (`capture`, chantier webcams) :
  - **Découverte** par `lab-media-auth`, toutes les `LAB_MEDIA_SCAN_S` secondes (2), en lisant `/sys` seulement : aucun nœud n'est ouvert. Une webcam = un appareil USB dont une interface de classe vidéo (`0e`) porte un nœud video4linux d'index 0 (capture ; l'index 1 est celui des métadonnées). Son micro = une carte son du **même appareil USB** ayant un PCM de capture. Une nouvelle webcam doit être vue deux passages de suite (la carte son suit parfois le nœud vidéo d'un instant). Identifiant : `API.md` §1.4.
  - **Inventaire** : `/state/inventory.json` (volume `state`), écrit par `lab-media-auth` seul : toutes les webcams déjà vues, leur réglage d'enregistrement, les chemins oubliés gardés jusqu'à la purge de leurs enregistrements. Illisible ⇒ `lab-media-auth` refuse de démarrer (jamais de remise à zéro silencieuse).
  - **Plan** : `/state/plan`, une ligne par webcam à capturer : `<id> <port USB> <micro 0|1> <base des chemins>`. Au plus `MEDIA_CAPTURE_MAX` (2 ; de 0 à 8). Une webcam déjà capturée garde sa place ; une place libérée va à la webcam en attente vue le plus tôt. Le nom de produit et le numéro de série — choisis librement par l'appareil — n'entrent ni dans le plan, ni dans un chemin, ni dans le journal : seulement dans `model`/`serial` de l'API, nettoyés et bornés.
  - **Capture** : `capture.sh` lit le plan chaque seconde (et revalide chaque champ, et le plafond) ; un travailleur `capture-one.sh` par ligne, donc un ffmpeg par webcam. Ligne disparue (débranchement) ou changée ⇒ travailleur arrêté, son ffmpeg tué **et attendu** ; ffmpeg mort ⇒ relancé après 3 s. Les nœuds sont retrouvés à chaque lancement depuis le port USB (`/sys/bus/usb/devices/<port>`), après contrôle du `vendor:product`, de la classe d'interface, de l'index et du majeur:mineur de `/hostdev/videoN`.
  - **Encodage** : MJPEG 1280x720 décodé, H.264 baseline 15 i/s 1 Mbit/s ; après un échec rapide, nouvel essai au format par défaut du pilote. Micro : `plughw:<carte>,<pcm>`, Opus mono 32 kbit/s. **Sans micro, vidéo seule** : `av` et `video` en H.264 seul, aucun chemin `audio`.
  - **Enregistrement** : par webcam, coupé par défaut, réglé par `PATCH /v1/devices/<id>` (`API.md` §1.4) ; changé à chaud dans `mediamtx.yml`, sans couper la publication.
  - **`webcam-ancienne`** : la caméra d'avant la découverte, déclarée au registre (`devices.legacy`) sur les chemins `webcam/{av,video,audio}`. Jamais capturée, jamais enregistrée ; ses enregistrements restent relisibles jusqu'à leur purge (7 jours).
  - Toujours **aucun `devices:`** (il fige un numéro de périphérique à la création du conteneur) : `/dev` de l'hôte est monté en lecture seule sous `/hostdev` (vue live) et `/dev/snd` en bind. `device_cgroup_rules` : `c 81:* rmw` (video4linux) et `c 116:* rmw` (ALSA), rien d'autre. Le `:ro` ne protège pas un nœud caractère : seules ces règles limitent ce que le conteneur peut ouvrir.
  - `MEDIA_DEVICE_VIDEO` et `MEDIA_DEVICE_AUDIO` ne sont plus lues : présentes dans `.env`, elles sont ignorées.
  - `MEDIA_CAPTURE_MODE=testsrc` remplace chaque webcam du plan par une mire (et un bip si elle a un micro) : mêmes chemins, aucun périphérique ouvert.
  - Ce conteneur n'est que sur le réseau interne.
- **Publiée par une app** : RTSP vers `lab-media:8554`, identifiants de publication de l'app.
- **Tirée** : `source_env` au registre.

## Enregistrements

- Volume `lab-media-recordings`, `external` (à créer une fois : `docker volume create lab-media-recordings`). Seul `lab-media` le monte.
- Forme : `/recordings/<chemin>/AAAA-MM-JJ_HH-MM-SS-µµµµµµ.mp4`, fMP4, heure UTC. C'est la forme de `peripheriques-recordings` : les fichiers existants se copient tels quels.
- La purge (`delete_after`) se compte depuis le **début** du segment. MediaMTX la lance toutes les 30 minutes, ou toutes les `delete_after / 2` si c'est plus court.
- Une app lit ses enregistrements par l'API (`API.md` §1.3), jamais par un montage.

## Cycle de vie (mesuré)

Les deux conteneurs sont séparés. MediaMTX ne dépend de `lab-media-auth` qu'au démarrage.

| Événement | Continue | S'arrête |
|---|---|---|
| App autorité arrêtée, ou hook en `500`, ou hook suspendu | Publication, enregistrement, lecteurs déjà ouverts, les autres apps | Toute **nouvelle** lecture des flux de cette app (refus en 3 s au plus) |
| `lab-media-auth` arrêté | Publications en cours, enregistrement, lecteurs WebRTC déjà ouverts (octets toujours émis) | Toute nouvelle lecture, toute nouvelle publication (ffmpeg ne peut pas se reconnecter), l'API de contrôle : ni état, ni **expulsion** |
| `lab-media-auth` redémarré | Tout ce qui précède ; MediaMTX ne redémarre pas | Rien de plus ; la lecture reprend dès son retour |
| `lab-media-auth` arrêté ou recréé (webcams) | La capture des webcams du plan (le plan est sur disque ; même ffmpeg, prouvé X8, G4), l'inventaire et les réglages d'enregistrement (volume `state`, prouvé M30) | La découverte : un branchement n'est vu, et l'API `/v1/devices` ne répond, qu'à son retour. Une webcam débranchée pendant l'arrêt perd son flux (ffmpeg échoue, le travailleur attend son retour sur le port) |
| `lab-media-capture` arrêté | Inventaire, découverte, API | Toute publication de webcam ; après 20 s, les webcams branchées passent en `error` |
| MediaMTX redémarré | — | Toutes les sessions. Les publications reviennent d'elles-mêmes (`capture.sh` boucle ; une app qui publie doit faire de même) |

Conséquence : pendant un arrêt de `lab-media-auth`, une révocation de droit ne peut pas couper un lecteur déjà ouvert. Garder cet arrêt court (un redémarrage prend quelques secondes).

## Réseau

- `lab-media` : `internal`, `dev-net`, `sso-net`. Seul port publié sur l'hôte : ICE 8189, UDP et TCP.
- L'API (9997) et la relecture (9996) de MediaMTX n'écoutent que sur l'adresse du réseau `internal` : depuis `dev-net` et `sso-net`, la connexion est refusée.
- `lab-media-auth` : `internal` (hook, port 9000, lié à cette seule adresse) et `dev-net` (API de contrôle, port 9100). Il n'est pas sur `sso-net` et ne porte aucun label Caddy.
- `lab-media-capture` : `internal` seulement.

## Journaux

- `lab-media-auth` écrit une ligne JSON par décision : action, chemin, protocole, id de session, adresse, app, verdict, raison, durée. Jamais de mot de passe, de jeton, de clé, de nom d'utilisateur ni de query.
- **Limite connue** : quand `lab-media-auth` est injoignable, MediaMTX écrit l'URL complète du hook dans son propre journal, donc `LAB_MEDIA_HOOK_KEY`. Cette clé ne protège qu'un port joignable depuis le seul réseau interne ; le journal n'est lisible que par qui a accès à Docker. `peripheriques-media` a le même comportement aujourd'hui avec `MEDIA_HOOK_KEY`.

## Pièges constatés

- MediaMTX répond `400` (et non `404`) à une demande de liste sur un chemin qui n'a encore rien enregistré (`lstat … no such file or directory`). L'API de contrôle rend `[]` dans ce cas.
- Redemander `index.m3u8` ouvre une **nouvelle** session HLS et repasse par le hook ; ce sont les sous-playlists qui sont servies sans contrôle.
- Le `?session=` des URL HLS est un secret de session, pas l'`id` de la session.
- MediaMTX retarde tout refus de 0 à 4 s (anti-force-brute) : un refus mesuré de bout en bout dure donc plus que le délai du relais.
- Sous `cap_drop: ALL`, root ne lit pas un fichier d'un autre compte : `lab-media` reçoit le groupe 10001 pour lire le `mediamtx.yml` écrit par `lab-media-auth`.
- Un `env_file` passe au conteneur **toutes** les clés du fichier : une variable réservée à Compose ne doit pas porter le nom d'un réglage lu par le service (constaté : un chemin de l'hôte lu comme chemin du conteneur).
- MediaMTX 1.21.1 **ignore** une modification de son fichier de configuration survenue moins d'environ 1 s après la précédente (mesuré : deux écritures à 0,5 s ou 1,0 s d'écart ⇒ un seul rechargement, la seconde est perdue, sans message). `lab-media-auth` espace ses écritures d'au moins 2 s et contrôle par l'API de MediaMTX (`/v3/config/paths/list`) que les chemins et réglages d'enregistrement voulus sont bien en place ; sinon il réécrit le fichier.
- Basculer `record` d'un chemin dans le fichier ne coupe ni la publication ni le lecteur (essai réel) ; un chemin à `record: no` avec `recordDeleteAfter` voit quand même ses anciens segments purgés. `recordDeleteAfter` doit être ≥ `recordSegmentDuration`, sinon MediaMTX refuse de démarrer.
- ffmpeg cite l'URL de publication, mot de passe compris, dans ses messages d'erreur (`Slave '…rtsp://capture:<mot de passe>@…'`). La capture fait passer son journal par un filtre qui le masque (contrôles J3, J4).
- Caddy (`caddy-docker-proxy`) lit les labels de **tous** les conteneurs de l'hôte : une pile de test ne doit porter aucun label `caddy`. `verify.sh` renomme le label en `lmtcaddy`, lu par un Caddy de test.
