import fs from 'node:fs';
import path from 'node:path';
import { DEV_ROOT, SPEC_NAME } from './spec.js';

// Tout le dépôt est monté sous DEV_ROOT (docker-compose.yml : ${HOST_DEV_ROOT}:/mnt/dev:ro).
// Les fonctions exportées supposent un nom déjà validé (isValidAppName, lib/spec.js).

// Même règle que lab-admin/backend/api/infra_info.py (_HANDLE_PATH_RE) : les
// labels caddy.handle_path du docker-compose.yml d'une app sont la seule
// source de vérité du routage réel (le nom de dossier peut diverger du
// préfixe). Dupliqué ici faute de pouvoir importer du Python — à garder en
// tête si la convention de label change un jour.
const HANDLE_PATH_RE = /caddy\.handle_path:\s*"(\/[^"]*)\/\*"/g;

function envVal(file, key) {
  if (!fs.existsSync(file)) return '';
  const content = fs.readFileSync(file, 'utf8');
  const re = new RegExp(`^${key}[ \\t]*=(.*)$`, 'm');
  const m = content.match(re);
  if (!m) return '';
  return m[1].trim().replace(/^["']|["']$/g, '');
}

/** Dossier d'une app : `deploiement/<app>` s'il existe (emplacement cible, voir
 * CLAUDE.md), sinon `<app>` à la racine (apps pas encore déménagées). Même règle
 * que registry_app_dir dans scripts/lib/registry.sh. */
function appDir(app, root = DEV_ROOT) {
  const deployed = path.join(root, 'deploiement', app);
  return fs.existsSync(deployed) ? deployed : path.join(root, app);
}

function frontendPath(app, root = DEV_ROOT) {
  const composeFile = path.join(appDir(app, root), 'docker-compose.yml');
  if (!fs.existsSync(composeFile)) return null;
  const content = fs.readFileSync(composeFile, 'utf8');
  const paths = [...content.matchAll(HANDLE_PATH_RE)].map((m) => m[1]);
  return paths.find((p) => !p.endsWith('-api')) ?? null;
}

/** Vrai si l'app porte frontend/e2e/cloisonnement.spec.ts. Seul signal « cette
 * app a un test » : le fichier n'est jamais lu ni chargé (contrat urgences v1, I2). */
export function hasAppSpec(app, root = DEV_ROOT) {
  return fs.existsSync(path.join(appDir(app, root), 'frontend', 'e2e', SPEC_NAME));
}

/** Résolution complète pour un run réel : URL publique de l'app + identifiants
 * e2e_member/e2e_outsider lus depuis sso-lab/.env (jamais mis en cache — donc
 * une rotation LDAP ne casse jamais le runner, cf. rotate-ldap-user-passwords.sh). */
export function resolveApp(app, root = DEV_ROOT) {
  const domain = envVal(path.join(root, '.env'), 'DOMAIN');
  const fPath = frontendPath(app, root);
  if (!domain || domain === 'CHANGE_ME' || !fPath) {
    throw new Error(
      `Impossible de résoudre l'URL de "${app}" (DOMAIN="${domain}", chemin frontend="${fPath}").`,
    );
  }
  const appUrl = `https://${domain}${fPath}/`;

  const ssoEnv = path.join(root, 'sso-lab', '.env');
  const memberPassword = envVal(ssoEnv, 'E2E_MEMBER_PASSWORD');
  const outsiderPassword = envVal(ssoEnv, 'E2E_OUTSIDER_PASSWORD');
  if (!memberPassword || !outsiderPassword) {
    throw new Error(
      'E2E_MEMBER_PASSWORD/E2E_OUTSIDER_PASSWORD absents de sso-lab/.env — ' +
      'rotate-ldap-user-passwords.sh (ou rotate-secrets-full.sh) a-t-il tourné ' +
      'au moins une fois depuis l\'ajout des comptes e2e_member/e2e_outsider ?',
    );
  }

  return {
    appUrl,
    domain,
    hasSpec: hasAppSpec(app, root),
    env: {
      E2E_APP_URL: appUrl,
      E2E_DOMAIN: domain,
      E2E_MEMBER_USER: 'e2e_member',
      E2E_MEMBER_PASSWORD: memberPassword,
      E2E_OUTSIDER_USER: 'e2e_outsider',
      E2E_OUTSIDER_PASSWORD: outsiderPassword,
    },
  };
}
