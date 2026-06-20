const express = require('express');
const session = require('express-session');
const path = require('path');
const { SESSION_SECRET } = require('./lib/auth');

const app = express();
const PORT = process.env.PORT || 8006;

app.use(express.json({ limit: '1mb' }));

app.use(session({
  secret: SESSION_SECRET,
  resave: false,
  saveUninitialized: false,
  cookie: {
    secure: false,
    httpOnly: true,
    maxAge: 8 * 60 * 60 * 1000,
  },
  name: 'mediacontrol.sid',
}));

app.use('/auth', require('./routes/auth'));
app.use('/api', require('./routes/api'));
app.use(express.static(path.join(__dirname, 'public')));

app.get('*', (req, res) => {
  res.sendFile(path.join(__dirname, 'public', 'index.html'));
});

app.listen(PORT, '0.0.0.0', () => {
  console.log(`\n  mediacontrol  ->  http://localhost:${PORT}`);
  console.log('  Run as root for tmux, cron, and media script access\n');
});
