# Répartiteur `edge-router`

Un petit nginx qui reçoit les ports **80 et 443 de l'hôte** et les aiguille vers le Caddy du bon
cadriciel selon le nom de domaine demandé. Il ne déchiffre rien : en 443 il lit seulement le nom
de domaine annoncé par le navigateur (SNI) et relaie la connexion telle quelle ; chaque Caddy
garde son propre certificat. En 80 il relaie selon l'en-tête `Host`.

Sans lui, le lab n'a pas de HTTPS : le Caddy de `sso-lab` ne publie plus lui-même 80 et 443.

## Où il vit

- **Ce dossier (`dev/edge-router.example/`) est un gabarit.** Il ne tourne pas ; ses fichiers
  s'appellent `docker-compose.example.yml` et `nginx.example.conf` pour que les scripts du lab ne
  le prennent pas pour une unité à déployer.
- **La copie active est dans `~/edge-router/`**, hors de tout dépôt, parce qu'elle est commune à
  tous les cadriciels de la machine : aucun d'eux ne doit pouvoir l'arrêter en se redéployant.
- `bash scripts/edge-router-install.sh` copie le gabarit dans `~/edge-router/` **s'il n'existe
  pas**, y inscrit le domaine du lab et le démarre. Il ne touche jamais à un `~/edge-router/`
  existant. `bash scripts/install.sh` l'appelle.

## Avec un seul cadriciel

Rien à faire : le gabarit envoie tout vers `caddy`, le Caddy de `dev/`.

## Ajouter un second cadriciel sur la même machine

Deux cadriciels peuvent partager les ports 80 et 443 d'une seule adresse IP, chacun avec son
domaine. Pour en ajouter un (appelons-le `dev2`, domaine `second.example.org`) :

1. **Son Caddy doit porter un autre nom de conteneur** que celui de `dev/` (par exemple `caddy2`),
   **ne publier aucun port** (pas de bloc `ports:`), et **rejoindre le réseau Docker `edge-net`** :
   ```yaml
   networks:
     edge-net:
       external: true
       name: edge-net
   services:
     caddy:
       container_name: caddy2
       networks: [ son-reseau-interne, edge-net ]
   ```
2. **Dans `~/edge-router/nginx.conf`, ajouter une ligne dans chacun des deux blocs `map`** (celui
   du 443 et celui du 80) :
   ```nginx
   second.example.org  caddy2:443;     # bloc « stream »
   second.example.org  caddy2:80;      # bloc « http »
   ```
   La ligne `default` décide qui reçoit un domaine inconnu : la laisser sur `caddy`.
3. **Recharger le répartiteur**, sans coupure :
   ```bash
   docker exec edge-router nginx -t && docker exec edge-router nginx -s reload
   ```
4. Vérifier : `curl -sI https://second.example.org/` répond par le second cadriciel, et le domaine
   du premier répond toujours.

Chaque cadriciel garde son propre nom de domaine, son propre certificat et son propre SSO : rien
n'est partagé entre eux hormis la machine, Docker et ce répartiteur.

## À savoir

- **Arrêter ou supprimer `~/edge-router/` coupe 80 et 443 pour tous les cadriciels à la fois.**
- Les ports 80 et 443 du routeur doivent être redirigés vers cette machine, une seule fois.
- Pour revenir à un Caddy directement exposé (un seul cadriciel, sans répartiteur) : arrêter
  `edge-router`, puis redonner un bloc `ports: ["80:80", "443:443"]` au service `caddy` de
  `sso-lab/docker-compose.yml`.
