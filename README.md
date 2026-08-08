# AI Usage Bar

> See Claude, Codex, and Antigravity usage before a limit surprises you.

AI Usage Bar is a small macOS menu-bar app for people who use Claude Code,
Codex, Antigravity, or any combination of the three. It shows today's token
activity and the remaining time and percentage in each provider's active
rate-limit window.

[Download a preview release](https://github.com/PerthTheIamCat/ai-usage-bar/releases)
· [Report an issue](https://github.com/PerthTheIamCat/ai-usage-bar/issues)

**Requirements:** macOS 13 or later · Apple Silicon · at least one supported
provider already installed and signed in. On macOS 26 (Tahoe) the popover's
panels render as real Liquid Glass; earlier versions get an equivalent
translucent treatment with no missing functionality.

## What it shows

`✳ 42%  ◇ 63%` in the menu bar means the tightest remaining limit for the
detected providers. Click it and the popover opens on **Overview** — the
question it exists to answer, and nothing else:

- **Lowest remaining** — a headline ring for the single tightest window across
  every provider, so "how much do I have left right now" never needs
  hunting for.
- **A card per provider** — 5-hour and weekly meters, reset time, and today's
  tokens/cost, nothing more.
- **A depletion warning** when the current pace projects hitting a window's
  limit before it resets — fit from recent readings, not a fixed guess.
- **"Switch there for now"** when one provider is critically low and another
  has real headroom, with a tap straight to it.

Tap a provider's card for the full detail pane: token breakdown, today's
sessions (skills and tools used, with a per-item cost estimate), model
breakdown, and 7-/30-day cost trends — all one click away rather than the
default view. No setup screen for the app itself; it detects the CLIs from
`~/.claude` and `~/.codex` on its own.

## Install and use

1. Open the [Releases](https://github.com/PerthTheIamCat/ai-usage-bar/releases)
   page and download the `macos-arm64.zip` file.
2. Double-click the ZIP, then move `AIUsageBar.app` to `/Applications` if you
   want to keep it there.
3. Open `AIUsageBar.app`.
   - Current preview builds use ad-hoc signing. If macOS blocks the first
     launch, Control-click the app, choose **Open**, then confirm **Open**.
4. Claude reads work differently depending on how you use Claude:
   - **Claude Desktop app** — nothing to configure. AI Usage Bar reads its
     local plan-usage file directly; open the popover after using Claude once
     and a reading appears.
   - **Claude Code (CLI)** — needs the local statusLine bridge once. The
     popover's Overview pane shows a **Set Up Status Line Bridge** button when
     no reading exists yet; it installs the bridge script and adds the
     `statusLine` entry to `~/.claude/settings.json` itself, backing the file
     up first and never touching an existing different `statusLine` command.
     To do it by hand instead, run `./Scripts/install-claude-statusline.sh`
     after placing the app in `/Applications` (set `AI_USAGE_BAR_BIN` first
     for a custom app location) — it only installs the bridge script and
     prints the snippet to add yourself.
5. Click the menu-bar icon whenever you want the detailed breakdown. Press
   `⌘R` or choose **Refresh Now** to reread local snapshots.
6. From version 0.2.0 onward, the app checks for updates automatically. Use
   **Check for Updates…** from the menu whenever you want to check now.

To start it automatically: **System Settings → General → Login Items → Add**
`AIUsageBar.app`.

## How data is handled

| Provider | Today's usage | Rate-limit reading |
| --- | --- | --- |
| Claude | Local Claude Code session logs | Claude Code's local `statusLine` snapshot, or the Claude Desktop app's own local usage file — whichever is fresher |
| Codex | Local Codex session logs | Latest `rate_limits` entry written by Codex |
| Antigravity | Local activity data | Local quota snapshot |

The app never reads, refreshes, rotates, or writes Claude credentials. Claude
limit snapshots contain only the `rate_limits` fields supplied to the local
status-line command (or the used-percentage fields from the Desktop app's own
file); prompt and transcript content is never stored. Codex readings are
local and are only as fresh as the latest Codex session that wrote them.

Both Claude sources are watched directly, so a new reading is picked up
within seconds rather than waiting for the next refresh. If neither source
has supplied one for 30 minutes, AI Usage Bar marks it stale and keeps the
last known value; it never falls back to an HTTP request. The Desktop app
samples every few minutes rather than continuously — between its samples,
the 5-hour figure is projected forward from Claude Code tokens logged since
the last sample (shown with a leading `~`), calibrated from your own recent
readings rather than an assumed formula. The Desktop app's file carries no
reset time, unlike the statusLine bridge's `rate_limits` payload, so a
Desktop-only reading has no "resets in" caption. See the
[Claude Code status line documentation](https://code.claude.com/docs/en/statusline).

The provider panes show the three most recent sessions today; the full list
is available through **Export…**. Claude session titles use the manually-set
`customTitle` when present, falling back to Claude's automatic `ai-title`;
Codex sessions fall back to the workspace name, since Codex does not write a
title of its own. Expand an individual session to see the named Claude
skills and tools recorded in its local log. Codex tool calls are read from
`function_call` / `custom_tool_call` records; Codex skills are marked
**inferred** when a tool argument references a `SKILL.md` file because Codex
does not emit a dedicated skill event. Only session titles, IDs, timestamps,
token totals, names, counts, and derived cost estimates are used for this
view — prompt text and tool arguments are not saved or displayed by AI Usage
Bar.

Claude's 7-/30-day cost totals and the Analytics trend chart are backed by a
local day-by-day history file. Claude Code (and Codex) prune local session
logs after roughly a month; each day's totals are captured to that file the
first time they're observed with real activity, so a day's numbers survive
even after its source log is gone.

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
  status-line update, or the Desktop app writes its next sample.
- The depletion warning and the between-sample Claude projection are both
  fit from your own recent readings, not a published formula — early on, or
  right after a long idle stretch, there may not be enough recent signal for
  either to say anything yet.
- Preview releases are not yet Developer ID signed or notarized. The first
  install may still need the Control-click → **Open** step above.
- **Updating from a version before 0.10.0**: the app's bundle identifier
  changed (a macOS-side issue was preventing some installs from ever getting
  a menu bar icon at all — see the 0.10.0 release notes). The in-app updater
  cannot bridge that change, so update by downloading the ZIP and replacing
  `AIUsageBar.app` by hand once; your settings carry over automatically on
  first launch.

## Build from source

```sh
swift build -c release
./make-app.sh
open AIUsageBar.app

# Print current readings without opening the menu-bar UI
.build/release/AIUsageBar --dump

# Run the test suite (pure-logic coverage: burn-rate regression, the daily-
# history backfill, the byte-scan log scanner, Claude's calibration math)
swift test
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
