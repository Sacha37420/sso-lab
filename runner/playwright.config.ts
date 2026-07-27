import { defineConfig } from '@playwright/test';

// testDir piloté par E2E_TEST_DIR (posé par server.js avant chaque appel) :
// le dossier e2e/ de l'app ciblée est hors de l'arborescence de ce fichier de
// config, et Playwright résout ses arguments positionnels comme des FILTRES
// à l'intérieur de testDir, pas comme des chemins arbitraires — passer le
// dossier en argument CLI (au lieu de testDir) donne silencieusement
// "No tests found" (vérifié). D'où testDir dynamique plutôt qu'un argument.
const testDir = process.env.E2E_TEST_DIR ?? process.cwd();
//
// E2E_DOMAIN (posé par server.js avant de lancer Playwright) : remappe la
// résolution DNS du domaine public vers le conteneur `caddy` (réseau sso-net
// partagé). Sans ça, Chromium sortirait vers l'IP WAN publique pour ensuite
// rentrer sur le même réseau — hairpin NAT, pas garanti sur toutes les box
// (cf. reset_url.sh). SNI/Host restent le vrai domaine : le certificat Caddy
// valide normalement, et le client Keycloak a un redirectUris:["*"] (voir
// create-app-client.sh), donc rien à adapter côté redirection OAuth.
const domain = process.env.E2E_DOMAIN;
const resolverArgs = domain ? [`--host-resolver-rules=MAP ${domain} caddy`] : [];

export default defineConfig({
  testDir,
  timeout: 30_000,
  use: {
    headless: true,
    trace: 'retain-on-failure',
    launchOptions: { args: resolverArgs },
  },
});
