# Working in this repo

Two halves of one product live here, because they share the wire contract in
`docs/protocol.md` and drift apart the moment they are split:

| Path | What |
|---|---|
| repo root | the Chrome extension (`background.js`, `popup.js`, `bridge.js`, `_locales/`) |
| `mac/` | the macOS menu bar app, Swift Package Manager, no dependencies |

UI strings in both halves are Thai. Code, comments, README and CHANGELOG are English.

## Building and installing the Mac app

```bash
cd mac && ./scripts/build.sh
```

`npm run build:mac` from the repo root does the same. Output is `mac/dist/Claude Quota.app`,
ad-hoc signed — enough to run and to register as a login item, not notarized.

**Install to `/Applications` and run it from there.** Never leave a copy in `mac/dist/` running
while doing anything that touches LaunchServices:

```bash
cp -R "mac/dist/Claude Quota.app" /Applications/
open "/Applications/Claude Quota.app"
```

### Open at login

**ตั้งค่า… → ทั่วไป → เปิดโปรแกรมตอนล็อกอิน**, or:

```bash
"/Applications/Claude Quota.app/Contents/MacOS/ClaudeQuota" --enable-login-item
```

`SMAppService` stores the login item as a **path**, and resolves this app's bundle identifier
through LaunchServices — which points at whichever copy is *running*. Register while a
`mac/dist/` copy is open and macOS records that build directory; the login item then breaks the
moment it is rebuilt or deleted. This has actually happened: registering from `/Applications`
wrote a git-worktree path into the Background Task Management database.

To move a registration between copies:

```bash
"/Applications/Claude Quota.app/Contents/MacOS/ClaudeQuota" --disable-login-item
pkill -x ClaudeQuota
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "<old copy>.app"
open "/Applications/Claude Quota.app"
"/Applications/Claude Quota.app/Contents/MacOS/ClaudeQuota" --enable-login-item
```

`--login-item-status` answers per **bundle identifier**, not per path: it reports `enabled` from
any copy, including one that is not the registered one. Only this knows the registered path:

```bash
sfltool dumpbtm | grep -A9 "Name: Claude Quota"
```

Run `sfltool` in the foreground. Backgrounded or piped through a long compound command it has
been seen to hang and produce nothing.

`pkill -f` with a pattern containing the app path also matches the shell running the command.
Use `pkill -x ClaudeQuota`.

### Connecting the halves

`--print-token` and `--print-port` give the values the extension's Options page needs, per Chrome
profile. `--install-statusline` wraps the configured Claude Code status line so it tees its
`rate_limits` to the app; `--uninstall-statusline` restores it byte for byte.

## Tests

```bash
npm test              # extension; needs npm install first (puppeteer, pngjs)
npm run test:mac      # mac/ — builds, then --selftest
```

`--selftest` covers the `settings.json` text patcher, limit-key parsing, display names, the
stats-cache fallback and calendar independence. Add to it rather than adding a test target;
there is no XCTest bundle.

## Things that bite

- **A `ScrollView` collapses a `MenuBarExtra` window.** Asked for its ideal height with no
  proposal — which is how the panel window sizes itself — it reports almost nothing, and the
  whole panel shrinks to its header and footer. It needs
  `.fixedSize(horizontal: false, vertical: true)`; a `.frame(maxHeight:)` alone is not enough,
  and the symptom is a panel with no content rather than a layout warning.
- **Opening the settings window took three fixes, not one**, and each one looked like
  the whole answer until it was tried against a real desktop.
  `NSApp.sendAction(Selector(("showSettingsWindow:")))` is a no-op on macOS 26 in a
  menu-bar-only app — it returns `true` and opens nothing, so use `SettingsLink`. But
  `SettingsLink` hands the new window no focus, and the same click dismisses the panel,
  which deactivates the app and drops the window behind whatever was in front. Raising it
  is still not enough: an `.accessory` app does not win an activation contest, so the app
  has to become `.regular` while the window is open. And even then an app that
  re-activates itself a moment later covers it, so the window is `.floating` for as long
  as it is open. All three live in `SettingsWindow` in `mac/Sources/ClaudeQuota/App.swift`.
  The click cannot be hooked — a `simultaneousGesture` on `SettingsLink` never fires — so
  the window is watched for instead.
- **`preferredColorScheme` does not reach the popover's window frame.** The pale ring around a
  dark panel is AppKit drawing the frame in the system appearance; only setting the window's
  `appearance` changes it. See `DarkWindows` in `mac/Sources/ClaudeQuota/App.swift` — and note
  it deliberately does *not* set `NSApp.appearance`, because the menu bar glyph draws with label
  colours that have to match the real menu bar.
- **`~/.claude/stats-cache.json` is recomputed lazily**, so today's entry is routinely missing on
  a machine that has been working since morning. Zero there means "not counted yet", not "no
  work"; never print it as today's total.
- **Thai locale defaults to the Buddhist calendar.** Any `DateFormatter` that produces or parses
  a `stats-cache.json` date key must pin `en_US_POSIX` and a Gregorian calendar, or every lookup
  misses against a year like 2569.
- **Quota percentages are the only truth about quota.** Token counts cannot be converted back
  into a percentage — Claude weights usage server-side — so they stay on their own line and
  never feed a bar.

## Verifying panel changes

The panel is a `MenuBarExtra` popover, so it cannot be screenshotted by asking nicely: it closes
when the app deactivates, `screencapture -R` fails on this OS, and a child process spawned by
the app lacks screen-recording rights. What works is a throwaway `--shot` flag on the app that
clicks its own status item, prints the window rect, and stays alive while the *shell*
screenshots the full screen and crops. `CQM_HOME` redirects both Application Support and the
home directory, so fixtures can be fed in without touching the real ones. Note that
`screencapture` writes no `pHYs` chunk, so `NSImage.size` on its output is already in pixels —
derive the point-to-pixel scale from `NSScreen`, not from the image.

**A harness must reproduce what a person does, or it verifies nothing.** The first version of
the settings check called `NSApp.activate` before clicking the button; that made the window
appear and the check pass, while the shipped app still opened it behind everything. Drive the
status item to open the panel — that is what activates the app for a real user — and give the
button click no help at all. Poll for each state rather than sleeping: the synthetic click races
with the panel becoming visible, and fixed delays produce runs that pass for the wrong reason.
Anything else running that steals focus (a browser, another automation) will also skew the
result, so judge it over several runs and A/B against the unfixed path. On this machine both
Dia and Claude for Desktop re-activate themselves seconds later, which makes "who is frontmost
at t+3s" unmeasurable; sample a trajectory (t+0.5, t+1, t+2) and report window *level* as well
as key state, so a window that is genuinely on top is not scored as a failure.

`screencapture` also fails outright — "could not create image from display" — whenever the
screen is locked, and a crop step that reuses its last output will then silently produce a
screenshot of something else entirely. Delete the target file first and check it exists before
cropping. When it cannot be made to work, window geometry is evidence too: the panel is 184pt
tall for two accounts and 290pt for four, which is a two-by-two grid without needing a picture.

## Checking the bridge without a browser

The app's own side can be exercised with `curl`, which separates "the Mac app is dropping
reports" from "no browser profile is sending any":

```bash
TOKEN=$("/Applications/Claude Quota.app/Contents/MacOS/ClaudeQuota" --print-token)
curl -s http://127.0.0.1:47821/v1/health
curl -s -X POST http://127.0.0.1:47821/v1/usage \
  -H "content-type: application/json" -H "x-cqm-token: $TOKEN" \
  -d '{"v":1,"source":"extension","browser":"test","account":{"uuid":"…"},"observedAt":0,"limits":{}}'
```

The routes are `GET /v1/health` and `POST /v1/usage` — nothing else. Point `CQM_HOME` at a
scratch directory and use a different port to do this without writing into the real state.

Each Chrome profile carries its own bridge config in `chrome.storage.local`; `pushToMac()` in
`bridge.js` returns early unless that profile has both `enabled` and a `token`. An account
missing from the panel almost always means that profile was never configured, not that the app
dropped it — the panel only ever shows accounts that have reported.
