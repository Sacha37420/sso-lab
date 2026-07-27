import express from 'express';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import fs from 'node:fs';
import { e2eDirFor, resolveApp } from './lib/resolve-app.js';

const execFileAsync = promisify(execFile);
const PORT = 4300;
const CONFIG = '/app/playwright.config.ts';
// Les fichiers e2e/*.spec.ts de chaque app vivent hors de /app (sous
// /mnt/dev/<app>/...) : leur `import ... from '@playwright/test'` ne
// résoudrait pas sans indiquer explicitement où se trouve node_modules
// (celui du runner — les apps n'ont jamais @playwright/test elles-mêmes,
// cf. CLAUDE.md). Vérifié : sans ça, "Cannot find module '@playwright/test'".
const NODE_PATH = '/app/node_modules';

const app = express();
app.use(express.json());

// Un seul run à la fois — filet de sécurité local en plus du
// --concurrency=1 du worker Celery de lab-admin (cf. CLAUDE.md, contrainte
// 2 vCPU/16 Go du serveur).
let busy = false;

app.get('/healthz', (_req, res) => res.json({ ok: true, busy }));

// Catalogue : liste les tests d'une app, sans navigateur (--list). Utilisé
// par setup_unit.sh à chaque déploiement.
app.get('/list', async (req, res) => {
  const appName = req.query.app;
  if (!appName || typeof appName !== 'string') {
    return res.status(400).json({ error: 'paramètre "app" manquant' });
  }
  const dir = e2eDirFor(appName);
  if (!fs.existsSync(dir)) {
    return res.json([]); // app sans frontend/e2e/ pour l'instant — pas une erreur
  }
  try {
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
  }
});

// Exécution réelle (navigateur) d'une app. Un seul en cours à la fois (409 sinon).
app.post('/run', async (req, res) => {
  const appName = req.body?.app;
  if (!appName || typeof appName !== 'string') {
    return res.status(400).json({ error: 'champ "app" manquant' });
  }
  if (busy) {
    return res.status(409).json({ error: 'un run est déjà en cours sur ce runner' });
  }
  busy = true;
  try {
    let resolved;
    try {
      resolved = resolveApp(appName);
    } catch (err) {
      return res.status(422).json({ error: String(err.message ?? err) });
    }
    if (!fs.existsSync(resolved.e2eDir)) {
      return res.json([]);
    }

    let stdout = '';
    try {
      ({ stdout } = await execFileAsync(
        'npx',
        ['playwright', 'test', '--config', CONFIG, '--reporter=json'],
        {
          cwd: '/app',
          env: { ...process.env, NODE_PATH, ...resolved.env, E2E_TEST_DIR: resolved.e2eDir },
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
