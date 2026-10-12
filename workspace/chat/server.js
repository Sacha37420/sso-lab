#!/usr/bin/env node
// ─────────────────────────────────────────────────────────────────────────────
// lab-chat — service de conversation de l'espace de travail (chantier
// « espace-chat », interfaces I1, I4, I5).
//
// Écoute sur :8090 dans le conteneur ws-<uid>, à côté de code-server. Sert une
// page de conversation pensée pour le téléphone et fait le pont entre cette
// page (WebSocket) et un agent parlant ACP v1 sur stdio :
//   claude → claude-agent-acp (qui pilote le `claude` déjà dans l'image)
//   vibe   → vibe-acp
//
// Ce que ce service NE fait PAS, par construction :
//   - il n'authentifie personne : la passerelle du lab a contrôlé chaque
//     requête ; il refuse seulement un WebSocket dont l'Origin n'est pas
//     l'hôte public (détournement depuis un autre site) ;
//   - il ne lit, n'affiche ni ne journalise aucun identifiant : il transmet
//     son environnement tel quel aux agents, sans en lire les valeurs, et ne
//     connaît l'état de connexion d'un assistant que par ce que l'agent répond ;
//   - il ne journalise aucun contenu de conversation : le journal ne porte que
//     des événements de cycle de vie (démarrage, arrêt d'un agent, erreurs
//     techniques sans texte de conversation) ;
//   - il n'accorde jamais seul une autorisation, sauf si l'utilisateur a
//     activé « tout accepter » pour LA conversation en cours (jamais par
//     défaut, jamais mémorisé).
//
// Protocole page ⇄ service : JSON sur WebSocket, décrit dans README.md.
// ─────────────────────────────────────────────────────────────────────────────
'use strict';

const http = require('http');
const fs = require('fs');
const path = require('path');
const { spawn } = require('child_process');
const { WebSocketServer } = require('ws');

const PORT = parseInt(process.env.LAB_CHAT_PORT || '8090', 10);
const APP = process.env.LAB_APP || '';
const WORK = `/work/${APP}`;
const PUBLIC = path.join(__dirname, 'public');
// Un agent sans spectateur ni tour en cours est arrêté après ce délai (mémoire de l'espace).
const AGENT_IDLE_MS = parseInt(process.env.LAB_CHAT_AGENT_IDLE_S || '300', 10) * 1000;
const MAX_ITEMS = 4000;            // éléments gardés par conversation (les plus anciens tombent)
const MAX_TEXTE = 200000;          // caractères gardés par bloc de texte ou de sortie d'outil
const MAX_PROMPT = 100000;

const log = (...a) => console.log('[lab-chat]', ...a);

// ── Agents ───────────────────────────────────────────────────────────────────
// `strict` : identifiant du mode « demander avant d'agir » de l'agent. Il est
// imposé à l'ouverture de chaque conversation, quel que soit le réglage par
// défaut de l'outil (Vibe démarre en « accept-edits ») ou de la maison du dev.
// LAB_CHAT_CMD_<AGENT> (tableau JSON) remplace la commande : réservé aux essais
// (faux agent de workspace/tests/).
function commande(nom, defaut) {
  const brut = process.env[`LAB_CHAT_CMD_${nom.toUpperCase()}`];
  if (!brut) return defaut;
  try {
    const c = JSON.parse(brut);
    if (Array.isArray(c) && c.length && c.every(x => typeof x === 'string')) return c;
  } catch { /* ignoré */ }
  log(`LAB_CHAT_CMD_${nom.toUpperCase()} illisible : commande par défaut gardée`);
  return defaut;
}
const DEFS = {
  claude: {
    label: 'Claude Code',
    cmd: commande('claude', [process.execPath,
      path.join(__dirname, 'node_modules/@agentclientprotocol/claude-agent-acp/dist/index.js')]),
    // Le paquet n'embarque pas de second binaire : il pilote le `claude` de l'image.
    env: { CLAUDE_CODE_EXECUTABLE: process.env.CLAUDE_CODE_EXECUTABLE || '/usr/local/bin/claude' },
    strict: 'default',
  },
  vibe: {
    label: 'Mistral Vibe',
    cmd: commande('vibe', ['vibe-acp']),
    env: {},
    strict: 'ask',
  },
};

// ── Activité (I1) ────────────────────────────────────────────────────────────
// Dernier instant où un client était connecté ET où quelque chose s'est passé.
// Un client connecté qui n'échange rien ne fait PAS avancer cette valeur.
let derniereActivite = 0;
const clients = new Set();
function touche() { if (clients.size > 0) derniereActivite = Date.now(); }
function tourEnCours() {
  for (const a of Object.values(agents)) for (const c of a.convs.values()) if (c.running) return true;
  return false;
}

// ── JSON-RPC sur stdio (une ligne = un message) ──────────────────────────────
class Rpc {
  constructor(proc, surRequete, surNotification) {
    this.proc = proc; this.n = 0; this.attente = new Map(); this.ferme = false;
    this.surRequete = surRequete; this.surNotification = surNotification;
    let tampon = '';
    proc.stdout.setEncoding('utf8');
    proc.stdout.on('data', d => {
      tampon += d;
      let i;
      while ((i = tampon.indexOf('\n')) >= 0) {
        const ligne = tampon.slice(0, i); tampon = tampon.slice(i + 1);
        if (ligne.trim()) this._recu(ligne);
      }
    });
  }
  _recu(ligne) {
    let m;
    try { m = JSON.parse(ligne); } catch { return; }       // bruit hors protocole : ignoré
    if (!m || typeof m !== 'object') return;
    if (m.method !== undefined && m.id !== undefined && m.id !== null) {
      Promise.resolve().then(() => this.surRequete(m.method, m.params || {}, m.id))
        .catch(() => this.erreur(m.id, -32603, 'erreur interne'));
    } else if (m.method !== undefined) {
      try { this.surNotification(m.method, m.params || {}); } catch (e) { log('notification non traitée :', m.method); }
    } else if (m.id !== undefined && this.attente.has(m.id)) {
      const a = this.attente.get(m.id); this.attente.delete(m.id);
      if (a.minuterie) clearTimeout(a.minuterie);
      if (m.error) { const e = new Error(String(m.error.message || 'erreur')); e.code = m.error.code; a.rejette(e); }
      else a.resout(m.result === undefined ? null : m.result);
    }
  }
  _ecrit(o) { if (!this.ferme && this.proc.stdin.writable) this.proc.stdin.write(JSON.stringify(o) + '\n'); }
  requete(method, params, delaiMs) {
    return new Promise((resout, rejette) => {
      if (this.ferme) return rejette(new Error('agent arrêté'));
      const id = ++this.n;
      const a = { resout, rejette, minuterie: null };
      if (delaiMs) a.minuterie = setTimeout(() => {
        this.attente.delete(id); const e = new Error(`pas de réponse à ${method}`); e.code = 'DELAI'; rejette(e);
      }, delaiMs);
      this.attente.set(id, a);
      this._ecrit({ jsonrpc: '2.0', id, method, params });
    });
  }
  notifie(method, params) { this._ecrit({ jsonrpc: '2.0', method, params }); }
  repond(id, result) { this._ecrit({ jsonrpc: '2.0', id, result }); }
  erreur(id, code, message) { this._ecrit({ jsonrpc: '2.0', id, error: { code, message } }); }
  termine() {
    this.ferme = true;
    for (const a of this.attente.values()) { if (a.minuterie) clearTimeout(a.minuterie); a.rejette(new Error('agent arrêté')); }
    this.attente.clear();
  }
}

// ── Mise en forme des contenus ACP ───────────────────────────────────────────
const coupe = (s, n = MAX_TEXTE) => (s.length > n ? s.slice(0, n) + '\n… (tronqué)' : s);
function texteDe(bloc) {
  if (!bloc || typeof bloc !== 'object') return '';
  switch (bloc.type) {
    case 'text': return typeof bloc.text === 'string' ? bloc.text : '';
    case 'image': return '[image]';
    case 'audio': return '[audio]';
    case 'resource_link': return `[${bloc.name || bloc.uri || 'ressource'}]`;
    case 'resource': return (bloc.resource && typeof bloc.resource.text === 'string') ? bloc.resource.text : '[ressource]';
    default: return '';
  }
}
function contenuOutil(liste) {
  const out = [];
  for (const c of Array.isArray(liste) ? liste : []) {
    if (!c || typeof c !== 'object') continue;
    if (c.type === 'content') { const t = texteDe(c.content); if (t) out.push({ type: 'text', text: coupe(t) }); }
    else if (c.type === 'diff') out.push({ type: 'diff', path: String(c.path || ''),
      oldText: c.oldText == null ? null : coupe(String(c.oldText)), newText: coupe(String(c.newText == null ? '' : c.newText)) });
    // 'terminal' : capacité non annoncée par ce client, jamais reçu.
  }
  return out;
}
function entreeOutil(brut) {
  if (brut == null) return '';
  if (typeof brut === 'string') return coupe(brut, 4000);
  if (typeof brut === 'object' && typeof brut.command === 'string') return coupe(brut.command, 4000);
  try { return coupe(JSON.stringify(brut, null, 1), 4000); } catch { return ''; }
}

// ── Conversation (état gardé par le service, rejoué à la reconnexion) ────────
class Conv {
  constructor(agent, sessionId) {
    this.agent = agent; this.id = sessionId;
    this.items = []; this.seq = 0;
    this.running = false; this.cancelling = false; this.loading = false;
    this.autoAccept = false;                       // jamais actif par défaut, jamais mémorisé
    this.mode = { current: null, name: null, strict: agent.def.strict, modes: [] };
    this.trust = null; this.title = null;
    this.tools = new Map(); this.pending = new Map(); this.plan = null;
    this.vueLe = Date.now();
  }
  spectateurs() { const r = []; for (const c of clients) if (c.vue === this) r.push(c); return r; }
  // `activite` : un élément de conversation émis PENDANT UN TOUR compte comme activité (I1).
  // Ne comptent pas : un changement d'état (mode, titre, réglage) ni ce qu'un agent dit de
  // lui-même hors de tout tour (Vibe annonce ainsi l'état de ses serveurs MCP à l'ouverture) —
  // sinon ouvrir la page suffirait à prolonger la vie de l'espace.
  _diffuse(msg, activite = true) { const s = JSON.stringify(msg); for (const c of this.spectateurs()) envoie(c, s); if (activite && this.running) touche(); }
  etat() {
    return { type: 'state', agent: this.agent.kind, sessionId: this.id, running: this.running, cancelling: this.cancelling,
      autoAccept: this.autoAccept, mode: { current: this.mode.current, name: this.mode.name, strict: this.mode.strict,
        strictDispo: this.mode.modes.some(m => m.id === this.mode.strict) }, trust: this.trust, title: this.title };
  }
  diffuseEtat() { this._diffuse(this.etat(), false); }
  instantane() { return { ...this.etat(), type: 'session', items: this.items }; }
  ajoute(item) {
    item.seq = ++this.seq; this.items.push(item);
    if (this.items.length > MAX_ITEMS) {
      const tombes = this.items.splice(0, this.items.length - MAX_ITEMS);
      for (const t of tombes) if (t.k === 'tool') this.tools.delete(t.id);
    }
    if (!this.loading) this._diffuse({ type: 'item', sessionId: this.id, item });
    return item;
  }
  corrige(item) { if (!this.loading) this._diffuse({ type: 'patch', sessionId: this.id, item }); }
  texte(k, t) {
    if (!t) return;
    const dernier = this.items[this.items.length - 1];
    if (dernier && dernier.k === k && !dernier.clos) {
      if (dernier.text.length < MAX_TEXTE) {
        dernier.text += t;
        if (!this.loading) this._diffuse({ type: 'append', sessionId: this.id, seq: dernier.seq, text: t });
      }
    } else this.ajoute({ k, text: t });
  }
  clos() { const d = this.items[this.items.length - 1]; if (d) d.clos = true; }
  setModes(modes) {
    if (!modes || !Array.isArray(modes.availableModes)) return;
    this.mode.modes = modes.availableModes.map(m => ({ id: String(m.id), name: String(m.name || m.id) }));
    this.setMode(modes.currentModeId);
  }
  setMode(id) {
    if (typeof id !== 'string') return;
    this.mode.current = id;
    const m = this.mode.modes.find(x => x.id === id);
    this.mode.name = m ? m.name : id;
  }
  outil(u, creation) {
    const id = String(u.toolCallId || '');
    if (!id) return null;
    let it = this.tools.get(id);
    const neuf = !it;
    if (neuf) { it = { k: 'tool', id, title: '', kind: 'other', status: 'pending', content: [], locations: [], input: '' }; }
    if (typeof u.title === 'string' && u.title) it.title = coupe(u.title, 500);
    if (typeof u.kind === 'string') it.kind = u.kind;
    if (typeof u.status === 'string') it.status = u.status;
    else if (creation && neuf) it.status = 'pending';
    if (Array.isArray(u.content)) it.content = contenuOutil(u.content);
    if (Array.isArray(u.locations)) it.locations = u.locations.map(l => String((l && l.path) || '')).filter(Boolean).slice(0, 20);
    if (u.rawInput !== undefined) it.input = entreeOutil(u.rawInput);
    if (neuf) { this.tools.set(id, it); this.ajoute(it); } else this.corrige(it);
    return it;
  }
  // Notification session/update de l'agent.
  maj(u) {
    if (!u || typeof u !== 'object') return;
    switch (u.sessionUpdate) {
      case 'agent_message_chunk': this.texte('text', texteDe(u.content)); break;
      case 'agent_thought_chunk': this.texte('thought', texteDe(u.content)); break;
      case 'user_message_chunk':
        // En direct, le message de l'utilisateur est déjà dans le fil (posé à l'envoi) :
        // l'écho de l'agent n'est gardé que pendant le rechargement d'une conversation.
        if (this.loading) this.texte('user', texteDe(u.content));
        break;
      case 'tool_call': this.outil(u, true); break;
      case 'tool_call_update': this.outil(u, false); break;
      case 'plan': {
        const entries = (Array.isArray(u.entries) ? u.entries : []).slice(0, 100).map(e => ({
          content: coupe(String((e && e.content) || ''), 1000), status: String((e && e.status) || 'pending') }));
        if (this.plan && this.items.includes(this.plan)) { this.plan.entries = entries; this.corrige(this.plan); }
        else this.plan = this.ajoute({ k: 'plan', entries });
        break;
      }
      case 'current_mode_update': this.setMode(u.currentModeId || u.modeId); if (!this.loading) this.diffuseEtat(); break;
      case 'config_option_update': {
        const o = (Array.isArray(u.configOptions) ? u.configOptions : []).find(x => x && x.id === 'mode');
        if (o && typeof o.currentValue === 'string' && o.currentValue !== this.mode.current) { this.setMode(o.currentValue); if (!this.loading) this.diffuseEtat(); }
        break;
      }
      case 'session_info_update':
        if (typeof u.title === 'string' && u.title) { this.title = coupe(u.title, 200); if (!this.loading) this.diffuseEtat(); }
        break;
      default: break;      // usage, commandes disponibles, etc. : sans objet pour l'écran
    }
  }
  // Requête session/request_permission de l'agent.
  permission(rpcId, p) {
    const tc = (p && p.toolCall) || {};
    const outil = this.outil(tc, false);
    const options = (Array.isArray(p.options) ? p.options : []).slice(0, 12).map(o => ({
      optionId: String(o.optionId), name: coupe(String(o.name || o.optionId), 200), kind: String(o.kind || '') }));
    const item = { k: 'perm', id: `p${rpcId}`, toolId: outil ? outil.id : null,
      title: (outil && outil.title) || coupe(String(tc.title || ''), 500), options, state: 'pending', chosen: null, auto: false };
    this.clos();
    if (this.autoAccept) {
      // Réglage « tout accepter » de CETTE conversation : accord pour cette fois seulement.
      const o = options.find(x => x.kind === 'allow_once') || options.find(x => x.kind === 'allow_always');
      if (o) {
        item.state = 'selected'; item.chosen = o.optionId; item.auto = true;
        this.ajoute(item);
        this.agent.rpc.repond(rpcId, { outcome: { outcome: 'selected', optionId: o.optionId } });
        return;
      }
    }
    this.pending.set(item.id, { rpcId, item });
    this.ajoute(item);
  }
  repondPermission(permId, optionId) {
    const p = this.pending.get(permId);
    if (!p) return false;
    const o = p.item.options.find(x => x.optionId === optionId);
    if (!o) return false;
    this.pending.delete(permId);
    p.item.state = 'selected'; p.item.chosen = o.optionId;
    this.agent.rpc.repond(p.rpcId, { outcome: { outcome: 'selected', optionId: o.optionId } });
    this.corrige(p.item);
    return true;
  }
  annulePermissions() {
    for (const p of this.pending.values()) {
      p.item.state = 'cancelled';
      if (this.agent.rpc && !this.agent.rpc.ferme) this.agent.rpc.repond(p.rpcId, { outcome: { outcome: 'cancelled' } });
      this.corrige(p.item);
    }
    this.pending.clear();
  }
}

// ── Agent : un processus ACP par assistant, lancé à la demande ───────────────
class Agent {
  constructor(kind) {
    this.kind = kind; this.def = DEFS[kind];
    this.state = 'stopped';          // stopped | starting | ready | error
    this.auth = 'unknown';           // unknown | ok | none — d'après les réponses de l'agent, jamais d'après un fichier
    this.detail = ''; this.info = null; this.caps = {};
    this.proc = null; this.rpc = null; this.demarrage = null;
    this.convs = new Map(); this.orphelines = new Map();
    this.inactifDepuis = Date.now();
  }
  vue() { return { type: 'agent', agent: this.kind, label: this.def.label, state: this.state, auth: this.auth, detail: this.detail, info: this.info }; }
  diffuse() { const s = JSON.stringify(this.vue()); for (const c of clients) if (c.agent === this) envoie(c, s); }
  pret() { return this.state === 'ready' && this.rpc && !this.rpc.ferme; }
  assure() {
    if (this.pret()) return Promise.resolve();
    if (!this.demarrage) this.demarrage = this._demarre().finally(() => { this.demarrage = null; });
    return this.demarrage;
  }
  async _demarre() {
    this.state = 'starting'; this.detail = ''; this.auth = 'unknown'; this.diffuse();   // l'agent relit ses identifiants au démarrage
    const [bin, ...args] = this.def.cmd;
    let proc;
    try {
      // Même environnement que le service (donc que le terminal de l'éditeur), même dossier.
      // stderr de l'agent : jeté, il peut porter du contenu de conversation.
      // detached : l'agent et ses enfants (le `claude` piloté) forment un groupe, arrêté d'un bloc.
      proc = spawn(bin, args, { cwd: WORK, env: { ...process.env, ...this.def.env }, stdio: ['pipe', 'pipe', 'ignore'], detached: true });
    } catch (e) { this.state = 'error'; this.detail = 'lancement impossible'; this.diffuse(); throw e; }
    this.proc = proc;
    const rpc = new Rpc(proc, (m, p, id) => this._requete(m, p, id), (m, p) => this._notification(m, p));
    this.rpc = rpc;
    proc.stdin.on('error', () => {});
    proc.on('error', () => this._fin(proc, 'lancement impossible'));
    proc.on('exit', (code, sig) => { log(`agent ${this.kind} terminé (pid ${proc.pid}, code ${code}, signal ${sig})`); this._fin(proc, 'arrêté'); });
    log(`agent ${this.kind} lancé (pid ${proc.pid})`);
    try {
      const r = await rpc.requete('initialize', {
        protocolVersion: 1,
        clientCapabilities: { fs: { readTextFile: false, writeTextFile: false }, terminal: false },
        clientInfo: { name: 'lab-chat', title: 'Lab — conversation', version: '1.0.0' },
      }, 90000);
      if (!r || r.protocolVersion !== 1) throw new Error('version de protocole ACP inattendue');
      this.caps = r.agentCapabilities || {};
      this.info = r.agentInfo ? { name: String(r.agentInfo.name || ''), title: String(r.agentInfo.title || ''), version: String(r.agentInfo.version || '') } : null;
      this.state = 'ready'; this.inactifDepuis = Date.now(); this.diffuse();
    } catch (e) {
      if (this.proc === proc) { this.state = 'error'; this.detail = e.code === 'DELAI' ? "l'assistant ne répond pas" : "l'assistant n'a pas démarré"; this.diffuse(); }
      this._tue(proc);
      throw e;
    }
  }
  _fin(proc, detail) {
    if (this.proc !== proc) return;
    this.proc = null; if (this.rpc) this.rpc.termine(); this.rpc = null;
    const etait = this.state;
    this.state = (etait === 'starting' || etait === 'error') ? 'error' : 'stopped';
    if (this.state === 'error' && !this.detail) this.detail = "l'assistant n'a pas démarré";
    for (const c of this.convs.values()) {
      c.pending.clear();
      for (const it of c.items) if (it.k === 'perm' && it.state === 'pending') { it.state = 'cancelled'; c.corrige(it); }
      c.morte = true;
    }
    this.orphelines.clear();
    this.diffuse();
  }
  // Arrêt : l'agent est tenu pour arrêté tout de suite (une relance ne réutilise jamais un
  // processus en train de mourir — vibe-acp met plusieurs secondes à rendre la main).
  arrete() { const p = this.proc; if (!p) return; this._fin(p, 'arrêté'); this._tue(p); }
  _tue(p) {
    const signale = s => { try { process.kill(-p.pid, s); } catch { try { p.kill(s); } catch { /* déjà mort */ } } };
    try { p.stdin.end(); } catch { /* déjà fermé */ }
    signale('SIGTERM');
    setTimeout(() => { if (p.exitCode === null && p.signalCode === null) signale('SIGKILL'); }, 5000).unref();
  }
  _notification(method, p) {
    if (method === 'session/update') {
      const c = this.convs.get(p.sessionId);
      if (c) c.maj(p.update);
      else if (typeof p.sessionId === 'string') {        // arrivée avant la réponse à session/new
        const f = this.orphelines.get(p.sessionId) || [];
        if (f.length < 500) f.push(p.update);
        this.orphelines.set(p.sessionId, f);
        if (this.orphelines.size > 20) this.orphelines.delete(this.orphelines.keys().next().value);
      }
    } else if (method === '_auth/status_update') {
      // Extension de claude-agent-acp : seul le genre est gardé (jamais le libellé du compte).
      const genre = p && p.authStatus && p.authStatus.kind;
      this.setAuth(genre === 'none' ? 'none' : 'ok');
    }
  }
  setAuth(a) { if (this.auth !== a) { this.auth = a; this.diffuse(); } }
  _requete(method, p, id) {
    if (method === 'session/request_permission') {
      const c = this.convs.get(p.sessionId);
      if (!c) return this.rpc.repond(id, { outcome: { outcome: 'cancelled' } });
      return c.permission(id, p);
    }
    // fs/*, terminal/*, elicitation… : capacités non annoncées.
    this.rpc.erreur(id, -32601, 'méthode non prise en charge par ce client');
  }
  // Impose le mode « demander avant d'agir ». Échec fermé : une conversation dont on ne
  // peut pas garantir le mode n'est pas ouverte.
  async _imposeStrict(conv, modes) {
    conv.setModes(modes);
    if (!conv.mode.modes.length) return;                      // agent sans modes : rien à imposer
    if (conv.mode.current === conv.mode.strict) return;
    if (!conv.mode.modes.some(m => m.id === conv.mode.strict)) {
      throw Object.assign(new Error(`le mode « ${conv.mode.strict} » (demander avant d'agir) est introuvable chez cet assistant`), { code: 'MODE' });
    }
    await this.rpc.requete('session/set_mode', { sessionId: conv.id, modeId: conv.mode.strict }, 30000);
    conv.setMode(conv.mode.strict);
  }
  _confiance(conv, meta) {
    const t = meta && meta.workspace_trust;          // extension de Vibe
    conv.trust = t && typeof t.status === 'string' ? t.status : null;
  }
  async nouvelle() {
    await this.assure();
    let r;
    try { r = await this.rpc.requete('session/new', { cwd: WORK, mcpServers: [] }, 120000); }
    catch (e) { if (e.code === -32000) this.setAuth('none'); throw e; }
    const conv = new Conv(this, String(r.sessionId));
    this.convs.set(conv.id, conv);
    try { await this._imposeStrict(conv, r.modes); }
    catch (e) { this.convs.delete(conv.id); this._ferme(conv); throw e; }
    this._confiance(conv, r._meta);
    for (const u of this.orphelines.get(conv.id) || []) conv.maj(u);
    this.orphelines.delete(conv.id);
    if (this.auth === 'unknown') this.setAuth('ok');
    return conv;
  }
  async liste() {
    await this.assure();
    if (!(this.caps.sessionCapabilities && this.caps.sessionCapabilities.list)) return [];
    const out = []; let cursor;
    for (let page = 0; page < 20; page++) {
      const r = await this.rpc.requete('session/list', cursor ? { cwd: WORK, cursor } : { cwd: WORK }, 30000);
      for (const s of (r && r.sessions) || []) {
        if (s && typeof s.sessionId === 'string' && (!s.cwd || s.cwd === WORK)) {
          out.push({ sessionId: s.sessionId, title: s.title ? coupe(String(s.title), 200) : '', updatedAt: s.updatedAt || null });
        }
      }
      cursor = r && r.nextCursor; if (!cursor) break;
    }
    out.sort((a, b) => String(b.updatedAt || '').localeCompare(String(a.updatedAt || '')));
    return out;
  }
  async charge(sessionId) {
    await this.assure();
    const vivante = this.convs.get(sessionId);
    if (vivante && !vivante.morte) return vivante;
    if (!this.caps.loadSession) throw new Error('cet assistant ne sait pas reprendre une conversation');
    // Seules les conversations de CE projet se reprennent.
    if (!(await this.liste()).some(s => s.sessionId === sessionId)) throw Object.assign(new Error('conversation introuvable pour ce projet'), { code: 'INCONNUE' });
    const conv = new Conv(this, sessionId);
    conv.loading = true;
    this.convs.set(sessionId, conv);
    try {
      const r = await this.rpc.requete('session/load', { sessionId, cwd: WORK, mcpServers: [] }, 180000);
      await this._imposeStrict(conv, r && r.modes);
      this._confiance(conv, r && r._meta);
    } catch (e) {
      if (this.convs.get(sessionId) === conv) this.convs.delete(sessionId);
      if (e.code === -32000) this.setAuth('none');
      throw e;
    }
    conv.loading = false; conv.clos();
    for (const it of conv.items) if (it.k === 'tool' && (it.status === 'pending' || it.status === 'in_progress')) it.status = 'completed';
    if (this.auth === 'unknown') this.setAuth('ok');
    return conv;
  }
  _ferme(conv) {
    if (this.pret() && this.caps.sessionCapabilities && this.caps.sessionCapabilities.close) {
      this.rpc.requete('session/close', { sessionId: conv.id }, 15000).catch(() => {});
    }
  }
  // Une seule conversation au repos par agent : les autres sont rendues à l'agent.
  menage(garder) {
    for (const c of [...this.convs.values()]) {
      if (c === garder || c.running || c.loading || c.spectateurs().length) continue;
      this.convs.delete(c.id);
      if (!c.morte) this._ferme(c);
    }
  }
  envoiePrompt(conv, text) {
    if (conv.running || conv.morte) return false;
    conv.running = true; conv.cancelling = false; conv.plan = null;
    conv.clos(); conv.ajoute({ k: 'user', text }); conv.clos();
    if (!conv.title) conv.title = coupe(text.split('\n')[0], 80);
    conv.diffuseEtat();
    this.rpc.requete('session/prompt', { sessionId: conv.id, prompt: [{ type: 'text', text }] }, 0)
      .then(r => { conv.clos(); conv.ajoute({ k: 'end', stopReason: String((r && r.stopReason) || 'end_turn') }); this.setAuth('ok'); })
      .catch(e => {
        conv.clos();
        if (e.code === -32000) { this.setAuth('none'); conv.ajoute({ k: 'error', code: 'auth', text: '' }); }
        else conv.ajoute({ k: 'error', code: 'agent', text: coupe(String(e.message || 'erreur'), 1000) });
      })
      .finally(() => {
        conv.running = false; conv.cancelling = false;
        conv.annulePermissions();
        for (const it of conv.tools.values()) if (it.status === 'pending' || it.status === 'in_progress') { it.status = 'failed'; conv.corrige(it); }
        conv.diffuseEtat();
        this.inactifDepuis = Date.now();
      });
    return true;
  }
  annule(conv) {
    if (!conv.running || conv.morte || !this.pret()) return;
    conv.cancelling = true;
    this.rpc.notifie('session/cancel', { sessionId: conv.id });
    conv.annulePermissions();          // ACP : toute demande en attente reçoit « cancelled »
    conv.diffuseEtat();
  }
}
const agents = { claude: new Agent('claude'), vibe: new Agent('vibe') };
let dernierAgent = null;

// Arrêt des agents sans spectateur ni tour en cours (rend la mémoire à l'espace).
setInterval(() => {
  const now = Date.now();
  for (const a of Object.values(agents)) {
    const occupe = [...clients].some(c => c.agent === a) || [...a.convs.values()].some(c => c.running || c.loading) || a.demarrage;
    if (occupe) { a.inactifDepuis = now; continue; }
    if (a.proc && now - a.inactifDepuis > AGENT_IDLE_MS) { log(`agent ${a.kind} : inactif, arrêté`); a.arrete(); a.convs.clear(); }
  }
}, 15000).unref();

// ── Page ⇄ service ───────────────────────────────────────────────────────────
function envoie(c, s) { if (c.ws.readyState === 1) c.ws.send(typeof s === 'string' ? s : JSON.stringify(s)); }
function erreurClient(c, e, quoi) {
  const m = { type: 'error', what: quoi, code: typeof e.code === 'string' ? e.code : (e.code === -32000 ? 'auth' : 'agent'),
    message: e.code === -32000 ? '' : coupe(String(e.message || 'erreur'), 500) };
  envoie(c, m);
}
function montre(c, conv) {
  c.vue = conv; conv.vueLe = Date.now();
  envoie(c, conv.instantane());
  conv.agent.menage(conv);
}
// File par client : une action longue (démarrage d'agent, rechargement) à la fois.
function enFile(c, f) { c.file = c.file.then(f).catch(() => {}); }

async function ouvre(c, kind, sessionId, creer) {
  const a = agents[kind] || agents.claude;
  c.agent = a; c.vue = null; dernierAgent = a.kind;
  envoie(c, a.vue());
  try {
    let conv = null;
    if (sessionId) {
      try { conv = await a.charge(sessionId); }
      catch (e) { if (e.code !== 'INCONNUE') throw e; }     // conversation disparue : on en ouvre une neuve
    }
    if (!conv && !creer) {
      // Reprise par défaut : la conversation vivante la plus récemment regardée de cet agent.
      conv = [...a.convs.values()].filter(x => !x.morte && !x.loading).sort((x, y) => y.vueLe - x.vueLe)[0] || null;
    }
    if (!conv) conv = await a.nouvelle();
    if (c.agent !== a) return;                               // l'utilisateur a changé d'assistant entre-temps
    montre(c, conv);
  } catch (e) {
    if (c.agent === a) { envoie(c, a.vue()); erreurClient(c, e, 'open'); }
  }
}

async function recoit(c, m) {
  const a = c.agent, conv = c.vue;
  switch (m.type) {
    case 'open':       // (ré)attachement automatique de la page : ne compte PAS comme activité
      return enFile(c, () => ouvre(c, String(m.agent || ''), typeof m.sessionId === 'string' ? m.sessionId : null, false));
    case 'new': touche(); return enFile(c, () => ouvre(c, a ? a.kind : 'claude', null, true));
    case 'load': touche(); if (typeof m.sessionId !== 'string') return; return enFile(c, () => ouvre(c, a ? a.kind : 'claude', m.sessionId, true));
    case 'retry':      // après une connexion faite dans le terminal : l'agent relit ses identifiants au démarrage
      touche();
      if (!a) return;
      return enFile(c, async () => {
        if (!a.demarrage) { for (const x of a.convs.values()) if (x.running) return; a.arrete(); a.convs.clear(); a.auth = 'unknown'; }
        return ouvre(c, a.kind, null, true);
      });
    case 'list':
      if (!a) return;
      try { envoie(c, { type: 'sessions', agent: a.kind, sessions: (await a.liste()).map(s => ({ ...s, live: a.convs.has(s.sessionId), running: !!(a.convs.get(s.sessionId) || {}).running })) }); }
      catch (e) { erreurClient(c, e, 'list'); }
      return;
    case 'prompt': {
      touche();
      const text = typeof m.text === 'string' ? m.text.trim() : '';
      if (!conv || !text || text.length > MAX_PROMPT) return;
      if (conv.morte) return envoie(c, { type: 'error', what: 'prompt', code: 'morte', message: '' });
      if (!a.envoiePrompt(conv, text)) envoie(c, { type: 'error', what: 'prompt', code: 'occupe', message: '' });
      return;
    }
    case 'cancel': touche(); if (conv) a.annule(conv); return;
    case 'permission': touche(); if (conv) conv.repondPermission(String(m.permId), String(m.optionId)); return;
    case 'auto': touche(); if (conv) { conv.autoAccept = m.value === true; conv.diffuseEtat(); } return;
    case 'mode_strict':
      touche();
      if (!conv || conv.morte || !a.pret()) return;
      try { await a.rpc.requete('session/set_mode', { sessionId: conv.id, modeId: conv.mode.strict }, 30000); conv.setMode(conv.mode.strict); conv.diffuseEtat(); }
      catch (e) { erreurClient(c, e, 'mode'); }
      return;
    case 'trust':      // Vibe : faire confiance au dossier du projet (il lit alors son AGENTS.md)
      touche();
      if (!conv || conv.morte || !a.pret() || a.kind !== 'vibe') return;
      try {
        const r = await a.rpc.requete('_trust/decision', { sessionId: conv.id, decision: m.decision === 'decline' ? 'decline' : 'trust_cwd', cwd: WORK }, 30000);
        conv.trust = r && typeof r.trust_status === 'string' ? r.trust_status : conv.trust; conv.diffuseEtat();
      } catch (e) { erreurClient(c, e, 'trust'); }
      return;
    default: return;
  }
}

// ── HTTP ─────────────────────────────────────────────────────────────────────
const TYPES = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8', '.css': 'text/css; charset=utf-8' };
const FICHIERS = { '/': 'index.html', '/index.html': 'index.html', '/app.js': 'app.js', '/style.css': 'style.css' };
const SECU = {
  'Content-Security-Policy': "default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self' data:; base-uri 'none'; form-action 'none'; frame-ancestors 'none'",
  'X-Content-Type-Options': 'nosniff', 'Referrer-Policy': 'no-referrer', 'Cache-Control': 'no-store',
};
function json(res, code, o) { res.writeHead(code, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' }); res.end(JSON.stringify(o)); }

const serveur = http.createServer((req, res) => {
  let chemin;
  try { chemin = new URL(req.url, 'http://x').pathname; } catch { res.writeHead(400); return res.end(); }
  if (req.method !== 'GET' && req.method !== 'HEAD') { res.writeHead(405, { Allow: 'GET, HEAD' }); return res.end(); }
  if (chemin === '/healthz') return json(res, 200, { ok: true });
  if (chemin === '/activity') {
    if (clients.size > 0 && tourEnCours()) derniereActivite = Date.now();   // un tour en cours = activité continue
    return json(res, 200, { last_activity_ms: derniereActivite });
  }
  const f = FICHIERS[chemin];
  if (!f) { res.writeHead(404, { 'Content-Type': 'text/plain; charset=utf-8' }); return res.end('introuvable\n'); }
  fs.readFile(path.join(PUBLIC, f), (e, data) => {
    if (e) { res.writeHead(500); return res.end(); }
    res.writeHead(200, { 'Content-Type': TYPES[path.extname(f)], ...SECU });
    res.end(req.method === 'HEAD' ? undefined : data);
  });
});

// Refus de toute poignée de main dont l'Origin ne désigne pas l'hôte public
// (X-Forwarded-Host posé par la passerelle, à défaut Host).
function origineAdmise(req) {
  const o = req.headers.origin;
  if (!o) return false;
  let hote;
  try { hote = new URL(o).host.toLowerCase(); } catch { return false; }
  const xf = String(req.headers['x-forwarded-host'] || '').split(',')[0].trim().toLowerCase();
  const attendu = xf || String(req.headers.host || '').toLowerCase();
  return !!attendu && hote === attendu;
}

const wss = new WebSocketServer({ noServer: true, maxPayload: 1024 * 1024 });
serveur.on('upgrade', (req, socket, head) => {
  let chemin = '';
  try { chemin = new URL(req.url, 'http://x').pathname; } catch { /* refusé plus bas */ }
  if (chemin !== '/ws') { socket.end('HTTP/1.1 404 Not Found\r\nConnection: close\r\n\r\n'); return; }
  if (!origineAdmise(req)) { socket.end('HTTP/1.1 403 Forbidden\r\nConnection: close\r\nContent-Length: 0\r\n\r\n'); return; }
  wss.handleUpgrade(req, socket, head, ws => {
    const c = { ws, agent: null, vue: null, file: Promise.resolve(), vivant: true };
    clients.add(c);
    envoie(c, { type: 'hello', app: APP, work: WORK, lastAgent: dernierAgent,
      agents: Object.fromEntries(Object.entries(DEFS).map(([k, d]) => [k, { label: d.label }])) });
    ws.on('pong', () => { c.vivant = true; });
    ws.on('message', (data, binaire) => {
      if (binaire) return;
      let m; try { m = JSON.parse(data.toString('utf8')); } catch { return; }
      if (!m || typeof m !== 'object' || typeof m.type !== 'string') return;
      recoit(c, m).catch(() => envoie(c, { type: 'error', what: m.type, code: 'interne', message: '' }));
    });
    ws.on('close', () => {
      if (tourEnCours()) derniereActivite = Date.now();       // jusqu'à cet instant, un client suivait le tour
      clients.delete(c); c.vue = null; c.agent = null;
    });
    ws.on('error', () => {});
  });
});
// Battement technique (ping WebSocket) : détecte les connexions mortes, ne compte pas comme activité.
setInterval(() => {
  for (const c of clients) {
    if (!c.vivant) { c.ws.terminate(); continue; }
    c.vivant = false; try { c.ws.ping(); } catch { /* fermé */ }
  }
}, 25000).unref();

function fin() {
  for (const a of Object.values(agents)) a.arrete();
  serveur.close(); for (const c of clients) c.ws.terminate();
  setTimeout(() => process.exit(0), 300).unref();
}
process.on('SIGTERM', fin); process.on('SIGINT', fin);
process.on('uncaughtException', e => { log('arrêt sur erreur interne :', e && e.name); for (const a of Object.values(agents)) a.arrete(); process.exit(1); });

serveur.listen(PORT, '0.0.0.0', () => log(`à l'écoute sur :${PORT}, projet ${WORK}`));
