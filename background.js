/**
 * Service worker
 *
 * - Polling via chrome.alarms a cada 10 min (sem aba aberta necessária)
 * - Restaura o badge ao reiniciar
 * - Atualiza o badge sempre que o storage mudar
 */

// Pushing the cached reading to the Mac app costs nothing on claude.ai's side, so it
// runs far more often than the actual quota fetch. That is what keeps the menu bar
// within a minute of the truth without adding request volume.
importScripts('bridge.js', 'usage.js');

const ALARM = 'quota-poll';
const POLL_MINUTES = 15;
const PUSH_ALARM = 'mac-push';
const PUSH_MINUTES = 1;

/* ── Fetch direto do background (funciona com os cookies do usuário) ── */
async function fetchPlan(orgId) {
  try {
    const res = await fetch(
      `https://claude.ai/api/organizations/${orgId}`,
      { credentials: 'include' }
    );
    if (!res.ok) return null;
    const d = await res.json();
    // rate_limit_tier ex: "default_claude_max_5x", "default_pro", "default_free"
    // capabilities ex: ["claude_max", "chat"]
    return d?.rate_limit_tier ?? d?.capabilities?.[0] ?? d?.plan_nickname ?? d?.plan ?? d?.tier ?? null;
  } catch { return null; }
}

async function fetchUsage() {
  const { claudeUsage } = await chrome.storage.local.get('claudeUsage');
  const orgId = claudeUsage?.orgId;
  if (!orgId) return; // ainda não visitou claude.ai após instalar

  const { parseUsage, recordFetch } = self.CQMUsage;
  try {
    const res = await fetch(
      `https://claude.ai/api/organizations/${orgId}/usage`,
      { credentials: 'include' }
    );
    if (!res.ok) return recordFetch(false, `http-${res.status}`);
    const parsed = parseUsage(await res.json().catch(() => null));
    if (!parsed) return recordFetch(false, 'no-limits');

    // Plan only changes on an upgrade/downgrade, so fetch it once and reuse it — this is
    // half the request volume. Clear claudeUsage.plan from storage to force a re-read.
    const plan = claudeUsage?.plan ?? await fetchPlan(orgId);

    await chrome.storage.local.set({
      claudeUsage: {
        ...claudeUsage,
        ...parsed,
        ...(plan ? { plan } : {}),
        ts: Date.now()
      }
    });
    await recordFetch(true);
  } catch { await recordFetch(false, 'network'); }
}

/* ── Ponte para o app da barra de menus do macOS ── */
// The app cannot reach into the browser on its own; it answers a push with a flag
// when the user asked for a refresh, and that is when we spend a real request.
async function pushCycle() {
  const result = await self.CQMBridge.pushToMac();
  if (result?.refresh) await fetchUsage();
}

/* ── Alarme periódico ── */
// chrome.alarms.create replaces any alarm of the same name and restarts its period from
// zero. MV3 re-runs this whole file on every service-worker wake, and the one-minute push
// alarm wakes it constantly — so creating the 15-minute poll unconditionally would reset
// its timer a dozen times before it could ever fire. Create only what is missing.
function ensureAlarm(name, periodInMinutes) {
  chrome.alarms.get(name).then((existing) => {
    if (!existing || existing.periodInMinutes !== periodInMinutes) {
      chrome.alarms.create(name, { periodInMinutes });
    }
  });
}

ensureAlarm(ALARM, POLL_MINUTES);
ensureAlarm(PUSH_ALARM, PUSH_MINUTES);
chrome.alarms.onAlarm.addListener((alarm) => {
  if (alarm.name === ALARM) fetchUsage();
  if (alarm.name === PUSH_ALARM) pushCycle();
});

/* ── Restaura badge e dispara fetch ao iniciar ── */
function restoreAndRefresh() {
  chrome.storage.local.get('claudeUsage', ({ claudeUsage }) => {
    updateBadge(claudeUsage);
    fetchUsage();          // atualiza logo ao abrir o navegador
    self.CQMBridge.pushToMac();  // e avisa o app do macOS que já existe um valor
  });
}

chrome.runtime.onStartup.addListener(restoreAndRefresh);
chrome.runtime.onInstalled.addListener((details) => {
  restoreAndRefresh();
  chrome.storage.local.remove('claudeUsageRaw'); // limpa resíduo de debug
  if (details.reason === 'install') {
    chrome.tabs.create({ url: chrome.runtime.getURL('onboarding.html') });
  }
});

/* ── Badge ── */
// Whichever ceiling is closest to 100 is the one that will stop you, so that is the one
// the badge shows. The prefix says which: S = the 5-hour session, W = the weekly cap
// across all models, otherwise the first letter of the model (O = Opus, F = Fable, …).
// The session only competes when the account has one — Ultra plans and some Team seats
// do not — and the weekly cap always does: it used to be left out, so an account with
// the week spent read S0.
//
// Written against the dynamic weeklyScoped list rather than a named model: the whole
// point of the API's `limits` array is that new models appear without a code change.
// Ties go to the earlier candidate, so the session wins over a weekly cap at the same %.
function bindingLimit(u) {
  const { hasSession } = self.CQMUsage;
  const candidates = [];
  if (hasSession(u)) candidates.push({ key: 'S', pct: u.percent });
  if (Number.isFinite(u.weeklyPercent)) candidates.push({ key: 'W', pct: u.weeklyPercent });
  for (const cat of u.weeklyScoped || []) {
    if (!cat) continue;
    const key = String(cat.name ?? '').trim().charAt(0).toUpperCase() || '?';
    candidates.push({ key, pct: Number.isFinite(cat.percent) ? cat.percent : 0 });
  }
  return candidates.reduce((best, c) => (best && best.pct >= c.pct ? best : c), null);
}

function buildTitle(u) {
  const { hasReading, hasSession } = self.CQMUsage;
  if (!hasReading(u)) return 'Claude Quota Monitor';
  const strip = (s) => s.replace(/\s*\(.*?\)/g, '').trim();
  const s = strip(chrome.i18n.getMessage('session_label') || 'Session');
  const w = strip(chrome.i18n.getMessage('weekly_label')  || 'Weekly');
  const parts = [];
  if (hasSession(u)) parts.push(`${s}: ${u.percent}%`);
  if (Number.isFinite(u.weeklyPercent)) parts.push(`${w}: ${u.weeklyPercent}%`);
  // Categorias por modelo (Fable, Sonnet, Opus, etc.)
  (u.weeklyScoped || []).forEach(cat => {
    if (cat?.name != null) parts.push(`${cat.name}: ${cat.percent ?? 0}%`);
  });
  return parts.join(' · ');
}

function updateBadge(u) {
  if (!self.CQMUsage.hasReading(u)) return;
  const binding = bindingLimit(u);
  if (!binding) return;
  const { key, pct } = binding;
  chrome.action.setBadgeText({ text: `${key}${Math.round(pct)}` });
  chrome.action.setBadgeBackgroundColor({
    color: pct >= 90 ? '#e53e3e' : pct >= 70 ? '#dd6b20' : '#2f855a'
  });
  chrome.action.setTitle({ title: buildTitle(u) });
}

chrome.storage.onChanged.addListener((changes) => {
  if (!changes.claudeUsage) return;
  updateBadge(changes.claudeUsage.newValue);
  // Send straight away rather than waiting for the next push alarm — a reading is
  // never fresher than the moment it lands.
  self.CQMBridge.pushToMac();
});

// Fetch imediato a pedido do popup
chrome.runtime.onMessage.addListener((msg) => {
  if (msg.type === 'FETCH_NOW') fetchUsage();
});
