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

**1. The browser.** The Claude Quota Monitor fork in the parent directory posts what it already
reads from `claude.ai` to `127.0.0.1`. One Chrome profile per account; each profile reports the
account it is signed in as.

**2. Claude Code on this machine.** Claude Code hands its status line command a JSON blob on
every render, and that blob contains the live `rate_limits`. A shim copies it to a file. No API
call, no polling, no extra process — and it is the freshest source there is, updating as you
work rather than every fifteen minutes.

Neither source is complete on its own. The status line has no per-model ceilings and does not
say which account it belongs to; the extension does not know about your terminal. Merged, one
row shows 5h/7d from the CLI within seconds and the model caps from the browser.

Model ceilings are not a fixed list. claude.ai reports them dynamically, so Fable showed up on
its own and the next model will too — neither half of this names a model anywhere.

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

Ages are tracked **per limit, not per account**. The two sources cover different ceilings —
the status line never reports Opus — so an account can be refreshing 5h every second while its
Opus figure quietly goes hours old. Each row is dimmed on its own clock.

| Situation | What you see |
|---|---|
| Read within 3 minutes | full colour |
| 3–30 minutes | slightly dimmed |
| 30 min – 3 hours | greyed, `~` before the number |
| Older | grey bar, "อ่านล่าสุด 5 ชม.ที่แล้ว" |
| Past its `resets_at` | empty dashed bar, "รีเซ็ตแล้ว · รอใช้ครั้งถัดไป" |
| Never reported | hollow outline, not `0%` |
| Nothing reporting for 5 min | hollow gold dot, "เงียบ 41 นาที" on the row and in the header |

That last row is a different claim from the ones above it, and the panel used to be unable to
make it. "This number is 40 minutes old" and "nothing has reported for 40 minutes" look
identical when the only thing tracked is the age of the reading — so a browser whose service
worker had died rendered exactly like a quiet afternoon. Contact is now recorded separately from
observation, and when the two disagree the silence is what gets the space.

A per-model ceiling that the API stops listing is retired once it is three hours old. The caps
arrive as a list, so a model that goes away does not come back as zero — it simply stops
appearing, and nothing would ever overwrite the last reading. The three-hour floor is there so a
single short report cannot erase a figure that is still live.

After a 5-hour window resets, the next reset time is genuinely unknowable — the window starts
on your next message, not on a schedule. It says so instead of inventing a countdown.

Token counts from `~/.claude/stats-cache.json` are shown on their own line and never fed into
a bar. Claude weights usage server-side; tokens cannot be converted back into a percentage, and
pretending otherwise would be the one lie that makes the whole panel untrustworthy.

## Install

```bash
cd mac
./scripts/build.sh
cp -R "dist/Claude Quota.app" /Applications/
open "/Applications/Claude Quota.app"
```

From the repo root, `npm run build:mac` does the same thing.

Needs macOS 14+ and a Swift toolchain (Xcode or the command line tools). No dependencies.

### Open at login

**ตั้งค่า… → ทั่วไป → เปิดโปรแกรมตอนล็อกอิน**, or:

```bash
"/Applications/Claude Quota.app/Contents/MacOS/ClaudeQuota" --enable-login-item
```

Register the copy you actually intend to keep. macOS stores the login item as a *path*, and it
resolves the bundle identifier through LaunchServices — which points at whichever copy is
running. Registering while a build directory copy is open records that directory, and the login
item breaks the moment it is rebuilt or deleted. Quit every other copy first, launch the one in
`/Applications`, then register. `--login-item-status` answers per bundle identifier, not per
path, so it will say `enabled` from any copy; `sfltool dumpbtm | grep -A8 claude-quota` is what
actually shows the registered path.

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
--enable-login-item      open this copy of the app at login
--disable-login-item     stop opening it at login
--login-item-status      report whether it opens at login
--print-token            print the loopback token
--print-port             print the port
--selftest               run the built-in checks
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

**Rows say "เงียบ" while the browser is open** — the extension is loaded unpacked, and Chromium
does not watch its files. Page and content scripts are re-read from disk on demand, but the
**service worker is only replaced when the extension is reloaded** — the Reload button on
`chrome://extensions`, or a browser restart. Edit `background.js` while the browser is running
and it keeps executing the copy it registered, which may predate the bridge entirely: the quota
still updates in the popup, and nothing is ever pushed here. Reload the extension in every
profile after pulling. To confirm the push alarm is actually registered:

```bash
grep -rac mac-push ~/Library/Application\ Support/<Browser>/*/Extension\ State/ 2>/dev/null
```

Zero everywhere means the worker running is older than the bridge.

**"พอร์ตถูกใช้อยู่แล้ว"** — change the port in ตั้งค่า → ทั่วไป, then change it in each profile's
Options to match.

**Two rows for one account** — they merge as soon as a report arrives carrying both identifiers.
If they persist, delete one in ตั้งค่า → บัญชี; it comes back correctly on the next report.

## Where things are

This is one half of a two-part tool. The Chrome extension is at the repo root; the wire contract
between them is in [`../docs/protocol.md`](../docs/protocol.md).

## Licence

MIT
