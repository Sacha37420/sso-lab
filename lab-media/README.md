# lab-media — la brique des flux audio/vidéo du lab

`lab-media` est le point d'entrée unique des flux audio et vidéo du lab, comme `postgres` l'est pour les données et `storage` pour les fichiers. Il reçoit des flux, les diffuse (WebRTC et HLS) et les enregistre. Il ne décide jamais qui peut lire : cette décision reste à l'app qui possède le flux.

- Contrats : `chantiers/lab-media/CONTRAT.md` ; webcams : `chantiers/webcams/CONTRAT.md` ; haut-parleur : `chantiers/haut-parleur/CONTRAT.md` ; chemins « publication WebRTC relayée » et URL de hook hors du dépôt : chantier `ecran` (I1).
- API des apps (fait foi) : [`API.md`](API.md).
- Bascule depuis `peripheriques` : [`BASCULE.md`](BASCULE.md).
- Preuve rejouable : `bash lab-media/verify.sh` (environ 13 minutes sur l’hôte chargé, 194 contrôles, pile isolée `lmt-*`, faux matériel : la vraie caméra n'est ni montée ni ouverte, aucune carte son n'est ouverte et aucun son ne sort).

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
| `lab-media-capture` | Superviseur + un ffmpeg par webcam du plan (au plus `MEDIA_CAPTURE_MAX`) : ouvre la webcam (et son micro s'il y en a un), encode une fois, publie `webcam/<id>/{av,video[,audio]}`. Et un lecteur par haut-parleur déclaré : joue sur la sortie ALSA ce qui est publié sur `speaker/<id>`. Profil Compose `capture` : la brique tourne sans lui. |

| Fichier | Rôle |
|---|---|
| `docker-compose.yml` | Les trois services, leurs trois réseaux, les volumes `config`, `state` et `speakers`. |
| `registry.json` | Le registre : apps, préfixes, sources, chemins, section `devices` (préfixe des webcams, rétention, entrée héritée, haut-parleurs déclarés). Aucun secret. |
| `.env` (non versionné) | Secrets et réglages ; modèle : `.env.example`. |
| `auth/labmediaauth/` | `registry.py` (registre, génération de `mediamtx.yml`), `server.py` (hook et API), `devices.py` (découverte des webcams, inventaire, plan). |
| `auth/mediamtx.base.yml` | Partie fixe de la configuration de MediaMTX. |
| `mediamtx/` | Images de MediaMTX et de la capture (`Dockerfile` à étapes : la capture a en plus `alsa-utils`) : `entrypoint.sh`, `capture.sh` (superviseur), `capture-one.sh` (une webcam), `speaker-one.sh` (un haut-parleur). |
| `verify.sh`, `verify/` | La preuve rejouable : apps fictives, sources synthétiques, faux matériel (`fakehw.py`, `compose.test.yml`, `asound.test.conf`), mesure de latence du haut-parleur (`speakerprobe.py`). |

## Qui décide quoi

| Action | Décidée par | Règle |
|---|---|---|
| `publish` | `lab-media-auth` | Identifiants de publication de l'app propriétaire du préfixe, ou d'une source interne sur ses chemins. RTSP seulement. Chemin déclaré au registre. |
| `publish` sur `speaker/<id>` | **l'app propriétaire du préfixe** | WebRTC (WHIP) seulement : `lab-media-auth` relaie le corps de MediaMTX à son hook, comme une lecture. Aucun identifiant n'ouvre une publication RTSP sur ces chemins. Un seul publieur à la fois (`overridePublisher: no`). |
| `publish` sur un chemin `"whip": true` | **l'app propriétaire du préfixe** | WebRTC (WHIP) seulement, relayé à son hook comme une lecture (même échec fermé). Aucun identifiant — de l'app, d'une source, de contrôle, internes — n'ouvre une publication sur ce chemin, en aucun protocole : ils ne sont même pas comparés. Un seul publieur (`overridePublisher: no`). |
| `read` | **l'app propriétaire du préfixe** | `lab-media-auth` relaie le corps de MediaMTX à son hook. Seul un `200` reçu en moins de 3 s autorise. Vaut aussi pour un chemin `"whip": true` (l'app impose elle-même le protocole qu'elle veut). |
| `read` sur `speaker/<id>` | `lab-media-auth` | Fermée à tous, sans consulter l'app, sauf au lecteur de la capture (RTSP, identifiants de la source `capture`). Personne n'écoute ce qui est dit ; rien n'est enregistré. |
| `api`, `playback`, `metrics`, `pprof` | `lab-media-auth` | Identifiants internes, tirés au hasard à chaque démarrage, jamais écrits nulle part. |
| Toute autre action | — | Refusée. |

**Ne jamais utiliser `authHTTPExclude`.** Sur MediaMTX 1.21.1, une action exclue est autorisée sans aucun contrôle, WHIP compris (essai réel du 2026-10-11). Le générateur de configuration refuse de démarrer si la base en contient.

La publication WHIP est joignable depuis Internet (Caddy sert tout `/lab-media-webrtc/*`) : elle n'est ouverte **que** sur les chemins de haut-parleur et les chemins déclarés `"whip": true`, et c'est le hook de l'app qui décide. Sur tout autre chemin, elle est refusée avant même de consulter l'app (contrôles HP6, P7, P8).

Le relais au hook porte la clé de l'app **deux fois** : en query (`?key=`, comme depuis l'origine) et dans l'en-tête `X-Lab-Media-Key` (chantier ecran), pour toutes les apps. Une app peut ne lire que l'en-tête et garder la query hors de ses journaux d'accès. Vers un hook `https://`, le certificat et le nom d'hôte sont vérifiés (magasin de certificats de l'image) ; aucune redirection n'est suivie : tout ce qui n'est pas `200` refuse.

## Ajouter une app

1. Dans `registry.json`, une entrée sous `apps` :
   ```json
   "mon-app": {"prefixes": ["mon-app"], "read_hook": "http://mon-app-backend:8000/api/media-auth/", "publish": true}
   ```
   - `prefixes` : un chemin appartient à l'app s'il est égal à un préfixe ou s'il commence par `<préfixe>/`. Deux apps ne peuvent pas avoir de préfixes emboîtés.
   - `read_hook` : URL du hook de lecture, sans query (forme : `API.md` §2).
   - `read_hook_env: true` (à la place de `read_hook`, jamais les deux) : l'URL du hook n'est pas écrite au registre — versionné, public — mais lue dans `.env` sous `LAB_MEDIA_APP_<NOM>_HOOK_URL`. Pour une app joignable seulement par une adresse publique qui n'a pas à figurer dans le dépôt. Même règle de forme (http(s), sans query ni fragment) ; absente, vide, à `CHANGE_ME` ou invalide : `lab-media-auth` refuse de démarrer, sans jamais recopier l'URL dans son journal.
   - `publish` : `true` seulement si l'app pousse elle-même des flux (RTSP).
2. Dans `registry.json`, ses chemins sous `paths` (tout chemin non déclaré est refusé) :
   ```json
   "mon-app/cam": {"record": true, "segment": "1h", "delete_after": "7d"},
   "mon-app/ip":  {"source_env": "LAB_MEDIA_PULL_MON_APP_IP"}
   ```
   - `record`, `segment`, `delete_after` : enregistrement en fMP4 sous `/recordings/<chemin>/`.
   - `source_env` : le chemin est **tiré** depuis une caméra IP ; la clé nommée porte l'URL `rtsp://…` dans `.env`. `on_demand: true` ne tire que lorsqu'un lecteur est là.
   - `"whip": true` (chantier ecran) : **publication WebRTC relayée**. Un client publie en WHIP (`…/lab-media-webrtc/<chemin>/whip`, jeton `Bearer`) et c'est le hook de l'app qui décide, avec le corps de MediaMTX tel quel ; la lecture lui est relayée comme partout. Jamais enregistré (`record: no` écrit dans `mediamtx.yml`), absent de la relecture (`404`), un seul publieur. Incompatible avec `record`, `segment`, `delete_after`, `source_env` et `on_demand` (refus au chargement, même `"record": false`) ; aucune source ne peut le lister dans ses `paths`. Exemple : `"ecran/a": {"whip": true}`.
3. Dans `.env`, ses secrets, sous des noms dérivés du nom de l'app (majuscules, `-` devient `_`) :
   ```
   LAB_MEDIA_APP_MON_APP_HOOK_KEY=…            clé présentée au hook de l'app (?key= et X-Lab-Media-Key)
   LAB_MEDIA_APP_MON_APP_HOOK_URL=https://…    seulement si "read_hook_env": true (URL du hook, sans query)
   LAB_MEDIA_APP_MON_APP_CONTROL_USER=…        identifiants de l'API de contrôle
   LAB_MEDIA_APP_MON_APP_CONTROL_PASSWORD=…
   LAB_MEDIA_APP_MON_APP_PUBLISH_USER=…        seulement si "publish": true
   LAB_MEDIA_APP_MON_APP_PUBLISH_PASSWORD=…
   ```
   Secrets : `[A-Za-z0-9_-]`, 16 caractères au moins. Un nom d'utilisateur ne sert qu'à une entrée. `HOOK_URL` n'est pas un secret de cette forme : c'est une URL, validée comme `read_hook`.
4. Appliquer : `docker compose -f lab-media/docker-compose.yml up -d --no-build --force-recreate --no-deps auth` (seul `lab-media-auth` est recréé). MediaMTX recharge sa configuration à chaud ; les publications et l'enregistrement en cours ne sont pas coupés (prouvé : contrôles G1 à G3).

`lab-media-auth` refuse de démarrer, en disant pourquoi dans son journal, si le registre est incohérent : chemin sans propriétaire, préfixes en conflit, secret absent, trop court ou resté à `CHANGE_ME`, clé inconnue.

## Sources

- **Webcams de l'hôte** (`capture`, chantier webcams) :
  - **Découverte** par `lab-media-auth`, toutes les `LAB_MEDIA_SCAN_S` secondes (2), en lisant `/sys` seulement : aucun nœud n'est ouvert. Une webcam = un appareil USB dont une interface de classe vidéo (`0e`) porte un nœud video4linux d'index 0 (capture ; l'index 1 est celui des métadonnées). Son micro = une carte son du **même appareil USB** ayant un PCM de capture. Une nouvelle webcam doit être vue deux passages de suite (la carte son suit parfois le nœud vidéo d'un instant). Identifiant : `API.md` §1.4.
  - **Inventaire** : `/state/inventory.json` (volume `state`), écrit par `lab-media-auth` seul : toutes les webcams déjà vues, leur réglage d'enregistrement, les chemins oubliés gardés jusqu'à la purge de leurs enregistrements. Illisible ⇒ `lab-media-auth` refuse de démarrer (jamais de remise à zéro silencieuse).
  - **Plan** : `/state/plan`, une ligne par webcam à capturer : `<id> <port USB> <micro 0|1> <base des chemins>`. Au plus `MEDIA_CAPTURE_MAX` (2 par défaut, de 0 à 8 ; le lab tourne à 3, avec `MEDIA_CAPTURE_FPS=8` au lieu de 15 — `lab-media/.env`). Une webcam déjà capturée garde sa place ; une place libérée va à la webcam en attente vue le plus tôt. Le nom de produit et le numéro de série — choisis librement par l'appareil — n'entrent ni dans le plan, ni dans un chemin, ni dans le journal : seulement dans `model`/`serial` de l'API, nettoyés et bornés.
  - **Capture** : `capture.sh` lit le plan chaque seconde (et revalide chaque champ, et le plafond) ; un travailleur `capture-one.sh` par ligne, donc un ffmpeg par webcam. Ligne disparue (débranchement) ou changée ⇒ travailleur arrêté, son ffmpeg tué **et attendu** ; ffmpeg mort ⇒ relancé après 3 s. Les nœuds sont retrouvés à chaque lancement depuis le port USB (`/sys/bus/usb/devices/<port>`), après contrôle du `vendor:product`, de la classe d'interface, de l'index et du majeur:mineur de `/hostdev/videoN`.
  - **Encodage** : MJPEG 1280x720 décodé, H.264 baseline 15 i/s 1 Mbit/s ; après un échec rapide, nouvel essai au format par défaut du pilote. Micro : `plughw:<carte>,<pcm>`, Opus mono 32 kbit/s. **Sans micro, vidéo seule** : `av` et `video` en H.264 seul, aucun chemin `audio`.
  - **Enregistrement** : par webcam, coupé par défaut, réglé par `PATCH /v1/devices/<id>` (`API.md` §1.4) ; changé à chaud dans `mediamtx.yml`, sans couper la publication.
  - **`webcam-ancienne`** : la caméra d'avant la découverte, déclarée au registre (`devices.legacy`) sur les chemins `webcam/{av,video,audio}`. Jamais capturée, jamais enregistrée ; ses enregistrements restent relisibles jusqu'à leur purge (7 jours).
  - Toujours **aucun `devices:`** (il fige un numéro de périphérique à la création du conteneur) : `/dev` de l'hôte est monté en lecture seule sous `/hostdev` (vue live) et `/dev/snd` en bind. `device_cgroup_rules` : `c 81:* rmw` (video4linux) et `c 116:* rmw` (ALSA), rien d'autre. Le `:ro` ne protège pas un nœud caractère : seules ces règles limitent ce que le conteneur peut ouvrir.
  - `MEDIA_DEVICE_VIDEO` et `MEDIA_DEVICE_AUDIO` ne sont plus lues : présentes dans `.env`, elles sont ignorées.
  - `MEDIA_CAPTURE_MODE=testsrc` remplace chaque webcam du plan par une mire (et un bip si elle a un micro) : mêmes chemins, aucun périphérique ouvert.
  - Ce conteneur n'est que sur le réseau interne.
- **Haut-parleurs** (`capture`, chantier haut-parleur) :
  - **Déclarés** au registre, pas découverts (une prise jack n'a pas d'identité USB) : `devices.speakers`, et le préfixe `speaker` dans les `prefixes` de l'app qui possède celui des webcams (`lab-media-auth` refuse de démarrer sinon). Exemple (le haut-parleur réel du lab) :
    ```json
    "devices": {"…": "…",
      "speakers": {"hp-jack": {"model": "Haut-parleur (prise jack)", "pcm": "plughw:CARD=PCH,DEV=0",
                               "mixer": {"card": "PCH", "control": "Master", "volume": 80}}}}
    ```
    - identifiant `^[a-z][a-z0-9-]{1,40}$`, jamais `usb-…` ni `webcam…` ; chemin `speaker/<id>` (calculé, jamais déclaré dans `paths`) ;
    - `pcm` : la sortie ALSA (`[A-Za-z0-9_:=,.-]`, sans espace). Nommer la carte par son **id** (`CARD=PCH`, `/proc/asound/cards`) plutôt que par son numéro : l'ordre des cartes (carte mère, HDMI de la carte graphique) peut changer au démarrage de l'hôte. `plughw` convertit format, fréquence et canaux ;
    - `mixer` : `null` (le mixeur n'est pas touché) ou `{"card", "control" (défaut `Master`), "volume" (0 à 100, défaut 80)}` ;
    - huit au plus.
  - **Mixeur** : au démarrage du lecteur (et après chaque erreur de sortie), `amixer -c <card> sset <control> <volume>% unmute`. Rien d'autre : ni les entrées (micros), ni `Auto-Mute Mode`, ni les autres sorties. Sur la carte du lab (ALC662), `Master` est à 0 % et coupé par défaut, `Headphone`/`Line Out`/`Speaker` à 100 % : sans ce réglage, rien n'est audible. Avec `Auto-Mute Mode` actif, brancher un casque en façade coupe la prise arrière.
  - **Lecteur** (`speaker-one.sh`, un par haut-parleur, supervisé par `capture.sh` comme les webcams) : `ffmpeg` lit `speaker/<id>` en RTSP (identifiants de la source `capture` : il est le seul lecteur permis), décode en PCM 48 kHz stéréo sans tampon (`-fflags nobuffer -flush_packets 1`), et `aplay` joue sur `pcm` avec un tampon ALSA borné (`MEDIA_SPEAKER_BUFFER_MS`, 160 ms par défaut ; lecture lancée à la moitié). Latence publieur → sortie ALSA mesurée par `verify.sh` (HP28) : 218 à 290 ms sur deux exécutions (médianes 226 et 260 ms, encodage Opus et WHIP compris) ; s'y ajoutent le tampon de la carte (lecture lancée à 80 ms, 160 ms au plus) et le trajet réseau du navigateur.
  - **Quand se connecte-t-il ?** Jamais en continu : `lab-media-auth` écrit `/state/talk` (`<id> <génération> <prêt>`). Une publication WHIP autorisée change la génération : le lecteur tente sa connexion toutes les 0,3 s pendant 15 s au plus. Pendant une parole, `lab-media-auth` suit l'état « prêt » de MediaMTX (toutes les 2 s) ; hors de ces moments, il n'interroge pas MediaMTX et le lecteur n'appelle pas le hook. La carte son n'est ouverte qu'au premier échantillon reçu.
  - **État** (`API.md` §1.5) : le lecteur écrit `idle`, `error mixer` ou `error output` dans le volume `speakers` (`/speakers/<id>`), toutes les 2 s ; `lab-media-auth` le lit. Statut de plus de 10 s : `offline` (capture absente). Un échec ALSA (carte absente, contrôle inconnu, sortie occupée) passe à `error` et fait réessayer toutes les 5 s, avec à chaque essai 0,1 s de silence envoyé à la sortie pour l'éprouver : jamais d'arrêt de la capture vidéo (contrôle HP30).
  - Jamais enregistré (`record: no` forcé dans `mediamtx.yml`, quel que soit le registre ; relecture → `404`).
- **Publiée par une app** : RTSP vers `lab-media:8554`, identifiants de publication de l'app.
- **Publiée en WHIP, décidée par l'app** (`"whip": true`, chantier ecran) : un client extérieur (navigateur, téléphone) publie sur un chemin déclaré ; le hook de l'app autorise ou refuse chaque ouverture. L'app peut expulser ce publieur par l'API de contrôle (`API.md` §1.2) : c'est elle qui l'a laissé entrer.
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
| `lab-media-capture` arrêté | Inventaire, découverte, API | Toute publication de webcam ; après 20 s, les webcams branchées passent en `error`. Les haut-parleurs passent `offline` en 10 s ; une parole publiée n'est plus jouée |
| MediaMTX redémarré | — | Toutes les sessions. Les publications reviennent d'elles-mêmes (`capture.sh` boucle ; une app qui publie doit faire de même) |

Conséquence : pendant un arrêt de `lab-media-auth`, une révocation de droit ne peut pas couper un lecteur déjà ouvert. Garder cet arrêt court (un redémarrage prend quelques secondes).

## Réseau

- `lab-media` : `internal`, `dev-net`, `sso-net`. Seul port publié sur l'hôte : ICE 8189, UDP et TCP.
- L'API (9997) et la relecture (9996) de MediaMTX n'écoutent que sur l'adresse du réseau `internal` : depuis `dev-net` et `sso-net`, la connexion est refusée.
- `lab-media-auth` : `internal` (hook, port 9000, lié à cette seule adresse) et `dev-net` (API de contrôle, port 9100). Il n'est pas sur `sso-net` et ne porte aucun label Caddy.
- `lab-media-capture` : `internal` seulement. Il est le seul à ouvrir une carte son (micros des webcams en entrée, haut-parleurs en sortie).

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
- Un client WHIP qui ne tente que le **premier** candidat ICE de la réponse (ffmpeg 8.1) échoue quand MediaMTX annonce les adresses de ses interfaces : la première est `127.0.0.1`. `verify.sh` fait tourner son publieur dans l'espace réseau de `lmt-media` (`--network container:lmt-media`) ; un navigateur essaie tous les candidats.
- Un **second publieur** WHIP sur un chemin occupé passe l'authentification (le hook de l'app est consulté) et reçoit sa réponse SDP : c'est MediaMTX qui ferme la session juste après l'établissement de la connexion (« someone is already publishing »). Le client voit une connexion fermée, pas un code HTTP d'erreur.
- `ffmpeg -f alsa` choisit le plus grand tampon ALSA permis (jusqu'à 131072 trames, 2,7 s à 48 kHz) : une rafale après une coupure réseau y resterait comme retard. D'où `aplay`, dont le tampon se règle (`--buffer-time`).
