# Phase « reprise » — ta session précédente a été interrompue

Ta session de cette nuit a été arrêtée avant la fin (limite d'utilisation, ou arrêt de l'hôte à
5 h 00). Elle est reprise ici, avec son historique. **Ne recommence pas : termine.** Le temps est
court (vise 45 minutes) ; la priorité est d'avoir des sorties complètes et justes, pas d'élargir la
relecture.

## Ordre de travail
1. Relis `/entree/mission.md` (tâche, phase, cibles ; la phase interrompue — principale, suite ou
   correction — s'y lit ou se déduit de ton historique et des sections finales du rapport), puis `/sortie/rapport.md` et
   `/sortie/resume.json` tels qu'ils sont sur le disque. Si l'un manque ou n'est pas du JSON valide
   (`jq . /sortie/resume.json`), réécris-le d'abord, avec `"statut": "partiel"`.
2. Pour chaque cible : `git -C /work/<cible> --no-optional-locks status --porcelain` et
   `git -C /work/<cible> diff`. C'est l'état réel des modifications : il peut différer de ce que ton
   historique ou le rapport annonce (session coupée au milieu d'une écriture). Une modification à
   moitié faite (fichier tronqué, test sans la correction ou l'inverse, syntaxe cassée —
   `PYTHONPYCACHEPREFIX=/tmp/pycache python3 -m py_compile`) se **termine** si c'est court, sinon se
   **retire** (`git -C /work/<cible> show HEAD:<chemin> > /work/<cible>/<chemin>`, ou suppression
   d'un fichier créé).
3. Fais concorder rapport, résumé et modifications réelles : chaque fichier modifié décrit dans le
   rapport, chaque correction annoncée présente sur le disque.
4. S'il reste du temps, termine la relecture **là où elle s'était arrêtée** (cible ou point non
   encore relu, tel que le dit ton historique ou le rapport) ; n'ouvre pas de nouveau sujet.
5. Note dans « Limites de cette relecture » que la session a été interrompue puis reprise, et ce qui
   n'a pas pu être relu.
6. Vérification finale (préambule § 8), puis `"statut": "fini"`. Si la phase interrompue était une
   phase suite ou correction, respecte aussi sa consigne : section `## Pour aller plus loin` ou
   `## Correction après tests` à la fin du rapport, contenu des phases précédentes conservé.

Toutes les règles du préambule s'appliquent, y compris : ne pas commiter, ne pas pousser, chemins
refusés, rien de sensible dans le rapport.
