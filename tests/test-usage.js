/**
 * Suite: reading /usage
 *
 * usage.js is a classic script that publishes onto `self`, loaded here for real. The
 * fetch tests run background.js's own fetchUsage against a mocked claude.ai, because the
 * bug they pin was in what that function did with a response, not in any helper.
 */

const fs = require('fs');
const path = require('path');
const vm = require('vm');

const read = (f) => fs.readFileSync(path.join(__dirname, '..', f), 'utf8');

function loadUsage() {
  const sandbox = {};
  vm.createContext(sandbox);
  sandbox.self = sandbox;
  sandbox.globalThis = sandbox;
  vm.runInContext(read('usage.js'), sandbox);
  return sandbox.CQMUsage;
}

/** background.js with claude.ai answering `reply`, and a real-enough chrome.storage. */
function loadBackground({ reply, store = {} }) {
  const sandbox = {};
  vm.createContext(sandbox);
  sandbox.self = sandbox;
  sandbox.globalThis = sandbox;
  sandbox.fetch = async (url) => {
    if (String(url).endsWith('/usage')) return reply(url);
    return { ok: false, json: async () => ({}) }; // the plan lookup; the stored plan wins
  };
  sandbox.navigator = { userAgent: '', userAgentData: { brands: [] } };
  sandbox.importScripts = (...files) => files.forEach((f) => vm.runInContext(read(f), sandbox));
  const noop = { addListener() {} };
  sandbox.chrome = {
    alarms: { async get() { return {}; }, create() {}, onAlarm: noop },
    storage: {
      local: {
        get(key, cb) {
          const r = {};
          for (const k of [].concat(key)) if (k in store) r[k] = store[k];
          if (cb) { cb(r); return; }
          return Promise.resolve(r);
        },
        async set(patch) { Object.assign(store, patch); },
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
  vm.runInContext(read('background.js'), sandbox);
  return { fetchUsage: sandbox.fetchUsage, store };
}

const ok = (body) => async () => ({ ok: true, status: 200, json: async () => body });
const SEEDED = () => ({
  claudeUsage: { orgId: 'org-1', plan: 'default_claude_max_20x', percent: 0, weeklyPercent: 100, ts: 1 }
});

module.exports = async function (describe) {
  const U = loadUsage();

  await describe('parseUsage — a response with no live 5-hour window', async (assert) => {
    // The weekly cap spent: the API has nothing to say about the 5-hour window.
    const capped = U.parseUsage({
      five_hour: null,
      seven_day: { utilization: 100, resets_at: '2026-11-03T04:00:00+00:00' },
      limits: [{ kind: 'weekly_scoped', scope: { model: { display_name: 'Fable' } },
                 percent: 0, resets_at: '2026-11-03T04:00:00+00:00' }]
    });
    assert(capped !== null, 'five_hour: null is still a reading, not a failed one');
    assert(capped.percent === 0 && capped.resetAt === null,
      'no window reads as 0% with no reset time');
    assert(capped.weeklyPercent === 100, 'the weekly figure is kept');
    assert(capped.weeklyScoped.length === 1 && capped.weeklyScoped[0].name === 'Fable',
      'the per-model ceilings are kept');

    const bare = U.parseUsage({ five_hour: null, seven_day: { utilization: 40 } });
    assert(bare !== null && bare.weeklyPercent === 40, 'seven_day alone is enough');

    const limitsOnly = U.parseUsage({ limits: [{ kind: 'weekly_scoped',
      scope: { model: { display_name: 'Opus' } }, percent: 5 }] });
    assert(limitsOnly !== null && limitsOnly.weeklyScoped[0].name === 'Opus',
      'a limits array alone is enough');
  });

  await describe('parseUsage — a response that is not a reading', async (assert) => {
    assert(U.parseUsage(null) === null, 'null');
    assert(U.parseUsage('<html>challenge</html>') === null, 'a string');
    assert(U.parseUsage({}) === null, 'an empty object');
    assert(U.parseUsage({ five_hour: null, seven_day: null, limits: [] }) === null,
      'every limit absent');
    assert(U.parseUsage({ five_hour: null, limits: [{ kind: 'session', percent: 40 }] }) === null,
      'a limits array of kinds this code does not read cannot pass as 0% used');
    assert(U.parseUsage({ error: { type: 'permission_error' } }) === null,
      'an error document');
  });

  await describe('parseUsage — the ordinary case is unchanged', async (assert) => {
    const r = U.parseUsage({
      five_hour: { utilization: 32, resets_at: '2026-11-01T10:00:00+00:00' },
      seven_day: { utilization: 31, resets_at: '2026-11-03T04:00:00+00:00' },
      extra_usage: { is_enabled: true, used_credits: 250, monthly_limit: 5000, currency: 'USD' }
    });
    assert(r.percent === 32 && r.resetAt === '2026-11-01T10:00:00+00:00', 'session');
    assert(r.weeklyPercent === 31, 'weekly');
    assert(r.extraUsageEnabled === true && r.extraUsageUsed === 250 &&
      r.extraUsageLimit === 5000 && r.extraUsageCurrency === 'USD', 'extra usage');
  });

  await describe('fetchUsage — a capped account keeps updating', async (assert) => {
    const { fetchUsage, store } = loadBackground({
      store: SEEDED(),
      reply: ok({ five_hour: null, seven_day: { utilization: 100, resets_at: 'x' } })
    });
    await fetchUsage();
    assert(store.claudeUsage.ts > 1, 'the reading is rewritten with a fresh timestamp');
    assert(store.claudeUsage.percent === 0 && store.claudeUsage.resetAt === null,
      'the idle session is stored as 0% with no reset');
    assert(store.claudeUsage.orgId === 'org-1' && store.claudeUsage.plan === 'default_claude_max_20x',
      'org and plan survive the rewrite');
    assert(store.usageFetchStatus.ok === true && store.usageFetchStatus.reason === null,
      'the fetch is recorded as good');
  });

  await describe('fetchUsage — a failure says why', async (assert) => {
    const cases = [
      ['http-403', async () => ({ ok: false, status: 403, json: async () => ({}) })],
      ['http-401', async () => ({ ok: false, status: 401, json: async () => ({}) })],
      ['no-limits', ok({ error: 'nope' })],
      ['no-limits', async () => ({ ok: true, status: 200, json: async () => { throw new Error('html'); } })],
      ['network', async () => { throw new TypeError('Failed to fetch'); }]
    ];
    for (const [reason, reply] of cases) {
      const { fetchUsage, store } = loadBackground({ store: SEEDED(), reply });
      await fetchUsage();
      assert(store.usageFetchStatus?.ok === false && store.usageFetchStatus.reason === reason,
        `recorded as ${reason}`);
      assert(store.claudeUsage.ts === 1, `${reason}: the last good reading is left alone`);
    }
  });
};
