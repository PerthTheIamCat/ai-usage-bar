import AppKit
import SwiftUI
import Sparkle

final class AppDelegate: NSObject, NSApplicationDelegate {
    // Sparkle owns the updater lifecycle and keeps its menu action enabled only
    // when the app is in a state that can check for updates.
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )
    private var statusItem: NSStatusItem!
    private var popover: NSPopover?
    private let refreshInterval: TimeInterval = 60
    private lazy var viewModel = UsageViewModel(refreshInterval: refreshInterval)
    private var timer: Timer?
    private var animationTimer: Timer?
    private var limitsWatchTimer: Timer?
    /// Modification dates of the Claude limit sources at the last check, so a
    /// rewrite by the bridge or the Desktop app is noticed within seconds.
    private var claudeSourceStamps: [String: Date] = [:]
    private var hasPrimedClaudeSources = false
    private var animationPhase: CGFloat = 0
    // Last successful Claude limits, reused while the local statusLine
    // snapshot is stale or unavailable. Persisted to UserDefaults so a
    // relaunch still has a useful last-known reading.
    private var lastGoodClaude: ClaudeLimits? {
        didSet { persistLastGoodClaude() }
    }
    // 7-/30-day cost aggregates are much heavier to compute than the
    // today-only reads (scans up to 30 days of logs), so they're recomputed
    // on their own slow cadence and cached like lastGoodClaude above.
    private var lastGoodPeriodCosts: PeriodCosts?
    private var lastGoodDailyTrend: DailyTrend?
    private var nextPeriodStatsAt = Date.distantPast
    private let periodStatsInterval: TimeInterval = 30 * 60
    // Last applied snapshot, re-rendered instantly when a setting changes.
    private var lastSnapshot: UsageSnapshot?
    // When the periodic refresh timer next fires, for the countdown ring.
    private var nextRefreshAt = Date()
    // Ignore progress/completion callbacks from an older refresh if the user
    // presses Refresh Now while a previous read is still running.
    private var activeRefreshID: UUID?
    // Historical cost/trend scans are deliberately kept out of the first
    // snapshot so today's data can appear quickly. Only one slow scan runs at
    // a time, and its progress is shown in the same loading indicator.
    private var periodStatsInFlight = false
    private var activePeriodStatsID: UUID?

    private static let appVersion: String = {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        guard let short else { return "dev" }
        return build.map { "\(short) (\($0))" } ?? short
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A stray second copy of the app (e.g. a dev build left in another
        // folder that Spotlight also indexes) launches under the same bundle
        // identifier and fights the first instance over the same status
        // item, which looks like the app hanging / refusing to open. Only
        // one instance should ever run.
        if let bundleID = Bundle.main.bundleIdentifier {
            let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
            if !others.isEmpty {
                appLog("app launched v\(Self.appVersion) — another instance is already running, quitting this one")
                NSApp.terminate(nil)
                return
            }
        }
        appLog("app launched v\(Self.appVersion)")
        restoreLastGoodClaude()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // Give the item a stable identity so macOS persists its menu bar
        // position across launches instead of re-placing it each time.
        statusItem.autosaveName = "AIUsageBarStatusItem"
        statusItem.isVisible = true
        statusItem.button?.title = "AI …"
        statusItem.button?.toolTip = "AI Usage Bar — starting…"
        statusItem.button?.setAccessibilityLabel("AI Usage Bar")
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusItemClicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        appLog("status item created — visible=\(statusItem.isVisible)")

        refresh()
        // .common mode so the periodic refresh keeps firing while the popover
        // is open (modal-ish tracking loops otherwise suspend default-mode timers).
        let t = Timer(timeInterval: refreshInterval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t

        // Claude's limit sources are written by other processes on their own
        // schedule — the status line bridge on every CLI turn, the Desktop app
        // every few minutes. Waiting for the next full refresh added up to a
        // minute of our own lag on top of that, so watch the two files and
        // pick a new reading up as soon as it lands. Re-reading limits is a
        // couple of small JSON files, nothing like the full log scan.
        let limitsWatch = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            self?.refreshClaudeLimitsIfSourceChanged()
        }
        RunLoop.main.add(limitsWatch, forMode: .common)
        limitsWatchTimer = limitsWatch

        let animation = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in
            guard let self, self.lastSnapshot?.antigravity?.isWorking == true else { return }
            self.animationPhase += 0.08
            self.updateStatusBarTitle(self.lastSnapshot!)
        }
        RunLoop.main.add(animation, forMode: .common)
        animationTimer = animation

        NotificationCenter.default.addObserver(
            forName: .usageSettingsChanged, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, let snap = self.lastSnapshot else { return }
            self.apply(snap)
        }
    }

    @objc private func statusItemClicked() {
        guard let button = statusItem.button else { return }
        if let popover, popover.isShown {
            popover.performClose(nil)
            return
        }
        let pop = popover ?? makePopover()
        popover = pop
        NSApp.activate(ignoringOtherApps: true)
        pop.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    private func makePopover() -> NSPopover {
        let content = PopoverContentView(
            viewModel: viewModel,
            appVersion: Self.appVersion,
            onRefresh: { [weak self] in self?.refreshClicked() },
            onCheckForUpdates: { [weak self] in self?.updaterController.checkForUpdates(nil) },
            onExportReport: { [weak self] in self?.copyUsageReport() },
            onExportJSON: { [weak self] in self?.copyUsageJSON() },
            onExportCSV: { [weak self] in self?.copyUsageCSV() },
            onSaveCSV: { [weak self] in self?.saveUsageCSV() },
            onSettings: { [weak self] in self?.settingsClicked() },
            onQuit: { [weak self] in self?.quitClicked() }
        )
        // NSHostingController's automatic content-size tracking miscalculates
        // when a ScrollView is inside: it reports the ScrollView's full
        // unclipped content height as the "ideal" size instead of respecting
        // PopoverContentView's own fixed .frame(height: 480), which made the
        // popover balloon to fit everything and render past its own bounds.
        // Disable that tracking and pin the size ourselves to match the
        // sidebar (130) + divider (~1) + content (380) layout exactly.
        let hosting = NSHostingController(rootView: content)
        hosting.sizingOptions = []
        let pop = NSPopover()
        pop.behavior = .transient
        pop.contentSize = NSSize(width: 511, height: 480)
        pop.contentViewController = hosting
        return pop
    }

    @objc private func refreshClicked() {
        refresh()
    }
    @objc private func settingsClicked() {
        popover?.performClose(nil)
        SettingsWindowController.shared.show()
    }
    @objc private func quitClicked() { NSApp.terminate(nil) }

    private func copyUsageReport() {
        let report = UsageReport.generate(viewModel.snapshot)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
        appLog("exported usage report to clipboard")
    }

    private func copyUsageJSON() {
        let json = UsageReport.generateJSON(viewModel.snapshot)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(json, forType: .string)
        appLog("exported JSON usage report to clipboard")
    }

    private func copyUsageCSV() {
        let csv = UsageReport.generateCSV(viewModel.snapshot)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(csv, forType: .string)
        appLog("exported CSV usage report to clipboard")
    }

    private func saveUsageCSV() {
        let panel = NSSavePanel()
        panel.title = "Export AI Usage CSV"
        panel.nameFieldStringValue = "ai-usage-\(Date().formatted(.dateTime.year().month().day())).csv"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try UsageReport.generateCSV(self?.viewModel.snapshot ?? UsageSnapshot())
                    .write(to: url, atomically: true, encoding: .utf8)
                appLog("exported CSV usage report to \(url.lastPathComponent)")
            } catch {
                appLog("CSV export failed — \(error.localizedDescription)")
            }
        }
    }

    /// Cheap Date compare on every tick; the Claude statusLine snapshot is
    /// local, while the exchange-rate fetch has its own slow cadence.
    private func maybeRefreshExchangeRate() {
        let s = AppSettings.shared
        guard s.thbAutoFetch else { return }
        let stale = s.thbLastFetched.map { Date().timeIntervalSince($0) > 6 * 3600 } ?? true
        guard stale else { return }
        ExchangeRateFetcher.fetchUSDtoTHB { rate in
            guard let rate else { return }
            AppSettings.shared.thbPerUSD = rate
            AppSettings.shared.thbLastFetched = Date()
        }
    }

    private func refresh() {
        guard !periodStatsInFlight, activeRefreshID == nil else { return }
        let refreshID = UUID()
        activeRefreshID = refreshID
        let isInitialLoad = lastSnapshot == nil
        let startedAt = Date()
        let shouldStartPeriodStats = Date() >= nextPeriodStatsAt
        if isInitialLoad {
            appLog("startup: reading local usage logs")
        }
        setLoadingStatus("Starting…")
        maybeRefreshExchangeRate()
        nextRefreshAt = Date().addingTimeInterval(refreshInterval)
        DispatchQueue.global(qos: .utility).async {
            let snap = UsageReader.snapshot(includePeriodStats: false) { message in
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.activeRefreshID == refreshID else { return }
                    self.setLoadingStatus(message)
                }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                guard self.activeRefreshID == refreshID else { return }
                var snap = snap
                snap.periodCosts = self.lastGoodPeriodCosts
                snap.dailyTrend = self.lastGoodDailyTrend
                self.apply(snap)
                self.activeRefreshID = nil
                let elapsed = String(format: "%.1fs", Date().timeIntervalSince(startedAt))
                if isInitialLoad || Date().timeIntervalSince(startedAt) > 2 {
                    appLog("\(isInitialLoad ? "startup" : "refresh"): usage snapshot ready in \(elapsed)")
                }
                self.viewModel.loadingMessage = nil
                if shouldStartPeriodStats {
                    self.startPeriodStatsRefresh(logAsStartup: isInitialLoad)
                }
            }
        }
    }

    private func startPeriodStatsRefresh(logAsStartup: Bool) {
        guard !periodStatsInFlight else { return }
        periodStatsInFlight = true
        let statsID = UUID()
        activePeriodStatsID = statsID
        nextPeriodStatsAt = Date().addingTimeInterval(periodStatsInterval)
        let startedAt = Date()
        setLoadingStatus("Calculating 7/30-day costs…")

        DispatchQueue.global(qos: .utility).async {
            let periodCosts = UsageReader.periodCosts()
            DispatchQueue.main.async { [weak self] in
                guard let self, self.activePeriodStatsID == statsID else { return }
                self.setLoadingStatus("Calculating 30-day trend…")
            }
            let trend = UsageReader.dailyTrend(days: 30)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.activePeriodStatsID == statsID else { return }
                self.lastGoodPeriodCosts = periodCosts
                self.lastGoodDailyTrend = trend
                var snap = self.viewModel.snapshot
                snap.periodCosts = periodCosts
                snap.dailyTrend = trend
                self.apply(snap)
                self.periodStatsInFlight = false
                self.activePeriodStatsID = nil
                self.nextRefreshAt = Date().addingTimeInterval(self.refreshInterval)
                self.viewModel.nextRefreshAt = self.nextRefreshAt
                self.viewModel.loadingMessage = nil
                let elapsed = String(format: "%.1fs", Date().timeIntervalSince(startedAt))
                appLog("\(logAsStartup ? "startup" : "refresh"): historical stats ready in \(elapsed)")
            }
        }
    }

    // MARK: - Limits persistence

    private struct StoredLimits: Codable {
        var fiveHourUsed: Double?
        var fiveHourReset: Date?
        var sevenDayUsed: Double?
        var sevenDayReset: Date?
        var fetchedAt: Date
    }

    // Keep the local-statusline cache separate from values written by older
    // builds that fetched Claude's HTTP usage endpoint.
    private static let storedLimitsKey = "lastGoodClaudeLimits.localStatusLine"

    private func persistLastGoodClaude() {
        guard let l = lastGoodClaude, let at = l.fetchedAt else { return }
        let stored = StoredLimits(
            fiveHourUsed: l.fiveHour?.usedPercent, fiveHourReset: l.fiveHour?.resetsAt,
            sevenDayUsed: l.sevenDay?.usedPercent, sevenDayReset: l.sevenDay?.resetsAt,
            fetchedAt: at)
        if let data = try? JSONEncoder().encode(stored) {
            UserDefaults.standard.set(data, forKey: Self.storedLimitsKey)
        }
    }

    private func restoreLastGoodClaude() {
        guard let data = UserDefaults.standard.data(forKey: Self.storedLimitsKey),
              let stored = try? JSONDecoder().decode(StoredLimits.self, from: data),
              // Older than the weekly window is stale beyond usefulness.
              stored.fetchedAt > Date().addingTimeInterval(-8 * 24 * 3600)
        else { return }
        var limits = ClaudeLimits()
        limits.state = .ok
        limits.fetchedAt = stored.fetchedAt
        if let used = stored.fiveHourUsed {
            limits.fiveHour = LimitWindow(usedPercent: used, resetsAt: stored.fiveHourReset)
        }
        if let used = stored.sevenDayUsed {
            limits.sevenDay = LimitWindow(usedPercent: used, resetsAt: stored.sevenDayReset)
        }
        lastGoodClaude = limits
        appLog("claude: restored cached limits from \(humanAgo(stored.fetchedAt))")
    }

    /// Cache good readings; reuse the last good one when this tick skipped the
    /// local read or failed, so the display holds steady. A stale/unavailable
    /// source is still surfaced as a status note. Feeds the popover's view
    /// model — the popover itself just re-renders reactively.
    /// Cheap poll of the two Claude limit files. `stat` on two paths every few
    /// seconds costs nothing next to the log scan a full refresh runs, and it
    /// avoids the atomic-replace races a file-descriptor watch would hit.
    private func refreshClaudeLimitsIfSourceChanged() {
        guard var snap = lastSnapshot, snap.claudeLimits != nil else { return }
        let sources = [ClaudeLimitsReader.statusLineSnapshotURL, ClaudeLimitsReader.desktopPlanUsageURL]
        var changed = false
        for url in sources {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if claudeSourceStamps[url.path] != modified {
                claudeSourceStamps[url.path] = modified
                changed = true
            }
        }
        // The first pass only records the current stamps — the refresh that
        // produced `lastSnapshot` already read them, so there is nothing new
        // until one of them actually moves.
        guard hasPrimedClaudeSources else {
            hasPrimedClaudeSources = true
            return
        }
        guard changed else { return }
        snap.claudeLimits = ClaudeLimitsReader.fetch()
        apply(snap)
    }

    private func apply(_ snap: UsageSnapshot) {
        lastSnapshot = snap
        var snap = snap
        var claudeLimitsProblem: String?
        if let cl = snap.claudeLimits {
            switch cl.state {
            case .ok:
                lastGoodClaude = cl
            case .stale:
                claudeLimitsProblem = "Claude statusline data is stale — use Claude Code to update it"
                if let cached = lastGoodClaude { snap.claudeLimits = cached }
            case .unavailable:
                claudeLimitsProblem = "Claude statusline bridge is not configured yet"
                if let cached = lastGoodClaude { snap.claudeLimits = cached }
            case .error(let m):
                claudeLimitsProblem = "Claude local limits failed: \(m)"
                if let cached = lastGoodClaude { snap.claudeLimits = cached }
            }
        } else if snap.claude != nil {
            snap.claudeLimits = lastGoodClaude
        }

        // Menu-bar title prefers the tightest (lowest-remaining) live limit;
        // falls back to today's token total when limits are unavailable.
        // Rendered attributed: real brand glyphs, monospaced digits so the
        // title width stays steady, and a segment turns red when a limit runs
        // low.
        updateStatusBarTitle(snap)

        viewModel.snapshot = snap
        viewModel.claudeLimitsProblem = claudeLimitsProblem
        viewModel.lastGoodClaudeFetchedAt = lastGoodClaude?.fetchedAt
        viewModel.nextRefreshAt = nextRefreshAt

        UsageNotifier.shared.check(snap)
    }

    // MARK: - Status bar title

    private func setLoadingStatus(_ message: String) {
        viewModel.loadingMessage = message
        guard let button = statusItem.button else { return }
        button.toolTip = "AI Usage Bar — \(message)"
        // Only take over the title before there is anything to show. Every
        // refresh re-reads the logs, so swapping the live percentages out for
        // a placeholder each minute just makes the menu bar flicker — keep
        // the last good reading up and report progress in the tooltip and
        // the popover footer instead.
        guard lastSnapshot == nil else { return }
        let font = NSFont.menuBarFont(ofSize: 0)
        button.attributedTitle = NSAttributedString(
            string: "AI…",
            attributes: [.font: font, .foregroundColor: NSColor.labelColor])
    }

    /// `remainingPercent` is nil when the segment has no meaningful percent
    /// to draw a meter from (e.g. unavailable/error states, or a
    /// token/prompt-count fallback) — those always render as text regardless
    /// of Limit style.
    private func statusBarPart(for kind: ProviderKind, _ snap: UsageSnapshot) -> (icon: NSImage, text: String, remainingPercent: Double?, warning: Bool, style: LimitStyle?)? {
        guard AppSettings.shared.isShownInMenuBar(kind) else { return nil }
        let warnBelow = AppSettings.shared.warnBelowRemaining
        switch kind {
        case .claude:
            guard snap.claude != nil else { return nil }
            let low = lowestClaudeRemaining(snap)
            return (BrandIcons.claude, claudeTitleValue(snap), low, (low ?? 100) < warnBelow, AppSettings.shared.limitStyle(for: .claude))
        case .codex:
            guard let x = snap.codex else { return nil }
            if let v = codexTitleValue(snap) { return (BrandIcons.codex, v.text, v.remaining, v.remaining < warnBelow, AppSettings.shared.limitStyle(for: .codex)) }
            return (BrandIcons.codex, formatTokens(x.totalTokens), nil, false, AppSettings.shared.limitStyle(for: .codex))
        case .antigravity:
            guard let g = snap.antigravity else { return nil }
            let settings = AppSettings.shared
            let windows = [
                settings.isLimitWindowShown(.fiveHour, for: .antigravity) ? g.fiveHour : nil,
                settings.isLimitWindowShown(.weekly, for: .antigravity) ? g.weekly : nil,
            ].compactMap { $0 }
            let icon = g.isWorking ? BrandIcons.rotated(BrandIcons.gemini, angle: animationPhase) : BrandIcons.gemini
            if let remaining = windows.map(\.remainingPercent).min() {
                return (icon, settings.displayMode.shortText(remaining: remaining), remaining, remaining < warnBelow, settings.limitStyle(for: .antigravity))
            }
            return (icon, "\(g.totalPrompts)P", nil, false, settings.limitStyle(for: .antigravity))
        }
    }

    /// Combined estimated spend for the user's chosen budget period, nil
    /// when the alert is off or there's not enough data yet (a "per 30 days"
    /// budget needs the slow-cadence period-cost aggregate to have run once).
    private func currentSpendUSD(_ snap: UsageSnapshot) -> Double? {
        let s = AppSettings.shared
        guard s.budgetEnabled, s.budgetAmountUSD > 0 else { return nil }
        switch s.budgetPeriod {
        case .day:
            return (snap.claude.map(Pricing.claudeCostUSD) ?? 0)
                + (snap.codex.map(Pricing.codexCostUSD) ?? 0)
                + (snap.antigravity.map(Pricing.antigravityCostUSD) ?? 0)
        case .month:
            guard let pc = snap.periodCosts else { return nil }
            return (pc.claudeUSD30 ?? 0) + (pc.codexUSD30 ?? 0) + (pc.antigravityUSD30 ?? 0)
        }
    }

    /// Only appears once spend reaches 80% of budget — routine, well-under-
    /// budget usage stays silent rather than adding a permanent segment.
    private func budgetPart(_ snap: UsageSnapshot) -> (icon: NSImage, text: String, remainingPercent: Double?, warning: Bool, style: LimitStyle?)? {
        guard let spend = currentSpendUSD(snap) else { return nil }
        let budget = AppSettings.shared.budgetAmountUSD
        let fraction = spend / budget
        guard fraction >= 0.8 else { return nil }
        let icon = NSImage(systemSymbolName: "dollarsign.circle.fill", accessibilityDescription: "Budget")
            ?? NSImage(size: NSSize(width: 1, height: 1))
        icon.isTemplate = true
        return (icon, formatUSD(spend), nil, fraction >= 1.0, nil)
    }

    private func updateStatusBarTitle(_ snap: UsageSnapshot) {
        var parts = AppSettings.shared.providerOrder.compactMap { statusBarPart(for: $0, snap) }
        if let budget = budgetPart(snap) { parts.append(budget) }
        guard let button = statusItem.button else { return }
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.menuBarFont(ofSize: 0).pointSize, weight: .regular)
        // Menu bar space is scarce — on a notched Mac with a busy bar, macOS
        // silently parks an item off-screen rather than shrinking it, and the
        // app looks like it never launched. Keep this title as narrow as the
        // content allows: no redundant "AI" word (the icons identify the
        // providers, and the tooltip/accessibility label carry the app name)
        // and a single-space gap between segments.
        let title = NSMutableAttributedString()
        for part in parts {
            if title.length > 0 {
                title.append(NSAttributedString(string: " ", attributes: [.font: font]))
            }
            let color: NSColor = part.warning ? .systemRed : .labelColor
            title.append(BrandIcons.attachment(part.icon, font: font, color: color))
            title.append(NSAttributedString(string: " ", attributes: [.font: font]))
            if let remaining = part.remainingPercent, let style = part.style, style.showsMeter {
                title.append(MiniMeter.attachment(remainingPercent: remaining, style: style, font: font, color: color))
                if style.showsPercent {
                    title.append(NSAttributedString(string: " " + part.text, attributes: [.font: font, .foregroundColor: color]))
                }
            } else {
                title.append(NSAttributedString(string: part.text, attributes: [.font: font, .foregroundColor: color]))
            }
        }
        if parts.isEmpty {
            title.append(NSAttributedString(string: "AI —", attributes: [.font: font, .foregroundColor: NSColor.labelColor]))
        }
        button.attributedTitle = title
        button.toolTip = "AI Usage Bar — Click to view usage"
    }

    private func claudeTitleValue(_ snap: UsageSnapshot) -> String {
        guard let l = snap.claudeLimits else { return "—" }
        switch l.state {
        case .ok:
            if let low = lowestClaudeRemaining(snap) {
                return AppSettings.shared.displayMode.shortText(remaining: low)
            }
            // Both windows hidden from the menu bar — fall back to tokens.
            if let c = snap.claude { return formatTokens(c.total) }
            return "—"
        case .stale: return "stale"
        case .unavailable: return "—"
        case .error: return "!"
        }
    }

    /// Lowest remaining % across the Claude windows the user chose to show in
    /// the menu bar; nil when limits are absent or both windows are hidden.
    private func lowestClaudeRemaining(_ snap: UsageSnapshot) -> Double? {
        guard let l = snap.claudeLimits, case .ok = l.state else { return nil }
        let s = AppSettings.shared
        var values: [Double] = []
        if s.isLimitWindowShown(.fiveHour, for: .claude), let w = l.fiveHour { values.append(w.remainingPercent) }
        if s.isLimitWindowShown(.weekly, for: .claude), let w = l.sevenDay { values.append(w.remainingPercent) }
        return values.min()
    }

    /// Codex has no live API here — the reading is whatever the last Codex
    /// session logged. Weekly window only; Codex retired its 5-hour window.
    /// Returns nil when even that is missing.
    private func codexTitleValue(_ snap: UsageSnapshot) -> (text: String, remaining: Double)? {
        guard let l = snap.codexLimits else { return nil }
        let settings = AppSettings.shared
        if settings.isLimitWindowShown(.weekly, for: .codex), let s = l.secondary, !isExpired(s) {
            return (settings.displayMode.shortText(remaining: s.remainingPercent), s.remainingPercent)
        }
        if settings.isLimitWindowShown(.fiveHour, for: .codex), let s = l.primary, !isExpired(s) {
            return (settings.displayMode.shortText(remaining: s.remainingPercent), s.remainingPercent)
        }
        return nil
    }

    private func isExpired(_ w: LimitWindow) -> Bool {
        if let r = w.resetsAt { return r <= Date() }
        return false
    }
}

if CommandLine.arguments.contains("--claude-statusline") {
    let input = FileHandle.standardInput.readDataToEndOfFile()
    print(ClaudeLimitsReader.captureStatusLineInput(input))
    exit(0)
}

func dumpSessionActivities(_ provider: String, _ sessions: [SessionActivity]) {
    guard !sessions.isEmpty else { return }
    print("\(provider) sessions today:")
    for session in sessions {
        let skills = formatSessionActivityCounts(session.skills)
        let skillText = skills.isEmpty
            ? "—"
            : skills + (session.inferredSkills.isEmpty ? "" : " (inferred)")
        let tools = formatSessionActivityCounts(session.tools).isEmpty
            ? "—"
            : formatSessionActivityCounts(session.tools)
        let time = session.lastActivityAt?.formatted(date: .omitted, time: .shortened) ?? "—"
        let name = session.name ?? session.workspace ?? "—"
        print("  \(session.id.prefix(12)) · \(name) · \(time) · \(formatTokens(session.tokenTotal)) tokens · skills=\(skillText) · tools=\(tools)")
    }
}

if CommandLine.arguments.contains("--dump") {
    let snap = UsageReader.snapshot()
    if let c = snap.claude {
        print("Claude: total=\(formatTokens(c.total)) in=\(c.inputTokens) out=\(c.outputTokens) cacheW=\(c.cacheCreationTokens) cacheR=\(c.cacheReadTokens) sessions=\(c.sessionCount) model=\(c.lastModel ?? "-")")
        if !c.skillCounts.isEmpty {
            let skills = c.skillCounts
                .map { (skill: $0.key, count: $0.value, lastUsed: c.skillLastUsed[$0.key]) }
                .sorted { ($0.lastUsed ?? .distantPast) > ($1.lastUsed ?? .distantPast) }
                .map { "\($0.skill)×\($0.count) (\($0.lastUsed.map(humanAgo) ?? "?"))" }
                .joined(separator: ", ")
            print("Claude skills today (most recent first): \(skills)")
        }
        dumpSessionActivities("Claude", c.sessions)
    } else {
        print("Claude: not detected")
    }
    if let l = snap.claudeLimits {
        func w(_ n: String, _ x: LimitWindow?) -> String {
            guard let x = x else { return "\(n)=n/a" }
            return "\(n)=\(Int(x.remainingPercent))% left (resets \(humanReset(x.resetsAt)))"
        }
        switch l.state {
        case .ok: print("Claude limits: \(w("5h", l.fiveHour))  \(w("weekly", l.sevenDay))")
        case .stale: print("Claude limits: stale — use Claude Code to update the statusline")
        case .unavailable: print("Claude limits: unavailable — configure the Claude Code statusline bridge")
        case .error(let m): print("Claude limits: error \(m)")
        }
    }
    if let x = snap.codex {
        print("Codex: total=\(formatTokens(x.totalTokens)) in=\(x.inputTokens) cached=\(x.cachedInputTokens) out=\(x.outputTokens) reasoning=\(x.reasoningTokens) sessions=\(x.sessionCount)")
        dumpSessionActivities("Codex", x.sessions)
    } else {
        print("Codex: not detected")
    }
    if let l = snap.codexLimits {
        func w(_ n: String, _ x: LimitWindow?) -> String {
            guard let x = x else { return "\(n)=n/a" }
            if let r = x.resetsAt, r <= Date() { return "\(n)=window reset (stale)" }
            return "\(n)=\(Int(x.remainingPercent))% left (resets \(humanReset(x.resetsAt)))"
        }
        print("Codex limits (as of \(humanAgo(l.asOf))): \(w("weekly", l.secondary))")
    }
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
