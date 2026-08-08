# Changelog

All notable changes to AI Usage Bar are documented in this file.

## [0.10.3] - 2026-08-08

### Added

- **Depletion warnings.** Every comparable usage tracker in this space
  converges on the same feature independently, so it earned a spot here too:
  the 5-hour window's recent readings are fit to a straight line, and when
  the current pace projects hitting 100% before the window resets, the
  popover swaps the reset caption for "hits the limit around HH:MM" and a
  notification fires once per window instance (separate from the existing
  low-remaining alert, and never on an estimated Claude reading — an
  estimate that overshot would raise a warning the next real reading then
  contradicted). Pace is fit from the last 45 minutes of whatever readings
  the app already displays, kept on disk so a relaunch doesn't lose it, and
  reset automatically when a window rolls over.

## [0.10.2] - 2026-08-08

### Changed

- The projected five-hour figure now re-fits itself continuously. It used to
  derive its percent-per-token rate from the single previous interval, which
  made it swing with whatever that one interval happened to contain. It now
  fits across the last 16 readings, takes the median so an unusual interval
  cannot drag it, skips intervals where the window rolled over or where the
  token history does not reach back far enough, and re-fits every time a new
  real reading lands. Backtested against recorded samples, mean absolute
  error dropped from 3.5 to 1.9 percentage points and the worst case from
  12.0 to 8.9.
- Token history for today is now gathered in one cached pass instead of a
  fresh log scan per interval, so fitting over many intervals costs no more
  than fitting over one.

## [0.10.1] - 2026-08-08

### Fixed

- The popover looked like separate slabs stitched together. It draws on the
  system's vibrant material, but the sidebar and the Overview cards painted
  an opaque control colour over it while the footer stayed translucent, so
  parts of the panel showed the desktop through and parts did not. Those
  panels now use a light translucent fill layered on the same material, and
  the popover reads as one surface.
- Enabling Reduce Transparency now switches the popover to solid backgrounds
  instead of leaving translucent panels in place.

## [0.10.0] - 2026-08-08

### Important

- **Update manually from the release page.** The bundle identifier changed
  from `com.perth.aiusagebar` to `com.perththeiamcat.aiusagebar` (see below),
  so macOS treats this as a different app and the in-app updater cannot
  replace an older install. Download the ZIP, replace `AIUsageBar.app` in
  `/Applications`, and re-grant notification permission if you use alerts.
  Your settings carry over automatically on first launch.

### Fixed

- **The menu bar icon could stop appearing entirely.** The app ran, read
  usage correctly, and created its status item, but macOS refused to assign
  that item a menu bar slot and parked it off-screen — so the app looked like
  it never launched and there was no way to reach the popover. The state was
  held against the old bundle identifier and survived logout, preference
  resets, Launch Services cleanup, and Control Center restarts; changing the
  identifier is what releases it. Settings are migrated to the new domain on
  first launch.
- Startup pegged a CPU core and took ~45 seconds on large histories, which
  macOS's watchdog could terminate outright. Log lines are now scanned for
  their ASCII markers a byte at a time instead of through `String.contains`,
  which does full Unicode grapheme comparison; startup is ~11 seconds on the
  same data.
- The popover ignored the Remaining/Used setting and always printed
  remaining, while its meter and the menu bar honoured it — the same window
  read "11%" in one place and "89%" in another.
- Session rows showed the project folder rather than the session title.
  Claude Code's automatic `ai-title` is now read alongside a manually set
  title, with the manual one always winning. Codex writes no title of its
  own, so those rows still fall back to the workspace name.
- The menu bar flashed a placeholder on every refresh instead of only during
  the first load, and progress now goes to the tooltip and popover footer.
- Sidebar labels wrapped onto a second line when selected, and long provider
  names were clipped.
- A second copy of the app launching under the same identifier fought the
  first one over the status item; duplicate launches now exit immediately.
- Installing the Claude Code status line bridge into an empty
  `~/.claude/settings.json` produced invalid JSON.

### Added

- Claude limits are now read from the Claude Desktop app's own local usage
  file when the Claude Code status line bridge has no reading. Desktop-only
  users get limits with no setup at all, and whichever source is fresher
  wins.
- A **Set Up Status Line Bridge** button in the popover installs the Claude
  Code bridge in one click, backing up `~/.claude/settings.json` first and
  refusing to touch an existing `statusLine` entry.
- Both Claude limit sources are now watched directly, so a new reading shows
  up within seconds of being written instead of waiting for the next
  once-a-minute refresh.
- Between the Claude Desktop app's occasional samples, the five-hour figure
  is projected forward from the tokens actually logged since the last
  reading. The rate is calibrated from your own previous interval rather than
  an assumed formula, capped at one interval's worth of movement, shown with
  a leading `~`, and never used to raise a limit notification.

### Known limits

- Reset times are only available through the Claude Code status line bridge.
  The Desktop app's file carries percentages but no reset time, so those rows
  no longer show a permanently empty "resets in —" caption.

### Changed

- The popover opens on a new **Overview** pane built around the one question
  it exists to answer: a headline showing the single tightest window across
  every provider, then one compact card per provider with its meters, reset
  time, and today's tokens and cost. Token breakdowns, sessions, skills, and
  trends moved one click away into the per-provider tabs.
- Session lists show the three most recent of today's sessions with no
  expansion; skills and tools within a session are laid out as an aligned
  table with counts and costs in columns instead of one run-on paragraph.
  Full lists remain available through Export.
- The General settings menu-bar style control now applies to every provider.
  It was bound to a stored default that per-provider styles always shadowed,
  so changing it appeared to do nothing.
- The menu bar title dropped its redundant "AI" prefix and wide separators,
  which frees roughly 30pt of menu bar space.

## [0.9.0] - 2026-08-02

### Added

- Providers settings now covers Claude Code, Codex, and Antigravity with
  independent menu-bar/popover visibility, limit-window choices, detail rows,
  ordering, and six menu-bar styles (including combined meter + percentage
  styles).
- Session explorer rows show estimated cost per session and associated
  skill/tool costs. Reports can be copied as Markdown, JSON, or CSV, or saved
  as a CSV file.
- Optional large-session notifications, session ID/workspace privacy toggles,
  and fingerprint-based session-summary caching.

## [0.8.0] - 2026-07-25

### Changed

- Updates now ask before installing instead of installing silently in the
  background, so the "what's new" dialog with this release's notes actually
  shows up before you update. The release pipeline also embeds the matching
  CHANGELOG section directly in the update feed instead of only linking out
  to the GitHub release page.

### Added

- Skills used today now tracks last-used time per skill, not just a count
  — the list sorts most-recently-used first instead of by count, so it
  answers "what did I just use" as well as "which skills, how often."
  `--dump` prints the same ordering.

### Changed

- Limit style (bar/ring/percent) moved to the menu bar — it was originally
  wired to the popover's rows in 0.7.0, but that was the wrong surface; the
  popover always shows the full bar meter now, same as before 0.7.0. The
  menu bar's compact title draws a small inline bar or ring graphic instead
  of (or alongside) the percentage, per the Settings › General picker.

### Added

- Budget alert (Settings › Cost) — set a $/day or $/30-days cap; the menu
  bar shows a warning segment and the popover's Analytics pane shows a
  banner once spend crosses 80% of it.
- Native notifications when a limit window drops below the warn threshold
  or the budget alert goes over (Settings › General toggle) — fires once
  per crossing, not repeatedly.
- "Copy Usage Report" button in the popover footer — copies a plain-text
  summary of today's stats to the clipboard.
- Calendar heatmap in the Analytics pane (Settings-free, always on) — a
  GitHub-contributions-style grid over the last 30 days, reusing the same
  trend data already fetched for the trend chart.

### Fixed

- Hourly chart's per-provider legend and both charts' axis labels were
  rendering garbled/missing. Cause: a detached `NSTextField` had `.frame`
  set but was never added as a subview, so nothing established a
  coordinate offset for it — calling `.draw(text.bounds)` on it directly
  ignored `frame.origin` entirely and drew every label piled up at the
  parent view's origin instead of its intended position. Replaced with
  direct `NSString.draw(in:withAttributes:)`, which honors the given rect
  correctly (same technique the "No usage recorded" placeholder already
  used, just not consistently).

## [0.7.0] - 2026-07-25

### Added

- Customizable limit display style — Settings › General now has a Bar /
  Ring / Percent-only picker for how each limit window is drawn. Ring is a
  new circular arc meter; Percent-only drops the meter graphic entirely for
  a denser, text-only row.
- Analytics pane split into "Today" and "Trend" sections:
  - Today's hourly chart now draws three separate colored lines
    (Claude/Codex/Antigravity) with a legend instead of one blended line —
    tokens and prompt-counts aren't the same unit, so summing them into one
    number was never that meaningful.
  - New 7-day / 30-day trend chart (stacked daily cost bars per provider,
    with a segmented range switcher) — Analytics previously only knew
    about today.
  - Busiest weekday note in the 30-day view.

## [0.6.1] - 2026-07-25

### Added

- Per-provider "show in menu bar" toggle in Settings › Providers (the eye
  icon on each row) — independent of drag order, and independent of the
  popover, so a provider can stay reachable via the popover's sidebar while
  being hidden from the compact status-bar title.
- Changelog tab in Settings, reading this file bundled into the app.

### Fixed

- Popover was sizing itself to the full (unclipped) height of its ScrollView
  content instead of the intended fixed 480pt — NSHostingController's
  automatic content-size tracking doesn't play well with a ScrollView inside
  a fixed frame. Popover size is now pinned explicitly.
- Footer buttons (Refresh Now, Check for Updates, Settings, Quit) were
  `.borderless` — flat text with no visible button chrome. Now `.bordered`.
- `make-app.sh` had a hardcoded local-build version fallback (`0.4.0`) that
  never got updated across several later releases, so any ad-hoc local
  build reported a stale version regardless of what was actually built.
  It now defaults to the latest git tag instead.

## [0.6.0] - 2026-07-24

### Changed

- Dropdown redesigned from a single scrolling NSMenu into a popover with a
  side tab bar — Claude Code / Codex / Antigravity / Analytics, one click
  switches panes instead of scrolling past everything. A persistent footer
  (refresh countdown, Refresh Now, Check for Updates, Settings, Quit) stays
  visible regardless of which tab is selected. Refresh Now no longer closes
  the window — data updates live in place.
- All existing rows (limits, today's tokens, cache hit rate, per-model
  breakdown, skills used, avg/session, 7-day/30-day cost, hourly chart)
  carried over 1:1 into the new panes, still gated by the same Settings
  toggles.

## [0.5.2] - 2026-07-24

### Added

- "Skills used today" — tallies Claude Code `Skill` tool invocations
  (e.g. `/commit`, `/graphify`) from today's transcripts, shown in the
  Claude Code dropdown section and toggleable in Settings › General.
  Reuses the existing token-usage dedup logic so re-streamed log entries
  don't double-count.

## [0.5.1] - 2026-07-24

### Added

- Custom app icon (`Resources/AppIcon.icns`) — purple gradient squircle with
  a usage-meter capsule and a sparkle accent. Previously the app had no icon
  at all and fell back to the generic system placeholder.

## [0.5.0] - 2026-07-24

### Added

- Add a daily Analytics section with an hourly line chart and peak activity
  hour.
- Show Antigravity quota remaining for the 5-hour and weekly windows when
  quota data is available.
- Animate the Antigravity logo in the menu bar while an AI task is running.
- Fall back to Antigravity prompt counts when quota data is unavailable.
- Reorderable provider order: drag Claude/Codex/Antigravity into any order in
  Settings › Providers — the same order now drives both the status-bar
  segments and the dropdown sections.
- More dropdown data: per-model cost/token breakdown (Claude), cache hit
  rate, average cost/tokens per session, and 7-day/30-day cumulative cost per
  provider.
- Live USD→THB exchange rate, auto-fetched periodically from
  api.frankfurter.app (Settings › Cost), with a manual override and a
  Refresh Now button.
- Settings window redesigned as four top tabs (General / Providers / Cost /
  Log) instead of one long scrolling form; the log viewer now has its own
  page.

### Fixed

- Antigravity 5-hour/weekly rows no longer silently disappear right around a
  window's rollover — they now show a "window reset" note like Claude/Codex
  instead of vanishing even though today's usage exists.
- Claude limit rows no longer show a blank gap before the first fetch
  resolves; a "Fetching limits…" note shows instead.
- The 5-hour/Weekly toggle in Settings now actually hides/shows the
  corresponding row in the dropdown, not just the menu-bar title.

## [0.4.0] - 2026-07-15

### Added

- Antigravity local prompt usage tracking and cost analytics:
  - Detects Antigravity CLI history files under `~/.gemini/antigravity-cli`.
  - Tracks today's prompts and session counts.
  - Computes estimated cost using Gemini 3.5 Flash list prices (assuming 1.5K input / 800 output tokens per prompt).
  - Displays Gemini brand icon/color in the status bar and dropdown.

## [0.3.1] - 2026-07-15

### Fixed

- Point the Sparkle update feed and repository links at the renamed repo
  (`AI_Usage` → `ai-usage-bar`); the old appcast URL now 404s, so builds
  carrying it cannot auto-update. **v0.3.0 shipped with the dead feed URL —
  install this version instead.**
- Recheck an expired login every minute (instead of every 5) so the display
  recovers almost as soon as the Claude CLI writes a fresh token.

## [0.3.0] - 2026-07-15

### Added

- Show estimated cost of today's tokens per provider, priced at API list
  prices per model and shown in both THB and USD (exchange rate configurable
  in Settings).
- Diagnostics log (API calls, keychain reads, errors) with a viewer in
  Settings; stored at `~/Library/Logs/AIUsageBar/`.
- Live countdown ring in the dropdown showing seconds until the next refresh.
- Show the app version in the dropdown menu.
- Settings toggles for which Claude windows (5-hour / weekly) drive the
  menu-bar percentage.
- Surface usage-API failures in the dropdown with the cause (HTTP status /
  error) and the age of the cached data still on display.
- Persist the last good Claude limits across relaunches, so the dropdown shows
  cached data (with its age) instead of nothing while the first fetch runs or
  is rate limited.

### Changed

- Wider dropdown (300 → 380) with token stats paired two per row, roughly
  halving the menu height.
- Wider Settings window with the menu-bar options grouped on one row.
- Honor the usage API's `Retry-After` on 429: nothing refetches before the
  server-given time — not the timer, not ⌘R, not a relaunch (the penalty
  window persists to disk) — and the dropdown shows a retry countdown.

### Fixed

- Parse fractional-second `resets_at` timestamps so Claude "resets in" no
  longer shows "—".
- Cache the Claude access token in memory: the keychain is read once per
  launch (and again only after a 401) instead of on every limits poll,
  cutting password prompts dramatically.
- Never start a second limits fetch while one is blocked on the keychain
  dialog — previously each 60s tick stacked another password prompt.
- Periodic refresh keeps firing while the dropdown is open (timer moved to
  `.common` run-loop mode).
- `make-app.sh` accepts `CODESIGN_IDENTITY` (and auto-detects a local
  "AIUsageBar Signing" certificate) so builds signed with a stable identity
  keep the keychain "Always Allow" grant across updates.

## [0.2.1] - 2026-07-15

### Fixed

- Fix the bundled Sparkle framework path so the released app launches normally.

## [0.2.0] - 2026-07-15

### Added

- Add Sparkle automatic updates using signed releases and a GitHub Pages appcast.
- Add **Check for Updates…** to the menu-bar menu.

### Known issue

- This release cannot launch because the bundled Sparkle framework path is
  missing. Install v0.2.1 instead.

## [0.1.0] - 2026-07-14

### Added

- First preview release of AI Usage Bar.
- Show Claude Code and Codex token usage and rate-limit readings in the macOS
  menu bar.
