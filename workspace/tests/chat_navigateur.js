// Conversation complète jouée en navigateur réel (Chromium, Playwright) contre le service de
// conversation, À TRAVERS un proxy qui retire le préfixe /ws/<uid>/_chat (ce que fera la
// passerelle du lab), avec le faux agent ACP (tests/faux_agent_acp.js).
//
// Lancé par verify.sh dans un conteneur jetable de l'image du runner. Variables :
//   CHAT_URL   http://<proxy>:<port>/ws/<uid>/_chat/
//   LARGEUR    largeur de la fenêtre (390 = téléphone, 1280 = bureau)
//   CAPTURES   dossier où écrire les captures (facultatif)
//
// Trois gestes ne peuvent pas être faits depuis la page : ils sont DEMANDÉS à verify.sh par une
// ligne `ACTION <nom>` sur la sortie, et la page en constate l'effet :
//   ACTION coupe            redémarrer le proxy (vraie coupure réseau, WebSocket compris)
//   ACTION sans-identifiants / ACTION avec-identifiants   faire répondre le faux agent
//                           comme un assistant non connecté, puis de nouveau connecté
// Sortie : `RESULTAT {json}` — étapes (ok / ECHEC …), contrôles de mise en page, requêtes.
const { chromium } = require('playwright');
const path = require('path');

const URL_CHAT = process.env.CHAT_URL;
const LARGEUR = parseInt(process.env.LARGEUR || '390', 10);
const HAUTEUR = LARGEUR < 900 ? 844 : 800;
const CAPTURES = process.env.CAPTURES || '';
const origine = new URL(URL_CHAT).origin;
const prefixe = new URL(URL_CHAT).pathname;

(async () => {
  const res = { largeur: LARGEUR, etapes: {}, erreurs: [], horsPrefixe: [], externes: [], console: [], debordements: [], cibles: [], sockets: 0 };
  const browser = await chromium.launch({ args: ['--no-sandbox', '--disable-dev-shm-usage'] });
  const contexte = await browser.newContext({ viewport: { width: LARGEUR, height: HAUTEUR }, deviceScaleFactor: LARGEUR < 900 ? 2 : 1,
    hasTouch: LARGEUR < 900, isMobile: LARGEUR < 900, locale: 'fr-FR', colorScheme: 'light' });
  const page = await contexte.newPage();
  const ecoute = pg => {
    pg.on('request', r => {
      const u = new URL(r.url());
      if (u.protocol === 'data:') return;
      if (u.origin !== origine && u.origin !== origine.replace(/^http/, 'ws')) res.externes.push(r.url());
      else if (!u.pathname.startsWith(prefixe.replace(/_chat\/$/, ''))) res.horsPrefixe.push(u.pathname);
    });
    pg.on('response', r => { if (r.status() >= 400) res.erreurs.push(`${r.status()} ${new URL(r.url()).pathname}`); });
    pg.on('console', m => { if (m.type() === 'error') res.console.push(m.text().slice(0, 200)); });
    pg.on('pageerror', e => res.console.push('pageerror ' + String(e).slice(0, 200)));
    pg.on('websocket', () => { res.sockets++; });
  };
  ecoute(page);

  let n = 0;
  // Capture + contrôles de mise en page : pas de défilement horizontal, cibles tactiles ≥ 44 px.
  const controle = async (nom, pg = page) => {
    const m = await pg.evaluate(() => {
      const visibles = [...document.querySelectorAll('button, a.btn, summary, label.reglage, textarea')].filter(e => {
        const r = e.getBoundingClientRect(), s = getComputedStyle(e);
        return r.width > 0 && r.height > 0 && s.visibility !== 'hidden' && r.bottom > 0 && r.top < innerHeight;
      });
      return {
        large: document.documentElement.scrollWidth, fenetre: innerWidth,
        filLarge: document.getElementById('fil').scrollWidth - document.getElementById('fil').clientWidth,
        petites: visibles.filter(e => { const r = e.getBoundingClientRect(); return r.height < 43.5 || r.width < 43.5; })
          .map(e => `${e.tagName.toLowerCase()}#${e.id || e.className}:${Math.round(e.getBoundingClientRect().width)}x${Math.round(e.getBoundingClientRect().height)}`),
      };
    });
    if (m.large > m.fenetre || m.filLarge > 0) res.debordements.push(`${nom}: page ${m.large}/${m.fenetre}, fil +${m.filLarge}`);
    for (const p of m.petites) res.cibles.push(`${nom}: ${p}`);
    if (CAPTURES) await pg.screenshot({ path: path.join(CAPTURES, `${LARGEUR}-${String(++n).padStart(2, '0')}-${nom}.png`) }).catch(() => {});
  };
  const etape = async (nom, f) => {
    try { await f(); res.etapes[nom] = 'ok'; }
    catch (e) { res.etapes[nom] = 'ECHEC ' + String(e.message).split('\n')[0].slice(0, 300); if (CAPTURES) await page.screenshot({ path: path.join(CAPTURES, `${LARGEUR}-ECHEC-${nom}.png`) }).catch(() => {}); }
  };
  // La page interdit l'évaluation de chaînes (politique de contenu `script-src 'self'`), ce dont
  // `page.waitForFunction` a besoin : on attend donc en interrogeant la page depuis ici. La
  // politique reste active pendant tout l'essai — c'est elle qu'on éprouve aussi.
  const attendQue = async (f, arg, ms = 30000, pg = page) => {
    const fin = Date.now() + ms;
    for (;;) {
      if (await pg.evaluate(f, arg).catch(() => false)) return;
      if (Date.now() > fin) throw new Error('attente dépassée : ' + String(f).slice(0, 120) + ' ' + JSON.stringify(arg || ''));
      await pg.waitForTimeout(100);
    }
  };
  const attendTexte = (sel, t, ms = 30000) => attendQue(([s, x]) => [...document.querySelectorAll(s)].some(e => (e.textContent || '').includes(x)), [sel, t], ms);
  const etat = t => attendTexte('#etat-connexion', t);
  const repos = () => page.waitForSelector('#envoyer:not([hidden]):not([disabled])', { timeout: 30000 });
  const dit = async t => { await repos(); await page.fill('#texte', t); await page.click('#envoyer'); };
  const dernier = sel => page.evaluate(s => { const l = document.querySelectorAll(s); return l.length ? l[l.length - 1].textContent : null; }, sel);
  const compte = sel => page.evaluate(s => document.querySelectorAll(s).length, sel);
  const verifie = (c, m) => { if (!c) throw new Error(m); };
  const tiroir = async () => { if (LARGEUR < 900) { await page.click('#ouvrir-tiroir'); await page.waitForSelector('.app.tiroir-ouvert'); } };

  await etape('page', async () => {
    await page.goto(URL_CHAT + '?agent=claude', { waitUntil: 'domcontentloaded', timeout: 60000 });
    await attendTexte('.vide', 'Nouvelle conversation');
    await etat('· connecté');
    verifie((await page.textContent('#projet')) === 'demo-app' && (await page.textContent('#etat-connexion')).startsWith('Claude Code'), 'projet ou assistant absent de l\'en-tête');
    verifie((await page.getAttribute('.bascule button[data-agent="claude"]', 'aria-pressed')) === 'true', 'assistant en cours non marqué dans la bascule');
    verifie(!(await page.isChecked('#auto')), '« tout accepter » coché par défaut');
    await controle('nouvelle-conversation');
  });
  await etape('flux', async () => {
    await dit('bonjour');
    await attendTexte('.msg-agent', 'Voilà.');
    await repos();
    verifie(await compte('.msg-agent pre code') === 1 && await compte('.msg-agent li') === 2 && await compte('.msg-agent strong') === 1, 'Markdown non rendu');
    verifie((await dernier('.msg-user')) === 'bonjour', 'message de l\'utilisateur absent');
    await controle('texte-au-fil-de-l-eau');
  });
  await etape('outil', async () => {
    await dit('outil');
    await page.waitForSelector('details.outil.etat-completed', { timeout: 30000 });
    await attendTexte('.msg-agent', 'un lot');
    verifie(!(await page.evaluate(() => document.querySelector('details.outil').open)), 'appel d\'outil non replié');
    verifie((await dernier('details.outil .o-etat')) === 'terminé', 'état de l\'outil non affiché');
    await controle('outil-replie');
    await page.click('details.outil summary');
    await attendTexte('details.outil pre', 'Feuille de route');
    await controle('outil-deplie');
  });
  await etape('autorisation_accordee', async () => {
    await dit('modifie');
    await page.waitForSelector('.panneau.autorisation', { timeout: 30000 });
    const boutons = await page.$$eval('.panneau.autorisation .actions button', l => l.map(b => b.textContent));
    verifie(JSON.stringify(boutons) === JSON.stringify(['Autoriser une fois', 'Always allow edits', 'Refuser']), 'boutons inattendus : ' + boutons.join(' | '));
    verifie(await compte('.panneau.autorisation .diff .diff-l.a') === 3, 'modification non lisible dans la demande (3 lignes ajoutées attendues)');
    await page.waitForTimeout(2000);
    verifie(await compte('.panneau.autorisation') === 1 && await page.isVisible('#arreter'), 'la demande n\'attend pas la réponse');
    await controle('demande-d-autorisation');
    await page.click('.panneau.autorisation button[data-kind="allow_once"]');
    await attendTexte('.msg-agent', 'Fichier modifié');
    await repos();
    verifie(await compte('.panneau.autorisation') === 0 && await compte('.ligne-perm.accorde') === 1, 'accord non reflété');
    verifie(await page.evaluate(() => { const d = [...document.querySelectorAll('details.outil')].pop(); return d.open && !!d.querySelector('.diff-l.a'); }), 'modification de fichier non lisible dans le fil');
    await controle('autorisation-accordee');
  });
  await etape('autorisation_refusee', async () => {
    await dit('modifie');
    await page.waitForSelector('.panneau.autorisation', { timeout: 30000 });
    await page.click('.panneau.autorisation button[data-kind="reject_once"]');
    await attendTexte('.msg-agent', 'Modification refusée');
    await repos();
    verifie(await compte('.ligne-perm.refuse') === 1 && (await dernier('details.outil .o-etat')) === 'échec', 'refus non reflété');
    await controle('autorisation-refusee');
  });
  await etape('arret', async () => {
    await dit('long');
    await attendTexte('.msg-agent', 'morceau 3 ');
    const avant = (await dernier('.msg-agent')).length;
    await page.waitForTimeout(700);
    verifie((await dernier('.msg-agent')).length > avant, 'le texte n\'arrive pas au fil de l\'eau');
    verifie(await page.isVisible('#arreter') && !(await page.isVisible('#envoyer')), 'bouton d\'arrêt absent pendant le tour');
    await controle('tour-en-cours');
    await page.click('#arreter');
    await attendTexte('.note', 'Tour arrêté.');
    await repos();
    verifie(!(await dernier('.msg-agent')).includes('morceau 40'), 'le tour ne s\'est pas arrêté');
  });
  await etape('coupure_pendant_un_tour', async () => {
    await dit('long');
    await attendTexte('.msg-agent', 'morceau 4 ');
    console.log('ACTION coupe');
    await etat('Connexion perdue');
    await controle('connexion-perdue');
    await etat('· au travail');                               // reconnecté, le tour continue
    await attendTexte('.msg-agent', 'morceau 40', 40000);
    await repos();
    const t = await dernier('.msg-agent');
    verifie(t.split('morceau 7 ').length === 2 && t.split('morceau 30 ').length === 2, 'texte perdu ou doublé après la reconnexion');
    verifie(await compte('.msg-user') === 6, 'le fil n\'a pas été rejoué à l\'identique');
    await controle('apres-reconnexion');
  });
  await etape('coupure_pendant_une_demande', async () => {
    await dit('commande');
    await page.waitForSelector('.panneau.autorisation', { timeout: 30000 });
    console.log('ACTION coupe');
    await etat('Connexion perdue');
    await etat('· au travail');
    await page.waitForSelector('.panneau.autorisation button:not([disabled])', { timeout: 30000 });
    verifie((await page.textContent('.panneau.autorisation pre')).includes('git status --short'), 'commande absente de la demande rejouée');
    verifie(await compte('.panneau.autorisation .p-outil') === 0, 'commande répétée dans la demande');
    await controle('demande-toujours-en-attente');
    await page.click('.panneau.autorisation button[data-kind="allow_always"]');
    await attendTexte('.msg-agent', 'Commande lancée');
    await repos();
  });
  await etape('plan', async () => {
    await dit('plan');
    await attendTexte('.msg-agent', 'Plan déroulé');
    await repos();
    verifie(await compte('.plan') === 1 && await compte('.plan li.completed') === 3, 'plan non rendu');
  });
  await etape('tout_accepter', async () => {
    await page.click('#reglage-auto');
    await page.waitForSelector('#reglage-auto.actif');
    await dit('modifie');
    await attendTexte('.ligne-perm.accorde', 'Accepté automatiquement');
    await repos();
    await controle('tout-accepter');
    await page.click('#reglage-auto');
    await page.waitForSelector('#reglage-auto:not(.actif)');
    verifie(!(await page.isChecked('#auto')), 'réglage non réversible');
  });
  await etape('conversations', async () => {
    await page.click('#reglage-auto'); await page.waitForSelector('#reglage-auto.actif');     // pour vérifier qu'il n'est PAS repris
    await tiroir();
    await page.waitForSelector('#liste button');
    await controle('conversations');
    await page.click('#nouvelle');
    await attendTexte('.vide', 'Nouvelle conversation');
    await repos();
    verifie(!(await page.isChecked('#auto')), '« tout accepter » repris dans une nouvelle conversation');
    await dit('seconde conversation');
    await attendTexte('.msg-agent', 'Voilà.');
    await repos();
    await tiroir();
    await attendQue(() => document.querySelectorAll('#liste button').length === 2);
    const titres = await page.$$eval('#liste .l-titre', l => l.map(e => e.textContent));
    verifie(titres[0] === 'seconde conversation' && titres[1] === 'bonjour', 'liste inattendue : ' + titres.join(' | '));
    await controle('liste-des-conversations');
    await page.click('#liste li:nth-child(2) button');
    await attendTexte('.msg-agent', 'Plan déroulé');
    await repos();
    verifie(await compte('.msg-user') === 9 && await compte('details.outil') === 5 && await compte('.plan') === 1, 'reprise incomplète');
    verifie(!(await page.isChecked('#auto')), '« tout accepter » repris à la reprise d\'une conversation');
    await controle('reprise');
    await dit('bonjour encore');
    await attendQue(() => document.querySelectorAll('.msg-user').length === 10 && !document.getElementById('envoyer').hidden);
  });
  await etape('bascule', async () => {
    await page.click('.bascule button[data-agent="vibe"]');
    await attendTexte('.vide', 'Mistral Vibe');
    await repos();
    verifie(page.url().endsWith('?agent=vibe') && (await page.textContent('#etat-connexion')).startsWith('Mistral Vibe'), 'bascule non reflétée');
    await dit('bonjour');
    await attendTexte('.msg-agent', 'faux agent vibe');
    await repos();
    await controle('bascule-vibe');
  });
  await etape('sans_identifiants', async () => {
    console.log('ACTION sans-identifiants');
    await page.waitForTimeout(4000);
    await tiroir();
    await page.click('#nouvelle');
    await page.waitForSelector('#panneau-auth', { timeout: 30000 });
    const t = await page.textContent('#panneau-auth');
    verifie(t.includes("n'a pas de clé d'API") && t.includes('vibe --setup') && t.includes("n'affiche jamais vos identifiants"), 'explication Vibe absente');
    verifie(!(await page.isVisible('#texte')), 'saisie visible sans identifiants');
    verifie((await page.textContent('#etat-connexion')).includes('à connecter'), 'état « à connecter » absent de l\'en-tête');
    verifie(new URL(await page.$eval('#panneau-auth a', a => a.href)).pathname === prefixe.replace(/_chat\/$/, ''), 'lien vers l\'éditeur inattendu');
    await controle('sans-identifiants-vibe');
    await page.click('.bascule button[data-agent="claude"]');
    await repos();
    await dit('bonjour');
    await page.waitForSelector('#panneau-auth', { timeout: 30000 });
    const c = await page.textContent('#panneau-auth');
    verifie(c.includes("n'est pas connecté") && c.includes('/login'), 'explication Claude absente');
    await controle('sans-identifiants-claude');
    console.log('ACTION avec-identifiants');
    await page.waitForTimeout(4000);
    await page.click('#panneau-auth button');
    await attendTexte('.vide', 'Nouvelle conversation');
    await repos();
    await dit('bonjour');
    await attendTexte('.msg-agent', 'faux agent claude');
  });
  await etape('rechargement', async () => {           // la page rechargée retrouve l'assistant et la conversation
    await page.reload({ waitUntil: 'domcontentloaded' });
    await attendTexte('.msg-agent', 'faux agent claude');
    verifie(page.url().endsWith('?agent=claude'), 'assistant perdu au rechargement');
  });
  await etape('theme_sombre', async () => {
    const c2 = await browser.newContext({ viewport: { width: LARGEUR, height: HAUTEUR }, deviceScaleFactor: LARGEUR < 900 ? 2 : 1, colorScheme: 'dark', locale: 'fr-FR' });
    const p2 = await c2.newPage(); ecoute(p2);
    await p2.goto(URL_CHAT, { waitUntil: 'domcontentloaded' });           // sans ?agent= : dernier utilisé
    await attendQue(() => document.querySelectorAll('.msg-agent').length > 0, null, 30000, p2);
    res.dernierAgent = new URL(p2.url()).search;
    const fond = await p2.evaluate(() => getComputedStyle(document.body).backgroundColor);
    verifie(fond === 'rgb(12, 14, 20)', 'thème sombre non appliqué : ' + fond);
    await controle('theme-sombre', p2);
    await c2.close();
  });

  for (const k of ['erreurs', 'horsPrefixe', 'externes', 'console', 'debordements', 'cibles']) res[k] = [...new Set(res[k])];
  console.log('RESULTAT ' + JSON.stringify(res));
  await browser.close();
})().catch(e => { console.log('RESULTAT ' + JSON.stringify({ fatal: String(e) })); process.exit(1); });
