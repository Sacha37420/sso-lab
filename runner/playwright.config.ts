import { defineConfig } from '@playwright/test';

// testDir piloté par E2E_TEST_DIR (posé par server.js avant chaque appel) :
// c'est le dossier temporaire où server.js a copié le spec du GABARIT
// (jamais le dossier e2e/ d'une app — contrat « urgences » v1, I2). Il est hors
// de l'arborescence de ce fichier de config, et Playwright résout ses
// arguments positionnels comme des FILTRES à l'intérieur de testDir, pas
// comme des chemins arbitraires — passer le dossier en argument CLI donne
// silencieusement "No tests found" (vérifié). D'où testDir dynamique.
const testDir = process.env.E2E_TEST_DIR ?? process.cwd();

// Seul fichier que le runner joue : cloisonnement.spec.ts. Second rempart
// derrière le dossier temporaire (qui ne contient que lui).
// Exception : storage/frontend/e2e/jouer-gestes.sh réutilise cette config par
// `docker exec` (geste humain, pas une route du runner) pour gestes.spec.ts,
// en posant E2E_GESTES=1 ; server.js ne pose jamais cette variable.
const testMatch = ['cloisonnement.spec.ts', ...(process.env.E2E_GESTES ? ['gestes.spec.ts'] : [])];
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
  testMatch,
  timeout: 30_000,
  use: {
    headless: true,
    trace: 'retain-on-failure',
    launchOptions: { args: resolverArgs },
  },
});
