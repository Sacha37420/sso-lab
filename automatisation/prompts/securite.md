# Tâche « securite » — failles et dépendances dangereuses de deux apps

Cibles : les apps nommées dans `/entree/mission.md` (en général deux), chacune dans `/work/<app>`.
But : trouver les failles de sécurité et les dépendances dangereuses, **corriger ce qui est petit et
sûr**, proposer le reste, classé par gravité. Partage ton temps à parts égales entre les cibles ;
finis entièrement la première (constats, corrections, sorties à jour) avant d'ouvrir la seconde.

## Ordre de travail, par cible

### 1. Carte de l'app (15 minutes au plus)
- `backend/config/settings.py`, `backend/config/urls.py`, `backend/api/urls.py` : la liste de toutes
  les routes, avec pour chacune la vue et sa permission. Écris cette carte dans `/tmp`, elle guide
  le reste.
- Les modèles qui portent un propriétaire (email, `owner`, membre, partage) : c'est la règle d'accès
  que chaque vue doit appliquer.
- Les points d'entrée hors requête : tâches Celery, commandes de gestion, signaux, webhooks, hooks
  appelés par un autre service, autre service du dépôt (`engine/`, `relay/`…).

### 2. Backend — points à contrôler (dans cet ordre de priorité)
1. **Authentification** (`api/authentication.py`) : les règles du § 5 du préambule, une par une —
   `azp`, `groups`, `email`, RS256, expiration, `PyJWKClientError`. Toute autre classe
   d'authentification (clé partagée, ticket, `Bridge`, compte de service) : comparaison à temps
   constant (`hmac.compare_digest`), refus si la clé attendue est vide, portée limitée à ses routes.
2. **Permissions** : `DEFAULT_PERMISSION_CLASSES` ; chaque `permission_classes`,
   `authentication_classes = []`, `AllowAny`, `@permission_classes`, vue Django hors DRF
   (`django.views.static.serve`, `HttpResponse` direct) — chacune justifiée par la feuille de route ?
3. **IDOR / filtre de propriétaire** : `get_queryset` filtré par l'utilisateur pour *toutes* les
   actions (list, retrieve, update, destroy, et chaque `@action(detail=True)`) ; recherche des
   `Model.objects.get(pk=…)` / `get_object_or_404(Model, …)` qui contournent ce filtre ; champs de
   clé étrangère écrivables (`PrimaryKeyRelatedField`, `fields = '__all__'`) dont le `queryset`
   n'est pas filtré — on rattache alors son objet à celui d'un autre ; champs de propriétaire
   écrivables (affectation de masse) ; rôles (gestionnaire / membre / lecteur) appliqués aussi à
   l'écriture.
4. **Fichiers et chemins** : `os.path.join`/`Path` avec une entrée utilisateur (`..`, chemin absolu,
   `\x00`), `relative_path` envoyé à `storage`, nom de fichier téléversé repris tel quel, archive
   décompressée (zip-slip), `Content-Disposition` et `Content-Type` des fichiers servis (HTML ou SVG
   servis en ligne = XSS), taille maximale des envois et des lectures.
5. **SSRF** : tout `requests`/`httpx`/`urllib` vers une URL venue d'un utilisateur ou de la base
   (iCal, import, webhook, aperçu de lien) : refus des adresses internes, redirections contrôlées,
   résolution DNS unique (exemple de référence : `ical_fetch` de `conciergerie`), délai (`timeout=`)
   sur **chaque** appel sortant, taille bornée.
6. **Secrets et journaux** : clé, mot de passe ou jeton en dur dans le code (hors faux secrets de
   test évidents) ; secret dans une URL (`?token=`, `?key=`) ; `str(exc)` / `repr(exc)` d'une
   exception `requests` journalisé ou rendu ; `logger.*` qui écrit un en-tête `Authorization`, un
   corps de requête ou une query string ; trace d'erreur rendue au client ; jeton persisté en base
   ou dans les arguments d'une tâche Celery (utiliser un `contextvars.ContextVar`, jamais un champ
   JSON exposé).
7. **Réglages** : `DEBUG` par défaut à `False` ; `SECRET_KEY` sans défaut utilisable ;
   `ALLOWED_HOSTS` ; `CORS_ALLOW_ALL_ORIGINS` seulement si `DEBUG` ; `/api/schema/` et `/api/docs/`
   en `DEBUG` seulement ; `gunicorn.conf.py` (retrait de `SCRIPT_NAME`, pas de journal d'accès) ;
   cookies et CSRF si l'app a des sessions.
8. **Injections** : SQL brut (`raw(`, `extra(`, `cursor.execute` avec f-string ou `%`), `subprocess`
   avec `shell=True` ou argument utilisateur, `eval`/`exec`, `pickle`, `yaml.load` sans `SafeLoader`,
   `mark_safe`/`format_html` mal utilisés, XML sans `defusedxml`, expression régulière sur entrée
   utilisateur (ReDoS).
9. **Coffre** : clés d'API d'utilisateur en clair en base, rendues par l'API, ou journalisées.
10. **Annuaire** : toute route qui rend des comptes autres que l'appelant.
11. Sérialiseurs appelés sans `request` (tâches, commandes) qui montreraient un champ masqué.

### 3. Frontend (`frontend/src`)
- `core/` : `pkceMethod: 'S256'`, intercepteur avec `carriesToken` et `tokenBases()`,
  `redirect-uri.ts` ; comparer au gabarit décrit au § 5 du préambule.
- `grep -rn "localStorage\|sessionStorage" src` : seules des préférences d'affichage (thème) ; jamais
  un jeton, une clé, une donnée personnelle.
- `grep -rn "innerHTML\|outerHTML\|bypassSecurityTrust\|DomSanitizer\|insertAdjacentHTML\|eval(\|new Function" src`
  : chaque occurrence alimentée par une donnée utilisateur ou serveur est une XSS probable.
- `[href]`/`window.open`/`location` alimentés par une donnée (schéma `javascript:`) ; `?token=` dans
  une URL construite ; secret dans `env.js`/`environment*.ts`.

### 4. Fichiers que tu relis sans les corriger (chemins refusés)
`docker-compose*.yml`, `Dockerfile*`, `nginx*.conf`, `nginx-entrypoint.sh` : ports liés à
`127.0.0.1`, pas d'`env_file: .env` sur le frontend, pas de `privileged`/`cap_add`/`docker.sock`,
montages limités au dossier de l'app, images de base épinglées et récentes, en-têtes de sécurité
nginx. Tout écart va dans « Non corrigé — proposé » avec le changement exact.

### 5. Dépendances dangereuses
Lance ce qui suit avec un délai (`timeout 600`), depuis `/tmp` pour ne rien écrire dans `/work` :
- Python : `timeout 600 uvx pip-audit --no-deps --disable-pip -r /work/<app>/backend/requirements.txt`
  (et chaque autre `requirements*.txt`). Si les versions ne sont pas épinglées (`==`), dis-le
  (constat `moyenne`) et audite les versions effectivement résolues si c'est rapide, sinon lis-les.
- npm : `cd /work/<app>/frontend && timeout 600 npm audit --package-lock-only --json > /tmp/audit-<app>.json`
  (ne crée pas de `node_modules`) ; idem pour tout autre `package-lock.json` du dépôt (`engine/`,
  `relay/`…).
- Si un outil est injoignable, lis les versions à la main et compare aux avis connus ; dis dans
  « Limites » ce qui n'a pas pu être audité.
- Pour chaque vulnérabilité : est-elle **atteignable** dans l'usage de l'app (le paquet est-il
  utilisé à l'exécution, la fonction vulnérable appelée) ? Une dépendance de développement ou de
  build seulement est au plus `moyenne`.
- Correction : mise à jour minimale qui corrige (règles du § 4 du préambule). Une mise à jour de
  `requirements*.txt` fait reconstruire l'image de test par l'hôte : ne change qu'un paquet par
  vulnérabilité, sans toucher les autres lignes. Une version majeure, une image de base ou une
  dépendance d'app marquée lourde (`.heavy-build` à la racine de l'app) : proposition seulement.

## Section propre à la tâche dans le rapport

Après « Constats », ajoute `## Dépendances` : par cible, outil lancé et résultat (nombre d'avis par
gravité), tableau paquet · version · avis (identifiant public) · atteignable oui/non · action.

## Ce que tu ne fais pas
- Pas de test d'intrusion réel : tu n'as accès à aucune app en service, et tu ne cherches pas à en
  joindre une par Internet.
- Pas de refonte d'authentification ni de changement de modèle d'autorisation : proposition.
- Pas de durcissement qui casse un usage décrit par la feuille de route (un `AllowAny` décidé, un
  partage public voulu) : vérifie que le comportement voulu est conservé, et dis-le.
