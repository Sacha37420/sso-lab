# Amendement media-01 — HLS : le hook n'est appelé qu'une fois par session (point I2-(d) faux)

**Contrat lu : v1**   ·   **Interfaces concernées : I2 (point d), I4**   ·   **Émis par : secteur media**

## Ce qui ne marche pas (constaté, pas supposé)

Sur MediaMTX **1.21.1** (`bluenviron/mediamtx:1.21.1-ffmpeg@sha256:00ef3d1a…`), testé en réel
avec un stub du hook I2 sur un réseau Docker jetable :

1. `GET /webcam/av/index.m3u8` avec `Authorization: Bearer <token>` → **1** appel au hook
   (`action=read, protocol=hls, token=<bearer>`), 200. MediaMTX crée alors une *session HLS*
   et lui donne un secret (cookie `hlsSession` en HTTPS, sinon `?session=<uuid>` ajouté aux
   URL de la playlist).
2. Sous-playlist et segments demandés **sans aucun `Authorization`**, avec seulement ce secret →
   **200, 0 appel au hook**.
3. Hook basculé en refus total (simule la révocation) → sous-playlist et nouveaux segments
   toujours **200**. La lecture continue.

Code source à l'appui : `internal/servers/hls/http_server.go` (seule la playlist multivariant
crée une session — `createNonCDNSession`, qui passe par `AddReader` donc par le hook ; tout le
reste passe par `findNonCDNSession`, recherche par secret, sans authentification) et
`internal/servers/hls/session.go` (`sessionCloseAfterInactivity = 30s` : la session ne meurt que
30 s après la dernière requête — jamais tant que le lecteur tourne).

Donc le point **(d) est faux** : une révocation (PATCH → false, DELETE) ne coupe **pas** un
lecteur HLS déjà ouvert avec le kick I4 actuel, qui ne vise que `webrtcsessions`.

En revanche, constaté sur la même version (utile pour trancher) :
- `GET /v3/hlssessions/list` existe ; l'`id` de chaque item **est égal** à l'`id` reçu par le
  hook pour cette session (`protocol=hls`) ;
- `POST /v3/hlssessions/kick/<id>` → 200 ; requête suivante avec le même secret →
  `401 session not found` ; réouverture de la playlist avec le token, hook en refus → 401.
  **La révocation HLS est donc réalisable**, mais par un appel que I4 ne liste pas.
- Sans identifiants internes : kick → 401 (l'API reste protégée par le hook, règle 3).

Les trois autres points tiennent (vérifiés en réel, détail dans le rapport media) :
(a) le bearer arrive bien dans `token` pour WHEP **et** HLS ; (b) `?key=` conservée ;
(c) `id` du hook == `id` de `/v3/webrtcsessions/list` (⚠ **pas** l'uuid de l'en-tête
`Location` de la réponse WHEP, qui est un autre identifiant) ; kick WebRTC → pair `closed`,
liste vide.

## Pourquoi je ne peux pas le contourner dans mon périmètre

La configuration MediaMTX n'offre aucun réglage de ré-authentification par requête HLS dans
1.21.1. Le seul moyen de couper un lecteur HLS est l'appel de kick, qui est émis par le **backend**
au moment de la révocation — il doit donc figurer dans I4 et dans la logique de kick du backend.
Désactiver HLS de mon côté retirerait une route que I6 et le frontend consomment.

## Options

### Option A — Ajouter le kick HLS à I4 (préférée)
- Changement : I4 gagne
  `GET /v3/hlssessions/list → items[].id, .path` et `POST /v3/hlssessions/kick/<id>`.
  I2 règle 4 inchangée (elle enregistre déjà `(id, email, path, protocol)` — `protocol` vaut
  `webrtc` ou `hls`) ; le kick choisit l'endpoint selon `protocol`. Point (d) de I2 remplacé par :
  « HLS n'est authentifié qu'à l'ouverture de la session ; la révocation passe par le kick ».
- Conséquence pour **media** : aucune (déjà en place, aucun réglage nécessaire).
- Conséquence pour **backend** : la fonction de kick (PATCH true→false, DELETE) itère les
  sessions enregistrées de l'email et appelle `webrtcsessions/kick` ou `hlssessions/kick` selon
  `protocol` ; mock de test à étendre au 2ᵉ endpoint. Une session HLS déjà fermée par
  inactivité renvoie une erreur au kick → à traiter comme « déjà coupée », pas comme un échec.
- Conséquence pour **frontend** : hls.js doit traiter un 401/404 sur la sous-playlist comme une
  fin de lecture (erreur fatale, message « accès retiré »), sans boucle de reconnexion — une
  reconnexion repasserait de toute façon par le hook et serait refusée.
- Coût / risque : faible. Fenêtre de fuite = durée du PATCH/DELETE (kick synchrone).

### Option B — Supprimer HLS, WHEP seul
- Changement : I6 perd la route `/peripheriques-hls/*` ; I1/I2 ne parlent plus que de WebRTC.
- Conséquence pour **media** : `hls: no` (une ligne).
- Conséquence pour **backend** : rien.
- Conséquence pour **frontend** : plus aucun repli. WebRTC exige que le port 8189 (UDP ou TCP)
  de l'hôte soit joignable directement depuis le client ; un réseau qui ne laisse passer que
  443 (entreprise, certains Wi-Fi publics) n'a plus aucun direct.
- Coût / risque : perte fonctionnelle réelle pour les accès WAN restreints.

### Option C — Garder HLS sans kick, documenter le délai
- Changement : (d) accepté comme limite ; la révocation ne coupe HLS qu'à la fermeture du lecteur.
- Conséquences : aucune pour les secteurs. Mais un droit retiré continue de donner le direct
  indéfiniment tant que l'onglet reste ouvert — contraire à l'intention de cloisonnement. Non
  recommandé.

## Fait annexe — bloquant indépendamment de cet amendement (matériel, hors contrat)

La webcam Jieli `1224:2a25` **se déconnecte du bus USB** au bout de ~10–25 s de capture
continue, dès que le débit monte : MJPEG 1280×720 (seul format ≥ 720p ; pilote imposant
25 i/s), YUYV 640×480, et même MJPEG 640×480 + micro. Ont tenu 30 s : micro seul, MJPEG 640×480
sans micro. Avec MediaMTX, ffmpeg a été relancé ~12 fois en 2 min (`runOnInitRestart` fait son
travail, mais l'enregistrement est haché). Après l'une de ces déconnexions, le périphérique est
revenu **dégradé** pendant ~1–2 min : carte ALSA renommée `U0x12240x2a25` (au lieu de `U20`) et
aucun `/dev/video*` — ce qui casse à la fois `MEDIA_DEVICE_AUDIO=hw:CARD=U20,DEV=0` et le
chemin `by-id` de `MEDIA_DEVICE_VIDEO` (I5). Les deux sont revenus seuls ensuite.

Profil typique d'une alimentation/câble/port USB insuffisant (pas d'accès à `dmesg` pour le
confirmer). Action **physique** requise de l'utilisateur : brancher la caméra sur un port USB
arrière de la carte mère ou via un hub **alimenté**, autre câble si possible ; puis refaire un
essai de 5 min. Aucun contournement logiciel dans mon périmètre (descendre en résolution ne
suffit pas : 640×480 + micro décroche aussi).

## Mon option préférée

**A** — elle conserve le repli HLS (indispensable hors LAN), ne demande rien à media, coûte un
second endpoint au backend, et rend la révocation HLS aussi immédiate que la WebRTC.
**Je m'arrête ici et je rends la main : je n'implémente rien tant que S1 n'a pas tranché et
publié la version suivante du contrat.**
