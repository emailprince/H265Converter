const express = require('express');
const router = express.Router();
const { pamAuthenticate } = require('../lib/auth');

// Rate limiting map: ip -> { attempts, lockedUntil }
const loginAttempts = new Map();
const MAX_ATTEMPTS = 5;
const LOCK_MS = 15 * 60 * 1000; // 15 minutes

function getRateInfo(ip) {
  const now = Date.now();
  const info = loginAttempts.get(ip) || { attempts: 0, lockedUntil: 0 };
  if (info.lockedUntil && now > info.lockedUntil) {
    loginAttempts.delete(ip);
    return { attempts: 0, lockedUntil: 0 };
  }
  return info;
}

router.post('/login', async (req, res) => {
  const ip = req.ip || req.connection.remoteAddress;
  const { username, password } = req.body;

  const rate = getRateInfo(ip);
  if (rate.lockedUntil && Date.now() < rate.lockedUntil) {
    const remaining = Math.ceil((rate.lockedUntil - Date.now()) / 60000);
    return res.status(429).json({ ok: false, error: `Too many attempts. Locked for ${remaining} more minute(s).` });
  }

  const ok = await pamAuthenticate(username, password);

  if (!ok) {
    const attempts = (rate.attempts || 0) + 1;
    const lockedUntil = attempts >= MAX_ATTEMPTS ? Date.now() + LOCK_MS : rate.lockedUntil;
    loginAttempts.set(ip, { attempts, lockedUntil });
    return res.status(401).json({ ok: false, error: 'Invalid credentials' });
  }

  loginAttempts.delete(ip);
  req.session.user = username;
  req.session.loginAt = new Date().toISOString();
  res.json({ ok: true, user: username });
});

router.post('/logout', (req, res) => {
  req.session.destroy(() => res.json({ ok: true }));
});

router.get('/me', (req, res) => {
  if (req.session && req.session.user) {
    res.json({ ok: true, user: req.session.user, loginAt: req.session.loginAt });
  } else {
    res.status(401).json({ ok: false });
  }
});

module.exports = router;
