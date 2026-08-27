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

/**
 * Loads bridge.js with a `chrome` and a `fetch` the test drives, so the identity cache
 * can be exercised the way it actually runs. `routes` maps a claude.ai path to what the
 * request answers with; anything not listed comes back as a failed request, which is the
 * case the cache used to handle by throwing away what it already knew.
 */
function loadBridgeWithChrome({ store = {}, routes = {} } = {}) {
  const sandbox = {};
  vm.createContext(sandbox);
  sandbox.self = sandbox;
  sandbox.globalThis = sandbox;
  sandbox.fetch = async (url) => {
    const body = routes[String(url).replace('https://claude.ai', '')];
    if (body === undefined) return { ok: false, json: async () => ({}) };
    return { ok: true, json: async () => body };
  };
  sandbox.chrome = {
    storage: {
      local: {
        async get(key) { return key in store ? { [key]: store[key] } : {}; },
        async set(patch) { Object.assign(store, patch); }
      }
    },
    permissions: { async contains() { return true; } }
  };
  vm.runInContext(fs.readFileSync(path.join(__dirname, '..', 'bridge.js'), 'utf8'), sandbox);
  return { B: sandbox.CQMBridge, store };
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

    const carried = { uuid: 'u', orgId: 'o1', resolved: false, ts: now - 40 * 60e3 };
    assert(B.isCacheUsable(carried, 'o1') === false,
      'an identity carried across a failed probe is re-probed within the hour');
    assert(B.isCacheUsable({ ...carried, ts: now - 60e3 }, 'o1') === true,
      'and is reported with in the meantime rather than dropped');
    assert(B.isCacheUsable({ ...complete, resolved: true }, 'o1') === true,
      'a confirmed identity still lasts the day');
  });

  await describe('getAccount — an identity that survives a failed lookup', async (assert) => {
    const KEY = B.ACCOUNT_KEY;

    const good = loadBridgeWithChrome({
      routes: {
        '/api/bootstrap': { account: { uuid: 'u-1', email_address: 'A@B.c' } },
        '/api/organizations/org-1': { name: 'Org' }
      }
    });
    const first = await good.B.getAccount('org-1');
    assert(first.uuid === 'u-1' && first.email === 'a@b.c', 'a resolved identity is kept, lowercased');
    assert(first.orgName === 'Org', 'with the organization alongside it');
    assert(first.resolved === true, 'and marked as actually resolved');

    // The regression: claude.ai stopped answering the account lookup while the usage
    // endpoint kept working. Dropping the uuid here files the profile under its
    // organization instead, which the app cannot tell from a second account in a Team org
    // — so one failed request grew a duplicate card that could never be merged away.
    const lost = loadBridgeWithChrome({
      store: { [KEY]: { uuid: 'u-1', email: 'a@b.c', orgId: 'org-1', orgName: 'Org', ts: 0 } },
      routes: { '/api/organizations/org-1': { name: 'Org' } }
    });
    const kept = await lost.B.getAccount('org-1');
    assert(kept.uuid === 'u-1', 'a probe that answers nothing carries the last uuid across');
    assert(kept.orgName === 'Org', 'and does not blank the fields it did not answer');
    assert(kept.resolved === false, 'while recording that this probe resolved nothing');
    assert(lost.store[KEY].uuid === 'u-1', 'the cache keeps it rather than being overwritten');

    // A profile signed into a different account must not inherit the last one's uuid.
    const switched = loadBridgeWithChrome({
      store: { [KEY]: { uuid: 'u-1', email: 'a@b.c', orgId: 'org-1', ts: 0 } }
    });
    const fresh = await switched.B.getAccount('org-2');
    assert(fresh.uuid === undefined, 'another organization inherits nothing');
    assert(fresh.orgId === 'org-2', 'and is keyed to the organization it did find');

    const back = loadBridgeWithChrome({
      store: { [KEY]: { uuid: 'u-old', orgId: 'org-1', resolved: false, ts: 0 } },
      routes: { '/api/account': { uuid: 'u-new' }, '/api/organizations/org-1': { name: 'Org' } }
    });
    const renewed = await back.B.getAccount('org-1');
    assert(renewed.uuid === 'u-new', 'a lookup that answers again replaces what was carried');
    assert(renewed.resolved === true, 'and says so, so the day-long cache applies again');
  });

  await describe('carryOver — what survives a failed lookup', async (assert) => {
    assert(Object.keys(B.carryOver(undefined, 'o1')).length === 0, 'nothing cached carries nothing');
    assert(B.carryOver({ uuid: 'u', orgId: 'o1' }, 'o1').uuid === 'u', 'the same org keeps the uuid');
    assert(B.carryOver({ uuid: 'u', orgId: 'o1' }, 'o2').uuid === undefined, 'another org keeps none of it');
    assert(B.carryOver({ uuid: 'u', orgId: 'o1' }, undefined).uuid === 'u',
      'with no org to compare, what is known is kept');
    assert(B.carryOver({ uuid: 'u', email: null, orgName: '' }, undefined).email === undefined,
      'empty fields are not carried as values');
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
