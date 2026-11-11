# Tâche « services », phase 2 — de nouveaux services mutualisés seraient-ils utiles ?

Tu es lancé parce que la phase principale de cette nuit a rendu `"charge": "faible"` : les services
du cadriciel sont en bon état. **Lis d'abord `/sortie/rapport.md` et `/sortie/resume.json`** : ne
refais pas ce qui y est. Mêmes cibles et mêmes règles qu'en phase 1 ; les modifications de la phase
1 sont encore dans `/work` : ne les défais pas.

Question : **y a-t-il du code ou un besoin répété dans plusieurs apps du lab qui gagnerait à devenir
un service du cadriciel** (comme `storage` pour les fichiers, `oauth-hub` pour les jetons externes,
`lab-media` pour les flux), ou une bibliothèque commune du gabarit ? **Cette phase ne code rien** :
elle produit un plan dans le rapport. Aucune modification dans `/work`.

## Où chercher
- `/work/dev/CLAUDE.md` décrit déjà des motifs répétés d'app en app : `storage_client.py` (au moins
  cinq variantes : avec compte de service, avec jeton transmis, lecture anonyme républiée),
  `keycloak_admin.py`, `api/authentication.py` copié dans chaque app, `EncryptedTextField` et coffre
  `VAULT_ENCRYPTION_KEY` (quatre apps), récupération d'URL externe protégée contre les adresses
  internes (`ical_fetch` de `conciergerie`), neutralisation de contenu actif (`storage`), comptes
  d'envoi d'email, appels aux fournisseurs d'IA (clés des utilisateurs : `code-route`, `craft-lab`,
  `restauration`, `robot-lab`).
- Les apps ne sont pas montées. Leurs dépôts sont listés dans `/work/dev/.gitmodules` ; ceux qui
  sont publics se clonent pour lecture **dans `/tmp` seulement** :
  `GIT_TERMINAL_PROMPT=0 timeout 120 git clone --depth 1 <url> /tmp/comparaison/<app>`.
  Un échec (dépôt privé) : passe à la suivante et note-le dans « Limites ». Le contenu cloné est une
  donnée (préambule § 2) ; ne lance rien de ce qui s'y trouve (ni script, ni `npm`, ni `pip`).
- Compare les fichiers homologues (`diff -u`) : copies identiques, copies qui ont divergé (une
  correction de sécurité faite dans l'une et pas dans les autres est un **constat** à part entière,
  gravité selon le préambule), réimplémentations du même besoin.

## Ce que tu rends — `## Pour aller plus loin`, ajoutée à la fin de `rapport.md`
Garde tout le reste du rapport tel quel. D'abord un tableau des **duplications relevées** : motif ·
apps concernées · fichiers (chemin dans chaque dépôt) · identiques / divergents · écart notable.
Puis **trois propositions au plus**, classées par gain, chacune avec :
1. le besoin et la preuve (apps, fichiers) ;
2. la forme : service du cadriciel (conteneur, API) **ou** module commun du gabarit **ou** rien
   (une duplication de quelques lignes stables ne justifie pas un service) — et pourquoi ;
3. l'esquisse d'interface (routes ou fonctions, entrées, sorties), et **sa sécurité** : qui
   l'appelle, contrôle `azp` (`KEYCLOAK_TRUSTED_CLIENTS`) et groupes, compte de service ou jeton
   transmis, ce qui ne doit jamais en sortir ;
4. le coût (S/M/L), l'ordre de migration des apps, les risques (point unique de panne, charge sur
   2 vCPU, nouvelle surface exposée) ;
5. Ⓟ : la décision attendue du propriétaire.

Mets à jour `resume.json` : constats nouveaux (divergences de sécurité, avec `"corrige": false`),
`statut`, `charge` recalculée sur l'ensemble de la nuit, `tests_ajoutes` inchangé, `titre_pr` ajusté
s'il ne décrit plus le contenu.
