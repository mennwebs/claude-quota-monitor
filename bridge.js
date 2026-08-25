/**
 * Mac bridge — pushes the quota this extension already reads to a menu bar app
 * listening on loopback.
 *
 * Why loopback and not native messaging: a native host manifest has to be installed
 * into every Chromium data directory separately and pinned to an extension ID that
 * differs per browser. One port serves every profile with one manifest change here.
 *
 * Nothing is sent anywhere except 127.0.0.1, and only once the user has entered the
 * app's token — with no token configured this file makes no requests at all.
 *
 * Loaded via importScripts() from background.js and exposed on `self.CQMBridge`,
 * which also lets the test suite exercise the pure functions in plain Node.
 */
'use strict';

(function (root) {
  const LOOPBACK_ORIGIN = 'http://127.0.0.1/*';
  const CONFIG_KEY = 'macBridge';
  const STATUS_KEY = 'macBridgeStatus';
  const ACCOUNT_KEY = 'macBridgeAccount';
  const ACCOUNT_TTL_MS = 24 * 60 * 60 * 1000;
  // An identity that named neither an account nor an email is a failed probe, not a
  // result. Keep it so there is a coarse key to fall back on, but retry sooner than a day.
  const ACCOUNT_RETRY_MS = 30 * 60 * 1000;

  const DEFAULTS = { enabled: false, port: 47821, token: '', profileName: '' };

  /* ── Pure helpers (unit-tested) ─────────────────────────────────────────── */

  /**
   * claude.ai returns reset times as ISO strings, the local statusline as unix
   * seconds, and older builds as millisecond epochs. Normalize to seconds so the
   * app never has to guess.
   */
  function toEpochSeconds(value) {
    if (value === null || value === undefined || value === '') return null;
    if (typeof value === 'number') {
      if (!Number.isFinite(value) || value <= 0) return null;
      return Math.floor(value > 1e12 ? value / 1000 : value);
    }
    const asNumber = Number(value);
    if (!Number.isNaN(asNumber) && String(value).trim() !== '') return toEpochSeconds(asNumber);
    const parsed = Date.parse(value);
    return Number.isNaN(parsed) ? null : Math.floor(parsed / 1000);
  }

  /**
   * A model display name becomes a stable wire key. claude.ai hands back human names
   * ("Claude Design", "Opus"); the app needs something it can match on across reports
   * even if the capitalisation or spacing changes.
   */
  function slugModel(name) {
    return String(name ?? '')
      .toLowerCase()
      .replace(/[^a-z0-9]+/g, '-')
      .replace(/^-+|-+$/g, '')
      .slice(0, 32);
  }

  /**
   * Per-model weekly caps. Since extension 1.7.2 these arrive as a dynamic list, because
   * the API moved them out of the fixed `seven_day_*` fields — which now return null. The
   * legacy fields are still read so an older profile on the same machine keeps reporting.
   */
  function weeklyCategories(usage) {
    if (Array.isArray(usage.weeklyScoped) && usage.weeklyScoped.length) {
      return usage.weeklyScoped
        .filter((c) => c && c.name)
        .map((c) => ({ name: c.name, percent: c.percent, resetAt: c.resetAt }));
    }
    return [
      ['Opus', usage.opusWeeklyPercent, usage.opusWeeklyResetAt],
      ['Sonnet', usage.sonnetWeeklyPercent, usage.sonnetWeeklyResetAt],
      ['Design', usage.designWeeklyPercent, usage.designWeeklyResetAt]
    ]
      .filter(([, pct]) => pct !== undefined && pct !== null)
      .map(([name, percent, resetAt]) => ({ name, percent, resetAt }));
  }

  function detectBrowser(ua, brands) {
    const names = (brands || []).map(b => b.brand).join(' ');
    if (/Brave/i.test(names)) return 'Brave';
    if (/Edge/i.test(names) || /Edg\//.test(ua || '')) return 'Edge';
    if (/Opera|OPR/i.test(names) || /OPR\//.test(ua || '')) return 'Opera';
    if (/Vivaldi/i.test(ua || '')) return 'Vivaldi';
    if (/Arc/i.test(names)) return 'Arc';
    return 'Chrome';
  }

  /**
   * Maps the extension's stored shape onto the app's wire format. Returns null when
   * there is not a single usable limit — an empty report is worse than no report,
   * because it would refresh the row's timestamp without refreshing its numbers.
   */
  function buildPayload(usage, account, profileName, browser, nowMs) {
    if (!usage) return null;

    const limits = {};
    const put = (key, pct, resetsAt, label) => {
      const n = Number(pct);
      if (pct === undefined || pct === null || !Number.isFinite(n)) return;
      limits[key] = { pct: n, resetsAt: toEpochSeconds(resetsAt) };
      if (label) limits[key].label = label;
    };

    put('five_hour', usage.percent, usage.resetAt);
    put('seven_day', usage.weeklyPercent, usage.weeklyResetAt);

    // Open-ended by design: whatever models the API reports this week get sent, keyed by
    // slug and carrying the name to display. A new model needs no change on either side.
    for (const cat of weeklyCategories(usage)) {
      const slug = slugModel(cat.name);
      if (slug) put(`weekly:${slug}`, cat.percent, cat.resetAt, String(cat.name).trim());
    }

    if (Object.keys(limits).length === 0) return null;

    const payload = {
      v: 1,
      source: 'extension',
      browser: (profileName || '').trim() || browser,
      account: {
        uuid: account?.uuid ?? null,
        email: account?.email ?? null,
        orgId: usage.orgId ?? account?.orgId ?? null,
        orgName: account?.orgName ?? null,
        plan: usage.plan ?? account?.plan ?? null
      },
      observedAt: toEpochSeconds(usage.ts ?? nowMs),
      limits
    };

    if (usage.extraUsageEnabled !== undefined) {
      payload.extra = {
        enabled: !!usage.extraUsageEnabled,
        used: Number(usage.extraUsageUsed) || 0,
        limit: Number(usage.extraUsageLimit) || 0,
        currency: usage.extraUsageCurrency ?? null
      };
    }
    return payload;
  }

  /* ── Chrome-dependent parts ─────────────────────────────────────────────── */

  async function getConfig() {
    const stored = (await chrome.storage.local.get(CONFIG_KEY))[CONFIG_KEY];
    return { ...DEFAULTS, ...(stored || {}) };
  }

  async function setConfig(patch) {
    const next = { ...(await getConfig()), ...patch };
    await chrome.storage.local.set({ [CONFIG_KEY]: next });
    return next;
  }

  async function hasLoopbackPermission() {
    try {
      return await chrome.permissions.contains({ origins: [LOOPBACK_ORIGIN] });
    } catch { return false; }
  }

  async function requestLoopbackPermission() {
    try {
      return await chrome.permissions.request({ origins: [LOOPBACK_ORIGIN] });
    } catch { return false; }
  }

  async function fetchJSON(path) {
    try {
      const res = await fetch('https://claude.ai' + path, { credentials: 'include' });
      if (!res.ok) return null;
      return await res.json();
    } catch { return null; }
  }

  /**
   * Which account is this profile logged into?
   *
   * Keyed on the account rather than the org on purpose: several accounts can belong
   * to the same Team organization, and keying on org would collapse them into one row.
   * The endpoint that answers this has moved around, so try the known shapes in turn
   * and fall back to the organization — a coarse key still beats no key.
   */
  async function probeAccount() {
    for (const path of ['/api/bootstrap', '/api/account', '/api/auth/current_account']) {
      const data = await fetchJSON(path);
      const a = data?.account ?? data;
      if (!a || typeof a !== 'object') continue;
      const uuid = a.uuid ?? a.id ?? a.account_uuid ?? null;
      const email = a.email_address ?? a.email ?? null;
      if (uuid || email) return { uuid, email: email ? String(email).toLowerCase() : null };
    }
    return null;
  }

  async function probeOrg(orgId) {
    if (!orgId) {
      const orgs = await fetchJSON('/api/organizations');
      const first = Array.isArray(orgs) ? orgs[0] : null;
      return first ? { orgId: first.uuid ?? null, orgName: first.name ?? null } : null;
    }
    const org = await fetchJSON(`/api/organizations/${orgId}`);
    return { orgId, orgName: org?.name ?? null };
  }

  /** Identity changes only on logout, so a complete one is cached for a day. */
  async function getAccount(orgId, { force = false } = {}) {
    const cached = (await chrome.storage.local.get(ACCOUNT_KEY))[ACCOUNT_KEY];
    if (!force && isCacheUsable(cached, orgId)) return cached;

    const account = (await probeAccount()) || {};
    const org = (await probeOrg(orgId)) || {};
    const merged = { ...account, ...org, ts: Date.now() };
    if (merged.uuid || merged.email || merged.orgId) {
      await chrome.storage.local.set({ [ACCOUNT_KEY]: merged });
      return merged;
    }
    return cached || null;
  }

  /**
   * Reusable only if it belongs to the same org *and* actually identified the account.
   * Comparing against `orgId ?? cached.orgId` would compare a value with itself whenever
   * the caller has no org — a condition that is always true and never invalidates.
   */
  function isCacheUsable(cached, orgId) {
    if (!cached) return false;
    if (orgId && cached.orgId !== orgId) return false;
    const complete = !!(cached.uuid || cached.email);
    return Date.now() - (cached.ts || 0) < (complete ? ACCOUNT_TTL_MS : ACCOUNT_RETRY_MS);
  }

  async function setStatus(status) {
    await chrome.storage.local.set({ [STATUS_KEY]: { ...status, at: Date.now() } });
    return status;
  }

  /**
   * Send the cached reading to the app. This costs nothing on claude.ai's side — it
   * re-sends what we already have — which is why it can run every minute while the
   * actual quota fetch stays on its slow poll. The app therefore catches up within a
   * minute of launching instead of waiting for the next real fetch.
   *
   * The reply may ask for a real refresh; that is the only way the Mac side can reach
   * back into the browser.
   */
  async function pushToMac() {
    const cfg = await getConfig();
    if (!cfg.enabled || !cfg.token) return { ok: false, reason: 'not-configured' };
    if (!(await hasLoopbackPermission())) return setStatus({ ok: false, reason: 'no-permission' });

    const { claudeUsage } = await chrome.storage.local.get('claudeUsage');
    if (!claudeUsage) return setStatus({ ok: false, reason: 'no-data' });

    const account = await getAccount(claudeUsage.orgId);
    const payload = buildPayload(
      claudeUsage, account, cfg.profileName,
      detectBrowser(navigator.userAgent, navigator.userAgentData?.brands), Date.now()
    );
    if (!payload) return setStatus({ ok: false, reason: 'no-limits' });

    try {
      const res = await fetch(`http://127.0.0.1:${cfg.port}/v1/usage`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', 'X-CQM-Token': cfg.token },
        body: JSON.stringify(payload)
      });
      const body = await res.json().catch(() => ({}));
      if (!res.ok) {
        return setStatus({ ok: false, reason: res.status === 401 ? 'bad-token' : `http-${res.status}` });
      }
      await setStatus({ ok: true, reason: null });
      return { ok: true, refresh: !!body.refresh };
    } catch {
      // The app being closed is the normal case, not an error worth retrying harder.
      return setStatus({ ok: false, reason: 'app-not-running' });
    }
  }

  /** Used by the options page to tell "app is closed" from "token is wrong". */
  async function checkHealth(port) {
    if (!(await hasLoopbackPermission())) return { reachable: false, reason: 'no-permission' };
    try {
      const res = await fetch(`http://127.0.0.1:${port}/v1/health`, { cache: 'no-store' });
      const body = await res.json().catch(() => ({}));
      return { reachable: res.ok && body.app === 'claude-quota-mac', reason: null };
    } catch {
      return { reachable: false, reason: 'app-not-running' };
    }
  }

  root.CQMBridge = {
    DEFAULTS, LOOPBACK_ORIGIN, CONFIG_KEY, STATUS_KEY, ACCOUNT_KEY,
    toEpochSeconds, detectBrowser, buildPayload, isCacheUsable, slugModel, weeklyCategories,
    getConfig, setConfig, getAccount,
    hasLoopbackPermission, requestLoopbackPermission,
    pushToMac, checkHealth
  };
})(typeof self !== 'undefined' ? self : globalThis);
