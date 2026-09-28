# Rapport — secteur « <nom> »

**Contrat : v<N>**   ·   **Statut : `OK` | `AMENDEMENT` | `BLOQUÉ`**

<La première ligne est lue mécaniquement par S1 : un rapport `OK` estampillé d'une version
périmée est rejeté et renvoyé en revalidation. Ne pas l'omettre.>

## Ce qui a été fait
- <livrable> — `<fichier:ligne>`

## Vérification réelle (pas « devrait marcher »)
- <commande / parcours navigateur / test> → <résultat observé>
- Cas négatif vérifié : <ce qui doit échouer et échoue bien>

## Décisions prises dans mon périmètre
- <décision> — parce que <raison>. Alternative écartée : <laquelle>.

## À appliquer par S1 (je n'y ai PAS touché)
- Fichier partagé `<chemin>` : ligne exacte à ajouter → `<ligne>`
- Commande de provisionnement à lancer → `<commande>`
- Redéploiement nécessaire → `<commande>` (ne pas lancer en parallèle d'un autre build)

## Dépendances envers d'autres secteurs
- <point du code qui suppose <interface Ix> livrée ; ce qui se passe si elle ne l'est pas encore>

## Ce que ce secteur a appris et qui mérite `CLAUDE.md` / mémoire
- <piège découvert, mode d'échec silencieux, décision structurante>
