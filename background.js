/**
 * Service worker
 *
 * - Polling via chrome.alarms a cada 10 min (sem aba aberta necessária)
 * - Restaura o badge ao reiniciar
 * - Atualiza o badge sempre que o storage mudar
 */

const ALARM = 'quota-poll';
const POLL_MINUTES = 10;

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

/* Extrai categorias semanais por modelo do array `limits`, com fallback para
 * os campos legados seven_day_*. Mesma lógica do content.js. */
function extractWeeklyScoped(data) {
  if (Array.isArray(data.limits) && data.limits.length) {
    return data.limits
      .filter(l => l.kind === 'weekly_scoped' && l.scope?.model?.display_name)
      .map(l => ({
        name:    l.scope.model.display_name,
        percent: l.percent ?? 0,
        resetAt: l.resets_at ?? null
      }));
  }
  return [
    ['Sonnet', data.seven_day_sonnet],
    ['Opus',   data.seven_day_opus],
    ['Design', data.seven_day_omelette],
  ].filter(([, v]) => v).map(([name, v]) => ({
    name, percent: v.utilization ?? 0, resetAt: v.resets_at ?? null
  }));
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

    const extra = data.extra_usage ?? null;
    const weeklyScoped = extractWeeklyScoped(data);

    // Re-busca o plano para refletir upgrades/downgrades sem precisar abrir claude.ai
    const plan = await fetchPlan(orgId);

    chrome.storage.local.set({
      claudeUsage: {
        ...claudeUsage,
        percent:              session.utilization,
        resetAt:              session.resets_at,
        weeklyPercent:        data.seven_day?.utilization,
        weeklyResetAt:        data.seven_day?.resets_at,
        weeklyScoped,
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

/* ── Alarme periódico ── */
chrome.alarms.create(ALARM, { periodInMinutes: POLL_MINUTES });
chrome.alarms.onAlarm.addListener((alarm) => {
  if (alarm.name === ALARM) fetchUsage();
});

/* ── Restaura badge e dispara fetch ao iniciar ── */
function restoreAndRefresh() {
  chrome.storage.local.get('claudeUsage', ({ claudeUsage }) => {
    updateBadge(claudeUsage);
    fetchUsage(); // atualiza logo ao abrir o navegador
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
function buildTitle(u) {
  if (!u || u.percent === undefined) return 'Claude Quota Monitor';
  const strip = (s) => s.replace(/\s*\(.*?\)/g, '').trim();
  const s = strip(chrome.i18n.getMessage('session_label') || 'Session');
  const w = strip(chrome.i18n.getMessage('weekly_label')  || 'Weekly');
  let title = `${s}: ${u.percent}%`;
  if (u.weeklyPercent !== undefined) title += ` · ${w}: ${u.weeklyPercent}%`;
  // Categorias por modelo (Fable, Sonnet, Opus, etc.)
  (u.weeklyScoped || []).forEach(cat => {
    if (cat?.name != null) title += ` · ${cat.name}: ${cat.percent ?? 0}%`;
  });
  return title;
}

function updateBadge(u) {
  if (!u?.percent === undefined) return;
  const pct = u.percent;
  chrome.action.setBadgeText({ text: `${pct}%` });
  chrome.action.setBadgeBackgroundColor({
    color: pct >= 90 ? '#e53e3e' : pct >= 70 ? '#dd6b20' : '#2f855a'
  });
  chrome.action.setTitle({ title: buildTitle(u) });
}

chrome.storage.onChanged.addListener((changes) => {
  if (changes.claudeUsage) updateBadge(changes.claudeUsage.newValue);
});

// Fetch imediato a pedido do popup
chrome.runtime.onMessage.addListener((msg) => {
  if (msg.type === 'FETCH_NOW') fetchUsage();
});
