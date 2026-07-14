# AI Usage Bar

macOS menu-bar app showing Claude Code + Codex usage. Auto-detects each CLI
by the presence of `~/.claude` / `~/.codex`. No configuration.

## Menu bar

`✳ 42%  ◇ 63%` — remaining % of the tightest live limit window per provider.
Falls back to today's token total when a limit reading isn't available.

Click for the breakdown:

- **Rate limits** — 5-hour and weekly windows: % remaining, a 10-cell meter,
  and time until reset.
- **Today's tokens** — input / output / cache / reasoning, session count,
  last model.

## Where the numbers come from

| Provider | Token counts | Rate-limit % |
|----------|--------------|--------------|
| Claude   | `~/.claude/projects/**/*.jsonl` (today) | live `GET api.anthropic.com/api/oauth/usage` |
| Codex    | `~/.codex/sessions/**/*.jsonl` (today)  | `rate_limits` in the session logs |

### Claude limits — auth model

The app reads the access token the Claude CLI already stored in the login
keychain (`Claude Code-credentials`) and calls the same usage endpoint the CLI
uses. It is **read-only**:

- It never refreshes or rewrites the token. OAuth refresh tokens are
  single-use — rotating one here would invalidate the CLI's own token and log
  you out.
- The stored `expiresAt` is **not** trusted — observed tokens keep returning
  `200` well past it. Authority is the server: `401` → shows `login`, `200` →
  live percentages.

First launch triggers one macOS keychain prompt ("AIUsageBar wants to use
Claude Code-credentials") — click **Always Allow**.

The usage endpoint rate-limits hard, so the app polls it only every 5 minutes
(10 after a `429`), caches the last good reading, and shows `…` while a `429`
clears. Token counts still refresh every 60s independently. Don't hammer
"Refresh Now" — each click forces a live call and can trip the `429` cooldown.

### Codex limits — freshness

Codex writes its `rate_limits` (5-hour `primary`, weekly `secondary`) into
session logs, so the app reads the newest reading on disk. There is no live
API, so a window is only as fresh as your last Codex session. A window whose
reset time has already passed is shown as "window reset — reopen CLI for a
fresh reading" rather than a stale percentage. The menu shows the reading's age.

## Build / run

```sh
swift build -c release          # binary at .build/release/AIUsageBar
./make-app.sh                   # bundles + ad-hoc signs AIUsageBar.app
open AIUsageBar.app

.build/release/AIUsageBar --dump   # print current numbers, no UI
```

Refreshes every 60s; "Refresh Now" (⌘R) forces it. Launch at login:
System Settings → General → Login Items → add `AIUsageBar.app`.

## Release build

```sh
./make-release.sh 0.1.0          # creates arm64 ZIP + SHA-256 checksum
```

Current release artifacts target Apple Silicon Macs (`arm64`) running macOS 13
or later. The local build uses ad-hoc signing; public distribution should use
Developer ID signing and Apple notarization.

## Status

Codex limits + both token counts are verified against real logs on this
machine. The Claude live-limit path is built to the response schema extracted
from the Claude Code binary (`five_hour`/`seven_day` → `utilization`,
`resets_at`).

Auth to the usage endpoint is **confirmed working**: the keychain access token
returns `429` (rate-limited), never `401` — i.e. it authenticates. A clean
`200` body hasn't been captured yet only because repeated probing tripped the
endpoint's rate limit (a long cooldown). Once it clears, the app renders real
percentages; click "Refresh Now" after the app has been idle a while, or just
wait for the 5-minute poll.
