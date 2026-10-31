import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

// Ce que le runner exécute — contrat « urgences » v1, interface I2.
//
// Le runner ne charge JAMAIS de code venu du dépôt d'une app : un dépôt est
// écrit par son développeur, et ce conteneur a sous les yeux tout le dépôt
// parent (donc sso-lab/.env) et les mots de passe des comptes e2e dans son
// environnement. Le spec joué est toujours celui du gabarit, que seul le
// superutilisateur écrit ; la présence du spec dans l'app n'est qu'un signal
// (« cette app a un test de cloisonnement »), son contenu n'est jamais lu.

export const DEV_ROOT = '/mnt/dev';
export const SPEC_NAME = 'cloisonnement.spec.ts';
export const TEMPLATE_SPEC = path.join(
  DEV_ROOT, '_templates', 'django-angular', 'frontend', 'e2e', SPEC_NAME,
);

// Même forme qu'un nom d'app du lab (check-app-name.sh) ; refuse d'emblée tout
// « .. », « / », majuscule ou caractère exotique avant le moindre path.join.
const APP_NAME_RE = /^[a-z][a-z0-9-]{0,62}$/;

export function isValidAppName(name) {
  return typeof name === 'string' && APP_NAME_RE.test(name);
}

/** Copie le spec du gabarit dans un dossier temporaire neuf, propre à ce run.
 * Rend le chemin du dossier (à passer en E2E_TEST_DIR, puis à removeRunDir). */
export function prepareRunDir(templateSpec = TEMPLATE_SPEC, tmpRoot = os.tmpdir()) {
  const dir = fs.mkdtempSync(path.join(tmpRoot, 'lab-runner-'));
  try {
    fs.copyFileSync(templateSpec, path.join(dir, SPEC_NAME));
  } catch (err) {
    removeRunDir(dir);
    throw new Error(`spec du gabarit illisible (${templateSpec}) : ${err.message ?? err}`);
  }
  return dir;
}

export function removeRunDir(dir) {
  if (dir) fs.rmSync(dir, { recursive: true, force: true });
}
