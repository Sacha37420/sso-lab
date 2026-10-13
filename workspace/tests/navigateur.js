// Preuve en navigateur réel (Chromium, Playwright) — lancée par verify.sh dans un conteneur
// jetable de l'image du runner du lab. Charge l'éditeur À TRAVERS le proxy, sous /ws/<uid>/ :
//   - aucune ressource en erreur côté proxy (le piège des chemins absolus) ;
//   - les WebSockets s'ouvrent sous le préfixe et échangent des trames ;
//   - un fichier Python s'ouvre et l'extension Python s'active ;
//   - une commande tapée dans le terminal intégré s'exécute.
// Écrit une ligne `RESULTAT {json}` puis `PRET`, et garde la page ouverte TENIR_S secondes
// pour que verify.sh mesure la mémoire de l'espace « éditeur ouvert ».
const { chromium } = require('playwright');

const URL_WS = process.env.WS_URL;                 // http://<proxy>/ws/<uid>/
const TENIR_S = parseInt(process.env.TENIR_S || '30', 10);
const origine = new URL(URL_WS).origin;
const prefixe = new URL(URL_WS).pathname;

(async () => {
  const res = { erreurs: [], horsPrefixe: [], sockets: [], etapes: {} };
  const browser = await chromium.launch({ args: ['--no-sandbox', '--disable-dev-shm-usage'] });
  const page = await (await browser.newContext({ viewport: { width: 1400, height: 900 } })).newPage();
  page.on('request', r => {
    const u = new URL(r.url());
    if (u.origin === origine && !u.pathname.startsWith(prefixe)) res.horsPrefixe.push(u.pathname);
  });
  page.on('response', r => {
    if (r.url().startsWith(origine) && r.status() >= 400) res.erreurs.push(`${r.status()} ${new URL(r.url()).pathname}`);
  });
  page.on('requestfailed', r => {
    if (r.url().startsWith(origine)) res.erreurs.push(`ECHEC ${new URL(r.url()).pathname} ${r.failure() && r.failure().errorText}`);
  });
  page.on('websocket', ws => {
    const s = { chemin: new URL(ws.url()).pathname, recues: 0, fermee: false };
    res.sockets.push(s);
    ws.on('framereceived', () => { s.recues++; });
    ws.on('close', () => { s.fermee = true; });
  });
  const etape = async (nom, f) => {
    try { await f(); res.etapes[nom] = 'ok'; } catch (e) { res.etapes[nom] = 'ECHEC ' + String(e.message).split('\n')[0]; }
  };
  const palette = async commande => {
    await page.keyboard.press('F1');
    await page.waitForSelector('.quick-input-widget .input', { state: 'visible', timeout: 20000 });
    await page.keyboard.type(commande, { delay: 15 });
    await page.waitForTimeout(1500);
    await page.keyboard.press('Enter');
  };

  await etape('page', async () => {
    await page.goto(URL_WS, { waitUntil: 'domcontentloaded', timeout: 60000 });
    res.urlFinale = page.url();
    await page.waitForSelector('.monaco-workbench', { timeout: 120000 });
    await page.waitForSelector('.statusbar-item', { timeout: 120000 });
  });
  await etape('confiance', async () => {
    const b = page.getByRole('button', { name: /trust the authors/i }).first();
    try { await b.waitFor({ state: 'visible', timeout: 20000 }); await b.click(); res.confianceDemandee = true; }
    catch { res.confianceDemandee = false; }
  });
  await etape('fichier_python', async () => {
    await page.waitForTimeout(3000);
    await page.keyboard.press('Control+P');
    await page.waitForSelector('.quick-input-widget .input', { state: 'visible', timeout: 20000 });
    await page.keyboard.type('main.py', { delay: 20 });
    await page.waitForTimeout(2500);
    await page.keyboard.press('Enter');
    await page.waitForSelector('.tab[aria-label*="main.py"], .tab[data-resource-name="main.py"]', { timeout: 60000 });
  });
  await etape('extension_python', async () => {
    // L'extension Python active affiche l'interpréteur choisi dans la barre d'état.
    await page.waitForFunction(
      () => [...document.querySelectorAll('.statusbar-item')].some(e => /3\.12\.\d+/.test(e.textContent || '')),
      null, { timeout: 180000 });
  });
  await etape('terminal', async () => {
    await palette('Terminal: Create New Terminal');
    await page.waitForSelector('.terminal-wrapper .xterm', { timeout: 60000 });
    await page.waitForTimeout(4000);
    await page.locator('.terminal-wrapper .xterm').first().click();
    await page.keyboard.type('bash /tmp/preuve_terminal.sh', { delay: 20 });
    await page.keyboard.press('Enter');
    await page.waitForTimeout(8000);
  });
  // Tâches de l'essai (contrat « essai-dev », I3) : fournies par l'extension intégrée à l'image,
  // sans .vscode/tasks.json. Ce que les tâches ont réellement lancé se lit dans le journal du
  // faux serveur MCP (verify.sh) ; ici on relève ce que l'éditeur PROPOSE.
  const liste = () => page.evaluate(() => {
    const w = [...document.querySelectorAll('.quick-input-widget')].find(e => e.getBoundingClientRect().height > 0);
    return w ? [...w.querySelectorAll('.monaco-list-row')].map(e => (e.getAttribute('aria-label') || e.textContent || '').trim()) : null;
  });
  const capture = async nom => { if (process.env.CAPTURE) await page.screenshot({ path: process.env.CAPTURE.replace(/\.png$/, `-${nom}.png`) }).catch(() => {}); };
  // La palette classe « Tasks: Restart Running Task » devant « Tasks: Run Task » : on clique la ligne exacte.
  const commandeExacte = async titre => {
    await page.keyboard.press('F1');
    await page.waitForSelector('.quick-input-widget .input', { state: 'visible', timeout: 20000 });
    await page.keyboard.type(titre, { delay: 15 });
    await page.waitForTimeout(1500);
    const lignes = page.locator('.quick-input-widget .monaco-list-row');
    for (let i = 0; i < await lignes.count(); i++) {
      const nom = ((await lignes.nth(i).getAttribute('aria-label')) || '').split(',')[0].trim();
      if (nom === titre) return lignes.nth(i).click();
    }
    throw new Error(`commande « ${titre} » absente de la palette`);
  };
  await etape('taches_proposees', async () => {
    await commandeExacte('Tasks: Run Task');
    await page.waitForTimeout(4000);
    await page.keyboard.type('lab-essai', { delay: 20 });
    await page.waitForTimeout(2500);
    res.tachesTypes = await liste();
    await capture('taches-types');
    await page.keyboard.press('Enter');          // ouvre le type « lab-essai » : ses trois tâches
    await page.waitForTimeout(5000);
    res.taches = await liste();
    await capture('taches');
    if (!res.taches || !res.taches.some(t => /Lab : état de l'essai/.test(t))) throw new Error('tâche « Lab : état de l\'essai » non proposée');
    await page.keyboard.type('état', { delay: 20 });
    await page.waitForTimeout(1500);
    await page.keyboard.press('Enter');          // lance « Lab : état de l'essai »
    await page.waitForTimeout(8000);
    res.apresEtat = await liste();               // null attendu : aucune question posée (détecteur d'erreurs…)
    await page.keyboard.press('Escape');
  });
  await etape('tache_build_par_defaut', async () => {
    await commandeExacte('Tasks: Run Build Task');   // ce que fait Ctrl+Maj+B
    await page.waitForTimeout(8000);
    res.choixBuild = await liste();              // null attendu : la tâche par défaut part sans rien demander
    await capture('build');
    await page.keyboard.press('Escape');
    await page.waitForTimeout(6000);
  });
  if (process.env.CAPTURE) await page.screenshot({ path: process.env.CAPTURE }).catch(() => {});
  res.barreEtat = await page.evaluate(() => [...document.querySelectorAll('.statusbar-item')].map(e => (e.textContent || '').trim()).filter(Boolean));
  res.erreurs = [...new Set(res.erreurs)];
  res.horsPrefixe = [...new Set(res.horsPrefixe)];
  console.log('RESULTAT ' + JSON.stringify(res));
  console.log('PRET');
  await page.waitForTimeout(TENIR_S * 1000);
  await browser.close();
})().catch(e => { console.log('RESULTAT ' + JSON.stringify({ fatal: String(e) })); console.log('PRET'); process.exit(1); });
