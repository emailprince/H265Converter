const { spawn } = require('child_process');
const crypto = require('crypto');

const PAM_SERVICE = process.env.MEDIA_CONTROL_PAM_SERVICE || process.env.PROXMOUNT_PAM_SERVICE || 'proxmox-ve-auth';
const USER_RE = /^[a-zA-Z0-9._-]+$/;
const PAM_REALM_USER_RE = /^[a-zA-Z0-9._-]+@pam$/;

function normalizePamUsername(username) {
  if (!username || typeof username !== 'string') return null;
  const trimmed = username.trim();
  if (USER_RE.test(trimmed)) return trimmed;
  if (PAM_REALM_USER_RE.test(trimmed)) return trimmed.slice(0, -4);
  return null;
}

function runWithPassword(command, args, password, timeoutMs) {
  return new Promise((resolve) => {
    const child = spawn(command, args, {
      stdio: ['pipe', 'ignore', 'ignore'],
      timeout: timeoutMs,
    });

    let settled = false;
    const finish = (ok) => {
      if (settled) return;
      settled = true;
      resolve(ok);
    };

    child.on('error', () => finish(false));
    child.on('exit', (code) => finish(code === 0));
    child.stdin.on('error', () => {});

    child.stdin.end(password);
  });
}

// PAM authentication via Proxmox's installed Perl Authen::PAM binding.
// This avoids native npm modules and uses the same PAM service Proxmox uses.
function pamAuthenticate(username, password) {
  return new Promise((resolve) => {
    const pamUser = normalizePamUsername(username);
    if (!pamUser || !password || typeof password !== 'string') return resolve(false);

    const script = `
use strict;
use warnings;
use Authen::PAM qw(:constants);
my ($service, $username) = @ARGV;
my $password = do { local $/; <STDIN> };
my $pamh = Authen::PAM->new($service, $username, sub {
  my @res;
  while (@_) {
    my $msg_type = shift;
    my $msg = shift;
    push @res, (0, $password);
  }
  push @res, 0;
  return @res;
});
exit 1 if !ref($pamh);
exit 1 if $pamh->pam_authenticate(0) != PAM_SUCCESS;
exit 1 if $pamh->pam_acct_mgmt(0) != PAM_SUCCESS;
exit 0;
`;

    runWithPassword('perl', ['-e', script, PAM_SERVICE, pamUser], password, 8000)
      .then((ok) => ok ? resolve(true) : shadowFallback(pamUser, password).then(resolve));
  });
}

// Fallback: compare against /etc/shadow using libc crypt via Perl (root only).
// This supports modern Debian/Proxmox yescrypt hashes, unlike openssl passwd.
function shadowFallback(username, password) {
  return new Promise((resolve) => {
    try {
      const fs = require('fs');
      const shadow = fs.readFileSync('/etc/shadow', 'utf8');
      const line = shadow.split('\n').find(l => l.startsWith(username + ':'));
      if (!line) return resolve(false);
      const hash = line.split(':')[1];
      if (!hash || hash === '*' || hash === '!') return resolve(false);
      const script = 'my ($hash) = @ARGV; my $pw = do { local $/; <STDIN> }; exit(crypt($pw, $hash) eq $hash ? 0 : 1);';
      runWithPassword('perl', ['-e', script, hash], password, 5000).then(resolve);
    } catch {
      resolve(false);
    }
  });
}

// Generate a cryptographically random session secret on startup
const SESSION_SECRET = crypto.randomBytes(32).toString('hex');

module.exports = { pamAuthenticate, SESSION_SECRET };
