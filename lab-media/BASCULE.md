# Bascule de `peripheriques-media` vers `lab-media` (phase C)

Procédure à jouer par l'architecte, en présence d'un navigateur réel pour le dernier contrôle. Chaque étape a son point de contrôle ; ne pas passer à la suivante s'il échoue. Le retour arrière reste possible jusqu'à l'étape 9.

**Ce que la bascule coupe** : l'enregistrement et le direct s'arrêtent entre l'étape 5 (arrêt de l'ancien conteneur) et l'étape 6 (démarrage du nouveau). Les deux conteneurs ne peuvent pas tourner ensemble : une caméra ne s'ouvre qu'une fois, et le port 8189 n'est publié que par un seul. Tout ce qui précède l'étape 5 se fait sans rien couper.

## 0. Préalables

- Phase B livrée : `peripheriques` adaptée à `lab-media/API.md`, prête à être déployée, pas encore déployée.
- Modifications des fichiers partagés appliquées (liste dans `chantiers/lab-media/rapports/media.md`).
- La brique est saine sur cet hôte, sans rien toucher au lab :
  ```bash
  bash lab-media/verify.sh        # « N contrôles, tous PASS », puis pile lmt-* supprimée
  ```
- Place disque : la copie double les enregistrements le temps de la bascule.
  ```bash
  docker system df -v | grep peripheriques-recordings ; df -h /var/lib/docker
  ```

## 1. `lab-media/.env`

```bash
cp lab-media/.env.example lab-media/.env && chmod 600 lab-media/.env
```

| Clé de `lab-media/.env` | Valeur |
|---|---|
| `DOMAIN`, `HOST_DEV_ROOT` | posées par `bash scripts/reset_url.sh` (ou recopiées de `lab-mcp/.env`) |
| `COMPOSE_PROFILES` | `capture` |
| `MEDIA_DEVICE_VIDEO`, `MEDIA_DEVICE_AUDIO`, `MEDIA_WEBRTC_PORT`, `MEDIA_WEBRTC_HOSTS` | recopiées de `deploiement/peripheriques/.env` |
| `LAB_MEDIA_HOOK_KEY` | nouvelle : `openssl rand -hex 24` |
| `LAB_MEDIA_SOURCE_CAPTURE_PUBLISH_USER` / `_PASSWORD` | `capture` / nouvelle : `openssl rand -hex 24` |
| `LAB_MEDIA_APP_PERIPHERIQUES_HOOK_KEY` | **la valeur de `MEDIA_HOOK_KEY`** de `deploiement/peripheriques/.env` |
| `LAB_MEDIA_APP_PERIPHERIQUES_CONTROL_USER` / `_PASSWORD` | **les valeurs de `MEDIA_INTERNAL_USER` / `MEDIA_INTERNAL_PASSWORD`** de l'app |

Les trois secrets actuels de l'app conviennent tels quels (48 caractères, jeu `[A-Za-z0-9_-]`, vérifié le 2026-10-11). Les reprendre évite de toucher au `.env` de l'app pour autre chose que ses deux URL.

Contrôle : la configuration se résout et ne contient aucun `CHANGE_ME`.
```bash
docker compose -f lab-media/docker-compose.yml config -q && ! grep -n CHANGE_ME lab-media/.env
```

## 2. Images

```bash
bash scripts/lab-lock.sh docker compose -f lab-media/docker-compose.yml --profile capture build
```
Contrôle : `docker image ls | grep '^lab-media-'` montre `lab-media-auth`, `lab-media-media`, `lab-media-capture`.

## 3. Volume et première copie (l'ancien service tourne toujours)

```bash
IMG=bluenviron/mediamtx:1.21.1-ffmpeg        # déjà sur l'hôte ; sert ici de simple busybox
docker volume create lab-media-recordings
docker run --rm --network none -v peripheriques-recordings:/from:ro -v lab-media-recordings:/to --entrypoint sh $IMG -c \
  'cp -a /from/. /to/ && for d in /from /to; do cd $d; echo "$d : $(find . -type f | wc -l) fichiers, $(du -sk . | cut -f1) ko"; done'
```
Contrôle : même nombre de fichiers des deux côtés. La taille peut différer de ce que le segment de l'heure en cours a grossi pendant la copie : il est recopié à l'étape 5.

## 4. Sauvegarde de l'état de l'app

```bash
docker inspect -f '{{.Image}}' peripheriques-backend peripheriques-frontend peripheriques-media > /tmp/peripheriques-images.avant
git -C deploiement/peripheriques rev-parse HEAD > /tmp/peripheriques-commit.avant
cp deploiement/peripheriques/.env /tmp/peripheriques.env.avant && chmod 600 /tmp/peripheriques.env.avant
```

## 5. Arrêt de l'ancien service et copie finale — début de la coupure

```bash
docker stop peripheriques-media          # arrêté, PAS supprimé : c'est le retour arrière
docker run --rm --network none -v peripheriques-recordings:/from:ro -v lab-media-recordings:/to --entrypoint sh $IMG -c \
  'cp -au /from/. /to/ && for d in /from /to; do cd $d; echo "$d : $(find . -type f | wc -l) fichiers, $(du -sk . | cut -f1) ko"; done
   cd /from && find . -type f | sort | tail -5 | xargs md5sum > /tmp/sommes && cd /to && md5sum -c /tmp/sommes'
ss -H -tlnu | grep -c ':8189 '           # 0 : le port est libre (4 tant que l'ancien conteneur tourne)
```
Contrôle : nombre de fichiers **et** taille identiques des deux côtés, cinq lignes `OK` (les cinq segments les plus récents, dont celui qui était en écriture). Ces commandes ont été répétées sur des volumes jetables, écart provoqué compris (`FAILED` sur le fichier altéré).

Si ce contrôle échoue : `docker start peripheriques-media` remet tout en service comme avant ; rien d'autre n'a encore changé.

## 6. Démarrage de `lab-media` — fin de la coupure de l'enregistrement

```bash
docker compose -f lab-media/docker-compose.yml up -d --no-build
```
Contrôles :
```bash
docker ps --filter name='^lab-media' --format '{{.Names}}: {{.Status}}'      # 3 conteneurs, auth « healthy »
docker logs --tail 5 lab-media-auth                                          # "event":"started", apps et chemins attendus
docker logs --tail 20 lab-media-capture                                      # « publication webcam/{video,audio,av} », aucune ERREUR
docker logs lab-media 2>&1 | grep -E "is publishing to path|recording" | tail -4
docker exec lab-media sh -c 'ls -l /recordings/webcam/av | tail -2'          # un segment daté de maintenant, qui grossit
```
Si la capture n'obtient pas la caméra : `docker logs lab-media-capture` le dit (`[wait-devices] attente …`). Vérifier d'abord que `peripheriques-media` est bien arrêté.

## 7. Déploiement de `peripheriques` adaptée

Dans `deploiement/peripheriques/.env` : `MEDIA_API_URL=http://lab-media-auth:9100` et `MEDIA_PLAYBACK_URL=http://lab-media-auth:9100`. Puis le déploiement de l'app, par la commande que rapporte le secteur de la phase B.

Contrôle depuis le backend de l'app, avec ses propres identifiants :
```bash
docker exec peripheriques-backend python -c "
import os, requests
r = requests.get(os.environ['MEDIA_API_URL'] + '/v1/paths/webcam/av', auth=(os.environ['MEDIA_INTERNAL_USER'], os.environ['MEDIA_INTERNAL_PASSWORD']), timeout=5)
print(r.status_code, r.json())"                                              # 200, ready: true, tracks H264 + Opus
```

## 8. Contrôles réels

| # | Contrôle | Attendu |
|---|---|---|
| 1 | Page « direct » de l'app, compte ayant un droit | image et son en WebRTC ; `docker logs lab-media-auth` montre `"action":"read"`, `"app":"peripheriques"`, `"allowed":true` |
| 2 | Même page, compte sans droit | refus ; journal : `"allowed":false`, raison `hook de peripheriques : 401` |
| 3 | Révocation du droit pendant une lecture WebRTC, puis pendant une lecture HLS | la lecture se coupe ; journal : `"route":"sessions/kick"`, `"status":204` pour chaque protocole |
| 4 | Relecture d'une heure **antérieure** à la bascule | la liste montre les plages copiées ; le clip se lit |
| 5 | Relecture d'un instant antérieur au `since` du droit | refusée par l'app |
| 6 | `docker restart peripheriques-backend` | pendant le redémarrage : `ls -l /recordings/webcam/av` grossit toujours, `docker logs lab-media` ne montre aucune fermeture de la publication ; la lecture est refusée puis revient |
| 7 | Cloisonnement de l'app | `docker exec lab-runner sh -c "curl -s -X POST -H 'Content-Type: application/json' -d '{\"app\":\"peripheriques\"}' http://localhost:4300/run"` : résultats non vides, tous verts |
| 8 | Depuis un conteneur de `dev-net` : `lab-media:9997`, `lab-media:9996`, `lab-media-auth:9000` | connexion refusée |
| 9 | **Image H.264 dans un vrai navigateur, par l'utilisateur** | seule validation qui autorise l'étape 9 |

## Retour arrière (possible jusqu'à l'étape 9)

```bash
docker compose -f lab-media/docker-compose.yml --profile capture down     # libère la caméra et le port 8189 ; le volume external reste
cp /tmp/peripheriques.env.avant deploiement/peripheriques/.env            # si l'étape 7 a été jouée
git -C deploiement/peripheriques checkout "$(cat /tmp/peripheriques-commit.avant)"
# redéploiement de l'app à ce commit (commande habituelle), puis :
docker start peripheriques-media
```
Les segments écrits par `lab-media` entre-temps se rapatrient, si on les veut, par la copie inverse :
```bash
docker run --rm --network none -v lab-media-recordings:/from:ro -v peripheriques-recordings:/to --entrypoint sh bluenviron/mediamtx:1.21.1-ffmpeg -c 'cp -au /from/. /to/'
```
Contrôle : `docker logs --tail 5 peripheriques-media` montre la publication et l'enregistrement repris.

## 9. Nettoyage — seulement après validation par l'utilisateur

```bash
docker rm peripheriques-media
docker volume rm peripheriques-recordings
docker image rm peripheriques-media
```
Puis le retrait du service `media`, du volume et du dossier `media/` dans le dépôt de l'app (préparé par la phase B).
