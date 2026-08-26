/**
 * Options for the macOS menu bar bridge.
 *
 * The loopback origin is an *optional* permission: installing this extension should
 * not ask for anything the default install does not use. It is requested here, from a
 * real click, and only when the bridge is switched on.
 */
'use strict';

const B = self.CQMBridge;
const $ = (id) => document.getElementById(id);

const t = (key, fallback) => chrome.i18n.getMessage(key) || fallback;

function applyI18n() {
  document.querySelectorAll('[data-i18n]').forEach((el) => {
    const msg = chrome.i18n.getMessage(el.dataset.i18n);
    if (msg) el.textContent = msg;
  });
}

function setStatus(kind, text) {
  const el = $('status');
  el.className = `status ${kind}`;
  el.textContent = text;
}

async function load() {
  const cfg = await B.getConfig();
  $('enabled').checked = cfg.enabled;
  $('port').value = cfg.port;
  $('token').value = cfg.token;
  $('profile').value = cfg.profileName;
  await report();
}

/** Distinguishes the three ways this can be not-working, because the fixes differ. */
async function report() {
  const cfg = await B.getConfig();
  if (!cfg.enabled) return setStatus('idle', t('bridge_off', 'Off — this profile is not reporting.'));
  if (!cfg.token) return setStatus('warn', t('bridge_need_token', 'Paste the token from the Mac app.'));

  if (!(await B.hasLoopbackPermission())) {
    return setStatus('warn', t('bridge_need_perm', 'Permission for 127.0.0.1 not granted — press Save & connect.'));
  }

  const health = await B.checkHealth(cfg.port);
  if (!health.reachable) {
    return setStatus('err', t('bridge_no_app', 'No app answering on port ') + cfg.port + '.');
  }

  const stored = (await chrome.storage.local.get(B.STATUS_KEY))[B.STATUS_KEY];
  if (stored?.ok) {
    const when = stored.at ? new Date(stored.at).toLocaleTimeString() : '';
    return setStatus('ok', t('bridge_ok', 'Connected. Last sent ') + when + '.');
  }
  if (stored?.reason === 'bad-token') return setStatus('err', t('bridge_bad_token', 'App rejected the token.'));
  if (stored?.reason === 'no-data') {
    return setStatus('warn', t('bridge_no_data', 'App reachable, but this profile has no reading yet — open claude.ai.'));
  }
  setStatus('ok', t('bridge_reachable', 'App reachable. Waiting for the next reading.'));
}

async function save() {
  const port = Number($('port').value);
  if (!Number.isInteger(port) || port < 1024 || port > 65535) {
    return setStatus('err', t('bridge_bad_port', 'Port must be between 1024 and 65535.'));
  }

  const enabled = $('enabled').checked;
  if (enabled && !(await B.hasLoopbackPermission())) {
    // Must happen inside the click that got us here.
    const granted = await B.requestLoopbackPermission();
    if (!granted) return setStatus('err', t('bridge_perm_denied', 'Permission denied — the bridge cannot send anything.'));
  }

  await B.setConfig({
    enabled,
    port,
    token: $('token').value.trim(),
    profileName: $('profile').value.trim()
  });

  if (enabled) await B.pushToMac();
  await report();
}

$('save').addEventListener('click', save);
$('test').addEventListener('click', async () => {
  setStatus('idle', t('bridge_testing', 'Testing…'));
  if ((await B.getConfig()).enabled) await B.pushToMac();
  await report();
});
$('reveal').addEventListener('click', () => {
  const input = $('token');
  const hidden = input.type === 'password';
  input.type = hidden ? 'text' : 'password';
  $('reveal').textContent = hidden ? t('bridge_hide', 'hide') : t('bridge_reveal', 'show');
});

applyI18n();
load();
