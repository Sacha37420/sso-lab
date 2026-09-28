# Chantier « <nom> » — CONTRAT  ·  **version v1**

> Fichier **possédé par S1 (l'architecte) seul**. Aucun S2/S3 ne l'édite jamais — un besoin de
> changement passe par un amendement (`../amendements/`), voir la skill `chantier`.

## Journal des versions
| Version | Date | Ce qui change | Secteurs à re-notifier |
|---|---|---|---|
| v1 | AAAA-MM-JJ | rédaction initiale | — |

---

## 1. Objectif — formulation d'origine, à respecter à la lettre
<Recopier les mots de l'utilisateur. Ne pas reformuler : reformuler est déjà décider.>

## 2. Constat vérifié le AAAA-MM-JJ (à revérifier rapidement au démarrage)
<État réel du code, vérifié et non supposé, avec les fichiers/commandes qui l'établissent.
Chaque affirmation ici doit être re-vérifiable en une commande.>

## 3. Carte des secteurs

| # | Secteur | Périmètre exclusif (chemins) | Critère d'acceptation |
|---|---|---|---|
| 1 | <nom> | `<app>/backend/**`, `<app>/frontend/**` | <ce qui prouve que c'est fini> |
| 2 | | | |

Test à 3 critères (à cocher pour chaque secteur) : périmètre disjoint ☐ · ne parle aux autres que
par une interface ci-dessous ☐ · testable seul ☐.

## 4. Interfaces figées — **v1**

### I1 — <nom de l'interface> · producteur : secteur N · consommateurs : secteurs M, P
```
<schéma de données exact / signature d'endpoint / clé .env / convention de nommage>
```
Contraintes non négociables : <ce qui ne peut pas changer sans amendement>.

### I2 — …

## 5. Fichiers partagés — propriété exclusive de S1
Aucun S2/S3 ne les édite. Les modifications nécessaires sont **rapportées ligne à ligne** et
appliquées par S1 en un seul edit groupé à l'intégration.

`CLAUDE.md` · `README.md` · `.ports` · `.gitignore` · `.app-descriptions` · `infra/**` ·
`sso-lab/**` · `runner/**` · `scripts/**` · `<autres à lister pour ce chantier>`

## 6. Ressources sérialisées (jamais deux en parallèle — 2 vCPU / 16 Go)
Builds Docker lourds · `setup2.sh` / `recompose_docker.sh` · migrations de base ·
exécutions Playwright (`lab-runner`, mutex lab-wide, répond 409 si occupé).
**Les S2 ne déploient pas : ils rapportent la commande, S1 séquence.**

## 7. Questions déjà tranchées (ne pas rouvrir)
- <décision> — parce que <raison>. Alternative écartée : <laquelle et pourquoi>.

## 8. Questions volontairement ouvertes (le secteur tranche et documente)
- <question> — secteur <N> décide, documente son choix dans son rapport.
