# Tâche « interface », phase 2 — aller plus loin (la phase 1 a peu produit)

Tu es lancé parce que la phase principale de cette nuit a rendu `"charge": "faible"` : lab-admin et
le gabarit sont en bon état sur les points de base. **Lis d'abord `/sortie/rapport.md` et
`/sortie/resume.json`** : ne refais pas ce qui y est, ne recompte pas ses constats. Mêmes cibles et
mêmes contraintes que la phase 1 (lab-admin dans `/work/lab-admin`, `_templates/` seul dans
`/work/dev` ; ligne `## Lot 2 — ` et marqueurs `__…__` du gabarit intacts ; pas de nouvelle page,
pas de changement de navigation ni d'API). Les modifications de la phase 1 sont encore dans
`/work` : ne les défais pas.

## Ce que tu cherches maintenant (plus fin que la phase 1)
1. **Accessibilité réelle** : navigation au clavier de bout en bout (ordre, pièges de focus dans les
   dialogues — `confirm-dialog` rend-il le focus à l'élément d'origine ? `Échap` ferme-t-il ?),
   annonces aux lecteurs d'écran (`aria-live` sur les résultats de job, les erreurs), libellés des
   icônes, contraste des tokens dans les deux thèmes (calcule le rapport pour `--text`/`--bg`,
   `--accent` sur `--bg`, texte secondaire ; cible 4,5:1 pour le texte courant).
2. **Robustesse des écrans** : texte très long (nom de projet, message d'erreur du moteur) qui
   déborde ; liste de 50 projets ; écran étroit de 320 px ; recouvrement de navigation < 900 px qui
   bloque le défilement du fond ; état « hors ligne » ou moteur injoignable.
3. **Cohérence de la langue** : même verbe pour la même action dans tout lab-admin et le gabarit
   (« Déployer », « Supprimer », « Annuler ») ; ponctuation et majuscules ; dates au format
   français.
4. **Le gabarit comme point de départ** : une app qui vient de naître affiche-t-elle à son
   développeur ce qu'il doit faire ensuite (page `home`) ? Les `regles/` disent-elles clairement, en
   peu de mots, comment travailler lot par lot ?

## Ce que tu fais
- Au plus **trois** petites améliorations sûres (même définition qu'en phase 1), chacune décrite.
- Pour le reste, un **plan** : `## Pour aller plus loin`, ajoutée à la fin de `rapport.md` (garde
  tout le reste tel quel). Pour chaque proposition : constat [C]/[D], gain pour l'utilisateur,
  fichiers concernés, coût S/M/L, Ⓟ si c'est un choix du propriétaire. Classe par gain décroissant ;
  dix propositions au plus.
- Mets à jour `resume.json` : ajoute tes constats à ceux de la phase 1, cumule `tests_ajoutes`,
  recalcule `statut` et `charge` sur l'ensemble de la nuit, ajuste `titre_pr` s'il ne décrit plus le
  contenu.
