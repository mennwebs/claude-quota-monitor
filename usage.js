/**
 * Reading claude.ai's `/usage` document — shared by the service worker (importScripts)
 * and the content script (listed ahead of content.js in the manifest), so the two can
 * no longer disagree about what a usable response looks like.
 *
 * Also loadable in plain Node: it publishes onto `self` and does nothing else on load.
 */
'use strict';

(function (root) {
  const STATUS_KEY = 'usageFetchStatus';

  /* Per-model weekly ceilings from the `limits` array, falling back to the legacy
   * seven_day_* fields. */
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

  /**
   * The fields of `claudeUsage` that come out of one `/usage` response, or null when the
   * response says nothing about any limit.
   *
   * `five_hour` is allowed to be missing. With the weekly cap spent there is no live
   * 5-hour window, and the API has answered `five_hour: null` for exactly that — which
   * this code used to treat as "nothing to report" and silently drop, freezing the
   * profile on its last reading for as long as the cap lasted. No window means no
   * session usage: 0% with no reset time, which is what the panel already shows for an
   * idle window.
   */
  function parseUsage(data) {
    if (!data || typeof data !== 'object') return null;

    const session = data.five_hour ?? null;
    // A `limits` array only counts when it carries a ceiling this code reads; one that
    // holds other kinds alone would otherwise pass as "0% used" with a fresh timestamp.
    const hasLimits = !!session || !!data.seven_day ||
      (Array.isArray(data.limits) && data.limits.some(l => l?.kind === 'weekly_scoped'));
    if (!hasLimits) return null;

    const extra = data.extra_usage ?? null;
    return {
      percent:            session?.utilization ?? 0,
      resetAt:            session?.resets_at ?? null,
      weeklyPercent:      data.seven_day?.utilization,
      weeklyResetAt:      data.seven_day?.resets_at,
      weeklyScoped:       extractWeeklyScoped(data),
      extraUsageEnabled:  extra?.is_enabled   ?? false,
      extraUsageUsed:     extra?.used_credits ?? 0,
      extraUsageLimit:    extra?.monthly_limit ?? 0,
      extraUsageCurrency: extra?.currency ?? null
    };
  }

  /**
   * Leave a note of how the last fetch went. Every early return in the fetchers used to
   * be silent, so a profile that stopped updating looked exactly like one that had
   * nothing new — the popup could only say "updated 24h ago" and not why.
   */
  async function recordFetch(ok, reason) {
    try {
      await chrome.storage.local.set({
        [STATUS_KEY]: { ok, reason: ok ? null : reason, at: Date.now() }
      });
    } catch { /* a diagnostic must never break the fetch it is describing */ }
  }

  root.CQMUsage = { STATUS_KEY, extractWeeklyScoped, parseUsage, recordFetch };
})(typeof self !== 'undefined' ? self : globalThis);
