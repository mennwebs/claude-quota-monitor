/**
 * Suite: Popup rendering
 * Testa estados do popup com diferentes combinações de dados.
 */

const { openPopup } = require('./helpers');

// Dados de exemplo para testes
const FULL_DATA = {
  claudeUsage: {
    percent:       32,
    resetAt:       new Date(Date.now() + 2 * 3_600_000 + 14 * 60_000).toISOString(),
    weeklyPercent: 31,
    weeklyResetAt: new Date(Date.now() + 89 * 3_600_000).toISOString(),
    weeklyScoped: [
      { name: 'Fable', percent: 48,
        resetAt: new Date(Date.now() + 113 * 3_600_000).toISOString() },
    ],
    plan:          'pro',
    ts:            Date.now()
  }
};

const NO_SCOPED_DATA = {
  claudeUsage: {
    percent:       22,
    resetAt:       new Date(Date.now() + 3_600_000).toISOString(),
    weeklyPercent: 10,
    weeklyResetAt: new Date(Date.now() + 50 * 3_600_000).toISOString(),
    weeklyScoped:  [],
    plan:          'pro',
    ts:            Date.now()
  }
};

const WARN_DATA = {
  claudeUsage: {
    percent:  75,
    resetAt:  new Date(Date.now() + 3_600_000).toISOString(),
    plan:     'pro',
    ts:       Date.now()
  }
};

const CRIT_DATA = {
  claudeUsage: {
    percent:  92,
    resetAt:  new Date(Date.now() + 3_600_000).toISOString(),
    plan:     'pro',
    ts:       Date.now()
  }
};

module.exports = async function(describe) {

  // ── 1. Estado vazio ──────────────────────────────────────────────────────
  await describe('Empty state (no data)', async (assert) => {
    const { browser, page } = await openPopup({});
    try {
      const emptyVisible = await page.$eval('#empty-section',
        el => !el.classList.contains('hidden'));
      assert(emptyVisible, 'Empty section is visible');

      const dataHidden = await page.$eval('#data-section',
        el => el.classList.contains('hidden'));
      assert(dataHidden, 'Data section is hidden');
    } finally { await browser.close(); }
  });

  // ── 2. Dados completos ───────────────────────────────────────────────────
  await describe('Full data (session + weekly + scoped model)', async (assert) => {
    const { browser, page } = await openPopup(FULL_DATA);
    try {
      const dataVisible = await page.$eval('#data-section',
        el => !el.classList.contains('hidden'));
      assert(dataVisible, 'Data section is visible');

      const pct = await page.$eval('#pct-text', el => el.textContent);
      assert(pct === '32%', `Session pct shows 32% (got "${pct}")`);

      const plan = await page.$eval('#plan', el => el.textContent);
      assert(plan === 'Pro', `Plan badge shows "Pro" (got "${plan}")`);

      const weeklyVisible = await page.$eval('#weekly-row',
        el => !el.classList.contains('hidden'));
      assert(weeklyVisible, 'Weekly row is visible');

      const weeklyPct = await page.$eval('#weekly-pct-text', el => el.textContent);
      assert(weeklyPct.includes('31%'), `Weekly pct includes 31% (got "${weeklyPct}")`);

      // Categoria por modelo (Fable) injetada dinamicamente
      const scopedCount = await page.$eval('#weekly-scoped-container',
        el => el.querySelectorAll('.weekly-category').length);
      assert(scopedCount === 1, `One scoped category rendered (got ${scopedCount})`);

      const scopedLabel = await page.$eval('#weekly-scoped-container .weekly-cat-label',
        el => el.textContent);
      assert(scopedLabel === 'Fable', `Scoped label shows "Fable" (got "${scopedLabel}")`);

      const scopedPct = await page.$eval('#weekly-scoped-container .weekly-scoped-pct',
        el => el.textContent);
      assert(scopedPct.includes('48%'), `Scoped pct includes 48% (got "${scopedPct}")`);
    } finally { await browser.close(); }
  });

  // ── 3. Sem categorias por modelo ─────────────────────────────────────────
  await describe('Weekly data without scoped models', async (assert) => {
    const { browser, page } = await openPopup(NO_SCOPED_DATA);
    try {
      const weeklyVisible = await page.$eval('#weekly-row',
        el => !el.classList.contains('hidden'));
      assert(weeklyVisible, 'Weekly row is visible');

      const scopedCount = await page.$eval('#weekly-scoped-container',
        el => el.querySelectorAll('.weekly-category').length);
      assert(scopedCount === 0, `No scoped categories when array is empty (got ${scopedCount})`);
    } finally { await browser.close(); }
  });

  // ── 4. Cor da barra — warn (70–89%) ─────────────────────────────────────
  await describe('Progress bar color — warn (75%)', async (assert) => {
    const { browser, page } = await openPopup(WARN_DATA);
    try {
      const hasWarn = await page.$eval('#bar',
        el => el.classList.contains('warn'));
      assert(hasWarn, 'Bar has "warn" class at 75%');

      const hasCrit = await page.$eval('#bar',
        el => el.classList.contains('crit'));
      assert(!hasCrit, 'Bar does NOT have "crit" class at 75%');
    } finally { await browser.close(); }
  });

  // ── 5. Cor da barra — crit (≥90%) ───────────────────────────────────────
  await describe('Progress bar color — crit (92%)', async (assert) => {
    const { browser, page } = await openPopup(CRIT_DATA);
    try {
      const hasCrit = await page.$eval('#bar',
        el => el.classList.contains('crit'));
      assert(hasCrit, 'Bar has "crit" class at 92%');
    } finally { await browser.close(); }
  });

  // ── 6. i18n strings aplicadas ───────────────────────────────────────────
  await describe('i18n strings', async (assert) => {
    const { browser, page } = await openPopup(FULL_DATA);
    try {
      const sessionLabel = await page.$eval(
        '[data-i18n="session_label"]', el => el.textContent);
      assert(sessionLabel === 'Current session (5h)',
        `session_label translated (got "${sessionLabel}")`);

      const weeklyLabel = await page.$eval(
        '[data-i18n="weekly_label"]', el => el.textContent);
      assert(weeklyLabel === 'Weekly (7 days)',
        `weekly_label translated (got "${weeklyLabel}")`);

      const allModels = await page.$eval(
        '[data-i18n="weekly_all_models"]', el => el.textContent);
      assert(allModels === 'All models',
        `weekly_all_models translated (got "${allModels}")`);
    } finally { await browser.close(); }
  });

};
