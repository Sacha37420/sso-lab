# MISSION — Refonte UI « Foyer » : identité visuelle unifiée + navigation responsive

Refonte **purement UI** de toutes les applications du lab et de leurs templates de
scaffold, pour :
1. les rendre pleinement exploitables au doigt sur téléphone, pas seulement au clic sur PC ;
2. remplacer toute navigation en en-tête horizontal par un principe **unique et
   toujours vertical** — bandeau latéral rétractable sur PC, recouvrement plein écran
   sur mobile ;
3. leur donner une identité graphique commune et cohérente : **Foyer**.

Ce document est le cahier des charges complet — noms, valeurs de couleurs, tailles,
comportements — pour qu'il soit exécutable sans dépendre d'un autre document ou d'un
aperçu externe.

---

## Ce qui est HORS PÉRIMÈTRE (à ne jamais toucher)

- Routes, URLs, logique métier, appels API, code backend, config Docker/déploiement.
- Le comportement fonctionnel de chaque page (ce qu'elle fait) ne change pas — seule
  son enveloppe visuelle et sa structure de navigation changent.
- Les noms de composants TypeScript existants peuvent rester tels quels ; ne pas
  renommer/déplacer de fichiers au-delà de ce qui est nécessaire pour la nav.

Si une tâche ci-dessous semble impliquer un changement fonctionnel, c'est un signal
pour s'arrêter et clarifier plutôt que d'improviser.

---

## Identité — Foyer

### Nom et logo

- Nom : **Foyer**.
- Logo : monogramme « F » sur badge dégradé (accent → accent foncé), coins mi-arrondis
  (`--radius-sm`), + mot-symbole « Foyer » en Inter 800. Le badge seul sert de favicon
  à chaque app (32×32 et 16×16, fond plein, pas de transparence).

### Polices (à self-hoster, jamais de CDN Google Fonts)

Deux rôles, pas plus : **Inter** pour toute l'UI (y compris les titres, via la
graisse, pas une police séparée), **JetBrains Mono** pour le code/données tabulaires
(SQL, JSON, coordonnées).

Récupérer ces 5 fichiers WOFF2 statiques (déjà validés, ~115 Ko au total) et les
placer dans `src/assets/fonts/` de **chaque** app :

```
https://raw.githubusercontent.com/fontsource/font-files/main/fonts/google/inter/files/inter-latin-400-normal.woff2
https://raw.githubusercontent.com/fontsource/font-files/main/fonts/google/inter/files/inter-latin-600-normal.woff2
https://raw.githubusercontent.com/fontsource/font-files/main/fonts/google/inter/files/inter-latin-800-normal.woff2
https://raw.githubusercontent.com/fontsource/font-files/main/fonts/google/jetbrains-mono/files/jetbrains-mono-latin-400-normal.woff2
https://raw.githubusercontent.com/fontsource/font-files/main/fonts/google/jetbrains-mono/files/jetbrains-mono-latin-600-normal.woff2
```

```scss
@font-face { font-family: "Foyer UI"; font-weight: 400; font-style: normal; font-display: swap;
  src: url("/assets/fonts/inter-latin-400-normal.woff2") format("woff2"); }
@font-face { font-family: "Foyer UI"; font-weight: 600; font-style: normal; font-display: swap;
  src: url("/assets/fonts/inter-latin-600-normal.woff2") format("woff2"); }
@font-face { font-family: "Foyer UI"; font-weight: 800; font-style: normal; font-display: swap;
  src: url("/assets/fonts/inter-latin-800-normal.woff2") format("woff2"); }
@font-face { font-family: "Foyer Mono"; font-weight: 400; font-style: normal; font-display: swap;
  src: url("/assets/fonts/jetbrains-mono-latin-400-normal.woff2") format("woff2"); }
@font-face { font-family: "Foyer Mono"; font-weight: 600; font-style: normal; font-display: swap;
  src: url("/assets/fonts/jetbrains-mono-latin-600-normal.woff2") format("woff2"); }
```

### Tokens de couleur (clair + sombre, bascule automatique + manuelle)

À placer dans `src/styles.scss` de chaque app, en tête de fichier. Neutres
volontairement teintés bleu (jamais de gris pur). L'accent est un bleu franc,
distinct du violet/indigo. Les couleurs sémantiques (succès/attention/erreur) sont
indépendantes de l'accent — elles reprennent la sémantique déjà en place dans
carto-lab pour les statuts de job (PENDING/RUNNING/DONE/ERROR).

```css
:root {
  --accent: #2a6df4; --accent-deep: #1b4fc4; --accent-tint: #e8effe;
  --success: #1fa463; --success-tint: #e4f6ec;
  --warning: #d98e1e; --warning-tint: #fbf0dc;
  --danger:  #e14b4b; --danger-tint:  #fbe6e6;

  --bg: #f6f7fb; --card: #ffffff; --border: #e2e5ee;
  --text: #12141c; --text-mute: #5b6172;
  --accent-on: #ffffff;

  --font-ui: "Foyer UI", -apple-system, "Segoe UI", sans-serif;
  --font-mono: "Foyer Mono", ui-monospace, "SF Mono", monospace;

  --space-1: 4px;  --space-2: 8px;  --space-3: 12px; --space-4: 16px;
  --space-5: 24px; --space-6: 32px; --space-7: 48px; --space-8: 64px;

  --radius-sm: 8px; --radius-md: 12px; --radius-lg: 18px; --radius-full: 999px;

  --text-xs: 12px; --text-sm: 14px; --text-base: 16px;
  --text-lg: 20px; --text-xl: 24px; --text-2xl: 32px; --text-3xl: 40px;

  --nav-h: 64px;          /* hauteur du bandeau mobile compact */
  --sidebar-w: 240px;     /* largeur du bandeau latéral déployé */
  --sidebar-w-collapsed: 76px; /* largeur du bandeau latéral réduit */
  color-scheme: light;
}

@media (prefers-color-scheme: dark) {
  :root {
    --accent: #5b8dff; --accent-deep: #7fa4ff; --accent-tint: #182749;
    --success: #34c07f; --success-tint: #123625;
    --warning: #eba53a; --warning-tint: #3a2c10;
    --danger:  #ef6a6a; --danger-tint:  #3a1717;
    --bg: #0c0e14; --card: #14171f; --border: #262b38;
    --text: #eef0f5; --text-mute: #98a0b3; --accent-on: #0c0e14;
    color-scheme: dark;
  }
}
/* Un interrupteur manuel doit pouvoir forcer un thème quel que soit prefers-color-scheme,
   dans les deux sens — via [data-theme="dark"] / [data-theme="light"] sur <html>,
   en redéfinissant exactement les mêmes tokens que ci-dessus. Le choix se persiste
   en localStorage et se relit avant le premier rendu pour éviter un flash. */
```

Styler tous les composants **via ces tokens**, jamais de couleur en dur — c'est ce qui
permet au thème sombre de fonctionner partout sans reprise manuelle page par page.

### Échelle typographique

Un titre est un corps de texte en graisse 800, pas une police différente.

| Rôle | Taille | Graisse |
|---|---|---|
| Titre de page (h1) | `--text-3xl` (40px) | 800 |
| Titre de section (h2) | `--text-2xl` (32px) | 800 |
| Titre de carte (h3) | `--text-lg` (20px) | 600 |
| Corps | `--text-base` (16px) | 400 |
| Légende / méta | `--text-sm` (14px) | 600, `--text-mute` |
| Eyebrow (surtitre) | `--text-xs` (12px) | 700, majuscules, `letter-spacing: .08em`, couleur accent |

### Composants de base

- **Boutons** : hauteur 44px (cible tactile), `--radius-sm`, variantes primaire
  (fond `--accent`), secondaire (bordure `--border`), fantôme (texte seul).
- **Champs** : hauteur 44px, `--radius-sm`, focus = bordure `--accent` + anneau
  `--accent-tint`.
- **Cartes** : fond `--card`, bordure `--border`, `--radius-md`, padding `--space-5`.
- **Pastilles de statut** : `--radius-full`, teinte + fond `-tint` correspondants
  (pending → warning, running → accent, done → success, error → danger).
- **Cible tactile minimale : 44×44px partout**, sans exception, sur tout élément
  interactif (bouton, lien de nav, case à cocher).

---

## Navigation — un seul principe, toujours vertical

**Jamais** de bascule horizontal (PC) → menu burger déroulant (mobile) : c'est
précisément le pattern à ne PAS reproduire. Dans les deux cas, la navigation est une
**liste verticale**.

### Desktop (≥ 900px) — bandeau latéral rétractable

- `<aside class="sidebar">` collé à gauche, `position: sticky; top:0; height:100vh`,
  largeur `--sidebar-w` (240px).
- Contenu, du haut vers le bas : logo (badge + mot-symbole) → liste verticale des
  liens de nav (icône + libellé) → pied de bandeau (interrupteur thème, bouton
  Réduire).
- **Rétractable** : un bouton « Réduire » bascule une classe `.collapsed` qui ramène
  la largeur à `--sidebar-w-collapsed` (76px) ; les libellés disparaissent, seules
  les icônes restent (chaque lien garde un attribut `title` pour l'infobulle
  native). Le contenu principal (`.main { flex: 1 }`) occupe l'espace libéré
  automatiquement — pas de marge calculée en JS.
- Chaque lien de nav a une icône : un carré `--radius-sm` de 30px avec une
  abréviation de 2 lettres en `--font-mono` (ex. « Db » pour Dashboard) — c'est le
  système déjà utilisé dans la maquette Foyer, pas la peine d'en inventer un autre.

### Mobile (< 900px) — recouvrement plein écran

- Le bandeau latéral disparaît (`display:none`). À la place : un bandeau compact
  (`--nav-h`, 64px) avec logo à gauche, bouton menu (3 barres) et interrupteur thème
  à droite.
- Au clic sur le bouton menu, un panneau **`position: fixed; inset: 0`** recouvre la
  quasi-totalité de l'écran (padding `--space-5`), liste verticale des liens en
  grands boutons tactiles (padding `--space-4`, `--text-lg`), bouton de fermeture
  (✕) en haut à droite. Transition douce (translateY + opacity, ~250ms), jamais de
  saut brutal.
- Ce n'est **pas** un petit panneau déroulant sous le bandeau : il doit occuper
  l'écran, avec une vraie respiration.

### Rupture

**900px**, fixe et identique pour toutes les apps — ne pas la faire varier d'une app
à l'autre, c'est ce qui garantit un comportement prévisible partout dans le lab.

### Ce que chaque app doit reconstruire elle-même

La structure (sidebar + recouvrement) est identique partout, mais **les liens de
navigation sont propres à chaque app** — ne pas copier ceux d'une autre. Avant de
toucher une app, lire son composant de nav actuel (`shared/navbar/` ou équivalent)
et son `app.routes.ts` pour en extraire la liste réelle des pages, puis les
reconstruire dans la nouvelle structure sans en changer les libellés ni les cibles.

---

## Périmètre — 8 apps + 2 templates

| Dossier | Nav actuelle à remplacer |
|---|---|
| `front-cadriciel` | Dashboard, Apps, Code, Déploiements (voir `app.routes.ts`) — **app pilote, à faire en premier** |
| `carto-lab/frontend` | `shared/navbar/navbar.component` (Accueil, Carte, Traitements, Météo, Profil) |
| `app-builder/frontend` | à identifier dans le code existant |
| `analyse-lora/frontend` | à identifier |
| `restauration/frontend` | à identifier |
| `traitement-de-fichiers-compils/frontend` | à identifier |
| `arbre-genealogique/frontend` | à identifier |
| `google-agenda/frontend` | à identifier |
| `_templates/angular-only` | template de scaffold — futures apps Angular seul |
| `_templates/django-angular/frontend` | template de scaffold — futures apps Django+Angular |

---

## Déroulé en lots

### Lot 0 — Assets partagés
Télécharger les 5 polices WOFF2, vérifier leur poids total (doit rester sous ~150 Ko),
préparer le bloc de tokens CSS ci-dessus comme référence unique à dupliquer ensuite
(pas de package npm partagé à créer — chaque app reste un dépôt git indépendant,
c'est la convention existante du lab).

### Lot 1 — Pilote : `front-cadriciel`
Appliquer l'intégralité de la charte (tokens, polices, sidebar rétractable,
recouvrement mobile) sur le portail du lab. C'est l'app la plus visible et la plus
simple structurellement (4 routes) — elle sert à valider le pattern avant de le
répéter 9 fois. Tester réellement au clavier, à la souris (redimensionnement sous
900px) et si possible sur un vrai téléphone avant de continuer.

### Lot 2 — Templates
Une fois le Lot 1 validé, porter exactement le même pattern dans
`_templates/angular-only` et `_templates/django-angular/frontend`, avec les
placeholders `__APP_NAME__`/`__APP_TITLE__` existants pour le mot-symbole. Toute
nouvelle app créée via `new-app.sh` doit hériter de Foyer sans travail
supplémentaire.

### Lot 3 — Reste des apps
Une app à la fois : `carto-lab`, `app-builder`, `analyse-lora`, `restauration`,
`traitement-de-fichiers-compils`, `arbre-genealogique`, `google-agenda`. Pour
chacune : lire sa nav actuelle → construire la nouvelle structure avec ses vrais
liens → appliquer les tokens → vérifier qu'aucune route/fonctionnalité n'a bougé →
tester clair/sombre + le comportement responsive avant de passer à la suivante.

---

## Checklist de vérification (à répéter pour chaque app)

- [ ] `src/assets/fonts/` contient les 5 WOFF2, chargés via `@font-face` (pas de CDN).
- [ ] Tokens de couleur en tête de `styles.scss`, aucune couleur en dur ailleurs
      dans l'app (grep rapide sur des valeurs hex pour confirmer).
- [ ] Bandeau latéral fonctionnel ≥ 900px, rétractable, contenu qui se redimensionne
      sans JS de calcul de marge.
- [ ] Recouvrement plein écran fonctionnel < 900px, liste verticale, fermeture au
      clic sur un lien et sur le bouton ✕.
- [ ] Interrupteur clair/sombre présent (bandeau latéral en desktop, bandeau compact
      en mobile), persiste le choix, respecte `prefers-color-scheme` par défaut.
- [ ] Toute cible interactive mesure au moins 44×44px.
- [ ] `prefers-reduced-motion` respecté sur les transitions (sidebar, recouvrement).
- [ ] États de focus visibles au clavier (`:focus-visible`).
- [ ] Aucune route, aucun appel API, aucune logique métier modifiés — seul le rendu
      a changé.
- [ ] Testé dans les deux thèmes, à la largeur desktop et sous 900px.
