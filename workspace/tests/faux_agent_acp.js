#!/usr/bin/env node
// Faux agent ACP v1 (stdio, une ligne JSON par message) pour verify.sh et tests/chat_navigateur.js.
// Aucune dépendance, aucun réseau, aucun identifiant : il JOUE un assistant pour éprouver le
// service de conversation (workspace/chat/server.js) de bout en bout.
//
//   node faux_agent_acp.js claude|vibe
//
// Ce qu'il imite des vrais agents (constaté sur claude-agent-acp 0.81.2 et vibe-acp 2.26.1) :
//   - modes de session : il DÉMARRE dans un mode permissif (« accept-edits », comme Vibe), où il
//     modifie un fichier SANS demander. Le service doit le ramener au mode strict
//     (« default » pour claude, « ask » pour vibe) : c'est ce que prouve le scénario « modifie ».
//   - sans identifiants : claude → session ouverte, notification `_auth/status_update {kind:none}`,
//     puis -32000 à chaque message ; vibe → -32000 dès `session/new`.
//     Déclenché par la présence du fichier $FAUX_AGENT_DIR/sans-identifiants.
//   - conversations gardées sur disque ($FAUX_AGENT_DIR/<genre>/<id>.json) : `session/list` et
//     `session/load` (qui rejoue l'historique) fonctionnent après un redémarrage de l'agent.
//
// Scénarios, d'après le texte du message :
//   « outil »    appel d'outil de lecture (pending → in_progress → completed), puis du texte
//   « modifie »  modification de fichier : diff, demande d'autorisation, écriture réelle de
//                <cwd>/essai-chat.txt si elle est accordée
//   « commande » exécution : demande d'autorisation avec trois options
//   « plan »     plan en trois étapes qui avance
//   « long »     40 morceaux de texte, un toutes les 250 ms (arrêt, coupure réseau)
//   autre        réponse en Markdown, au fil de l'eau
//
// Journal ($FAUX_AGENT_DIR/journal.log) : ce que l'agent a reçu, sans contenu de conversation —
// `env …` (présence des variables de l'espace, jamais leur valeur), `new`, `load`, `set_mode <id>`,
// `permission <issue>`, `cancel`, `prompt mode=<id>`.
'use strict';
const fs = require('fs');
const path = require('path');

const GENRE = process.argv[2] === 'vibe' ? 'vibe' : 'claude';
const RACINE = process.env.FAUX_AGENT_DIR || '/tmp/faux-agent';
const DIR = path.join(RACINE, GENRE);
fs.mkdirSync(DIR, { recursive: true });
const MODES = GENRE === 'vibe'
  ? [{ id: 'ask', name: 'Ask' }, { id: 'accept-edits', name: 'Accept Edits' }, { id: 'auto-approve', name: 'Auto Approve' }]
  : [{ id: 'default', name: 'Manual' }, { id: 'acceptEdits', name: 'Accept edits' }, { id: 'bypassPermissions', name: 'Bypass permissions' }];
const PERMISSIF = MODES[1].id;
const journal = l => fs.appendFileSync(path.join(RACINE, 'journal.log'), `${GENRE} ${l}\n`);
const sansIdentifiants = () => fs.existsSync(path.join(RACINE, 'sans-identifiants'));
const dort = ms => new Promise(r => setTimeout(r, ms));

journal(`env cwd=${process.cwd()} LAB_APP=${process.env.LAB_APP || ''} LAB_UID=${process.env.LAB_UID || ''} ` +
  `jeton_mcp=${process.env.LAB_MCP_TOKEN ? 'present' : 'absent'} claude_exe=${process.env.CLAUDE_CODE_EXECUTABLE || ''}`);

// ── JSON-RPC ──────────────────────────────────────────────────────────────
let n = 0; const attente = new Map();
const ecrit = o => process.stdout.write(JSON.stringify(o) + '\n');
const notifie = (method, params) => ecrit({ jsonrpc: '2.0', method, params });
const requete = (method, params) => new Promise(r => { const id = `a${++n}`; attente.set(id, r); ecrit({ jsonrpc: '2.0', id, method, params }); });
const maj = (s, update) => { notifie('session/update', { sessionId: s.sessionId, update }); if (!s.rejeu) s.history.push(update); };
const texte = t => ({ type: 'text', text: t });

// ── Conversations ─────────────────────────────────────────────────────────
const vives = new Map();
const fichier = id => path.join(DIR, `${id}.json`);
const sauve = s => { if (s.history.length) fs.writeFileSync(fichier(s.sessionId), JSON.stringify({ sessionId: s.sessionId, cwd: s.cwd, title: s.title, updatedAt: s.updatedAt, history: s.history })); };
const modes = s => ({ currentModeId: s.mode, availableModes: MODES });
function neuve(id, cwd) { const s = { sessionId: id, cwd, title: null, updatedAt: null, history: [], mode: PERMISSIF, annule: false, rejeu: false, k: 0 }; vives.set(id, s); return s; }

async function demande(s, toolCallId, options) {
  const r = await requete('session/request_permission', { sessionId: s.sessionId, toolCall: { toolCallId }, options });
  const o = (r && r.outcome) || {};
  const choisie = options.find(x => x.optionId === o.optionId);
  journal(`permission ${o.outcome}${choisie ? ' ' + choisie.kind : ''}`);
  return o.outcome === 'selected' && choisie ? choisie.kind : 'cancelled';
}

async function tour(s, t) {
  const dire = async (morceaux, ms = 60) => { for (const m of morceaux) { if (s.annule) return false; maj(s, { sessionUpdate: 'agent_message_chunk', content: texte(m) }); await dort(ms); } return !s.annule; };
  const id = `outil-${s.sessionId.slice(0, 6)}-${++s.k}`;
  maj(s, { sessionUpdate: 'agent_thought_chunk', content: texte('Je regarde la demande. ') });
  if (/\blong\b/i.test(t)) {
    const ok = await dire(Array.from({ length: 40 }, (_, i) => `morceau ${i + 1} `), 250);
    return ok ? 'end_turn' : 'cancelled';
  }
  if (/\bplan\b/i.test(t)) {
    const e = ['Lire la feuille de route', 'Écrire le lot', 'Lancer les tests'].map(c => ({ content: c, priority: 'medium', status: 'pending' }));
    for (let i = 0; i <= e.length; i++) {
      if (i > 0) e[i - 1].status = 'completed';
      if (i < e.length) e[i].status = 'in_progress';
      maj(s, { sessionUpdate: 'plan', entries: e.map(x => ({ ...x })) });
      await dort(150);
    }
    await dire(['Plan déroulé.']);
    return 'end_turn';
  }
  if (/\boutil\b/i.test(t)) {
    maj(s, { sessionUpdate: 'tool_call', toolCallId: id, title: 'Lire FEUILLE_DE_ROUTE.md', kind: 'read', status: 'pending', locations: [{ path: `${s.cwd}/FEUILLE_DE_ROUTE.md` }], rawInput: { path: 'FEUILLE_DE_ROUTE.md' } });
    await dort(150);
    maj(s, { sessionUpdate: 'tool_call_update', toolCallId: id, status: 'in_progress' });
    await dort(300);
    maj(s, { sessionUpdate: 'tool_call_update', toolCallId: id, status: 'completed', content: [{ type: 'content', content: texte('# Feuille de route\n\n## Lot 1 — socle\n') }] });
    await dire(['La feuille de route ', 'contient **un lot**.']);
    return s.annule ? 'cancelled' : 'end_turn';
  }
  if (/\bmodifie\b/i.test(t)) {
    const cible = path.join(s.cwd, 'essai-chat.txt');
    const ancien = fs.existsSync(cible) ? fs.readFileSync(cible, 'utf8') : null;
    const nouveau = (ancien || 'ligne 1\nligne 2\n') + `ajout du faux agent (${GENRE})\n`;
    maj(s, { sessionUpdate: 'tool_call', toolCallId: id, title: 'Modifier essai-chat.txt', kind: 'edit', status: 'pending',
      locations: [{ path: cible }], content: [{ type: 'diff', path: cible, oldText: ancien, newText: nouveau }] });
    let issue = 'allow_once';
    if (s.mode !== PERMISSIF && s.mode !== MODES[2].id) {       // mode strict : il demande
      issue = await demande(s, id, [
        { optionId: 'oui', name: 'Allow', kind: 'allow_once' },
        { optionId: 'toujours', name: 'Always allow edits', kind: 'allow_always' },
        { optionId: 'non', name: 'Reject', kind: 'reject_once' }]);
    } else journal('modification SANS demande (mode permissif)');
    if (issue === 'cancelled') { maj(s, { sessionUpdate: 'tool_call_update', toolCallId: id, status: 'failed' }); return 'cancelled'; }
    if (issue.startsWith('reject')) {
      maj(s, { sessionUpdate: 'tool_call_update', toolCallId: id, status: 'failed' });
      await dire(['Modification refusée : ', 'je ne touche pas au fichier.']);
      return 'end_turn';
    }
    fs.writeFileSync(cible, nouveau);
    maj(s, { sessionUpdate: 'tool_call_update', toolCallId: id, status: 'completed' });
    await dire(['Fichier modifié : ', '`essai-chat.txt`.']);
    return 'end_turn';
  }
  if (/\bcommande\b/i.test(t)) {
    maj(s, { sessionUpdate: 'tool_call', toolCallId: id, title: 'git status --short', kind: 'execute', status: 'pending', rawInput: { command: 'git status --short' } });
    const issue = await demande(s, id, [
      { optionId: 'oui', name: 'Allow', kind: 'allow_once' },
      { optionId: 'toujours', name: 'Always allow git status', kind: 'allow_always' },
      { optionId: 'non', name: 'Reject', kind: 'reject_once' }]);
    if (issue === 'cancelled') { maj(s, { sessionUpdate: 'tool_call_update', toolCallId: id, status: 'failed' }); return 'cancelled'; }
    if (issue.startsWith('reject')) { maj(s, { sessionUpdate: 'tool_call_update', toolCallId: id, status: 'failed' }); await dire(['Commande refusée.']); return 'end_turn'; }
    maj(s, { sessionUpdate: 'tool_call_update', toolCallId: id, status: 'completed', content: [{ type: 'content', content: texte(' M essai-chat.txt\n') }] });
    await dire(['Commande lancée.']);
    return 'end_turn';
  }
  await dire(['Bonjour ! ', `Je suis le faux agent **${GENRE}**, `, 'dans `' + s.cwd + '`.\n\n', '- un point\n', '- un autre\n\n', '```python\n', 'print("bonjour")\n', '```\n', 'Voilà.']);
  return s.annule ? 'cancelled' : 'end_turn';
}

const METHODES = {
  async initialize() {
    return { protocolVersion: 1, agentInfo: { name: `faux-agent-${GENRE}`, title: 'Faux agent', version: '0' },
      agentCapabilities: { loadSession: true, promptCapabilities: {}, sessionCapabilities: { list: {}, close: {} } }, authMethods: [] };
  },
  async 'session/new'(p) {
    if (GENRE === 'vibe' && sansIdentifiants()) throw { code: -32000, message: 'Missing API key for mistral provider.' };
    const s = neuve(require('crypto').randomUUID(), p.cwd);
    journal(`new cwd=${p.cwd} mcpServers=${(p.mcpServers || []).length}`);
    if (sansIdentifiants()) notifie('_auth/status_update', { authStatus: { kind: 'none', label: 'Not logged in' } });
    return { sessionId: s.sessionId, modes: modes(s) };
  },
  async 'session/load'(p) {
    if (!fs.existsSync(fichier(p.sessionId))) throw { code: -32002, message: 'Resource not found' };
    const d = JSON.parse(fs.readFileSync(fichier(p.sessionId), 'utf8'));
    const s = neuve(d.sessionId, p.cwd); Object.assign(s, { title: d.title, updatedAt: d.updatedAt, history: d.history });
    journal(`load ${s.history.length} mises à jour`);
    s.rejeu = true; for (const u of s.history) maj(s, u); s.rejeu = false;
    return { modes: modes(s) };
  },
  async 'session/list'(p) {
    const sessions = fs.readdirSync(DIR).filter(f => f.endsWith('.json')).map(f => JSON.parse(fs.readFileSync(path.join(DIR, f), 'utf8')))
      .filter(d => !p.cwd || d.cwd === p.cwd).map(d => ({ sessionId: d.sessionId, cwd: d.cwd, title: d.title, updatedAt: d.updatedAt }));
    return { sessions };
  },
  async 'session/set_mode'(p) {
    const s = vives.get(p.sessionId); if (!s) throw { code: -32602, message: 'session inconnue' };
    if (!MODES.some(m => m.id === p.modeId)) throw { code: -32602, message: 'mode inconnu' };
    s.mode = p.modeId; journal(`set_mode ${p.modeId}`);
    notifie('session/update', { sessionId: s.sessionId, update: { sessionUpdate: 'current_mode_update', currentModeId: s.mode } });
    return {};
  },
  async 'session/close'(p) { vives.delete(p.sessionId); journal('close'); return {}; },
  async 'session/prompt'(p) {
    const s = vives.get(p.sessionId); if (!s) throw { code: -32602, message: 'session inconnue' };
    if (sansIdentifiants()) throw { code: -32000, message: 'Authentication required' };
    const t = (p.prompt || []).map(b => b.text || '').join('');
    journal(`prompt mode=${s.mode}`);
    s.annule = false;
    s.history.push({ sessionUpdate: 'user_message_chunk', content: texte(t) });
    if (!s.title) { s.title = t.slice(0, 60); }
    s.updatedAt = new Date().toISOString();
    notifie('session/update', { sessionId: s.sessionId, update: { sessionUpdate: 'session_info_update', title: s.title, updatedAt: s.updatedAt } });
    const stopReason = await tour(s, t);
    s.updatedAt = new Date().toISOString(); sauve(s);
    return { stopReason };
  },
};

let tampon = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', d => {
  tampon += d; let i;
  while ((i = tampon.indexOf('\n')) >= 0) {
    const l = tampon.slice(0, i); tampon = tampon.slice(i + 1);
    if (!l.trim()) continue;
    let m; try { m = JSON.parse(l); } catch { continue; }
    if (m.method === undefined) { const r = attente.get(m.id); if (r) { attente.delete(m.id); r(m.result || null); } continue; }
    if (m.id === undefined) {                        // notification
      if (m.method === 'session/cancel') { const s = vives.get(m.params.sessionId); if (s) s.annule = true; journal('cancel'); }
      continue;
    }
    const f = METHODES[m.method];
    if (!f) { ecrit({ jsonrpc: '2.0', id: m.id, error: { code: -32601, message: 'Method not found' } }); continue; }
    f(m.params || {}).then(result => ecrit({ jsonrpc: '2.0', id: m.id, result }),
      e => ecrit({ jsonrpc: '2.0', id: m.id, error: { code: e.code || -32603, message: e.message || 'erreur' } }));
  }
});
process.stdin.on('end', () => process.exit(0));
