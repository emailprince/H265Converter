const express = require('express');
const fs = require('fs');
const fsp = require('fs/promises');
const path = require('path');
const { spawn } = require('child_process');

const router = express.Router();
const APP_DIR = path.resolve(__dirname, '..');
const REPO_DIR = path.resolve(APP_DIR, '..');
const SCRIPT_DIR = path.join(REPO_DIR, 'scripts');

const CONFIG = {
  session: process.env.MEDIA_CONTROL_TMUX_SESSION || 'media_h265',
  logDir: process.env.MEDIA_CONTROL_LOG_DIR || path.join(REPO_DIR, 'transcode-logs'),
  envFile: process.env.MEDIA_CONTROL_ENV || path.join(REPO_DIR, 'movie-transcode.env'),
  runner: process.env.MEDIA_CONTROL_RUNNER || path.join(SCRIPT_DIR, 'run_movie_transcode_all.sh'),
  cronWrapper: process.env.MEDIA_CONTROL_CRON_WRAPPER || path.join(SCRIPT_DIR, 'weekly_movie_transcode_cron.sh'),
  scripts: [
    path.join(SCRIPT_DIR, 'run_movie_transcode_all.sh'),
    path.join(SCRIPT_DIR, 'weekly_movie_transcode_cron.sh'),
    path.join(SCRIPT_DIR, 'transcode_movies_h265_vaapi.sh'),
    path.join(SCRIPT_DIR, 'transcode_iso_movies_h265_vaapi.sh'),
    path.join(SCRIPT_DIR, 'standardize_movie_filenames.sh'),
    path.join(SCRIPT_DIR, 'refresh_plex_library.sh'),
  ],
};

function requireAuth(req, res, next) {
  if (req.session && req.session.user) return next();
  return res.status(401).json({ ok: false, error: 'Authentication required' });
}

function run(command, args, opts = {}) {
  return new Promise((resolve) => {
    const child = spawn(command, args, {
      stdio: ['ignore', 'pipe', 'pipe'],
      timeout: opts.timeout || 10000,
      env: opts.env || process.env,
    });
    let stdout = '';
    let stderr = '';
    child.stdout.on('data', d => { stdout += d.toString(); });
    child.stderr.on('data', d => { stderr += d.toString(); });
    child.on('error', err => resolve({ ok: false, code: -1, stdout, stderr: err.message }));
    child.on('close', code => resolve({ ok: code === 0, code, stdout, stderr }));
  });
}

async function exists(file) {
  try {
    await fsp.access(file, fs.constants.F_OK);
    return true;
  } catch {
    return false;
  }
}

async function statFile(file) {
  try {
    const stat = await fsp.stat(file);
    return {
      path: file,
      exists: true,
      mode: '0' + (stat.mode & 0o777).toString(8),
      size: stat.size,
      mtime: stat.mtime.toISOString(),
      executable: Boolean(stat.mode & 0o111),
    };
  } catch {
    return { path: file, exists: false };
  }
}

async function readEnvFile() {
  const result = {};
  try {
    const data = await fsp.readFile(CONFIG.envFile, 'utf8');
    for (const line of data.split('\n')) {
      const trimmed = line.trim();
      if (!trimmed || trimmed.startsWith('#') || !trimmed.includes('=')) continue;
      const idx = trimmed.indexOf('=');
      result[trimmed.slice(0, idx)] = trimmed.slice(idx + 1);
    }
  } catch {}
  return result;
}

async function tailFile(file, maxBytes = 24000) {
  const stat = await fsp.stat(file);
  const start = Math.max(0, stat.size - maxBytes);
  const handle = await fsp.open(file, 'r');
  try {
    const buf = Buffer.alloc(stat.size - start);
    await handle.read(buf, 0, buf.length, start);
    return buf.toString('utf8');
  } finally {
    await handle.close();
  }
}

async function latestLog(prefix) {
  try {
    const files = await fsp.readdir(CONFIG.logDir, { withFileTypes: true });
    const matches = [];
    for (const entry of files) {
      if (!entry.isFile() || !entry.name.startsWith(prefix)) continue;
      const full = path.join(CONFIG.logDir, entry.name);
      const stat = await fsp.stat(full);
      matches.push({ name: entry.name, path: full, mtimeMs: stat.mtimeMs, size: stat.size });
    }
    matches.sort((a, b) => b.mtimeMs - a.mtimeMs);
    return matches[0] || null;
  } catch {
    return null;
  }
}

function parseProgress(lines) {
  const text = lines || '';
  const all = text.split('\n').filter(Boolean);
  const lastStart = [...all].reverse().find(l => l.includes('START ') || l.includes('Starting ')) || '';
  const lastDone = [...all].reverse().find(l => l.includes('DONE ') || l.includes('Complete.') || l.includes('All passes complete')) || '';
  const lastFail = [...all].reverse().find(l => l.includes('FAIL ') || l.includes('ERROR ') || l.includes('FAILED ')) || '';
  return { lastStart, lastDone, lastFail };
}

async function tmuxRunning() {
  const res = await run('tmux', ['has-session', '-t', CONFIG.session], { timeout: 3000 });
  return res.ok;
}

async function activeProcessSummary() {
  const res = await run('pgrep', ['-af', 'transcode_.*_h265_vaapi.sh|ffmpeg .*hevc_vaapi|run_movie_transcode_all.sh'], { timeout: 3000 });
  if (!res.ok && res.code !== 1) return [];
  return res.stdout.split('\n').filter(Boolean).map(line => {
    const firstSpace = line.indexOf(' ');
    return {
      pid: firstSpace > -1 ? line.slice(0, firstSpace) : line,
      command: firstSpace > -1 ? line.slice(firstSpace + 1) : '',
    };
  });
}

async function cronEntry() {
  const res = await run('crontab', ['-l'], { timeout: 3000 });
  const lines = res.stdout.split('\n').filter(Boolean);
  return lines.filter(line => line.includes(CONFIG.cronWrapper) || line.includes('transcode'));
}

router.use(requireAuth);

router.get('/status', async (req, res) => {
  const [env, tmux, processes, cron, runLog, movieLog, isoLog, scripts] = await Promise.all([
    readEnvFile(),
    tmuxRunning(),
    activeProcessSummary(),
    cronEntry(),
    latestLog('run-all-'),
    latestLog('movies-h265-vaapi-'),
    latestLog('iso-h265-vaapi-'),
    Promise.all(CONFIG.scripts.map(statFile)),
  ]);

  let logTail = '';
  const selectedLog = runLog || movieLog || isoLog;
  if (selectedLog) {
    try {
      logTail = await tailFile(selectedLog.path, 16000);
    } catch {}
  }

  res.json({
    ok: true,
    config: {
      session: CONFIG.session,
      logDir: CONFIG.logDir,
      envFile: CONFIG.envFile,
      runner: CONFIG.runner,
      cronWrapper: CONFIG.cronWrapper,
      env,
    },
    running: tmux || processes.length > 0,
    tmux,
    processes,
    cron,
    logs: { runLog, movieLog, isoLog, selectedLog, progress: parseProgress(logTail), tail: logTail },
    scripts,
    now: new Date().toISOString(),
  });
});

router.get('/logs', async (req, res) => {
  const limit = Math.min(Number(req.query.limit || 80), 250);
  try {
    const files = await fsp.readdir(CONFIG.logDir, { withFileTypes: true });
    const results = [];
    for (const entry of files) {
      if (!entry.isFile()) continue;
      const full = path.join(CONFIG.logDir, entry.name);
      const stat = await fsp.stat(full);
      results.push({
        name: entry.name,
        size: stat.size,
        mtime: stat.mtime.toISOString(),
        kind: entry.name.startsWith('run-all-') ? 'Run' :
          entry.name.startsWith('movies-h265-vaapi-') ? 'Movies' :
          entry.name.startsWith('iso-h265-vaapi-') ? 'ISO' :
          entry.name.startsWith('filename-standardize-') ? 'Names' :
          entry.name.startsWith('plex-refresh-') ? 'Plex' :
          entry.name.includes('failed') ? 'Failed' : 'Other',
      });
    }
    results.sort((a, b) => b.mtime.localeCompare(a.mtime));
    res.json({ ok: true, logs: results.slice(0, limit) });
  } catch (err) {
    res.status(500).json({ ok: false, error: err.message });
  }
});

router.get('/logs/:name', async (req, res) => {
  const name = path.basename(req.params.name);
  const full = path.join(CONFIG.logDir, name);
  if (!full.startsWith(CONFIG.logDir + path.sep)) {
    return res.status(400).json({ ok: false, error: 'Invalid log path' });
  }
  try {
    const maxBytes = Math.min(Number(req.query.bytes || 60000), 200000);
    const stat = await fsp.stat(full);
    if (!stat.isFile()) return res.status(404).json({ ok: false, error: 'Not a file' });
    const content = await tailFile(full, maxBytes);
    res.json({ ok: true, name, size: stat.size, mtime: stat.mtime.toISOString(), content, progress: parseProgress(content) });
  } catch (err) {
    res.status(404).json({ ok: false, error: err.message });
  }
});

router.post('/start', async (req, res) => {
  if (await tmuxRunning()) {
    return res.status(409).json({ ok: false, error: `tmux session ${CONFIG.session} is already running` });
  }
  if (!(await exists(CONFIG.runner))) {
    return res.status(500).json({ ok: false, error: `${CONFIG.runner} does not exist` });
  }
  await fsp.mkdir(CONFIG.logDir, { recursive: true });
  const result = await run('tmux', [
    'new-session',
    '-d',
    '-s',
    CONFIG.session,
    `env MOVIE_TRANSCODE_CONFIG=${CONFIG.envFile} ${CONFIG.runner}`,
  ], { timeout: 5000 });
  if (!result.ok) {
    return res.status(500).json({ ok: false, error: result.stderr || result.stdout || 'Failed to start job' });
  }
  res.json({ ok: true });
});

router.post('/stop', async (req, res) => {
  const wasRunning = await tmuxRunning();
  if (!wasRunning) return res.status(409).json({ ok: false, error: 'No active tmux session' });
  const result = await run('tmux', ['kill-session', '-t', CONFIG.session], { timeout: 5000 });
  if (!result.ok) {
    return res.status(500).json({ ok: false, error: result.stderr || result.stdout || 'Failed to stop session' });
  }
  res.json({ ok: true });
});

router.post('/run-cron-wrapper', async (req, res) => {
  if (!(await exists(CONFIG.cronWrapper))) {
    return res.status(500).json({ ok: false, error: `${CONFIG.cronWrapper} does not exist` });
  }
  const result = await run(CONFIG.cronWrapper, [], {
    timeout: 10000,
    env: { ...process.env, MOVIE_TRANSCODE_CONFIG: CONFIG.envFile },
  });
  if (!result.ok) {
    return res.status(500).json({ ok: false, error: result.stderr || result.stdout || 'Cron wrapper failed' });
  }
  res.json({ ok: true, output: result.stdout });
});

module.exports = router;
