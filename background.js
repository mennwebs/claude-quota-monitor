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
importScripts('bridge.js');

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

  try {
    const res = await fetch(
      `https://claude.ai/api/organizations/${orgId}/usage`,
      { credentials: 'include' }
    );
    if (!res.ok) return;
    const data = await res.json();

    const session = data.five_hour;
    if (!session) return;

    // Claude Design weekly quota (internal API field: seven_day_omelette)
    const design = data.seven_day_omelette ?? null;
    const sonnet = data.seven_day_sonnet   ?? null;
    const opus   = data.seven_day_opus     ?? null;
    const extra  = data.extra_usage        ?? null;

    // Plan only changes on an upgrade/downgrade, so fetch it once and reuse it — this is
    // half the request volume. Clear claudeUsage.plan from storage to force a re-read.
    const plan = claudeUsage?.plan ?? await fetchPlan(orgId);

    chrome.storage.local.set({
      claudeUsage: {
        ...claudeUsage,
        percent:              session.utilization,
        resetAt:              session.resets_at,
        weeklyPercent:        data.seven_day?.utilization,
        weeklyResetAt:        data.seven_day?.resets_at,
        sonnetWeeklyPercent:  sonnet?.utilization,
        sonnetWeeklyResetAt:  sonnet?.resets_at,
        opusWeeklyPercent:    opus?.utilization,
        opusWeeklyResetAt:    opus?.resets_at,
        designWeeklyPercent:  design?.utilization,
        designWeeklyResetAt:  design?.resets_at,
        extraUsageEnabled:    extra?.is_enabled  ?? false,
        extraUsageUsed:       extra?.used_credits ?? 0,
        extraUsageLimit:      extra?.monthly_limit ?? 0,
        extraUsageCurrency:   extra?.currency ?? null,
        ...(plan ? { plan } : {}),
        ts: Date.now()
      }
    });
  } catch { /* sem conexão ou sessão expirada */ }
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
// Weekly Opus is a separate ceiling that can block before the 5h session does, so the
// badge tracks whichever is closer to 100. Prefix says which: S = session, O = Opus.
// opusWeeklyPercent is undefined on plans without a separate Opus limit.
function bindingLimit(u) {
  const opus = u.opusWeeklyPercent;
  return opus !== undefined && opus > u.percent
    ? { key: 'O', pct: opus }
    : { key: 'S', pct: u.percent };
}

function buildTitle(u) {
  if (!u || u.percent === undefined) return 'Claude Quota Monitor';
  const strip = (s) => s.replace(/\s*\(.*?\)/g, '').trim();
  const s = strip(chrome.i18n.getMessage('session_label') || 'Session');
  const w = strip(chrome.i18n.getMessage('weekly_label')  || 'Weekly');
  const o = strip(chrome.i18n.getMessage('weekly_opus')   || 'Only Opus');
  const d =       chrome.i18n.getMessage('weekly_design') || 'Claude Design';
  let title = `${s}: ${u.percent}%`;
  if (u.weeklyPercent       !== undefined) title += ` · ${w}: ${u.weeklyPercent}%`;
  if (u.opusWeeklyPercent   !== undefined) title += ` · ${o}: ${u.opusWeeklyPercent}%`;
  if (u.designWeeklyPercent !== undefined) title += ` · ${d}: ${u.designWeeklyPercent}%`;
  return title;
}

function updateBadge(u) {
  if (u?.percent === undefined) return;
  const { key, pct } = bindingLimit(u);
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
