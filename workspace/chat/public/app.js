// lab-chat — page de conversation de l'espace de travail (JavaScript simple, aucune dépendance).
// Tout texte venu de l'assistant est posé par textContent / createElement : jamais d'innerHTML.
(() => {
  'use strict';
  const $ = id => document.getElementById(id);
  const el = (tag, cls, texte) => { const e = document.createElement(tag); if (cls) e.className = cls; if (texte != null) e.textContent = texte; return e; };

  const AGENTS = ['claude', 'vibe'];
  const AIDE = {
    claude: {
      titre: "Claude Code n'est pas connecté dans cet espace",
      etapes: ["Ouvrez l'éditeur du projet (bouton ci-dessous).",
        'Dans son terminal, lancez « claude », puis « /login », et suivez les instructions.',
        'Revenez sur cette page et touchez « Réessayer ».'],
    },
    vibe: {
      titre: "Mistral Vibe n'a pas de clé d'API dans cet espace",
      etapes: ["Ouvrez l'éditeur du projet (bouton ci-dessous).",
        'Dans son terminal, lancez « vibe --setup » et donnez-lui votre clé d\'API Mistral.',
        'Revenez sur cette page et touchez « Réessayer ».'],
    },
  };
  const ETATS_OUTIL = { pending: 'en attente', in_progress: 'en cours', completed: 'terminé', failed: 'échec' };
  const GENRES = { read: 'Lecture', edit: 'Modification', delete: 'Suppression', move: 'Déplacement', search: 'Recherche',
    execute: 'Commande', think: 'Réflexion', fetch: 'Web', switch_mode: 'Mode', other: 'Outil' };
  const FINS = { cancelled: 'Tour arrêté.', max_tokens: 'Arrêt : limite de longueur atteinte.',
    max_turn_requests: "Arrêt : nombre maximal d'étapes atteint.", refusal: "L'assistant a refusé de répondre." };

  // ── État ────────────────────────────────────────────────────────────────
  const S = {
    ws: null, connecte: false, essais: 0, minuterie: null,
    app: '', labels: { claude: 'Claude Code', vibe: 'Mistral Vibe' },
    agent: null, agentVue: null,        // agentVue : dernier message « agent » reçu
    session: null,                      // { sessionId, running, autoAccept, mode, trust, title, … }
    items: new Map(),                   // seq → { item, noeud }
    erreur: null,                       // erreur d'ouverture à afficher dans le quai
    sessions: [],
  };
  const fil = $('fil'), quai = $('quai'), texte = $('texte');

  const memoire = {
    lit(k) { try { return localStorage.getItem(k); } catch { return null; } },
    ecrit(k, v) { try { if (v == null) localStorage.removeItem(k); else localStorage.setItem(k, v); } catch { /* stockage indisponible */ } },
  };
  const cleSession = () => `lab-chat:${S.app}:${S.agent}:session`;

  // ── Rendu Markdown minimal et sûr ───────────────────────────────────────
  function enLigne(parent, s) {
    const re = /(`[^`\n]+`)|(\*\*[^*\n]+\*\*)|(\*[^*\s][^*\n]*\*)|(\[[^\]\n]+\]\(https?:\/\/[^\s)]+\))/g;
    let i = 0, m;
    while ((m = re.exec(s))) {
      if (m.index > i) parent.append(s.slice(i, m.index));
      const t = m[0];
      if (m[1]) parent.append(el('code', null, t.slice(1, -1)));
      else if (m[2]) parent.append(el('strong', null, t.slice(2, -2)));
      else if (m[3]) parent.append(el('em', null, t.slice(1, -1)));
      else {
        const k = t.indexOf('](');
        const a = el('a', null, t.slice(1, k));
        a.href = t.slice(k + 2, -1); a.target = '_blank'; a.rel = 'noopener noreferrer';
        parent.append(a);
      }
      i = m.index + t.length;
    }
    if (i < s.length) parent.append(s.slice(i));
  }
  function markdown(src) {
    const frag = document.createDocumentFragment();
    const lignes = src.split('\n');
    let para = [], liste = null;
    const videPara = () => { if (para.length) { const p = el('p'); enLigne(p, para.join('\n')); frag.append(p); para = []; } };
    const videListe = () => { liste = null; };
    for (let i = 0; i < lignes.length; i++) {
      const l = lignes[i];
      const cloture = l.match(/^\s*```(.*)$/);
      if (cloture) {
        videPara(); videListe();
        const corps = [];
        i++;
        while (i < lignes.length && !/^\s*```\s*$/.test(lignes[i])) { corps.push(lignes[i]); i++; }
        const pre = el('pre'); pre.append(el('code', null, corps.join('\n'))); frag.append(pre);
        continue;
      }
      let m;
      if (!l.trim()) { videPara(); videListe(); }
      else if ((m = l.match(/^(#{1,6})\s+(.*)$/))) {
        videPara(); videListe();
        const h = el('h' + Math.min(5, m[1].length + 2)); enLigne(h, m[2]); frag.append(h);
      } else if ((m = l.match(/^\s*(?:[-*+]|(\d+)[.)])\s+(.*)$/))) {
        videPara();
        const genre = m[1] ? 'ol' : 'ul';
        if (!liste || liste.tagName.toLowerCase() !== genre) { liste = el(genre); frag.append(liste); }
        const li = el('li'); enLigne(li, m[2]); liste.append(li);
      } else if ((m = l.match(/^>\s?(.*)$/))) {
        videPara(); videListe();
        const b = el('blockquote'); enLigne(b, m[1]); frag.append(b);
      } else { videListe(); para.push(l); }
    }
    videPara();
    return frag;
  }

  // ── Différences de fichiers ─────────────────────────────────────────────
  function lignesDiff(ancien, nouveau) {
    // Un texte terminé par un retour à la ligne ne compte pas une dernière ligne vide.
    const decoupe = t => { const l = t.split('\n'); if (l.length > 1 && l[l.length - 1] === '') l.pop(); return l; };
    const a = ancien == null ? [] : decoupe(ancien), b = decoupe(nouveau);
    if (a.length * b.length > 400000) return [...a.map(t => ['r', t]), ...b.map(t => ['a', t])];
    const n = a.length, m = b.length, w = m + 1;
    const T = new Uint32Array((n + 1) * w);
    for (let i = n - 1; i >= 0; i--) for (let j = m - 1; j >= 0; j--) {
      T[i * w + j] = a[i] === b[j] ? T[(i + 1) * w + j + 1] + 1 : Math.max(T[(i + 1) * w + j], T[i * w + j + 1]);
    }
    const out = []; let i = 0, j = 0;
    while (i < n && j < m) {
      if (a[i] === b[j]) { out.push(['c', a[i]]); i++; j++; }
      else if (T[(i + 1) * w + j] >= T[i * w + j + 1]) { out.push(['r', a[i]]); i++; }
      else { out.push(['a', b[j]]); j++; }
    }
    while (i < n) out.push(['r', a[i++]]);
    while (j < m) out.push(['a', b[j++]]);
    return out;
  }
  function blocDiff(d) {
    const lignes = lignesDiff(d.oldText, d.newText);
    const plus = lignes.filter(x => x[0] === 'a').length, moins = lignes.filter(x => x[0] === 'r').length;
    const bloc = el('div', 'diff');
    const tete = el('div', 'diff-tete');
    tete.append(el('span', null, d.path || 'fichier'), el('span', 'plus', `+${plus}`), el('span', 'moins', `−${moins}`));
    if (d.oldText == null) tete.append(el('span', null, '(nouveau fichier)'));
    const corps = el('div', 'diff-corps');
    // Seules les lignes proches d'un changement sont montrées.
    const garde = new Uint8Array(lignes.length);
    lignes.forEach((x, k) => { if (x[0] !== 'c') for (let q = Math.max(0, k - 2); q <= Math.min(lignes.length - 1, k + 2); q++) garde[q] = 1; });
    let saute = false;
    lignes.forEach((x, k) => {
      if (!garde[k]) { if (!saute) { corps.append(el('span', 'diff-l s', '⋯')); saute = true; } return; }
      saute = false;
      corps.append(el('span', 'diff-l ' + x[0], (x[0] === 'a' ? '+ ' : x[0] === 'r' ? '− ' : '  ') + x[1]));
    });
    bloc.append(tete, corps);
    return bloc;
  }

  // ── Rendu des éléments du fil ───────────────────────────────────────────
  function corpsOutil(it, corps) {
    corps.replaceChildren();
    if (it.input) corps.append(el('pre', null, it.input));
    for (const l of it.locations || []) corps.append(el('div', 'o-lieu', l));
    for (const c of it.content || []) corps.append(c.type === 'diff' ? blocDiff(c) : el('pre', null, c.text));
    if (!corps.childNodes.length) corps.append(el('div', 'o-lieu', 'Aucun détail.'));
  }
  function rendOutil(it, ancien) {
    const d = ancien || el('details', 'carte outil');
    const aDiff = (it.content || []).some(c => c.type === 'diff');
    if (!ancien) {
      const s = el('summary');
      s.append(el('span', 'o-genre'), el('span', 'o-titre'), el('span', 'o-etat'));
      d.append(s, el('div', 'carte-corps'));
    }
    if (aDiff && !d.dataset.diff) { d.open = true; d.dataset.diff = '1'; }     // une modification de fichier se lit sans geste
    d.className = `carte outil etat-${it.status}`;
    d.querySelector('.o-genre').textContent = GENRES[it.kind] || GENRES.other;
    d.querySelector('.o-titre').textContent = it.title || '(outil)';
    d.querySelector('.o-etat').textContent = ETATS_OUTIL[it.status] || it.status;
    corpsOutil(it, d.querySelector('.carte-corps'));
    return d;
  }
  function libelleOption(item, o) {
    const meme = item.options.filter(x => x.kind === o.kind).length;
    if (o.kind === 'allow_once' && meme === 1) return 'Autoriser une fois';
    if (o.kind === 'reject_once' && meme === 1) return 'Refuser';
    return o.name;
  }
  function rendPerm(it, ancien) {
    const d = ancien || el('div');
    const o = it.options.find(x => x.optionId === it.chosen);
    if (it.state === 'pending') { d.className = 'ligne-perm'; d.textContent = `Autorisation demandée : ${it.title || 'action'} — en attente de votre réponse.`; }
    else if (it.state === 'cancelled') { d.className = 'ligne-perm'; d.textContent = `Demande d'autorisation annulée : ${it.title || 'action'}.`; }
    else if (o && o.kind.startsWith('reject')) { d.className = 'ligne-perm refuse'; d.textContent = `✕ Refusé : ${it.title || 'action'}.`; }
    else { d.className = 'ligne-perm accorde'; d.textContent = `✓ ${it.auto ? 'Accepté automatiquement' : 'Autorisé'} (${o ? libelleOption(it, o) : '—'}) : ${it.title || 'action'}.`; }
    return d;
  }
  function rendPlan(it, ancien) {
    const d = ancien || el('div', 'plan');
    d.replaceChildren(el('strong', null, 'Plan'));
    const ul = el('ul');
    for (const e of it.entries) {
      const li = el('li', e.status);
      li.append(el('span', 'puce', e.status === 'completed' ? '✓' : e.status === 'in_progress' ? '▶' : '○'), el('span', null, e.content));
      ul.append(li);
    }
    d.append(ul);
    return d;
  }
  function rend(it, ancien) {
    switch (it.k) {
      case 'user': { const d = ancien || el('div', 'msg msg-user'); d.textContent = it.text; return d; }
      case 'text': { const d = ancien || el('div', 'msg msg-agent'); d.replaceChildren(markdown(it.text)); return d; }
      case 'thought': {
        const d = ancien || el('details', 'carte pensee');
        if (!ancien) { const s = el('summary'); s.append(el('span', 'o-genre', 'Réflexion')); d.append(s, el('div', 'carte-corps')); }
        d.querySelector('.carte-corps').textContent = it.text;
        return d;
      }
      case 'tool': return rendOutil(it, ancien);
      case 'perm': return rendPerm(it, ancien);
      case 'plan': return rendPlan(it, ancien);
      case 'end': { const t = FINS[it.stopReason]; if (!t) return null; return el('div', 'note', t); }
      case 'error': return el('div', 'note alerte', it.code === 'auth' ? "L'assistant n'est pas connecté : message non traité." : `Erreur de l'assistant : ${it.text}`);
      default: return null;
    }
  }
  const presDuBas = () => fil.scrollHeight - fil.scrollTop - fil.clientHeight < 120;
  const versLeBas = () => { fil.scrollTop = fil.scrollHeight; };
  let indicateur = null;
  function poseIndicateur() {
    if (indicateur) indicateur.remove();
    indicateur = null;
    if (S.session && S.session.running) {
      indicateur = el('div', 'travail');
      const p = el('span', 'points'); p.append(el('i'), el('i'), el('i'));
      indicateur.append(p, el('span', null, S.session.cancelling ? 'Arrêt demandé…' : "L'assistant travaille…"));
      fil.append(indicateur);
    }
  }
  function ajouteItem(it) {
    const coller = presDuBas();
    const vide = fil.querySelector('.vide'); if (vide) vide.remove();
    const n = rend(it, null);
    S.items.set(it.seq, { item: it, noeud: n });
    if (n) { if (indicateur) fil.insertBefore(n, indicateur); else fil.append(n); }
    if (coller || it.k === 'user') versLeBas();
  }
  const aRendre = new Set(); let trame = 0;
  function redessine(seq) {       // regroupe les rendus de texte au fil de l'eau
    aRendre.add(seq);
    if (trame) return;
    trame = requestAnimationFrame(() => {
      trame = 0;
      const coller = presDuBas();
      for (const s of aRendre) { const e = S.items.get(s); if (e && e.noeud) rend(e.item, e.noeud); }
      aRendre.clear();
      if (coller) versLeBas();
    });
  }

  // ── Quai : autorisations, connexion de l'assistant, avertissements ──────
  function bouton(cls, libelle, action) { const b = el('button', 'btn ' + cls, libelle); b.type = 'button'; b.addEventListener('click', action); return b; }
  function panneauAuth() {
    const a = AIDE[S.agent];
    const p = el('section', 'panneau avert'); p.id = 'panneau-auth';
    p.append(el('h2', null, a.titre));
    const ol = el('ol'); for (const e of a.etapes) ol.append(el('li', null, e)); p.append(ol);
    p.append(el('p', 'note', "Cette page ne demande et n'affiche jamais vos identifiants : la connexion se fait dans le terminal."));
    const act = el('div', 'actions');
    const lien = el('a', 'btn btn-secondaire', "Ouvrir l'éditeur"); lien.href = '../';
    act.append(lien, bouton('btn-primaire', 'Réessayer', () => { S.erreur = null; envoie({ type: 'retry' }); }));
    p.append(act);
    return p;
  }
  function panneauPerm(it) {
    const p = el('section', 'panneau autorisation'); p.dataset.perm = it.id;
    p.append(el('h2', null, 'Autorisation demandée'));
    const outil = [...S.items.values()].map(x => x.item).find(x => x.k === 'tool' && x.id === it.toolId);
    if (!(outil && outil.input && outil.input === it.title)) p.append(el('div', 'p-outil', it.title || 'Action'));
    if (outil) {
      if (outil.input) p.append(el('pre', null, outil.input));
      for (const c of outil.content || []) if (c.type === 'diff') p.append(blocDiff(c));
    }
    const act = el('div', 'actions');
    const ordre = { allow_once: 0, allow_always: 1, reject_once: 2, reject_always: 3 };
    for (const o of [...it.options].sort((x, y) => (ordre[x.kind] ?? 1.5) - (ordre[y.kind] ?? 1.5))) {
      const cls = o.kind === 'allow_once' ? 'btn-primaire' : o.kind.startsWith('reject') ? 'btn-refus' : 'btn-secondaire';
      const b = bouton(cls, libelleOption(it, o), () => { envoie({ type: 'permission', permId: it.id, optionId: o.optionId }); for (const x of act.querySelectorAll('button')) x.disabled = true; });
      b.dataset.kind = o.kind; b.title = o.name;
      act.append(b);
    }
    p.append(act);
    return p;
  }
  function majQuai() {
    const sess = S.session, av = S.agentVue;
    const blocs = [];
    const sansIdentifiants = av && av.auth === 'none';
    if (!S.connecte) { /* l'en-tête dit déjà l'état de la connexion */ }
    else if (av && av.state === 'error') {
      const p = el('section', 'panneau erreur');
      p.append(el('h2', null, `${S.labels[S.agent]} n'a pas démarré`), el('p', null, av.detail || ''));
      const act = el('div', 'actions'); act.append(bouton('btn-primaire', 'Réessayer', () => { S.erreur = null; envoie({ type: 'retry' }); })); p.append(act);
      blocs.push(p);
    } else if (sansIdentifiants) blocs.push(panneauAuth());
    else if (av && av.state === 'stopped' && sess) {
      const p = el('section', 'panneau avert');
      p.append(el('h2', null, `${S.labels[S.agent]} s'est arrêté`), el('p', null, "La conversation est conservée par l'assistant : relancez-le pour la reprendre."));
      const act = el('div', 'actions'); act.append(bouton('btn-primaire', 'Relancer', () => ouvre())); p.append(act);
      blocs.push(p);
    } else if (S.erreur) {
      const p = el('section', 'panneau erreur');
      p.append(el('h2', null, 'Conversation non ouverte'), el('p', null, S.erreur));
      const act = el('div', 'actions'); act.append(bouton('btn-primaire', 'Réessayer', () => { S.erreur = null; ouvre(); })); p.append(act);
      blocs.push(p);
    }
    if (sess && S.connecte && !sansIdentifiants) {
      for (const { item } of S.items.values()) if (item.k === 'perm' && item.state === 'pending') blocs.push(panneauPerm(item));
      const m = sess.mode;
      if (m && m.current && m.current !== m.strict && m.strictDispo) {
        const p = el('section', 'panneau avert'); p.id = 'panneau-mode';
        p.append(el('p', null, `L'assistant est en mode « ${m.name} » : il n'attend plus votre accord pour certaines actions.`));
        const act = el('div', 'actions'); act.append(bouton('btn-secondaire', 'Revenir à « demander avant d\'agir »', () => envoie({ type: 'mode_strict' }))); p.append(act);
        blocs.push(p);
      }
      if (S.agent === 'vibe' && sess.trust === 'untrusted') {
        const p = el('section', 'panneau avert'); p.id = 'panneau-confiance';
        p.append(el('p', null, "Vibe ne lit les règles du projet (AGENTS.md) que pour un dossier « de confiance ». Ce dossier est celui de votre projet."));
        const act = el('div', 'actions'); act.append(bouton('btn-secondaire', 'Faire confiance à ce dossier', () => envoie({ type: 'trust', decision: 'trust_cwd' }))); p.append(act);
        blocs.push(p);
      }
    }
    quai.replaceChildren(...blocs);
    // Saisie : masquée tant qu'on ne peut pas parler à l'assistant.
    const parlable = !!sess && !sansIdentifiants && !(av && (av.state === 'error' || av.state === 'stopped'));
    $('saisie').hidden = !parlable;
    const enCours = !!(sess && sess.running);
    $('envoyer').hidden = enCours; $('arreter').hidden = !enCours;
    $('envoyer').disabled = !S.connecte; $('arreter').disabled = !S.connecte || !!(sess && sess.cancelling);
    $('auto').checked = !!(sess && sess.autoAccept); $('auto').disabled = !S.connecte;
    $('reglage-auto').classList.toggle('actif', !!(sess && sess.autoAccept));
    poseIndicateur();
  }
  function majEntete() {
    $('projet').textContent = S.app || 'Espace de travail';
    for (const b of document.querySelectorAll('.bascule button')) b.setAttribute('aria-pressed', String(b.dataset.agent === S.agent));
    const p = $('pastille'), e = $('etat-connexion'), av = S.agentVue;
    // Sous-titre : l'assistant en cours, puis l'état de la liaison (court : il doit tenir à 390 px).
    let t, c;
    if (!S.connecte) { t = S.essais ? 'reconnexion…' : 'connexion…'; c = S.essais ? 'ko' : ''; }
    else if (av && av.state === 'starting') { t = 'démarrage…'; c = ''; }
    else if (av && av.auth === 'none') { t = 'à connecter'; c = ''; }
    else if (S.session && S.session.running) { t = 'au travail'; c = 'ok'; }
    else { t = 'connecté'; c = 'ok'; }
    // Hors ligne, l'état passe seul : c'est lui qui doit se lire d'un coup d'œil sur un téléphone.
    e.textContent = S.connecte ? `${S.labels[S.agent] || 'Assistant'} · ${t}` : (S.essais ? 'Connexion perdue · reconnexion…' : 'Connexion…');
    p.className = 'pastille ' + c;
    e.title = !S.connecte && S.essais ? 'Connexion perdue : la page se reconnecte seule, le tour en cours continue.' : '';
    document.title = S.app ? `${S.app} — ${S.labels[S.agent] || 'conversation'}` : 'Conversation';
  }
  function filVide(titre, sous) {
    fil.replaceChildren(); indicateur = null;
    const v = el('div', 'vide'); v.append(el('strong', null, titre)); if (sous) v.append(el('span', null, sous));
    fil.append(v);
  }

  // ── Liste des conversations ─────────────────────────────────────────────
  function quand(iso) {
    const d = iso ? new Date(iso) : null;
    if (!d || isNaN(d)) return '';
    const s = (Date.now() - d.getTime()) / 1000;
    if (s < 90) return "à l'instant";
    if (s < 3600) return `il y a ${Math.round(s / 60)} min`;
    if (s < 86400) return `il y a ${Math.round(s / 3600)} h`;
    return d.toLocaleDateString('fr-FR', { day: 'numeric', month: 'short' });
  }
  function majListe() {
    const ul = $('liste'); ul.replaceChildren();
    $('liste-note').textContent = S.sessions.length ? '' : 'Aucune conversation précédente pour ce projet avec cet assistant.';
    for (const s of S.sessions) {
      const li = el('li'), b = el('button'); b.type = 'button';
      const courant = S.session && S.session.sessionId === s.sessionId;
      if (courant) b.setAttribute('aria-current', 'true');
      b.append(el('span', 'l-titre', s.title || 'Conversation sans titre'), el('span', 'l-date', (s.running ? 'en cours · ' : '') + quand(s.updatedAt)));
      b.addEventListener('click', () => { fermeTiroir(); if (!courant) { S.erreur = null; S.session = null; S.items.clear(); filVide('Chargement de la conversation…'); majQuai(); envoie({ type: 'load', sessionId: s.sessionId }); } });
      li.append(b); ul.append(li);
    }
  }
  const ouvreTiroir = () => { $('app').classList.add('tiroir-ouvert'); envoie({ type: 'list' }); };
  const fermeTiroir = () => $('app').classList.remove('tiroir-ouvert');

  // ── Liaison avec le service ─────────────────────────────────────────────
  function envoie(m) { if (S.ws && S.ws.readyState === 1) { S.ws.send(JSON.stringify(m)); return true; } return false; }
  function ouvre() { envoie({ type: 'open', agent: S.agent, sessionId: (S.session && S.session.sessionId) || memoire.lit(cleSession()) || null }); }
  function choisitAgent(a, parUtilisateur) {
    S.agent = AGENTS.includes(a) ? a : 'claude';
    S.session = null; S.agentVue = null; S.erreur = null; S.items.clear(); S.sessions = [];
    memoire.ecrit(`lab-chat:${S.app}:agent`, S.agent);
    try { history.replaceState(null, '', `?agent=${S.agent}`); } catch { /* sans gravité */ }
    filVide(`Démarrage de ${S.labels[S.agent]}…`, 'Cela peut prendre quelques secondes.');
    majListe(); majEntete(); majQuai();
    if (parUtilisateur || S.connecte) ouvre();
  }
  function recoit(m) {
    switch (m.type) {
      case 'hello': {
        S.app = m.app || '';
        for (const k of AGENTS) if (m.agents && m.agents[k]) S.labels[k] = m.agents[k].label;
        if (!S.agent) {
          const demande = new URLSearchParams(location.search).get('agent');
          // ?agent=… d'abord ; sinon le dernier utilisé ; sinon Claude.
          S.agent = AGENTS.includes(demande) ? demande : (m.lastAgent || memoire.lit(`lab-chat:${S.app}:agent`) || 'claude');
          choisitAgent(S.agent, false);
        } else { majEntete(); ouvre(); }           // reconnexion : on reprend la même conversation
        break;
      }
      case 'agent':
        if (m.agent !== S.agent) break;
        S.agentVue = m;
        if (m.state === 'starting' && !S.session) filVide(`Démarrage de ${S.labels[S.agent]}…`, 'Cela peut prendre quelques secondes.');
        if ((m.auth === 'none' || m.state === 'error') && !S.session) filVide(S.labels[S.agent], '');
        majEntete(); majQuai();
        break;
      case 'session': {
        if (m.agent !== S.agent) break;
        S.session = m; S.erreur = null; S.items.clear();
        memoire.ecrit(cleSession(), m.sessionId);
        fil.replaceChildren(); indicateur = null;
        if (!m.items.length) filVide('Nouvelle conversation', `${S.labels[S.agent]} travaille dans ${S.app ? '/work/' + S.app : 'le projet'} et demande avant d'agir.`);
        for (const it of m.items) ajouteItem(it);
        majEntete(); majQuai(); versLeBas();
        envoie({ type: 'list' });
        break;
      }
      case 'state':
        if (!S.session || m.sessionId !== S.session.sessionId) break;
        { const finDeTour = S.session.running && !m.running;
          Object.assign(S.session, m, { type: 'session' });
          majEntete(); majQuai();
          if (finDeTour) envoie({ type: 'list' }); }
        break;
      case 'item':
        if (!S.session || m.sessionId !== S.session.sessionId) break;
        ajouteItem(m.item);
        if (m.item.k === 'perm' || m.item.k === 'error') majQuai();
        break;
      case 'append': {
        if (!S.session || m.sessionId !== S.session.sessionId) break;
        const e = S.items.get(m.seq); if (!e) break;
        e.item.text += m.text; redessine(m.seq);
        break;
      }
      case 'patch': {
        if (!S.session || m.sessionId !== S.session.sessionId) break;
        const e = S.items.get(m.item.seq); if (!e) { ajouteItem(m.item); break; }
        e.item = m.item; if (e.noeud) rend(m.item, e.noeud);
        if (m.item.k === 'perm' || m.item.k === 'tool') majQuai();
        break;
      }
      case 'sessions': if (m.agent === S.agent) { S.sessions = m.sessions; majListe(); } break;
      case 'error':
        if (m.what === 'open' && m.code !== 'auth') {
          S.erreur = m.message || "L'assistant n'a pas pu ouvrir la conversation.";
          if (!S.session) filVide(S.labels[S.agent], '');
        }
        majQuai();
        break;
      default: break;
    }
  }
  function connecte() {
    clearTimeout(S.minuterie);
    const u = new URL('ws', location.href); u.protocol = location.protocol === 'https:' ? 'wss:' : 'ws:'; u.search = '';
    let ws;
    try { ws = new WebSocket(u); } catch { return replanifie(); }
    S.ws = ws;
    ws.onopen = () => { S.connecte = true; S.essais = 0; majEntete(); majQuai(); };
    ws.onmessage = ev => { let m; try { m = JSON.parse(ev.data); } catch { return; } recoit(m); };
    ws.onclose = () => { if (S.ws !== ws) return; S.connecte = false; S.ws = null; replanifie(); };
    ws.onerror = () => {};
  }
  function replanifie() {
    S.essais++; majEntete(); majQuai();
    clearTimeout(S.minuterie);
    S.minuterie = setTimeout(connecte, Math.min(5000, 400 * 2 ** Math.min(S.essais - 1, 4)));
  }
  // Retour du réseau ou de l'onglet : reconnexion immédiate.
  const relance = () => { if (!S.connecte && (!S.ws || S.ws.readyState > 1)) { clearTimeout(S.minuterie); connecte(); } };
  window.addEventListener('online', relance);
  document.addEventListener('visibilitychange', () => { if (!document.hidden) relance(); });

  // ── Gestes ──────────────────────────────────────────────────────────────
  function ajuste() { texte.style.height = 'auto'; texte.style.height = Math.min(texte.scrollHeight + 2, window.innerHeight * 0.4) + 'px'; }
  function envoiePrompt() {
    const t = texte.value.trim();
    if (!t || !S.session || S.session.running) return;
    if (envoie({ type: 'prompt', text: t })) { texte.value = ''; ajuste(); }
  }
  texte.addEventListener('input', ajuste);
  texte.addEventListener('keydown', e => {
    // Entrée envoie sur un clavier physique ; sur téléphone, Entrée fait une ligne et le bouton envoie.
    if (e.key === 'Enter' && !e.shiftKey && !e.isComposing && !matchMedia('(pointer: coarse)').matches) { e.preventDefault(); envoiePrompt(); }
  });
  $('envoyer').addEventListener('click', envoiePrompt);
  $('arreter').addEventListener('click', () => envoie({ type: 'cancel' }));
  $('auto').addEventListener('change', e => { if (!envoie({ type: 'auto', value: e.target.checked })) e.target.checked = !e.target.checked; });
  $('nouvelle').addEventListener('click', () => { fermeTiroir(); S.erreur = null; S.session = null; S.items.clear(); filVide('Nouvelle conversation…'); majQuai(); envoie({ type: 'new' }); });
  $('ouvrir-tiroir').addEventListener('click', ouvreTiroir);
  $('fermer-tiroir').addEventListener('click', fermeTiroir);
  for (const b of document.querySelectorAll('.bascule button')) b.addEventListener('click', () => { if (b.dataset.agent !== S.agent) choisitAgent(b.dataset.agent, true); });

  filVide('Connexion…');
  majEntete(); majQuai();
  connecte();
})();
