/* ── Theme ── */
function applyTheme(theme) {
  const btn = document.getElementById('theme-btn');
  if (theme === 'light') {
    document.documentElement.setAttribute('data-theme', 'light');
    if (btn) btn.title = chrome.i18n.getMessage('theme_to_dark') || 'Switch to dark mode';
  } else {
    document.documentElement.removeAttribute('data-theme');
    if (btn) btn.title = chrome.i18n.getMessage('theme_to_light') || 'Switch to light mode';
  }
}

// Load stored theme, fallback to OS preference
chrome.storage.local.get('theme', ({ theme }) => {
  if (theme) {
    applyTheme(theme);
  } else {
    const prefersDark = window.matchMedia('(prefers-color-scheme: dark)').matches;
    applyTheme(prefersDark ? 'dark' : 'light');
  }
});

document.getElementById('theme-btn').addEventListener('click', () => {
  const isLight = document.documentElement.getAttribute('data-theme') === 'light';
  const next = isLight ? 'dark' : 'light';
  applyTheme(next);
  chrome.storage.local.set({ theme: next });
});

/* ── i18n helper ── */
const t = (key) => chrome.i18n.getMessage(key) || key;

function applyI18n() {
  document.querySelectorAll('[data-i18n]').forEach(el => {
    el.textContent = t(el.dataset.i18n);
  });
  document.querySelectorAll('[data-i18n-title]').forEach(el => {
    el.title = t(el.dataset.i18nTitle);
  });
  // Hint de estado vazio (contém link, não pode ser só textContent)
  const hint = document.getElementById('no-data-hint');
  if (hint) hint.innerHTML = t('no_data_hint').replace(
    'claude.ai',
    '<a id="open-claude" href="#">claude.ai</a>'
  );
}

/* ── Formatação de tempo ── */
function fmtReset(isoOrMs) {
  if (!isoOrMs) return '—';
  const ts = typeof isoOrMs === 'number'
    ? (isoOrMs > 1e12 ? isoOrMs : isoOrMs * 1000)
    : Date.parse(isoOrMs);
  if (!ts || isNaN(ts)) return String(isoOrMs);
  const diff = ts - Date.now();
  if (diff <= 0) return t('now');
  const totalMin = Math.floor(diff / 60_000);
  const d = Math.floor(totalMin / 1_440);
  const h = Math.floor((totalMin % 1_440) / 60);
  const m = totalMin % 60;
  const D = t('time_days'), H = t('time_hours'), M = t('time_mins');
  if (d > 0) return `${d}${D} ${h}${H} ${m}${M}`;
  if (h > 0) return `${h}${H} ${m}${M}`;
  return `${m}${M}`;
}

function fmtAgo(ts) {
  if (!ts) return '';
  const prefix = t('updated_ago');
  const s = Math.round((Date.now() - ts) / 1000);
  if (s < 60)  return `${prefix} ${s}s`;
  const m = Math.floor(s / 60);
  if (m < 60)  return `${prefix} ${m}min`;
  const h = Math.floor(m / 60);
  return `${prefix} ${h}h ${m % 60}min`;
}

let lastTs = null;

function tickLastUpdate() {
  document.getElementById('last-update').textContent = fmtAgo(lastTs);
}

setInterval(tickLastUpdate, 1000);

/* ── Barra de progresso ── */
function setBar(barEl, pct) {
  barEl.style.width = `${pct}%`;
  // Preserva todos os modificadores bar--* e reaplica warn/crit conforme o %
  const modifiers = Array.from(barEl.classList).filter(c => c.startsWith('bar--'));
  barEl.className = ['bar', ...modifiers,
    (pct >= 90 ? 'crit' : pct >= 70 ? 'warn' : '')].filter(Boolean).join(' ');
}

/* Cor base de cada categoria por modelo. Nomes conhecidos têm cor fixa; os
 * demais recebem uma cor estável derivada do nome. */
function scopedColor(name) {
  const key = (name || '').toLowerCase();
  const known = {
    fable:  '#2563eb',
    sonnet: '#0e7490',
    opus:   '#7c3aed',
    design: '#6366f1',
    haiku:  '#059669',
  };
  for (const k in known) if (key.includes(k)) return known[k];
  const palette = ['#6366f1', '#0e7490', '#7c3aed', '#b45309', '#059669', '#db2777'];
  let h = 0;
  for (let i = 0; i < key.length; i++) h = (h * 31 + key.charCodeAt(i)) | 0;
  return palette[Math.abs(h) % palette.length];
}

/* ── Formatação monetária ── */
function fmtCurrency(amountCents, currency) {
  try {
    return new Intl.NumberFormat(undefined, {
      style: 'currency', currency, minimumFractionDigits: 2
    }).format(amountCents / 100);
  } catch {
    return `${currency} ${(amountCents / 100).toFixed(2)}`;
  }
}

/* ── Formatação do nome do plano ── */
function formatPlan(raw) {
  if (!raw) return 'Pro';
  const map = {
    // rate_limit_tier values (fonte primária da API)
    'default_claude_max_5x':  'Max (5×)',
    'default_claude_max_20x': 'Max (20×)',
    'default_claude_max':     'Max',
    'default_pro':            'Pro',
    'default_free':           'Free',
    'default_team':           'Team',
    'default_enterprise':     'Enterprise',
    // capabilities[] values (fallback)
    'claude_max':             'Max',
    // valores legados / outros campos
    'free':                   'Free',
    'pro':                    'Pro',
    'max':                    'Max',
    'max_5x':                 'Max (5×)',
    'max_20x':                'Max (20×)',
    'team':                   'Team',
    'enterprise':             'Enterprise',
  };
  const key = raw.toString().toLowerCase().replace(/[\s-]+/g, '_');
  return map[key] ?? raw.toString().split(/[\s_-]/).map(w => w.charAt(0).toUpperCase() + w.slice(1)).join(' ');
}

/* ── Categorias semanais por modelo (dinâmicas) ── */
function renderScopedCategories(scoped) {
  const container = document.getElementById('weekly-scoped-container');
  container.textContent = ''; // limpa antes de reconstruir
  scoped.forEach(cat => {
    const pct = Math.min(100, Math.max(0, cat.percent ?? 0));

    const wrap = document.createElement('div');
    wrap.className = 'weekly-category';

    const divider = document.createElement('div');
    divider.className = 'weekly-cat-divider';

    const label = document.createElement('div');
    label.className = 'weekly-cat-label';
    label.textContent = cat.name;

    const barWrap = document.createElement('div');
    barWrap.className = 'bar-wrapper bar-wrapper--sm';
    const bar = document.createElement('div');
    bar.className = 'bar bar--sm bar--scoped';
    bar.style.setProperty('--bar-base', scopedColor(cat.name));
    barWrap.appendChild(bar);

    const meta = document.createElement('div');
    meta.className = 'bar-meta';
    const pctSpan = document.createElement('span');
    pctSpan.className = 'weekly-scoped-pct';
    pctSpan.textContent = `${pct}% ${t('used_suffix')}`;
    const resetSpan = document.createElement('span');
    resetSpan.className = 'muted weekly-scoped-reset';
    resetSpan.textContent = cat.resetAt ? `${t('resets_in')} ${fmtReset(cat.resetAt)}` : '';
    meta.append(pctSpan, resetSpan);

    wrap.append(divider, label, barWrap, meta);
    container.appendChild(wrap);
    setBar(bar, pct); // aplica largura + warn/crit
  });
}

/* ── Renderização ── */
function render(u) {
  const hasData = u?.percent !== undefined;
  document.getElementById('data-section').classList.toggle('hidden', !hasData);
  document.getElementById('empty-section').classList.toggle('hidden', hasData);
  if (!hasData) return;

  document.getElementById('plan').textContent = formatPlan(u.plan);

  const pct = Math.min(100, Math.max(0, u.percent));
  setBar(document.getElementById('bar'), pct);
  document.getElementById('pct-text').textContent = `${pct}%`;
  document.getElementById('reset-text').textContent = fmtReset(u.resetAt);

  const weeklyRow = document.getElementById('weekly-row');
  if (u.weeklyPercent !== undefined) {
    weeklyRow.classList.remove('hidden');

    // Todos os modelos
    const wp = Math.min(100, Math.max(0, u.weeklyPercent));
    const barW = document.getElementById('bar-weekly');
    barW.classList.add('bar--sm');
    setBar(barW, wp);
    document.getElementById('weekly-pct-text').textContent = `${wp}% ${t('used_suffix')}`;
    document.getElementById('weekly-reset-text').textContent =
      `${t('resets_in')} ${fmtReset(u.weeklyResetAt)}`;

    // Categorias por modelo (dinâmicas)
    renderScopedCategories(u.weeklyScoped || []);
  } else {
    weeklyRow.classList.add('hidden');
  }

  // Créditos de uso
  const extraRow = document.getElementById('extra-usage-row');
  if (u.extraUsageEnabled && u.extraUsageLimit > 0) {
    extraRow.classList.remove('hidden');
    const ep = u.extraUsageLimit > 0
      ? Math.min(100, Math.round((u.extraUsageUsed / u.extraUsageLimit) * 100))
      : 0;
    const barE = document.getElementById('bar-extra-usage');
    barE.classList.add('bar--sm', 'bar--extra');
    setBar(barE, ep);
    const cur = u.extraUsageCurrency || 'USD';
    document.getElementById('extra-usage-amount-text').textContent =
      `${fmtCurrency(u.extraUsageUsed, cur)} ${t('used_suffix')}`;
    document.getElementById('extra-usage-limit-text').textContent =
      `${t('extra_usage_limit')} ${fmtCurrency(u.extraUsageLimit, cur)}`;
  } else {
    extraRow.classList.add('hidden');
  }

  lastTs = u.ts ?? null;
  tickLastUpdate();
}

/* ── Init ── */
applyI18n();
chrome.storage.local.get('claudeUsage', ({ claudeUsage }) => {
  render(claudeUsage ?? null);

  // Sem dados: tenta buscar agora e fica verificando a cada 3s
  if (!claudeUsage?.percent) {
    chrome.runtime.sendMessage({ type: 'FETCH_NOW' });

    const poll = setInterval(() => {
      chrome.storage.local.get('claudeUsage', ({ claudeUsage: u }) => {
        if (u?.percent !== undefined) {
          render(u);
          clearInterval(poll);
        }
      });
    }, 3000);
  }
});

chrome.storage.onChanged.addListener((changes) => {
  if (changes.claudeUsage) render(changes.claudeUsage.newValue ?? null);
});

/* ── Botões ── */
document.getElementById('refresh-btn').addEventListener('click', () => {
  chrome.tabs.create({ url: 'https://claude.ai/settings/usage' });
});

document.getElementById('donate-btn').addEventListener('click', () => {
  chrome.tabs.create({ url: 'https://ko-fi.com/claudequotamonitor' });
});

document.addEventListener('click', (e) => {
  if (e.target.id === 'open-claude') {
    e.preventDefault();
    chrome.tabs.create({ url: 'https://claude.ai' });
  }
});

document.getElementById('site-btn').addEventListener('click', (e) => {
  e.preventDefault();
  chrome.tabs.create({ url: 'https://claudequotamonitor.github.io' });
});

/* ── Créditos de uso: recolhível ── */
(function initExtraUsageToggle() {
  chrome.storage.local.get('extraUsageCollapsed', ({ extraUsageCollapsed }) => {
    if (extraUsageCollapsed) {
      document.getElementById('extra-usage-row').classList.add('collapsed');
    }
  });
})();

document.getElementById('extra-usage-toggle').addEventListener('click', () => {
  const row = document.getElementById('extra-usage-row');
  const collapsed = row.classList.toggle('collapsed');
  chrome.storage.local.set({ extraUsageCollapsed: collapsed });
});

/* ── Review / Rating ── */
const CWS_REVIEW_URL          = 'https://chromewebstore.google.com/detail/claude-quota-monitor/gpeogkjjkpmdjgggeaegmnmlmikgkjjm/reviews';
const REVIEW_FIRST_THRESHOLD  = 10;
const REVIEW_SNOOZE_INCREMENT = 20;

(function initReview() {
  chrome.storage.local.get(['reviewState', 'openCount', 'snoozeThreshold', 'starDismissed'], (data) => {
    const state          = data.reviewState  || 'pending';
    const starDismissed  = data.starDismissed || false;
    const newCount       = (data.openCount   || 0) + 1;
    const threshold      = data.snoozeThreshold || REVIEW_FIRST_THRESHOLD;

    chrome.storage.local.set({ openCount: newCount });

    // Star button: hide when rated, star dismissed, or chip permanently dismissed
    if (state === 'done' || starDismissed) {
      document.getElementById('review-star-btn').closest('.review-star-wrap').classList.add('hidden');
    }

    // Chip: show when threshold reached and chip not dismissed/done
    if ((state === 'pending' || state === 'snoozed') && newCount >= threshold) {
      document.getElementById('review-chip').classList.remove('hidden');
    }
  });
})();

function openReviewPage() {
  chrome.tabs.create({ url: CWS_REVIEW_URL });
}

function hideStarBtn() {
  document.getElementById('review-star-btn').closest('.review-star-wrap').classList.add('hidden');
}

document.getElementById('review-btn-rate').addEventListener('click', () => {
  openReviewPage();
  // Marks both as done — chip and star both go away
  chrome.storage.local.set({ reviewState: 'done', starDismissed: true });
  document.getElementById('review-chip').classList.add('hidden');
  hideStarBtn();
});

document.getElementById('review-btn-later').addEventListener('click', () => {
  chrome.storage.local.get(['openCount'], (data) => {
    const newThreshold = (data.openCount || 0) + REVIEW_SNOOZE_INCREMENT;
    chrome.storage.local.set({ reviewState: 'snoozed', snoozeThreshold: newThreshold });
  });
  // Only hides chip — star is unaffected
  document.getElementById('review-chip').classList.add('hidden');
});

document.getElementById('review-btn-never').addEventListener('click', () => {
  // Only dismisses chip — star is unaffected
  chrome.storage.local.set({ reviewState: 'dismissed' });
  document.getElementById('review-chip').classList.add('hidden');
});

document.getElementById('review-dismiss-btn').addEventListener('click', () => {
  // Only dismisses star — chip state is unaffected
  chrome.storage.local.set({ starDismissed: true });
  hideStarBtn();
});

document.getElementById('review-star-btn').addEventListener('click', () => {
  openReviewPage();
  // Marks both as done — chip and star both go away
  chrome.storage.local.set({ reviewState: 'done', starDismissed: true });
  document.getElementById('review-chip').classList.add('hidden');
  hideStarBtn();
});

const syncBtn = document.getElementById('sync-btn');
syncBtn.addEventListener('click', () => {
  syncBtn.classList.add('spinning');
  chrome.runtime.sendMessage({ type: 'FETCH_NOW' });
});

chrome.storage.onChanged.addListener((changes) => {
  if (changes.claudeUsage) syncBtn.classList.remove('spinning');
});
