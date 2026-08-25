# Changelog

All notable changes to Claude Quota Monitor are documented here.

---

## [Unreleased] — macOS menu bar bridge

### Added
- `bridge.js` — pushes the reading this extension already has to a menu bar app listening on
  `127.0.0.1`. Opt-in: with no token configured it makes no requests.
- Options page for the bridge (port, token, profile name), reachable from the toolbar icon's
  right-click menu.
- A one-minute push alarm. It re-sends the cached value and never touches claude.ai, so the Mac
  app is current within a minute of launching while request volume to claude.ai is unchanged.
- The app can ask for a real refresh in its reply to a push — the only path from the Mac back
  into the browser.
- `tests/test-bridge.js` — 23 checks over the payload builder, loaded from `bridge.js` itself
  rather than copied, so it cannot drift from what ships.

### Changed
- `optional_host_permissions: http://127.0.0.1/*`. Optional on purpose: a plain install carries
  no new permission, and Chrome only asks when the bridge is switched on.
- README's permission table no longer lists `tabs`, which was dropped in 5edcd50.


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
