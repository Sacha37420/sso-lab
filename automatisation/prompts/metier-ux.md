# Tâche « metier-ux » — validité métier et simplicité de l'interface de deux apps

Cibles : les apps nommées dans `/entree/mission.md` (en général deux), chacune dans `/work/<app>`.
But : vérifier que l'app fait **ce que sa feuille de route dit qu'elle fait**, sans erreur métier,
et que son interface est **simple à utiliser** ; corriger ce qui est petit et sûr, ajouter les tests
métier manquants, proposer le reste. Partage ton temps à parts égales ; finis entièrement la
première cible avant d'ouvrir la seconde.

**Pas de changement fonctionnel non demandé par la feuille de route** : une fonctionnalité, une
page, un champ ou une règle nouvelle se propose dans le rapport, elle ne se code pas. Sont permis :
corriger un comportement qui contredit la feuille de route, le cahier des charges ou un invariant
évident ; un libellé, un message, un état vide, un état de chargement, l'accessibilité ; la
conformité à Foyer.

## Partie A — validité métier

### 1. Établir la règle (20 minutes au plus)
- `FEUILLE_DE_ROUTE.md` : pour chaque lot **livré**, la liste de ce qu'il promet ; pour les lots « à
  faire », les constats déjà connus (ne les recompte pas comme nouveaux).
- `CAHIER_DES_CHARGES.md` s'il existe : modèles, règles métier, rôles, pages. Une contradiction
  avec une règle du lab : c'est la règle du lab qui gagne, note l'écart.
- Écris dans `/tmp` la liste des **invariants** de l'app (ex. « un solde est la somme des
  mouvements », « une réservation ne chevauche pas une autre sur le même bien », « un montant n'est
  jamais négatif », « un élève ne voit pas la correction avant la fin du quiz »).

### 2. Confronter le code à la règle
Pour chaque promesse et chaque invariant : trouve le code qui le tient (modèle, sérialiseur, vue,
tâche) et le test qui le prouve. Cherche en particulier :
- **calculs** : flottants pour de l'argent (`Decimal` attendu), arrondis, division par zéro, unités,
  sommes qui oublient une catégorie, formule appliquée dans un sens et testée dans l'autre ;
- **dates et heures** : fuseaux (`USE_TZ`, `timezone.now()` contre `datetime.now()`), bornes
  incluses/exclues, fin de mois, changement d'heure, dates passées ou futures acceptées à tort ;
- **cas limites** : liste vide, une seule entrée, doublon, valeur nulle, chaîne vide, très grande
  valeur, objet supprimé entre-temps, suppression en cascade qui emporte trop ou pas assez ;
- **validation** : règles vérifiées seulement dans le frontend et pas dans l'API ; contraintes en
  base absentes (unicité, non-nul) quand le métier les exige ;
- **rôles** : chaque rôle de la feuille de route peut faire ce qu'il doit, et pas plus (un défaut
  d'accès est aussi un constat ici, gravité selon le préambule) ;
- **concurrence** : deux requêtes simultanées qui cassent un invariant (compteur, réservation,
  stock) — à proposer, rarement à corriger de nuit.

### 3. Tests métier manquants
Pour chaque invariant sans test : **ajoute un test backend** qui le prouve sur le comportement
actuel (s'il est juste). S'il est faux : corrige si c'est petit, avec le test ; sinon propose et, si
utile, ajoute le test sous `@unittest.expectedFailure` avec un commentaire qui renvoie au rapport.
Suis la disposition et les aides des tests existants (préambule § 4). Un test qui demande des
données : crée-les dans le test, jamais à partir de données réelles.

## Partie B — simplicité de l'interface

Tu n'as pas de navigateur : raisonne sur `frontend/src` (routes, composants, gabarits HTML, styles).

### 1. Parcours
Depuis `app.routes.ts` et la navigation : liste les parcours principaux qu'annonce la feuille de
route (ex. « créer un bien puis y rattacher un séjour »). Pour chacun : nombre d'écrans et de clics,
point où l'utilisateur ne sait pas quoi faire, action principale visible ou non, retour possible,
confirmation avant une action destructive, perte de saisie possible (navigation sans avertissement).

### 2. Textes et états
- Libellés : en français, cohérents d'un écran à l'autre (même mot pour la même chose), sans jargon
  technique (« 403 », « null », « payload », nom de champ d'API).
- **Messages d'erreur** : chaque appel HTTP a un traitement d'erreur ; le message dit ce qui s'est
  passé et quoi faire ; jamais le corps brut de la réponse ni une trace.
- **États vides** (« aucun bien — en ajouter un »), **chargement**, **succès** d'une action.
- Formulaires : champs obligatoires signalés, erreur affichée à côté du champ, types de champ
  adaptés (date, nombre, email), bouton désactivé pendant l'envoi (double soumission).

### 3. Foyer et accessibilité (règles exactes au § 5 du préambule)
- Couleurs en dur hors `src/styles.scss` :
  `grep -rnE "#[0-9a-fA-F]{3,8}\b|rgba?\(|hsla?\(" src/app --include=*.scss --include=*.css --include=*.html --include=*.ts`
  — chaque occurrence dans un composant se remplace par le token existant le plus proche (n'en crée
  un nouveau dans `styles.scss` que s'il manque, en thème clair **et** sombre).
- Cibles tactiles < 44 px (`height`, `min-height`, `padding` des boutons, icônes cliquables, liens
  de liste) ; rupture à **900 px** exactement dans chaque `@media` de mise en page ; navigation
  verticale ; polices sans CDN (`fonts.googleapis`).
- Accessibilité : `alt` des images, `aria-label` des boutons à icône seule, `label` lié à chaque
  champ, focus visible (pas de `outline: none` sans remplacement), ordre de tabulation, contraste
  garanti par les tokens.

## Section propre à la tâche dans le rapport

Après « Constats », ajoute `## Invariants et tests` (par cible : invariant · code qui le tient · test
existant ou ajouté · état) et `## Parcours` (par parcours : étapes, frictions relevées, corrections
faites ou proposées).

## Ce que tu ne fais pas
- Pas de refonte d'écran, pas de changement de navigation (liens, ordre, routes), pas de nouvelle
  bibliothèque.
- Pas de changement de la forme des réponses d'API pour arranger le frontend.
- Pas de modification de la logique métier « pour l'améliorer » quand elle est conforme à la
  feuille de route : une meilleure règle se propose (Ⓟ).
