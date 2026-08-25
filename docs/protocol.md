# Wire protocol

One writable route, on loopback only.

## `POST /v1/usage`

Headers: `Content-Type: application/json`, `X-CQM-Token: <token from the app>`

```json
{
  "v": 1,
  "source": "extension",
  "browser": "Chrome",
  "account": {
    "uuid":    "85eb22d5-…",
    "email":   "you@example.com",
    "orgId":   "86316975-…",
    "orgName": "SeedWebs",
    "plan":    "default_claude_max_5x"
  },
  "observedAt": 1787648000,
  "limits": {
    "five_hour":        { "pct": 47.0, "resetsAt": 1787660000 },
    "seven_day":        { "pct": 22.0, "resetsAt": 1788000000 },
    "seven_day_opus":   { "pct": 61.0, "resetsAt": 1788000000 },
    "seven_day_sonnet": { "pct":  5.0, "resetsAt": 1788000000 },
    "seven_day_design": { "pct":  0.0, "resetsAt": 1788000000 }
  },
  "extra": { "enabled": true, "used": 12, "limit": 50, "currency": "USD" }
}
```

- `observedAt` and `resetsAt` accept unix seconds, millisecond epochs, or ISO-8601. They are
  normalized to seconds on the way in.
- `observedAt` is clamped to arrival time. A sender with a fast clock must not win every merge.
- Unknown keys in `limits` are ignored; a report with no recognized limit is rejected, because
  an empty report would refresh a row's timestamp without refreshing its numbers.
- Identity is matched account → email → org, in that order. Several accounts can belong to one
  Team organization, so `orgId` alone is not an identity.

Reply:

```json
{ "ok": true, "refresh": false }
```

`refresh: true` means the user pressed Refresh in the menu bar. That is the only way the Mac
side can reach into the browser: the sender should spend one real fetch and post the result.

## `GET /v1/health`

Unauthenticated, so a client can tell "app is not running" from "token is wrong".

```json
{ "ok": true, "app": "claude-quota-mac", "v": 1 }
```

## Everything else

`OPTIONS` returns 204. Any other path returns 404. Bodies over 256 KB return 413. CORS headers
are echoed back only for a `chrome-extension://` origin.

## The status line source

The shim writes Claude Code's status line payload verbatim to `cli.json`. The app reads only
`rate_limits.{five_hour,seven_day}.{used_percentage,resets_at}` from it, takes the observation
time from the file's mtime, and takes the account identity from `oauthAccount` in
`~/.claude.json`. A half-written file simply fails to parse and is picked up on the next tick.
