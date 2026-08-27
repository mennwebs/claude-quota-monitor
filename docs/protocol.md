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
    "uuid":    "00000000-0000-4000-8000-000000000001",
    "email":   "you@example.com",
    "orgId":   "00000000-0000-4000-8000-0000000000ff",
    "orgName": "Your Org",
    "plan":    "default_claude_max_5x"
  },
  "observedAt": 1787648000,
  "limits": {
    "five_hour":            { "pct": 47.0, "resetsAt": 1787660000 },
    "seven_day":            { "pct": 22.0, "resetsAt": 1788000000 },
    "weekly:opus":          { "pct": 61.0, "resetsAt": 1788000000, "label": "Opus" },
    "weekly:fable":         { "pct": 34.0, "resetsAt": 1788000000, "label": "Fable" },
    "weekly:claude-design": { "pct":  7.0, "resetsAt": 1788000000, "label": "Claude Design" }
  },
  "extra": { "enabled": true, "used": 12, "limit": 50, "currency": "USD" }
}
```

- `observedAt` and `resetsAt` accept unix seconds, millisecond epochs, or ISO-8601. They are
  normalized to seconds on the way in.
- `observedAt` is clamped to arrival time. A sender with a fast clock must not win every merge.
- The key space is **open**. `five_hour` and `seven_day` are the two structural ceilings;
  everything else is `weekly:<slug>` for a per-model weekly cap, with `label` carrying the
  name to display. claude.ai moved these out of fixed `seven_day_opus`-style fields — which now
  return null — into a dynamic list, so Fable appeared unannounced and the next model will too.
  Neither side names a model anywhere.
- `slug` is the display name lowercased with runs of non-alphanumerics collapsed to `-`, capped
  at 32 characters. Keys that do not fit that shape are dropped, and a single report may carry
  at most 16 limits: open-ended is not the same as unbounded.
- The old `seven_day_opus` / `seven_day_sonnet` / `seven_day_design` keys are still accepted and
  translated, so a profile running an older extension build keeps reporting.
- A report with no recognized limit is rejected, because an empty report would refresh a row's
  timestamp without refreshing its numbers.
- Identity is matched account → email → browser profile → org, in that order. Several accounts
  can belong to one Team organization, so `orgId` alone is not an identity.
- `browser` is part of that chain, not decoration. claude.ai has stopped answering the
  extension's account lookup before, and a report that names only its organization is otherwise
  indistinguishable from a second account in the same Team org — so it would open a second row
  for an account that already has one, permanently. A profile is signed into one account at a
  time, so such a report is filed under the row that profile is already feeding, and only when
  exactly one row is a candidate. Send the same `browser` string from a given profile every
  time; changing it is the same as arriving as a new source.

Reply:

```json
{ "ok": true, "refresh": false }
```

`refresh: true` means the user pressed Refresh in the menu bar. That is the only way the Mac
side can reach into the browser: the sender should spend one real fetch and post the result.

The flag stays raised for 90 seconds rather than being consumed by the first caller. Each
profile checks in on its own minute, so a destructive read would refresh one account and leave
the rest untouched — which is not what pressing Refresh means.

## `GET /v1/health`

Unauthenticated, so a client can tell "app is not running" from "token is wrong".

```json
{ "ok": true, "app": "claude-quota-mac", "v": 1 }
```

## Everything else

`OPTIONS` returns 204. Any other path returns 404. Bodies over 256 KB return 413. CORS headers
are echoed back only for a `chrome-extension://` origin.

Every local process can reach the port, so a connection is cancelled 10 seconds after it is
accepted and at most 32 are held at once. A peer that opens a socket and never finishes a
request cannot hold a file descriptor, or crowd out the request that matters.

## The status line source

The shim writes Claude Code's status line payload verbatim to `cli.json`. The app reads only
`rate_limits.{five_hour,seven_day}.{used_percentage,resets_at}` from it, takes the observation
time from the file's mtime, and takes the account identity from `oauthAccount` in
`~/.claude.json`. A half-written file simply fails to parse and is picked up on the next tick.
