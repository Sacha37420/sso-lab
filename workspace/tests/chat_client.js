#!/usr/bin/env node
// Client d'essai du service de conversation, lancé DANS l'espace par verify.sh
// (NODE_PATH=/opt/lab/chat/node_modules). Parle le protocole de la page (WebSocket JSON)
// et rend une ligne `RESULTAT {json}` ; verify.sh juge.
//
//   node chat_client.js ouvre <agent>      ouvre une conversation, rend l'état vu par la page
//   node chat_client.js conversation       déroule tout le scénario avec le faux agent
//
// CHAT_URL (défaut http://127.0.0.1:8090) : adresse du service.
'use strict';
const http = require('http');
const WebSocket = require('ws');

const BASE = process.env.CHAT_URL || 'http://127.0.0.1:8090';
const dort = ms => new Promise(r => setTimeout(r, ms));
const get = chemin => new Promise((ok, ko) => http.get(BASE + chemin, r => { let d = ''; r.on('data', x => { d += x; }); r.on('end', () => { try { ok(JSON.parse(d)); } catch (e) { ko(e); } }); }).on('error', ko));
const activite = async () => (await get('/activity')).last_activity_ms;

// Une « page » : garde, comme la vraie, l'état reconstruit à partir des messages reçus.
class Page {
  constructor() { this.finsAvant = -1; this.recus = []; this.items = new Map(); this.session = null; this.agent = null; this.sessions = null; this.erreurs = []; this.attentes = []; }
  connecte() {
    return new Promise((ok, ko) => {
      const u = new URL(BASE); const ws = new WebSocket(`ws://${u.host}/ws`, { headers: { Origin: `http://${u.host}` } });
      this.ws = ws;
      ws.on('open', ok); ws.on('error', ko);
      ws.on('message', d => { const m = JSON.parse(d.toString()); this.recus.push(m); this.applique(m); this.reveille(); });
    });
  }
  applique(m) {
    if (m.type === 'agent') this.agent = m;
    else if (m.type === 'session') { this.session = m; this.items = new Map(m.items.map(i => [i.seq, i])); if (this.finsAvant < 0) this.finsAvant = this.fins(); }
    else if (m.type === 'state' && this.session && m.sessionId === this.session.sessionId) Object.assign(this.session, m, { type: 'session' });
    else if (m.type === 'item') this.items.set(m.item.seq, m.item);
    else if (m.type === 'append') { const i = this.items.get(m.seq); if (i) i.text += m.text; }
    else if (m.type === 'patch') this.items.set(m.item.seq, m.item);
    else if (m.type === 'sessions') this.sessions = m.sessions;
    else if (m.type === 'error') this.erreurs.push(m);
  }
  reveille() { this.attentes = this.attentes.filter(a => { if (a.test()) { clearTimeout(a.t); a.ok(true); return false; } return true; }); }
  attend(test, ms = 30000) {
    if (test()) return Promise.resolve(true);
    return new Promise(ok => { const a = { test, ok }; a.t = setTimeout(() => { this.attentes = this.attentes.filter(x => x !== a); ok(false); }, ms); this.attentes.push(a); });
  }
  envoie(m) { this.ws.send(JSON.stringify(m)); }
  liste(k) { return [...this.items.values()].filter(i => i.k === k); }
  dernier(k) { const l = this.liste(k); return l[l.length - 1]; }
  fins() { return [...this.items.values()].filter(i => i.k === 'end' || i.k === 'error').length; }
  // Envoie un message ; `finTour()` attend ensuite la fin de CE tour (un « end » de plus qu'à l'envoi).
  prompt(text) { this.finsAvant = this.fins(); this.envoie({ type: 'prompt', text }); }
  finTour() { return this.attend(() => this.session && !this.session.running && this.fins() > this.finsAvant); }
  coupe() { return new Promise(ok => { this.ws.on('close', ok); this.ws.terminate(); }); }
}

async function ouvre(agent) {
  const p = new Page(); await p.connecte();
  const t0 = Date.now();
  p.envoie({ type: 'open', agent, sessionId: null });
  await p.attend(() => p.session || p.erreurs.length || (p.agent && p.agent.state === 'error'), 150000);
  await dort(1500);          // laisse arriver un éventuel état d'authentification
  const r = { ms: Date.now() - t0, agent: p.agent, session: p.session ? { mode: p.session.mode, trust: p.session.trust, items: p.session.items.length } : null, erreurs: p.erreurs, activite: await activite() };
  p.ws.close();
  return r;
}

async function conversation() {
  const R = {};
  R.activite_avant = await activite();                             // personne ne s'est encore connecté
  let p = new Page(); await p.connecte();
  p.envoie({ type: 'open', agent: 'claude', sessionId: null });
  R.ouverte = await p.attend(() => p.session);
  const premiere = p.session.sessionId;
  R.mode_initial = p.session.mode;
  R.auto_initial = p.session.autoAccept;
  await dort(1200);
  R.activite_apres_ouverture = await activite();                   // page ouverte, rien d'échangé : n'avance pas

  // 1. texte au fil de l'eau
  const a0 = Date.now(); p.prompt('bonjour');
  await p.finTour();
  R.flux = { morceaux: p.recus.filter(m => m.type === 'append').length, texte: (p.dernier('text') || {}).text, fin: (p.dernier('end') || {}).stopReason, reflexion: !!p.dernier('thought') };
  R.activite_echange = (await activite()) >= a0;                   // cas 1 : client connecté + échange

  // 3. client connecté, plus rien : n'avance pas
  const a1 = await activite(); await dort(2500); const a2 = await activite();
  R.activite_fige = { identique: a1 === a2, retard_ms: Date.now() - a2 };

  // 2. appel d'outil
  const vus = new Set(); const suit = setInterval(() => { const o = p.dernier('tool'); if (o) vus.add(o.status); }, 20);
  p.prompt('outil'); await p.finTour(); clearInterval(suit);
  const o = p.dernier('tool');
  R.outil = { titre: o.title, genre: o.kind, etat: o.status, etats_vus: [...vus], contenu: (o.content[0] || {}).text, lieu: o.locations[0], entree: o.input };

  // 3. autorisation : accordée
  p.prompt('modifie');
  R.perm_demandee = await p.attend(() => (p.dernier('perm') || {}).state === 'pending');
  const perm = p.dernier('perm');
  R.perm = { titre: perm.title, options: perm.options.map(x => x.kind), outil_diff: (p.dernier('tool').content[0] || {}).type };
  await dort(1500);
  R.perm_attend = p.session.running && p.dernier('perm').state === 'pending';   // jamais d'accord automatique
  p.envoie({ type: 'permission', permId: perm.id, optionId: 'oui' });
  await p.finTour();
  R.perm_accordee = { etat: p.dernier('perm').state, choix: p.dernier('perm').chosen, outil: p.dernier('tool').status, texte: p.dernier('text').text };

  // 4. autorisation : refusée
  p.prompt('modifie');
  await p.attend(() => (p.dernier('perm') || {}).state === 'pending');
  p.envoie({ type: 'permission', permId: p.dernier('perm').id, optionId: 'non' });
  await p.finTour();
  R.perm_refusee = { choix: p.dernier('perm').chosen, outil: p.dernier('tool').status, texte: p.dernier('text').text };

  // 5. arrêt du tour, et activité continue pendant un tour
  p.prompt('long');
  await p.attend(() => (p.dernier('text') || {}).text && p.dernier('text').text.includes('morceau 3'));
  await dort(700); const t1 = Date.now(); const b1 = await activite();
  R.activite_tour = { ecart_ms: Math.abs(t1 - b1) };               // cas 2 : tour en cours = activité continue
  p.envoie({ type: 'cancel' });
  await p.finTour();
  R.arret = { fin: p.dernier('end').stopReason, texte_coupe: !p.dernier('text').text.includes('morceau 40') };

  // 6. coupure du WebSocket pendant un tour, reconnexion
  p.prompt('long');
  await p.attend(() => (p.dernier('text') || {}).text && p.dernier('text').text.includes('morceau 4'));
  const tCoupe = Date.now(); await p.coupe();
  await dort(500);          // le temps que le service constate la fermeture (sinon le premier relevé le précède)
  const c1 = await activite(); await dort(2000); const c2 = await activite();
  // tour en cours mais plus personne : la valeur s'arrête à l'instant de la coupure et n'avance plus
  R.activite_sans_client = c1 === c2 && c1 >= tCoupe - 1000 && c1 <= tCoupe + 500;
  p = new Page(); await p.connecte();
  p.envoie({ type: 'open', agent: 'claude', sessionId: premiere });
  await p.attend(() => p.session);
  R.reconnexion = { meme: p.session.sessionId === premiere, en_cours: p.session.running, rejoue: p.session.items.length, texte_garde: p.dernier('text').text.includes('morceau 4') };
  await p.finTour();
  R.reconnexion.fin = p.dernier('end').stopReason; R.reconnexion.complet = p.dernier('text').text.includes('morceau 40');

  // 7. coupure pendant qu'une autorisation est en attente
  p.prompt('commande');
  await p.attend(() => (p.dernier('perm') || {}).state === 'pending');
  await p.coupe(); await dort(1500);
  p = new Page(); await p.connecte();
  p.envoie({ type: 'open', agent: 'claude', sessionId: premiere });
  await p.attend(() => p.session);
  const pp = p.dernier('perm');
  R.perm_survit = { etat: pp.state, en_cours: p.session.running, options: pp.options.length };
  p.envoie({ type: 'permission', permId: pp.id, optionId: 'toujours' });
  await p.finTour();
  R.perm_survit.apres = { choix: p.dernier('perm').chosen, outil: p.dernier('tool').status, sortie: (p.dernier('tool').content[0] || {}).text, entree: p.dernier('tool').input };

  // 8. plan
  p.prompt('plan'); await p.finTour();
  R.plan = { plans: p.liste('plan').length, etats: p.dernier('plan').entries.map(e => e.status) };

  // 9. « tout accepter » : par conversation, visible, réversible
  p.envoie({ type: 'auto', value: true }); await p.attend(() => p.session.autoAccept === true);
  p.prompt('modifie'); await p.finTour();
  R.auto = { etat: p.dernier('perm').state, auto: p.dernier('perm').auto, choix: p.dernier('perm').chosen };
  p.envoie({ type: 'auto', value: false }); await p.attend(() => p.session.autoAccept === false);
  p.prompt('modifie');
  R.auto.redemande = await p.attend(() => (p.dernier('perm') || {}).state === 'pending');
  p.envoie({ type: 'cancel' }); await p.finTour();
  R.auto.arret_annule_demande = { perm: p.dernier('perm').state, fin: p.dernier('end').stopReason };

  // 10. nouvelle conversation, liste, reprise
  p.envoie({ type: 'auto', value: true }); await p.attend(() => p.session.autoAccept === true);
  p.envoie({ type: 'new' });
  await p.attend(() => p.session && p.session.sessionId !== premiere);
  R.nouvelle = { vide: p.session.items.length === 0, auto: p.session.autoAccept, mode: p.session.mode.current };
  p.prompt('seconde conversation'); await p.finTour();
  p.envoie({ type: 'list' }); await p.attend(() => p.sessions);
  R.liste = p.sessions.map(s => ({ titre: s.title, premiere: s.sessionId === premiere }));
  p.envoie({ type: 'load', sessionId: premiere });
  await p.attend(() => p.session && p.session.sessionId === premiere);
  R.reprise = { messages_utilisateur: p.liste('user').map(i => i.text), outils: p.liste('tool').length, auto: p.session.autoAccept, mode: p.session.mode.current, en_cours: p.session.running };
  p.prompt('bonjour encore'); await p.finTour();
  R.reprise.suite = p.dernier('end').stopReason;
  p.envoie({ type: 'load', sessionId: 'inconnue-00000000' });
  await p.attend(() => p.session && p.session.sessionId !== premiere);
  R.reprise.inconnue_donne_neuve = p.session.items.length === 0;

  // 11. bascule vers l'autre assistant
  p.envoie({ type: 'open', agent: 'vibe', sessionId: null });
  await p.attend(() => p.session && p.session.agent === 'vibe');
  R.bascule = { agent: p.agent.agent, label: p.agent.label, mode: p.session.mode.current };
  p.prompt('bonjour'); await p.finTour();
  R.bascule.texte = p.dernier('text').text;
  p.ws.close();
  return R;
}

(async () => {
  const [, , cmd, arg] = process.argv;
  const r = cmd === 'ouvre' ? await ouvre(arg) : await conversation();
  console.log('RESULTAT ' + JSON.stringify(r));
  process.exit(0);
})().catch(e => { console.log('RESULTAT ' + JSON.stringify({ fatal: String(e && e.stack || e) })); process.exit(1); });
