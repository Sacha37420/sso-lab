# To-do — migrer MediaMTX vers une brique commune du lab (`lab-media`)

> **Statut au 2026-10-11 : brique construite et prouvée sur sources synthétiques (`lab-media/`, 99
> contrôles — `bash lab-media/verify.sh`), non déployée. Elle vit dans `lab-media/` à la racine, pas dans
> `infra/` (toucher au compose d'`infra` recrée les conteneurs PostgreSQL). Contrat :
> `chantiers/lab-media/CONTRAT.md`. Reste : adaptation de `peripheriques` (phase B), puis la
> bascule de la caméra (`lab-media/BASCULE.md`), à faire avec le propriétaire.**
>
> *(ancien statut)* **non commencé.** Décision du 2026-10-04 : `peripheriques` est livrée avec MediaMTX
> **privé à l'app** (`peripheriques/media/`). Ce fichier décrit la migration à faire ensuite pour
> en faire une base commune à tous les sous-modules, au même titre que `postgres` (données
> structurées) et `storage` (fichiers utilisateur).
>
> Régime : **chantier** (touche `infra/`, `scripts/reset_url.sh`, `CLAUDE.md`, sécurité du
> cloisonnement) → invoquer la skill `chantier`. Contrat de départ à reprendre :
> `chantiers/peripheriques/CONTRAT.md` (v3) — ses interfaces I1/I2/I4 restent valables, seuls
> l'hébergement, les noms et la propriété changent.

## Pourquoi

- Une seule instance peut détenir une caméra ou un micro (V4L2/ALSA s'ouvrent une fois). Si une
  2ᵉ app veut un flux (ex. `robot-lab`, `atelier-3d` photogrammétrie, un futur interphone), elle
  ne doit ni ouvrir le périphérique elle-même ni dépendre du cycle de vie de `peripheriques`.
- Même logique que `storage` : **un point d'entrée unique**, l'autorisation décidée par l'app qui
  porte la règle métier.

## Cible

| | Aujourd'hui | Après migration |
|---|---|---|
| Service | `peripheriques/media/`, conteneur `peripheriques-media` | `infra/media/` + service `media` dans `infra/docker-compose.yml`, conteneur `lab-media`, réseaux `dev-net` + `sso-net` (Caddy) |
| Enregistrements | volume external `peripheriques-recordings` | volume **possédé par `infra`** (`infra_media-recordings`), référencé `external` par les apps qui le lisent — même schéma que `storage-media` |
| Secrets `MEDIA_PUBLISH_*`, `MEDIA_INTERNAL_*`, `MEDIA_HOOK_KEY` | `peripheriques/.env` | source de vérité `infra/.env`, propagés par `reset_url.sh` aux seuls `.env` qui déclarent la clé (`upsert_env` no-op sinon) — même convention que `POSTGRES_PASSWORD` |
| `MEDIA_API_URL` / `MEDIA_PLAYBACK_URL` | `http://peripheriques-media:9997` / `:9996` | `http://lab-media:9997` / `:9996` |
| Périphériques (`MEDIA_DEVICE_*`) | `peripheriques/.env` | `infra/.env` |
| Labels Caddy `/peripheriques-webrtc/*`, `/peripheriques-hls/*` | sur `peripheriques-media` | **renommés** `/lab-media-webrtc/*`, `/lab-media-hls/*` sur `lab-media` (frontend de `peripheriques` à adapter : `core/api.service.ts`, `whepUrl`/`hlsUrl`) |
| Port ICE 8189 udp/tcp | publié par `peripheriques` | publié par `infra` |
| Autorité sur les droits | backend `peripheriques` (hook I2) | **inchangée** : `peripheriques` reste la seule autorité d'accès aux périphériques |

## Point de conception à trancher en premier (ne pas sauter)

Aujourd'hui `authMethod: http` délègue **toutes** les actions au backend `peripheriques`, y compris
la publication par ffmpeg. Dans une brique commune, ça rendrait **l'enregistrement dépendant de la
disponibilité d'une app** : un `setup2.sh peripheriques` ou une panne du backend → publication
refusée → trou dans les enregistrements.

À vérifier en réel sur la version épinglée (actuellement `1.21.1`) **avant** d'écrire le contrat :
- [x] (non, voir ci-dessous) peut-on authentifier `publish` / `api` / `playback` en interne (`authInternalUsers`) tout en
      déléguant `read` au hook HTTP ? (`authHTTPExclude` : les actions exclues sont-elles
      *refusées*, *autorisées sans contrôle*, ou *renvoyées à l'auth interne* ?) ;
- [x] (retenu, éprouvé) si le mélange est impossible : alternative = un mini-service d'auth `lab-media-auth` dans
      `infra/` (règles publish/internal locales, `read` relayé à `peripheriques`) — ou accepter le
      trou, mais alors le documenter dans `CLAUDE.md` ;
- [ ] **ne jamais** se rabattre sur « `publish` sans authentification » : RTSP est joignable par
      toute app sur `dev-net`.

### Tranché par essai réel le 2026-10-11 (MediaMTX 1.21.1, conteneurs jetables, mire synthétique)

- **Le mélange n'existe pas nativement.** `authMethod` est une valeur unique (`internal` | `http` |
  `jwt`), sans repli de l'une vers l'autre (`internal/auth/manager.go`, `Manager.Authenticate`).
- **Une action listée dans `authHTTPExclude` est autorisée sans aucun contrôle** — ni refusée, ni
  renvoyée à `authInternalUsers` (`authenticateHTTP` rend un succès immédiat). Constaté :
  publication RTSP sans identifiants acceptée, API et relecture en 200 sans identifiants, et WHIP
  (routé par Caddy) ouvert à tous. **Ne jamais utiliser `authHTTPExclude`.**
- **Retenu : un mini-service d'authentification `lab-media-auth`, dans le cadriciel.** MediaMTX
  garde `authMethod: http` sans exclusion et pointe sur lui ; il tranche lui-même `publish`,
  `api`, `playback`, `metrics` avec les secrets `MEDIA_*`, et **relaie `read`** à l'app qui porte
  la règle d'accès, en échec fermé. Constaté : publication acceptée et enregistrement qui
  continue quand l'app est arrêtée ; `read` refusé tant qu'elle est arrêtée ; mauvais mot de
  passe refusé partout ; environ +1,4 ms par appel.
- Conséquences : la dépendance se déplace vers ce mini-service — il partage le cycle de vie de
  `lab-media` (une publication en cours lui survit, mais ffmpeg ne peut pas se reconnecter pendant
  son arrêt, et les expulsions sont impossibles pendant ce temps). Le hook reçoit deux appels par
  connexion RTSP (le premier sans identifiants, avant le défi), et un champ `userAgent` en plus.
- Non vérifié : app qui pend au lieu de refuser, lecture WHEP par un vrai navigateur à travers le
  relais, relecture `/get`.

## Étapes

1. [ ] Trancher le point ci-dessus, écrire `chantiers/lab-media/CONTRAT.md` (v1).
2. [ ] Déplacer `peripheriques/media/**` → `infra/media/**` (`git mv` impossible entre dépôts :
       `infra/` est dans le dépôt parent, `peripheriques/` est un sous-module — copier, puis
       supprimer dans le sous-module dans un commit séparé).
3. [ ] Service `media` dans `infra/docker-compose.yml` (devices, `group_add` 44/29, volume, ports
       8189, labels Caddy). Ajouter `lab-media` au `.heavy-build` si son build est lent.
4. [ ] `infra/.env` + `infra/.env.example` : clés `MEDIA_*` ; `scripts/init-secrets.sh` ou
       équivalent pour les générer si absentes ; `scripts/reset_url.sh` : propagation.
5. [ ] **Migration des enregistrements** (≤ 7 j, ~80 Go) : copier `peripheriques-recordings` vers
       le volume `infra` **avant** de basculer (même chemin `/recordings/%path/...`), vérifier par
       nombre de fichiers + taille, puis seulement supprimer l'ancien volume. Prévoir le disque :
       la copie double l'occupation le temps de la bascule.
6. [ ] Backend `peripheriques` : URLs I4, rien d'autre (les noms de clés `.env` ne changent pas).
7. [ ] Frontend `peripheriques` : préfixes Caddy WHEP/HLS.
8. [ ] Retirer le service `media` et le volume de `peripheriques/docker-compose.yml`.
8 bis. [ ] **Automatiser l'ouverture du port ICE 8189 (UDP + TCP) sur la Bbox.** Aujourd'hui
       ouvert **à la main** par l'utilisateur (redirection 8189/udp et 8189/tcp → hôte LAN).
       `scripts/open-bbox-ports2.sh` ne sait faire que du TCP (`protocol=tcp` en dur) et, en mode
       HTTPS, n'ouvre que 80/443. À faire : un registre des ports publics non-HTTP avec protocole
       (ex. `.public-ports`, `nom:port:proto`), lu dans tous les modes, et une détection « règle
       déjà existante » qui compare **port ET protocole** (sinon 8189/tcp masque 8189/udp). Seul
       `dev/` ouvre des ports sur la Bbox — ne pas le faire depuis `dev2/`.
9. [ ] Cycle de vie : vérifier que `setup2.sh` tout-le-lab, `clean2.sh` (infra protégée) et
       `rotate-secrets*.sh` (qui arrêtent l'infra) se comportent correctement ; documenter que la
       rotation « tout le lab » coupe l'enregistrement le temps de l'arrêt.
10. [ ] Re-tester : kick WHEP + kick HLS après révocation, relecture clippée au `since`, publication
        avec mauvais mot de passe refusée, API/playback refusés sans identifiants internes,
        enregistrement qui continue pendant un `setup2.sh peripheriques`.
11. [ ] `CLAUDE.md` : section « Flux audio/vidéo — `lab-media` » à côté de « Base de données » et
        « Stockage » (point d'entrée unique, `peripheriques` = autorité des droits, aucune app
        n'ouvre un périphérique ni ne monte le volume directement). Mettre à jour la ligne
        `peripheriques` du tableau des sous-modules.
12. [ ] Supprimer ce fichier une fois la migration absorbée dans `CLAUDE.md`.

## Pièges déjà connus (constatés pendant le chantier `peripheriques`)

- HLS de MediaMTX n'appelle le hook qu'à l'**ouverture** de session : seule
  `POST /v3/hlssessions/kick/<id>` révoque un lecteur HLS en cours.
- L'uuid de l'en-tête `Location` WHEP ≠ id de session MediaMTX (celui du hook / des listes).
- Docker masque `/proc/asound` : détecter la carte via `/sys/class/sound/card*/id`.
- Désigner le micro par **nom** (`hw:CARD=U20,DEV=0`), jamais par index.
- Un `--device` est figé à la création du conteneur : une ré-énumération USB sous un autre numéro
  impose de recréer le conteneur (`wait-devices.sh` le signale dans les logs).
- La webcam Jieli se déconnectait du bus USB sous débit soutenu (alimentation/câble) — vérifier son
  branchement avant toute campagne de mesure.
- `lab-runner` (Chromium) ne décode pas le H.264 : la vidéo se vérifie dans un vrai navigateur.
