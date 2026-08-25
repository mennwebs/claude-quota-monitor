/**
 * Suite: Mac bridge
 *
 * bridge.js is written as a classic script that publishes onto `self`, so the pure
 * functions can be loaded here for real instead of being copied — no duplicate
 * implementation to drift out of sync with the one that ships.
 */

const fs = require('fs');
const path = require('path');
const vm = require('vm');

function loadBridge() {
  const sandbox = {};
  vm.createContext(sandbox);
  sandbox.self = sandbox;
  sandbox.globalThis = sandbox;
  vm.runInContext(fs.readFileSync(path.join(__dirname, '..', 'bridge.js'), 'utf8'), sandbox);
  return sandbox.CQMBridge;
}

/**
 * Loads background.js with a mocked chrome, and reports which alarms it created.
 * MV3 re-runs this file on every service-worker wake, so "what does a wake create?"
 * is the question that matters.
 */
function loadBackground(existingAlarms) {
  const created = [];
  const sandbox = {};
  vm.createContext(sandbox);
  sandbox.self = sandbox;
  sandbox.globalThis = sandbox;
  sandbox.fetch = async () => ({ ok: false, json: async () => ({}) });
  sandbox.navigator = { userAgent: '', userAgentData: { brands: [] } };
  sandbox.importScripts = (file) =>
    vm.runInContext(fs.readFileSync(path.join(__dirname, '..', file), 'utf8'), sandbox);
  const noop = { addListener() {} };
  sandbox.chrome = {
    alarms: {
      async get(name) { return existingAlarms[name]; },
      create(name, opts) { created.push({ name, ...opts }); },
      onAlarm: noop
    },
    storage: {
      local: {
        get(keys, cb) { const r = {}; if (cb) { cb(r); return; } return Promise.resolve(r); },
        set() { return Promise.resolve(); },
        remove() {}
      },
      onChanged: noop
    },
    runtime: { onStartup: noop, onInstalled: noop, onMessage: noop, getURL: (u) => u },
    action: { setBadgeText() {}, setBadgeBackgroundColor() {}, setTitle() {} },
    i18n: { getMessage: () => '' },
    permissions: { async contains() { return false; } },
    tabs: { create() {} }
  };
  vm.runInContext(fs.readFileSync(path.join(__dirname, '..', 'background.js'), 'utf8'), sandbox);
  return created;
}

const settle = () => new Promise((r) => setTimeout(r, 0));

module.exports = async function (describe) {
  const B = loadBridge();

  await describe('toEpochSeconds — reset timestamps', async (assert) => {
    assert(B.toEpochSeconds('2026-08-25T18:20:00Z') === 1787696400 ||
           B.toEpochSeconds('2026-08-25T18:20:00Z') === Math.floor(Date.parse('2026-08-25T18:20:00Z') / 1000),
      'ISO string converts to unix seconds');
    assert(B.toEpochSeconds(1787660000000) === 1787660000, 'millisecond epoch is scaled down');
    assert(B.toEpochSeconds(1787660000) === 1787660000, 'second epoch passes through');
    assert(B.toEpochSeconds(undefined) === null, 'undefined becomes null');
    assert(B.toEpochSeconds('') === null, 'empty string becomes null');
    assert(B.toEpochSeconds('not a date') === null, 'unparseable string becomes null');
    assert(B.toEpochSeconds(0) === null, 'zero is not a reset time');
  });

  await describe('detectBrowser — Chromium forks', async (assert) => {
    assert(B.detectBrowser('', [{ brand: 'Brave' }]) === 'Brave', 'Brave from brands');
    assert(B.detectBrowser('Mozilla/5.0 Edg/120', []) === 'Edge', 'Edge from user agent');
    assert(B.detectBrowser('Mozilla/5.0 Vivaldi/6', []) === 'Vivaldi', 'Vivaldi from user agent');
    assert(B.detectBrowser('Mozilla/5.0 Chrome/120', [{ brand: 'Chromium' }]) === 'Chrome',
      'plain Chromium reports as Chrome');
  });

  await describe('buildPayload — wire format', async (assert) => {
    const usage = {
      percent: 47, resetAt: '2026-08-25T18:20:00Z',
      weeklyPercent: 22, weeklyResetAt: 1787900000,
      opusWeeklyPercent: 61,
      orgId: 'org-1', plan: 'default_pro', ts: 1787648000000,
      extraUsageEnabled: true, extraUsageUsed: 12, extraUsageLimit: 50, extraUsageCurrency: 'USD'
    };
    const p = B.buildPayload(usage, { uuid: 'u-1', email: 'a@b.c', orgName: 'Org' }, '', 'Chrome', Date.now());

    assert(p.v === 1 && p.source === 'extension', 'envelope is versioned and tagged');
    assert(p.account.uuid === 'u-1' && p.account.email === 'a@b.c', 'account identity carried');
    assert(p.account.orgId === 'org-1', 'orgId comes from the stored reading');
    assert(p.observedAt === 1787648000, 'observedAt is seconds, from the reading not from now');
    assert(Object.keys(p.limits).length === 3, 'only limits that exist are sent');
    assert(p.limits.five_hour.pct === 47, 'five_hour percentage carried');
    assert(p.limits['weekly:opus'].resetsAt === null, 'a limit without a reset time still sends');
    assert(p.extra.used === 12 && p.extra.currency === 'USD', 'extra usage credits carried');

    const named = B.buildPayload(usage, null, '  work  ', 'Chrome', Date.now());
    assert(named.browser === 'work', 'profile name overrides the detected browser, trimmed');

    assert(B.buildPayload({}, null, '', 'Chrome', Date.now()) === null,
      'a reading with no limits produces no payload');
    assert(B.buildPayload(null, null, '', 'Chrome', Date.now()) === null,
      'no reading produces no payload');

    const partial = B.buildPayload({ percent: 0 }, null, '', 'Chrome', Date.now());
    assert(partial !== null && partial.limits.five_hour.pct === 0,
      'zero percent is a real reading, not a missing one');
  });

  await describe('slugModel — model names become wire keys', async (assert) => {
    assert(B.slugModel('Opus') === 'opus', 'simple name lowercases');
    assert(B.slugModel('Claude Design') === 'claude-design', 'spaces become hyphens');
    assert(B.slugModel('  Sonnet 4.5  ') === 'sonnet-4-5', 'punctuation and padding collapse');
    assert(B.slugModel('') === '', 'an empty name yields no key');
    assert(B.slugModel('!!!') === '', 'a name with nothing usable yields no key');
    assert(B.slugModel('x'.repeat(60)).length === 32, 'a runaway name is capped');
  });

  await describe('weeklyCategories — dynamic list, legacy fallback', async (assert) => {
    // Extension 1.7.2 moved per-model caps into a dynamic list because the API stopped
    // filling the seven_day_* fields. Both shapes have to work: profiles update one at a time.
    const dynamic = B.weeklyCategories({
      weeklyScoped: [{ name: 'Fable', percent: 34 }, { name: 'Opus', percent: 61 }]
    });
    assert(dynamic.length === 2 && dynamic[0].name === 'Fable', 'the dynamic list is used as-is');

    const legacy = B.weeklyCategories({ opusWeeklyPercent: 61, sonnetWeeklyPercent: 12 });
    assert(legacy.length === 2, 'legacy fields are read when there is no list');
    assert(legacy.some((c) => c.name === 'Opus' && c.percent === 61), 'legacy Opus carried');

    assert(B.weeklyCategories({}).length === 0, 'neither shape present yields nothing');
    assert(B.weeklyCategories({ weeklyScoped: [{ percent: 5 }] }).length === 0,
      'an entry with no model name is dropped rather than keyed as empty');
    assert(B.weeklyCategories({ weeklyScoped: [], opusWeeklyPercent: 61 }).length === 1,
      'an empty list falls back rather than reporting nothing');
  });

  await describe('buildPayload — dynamic model ceilings', async (assert) => {
    const p = B.buildPayload({
      percent: 41,
      weeklyScoped: [
        { name: 'Opus', percent: 61, resetAt: 1787994000 },
        { name: 'Claude Design', percent: 5, resetAt: null }
      ],
      ts: 1787648000000
    }, { uuid: 'u' }, '', 'Chrome', Date.now());

    assert(p.limits['weekly:opus'].pct === 61, 'a model cap is keyed by slug');
    assert(p.limits['weekly:opus'].label === 'Opus', 'and carries its display name');
    assert(p.limits['weekly:claude-design'].label === 'Claude Design',
      'a multi-word model keeps its wording for display');
    assert(p.limits.five_hour.label === undefined,
      'the well-known ceilings send no label — they name themselves');
  });

  await describe('isCacheUsable — identity caching', async (assert) => {
    const now = Date.now();
    const complete = { uuid: 'u', email: 'a@b.c', orgId: 'o1', ts: now };

    assert(B.isCacheUsable(complete, 'o1') === true, 'a fresh complete identity is reused');
    assert(B.isCacheUsable(complete, 'o2') === false, 'a different org invalidates it');
    assert(B.isCacheUsable(undefined, 'o1') === false, 'nothing cached is not usable');
    assert(B.isCacheUsable({ ...complete, ts: now - 25 * 3600e3 }, 'o1') === false,
      'a complete identity expires after a day');

    // The bug this replaced: `cached.orgId === (orgId ?? cached.orgId)` compared a value
    // with itself when no org was supplied, so the cache never expired by org.
    assert(B.isCacheUsable(complete, undefined) === true,
      'no org supplied falls back to the age check, not a self-comparison');

    const orgOnly = { orgId: 'o1', orgName: 'Org', ts: now - 40 * 60e3 };
    assert(B.isCacheUsable(orgOnly, 'o1') === false,
      'an org-only identity is a failed probe and is retried within the hour');
    assert(B.isCacheUsable({ ...orgOnly, ts: now - 60e3 }, 'o1') === true,
      'but not retried on every single push');
  });

  await describe('background.js — alarms survive a service-worker wake', async (assert) => {
    // chrome.alarms.create restarts an existing alarm's period. The worker re-runs this
    // file every time the 1-minute push alarm wakes it, so an unguarded create would
    // reset the 15-minute quota poll before it could ever fire.
    const cold = loadBackground({});
    await settle();
    assert(cold.length === 2, 'a cold start creates both alarms');
    assert(cold.some((a) => a.name === 'quota-poll' && a.periodInMinutes === 15),
      'quota-poll is created at 15 minutes');
    assert(cold.some((a) => a.name === 'mac-push' && a.periodInMinutes === 1),
      'mac-push is created at 1 minute');

    const warm = loadBackground({
      'quota-poll': { name: 'quota-poll', periodInMinutes: 15 },
      'mac-push': { name: 'mac-push', periodInMinutes: 1 }
    });
    await settle();
    assert(warm.length === 0, 'a wake with both alarms already armed creates nothing');

    const changed = loadBackground({
      'quota-poll': { name: 'quota-poll', periodInMinutes: 10 },
      'mac-push': { name: 'mac-push', periodInMinutes: 1 }
    });
    await settle();
    assert(changed.length === 1 && changed[0].name === 'quota-poll',
      'an alarm whose period changed is re-created, and only that one');
  });
};
