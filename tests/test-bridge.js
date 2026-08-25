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
    assert(p.limits.seven_day_opus.resetsAt === null, 'a limit without a reset time still sends');
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
};
