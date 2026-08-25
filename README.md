# Claude Quota — macOS menu bar

Four Claude accounts, one glance. A bar per account in the menu bar, showing how full each
one is, when it resets, and — honestly — how old the number is.

```
 ▁▃▇▂  74%
```

Each bar tracks that account's **binding** limit: whichever ceiling is closest to stopping
you. Weekly Opus routinely fills before the 5-hour window does, so "how full am I" cannot
just read the session quota.

## Where the numbers come from

Two sources, merged per account, newest observation wins per limit.

**1. The browser.** A [forked Claude Quota Monitor](https://github.com/mennwebs/claude-quota-monitor)
extension posts what it already reads from `claude.ai` to `127.0.0.1`. One Chrome profile per
account; each profile reports the account it is signed in as.

**2. Claude Code on this machine.** Claude Code hands its status line command a JSON blob on
every render, and that blob contains the live `rate_limits`. A shim copies it to a file. No API
call, no polling, no extra process — and it is the freshest source there is, updating as you
work rather than every fifteen minutes.

Neither source is complete on its own. The status line has no Opus ceiling and does not say
which account it belongs to; the extension does not know about your terminal. Merged, one row
shows 5h/7d from the CLI within seconds and Opus from the browser.

Hooks were the obvious alternative to the status line shim. They do not carry rate limits —
`statusLine` is the only local carrier.

## Why loopback and not native messaging

Native messaging needs a host manifest installed into every Chromium data directory, each
pinned to an extension ID that differs per browser. One loopback port serves every profile
with one manifest change on the extension side.

The usual objection — data is lost while the app is closed — does not apply here: re-posting a
cached reading costs nothing on claude.ai's side, so the extension pushes every minute while
fetching every fifteen. Open the app and it is current within a minute.

## Honesty rules

The point of the thing is to be trusted at a glance, so it never dresses up what it does not know.

| Situation | What you see |
|---|---|
| Read within 3 minutes | full colour |
| 3–30 minutes | slightly dimmed |
| 30 min – 3 hours | greyed, `~` before the number |
| Older | grey bar, "อ่านล่าสุด 5 ชม.ที่แล้ว" |
| Past its `resets_at` | empty dashed bar, "รีเซ็ตแล้ว · รอใช้ครั้งถัดไป" |
| Never reported | hollow outline, not `0%` |

After a 5-hour window resets, the next reset time is genuinely unknowable — the window starts
on your next message, not on a schedule. It says so instead of inventing a countdown.

Token counts from `~/.claude/stats-cache.json` are shown on their own line and never fed into
a bar. Claude weights usage server-side; tokens cannot be converted back into a percentage, and
pretending otherwise would be the one lie that makes the whole panel untrustworthy.

## Install

```bash
git clone https://github.com/mennwebs/claude-quota-mac
cd claude-quota-mac
./scripts/build.sh
cp -R "dist/Claude Quota.app" /Applications/
open "/Applications/Claude Quota.app"
```

Needs macOS 14+ and a Swift toolchain (Xcode or the command line tools). No dependencies.

### Connect a browser profile

1. In the menu bar app: **ตั้งค่า… → ทั่วไป**, copy the token.
2. In Chrome, load the forked extension unpacked, then right-click its toolbar icon → **Options**.
3. Tick *Send readings to the Mac app*, paste the token, optionally name the profile, press
   **Save & connect**. Chrome will ask for permission to reach `127.0.0.1` — that permission is
   optional and is only requested at this point.
4. Repeat in every profile.

### Connect Claude Code

**ตั้งค่า… → เครื่องนี้ → ติดตั้ง**, or from a terminal:

```bash
"/Applications/Claude Quota.app/Contents/MacOS/ClaudeQuota" --install-statusline
```

This wraps whatever status line you already have: `statusLine.command` in
`~/.claude/settings.json` is repointed at a generated shim which tees the JSON and then runs
your original command unchanged. Your own script is never edited. `settings.json` is patched as
text, so the change is a one-line diff — key order and formatting survive — and a dated backup
is kept. `--uninstall-statusline` puts it back byte for byte.

## Command line

```
--install-statusline     wrap the configured status line
--uninstall-statusline   restore the previous one
--statusline-status      report whether the shim is installed
--print-token            print the loopback token
--print-port             print the port
--selftest               run the settings.json patcher checks
```

## Files

| Path | What |
|---|---|
| `~/Library/Application Support/ClaudeQuotaMonitor/state.json` | merged per-account readings |
| `~/Library/Application Support/ClaudeQuotaMonitor/settings.json` | port, labels, thresholds |
| `~/Library/Application Support/ClaudeQuotaMonitor/token` | loopback token, mode 0600 |
| `~/Library/Application Support/ClaudeQuotaMonitor/cli.json` | last status line payload |
| `~/.claude/cqm-statusline.sh` | the generated shim |

Nothing is sent off the machine. The app binds `127.0.0.1` only, serves two routes, caps
request bodies at 256 KB, and requires the token on the one route that writes.

## Troubleshooting

**Menu bar shows a hollow outline** — nothing has reported yet. Open the extension's Options and
press **Test**; it distinguishes "app not running" from "wrong token" from "no reading yet".

**"พอร์ตถูกใช้อยู่แล้ว"** — change the port in ตั้งค่า → ทั่วไป, then change it in each profile's
Options to match.

**Two rows for one account** — they merge as soon as a report arrives carrying both identifiers.
If they persist, delete one in ตั้งค่า → บัญชี; it comes back correctly on the next report.

## Licence

MIT
