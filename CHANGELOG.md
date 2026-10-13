# Changelog

All notable changes to AI Usage Bar are documented in this file.

## [Unreleased]

## [0.14.0] - 2026-10-13

### Added

- **New display styles:** Added Blocks, Battery, and Pill meter styles with compact visual representations for the menu bar.
- **Touch Bar support:** Added hardware detection and optional live usage display in the macOS Control Strip for supported MacBook models.
- **Antigravity model groups:** Full live quota tracking for Gemini Models and Claude/GPT models via Desktop IDE Connect RPC and CLI status-line bridge.

### Fixed

- **Pill contrast and clipping:** Implemented two-tone inverted contrast clipping so percentage numbers remain clearly legible across filled and unfilled portions.
- **Antigravity popover layout:** Standardized Antigravity limit rows to use horizontal capsule bars matching Claude Code and Codex styles.

## [0.13.0] - 2026-09-06

### Added

- **Provider source paths:** See where each provider reads data and reveal the path in Finder.

### Fixed

- **Popover footer:** Actions now use two compact rows, leaving more room for usage details.
- **Claude reset rows:** Stale readings keep their reset countdown when Claude provides one.
- **Light-theme meters:** Bars and labels stay readable on translucent light menu bars.
- **Antigravity detection:** IDE conversations are detected even without CLI history.
- **Antigravity quota:** CLI status-line quota and reset data can be captured locally.

## [0.12.0] - 2026-09-05

### Added

- **Dual-window meters:** Show 5-hour and weekly usage together as stacked bars or concentric rings.
- **Display presets:** Choose Bar, Ring, Percent, or combined styles with a live preview.
- **Window visibility:** Show 5-hour, weekly, both, or neither; a single row expands to use the space.

### Changed

- **Usage labels:** Percentages default to used.
- **Meter colors:** Semantic macOS colors keep readings clear in light and dark appearances.

## [0.11.1] - 2026-08-09

### Fixed

- **Five-hour projection:** Token weighting now matches how the window is consumed, improving projection accuracy.
- **Large usage bursts:** The projection no longer hides real jumps behind a small movement cap.

## [0.11.0] - 2026-08-09

### Changed

- **Refresh performance:** Idle refreshes skip unchanged logs; active logs are read incrementally.
- **History calculations:** Today, hourly, cost, and trend views reuse parsed records instead of rescanning the same files.
- **Menu-bar redraws:** The title only redraws when its visible value changes.
- **Resource use:** Sustained CPU fell from 2.12% to 0.073% and memory from 45 MB to 29 MB in the measured workload.

### Fixed

- **Midnight refresh:** An app left open across midnight now reads the new day.
- **Claude limit watcher:** New status-line readings appear without waiting for a full refresh.
- **Duplicate token events:** Projection totals now use the same de-duplicated records as the display.

## [0.10.6] - 2026-08-08

### Added

- **Icon Composer source:** Added layered source artwork for a future macOS 26 icon asset.

### Fixed

- **Codex five-hour alerts:** The low-remaining check now includes the five-hour window when available.

## [0.10.5] - 2026-08-08

### Fixed

- **Release build:** CI now builds with the macOS 26 SDK required by Liquid Glass.

## [0.10.4] - 2026-08-08

### Added

- **Provider switching:** Overview suggests a provider with more remaining capacity.
- **Reading age:** Antigravity shows how old its cached quota is.
- **History retention:** Daily totals survive Claude Code and Codex log pruning.
- **Test coverage:** Added automated tests for parsing, history, projections, and byte scanning.
- **Liquid Glass:** Popover cards use the native material on macOS 26.

### Changed

- **Historical costs:** 7-day and 30-day totals reuse the trend scan.

### Fixed

- **Projection work:** Claude calibration scans logs once per interval.
- **Antigravity animation:** The working indicator runs only while a task is active.

## [0.10.3] - 2026-08-08

### Added

- **Depletion warnings:** The popover warns when the current pace reaches a limit before reset.

## [0.10.2] - 2026-08-08

### Changed

- **Projection calibration:** Five-hour estimates fit the last 16 readings and ignore reset or incomplete intervals.
- **Token history:** Projection inputs are gathered in one cached pass.

## [0.10.1] - 2026-08-08

### Fixed

- **Popover surface:** Sidebar, cards, and footer now share one translucent material.
- **Reduce Transparency:** The popover uses solid backgrounds when the system setting is enabled.

## [0.10.0] - 2026-08-08

### Notes

- **Upgrade:** Replace older installs manually because the bundle identifier changed; settings migrate automatically.
- **Claude Desktop limitation:** Desktop files provide percentages but no reset time; reset times require the Claude Code status-line bridge.

### Added

- **Claude Desktop readings:** Limits appear from the Desktop app's local usage file without setup.
- **Claude status-line bridge:** Install the CLI bridge from the popover with a settings backup.
- **Live Claude updates:** Both local limit files are watched for new readings.
- **Estimated five-hour usage:** Desktop readings can project forward from logged Claude Code tokens.

### Changed

- **Overview:** The popover opens on the tightest limit, then shows one compact card per provider.
- **Session lists:** Recent sessions are compact; full details remain available through Export.
- **General style:** One menu-bar style setting now applies to every provider.
- **Menu-bar title:** Removed the redundant “AI” prefix and wide separators.

### Fixed

- **Menu-bar visibility:** Changed the bundle identifier to recover status items hidden by macOS.
- **Startup time:** Byte-level log scanning reduced startup work on large histories.
- **Used/remaining labels:** Popover text now matches the selected display mode.
- **Session titles:** Rows prefer custom titles, then automatic titles, then the workspace name.
- **Refresh feedback:** Progress appears in the tooltip and footer without flashing placeholders.
- **Sidebar layout:** Selected and long labels no longer wrap or clip.
- **Duplicate launches:** A second copy exits instead of competing for the status item.
- **Claude settings:** An empty settings file remains valid after bridge setup.

## [0.9.0] - 2026-08-02

### Added

- **Provider settings:** Configure visibility, windows, details, order, and six menu-bar styles per provider.
- **Session costs:** See estimated cost for each session and its skills/tools.
- **Reports:** Copy or save usage as Markdown, JSON, or CSV.
- **Notifications:** Enable large-session alerts and optional privacy controls.
- **Summary cache:** Session summaries are cached by fingerprint.

## [0.8.0] - 2026-07-25

### Added

- **Skill activity:** Skills sort by most recent use as well as count.
- **Budget alerts:** Set a daily or 30-day spend cap with an 80% warning.
- **Usage reports:** Copy today's summary as plain text.
- **Calendar heatmap:** Review daily cost activity across the last 30 days.

### Changed

- **Update flow:** Updates ask before installing and include release notes.
- **Menu-bar styles:** Bar and ring graphics moved to the menu bar; the popover keeps full meters.

### Fixed

- **Analytics labels:** Chart legends and axis labels now render in the correct positions.

## [0.7.0] - 2026-07-25

### Added

- **Limit styles:** Choose Bar, Ring, or Percent-only display.
- **Analytics sections:** Added hourly provider lines, 7-day/30-day cost trends, and busiest weekday.

## [0.6.1] - 2026-07-25

### Added

- **Provider visibility:** Show or hide each provider in the menu bar independently from the popover.
- **Changelog tab:** Read this file inside Settings.

### Fixed

- **Popover size:** The window stays at its intended fixed height.
- **Footer buttons:** Actions now use visible macOS button chrome.
- **Build version:** Local builds default to the latest git tag.

## [0.6.0] - 2026-07-24

### Changed

- **Popover navigation:** Replaced the scrolling menu with side tabs and a persistent footer.
- **Existing details:** Limits, tokens, costs, sessions, skills, and charts remain available in the new panes.

## [0.5.2] - 2026-07-24

### Added

- **Skills used today:** Count Claude Code Skill calls and show the most-used skills in the provider pane.

## [0.5.1] - 2026-07-24

### Added

- **App icon:** Added a custom purple usage-meter icon.

## [0.5.0] - 2026-07-24

### Added

- **Analytics:** Added hourly activity, peak hour, and daily cost views.
- **Antigravity quota:** Show 5-hour and weekly quota when available.
- **Antigravity activity:** Animate its icon while a task runs and fall back to prompt counts without quota data.
- **Provider order:** Reorder providers once for both the menu bar and popover.
- **Usage details:** Added model, cache, session, and period-cost breakdowns.
- **Currency conversion:** Added live USD-to-THB rates with manual override.
- **Settings tabs:** Split General, Providers, Cost, and Log into separate tabs.

### Fixed

- **Window rollover:** Antigravity rows explain a reset instead of disappearing.
- **Claude loading:** Show a fetching state before the first limits read.
- **Window toggles:** Settings now controls which rows appear in the popover.

## [0.4.0] - 2026-07-15

### Added

- **Antigravity tracking:** Detect local prompts, sessions, estimated cost, and Gemini branding.

## [0.3.1] - 2026-07-15

### Fixed

- **Update feed:** Pointed releases and repository links at the renamed repository.
- **Login recovery:** Recheck expired Claude login state every minute.

## [0.3.0] - 2026-07-15

### Added

- **Cost estimates:** Show today's provider cost in USD and THB.
- **Diagnostics log:** Record app events and view them in Settings.
- **Refresh countdown:** Show seconds until the next refresh.
- **Version display:** Show the app version in the popover.
- **Window settings:** Choose which Claude windows drive the menu-bar percentage.
- **API errors:** Show failure causes and cached-data age.

### Changed

- **Popover width:** Pair token stats in rows to reduce height.
- **Settings layout:** Group menu-bar options on one row.
- **Retry handling:** Respect the server's Retry-After value before refetching.

### Fixed

- **Reset timestamps:** Parse fractional-second reset values.
- **Keychain reads:** Cache the Claude access token between requests.
- **Fetch coordination:** Prevent duplicate keychain prompts and overlapping fetches.
- **Refresh timer:** Continue updating while the popover is open.
- **Signing:** Support a stable local signing identity for updates.

## [0.2.1] - 2026-07-15

### Fixed

- **Sparkle framework:** Corrected the bundled path so the app launches.

## [0.2.0] - 2026-07-15

### Added

- **Automatic updates:** Added signed Sparkle updates and a manual update check.

### Notes

- **Known issue:** This release cannot launch; install 0.2.1 instead.

## [0.1.0] - 2026-07-14

### Added

- **First release:** Show Claude Code and Codex usage and rate limits in the macOS menu bar.
