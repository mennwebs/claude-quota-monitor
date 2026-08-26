# Claude Quota Monitor

> Track your Claude.ai quota usage directly in the browser toolbar — no setup required.

[![Chrome Web Store](https://img.shields.io/chrome-web-store/v/gpeogkjjkpmdjgggeaegmnmlmikgkjjm?label=Chrome%20Web%20Store&color=a78bfa)](https://chromewebstore.google.com/detail/claude-quota-monitor/gpeogkjjkpmdjgggeaegmnmlmikgkjjm)
[![License: MIT](https://img.shields.io/badge/License-MIT-a78bfa.svg)](LICENSE)
[![Users](https://img.shields.io/chrome-web-store/users/gpeogkjjkpmdjgggeaegmnmlmikgkjjm?color=a78bfa)](https://chromewebstore.google.com/detail/claude-quota-monitor/gpeogkjjkpmdjgggeaegmnmlmikgkjjm)

## Features

- **Session usage** — current 5-hour window with color-coded progress bar
- **Weekly usage** — 7-day quota for all models and Claude Design separately
- **Reset timer** — time remaining until each quota resets
- **Toolbar badge** — usage % always visible; turns orange at 70%, red at 90%
- **Auto refresh** — updates every 10 minutes and after each Claude response
- **10 languages** — English, Portuguese (BR), Spanish, French, Arabic, Bengali, Hindi, Indonesian, Russian, Chinese (Simplified)
- **Private by design** — no account, no tracking, no data collection

## Installation

Install directly from the **[Chrome Web Store](https://chromewebstore.google.com/detail/claude-quota-monitor/gpeogkjjkpmdjgggeaegmnmlmikgkjjm)**.

## How it works

The extension reads quota data from the `claude.ai/api/organizations/*/usage` endpoint when you visit claude.ai, storing it locally via `chrome.storage.local`. No data ever leaves your browser.

**Permissions used:**
| Permission | Purpose |
|---|---|
| `storage` | Persist quota data between sessions |
| `alarms` | Schedule background refresh |
| `host_permissions: claude.ai` | Read quota data from the Claude API |
| `optional_host_permissions: 127.0.0.1` | Only if you turn on the macOS menu bar bridge. Requested at that point, never on install |

## macOS menu bar bridge

If you run several Claude accounts in several Chrome profiles, this fork can push each
profile's reading to the macOS menu bar app in [`mac/`](mac/) — one bar per account, with reset
times, and readings greyed out once they go stale.

The app lives in this repo because the two halves share a wire contract
([`docs/protocol.md`](docs/protocol.md)); changing it on one side without the other is the
mistake worth making impossible. The extension stays at the repo root so merges from upstream
keep applying cleanly.

Right-click the toolbar icon → **Options**, tick *Send readings to the Mac app*, paste the
token from the app, and press **Save & connect**. Repeat in every profile.

It talks to `127.0.0.1` and nothing else. That host permission is **optional** — a plain install
does not hold it, and Chrome only asks when you press Save & connect. With the bridge off,
`bridge.js` makes no requests at all.

Re-posting the cached reading is free on claude.ai's side, so the bridge pushes every minute
while the quota fetch stays on its slow poll. Request volume to claude.ai is unchanged.

## Development

### Prerequisites

- Node.js 18+
- npm

### Setup

```bash
git clone https://github.com/claudequotamonitor/claude-quota-monitor.git
cd claude-quota-monitor
npm install
```

### Load the extension in Chrome

1. Open `chrome://extensions`
2. Enable **Developer mode** (top right)
3. Click **Load unpacked** and select this folder

### Run tests

```bash
npm test
```

The test suite covers popup rendering, bar colors, i18n strings, time formatting, and the
bridge's payload builder. The bridge suite needs no browser:

```bash
npm run test:bridge   # bridge only, no browser needed
npm run test:mac      # the Swift app's own checks
```

## Project structure

```
claude-quota-monitor/
├── manifest.json          # Extension manifest (MV3)
├── background.js          # Service worker — refresh scheduler, badge updates
├── bridge.js              # macOS menu bar bridge — loopback push (opt-in)
├── options.html/css/js    # Bridge settings
├── content.js             # Injected into claude.ai — captures quota from API
├── popup.html/css/js      # Extension popup UI
├── onboarding.html/css/js # First-install welcome page
├── icons/                 # Extension icons (16, 48, 128px)
├── _locales/              # i18n strings (10 languages)
├── tests/                 # Automated test suite
├── docs/protocol.md       # Wire contract between the extension and the Mac app
└── mac/                   # macOS menu bar app (Swift, no dependencies)
```

## Changelog

See [CHANGELOG.md](CHANGELOG.md) for version history.

## Contributing

Bug reports and pull requests are welcome! Please open an issue first to discuss what you'd like to change.

## Privacy

This extension does not collect, store, or transmit any personal data. See the full [Privacy Policy](https://claudequotamonitor.github.io/privacy-policy.html).

## Support

- **Email:** claudequotamonitor@gmail.com

## Sponsor

[![ko-fi](https://ko-fi.com/img/githubbutton_sm.svg)](https://ko-fi.com/A0A11Y1RAC)

## Disclaimer

This project is not affiliated with or endorsed by Anthropic.

## License

[MIT](LICENSE) © 2026 The Claude Quota Monitor team
