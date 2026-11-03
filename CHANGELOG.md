# Changelog

All notable changes to Claude Quota Monitor are documented here.

---

## [Unreleased]

### Added
- **Mac app: an optional quota source that reads the API directly.** `ตั้งค่า… → ในเครื่อง →
  quota API` borrows the OAuth token Claude Code keeps in the login keychain and reads
  `api.anthropic.com/api/oauth/usage` — the endpoint the CLI's own `/usage` calls. It answers
  the same document claude.ai serves the extension, so the account Claude Code is signed into
  gets its per-model weekly caps and extra-usage credits without a browser profile pointed at
  it, and around the clock rather than only while a terminal is drawing a status line.

  **Off by default**, because turning it on reads a credential belonging to another
  application. **Read-only, permanently**: the refresh that renews an access token also rotates
  the refresh token, so a second process refreshing the same credential can log Claude Code
  out. When the token expires the panel says so and waits for Claude Code to renew it.

  Complements the statusline shim rather than replacing it — the shim is still fresher and
  still costs no request. Both may be on; readings merge per limit on observation time, as
  every source does.
- Pressing Refresh now actually refreshes this source. The browser can only be *asked*, through
  a flag it answers on its own minute; this source is local, so it just fetches.
- **An empty panel now offers the route this machine can take.** It named only the extension,
  so someone who lives in Claude Code and has no browser profile signed in read it as "this app
  is not for you" and closed it. When Claude Code has signed in here and the quota API source
  is still off, the panel says so first and the extension line follows as the alternative. When
  the source is on but stuck on something only the user can clear — a declined keychain, no
  credential — it points at Settings rather than leaving an empty panel with no route to the
  reason it is empty. Whether Claude Code has signed in is read from `~/.claude.json`, which is
  already polled; the keychain is not touched to decide what to suggest.

### Fixed
- **Extension: a claude.ai tab left open across an extension reload no longer throws.**
  The old content script outlives the reload with its connection cut, and its poll and DOM
  observer kept calling `chrome.*` — "Extension context invalidated" on every tick. It now
  notices `chrome.runtime.id` is gone and stands down. Reload the tab to get the new one.

- **A profile whose weekly cap was spent stopped updating, silently.** With the cap at 100%
  there is no live 5-hour window and the API answers `five_hour: null`; both the service
  worker and the content script read that as "no reading" and returned without writing, so the
  profile sat on its last numbers (and the Mac app on that profile's last push) for as long as
  the cap lasted. A missing window no longer stops the reading from being written — see
  *Changed* below for what it is stored as — and the parsing lives in one `usage.js` that both
  sides load instead of two copies.
- **The popup now says why a reading is old.** Every early exit in the fetchers was silent, so
  "updated 24h ago" was all there was to go on. The last fetch's outcome (`http-403`,
  `no-limits`, `network`) is kept in `usageFetchStatus`, and the popup shows it once a failing
  fetch has left the reading more than 30 minutes old.
- **A new field in `settings.json` silently wiped every setting.** `AppSettings.load()` answers
  a thrown decode with defaults and Swift's synthesized `Decodable` ignores property defaults,
  so adding one stored field would have taken the user's account labels, their chosen port and
  their freshness thresholds with it on the first launch of the new build. Each field now falls
  back on its own; one unreadable field costs that field, not the file. `--selftest` round-trips
  the whole struct so the next field added but not wired up is caught here.
- Per-model caps are retired per source rather than by the extension alone. Two sources that
  both list caps poll on their own clocks, so one dropping Opus must not erase the other's
  live Opus reading.
- **The Mac app put Claude Code's quota on the wrong account's card.** The status line payload
  names no account, so the app took one from `oauthAccount` in `~/.claude.json` — which says who
  Claude Code last *looked up*, not whose credential it is *using*. On the machine this was found
  on the two had disagreed since July, and one account's 5h and 7d readings had been overwriting
  another's for weeks, winning every merge for being the freshest thing on the row.

  Identity now comes from `cachedUsageUtilization.accountUuid`, which is stamped with the account
  the quota response actually came back for, cross-checked against `oauthAccount`. Agreeing uuids
  stand. A disagreement is settled by the seven-day reset instant: the cached block and the status
  line have to be describing the same week, or the report is dropped instead of filed under a
  guess. A corrected identity carries the uuid alone — the email, organization and plan beside it
  belong to the other account. Reading Claude Code's keychain item and asking `/api/oauth/profile`
  would have been authoritative and was not taken: it costs a keychain prompt on every rebuild of
  an ad-hoc signed app and would make this the app's only outbound request. `mac/README.md` has
  the reasoning.

  A row already holding the wrong numbers heals itself — the extension reports the same two
  ceilings for that account, and the next push is newer.

  With the quota API source above turned on, that inference is not needed: `/api/oauth/profile`
  answers from the same auth context as the numbers, so it is taken as the credential's account
  outright — including in the case the file-based rule refuses to guess at.
- **Extension: the toolbar badge ignored the weekly cap.** It picked the fullest of the 5-hour
  session and the per-model caps, never `seven_day`, so an account with the week spent read
  `S0`. The weekly cap now competes as `W`, and the session only when the account has one.
- Tests: the popup suite never ran on macOS — `--disable-gpu` keeps current Chrome for Testing
  from reaching network-idle, so every case timed out — and the test page had never included
  `popup.css`, because the tag it looked for was written differently in `popup.html`.

### Changed
- **Mac app: a Team card no longer carries a per-model cap row.** Team organizations tend not to
  use the models that have a weekly cap of their own, so the row sat at `Fable 0%` under every
  Team card's real numbers. It is hidden by default, along with any other per-model cap on a Team
  seat, and a hidden cap no longer fills the menu bar glyph either — a bar the panel cannot
  explain would be worse than none. **ตั้งค่า… → ทั่วไป → แสดงเพดานรายโมเดลของบัญชี Team** brings
  them back for an organization that does use them. Every other plan shows its caps as before.

  Unlike the 5h rule below, this one goes by the plan rather than by the data: a 0% cap reads the
  same whether the model is unused or simply not used *yet*, so only the user can say it is noise.
- **The extension's plan now outranks the status line's.** claude.ai's organization names a Team
  seat `default_raven`; `~/.claude.json` carries the tier Claude Code's profile answered, which on
  that same seat is a Max tier. Merging was last-writer-wins, and the status line reports on every
  render, so a Team seat signed into Claude Code could have its badge — and now its model-cap row —
  turned back within seconds of each extension report. Each source may still revise its own word.
- **No 5h row for an account that has no 5-hour window.** Ultra plans and some Team seats have
  no session limit at all, and the API answers `five_hour: null` for them on every call. The
  extension stored that as 0% with no reset time, so every such card in the Mac panel — and the
  popup — carried an idle-looking 5h bar for a limit that does not exist. A missing window is
  now stored as `percent: null`, the bridge leaves `five_hour` out of the report, the popup
  drops its session block, and the Mac app retires a source's own `five_hour` reading as soon as
  that source posts a newer report without one — and remembers it, so another profile on the
  same account re-posting an older 5h cannot revive the row. The rule follows the data rather than the plan
  name, because the plan name cannot tell: two Team seats in the same organization differ.

  An account that does have a window loses it the same way while its weekly cap is spent, so
  its 5h row now steps aside until the week resets; the 7d row at 100% already says why.

  A browser profile still running an older build keeps sending the 0% until the extension is
  reloaded there.
- **Plan badges use the names people know.** The tier ids lag the product: Max 20x was renamed
  Ultra while the API kept answering `default_claude_max_20x`, and a Team seat answers with the
  codename `default_raven`. Both the Mac panel and the popup now show them as *Ultra* and
  *Team*; Max 5x is unchanged.

---

## [1.8] — 2026-09-01

### Added
- `bridge.js` — pushes the reading this extension already has to a menu bar app listening on
  `127.0.0.1`. Opt-in: with no token configured it makes no requests.
- Options page for the bridge (port, token, profile name), reachable from the toolbar icon's
  right-click menu.
- A one-minute push alarm. It re-sends the cached value and never touches claude.ai, so the Mac
  app is current within a minute of launching while request volume to claude.ai is unchanged.
- The app can ask for a real refresh in its reply to a push — the only path from the Mac back
  into the browser.
- `mac/` — the menu bar app itself, in this repo because the two halves share the wire contract
  in `docs/protocol.md`. First release of the app, versioned 1.0.0 on its own track.
- `tests/test-bridge.js` — checks over the payload builder and the alarm scheduling, loading
  `bridge.js` and `background.js` themselves rather than copies, so they cannot drift.
- `--enable-login-item` / `--disable-login-item` / `--login-item-status` on the Mac app, next to
  the statusline flags and for the same reason: "open at login" is a persistent change to the
  machine, and being able to set and inspect it from a terminal makes it auditable. The GUI
  toggle in ตั้งค่า → ทั่วไป is unchanged. `LoginItem` moved from `SettingsView.swift` to
  `Support.swift` — the CLI needs it and it was never a view.

### Fixed
- **Mac panel showed no bars at all** — `ScrollView { … }.frame(maxHeight:)` reports almost no
  ideal height when asked for one with no proposal, which is exactly what a `MenuBarExtra`
  window does. The window sized itself to 68pt: header, footer, and every account squeezed out
  of existence. `fixedSize(horizontal: false, vertical: true)` makes the scroll view report the
  height its content wants, and the frame still caps it so long lists scroll.
- **"ตั้งค่า…" did nothing** — two faults, one symptom.
  `NSApp.sendAction(Selector(("showSettingsWindow:")))` returns `true` on macOS 26 and opens no
  window in a menu-bar-only app, so it is now `SettingsLink`. But `SettingsLink` on its own
  still looks broken: it gives the new window no focus, and the same click dismisses the panel,
  which deactivates the app and leaves the window behind whatever was in front. `SettingsWindow`
  watches for it and raises it — a `simultaneousGesture` on `SettingsLink` never fires, so the
  click cannot be hooked. Raising is itself two things: the app becomes `.regular` while the
  window is open, because an `.accessory` app does not win an activation contest, and the window
  floats while it is open, because an app that re-activates itself a second later would
  otherwise cover it. It reverts to a menu bar app on close.
- **"เครื่องนี้: 0 tok · 0 ข้อความ"** — Claude Code recomputes `stats-cache.json` lazily, so
  today's entry is regularly missing on a machine that has been busy since morning. The panel
  and the settings pane now name the day the cache actually covers and show its figures instead
  of a zero that reads as "you did nothing".

### Changed
- **The menu bar shows bars only.** The percentage beside them named one account's number
  while the glyph is about all of them at a glance, and the colour already says the same
  thing. The "แสดง %" toggle in ตั้งค่า → การแสดงผล goes with it.
- **Two columns.** Accounts sit side by side, so two of them take the height one used to. The
  panel is only as wide as the columns it shows: one account keeps it narrow.
- **Per-model weekly caps share one row.** They all reset together and there can be any number
  of them, so the fullest model gets the bar and the label, the others are marks on the same
  track plus one small line of figures. `Claude Design` displays as `Design`.
- **Dark, in Claude's own colours**, whatever the Mac is set to — a translucent light popover
  picks up whatever wallpaper is behind it. Near-black surface, raised cards, and a warm ramp
  (sage → gold → terracotta → clay) with Claude's `#D97757` where a bar starts asking for
  attention. Only the panel's window is switched: the menu bar glyph keeps system colours
  because it has to match the real menu bar, and the settings window stays a normal Mac window.
- Reset countdowns lost their wall-clock half to buy the width; it is a tooltip now.
- `optional_host_permissions: http://127.0.0.1/*`. Optional on purpose: a plain install carries
  no new permission, and Chrome only asks when the bridge is switched on.
- The badge's binding-limit tracking follows 1.7.2's move to dynamic per-model categories
  instead of naming Opus, so a new model is picked up without a code change.

---

## [1.7.3] — 2026-07-31

### Fixed
- **Removed unnecessary `tabs` permission** — the Chrome Web Store flagged the `tabs` permission as excessive (policy "Purple Potassium"). The extension only uses `chrome.tabs.create({ url })`, which does not require the `tabs` permission (that permission is only needed to read sensitive tab properties like url/title of existing tabs). Removing it resolves the compliance warning with no loss of functionality.

---

## [1.7.2] — 2026-07-23

### Added
- **Fable weekly quota** — the new Fable model now appears as a weekly category
- **Dynamic per-model categories** — weekly model breakdowns are now rendered dynamically from the API's new `limits` array, so any current or future model (Fable, Sonnet, Opus, Design, ...) shows up automatically with the name and reset time the API provides

### Fixed
- **Per-model bars broken by API change** — the API moved per-model quota from individual `seven_day_*` fields (now returning null) to a structured `limits` array with `weekly_scoped` entries; the extension now reads the new format, with a fallback to the legacy fields
- **Wrong organization selected on multi-org accounts** — accounts with a separate API organization could have the extension pick the wrong org (`orgs[0]`); it now prefers the organization with the `chat` capability
- **BOM in locale files** — messages.json files written during 1.7/1.7.1 packaging contained a UTF-8 BOM; removed for clean JSON parsing

### Changed
- `setBar()` simplified to preserve any `bar--*` color modifier generically instead of a hardcoded list
- Removed now-unused locale keys `weekly_sonnet`, `weekly_opus`, `weekly_design` (per-model labels come from the API's `display_name`)

---

## [1.7.1] — 2026-06-03

### Added
- **Claude Opus weekly bar** — new category in the weekly section (purple `#7c3aed`), shown only when the quota exists for the account
- **Sonnet-only weekly bar** — new category tracking `seven_day_sonnet` quota (cyan `#0e7490`)
- **Usage Credits section** — displays monthly credit spending (`extra_usage`) with a monetary progress bar and `Intl.NumberFormat` currency formatting; collapsible with state persisted in `chrome.storage.local`

### Fixed
- **`setBar` color loss on re-render** — function was rebuilding `className` without preserving `bar--sonnet`, `bar--opus`, `bar--design`, `bar--extra` modifiers; now restores all modifier classes before reassigning
- **Plan name not updating after subscription change** — `background.js` spread was preserving stale `plan` value on every poll; now re-fetches from `rate_limit_tier` / `capabilities` fields on each background cycle
- **Plan display for Max plans** — API exposes plan via `rate_limit_tier` (e.g. `default_claude_max_5x`), not `plan`/`plan_nickname`; mapped via `formatPlan()` lookup table

### Improved
- Popup width increased 280px → 290px for better horizontal breathing room
- Spacing compacted (container gap, weekly-row padding, footer gap) to stay within Chrome's 600px popup height cap

### Localization
- New strings (`weekly_sonnet`, `weekly_opus`, `extra_usage_label`, `extra_usage_limit`) fully translated in all 10 languages

---

## [1.7] — 2026-05-04

### Added
- **Review reminder** — after 10 popup opens, a chip appears prompting the user to rate the extension on the Chrome Web Store, with three options: *Rate now*, *Maybe later* (snoozes by 20 opens), *Don't remind me*
- **Star rating button** — persistent shortcut in the popup footer to open the Chrome Web Store review page directly, with an ×-dismiss button visible on hover
- **Inverted theme on review chip** — chip uses a light background in dark mode and a dark background in light mode, making it visually prominent in both themes
- **Independent dismiss logic** — dismissing the star button (×) and the chip ("Don't remind me") are tracked separately via `starDismissed` and `reviewState` storage keys; "Rate now" marks both as done

### Localization
- New strings (`review_prompt`, `review_rate`, `review_later`, `review_never`, `review_star_label`, `review_star_title`) fully translated in all 10 languages

---

## [1.6] — 2026-04-29

### Added
- **Dark / light theme toggle** — button in the popup header (🌙 / ☀️) switches between themes; preference is persisted via `chrome.storage.local` and falls back to `prefers-color-scheme` on first launch
- **Website link** — globe icon in the popup header links to claudequotamonitor.github.io
- **Language switcher on the onboarding page** — same dropdown experience as the website, with preference stored in `localStorage`

### Improved
- **Reset timer shows days** — times ≥ 24 h are now formatted as `Xd Yh Zm` instead of a raw hour count (e.g. `6d 17h 36m` instead of `161h 36m`)
- **Badge tooltip** — hovering the extension icon now shows a concise usage summary: *Session · Weekly · Claude Design* percentages
- **Localized time units** — day / hour / minute abbreviations adapted for all 10 supported languages

### Localization
- New strings (`time_days`, `time_hours`, `time_mins`, `visit_website`, `theme_to_light`, `theme_to_dark`) fully translated in all 10 languages
- Onboarding page now has a standalone JS-based i18n system (independent of `chrome.i18n`) enabling the in-page language switcher; title gradient on *Claude Quota* restored

---

## [1.5] — 2026-04-19

### Added
- **Claude Design quota** — the weekly section now shows two categories: *All models* and *Claude Design*, each with usage percentage and reset time
- **Onboarding page** — shown automatically on first install, guiding users through setup in 4 steps (including browser-specific instructions to pin the extension)
- **Automated test suite** — 25 tests covering popup rendering, bar colors, i18n strings, and time formatting (`npm test`)

### Improved
- Extension icon completely redrawn at high resolution (vectorially rendered at 8×, 4×, and 2× scale for 16px, 48px, and 128px sizes)
- Icon arc rotation corrected; track arc contrast improved
- Popup title updated to full name: **Claude Quota Monitor**
- All marketing assets (X banner, YouTube banner, thumbnail) updated with corrected icon

### Fixed
- Extension icon was missing from the `chrome://extensions/` list (missing top-level `icons` field in `manifest.json`)

### Localization
- Onboarding page fully translated in all 10 supported languages
- New strings added: weekly category labels, pill labels, step 4 pin instructions (browser-aware: Chrome, Brave, Edge, Arc)

---

## [1.4.1] — 2026-04-18

### Added
- **Onboarding page** — shown automatically on first install, guiding users through setup in 4 steps with browser-specific instructions to pin the extension (Chrome, Brave, Edge, Arc)
- Onboarding page translated in all 10 supported languages

### Fixed
- Badge not restored correctly after browser restart in some cases

---

## [1.4] — 2026-03-18

### Added
- Initial public release on the Chrome Web Store
- Session quota tracking (5-hour window) with color-coded toolbar badge (green → orange at 70% → red at 90%)
- Weekly quota tracking (7-day window) with reset timer
- Auto background refresh every 10 minutes via `chrome.alarms`
- MutationObserver-based refresh triggered after each Claude response
- Donation link (Ko-fi) in popup footer

### Localization
- Full UI in 10 languages: English, Portuguese (BR), Spanish, French, Arabic, Bengali, Hindi, Indonesian, Russian, Chinese (Simplified)

---

## [1.3] — 2026-04-17

### Added
- Internationalization (i18n) infrastructure using `_locales/` and `chrome.i18n`
- Support for 10 languages: English, Portuguese (BR), Spanish, French, Arabic, Bengali, Hindi, Indonesian, Russian, Chinese (Simplified)
- RTL layout support for Arabic
- Store listing descriptions written in all 10 languages

---

## [1.2] — 2026-04-17

### Added
- Extension icons at all required sizes (16px, 48px, 128px) rendered from SVG source
- Toolbar badge showing current session usage percentage

### Improved
- Popup UI redesigned with inline SVG logo, removing any external asset dependencies
- Visual consistency across light and dark browser themes

---

## [1.1] — 2026-04-16

### Added
- MutationObserver in content script to detect when Claude finishes a response and trigger an automatic data refresh (~2 seconds after each reply)
- Retry logic with exponential backoff (3s → 8s → 20s → 60s) for API calls that fail during login or page load
- Auto-fetch when popup is opened and no cached data is available yet

### Improved
- Empty state handling in popup when extension is freshly installed

---

## [1.0] — 2026-04-15

### Added
- Initial working version
- Content script intercepts fetch requests to `claude.ai/api/organizations/{uuid}/usage` and captures session and weekly quota data
- Data stored locally via `chrome.storage.local`
- Background service worker with `chrome.alarms` polling every 10 minutes
- Popup displaying session usage percentage and reset time
- CSP bypass via `chrome.scripting.executeScript` with `world: 'MAIN'`

---
