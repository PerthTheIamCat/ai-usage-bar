# AI Usage Bar

> See Claude Code and Codex usage before a limit surprises you.

AI Usage Bar is a small macOS menu-bar app for people who use Claude Code,
Codex, Antigravity, or any combination of the three. It shows today's token
activity and the remaining time and percentage in each provider's active
rate-limit window.

[Download a preview release](https://github.com/PerthTheIamCat/ai-usage-bar/releases)
· [Report an issue](https://github.com/PerthTheIamCat/ai-usage-bar/issues)

**Requirements:** macOS 13 or later · Apple Silicon · at least one supported
provider already installed and signed in.

## What it shows

`✳ 42%  ◇ 63%` in the menu bar means the tightest remaining limit for the
detected providers. Click it for the full picture:

- **Rate limits** — remaining percentage, 5-hour and weekly windows, a compact
  meter, and reset time.
- **Today's tokens** — input, output, cache, reasoning, session count, and the
  most recent model.
- **Freshness** — when a value was last updated, so an old Codex session does
  not look like a current limit reading.
- **Session explorer** — expand today's Claude Code and Codex sessions to see
  the skills and tools used, with an estimated cost for each session, skill,
  and tool.

No setup screen. The app detects the CLIs from `~/.claude` and `~/.codex`.

## Install and use

1. Open the [Releases](https://github.com/PerthTheIamCat/ai-usage-bar/releases)
   page and download the `macos-arm64.zip` file.
2. Double-click the ZIP, then move `AIUsageBar.app` to `/Applications` if you
   want to keep it there.
3. Open `AIUsageBar.app`.
   - Current preview builds use ad-hoc signing. If macOS blocks the first
     launch, Control-click the app, choose **Open**, then confirm **Open**.
4. Configure the Claude Code local status-line bridge once. From a source
   checkout, run `./Scripts/install-claude-statusline.sh` after placing the
   app in `/Applications`. For a custom app location, set `AI_USAGE_BAR_BIN`
   to the app executable before running the installer. The installer only
   installs the bridge script and prints the `statusLine` snippet; it never
   modifies an existing Claude Code configuration.
5. Click the menu-bar icon whenever you want the detailed breakdown. Press
   `⌘R` or choose **Refresh Now** to reread local snapshots.
6. From version 0.2.0 onward, the app checks for updates automatically. Use
   **Check for Updates…** from the menu whenever you want to check now.

To start it automatically: **System Settings → General → Login Items → Add**
`AIUsageBar.app`.

## How data is handled

| Provider | Today's usage | Rate-limit reading |
| --- | --- | --- |
| Claude | Local Claude Code session logs | Local snapshot supplied by Claude Code `statusLine` |
| Codex | Local Codex session logs | Latest `rate_limits` entry written by Codex |
| Antigravity | Local activity data | Local quota snapshot |

The app never reads, refreshes, rotates, or writes Claude credentials. Claude
limit snapshots contain only the `rate_limits` fields supplied to the local
status-line command; prompt and transcript content is not stored by the
bridge. Codex readings are local and are only as fresh as the latest Codex
session that wrote them.

Claude limits are reread from the local snapshot every minute. If Claude Code
has not supplied a newer snapshot for 30 minutes, AI Usage Bar marks it stale
and keeps the last known value; it never falls back to an HTTP request.
Claude Code's documented `statusLine` input includes the 5-hour and 7-day
`rate_limits` fields. See the [Claude Code status line documentation](https://code.claude.com/docs/en/statusline).

The provider panes show the three most recent sessions first; choose **Show all**
to expand the complete list. Explicit Claude `customTitle` and Codex
`thread_name_updated` metadata are shown as session titles when available,
with a workspace/ID fallback when a provider has not supplied one. Expand an
individual session to see the named Claude skills and tools recorded in its
local log. Codex tool calls are read from `function_call` /
`custom_tool_call` records; Codex skills are marked **inferred** when a tool
argument references a `SKILL.md` file because Codex does not emit a dedicated
skill event. Only session titles, IDs, timestamps, token totals, names, counts,
and derived cost estimates are used for this view — prompt text and tool
arguments are not saved or displayed by AI Usage Bar.

## Customize providers and reports

Open **Settings → Providers** to configure every supported provider (Claude
Code, Codex, and Antigravity) independently:

- reorder providers and show/hide them separately in the menu bar and popover;
- choose a menu-bar style per provider: Bar, Ring, Percent only, Bar + percent,
  Ring + percent, or Dot + percent;
- choose which rate-limit windows and detail rows each provider exposes.

The popover's **Export…** menu can copy a Markdown report, JSON, or CSV, or
save a CSV file. JSON/CSV exports include session-level skill/tool cost
estimates. In **Settings → General**, session alerts can notify when a session
crosses a token threshold, while privacy toggles hide session IDs and workspace
names from the popover and exports. Session summaries are cached by local log
file fingerprint so refreshes do not rescan unchanged files.
On startup, today's provider data is shown before the heavier 7-/30-day cost
and trend scan finishes; the menu bar and popover footer show the current
loading phase while that background work runs.

## Limits to know

- Release builds currently target Apple Silicon (`arm64`) only.
- A Codex limit window may be stale until you open Codex again.
- Claude limit data may be stale until Claude Code produces another
  status-line update.
- Preview releases are not yet Developer ID signed or notarized. The first
  install may still need the Control-click → **Open** step above.

## Build from source

```sh
swift build -c release
./make-app.sh
open AIUsageBar.app

# Print current readings without opening the menu-bar UI
.build/release/AIUsageBar --dump
```

## Releases for maintainers

Push a version tag such as `v0.2.1`. GitHub Actions builds an Apple Silicon ZIP
and SHA-256 checksum, publishes a prerelease, then signs and deploys the
Sparkle update feed to GitHub Pages. The private Sparkle key is stored only as
the `SPARKLE_PRIVATE_KEY` repository secret; never commit it. For a tag that
already exists, run **Publish release** manually from GitHub Actions and enter
the tag name.

```sh
./make-release.sh 0.2.1 3
```

## License

[MIT](LICENSE)
