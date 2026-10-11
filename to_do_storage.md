# to_do_storage — rendre `storage` simple à utiliser et à modifier

Analyse du 2026-10-11. L'analyse n'a rien modifié dans le code ; seul le Lot 0 (sécurité) a été écrit
ensuite, le même jour — voir la section qui suit.
Convention de lecture : **[C]** = constaté (navigateur réel du lab avec le compte `e2edev`, ou lecture
directe du code / de la base) ; **[D]** = déduit du code sans l'avoir exécuté.

---

## Lot 0 — fait le 2026-10-11 (code écrit et vérifié, **non commité, non déployé**)

La faille décrite en 2.3 est corrigée dans `storage/backend/` ; le reste de ce document (analyse et
lots 1 à 7) est inchangé et reste à décider.

**Ce qui change**
- `storage/backend/api/content_safety.py` (nouveau) : la politique de service, par listes blanches.
- `storage/backend/api/views.py` (`FileContentView.get`) : n'émet plus le type du déposant, applique
  la politique.
- `storage/backend/api/tests/` (nouveau, 49 tests) et `storage/backend/config/settings_test.py`.

**La règle.** Le type déclaré par le déposant n'est jamais recopié dans la réponse ; il sert de clé
dans des listes tenues dans le code.

| Type déclaré | Type émis | Disposition | CSP |
|---|---|---|---|
| PNG, JPEG, GIF, WebP, AVIF, BMP, ICO ; audio et vidéo courants | forme canonique | `inline` | `sandbox` |
| PDF | `application/pdf` | `inline` | aucune (sinon la visionneuse intégrée ne se charge pas) |
| `text/plain` | `text/plain; charset=utf-8` (ou latin-1 / windows-1252 déclaré) | `inline` | `sandbox` |
| formats inertes connus : `model/*`, `font/*`, autres `image/*` `audio/*` `video/*`, JSON, zip, CSV, bureautique | inchangé | `attachment` | `sandbox; default-src 'none'` |
| **tout le reste** — HTML, XHTML, SVG, tout XML (`*/xml`, `*+xml`), JavaScript, CSS, type inconnu, vide ou illisible | `application/octet-stream` | `attachment` | `sandbox; default-src 'none'` |

`X-Content-Type-Options: nosniff` sur toutes les réponses de contenu. Octets, codes de retour,
routes et authentification inchangés.

**Écart avec le Lot 0 décrit plus bas** : un SVG n'est **plus** affichable par `<img>` directement
depuis `storage` (il sort en `application/octet-stream`). Raison : conciergerie rouvre les factures
depuis un `Blob` dans un nouvel onglet, et un blob `image/svg+xml` s'exécute sur l'origine de la
page, quels que soient les en-têtes de `storage`. Aucun SVG n'est stocké à ce jour.

**Vérifié**
- 49 tests Django verts (conteneur jetable, SQLite en mémoire, sans réseau) :
  `docker run --rm --env-file storage/.env --network none -v "$PWD/storage/backend:/app:ro" -w /app storage-backend:latest python manage.py test --settings=config.settings_test api`
- Essai d'origine rejoué dans Chromium (`lab-runner`) contre un backend jetable portant ce code :
  HTML, SVG, XML-XHTML, HTML en majuscules et HTML sans type → téléchargés, **aucun ne s'exécute** ;
  HTML déclaré `image/png` → image cassée ; HTML déclaré `text/plain` → affiché comme texte ;
  PNG réel → affiché, y compris par `<img src="…?token=">`.
- **Non vérifié** : l'affichage d'un PDF dans la visionneuse (le Chromium sans écran du runner
  télécharge tous les PDF) — ses en-têtes sont ceux d'avant, `nosniff` en plus.

**À rejouer après déploiement** (script gardé hors dépôt, à recopier si besoin) : même essai avec
`TARGET=https://<domaine>/storage-api`, puis une facture PDF dans conciergerie, une photo et un
maillage dans atelier-3d, une icône dans craft-lab.

**Reste ouvert**
- **`?token=`** : toujours accepté, sur toutes les routes. Trois frontends s'en servent (atelier-3d,
  craft-lab, arbre-genealogique) pour `<img>`, `GLTFLoader` et un lien de téléchargement. S'en passer :
  charger par `fetch` avec en-tête puis `Blob`, ou des adresses signées à courte durée liées à un
  chemin. À défaut, le limiter au `GET` de la route de contenu.
- **`DEBUG=True`** dans `storage/.env` en service (page 404 technique de Django visible).
- **Proxys des apps** (conciergerie, restauration, atelier-3d) : ils relaient le `Content-Type` de
  `storage` en `inline` sans `nosniff`. Ils héritent maintenant d'un type sûr, mais ne se protègent
  pas eux-mêmes.
- Le dépôt accepte toujours n'importe quel type : le filtrage est fait à la lecture, pas à l'écriture.

---

## Résumé

**Constat.** L'interface de `storage` est une liste en lecture avec deux boutons par ligne
(« Télécharger », « Supprimer »). Sur les 27 gestes usuels passés en revue, **1 est présent,
7 sont partiels, 19 absents**. Il n'existe ni sélection (un Maj-clic ou un glissé surligne du texte), ni
menu contextuel, ni raccourci clavier, ni renommage, ni déplacement, ni copie, ni création de
dossier, ni aperçu, ni tri, ni recherche ; le dépôt de fichiers ne fonctionne que sur un bandeau de
60 px ; un conflit de nom **écrase sans prévenir** ; supprimer dix fichiers demande vingt clics, et un
dossier ne peut pas être supprimé du tout. Côté code, tout l'écran tient dans **un composant de
377 lignes + 233 lignes de gabarit** qui mêle navigation, partages, membres et téléversement ; il
n'y a **aucun test**, ni côté Angular (pas de cible de test dans `angular.json`), ni côté Django.
L'API ne sait faire que quatre choses sur un fichier : lister, déposer, lire, supprimer.

**Deux découvertes hors ergonomie, à traiter avant le reste.**
1. **Faille : un fichier HTML déposé dans `storage` s'exécute sur l'origine du lab** [C]. Ouvert par
   `…/storage-api/api/files/<espace>/content/x.html?token=<jeton>`, il est servi `text/html` en
   `inline`, sans `nosniff` ni CSP : son script a tourné sur `https://<domaine>` , l'origine que
   partagent toutes les apps. Voir Lot 0.
2. **L'usage humain est encore quasi nul** [C] : 958 fichiers (2,05 Go), dont **1 seul** dans un
   espace personnel ; les 957 autres sont dans des partages (450 au total), pour l'essentiel ceux
   des apps. Le gestionnaire de
   fichiers est donc à construire pour un usage à venir, et la première question est de savoir ce
   qu'un humain a le droit de faire dans un partage **géré par une app** (y renommer un fichier
   casse la référence que l'app garde en base).

**Bonne nouvelle structurante.** Les octets sont rangés sous un nom opaque (`blobs/<uuid>`),
jamais sous le chemin logique [C]. Renommer ou déplacer un fichier — ou un dossier entier — est donc
un simple `UPDATE` en base, sans toucher au disque. Tout ce qui manque à l'API **s'ajoute par de
nouvelles routes** ; aucune des routes qu'utilisent les neuf apps consommatrices n'a besoin de changer.

**Cible.** Un seul volet latéral (arborescence « Mes fichiers » + partages), une barre d'actions
au-dessus de la liste, une liste triable (puis une grille à vignettes), un panneau de téléversement
en bas à droite, un aperçu en superposition. Les mêmes actions sont atteignables de trois façons
— barre, clic droit / appui long, clavier — parce qu'elles viennent d'**une seule table d'actions**
dans le code. Bibliothèques : `@angular/cdk` 21 (menu, glisser-déposer, clavier) et
`@viselect/vanilla` (rectangle de sélection) ; le reste s'écrit à la main.

**Les trois premiers lots** (après le correctif de sécurité, ½ journée) :
- **Lot 1 — Sélection, clavier, menu contextuel** (frontend seul, ~3 j) : clic / Ctrl / Maj /
  rectangle glissé / Ctrl+A, barre d'actions sur la sélection, suppression et téléchargement
  groupés avec annulation, clic droit et appui long, flèches / Entrée / Suppr / Échap, tri par
  colonne, filtre par nom. Le composant unique est découpé au passage, sans réécriture.
- **Lot 2 — Glisser-déposer et téléversement** (frontend seul, ~3 j) : dépôt sur toute la liste et
  sur un dossier, dossiers entiers, file d'attente avec progression par fichier, annulation,
  reprise après échec, choix explicite en cas de conflit de nom, « Nouveau dossier ».
- **Lot 3 — Déplacer, renommer, copier, corbeille** (backend additif + frontend, ~5 j) : glisser
  une sélection vers un dossier, couper / copier / coller, F2, suppression de dossier, corbeille.
  Premier lot qui touche l'API : il commence par des tests de contrat qui figent l'existant.

Les lots 1 et 2 ne touchent ni le backend ni l'API : risque nul pour les apps consommatrices.

---

## 1. État des lieux de l'interface

### 1.1 Ce qu'on voit

Bureau 1280 px [C] : le bandeau Foyer (240 px, un seul lien « Fichiers »), puis un **second** volet
de 240 px (« Mes fichiers », « Partages »), puis la zone principale — il lui reste 727 px. Dans la
zone : le chemin en police mono, un bandeau pointillé « Déposer des fichiers ici, ou cliquer pour
choisir », et un tableau à quatre colonnes (Nom, Taille, Modifié, actions). Les dossiers sont une
ligne `📁 nom — —`, sans taille, sans date, sans action.

Mobile 390 px [C] : le volet des espaces passe **au-dessus** de la liste (le tableau commence à
480 px du haut) ; le tableau mesure 492 px de large pour 342 px disponibles, la page défile
horizontalement (517 px) et les noms se coupent sur trois lignes.

### 1.2 Combien de gestes

| Tâche | Aujourd'hui |
|---|---|
| Déposer des fichiers dans un dossier existant | ouvrir le dossier, puis viser le bandeau de 60 px. Lâcher sur le tableau ne fait rien [C] |
| Créer un dossier | **impossible dans l'interface**. Un dossier n'existe que s'il contient un fichier ; seul un appel API avec un chemin contenant `/` en crée un [C] |
| Supprimer 10 fichiers | 20 clics (bouton + `confirm()` natif, dix fois) [C] |
| Supprimer un dossier | impossible ; il faut vider chaque sous-dossier fichier par fichier |
| Renommer, déplacer, copier | impossible (l'API répond 405 à `PATCH`/`PUT`) [C] ; contournement : télécharger, redéposer, supprimer |
| Télécharger 10 fichiers | 10 clics ; chaque fichier est chargé entièrement en mémoire avant l'enregistrement, sans indicateur [D] |
| Voir une image ou un PDF | impossible sans télécharger ; le double-clic ne fait rien [C] |
| Retrouver un fichier | parcourir les dossiers à la main ; ni tri, ni recherche [C] |

### 1.3 Les gestes, un par un

| # | Geste | État | Constat |
|---|---|---|---|
| 1 | Sélection simple | **absent** | un clic sur une ligne de fichier ne change rien [C] |
| 2 | Sélection multiple Ctrl / Maj | **absent** | Maj-clic sélectionne **du texte** (64 caractères surlignés) [C] |
| 3 | Rectangle glissé | **absent** | le glissé surligne le texte du tableau (341 caractères) [C] |
| 4 | Tout sélectionner | **absent** | Ctrl+A sélectionne le texte de la page [C] |
| 5 | Glisser-déposer pour téléverser des fichiers | **partiel** | fonctionne sur le bandeau seulement ; rien sur le tableau [C] ; hors bandeau le navigateur ouvre le fichier lâché [D] |
| 6 | … des dossiers entiers | **absent** | le code ne lit que `dataTransfer.files` ; l'`<input>` n'a pas `webkitdirectory` [C] |
| 7 | Glisser-déposer pour déplacer | **absent** | lignes non `draggable` [C], aucune route de déplacement |
| 8 | Copier / couper / coller | **absent** | [C] |
| 9 | Renommer en place | **absent** | F2 sans effet [C] ; pas de route |
| 10 | Créer un dossier | **absent** | voir 1.2 |
| 11 | Supprimer | **partiel** | un fichier à la fois, `confirm()` natif, **définitif**, pas de corbeille ni d'annulation [C] ; aucun moyen sur un dossier |
| 12 | Menu contextuel | **absent** | clic droit non intercepté (menu du navigateur) [C] ; pas d'appui long |
| 13 | Raccourcis clavier | **absent** | Suppr, F2, Entrée, Retour arrière, `/`, Ctrl+C/V : aucun appel, aucun effet [C] |
| 14 | Navigation au clavier | **absent** | Tab n'atteint que les boutons « Télécharger / Supprimer » ; **dossiers, fil d'Ariane et liens d'espaces sont inatteignables** (`<a>` sans `href`, `<tr>` cliquable sans `tabindex`) [C] |
| 15 | Fil d'Ariane | **présent** | cliquable, URL profonde, bouton Précédent du navigateur fonctionnel [C] ; hors clavier (14) |
| 16 | Arborescence latérale | **partiel** | arbre des **partages** seulement ; les dossiers n'y figurent pas, pas de pli / dépli |
| 17 | Vue liste / grille, vignettes | **partiel** | liste seule, sans icône de type ; ni grille ni vignette |
| 18 | Tri et colonnes | **absent** | ordre alphabétique figé ; cliquer un en-tête ne trie pas [C] |
| 19 | Recherche et filtres | **absent** | aucun champ [C] ; `?search=` est ignoré par l'API [C] |
| 20 | Aperçu | **absent** | aucun type |
| 21 | Télécharger un dossier / une sélection | **absent** | pas d'archive, ni côté client ni côté serveur |
| 22 | Téléversement : progression, file, reprise, conflits | **partiel** | un pourcentage du fichier en cours, sans nom ni compteur ; envoi séquentiel ; pas d'annulation ; **une erreur abandonne les fichiers restants** [D] ; conflit de nom : **écrasement silencieux** (3 o → 17 o, aucun dialogue) [C] ; limite de 200 Mo découverte à l'échec |
| 23 | Partage | **partiel** | membres par courriel avec droit lecture/écriture, groupe (affiché, non modifiable), emplacement dans la hiérarchie ; pas de lien à copier ; on partage un **espace nommé entier**, jamais un dossier existant ; un membre ne voit pas la liste des membres |
| 24 | Informations et propriétés | **absent** | l'auteur du dépôt, la date de création et le type sont renvoyés par l'API mais jamais affichés |
| 25 | Quota et espace occupé | **absent** | ni affichage ni limite, hors 200 Mo par fichier |
| 26 | Tactile et mobile | **partiel** | utilisable mais débordement horizontal ; cibles de 24 px de haut pour les actions, 16 px pour le fil d'Ariane, 24×24 pour « + », 38 px pour les espaces — toutes sous les 44 px de Foyer [C] ; rupture à **720 px** au lieu des 900 px de Foyer [C] |
| 27 | Accessibilité | **absent** | aucun rôle ARIA, aucune zone `aria-live` (progression et erreurs muettes), en-têtes sans `scope`, icônes en emoji [C] |

### 1.4 Défauts relevés au passage

- **Un membre en écriture ne peut pas écrire depuis l'interface** [D] : `canWrite` ne regarde que
  « mon espace » et « mes partages » (`browser.component.ts:111`). Un membre `write` ou un membre du
  groupe d'un partage ne voit ni la zone de dépôt ni « Supprimer », alors que l'API l'autoriserait
  et que l'arbre renvoyé par `GET /api/shares/` porte déjà `can_write`. Non essayé en réel, pour ne
  toucher à aucun partage.
- **Une erreur masque la liste** [D] : le gabarit affiche *soit* l'erreur *soit* le tableau. Un
  dépôt refusé fait disparaître les fichiers jusqu'au rechargement.
- **Tout l'espace est rechargé à chaque changement de dossier** [C] : ouvrir un dossier relance
  `GET /api/files/<espace>/` en entier. Sans gravité aujourd'hui (le plus gros espace compte
  116 fichiers), mais inutile.
- **Polices Foyer en 404** [C] : six requêtes `/assets/fonts/*.woff2` échouent à chaque chargement
  (défaut déjà connu du lab, URL absolue qui ignore `<base href>`).
- **Thème sombre** : la bascule manuelle fonctionne [C].

---

## 2. État des lieux du code

### 2.1 Frontend (Angular 21.2.18, composants autonomes, signaux)

```
src/app/app.ts / app.html / app.scss        coquille Foyer (bandeau, thème, menu mobile)
src/app/app.routes.ts                       une route : '**' → BrowserComponent
src/app/core/api.service.ts      161 l.     tous les appels HTTP, types inclus
src/app/core/keycloak.service.ts, auth.interceptor.ts, auth.guard.ts, theme.service.ts
src/app/pages/browser/browser.component.{ts,html,scss}   377 + 233 + 343 l.
```

Aucune dépendance au-delà d'Angular, `rxjs` et `keycloak-js` — ni CDK ni bibliothèque d'interface.

Ce qui rend une évolution risquée :
- **Un composant pour tout** : lecture de la route, chargement, dérivation dossiers/fichiers,
  création de partage, membres, déplacement de partage, téléversement, téléchargement, suppression.
  Vingt signaux et champs d'état au même niveau. Ajouter la sélection ici, c'est ajouter un état
  transversal que chaque méthode existante devra penser à remettre à zéro.
- **Aucune couche d'état** : la liste (`allFiles`), le chemin et les droits vivent dans le composant.
  Rien n'est réutilisable par une barre d'actions ou un menu contextuel sans tout passer en `@Input`.
- **Trois notions de « droit d'écriture »** : `canWrite` recalculé côté client (et faux, cf. 1.4),
  `can_write` dans l'arbre de l'API, et la vérité dans `resolve_namespace`.
- **La logique « dossiers » est côté client** : l'API renvoie une liste plate, le composant en
  déduit les dossiers par découpage de chaînes. C'est correct et peu coûteux, mais non testé.
- **Budget de style** : `browser.component.scss` pèse 7 580 octets ; `angular.json` fait **échouer la
  compilation** au-delà de 8 ko par feuille de composant. Y ajouter les styles d'une sélection ou
  d'une grille cassera le build [D — le budget se mesure sur le CSS compilé, le chiffre exact
  diffère]. Le découpage en composants règle ce point de lui-même.
- **Aucun test** : pas de cible `test` dans `angular.json`, aucun `*.spec.ts`, ni `vitest` ni `karma`
  installés [C]. `npm test` ne peut pas tourner. Le seul test est `e2e/cloisonnement.spec.ts`
  (accès à la page), et `CLAUDE.md` interdit un second fichier E2E sans mise à jour de sa section.
- **Dialogues natifs** (`confirm()`) : bloquants, non stylés, impossibles à enrichir (« ne plus
  demander », « annuler »).

Ce qui est sain et à garder : signaux et `computed`, `ApiService` typé et sans logique, URL = état
(chaque dossier a une adresse), aucune couleur en dur (0 valeur hexadécimale dans les deux feuilles) [C].

### 2.2 Backend (Django 5 + DRF)

```
api/models.py          KnownUser, Share (parent, required_groups), ShareMember (rôle), StoredFile
api/views.py   242 l.  7 vues APIView écrites à la main
api/permissions.py     resolve_namespace — l'unique décision d'accès — + validate_new_parent
api/discovery.py       arbre des partages visibles (GET /api/shares/ → tree)
api/authentication.py  JWT Keycloak, liste blanche azp, comptes de service, repli ?token=
api/validators.py      slug d'espace, chemin relatif
management/commands/   create_share, create_group_share, set_share_parent
```

- `StoredFile` : `(namespace, relative_path)` unique, `content` = `blobs/<uuid>`, `size`,
  `content_type`, `uploaded_by_email`, dates. **Le chemin physique n'est jamais dérivé du chemin
  logique** : c'est ce qui rendra déplacement et renommage triviaux.
- **Pas de modèle de dossier** : un dossier vide ne peut pas exister.
- **Suppression définitive**, blob effacé dans la foulée ; pas de transaction entre l'effacement du
  blob et la ligne.
- **Aucun test** [C].
- **Servi par `manage.py runserver`** en production (`Dockerfile`, en-tête `Server: WSGIServer/0.2`
  constaté) : serveur de développement, pour des fichiers jusqu'à 141 Mo.
- **Pas de requêtes partielles** [C] : `Range: bytes=0-1` renvoie 200 et le fichier entier. Lecture
  audio/vidéo sans déplacement possible, pas de reprise de téléchargement.
- **Aucune pagination** : la liste d'un espace part en un bloc ; `build_share_forest` charge les
  450 partages à chaque ouverture de page.
- Qualité d'ensemble : code court, très commenté, décisions de sécurité expliquées sur place.
  `resolve_namespace` est le bon point d'appui — toute nouvelle route doit passer par lui et par
  rien d'autre.

### 2.3 Faille constatée : contenu actif servi sur l'origine du lab

`FileContentView.get` renvoie le `content_type` **fourni par le déposant**, en
`Content-Disposition: inline`, sans `X-Content-Type-Options` ni `Content-Security-Policy` [C]. Avec
le repli `?token=`, l'adresse d'un fichier est ouvrable par simple navigation. Essai réel dans
l'espace de `e2edev` : un fichier `text/html` contenant un script, ouvert dans un nouvel onglet avec
`?token=`, a exécuté ce script sur `https://<domaine>` (titre de page modifié par le script).

Conséquence [D] : un compte du lab dépose un `.html` dans son espace et envoie à une victime le lien
portant **son propre** jeton (valable quelques minutes). Le script tourne dans le navigateur de la
victime sur l'origine commune à toutes les apps : il peut lire leur stockage local et, la victime
ayant une session SSO, obtenir des jetons pour n'importe quelle app. Le SVG (`image/svg+xml`, servi
`inline` de la même façon [C]) ouvre la même porte. Je n'ai pas poussé la démonstration au-delà de
l'exécution du script.

Ce point conditionne aussi l'aperçu (lot 5) : afficher un fichier dans l'interface ne doit jamais
passer par une navigation vers cette adresse.

---

## 3. L'API : ce qui existe, ce qui manque

### 3.1 Contrat actuel — à ne pas casser

Préfixe public `https://<domaine>/storage-api`, interne `http://storage-backend:8000`.
Authentification : `Authorization: Bearer <jwt>` ou `?token=<jwt>` ; `azp` dans la liste blanche.

| Route | Forme | Utilisée par |
|---|---|---|
| `GET /api/me/` | `{email, username, groups}` | interface |
| `GET /api/shares/` | `{owned[], member_of[], tree[]}` | interface |
| `POST /api/shares/` | `{name, parent?}` → 201 `{name, owner_username, required_groups, parent, created_at}` | interface, arbre-genealogique, atelier-3d |
| `PATCH /api/shares/<nom>/` | `{parent}` | interface |
| `DELETE /api/shares/<nom>/` | 204 ; 400 s'il a des enfants | interface, traitement-de-fichiers-compils |
| `GET /api/shares/<nom>/members/` | `[{member_email, role, added_at}]` | interface, arbre-genealogique, atelier-3d |
| `POST /api/shares/<nom>/members/` | `{member_email, role}` → 201 (met à jour le rôle si déjà membre) | interface, conciergerie, tdfc, arbre-genealogique, atelier-3d |
| `DELETE /api/shares/<nom>/members/<courriel>/` | 204 / 404 | les mêmes |
| `GET /api/files/<espace>/[?prefix=]` | liste plate `[{namespace, relative_path, size, content_type, uploaded_by_email, created_at, updated_at}]` | interface, atelier-3d (`listing`, lit `relative_path`, `size`, `updated_at`), conciergerie (sert à faire naître le partage) |
| `POST /api/files/<espace>/` | multipart `file` + `relative_path` → **201** + le même objet ; **remplace** si le chemin existe | les neuf apps |
| `GET /api/files/<espace>/content/<chemin>` | 200, flux, `inline` ; 404 | les neuf apps côté serveur ; **le navigateur directement** avec `?token=` pour atelier-3d, craft-lab, arbre-genealogique, carto-lab, conciergerie, tdfc |
| `DELETE /api/files/<espace>/content/<chemin>` | 204 ; 404 (les clients acceptent les deux) | conciergerie, carto-lab, code-route, restauration, tdfc, arbre-genealogique, atelier-3d |

Apps consommatrices recensées dans `deploiement/*/backend/api/storage_client.py` [C] : **neuf**, et
non six — `code-route` et `craft-lab` s'ajoutent à la liste de `CLAUDE.md`.

Comportements dont des clients dépendent, à figer par des tests avant toute retouche :
- `POST` de fichier : code **201** (tous les clients testent `== 201`), **remplacement** au même
  chemin (la reprise de migration de `tdfc` et `LabStorage` d'atelier-3d s'appuient dessus).
- Auto-création d'un partage au premier accès d'un compte de service à préfixe.
- `POST /api/shares/` sur un nom déjà pris : le client d'arbre-genealogique documente qu'il reçoit
  un **500** et s'en accommode ; ne pas « corriger » ce code sans prévenir.
- Adresse de contenu stable et lisible par `<img>` / `fetch` avec `?token=`.

### 3.2 Ce qui manque, geste par geste

« Additif » = nouvelle route ou nouveau champ ; les routes ci-dessus gardent forme et comportement.

| Besoin | Aujourd'hui | Proposition | Touche les apps ? |
|---|---|---|---|
| Renommer / déplacer un fichier ou un dossier | absent (405) | `POST /api/files/<espace>/ops/` : `{op:"move", items:[chemins], dest:"dossier/", on_conflict:"fail"\|"rename"\|"replace"}` → résultat par élément. `UPDATE` de `relative_path` en une transaction, aucun octet déplacé | non (additif) |
| Copier | absent | même route, `op:"copy"` (copie du blob côté serveur) | non |
| Suppression groupée, suppression de dossier | une requête par fichier | même route, `op:"delete"` / `op:"trash"` avec préfixes | non |
| Déplacer d'un espace à un autre | interdit par le modèle (« un fichier ne change jamais de namespace ») | `dest_namespace` dans `ops`, droit d'écriture exigé des deux côtés ; met à jour `namespace` et `share` | non, mais à décider (Q3) |
| Dossier vide, « Nouveau dossier » | impossible | table `Folder(namespace, path)` + `GET/POST/DELETE /api/folders/<espace>/`. La liste de fichiers reste plate et inchangée | non |
| Corbeille | absent | table **séparée** `TrashedFile` (la ligne quitte `stored_files`, le blob reste) + `GET /api/trash/<espace>/`, restauration, purge. `DELETE …/content/…` **reste définitif** | non — c'est la raison de la table séparée : aucune requête existante n'a à filtrer « non supprimé » |
| Archive d'un dossier / d'une sélection | absent | d'abord côté navigateur (lot 4) ; route serveur `GET /api/files/<espace>/archive/?path=` seulement si le besoin se confirme | non |
| Vignettes | absent | `GET /api/files/<espace>/thumb/<chemin>?s=256`, générée à la demande, mise en cache sur disque | non |
| Lecture partielle (audio, vidéo, reprise) | absent | prise en charge de `Range` sur la route de contenu (206 seulement si l'en-tête est envoyé) | non en principe — aucun client n'envoie `Range` [D] ; à couvrir par test |
| Contenu actif neutralisé | absent (faille 2.3) | `X-Content-Type-Options: nosniff` partout ; pour `text/html`, `image/svg+xml`, XML, JavaScript : `Content-Disposition: attachment` + `Content-Security-Policy: sandbox` | **à vérifier** : sans effet sur `<img>`, `fetch`, `GLTFLoader` ; gênerait seulement une app qui ouvrirait un HTML/SVG par navigation directe — aucune trouvée, non vérifié exhaustivement |
| Recherche | absent | dans l'espace courant : côté navigateur, la liste complète est déjà chargée. Tous espaces : `GET /api/search/?q=` plus tard | non |
| Espace occupé, quota | absent | occupation : calculable côté navigateur. Quota : `GET /api/usage/` + refus à l'envoi | le refus toucherait les apps si le quota s'appliquait à leurs partages — à exclure (Q5) |
| Droit d'écriture réel | recalculé à tort côté client | lire `can_write` dans `tree` (déjà renvoyé) ; à terme un en-tête ou un champ sur la liste | non |
| Téléversement reprenable (tus) | absent | non proposé : 200 Mo au plus, réseau local ou fibre ; la relance d'un fichier échoué suffit | — |
| Lien public | absent | non proposé, cf. Q4 | — |

### 3.3 Le point de conception à trancher avant le lot 3 : les partages gérés par une app

Renommer, déplacer ou mettre à la corbeille un fichier de `carto-lab`, `atelier-3d` ou
`conciergerie-bien-12` depuis l'interface de `storage` casse l'app : elle garde le chemin en base.
La suppression le permet déjà aujourd'hui (pour le propriétaire et les membres en écriture).
Proposition : les **nouvelles** opérations (`ops`, corbeille, dossiers) sont refusées par le backend
dans un partage dont le propriétaire est un compte de service (`owner_username` commençant par
`service:`) ou qui figure dans `KEYCLOAK_SERVICE_WRITE_SHARES` ; l'interface y affiche « géré par
l'application … » et n'offre que lecture, aperçu et téléchargement. Les routes existantes ne
bougent pas. Voir Q2.

---

## 4. La cible

### 4.1 L'écran

```
┌ Foyer ┬ Espaces ──────────┬ e2edev › photos › 2026          [Rechercher…]  [☰ ▦] ┐
│       │ ▾ Mes fichiers    ├──────────────────────────────────────────────────────┤
│ Fi    │   ▸ photos        │ [+ Nouveau ▾] [Téléverser]  │ 3 sélectionnés :       │
│       │   ▸ factures      │   Télécharger · Déplacer · Renommer · Supprimer   ✕  │
│       │ ▾ Partages        ├──────────────────────────────────────────────────────┤
│       │   famille   écrit.│ ☐ Nom ▲            Taille    Modifié        Par      │
│       │   ▸ carto-lab  app│ ☐ 📁 été             12 Mo    03/08 14:02   —        │
│       │ Corbeille         │ ☑ 🖼 plage.jpg       2,1 Mo   03/08 14:01   sacha    │
│       │                   │ ☑ 🖼 dune.jpg        1,8 Mo   03/08 14:01   sacha    │
│       │ 1,2 Go occupés    │ ☑ 📄 notes.pdf       340 Ko   02/08 09:12   sacha    │
└───────┴───────────────────┴───────────────────────────── Envois : 2/5 ▴ ─────────┘
```

- **Un seul volet latéral** pour les espaces, repliable, avec les dossiers dans l'arbre. Sous
  900 px il devient un tiroir ouvert depuis le fil d'Ariane ; la liste occupe toute la largeur.
  (Aujourd'hui deux volets de 240 px se suivent.) Le bandeau Foyer reste tel quel.
- **Barre d'actions contextuelle** : sans sélection, « Nouveau » et « Téléverser » ; avec sélection,
  les actions applicables. Sur mobile elle se place en bas d'écran, boutons de 44 px.
- **Liste** : lignes de 44 px, case à cocher au survol et toujours visible au tactile, colonnes
  triables, sur mobile deux lignes par élément (nom, puis taille · date) sans tableau.
- **Grille** (lot 5) : vignettes pour les images, icône de type sinon.
- **Panneau d'envois** en bas à droite : un fichier par ligne, progression, annuler, relancer.
- **Aperçu** en superposition : flèches pour passer au suivant, Échap pour fermer.

### 4.2 Les gestes

| Geste | Effet |
|---|---|
| Clic | sélectionne l'élément seul |
| Ctrl+clic / Maj+clic | ajoute / étend la sélection |
| Glissé depuis le vide | rectangle de sélection |
| Glissé depuis un élément sélectionné | déplace la sélection vers un dossier, un cran du fil d'Ariane, un nœud de l'arbre |
| Double-clic, Entrée | ouvre le dossier / l'aperçu |
| Clic droit, appui long | menu contextuel (mêmes actions que la barre) |
| ↑ ↓ (←→ en grille), Début, Fin | déplace le curseur ; avec Maj, étend |
| Ctrl+A · Échap | tout sélectionner · désélectionner |
| Suppr · F2 · Ctrl+C / X / V | corbeille · renommer en place · copier / couper / coller |
| Retour arrière ou Alt+↑ | dossier parent |
| `/` ou Ctrl+F | champ de recherche |
| Dépôt de fichiers ou de dossiers | sur la liste : dossier courant ; sur une ligne dossier : ce dossier |
| Suppression | immédiate, avec « Annuler » pendant quelques secondes ; pas de boîte de confirmation |

### 4.3 Organisation du code visée

```
core/files-api.service.ts, core/shares-api.service.ts     appels HTTP, rien d'autre
features/browser/
  browser.store.ts          signaux : espace, chemin, entrées, tri, filtre, droits, presse-papiers
  entries.ts                fonctions pures : liste plate → dossiers + fichiers, tri, nom libre en cas de conflit
  selection.ts              classe pure : clic, Ctrl, Maj, plage, rectangle, tout
  actions.ts                LA table des actions : { id, libellé, icône, raccourci, visible(sel, ctx), exécuter(sel) }
  upload-queue.service.ts   file, parallélisme, progression, annulation, relance, conflits
  file-list/  toolbar/  breadcrumb/  space-tree/  share-panel/  upload-panel/  context-menu/  preview/
```

Trois règles qui font la « facilité de modification » :
1. **Une action = une entrée dans `actions.ts`.** La barre, le menu contextuel et le clavier la
   lisent tous les trois. Ajouter « Dupliquer » ne touche qu'un fichier.
2. **La logique est dans des fichiers sans Angular** (`entries.ts`, `selection.ts`) : testable en
   quelques millisecondes, sans navigateur.
3. **Les composants n'appellent jamais l'API** : ils lisent le magasin et déclenchent des actions.

### 4.4 Écrire soi-même ou prendre une bibliothèque

Vérifié le 2026-10-11 sur le registre npm, PyPI et les dépôts GitHub (licence, date de dernière
publication, dépendances déclarées) — pas de mémoire.

**À prendre**

| Bibliothèque | Usage | Licence | Entretien | Compatibilité Angular 21 |
|---|---|---|---|---|
| `@angular/cdk` **21.2.14** | `cdk/menu` (`CdkContextMenuTrigger`, clavier et ARIA fournis), `cdk/drag-drop` (déplacement), `cdk/a11y` (piège de focus, annonces), `cdk/overlay` + `cdk/dialog` (aperçu, confirmations), `cdk/scrolling` (défilement virtuel si un jour nécessaire) | MIT | équipe Angular ; 21.2.14 du 2026-06-03, étiquette `v21-lts` | pair `@angular/core ^21 \|\| ^22` — exact. Ne **pas** prendre `latest` (22.2.2), qui exige Angular 22 |
| `@viselect/vanilla` 3.10.1 | rectangle de sélection (souris et tactile, défilement automatique) | MIT | publié 2026-09-04, dépôt `simonwep/viselect` poussé 2026-09-13, non archivé | sans dépendance ni lien avec Angular : à envelopper dans une directive d'une trentaine de lignes |
| `client-zip` 2.5.1 | archive d'une sélection fabriquée dans le navigateur, en flux, sans compression | MIT | publié 2026-09-14 | sans dépendance |
| `Pillow` 12.3.0 (Python) | vignettes côté serveur | MIT-CMU | — | Python ≥ 3.10, image actuelle en 3.12 |

**À écrire soi-même** (peu de code, et c'est là que vit le comportement propre à `storage`) :
le modèle de sélection, la table d'actions et les raccourcis (un `HostListener` sur la liste — pas
besoin de `@ngneat/hotkeys`), le dépôt de fichiers et le parcours de dossiers
(`DataTransferItem.webkitGetAsEntry`, une cinquantaine de lignes), la file d'envoi, le tri, le
filtre, l'aperçu image / texte / audio / vidéo (balises natives alimentées par un `Blob`).

**Écartées**

| Bibliothèque | Raison |
|---|---|
| `ngx-drag-to-select` 5.0.1 | dernière publication 2021-12-09, dépôt sans activité depuis 2024-07, 31 tickets ouverts |
| `ngx-explorer` 5.0.2 (gestionnaire complet) | dernière publication 2024-07-01, dépôt GitHub déplacé (301) ; impose son propre modèle de données |
| `@syncfusion/ej2-angular-filemanager` | licence propriétaire (« Community License » sous conditions de revenu et d'effectif) ; impose un protocole serveur propre, donc une seconde API |
| `devextreme-angular` (FileManager) | le paquet `devextreme` requis est sous licence commerciale (« SEE LICENSE IN README ») |
| `ngx-file-drop` 16.0.0 | entretenue, MIT, mais remplace cinquante lignes ; dernière version de 2023 |
| `@uppy/*`, `tus-js-client` | la reprise d'envoi exige un protocole serveur (tus) que rien ne justifie à 200 Mo par fichier |
| `ngx-extended-pdf-viewer` 31, `pdfjs-dist` | le lecteur PDF du navigateur suffit, dans un `<iframe>` alimenté par un `Blob` |
| `zipstream-ng` (Python) | LGPL-3.0-only ; si une archive serveur devient nécessaire, `stream-zip` (MIT) ou `zipfile` de la bibliothèque standard |

---

## 5. Plan par lots

Chaque lot est livrable seul et se clôt par ses tests. Efforts en jours de travail d'une session
suivie, vérification en navigateur réel comprise.

### Lot 0 — Neutraliser le contenu actif (sécurité) — ½ j

> **Fait le 2026-10-11** — voir la section en tête de ce document, qui fait foi (le SVG n'est
> finalement plus servi comme image). Le texte ci-dessous est la proposition d'origine.

- **Objectif** : fermer la faille 2.3.
- **Backend** : sur `FileContentView.get`, `X-Content-Type-Options: nosniff` toujours ; pour les
  types actifs (`text/html`, `application/xhtml+xml`, `image/svg+xml`, `text/xml`,
  `application/xml`, `text/javascript`, `application/javascript`) : `Content-Disposition: attachment`
  et `Content-Security-Policy: sandbox; default-src 'none'`. Encoder le nom de fichier
  (`filename*=UTF-8''…`).
- **Frontend / API** : rien ; forme des réponses inchangée.
- **Tests** : (1) le scénario de l'essai — HTML déposé, ouvert par `?token=` — ne s'exécute plus ;
  (2) un SVG reste affichable par `<img src="…?token=">` ; (3) un glTF d'atelier-3d et une tuile de
  craft-lab se chargent toujours ; (4) la facture PDF de conciergerie s'ouvre toujours dans le
  navigateur (c'est pourquoi `sandbox` n'est **pas** posé sur tous les types : il bloquerait le
  lecteur PDF intégré).
- **Risque pour les apps** : faible, à vérifier — seule une app ouvrant un HTML ou un SVG par
  navigation directe serait gênée.

### Lot 1 — Sélection, clavier, menu contextuel — ~3 j — frontend seul

- **Objectif** : agir sur plusieurs éléments à la fois, à la souris, au clavier et au doigt.
- **Ce qui change** :
  - Découpage de `BrowserComponent` selon 4.3 (`browser.store.ts`, `entries.ts`, `selection.ts`,
    `actions.ts`, composants `file-list`, `toolbar`, `breadcrumb`, `space-tree`, `share-panel`).
    Déplacement de code, pas réécriture : même comportement à l'arrivée.
  - Ajout de `@angular/cdk@21.2.14` et `@viselect/vanilla`.
  - Sélection : clic, Ctrl, Maj, rectangle, Ctrl+A, Échap, cases à cocher ; `user-select: none`
    sur la liste.
  - Barre d'actions sur la sélection : télécharger (un par un, en file), supprimer en lot.
  - Suppression sans `confirm()` : l'élément disparaît, un bandeau « 3 éléments supprimés —
    Annuler » reste 6 s, l'appel `DELETE` ne part qu'ensuite. Onglet fermé avant : rien n'est
    supprimé.
  - Suppression d'un dossier = suppression de ses fichiers (liste déjà en mémoire), avec le compte
    annoncé dans le bandeau.
  - Menu contextuel (`cdk/menu`) au clic droit et à l'appui long (500 ms).
  - Clavier : flèches, Début / Fin, Entrée, Suppr, Retour arrière, `/`.
  - Tri par colonne (nom, taille, date), mémorisé ; champ de filtre par nom sur l'espace chargé ;
    taille et date des dossiers calculées côté client.
  - Corrections : `canWrite` lu dans `tree` ; erreurs en bandeau, la liste reste visible ; plus de
    rechargement de l'espace à chaque changement de dossier ; liens et lignes atteignables au
    clavier (`<button>` / `routerLink`, `role="grid"`, `aria-selected`, zone `aria-live`) ; cibles
    de 44 px ; rupture à 900 px ; liste mobile sans débordement.
  - Mise en place des tests unitaires (cible `test` avec `vitest`, absente aujourd'hui).
- **API** : aucune route nouvelle, aucun changement.
- **Tests avant clôture** :
  - unitaires : `selection.ts` (clic, Ctrl, Maj dans les deux sens, plage après tri, tout,
    rectangle) ; `entries.ts` (dossiers déduits, tri, tailles de dossier) ; `actions.ts`
    (visibilité selon sélection et droit d'écriture) ;
  - navigateur réel (`lab-runner`, compte `e2edev`, fichiers `zz-`) : Ctrl+A puis Suppr supprime
    tout, « Annuler » restaure ; Maj+clic ne surligne plus de texte ; rectangle sur 3 lignes →
    3 `aria-selected` ; clic droit ouvre le menu de l'app ; Tab puis flèches puis Entrée ouvre un
    dossier sans souris ; à 390 px, `scrollWidth == innerWidth` et toute cible ≥ 44 px ; thème
    sombre sans couleur en dur (`grep` hexadécimal = 0) ;
  - `cloisonnement.spec.ts` toujours vert.
- **Risque pour les apps** : nul.

### Lot 2 — Glisser-déposer et téléversement — ~3 j — frontend seul

- **Objectif** : déposer n'importe quoi n'importe où, et savoir où en est l'envoi.
- **Ce qui change** :
  - La zone de dépôt devient toute la liste (voile « Déposer dans *photos* ») ; déposer sur une
    ligne dossier ou sur un cran du fil d'Ariane cible ce dossier ; le bandeau pointillé disparaît
    au profit d'un bouton « Téléverser » (fichiers) et « Téléverser un dossier »
    (`webkitdirectory`).
  - Dépôt de dossiers entiers : parcours `webkitGetAsEntry`, chemins relatifs conservés.
  - `upload-queue.service.ts` : 2 envois en parallèle, progression par fichier et globale,
    annulation, relance d'un fichier échoué, un échec n'arrête plus la file ; refus immédiat et
    expliqué au-delà de 200 Mo (limite à exposer dans `env.js`).
  - Conflit de nom détecté **avant** l'envoi (la liste est connue) : « Remplacer / Garder les deux
    (`nom (2).ext`) / Ignorer », avec « appliquer à tous ».
  - « Nouveau dossier » : ouvre le dossier (l'adresse `/storage/<espace>/<chemin>` fonctionne déjà
    pour un chemin vide [D]) ; il existe réellement au premier fichier déposé. Limite assumée
    jusqu'au lot 3, dite dans l'interface (« le dossier sera conservé dès qu'il contiendra un
    fichier »).
  - Coller une image ou un fichier depuis le presse-papiers (Ctrl+V) = téléversement.
- **API** : inchangée (`POST /api/files/<espace>/` tel quel).
- **Tests avant clôture** :
  - unitaires : nom libre en cas de conflit (`a.txt` → `a (2).txt` → `a (3).txt`, extensions
    doubles, sans extension) ; file d'envoi (ordre, parallélisme 2, annulation, relance, échec
    isolé) avec une API simulée ;
  - navigateur réel : dépôt de 3 fichiers sur le tableau → 3 lignes ; dépôt sur une ligne dossier →
    fichiers dans ce dossier ; ré-envoi d'un nom existant → dialogue, et « Garder les deux » laisse
    l'original intact (taille inchangée) ; un envoi forcé en échec (`page.route`) n'empêche pas les
    suivants et propose « Relancer » ; dossier à deux niveaux → arborescence reproduite ;
  - non-régression du lot 1.
- **Risque pour les apps** : nul.

### Lot 3 — Déplacer, renommer, copier, corbeille — ~5 j — backend additif + frontend

- **Préalable** : trancher Q1 (corbeille) et Q2 (partages gérés par une app). Ce lot modifie
  `storage` et ajoute des routes : au sens de `CLAUDE.md` il relève du régime « chantier » ; le
  tableau 3.1 de ce document est le brouillon du contrat à figer.
- **Objectif** : réorganiser ses fichiers sans les télécharger.
- **Backend** :
  - d'abord, **tests de contrat** sur l'existant (3.1) : codes, formes, remplacement au `POST`,
    auto-création par préfixe, comptes de service, rôles lecture / écriture, repli `?token=` ;
  - `POST /api/files/<espace>/ops/` (`move`, `copy`, `delete`, `trash`) avec `on_conflict`,
    transactionnel, résultat par élément ; refus de déplacer un dossier dans lui-même ;
  - `Folder` + `/api/folders/<espace>/` (dossiers vides) ;
  - `TrashedFile` + `/api/trash/<espace>/` (lister, restaurer, purger) + commande de purge à
    30 jours ;
  - refus de ces nouvelles opérations dans un partage géré par une app (3.3).
- **Frontend** : glisser une sélection vers un dossier / le fil d'Ariane / l'arbre (`cdk/drag-drop`) ;
  Ctrl+C / X / V ; F2 et renommage en place ; « Déplacer vers… » (sélecteur de dossier, seul moyen
  au tactile) ; entrée « Corbeille » dans le volet ; « Nouveau dossier » réel ; partages gérés par
  une app en lecture seule avec leur étiquette.
- **Tests avant clôture** :
  - backend : contrat existant vert **avant et après** ; `move` d'un dossier de 200 fichiers = une
    transaction, aucun blob touché (mêmes `content.name`) ; conflits `fail` / `rename` / `replace` ;
    membre en lecture refusé ; compte de service inchangé ; mise à la corbeille puis restauration au
    même chemin, et restauration avec chemin réoccupé ; purge efface le blob ; opération refusée
    dans un partage d'app ;
  - navigateur réel : glisser 2 fichiers sur un dossier ; couper-coller entre deux dossiers ; F2,
    Entrée ; Suppr puis restauration depuis la corbeille ;
  - **apps consommatrices** : un envoi et une lecture réels depuis `carto-lab` (jeton utilisateur
    transmis), `restauration` (compte de service), `conciergerie` (préfixe) et `atelier-3d`
    (`LabStorage`, `listing`).
- **Risque pour les apps** : faible si le contrat est testé — routes et tables nouvelles, rien de
  retiré. Le risque réel est fonctionnel (3.3), d'où le refus côté serveur.

### Lot 4 — Télécharger une sélection, propriétés, espace occupé — ~2 j — frontend seul

- **Objectif** : sortir plusieurs fichiers d'un coup, savoir ce qu'on regarde.
- **Ce qui change** : archive d'une sélection ou d'un dossier fabriquée dans le navigateur
  (`client-zip`), avec progression et plafond annoncé (proposé : 2 Go) ; téléchargement d'un fichier
  avec progression ; panneau « Informations » (chemin, type, taille, créé, modifié, déposé par,
  « Copier le lien » vers l'adresse interne) ; espace occupé par espace et par dossier.
- **API** : inchangée.
- **Tests** : unitaires sur la construction des chemins dans l'archive (noms en double, accents) ;
  navigateur réel : archive de 3 fichiers et d'un sous-dossier, rouverte et comparée octet par
  octet ; le lien copié rouvre le bon dossier.
- **Risque pour les apps** : nul.

### Lot 5 — Aperçu, vignettes, vue grille — ~4 j — backend additif + frontend

- **Objectif** : voir sans télécharger.
- **Backend** : `Range` sur la route de contenu ; `GET …/thumb/<chemin>?s=` (Pillow, cache sur le
  volume, images matricielles seulement) ; passage de `runserver` à `gunicorn` — à faire ici au plus
  tard, à isoler dans son propre déploiement.
- **Frontend** : aperçu en superposition — image, PDF (`<iframe>` sur un `Blob`), texte et Markdown
  affichés **comme texte**, audio, vidéo ; **jamais** de rendu HTML ni de SVG en ligne ; navigation
  ← → ; vue grille avec vignettes ; chargement des images par `fetch` + en-tête d'autorisation, pas
  de jeton dans les adresses.
- **Tests** : backend — `Range` (206, bornes, hors limites 416), requête sans `Range` identique à
  aujourd'hui ; vignette d'un JPEG, refus propre d'un fichier non image ; navigateur réel — aperçu
  d'une image, d'un PDF, d'un texte ; un `.html` ouvert en aperçu s'affiche en source ; lecture
  vidéo avec déplacement dans la piste.
- **Risque pour les apps** : faible ; le changement de serveur est le point à surveiller (toutes les
  apps passent par lui) — un envoi et une lecture réels par app après déploiement.

### Lot 6 — Partage plus direct — ~3 j — frontend, backend additif léger

- **Objectif** : partager un dossier en un geste.
- **Ce qui change** : « Partager ce dossier… » depuis l'espace personnel = créer un partage et y
  **déplacer** le dossier (possible grâce au lot 3, Q3) ; dialogue unique : nom, membres, droits ;
  liste des membres visible par les membres ; propositions de courriels à partir des comptes
  connus ; le formulaire de hiérarchie reste, replié.
- **Tests** : backend — un membre lit la liste des membres, ne la modifie pas ; navigateur réel —
  partage d'un dossier de 3 fichiers, les fichiers ont quitté l'espace personnel et sont lisibles
  par un second compte.
- **Risque pour les apps** : nul si la lecture des membres par un membre est une route nouvelle.

### Lot 7 — Selon besoin

Recherche tous espaces (`GET /api/search/`), quotas, archive côté serveur pour les gros dossiers,
défilement virtuel et liste paginée par dossier au-delà de quelques milliers de fichiers par espace.
À ne lancer que sur un besoin constaté : aucun n'existe aujourd'hui (116 fichiers dans le plus gros
espace, 356 Go libres).

---

## Décisions du propriétaire (2026-10-11) — font foi sur les recommandations ci-dessous

- **Q1 Suppression** : **définitive, avec annulation** (bandeau « Annuler » quelques secondes). Pas
  de corbeille.
- **Q2 Partages gérés par une app** : **tout y est permis, comme ailleurs** (il assume le risque
  qu'une app perde une référence). L'interface signale simplement qu'un partage est géré par une
  app ; elle n'interdit rien.
- **Q3 Changement d'espace** : oui, entre espaces humains où l'on peut écrire.
- **Q4 Liens publics** : non. « Copier le lien » exige une connexion et un droit.
- **Q5 Quotas** : non pour l'instant ; afficher l'espace occupé.
- **Q6 Tests de gestes** : un second fichier E2E propre à `storage`, lancé à la main, hors catalogue.
- **Q8** : passer à `gunicorn`.
- **Lots lancés** : 1 et 2 (frontend seul). Le lot 3 n'est pas lancé.

## 6. Questions à trancher

**Q1 — Corbeille ou suppression définitive ?**
Recommandation : corbeille, 30 jours, **pour les actions faites dans l'interface seulement**, dans
les espaces personnels et les partages humains. La route `DELETE` que les apps appellent reste
définitive : elles gèrent leur propre cycle de vie, et une corbeille remplie par leurs purges
garderait indéfiniment ce qu'elles croient effacé. Dès le lot 1, l'annulation pendant 6 s couvre
l'erreur de manipulation sans rien changer au serveur.

**Q2 — Que peut faire un humain dans un partage géré par une app ?**
Recommandation : lecture, aperçu, téléchargement — rien d'autre depuis l'interface de `storage`,
et le serveur refuse les nouvelles opérations sur ces partages. Faut-il aussi retirer le bouton
« Supprimer » qui existe aujourd'hui sur ces fichiers ? Je le recommande (lot 1, côté interface) :
supprimer un raster de `carto-lab` ici laisse l'app avec une couche cassée.

**Q3 — Un fichier peut-il changer d'espace ?**
Le modèle dit aujourd'hui que non. Recommandation : oui, entre espace personnel et partages
**humains** où l'on a le droit d'écriture, jamais vers ou depuis un partage d'app. Sans cela, on ne
peut pas partager un dossier existant (lot 6).

**Q4 — Liens publics (lecture sans compte) ?**
Recommandation : non. `CLAUDE.md` pose que `storage` n'a et ne doit avoir aucun chemin de lecture
anonyme, la republication étant décidée par l'app qui porte la règle métier (cas `restauration`).
À la place : « Copier le lien », qui exige une connexion et un droit sur l'espace.

**Q5 — Quotas ?**
Recommandation : pas de quota pour l'instant — 2 Go utilisés, 356 Go libres, quatre comptes
connus. Afficher l'espace occupé (lot 4) suffit. Si un quota vient un jour, il ne doit s'appliquer
qu'aux espaces personnels, jamais aux partages d'app.

**Q6 — Où vivent les tests de gestes en navigateur ?**
`CLAUDE.md` impose un seul fichier E2E par app, copiable tel quel. Recommandation : autoriser un
second fichier `frontend/e2e/gestes.spec.ts` propre à `storage`, lancé à la main par `lab-runner`,
hors catalogue — ce qui demande de mettre à jour la section « Tests end-to-end » de `CLAUDE.md` et
de vérifier que le runner ne ramasse pas ce fichier dans le catalogue de cloisonnement. Avec quel
compte ? `e2edev` a servi ici ; `e2e_member` conviendrait aussi.

**Q7 — Lot 0 tout de suite ?**
Recommandation : oui, avant tout le reste et indépendamment de ce plan.

**Q8 — `runserver` en production.**
Recommandation : passer à `gunicorn` au lot 5 au plus tard. Cela concerne-t-il aussi le gabarit
`_templates/` et les autres apps ? Non vérifié ici.

**Q9 — `CLAUDE.md` cite six apps consommatrices de `storage` ; il y en a neuf** (`code-route` et `craft-lab` en plus, `traitement-de-fichiers-compils` utilise aussi un
préfixe). À corriger dans `CLAUDE.md` par qui en a la charge.

---

## Ce qui n'a pas été vérifié

- Le comportement de l'interface **dans un partage** (membre en lecture, en écriture, par groupe) :
  lu dans le code seulement, pour ne toucher à aucun partage. Le défaut `canWrite` (1.4) est donc
  une déduction.
- Le dépôt réel d'un **dossier** et d'un fichier **lâché hors du bandeau** : non simulables
  fidèlement avec un événement synthétique ; déduits du code.
- L'**exploitation complète** de la faille 2.3 (vol de jeton d'une autre app) : seule l'exécution du
  script sur l'origine du lab a été constatée. La durée de vie des jetons n'a pas été mesurée.
- Qu'aucune app n'ouvre un HTML ou un SVG de `storage` par navigation directe : recherché dans les
  `storage_client.py` et les sérialiseurs, pas dans tous les frontends.
- Le comportement avec de **gros fichiers** (progression, mémoire au téléchargement, délais) et le
  seuil exact du budget de style.
- Lecteur d'écran réel, navigateurs autres que Chromium, appareil tactile réel (mesures prises en
  émulation 390 × 844).
- Les efforts annoncés sont des ordres de grandeur.

Nettoyage : tous les fichiers `zz-analyse-*` créés dans l'espace de `e2edev` ont été supprimés ;
l'espace est vide, comme avant (vérifié par l'API en fin de chaque passe).
