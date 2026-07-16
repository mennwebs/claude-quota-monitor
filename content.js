/**
 * Duas estratégias de atualização:
 *
 * 1. Polling a cada 3 min (enquanto a aba estiver aberta)
 * 2. MutationObserver — detecta quando uma resposta do Claude termina
 *    e dispara um refresh imediato (~2s de delay)
 *
 * O background.js complementa com um alarme a cada 10 min,
 * sem precisar de aba aberta.
 */

const POLL_MS = 15 * 60 * 1000;

// orgId and plan don't change while the page is open, but were re-fetched every cycle —
// tripling the request count for two constants. Cache them; a reload re-reads both.
let cachedOrgId = null;
let cachedPlan = null;

async function getOrgId() {
  if (cachedOrgId) return cachedOrgId;
  try {
    const res = await fetch('/api/organizations', { credentials: 'include' });
    if (!res.ok) return null;
    const orgs = await res.json();
    cachedOrgId = Array.isArray(orgs) && orgs[0]?.uuid ? orgs[0].uuid : null;
    return cachedOrgId;
  } catch { return null; }
}

async function getPlan(orgId) {
  if (cachedPlan) return cachedPlan;
  try {
    const res = await fetch(`/api/organizations/${orgId}`, { credentials: 'include' });
    if (!res.ok) return null;
    const d = await res.json();
    // rate_limit_tier ex: "default_claude_max_5x", "default_pro", "default_free"
    // capabilities ex: ["claude_max", "chat"]
    cachedPlan = d?.rate_limit_tier ?? d?.capabilities?.[0] ?? d?.plan_nickname ?? d?.plan ?? d?.tier ?? null;
    return cachedPlan;
  } catch { return null; }
}

async function fetchAndStore() {
  const orgId = await getOrgId();
  if (!orgId) return;

  try {
    const res = await fetch(`/api/organizations/${orgId}/usage`, { credentials: 'include' });
    if (!res.ok) return;
    const data = await res.json();

    const session = data.five_hour;
    if (!session) return;

    const plan = await getPlan(orgId);

    // Claude Design weekly quota (internal API field: seven_day_omelette)
    const design = data.seven_day_omelette ?? null;
    const sonnet = data.seven_day_sonnet   ?? null;
    const opus   = data.seven_day_opus     ?? null;
    const extra  = data.extra_usage        ?? null;

    chrome.storage.local.set({
      claudeUsage: {
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
        plan:                 plan ?? null,
        orgId,
        ts: Date.now()
      }
    });
  } catch { /* silencioso */ }
}

/* ── 1. Fetch inicial com retry automático ──────────────────────────────
 * Se o fetch falhar (ex: login ainda em andamento, redirect), tenta
 * novamente com backoff: 3s, 8s, 20s, 60s.
 * Isso cobre o caso de o content script rodar durante o fluxo de login.
 */
const RETRY_DELAYS = [3000, 8000, 20000, 60000];

async function fetchWithRetry(attempt = 0) {
  const orgId = await getOrgId();
  if (orgId) {
    await fetchAndStore();
    // Verifica se os dados foram salvos com sucesso
    const { claudeUsage } = await chrome.storage.local.get('claudeUsage');
    if (claudeUsage?.percent !== undefined) return; // sucesso
  }
  // Falhou — agenda próxima tentativa se ainda houver
  if (attempt < RETRY_DELAYS.length) {
    setTimeout(() => fetchWithRetry(attempt + 1), RETRY_DELAYS[attempt]);
  }
}

fetchWithRetry();
setInterval(fetchAndStore, POLL_MS);

/* ── 2. Detecta fim de resposta do Claude via MutationObserver ──────────
 *
 * Quando o Claude termina de gerar uma resposta, novos elementos aparecem
 * no DOM (botões de ação, próxima mensagem, etc.). Usamos isso como sinal
 * para atualizar a cota, com debounce de 2s para esperar a resposta
 * da API de usage refletir o consumo recente.
 */
let debounceTimer = null;
let lastResponseCount = 0;

function scheduleRefresh() {
  clearTimeout(debounceTimer);
  debounceTimer = setTimeout(fetchAndStore, 2000);
}

function countAssistantNodes() {
  // Conta elementos que indicam mensagens do assistente.
  // Usa seletores amplos para resistir a mudanças de classe no React.
  return document.querySelectorAll(
    '[data-testid*="assistant"], [class*="assistant-message"], ' +
    '[class*="claude-message"], [class*="bot-message"]'
  ).length;
}

const observer = new MutationObserver(() => {
  const current = countAssistantNodes();
  if (current > lastResponseCount) {
    lastResponseCount = current;
    scheduleRefresh();
  }
});

// Aguarda o body existir (content script roda em document_idle, mas por segurança)
const startObserver = () => {
  if (!document.body) { setTimeout(startObserver, 100); return; }
  observer.observe(document.body, { childList: true, subtree: true });
  lastResponseCount = countAssistantNodes();
};

startObserver();
