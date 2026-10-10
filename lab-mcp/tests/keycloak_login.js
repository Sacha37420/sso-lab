// Connexion RÉELLE à Keycloak par le client `lab-mcp` (authorization code + PKCE
// S256), dans le navigateur de lab-runner. Le client n'autorise pas le password
// grant : il n'y a pas d'autre moyen d'obtenir un vrai jeton `azp = lab-mcp`.
//
//   docker exec -i -e LOGIN_AS=e2e_member lab-runner node - < tests/keycloak_login.js > jetons.json
//
// LOGIN_AS : e2e_member (défaut) | e2e_outsider. NO_PKCE=1 : omet le challenge.
// CLIENT=lab-admin REDIRECT=https://<DOMAIN>/lab-admin/ : jeton de l'entrée web.
// Sortie (stdout) : JSON {access_token, id_token} ou {denied: "<texte de la page>"}.
// Le mot de passe est lu dans sso-lab/.env (montage /mnt/dev) et jamais affiché.
const { chromium } = require('/app/node_modules/playwright');
const crypto = require('crypto');
const fs = require('fs');

const env = (file, key) => {
  const m = fs.readFileSync(file, 'utf8').match(new RegExp('^' + key + '=(.*)$', 'm'));
  return m ? m[1].trim().replace(/^['"]|['"]$/g, '') : '';
};
const who = process.env.LOGIN_AS || 'e2e_member';
const domain = env('/mnt/dev/.env', 'DOMAIN');
const password = env('/mnt/dev/sso-lab/.env', who.toUpperCase() + '_PASSWORD');
const CLIENT = process.env.CLIENT || 'lab-mcp';
const REDIRECT = process.env.REDIRECT || 'http://localhost:8976/callback';
const b64 = (b) => b.toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');

(async () => {
  const verifier = b64(crypto.randomBytes(48));
  const challenge = b64(crypto.createHash('sha256').update(verifier).digest());
  const state = b64(crypto.randomBytes(16));
  const params = new URLSearchParams({
    client_id: CLIENT, response_type: 'code', redirect_uri: REDIRECT,
    scope: 'openid profile email', state,
  });
  if (!process.env.NO_PKCE) { params.set('code_challenge', challenge); params.set('code_challenge_method', 'S256'); }
  const browser = await chromium.launch({ args: [`--host-resolver-rules=MAP ${domain} caddy`] });
  const page = await (await browser.newContext()).newPage();
  let callback = null;
  page.on('request', (r) => { if (!callback && r.url().startsWith(REDIRECT) && /[?&]code=/.test(r.url())) callback = r.url(); });
  await page.goto(`https://${domain}/auth/realms/ssolab/protocol/openid-connect/auth?${params}`).catch(() => {});
  if (!callback && await page.locator('#username').count()) {
    await page.fill('#username', who);
    await page.fill('#password', password);
    await page.click('#kc-login').catch(() => {});
    await page.waitForTimeout(4000);
  }
  if (!callback) {
    const text = (await page.locator('body').innerText().catch(() => '')).replace(/\s+/g, ' ').slice(0, 200);
    console.log(JSON.stringify({ denied: text }));
    await browser.close();
    return;
  }
  await browser.close();
  const u = new URL(callback);
  if (u.searchParams.get('state') !== state) throw new Error('state inattendu');
  const res = await fetch('http://keycloak:8080/realms/ssolab/protocol/openid-connect/token', {
    method: 'POST',
    body: new URLSearchParams({
      grant_type: 'authorization_code', client_id: CLIENT, code: u.searchParams.get('code'),
      redirect_uri: REDIRECT, code_verifier: verifier,
    }),
  });
  const tok = await res.json();
  if (!tok.access_token) { console.log(JSON.stringify({ denied: 'échange du code refusé : ' + JSON.stringify(tok).slice(0, 200) })); return; }
  console.log(JSON.stringify({ access_token: tok.access_token, id_token: tok.id_token }));
})().catch((e) => { console.error(String(e)); process.exit(1); });
