import express from 'express';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { hasAppSpec, resolveApp } from './lib/resolve-app.js';
import { isValidAppName, prepareRunDir, removeRunDir } from './lib/spec.js';

// API (contrat « urgences » v1, interface I2) — appelant : le moteur lab-mcp
// (labmcp/engine.py, POST /run). Voir README.md.
//   GET  /healthz            {ok, busy}
//   GET  /list?app=<app>     [{file, title}]        — sans navigateur
//   POST /run {"app": ...}   [{file, title, status, message, durationMs}]
// 400 si le nom d'app est absent ou mal formé ; 409 si un run tourne déjà ;
// [] si l'app n'a pas de frontend/e2e/cloisonnement.spec.ts (« aucun test »,
// jamais « tout va bien »).
//
// Le fichier joué est TOUJOURS le spec du gabarit, copié dans un dossier
// temporaire propre à chaque appel (lib/spec.js) : aucun fichier du dépôt de
// l'app n'est chargé.

const execFileAsync = promisify(execFile);
const PORT = 4300;
const CONFIG = '/app/playwright.config.ts';
// Le spec copié vit hors de /app (dossier temporaire) : son
// `import ... from '@playwright/test'` ne résoudrait pas sans indiquer où se
// trouve node_modules (celui du runner). Vérifié : sans ça,
// "Cannot find module '@playwright/test'".
const NODE_PATH = '/app/node_modules';

const app = express();
app.use(express.json());

// Un seul run à la fois sur tout le lab (2 vCPU / 16 Go) ; le moteur attend
// son tour sur le 409.
let busy = false;

/** Rend le nom d'app validé, ou répond 400 et rend null. */
function appNameOr400(value, res, label) {
  if (!value || typeof value !== 'string') {
    res.status(400).json({ error: `${label} manquant` });
    return null;
  }
  if (!isValidAppName(value)) {
    res.status(400).json({ error: `${label} invalide (attendu : ^[a-z][a-z0-9-]{0,62}$)` });
    return null;
  }
  return value;
}

app.get('/healthz', (_req, res) => res.json({ ok: true, busy }));

// Catalogue : liste les tests d'une app, sans navigateur (--list).
app.get('/list', async (req, res) => {
  const appName = appNameOr400(req.query.app, res, 'paramètre "app"');
  if (!appName) return;
  if (!hasAppSpec(appName)) {
    return res.json([]); // app sans test de cloisonnement — pas une erreur
  }
  let dir;
  try {
    dir = prepareRunDir();
    let stdout = '';
    try {
      ({ stdout } = await execFileAsync(
        'npx',
        ['playwright', 'test', '--config', CONFIG, '--list', '--reporter=json'],
        {
          cwd: '/app',
          env: { ...process.env, NODE_PATH, E2E_TEST_DIR: dir },
          maxBuffer: 10 * 1024 * 1024,
        },
      ));
    } catch (err) {
      // --list sort non-nul si 0 test matche (entre autres) — le rapport
      // JSON est quand même sur stdout, c'est lui qui fait foi.
      stdout = err.stdout ?? '';
      if (!stdout) throw err;
    }
    res.json(extractTests(JSON.parse(stdout)));
  } catch (err) {
    res.status(500).json({ error: String(err) });
  } finally {
    removeRunDir(dir);
  }
});

// Exécution réelle (navigateur) d'une app. Un seul en cours à la fois (409 sinon).
app.post('/run', async (req, res) => {
  const appName = appNameOr400(req.body?.app, res, 'champ "app"');
  if (!appName) return;
  if (busy) {
    return res.status(409).json({ error: 'un run est déjà en cours sur ce runner' });
  }
  busy = true;
  let dir;
  try {
    let resolved;
    try {
      resolved = resolveApp(appName);
    } catch (err) {
      return res.status(422).json({ error: String(err.message ?? err) });
    }
    if (!resolved.hasSpec) {
      return res.json([]);
    }

    dir = prepareRunDir();
    let stdout = '';
    try {
      ({ stdout } = await execFileAsync(
        'npx',
        ['playwright', 'test', '--config', CONFIG, '--reporter=json'],
        {
          cwd: '/app',
          env: { ...process.env, NODE_PATH, ...resolved.env, E2E_TEST_DIR: dir },
          maxBuffer: 20 * 1024 * 1024,
        },
      ));
    } catch (err) {
      // Playwright sort avec un code non-nul dès qu'un test échoue : le
      // rapport JSON est quand même sur stdout, c'est lui qui fait foi, pas
      // le code de sortie du process.
      stdout = err.stdout ?? '';
      if (!stdout) throw err;
    }
    res.json(extractResults(JSON.parse(stdout)));
  } catch (err) {
    res.status(500).json({ error: String(err) });
  } finally {
    removeRunDir(dir);
    busy = false;
  }
});

/** Aplati la sortie --list en [{file, title}]. */
function extractTests(report) {
  const out = [];
  const walk = (suite) => {
    for (const spec of suite.specs ?? []) {
      out.push({ file: spec.file, title: spec.title });
    }
    for (const sub of suite.suites ?? []) walk(sub);
  };
  for (const s of report.suites ?? []) walk(s);
  return out;
}

/** Aplati un rapport d'exécution en [{file, title, status, message, durationMs}]. */
function extractResults(report) {
  const out = [];
  const walk = (suite) => {
    for (const spec of suite.specs ?? []) {
      for (const test of spec.tests ?? []) {
        const result = test.results?.[0];
        const passed = result?.status === 'passed';
        out.push({
          file: spec.file,
          title: spec.title,
          status: passed ? 'PASSED' : result?.status === 'timedOut' ? 'ERROR' : 'FAILED',
          message: result?.error?.message ?? '',
          durationMs: result?.duration ?? null,
        });
      }
    }
    for (const sub of suite.suites ?? []) walk(sub);
  };
  for (const s of report.suites ?? []) walk(s);
  return out;
}

app.listen(PORT, () => console.log(`e2e-runner en écoute sur :${PORT}`));
