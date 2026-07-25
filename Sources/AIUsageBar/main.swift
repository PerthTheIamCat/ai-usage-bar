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
    private var animationPhase: CGFloat = 0
    // Last successful Claude limits, reused between limit polls and when a
    // poll is rate-limited (429) so the display holds steady. Persisted to
    // UserDefaults so a relaunch still has data while the first fetch runs
    // (or is rate limited).
    private var lastGoodClaude: ClaudeLimits? {
        didSet { persistLastGoodClaude() }
    }
    // The usage API rate-limits aggressively, so poll it far less often than
    // the (free, local) token counts, and back off further on 429.
    private var nextClaudeFetch = Date.distantPast
    private let claudePollOK: TimeInterval = 300
    private let claudePollBackoff: TimeInterval = 600
    private var manualRefresh = false
    // 7-/30-day cost aggregates are much heavier to compute than the
    // today-only reads (scans up to 30 days of logs), so they're recomputed
    // on their own slow cadence and cached like lastGoodClaude above.
    private var lastGoodPeriodCosts: PeriodCosts?
    private var lastGoodDailyTrend: DailyTrend?
    private var nextPeriodStatsAt = Date.distantPast
    private let periodStatsInterval: TimeInterval = 30 * 60
    // A limits fetch can block for a long time on the keychain-permission
    // dialog; never start a second one while the first is still out, or every
    // 60s tick stacks another password prompt behind the dialog.
    private var limitsFetchInFlight = false
    // Server-imposed 429 window. Nothing may fetch before it — not even ⌘R —
    // and it persists across relaunches so a restart doesn't burn another hit.
    private static let rateLimitedUntilKey = "claudeRateLimitedUntil"
    private var rateLimitedUntil: Date? {
        get {
            let t = UserDefaults.standard.double(forKey: Self.rateLimitedUntilKey)
            return t > 0 ? Date(timeIntervalSince1970: t) : nil
        }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue.timeIntervalSince1970, forKey: Self.rateLimitedUntilKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.rateLimitedUntilKey)
            }
        }
    }
    // Last applied snapshot, re-rendered instantly when a setting changes.
    private var lastSnapshot: UsageSnapshot?
    // When the periodic refresh timer next fires, for the countdown ring.
    private var nextRefreshAt = Date()

    private static let appVersion: String = {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        guard let short else { return "dev" }
        return build.map { "\(short) (\($0))" } ?? short
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        appLog("app launched v\(Self.appVersion)")
        restoreLastGoodClaude()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "AI …"
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusItemClicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        refresh()
        // .common mode so the periodic refresh keeps firing while the popover
        // is open (modal-ish tracking loops otherwise suspend default-mode timers).
        let t = Timer(timeInterval: refreshInterval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t

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
        manualRefresh = true   // force a limits fetch on explicit Refresh Now
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

    /// Cheap Date compare on every tick; the actual network call only fires
    /// once every ~6h (or never, if the user turned auto-fetch off).
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
        maybeRefreshExchangeRate()
        nextRefreshAt = Date().addingTimeInterval(refreshInterval)
        let inPenaltyBox = Date() < (rateLimitedUntil ?? .distantPast)
        let doLimits = (manualRefresh || Date() >= nextClaudeFetch)
            && !limitsFetchInFlight && !inPenaltyBox
        manualRefresh = false
        if doLimits { limitsFetchInFlight = true }
        let doPeriodStats = Date() >= nextPeriodStatsAt
        DispatchQueue.global(qos: .utility).async {
            let snap = UsageReader.snapshot(fetchClaudeLimits: doLimits, includePeriodStats: doPeriodStats)
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                var snap = snap
                if doLimits {
                    self.limitsFetchInFlight = false
                    self.scheduleNextClaudeFetch(snap.claudeLimits)
                }
                if doPeriodStats {
                    self.lastGoodPeriodCosts = snap.periodCosts
                    self.lastGoodDailyTrend = snap.dailyTrend
                    self.nextPeriodStatsAt = Date().addingTimeInterval(self.periodStatsInterval)
                } else {
                    snap.periodCosts = self.lastGoodPeriodCosts
                    snap.dailyTrend = self.lastGoodDailyTrend
                }
                self.apply(snap)
            }
        }
    }

    private func scheduleNextClaudeFetch(_ limits: ClaudeLimits?) {
        let delay: TimeInterval
        if case .rateLimited(let retryAfter)? = limits?.state {
            // Honor the server's Retry-After (plus a buffer) — polling sooner
            // just burns more 429s.
            delay = max(claudePollBackoff, (retryAfter ?? 0) + 15)
            rateLimitedUntil = Date().addingTimeInterval(delay)
            appLog("claude: backing off — next limits fetch in \(Int(delay))s")
        } else if case .stale? = limits?.state {
            // Token expired: the CLI will write a fresh one to the keychain on
            // its next refresh cycle. Recheck every poll tick so the display
            // recovers within a minute instead of five. We never refresh the
            // token ourselves — refresh tokens are single-use, and racing the
            // CLI for one would log the user out of Claude Code.
            delay = refreshInterval
            rateLimitedUntil = nil
        } else {
            delay = claudePollOK
            rateLimitedUntil = nil
        }
        nextClaudeFetch = Date().addingTimeInterval(delay)
    }

    // MARK: - Limits persistence

    private struct StoredLimits: Codable {
        var fiveHourUsed: Double?
        var fiveHourReset: Date?
        var sevenDayUsed: Double?
        var sevenDayReset: Date?
        var fetchedAt: Date
    }

    private static let storedLimitsKey = "lastGoodClaudeLimits"

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
    /// fetch (nil) or failed, so the display holds steady. A failure is still
    /// surfaced as a status note so the user knows what happened. Feeds the
    /// popover's view model — the popover itself just re-renders reactively.
    private func apply(_ snap: UsageSnapshot) {
        lastSnapshot = snap
        var snap = snap
        var claudeAPIProblem: String?
        if let cl = snap.claudeLimits {
            switch cl.state {
            case .ok:
                lastGoodClaude = cl
            case .rateLimited(let retryAfter):
                claudeAPIProblem = "Usage API rate limited (HTTP 429)"
                if let retryAfter {
                    claudeAPIProblem! += " · retry in \(humanDuration(retryAfter))"
                }
                if let cached = lastGoodClaude { snap.claudeLimits = cached }
            case .error(let m):
                claudeAPIProblem = "Usage API failed: \(m)"
                if let cached = lastGoodClaude { snap.claudeLimits = cached }
            case .stale, .notLoggedIn:
                break
            }
        } else if snap.claude != nil {
            snap.claudeLimits = lastGoodClaude
            if let until = rateLimitedUntil, until > Date() {
                claudeAPIProblem = "Usage API rate limited (HTTP 429) · retry in \(humanDuration(until.timeIntervalSinceNow))"
            }
        }

        // Menu-bar title prefers the tightest (lowest-remaining) live limit;
        // falls back to today's token total when limits are unavailable.
        // Rendered attributed: real brand glyphs, monospaced digits so the
        // title width stays steady, and a segment turns red when a limit runs
        // low.
        updateStatusBarTitle(snap)

        viewModel.snapshot = snap
        viewModel.claudeAPIProblem = claudeAPIProblem
        viewModel.lastGoodClaudeFetchedAt = lastGoodClaude?.fetchedAt
        viewModel.nextRefreshAt = nextRefreshAt

        UsageNotifier.shared.check(snap)
    }

    // MARK: - Status bar title

    /// `remainingPercent` is nil when the segment has no meaningful percent
    /// to draw a meter from (e.g. Claude's "login"/"…"/"!" states, or a
    /// token/prompt-count fallback) — those always render as text regardless
    /// of Limit style.
    private func statusBarPart(for kind: ProviderKind, _ snap: UsageSnapshot) -> (icon: NSImage, text: String, remainingPercent: Double?, warning: Bool)? {
        guard AppSettings.shared.isShownInMenuBar(kind) else { return nil }
        let warnBelow = AppSettings.shared.warnBelowRemaining
        switch kind {
        case .claude:
            guard snap.claude != nil else { return nil }
            let low = lowestClaudeRemaining(snap)
            return (BrandIcons.claude, claudeTitleValue(snap), low, (low ?? 100) < warnBelow)
        case .codex:
            guard let x = snap.codex else { return nil }
            if let v = codexTitleValue(snap) { return (BrandIcons.codex, v.text, v.remaining, v.remaining < warnBelow) }
            return (BrandIcons.codex, formatTokens(x.totalTokens), nil, false)
        case .antigravity:
            guard let g = snap.antigravity else { return nil }
            let windows = [g.fiveHour, g.weekly].compactMap { $0 }
            let icon = g.isWorking ? BrandIcons.rotated(BrandIcons.gemini, angle: animationPhase) : BrandIcons.gemini
            if let remaining = windows.map(\.remainingPercent).min() {
                return (icon, AppSettings.shared.displayMode.shortText(remaining: remaining), remaining, remaining < warnBelow)
            }
            return (icon, "\(g.totalPrompts)P", nil, false)
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
    private func budgetPart(_ snap: UsageSnapshot) -> (icon: NSImage, text: String, remainingPercent: Double?, warning: Bool)? {
        guard let spend = currentSpendUSD(snap) else { return nil }
        let budget = AppSettings.shared.budgetAmountUSD
        let fraction = spend / budget
        guard fraction >= 0.8 else { return nil }
        let icon = NSImage(systemSymbolName: "dollarsign.circle.fill", accessibilityDescription: "Budget")
            ?? NSImage(size: NSSize(width: 1, height: 1))
        icon.isTemplate = true
        return (icon, formatUSD(spend), nil, fraction >= 1.0)
    }

    private func updateStatusBarTitle(_ snap: UsageSnapshot) {
        var parts = AppSettings.shared.providerOrder.compactMap { statusBarPart(for: $0, snap) }
        if let budget = budgetPart(snap) { parts.append(budget) }
        guard let button = statusItem.button else { return }
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.menuBarFont(ofSize: 0).pointSize, weight: .regular)
        let style = AppSettings.shared.limitStyle
        let title = NSMutableAttributedString()
        for part in parts {
            if title.length > 0 { title.append(NSAttributedString(string: "   ", attributes: [.font: font])) }
            let color: NSColor = part.warning ? .systemRed : .labelColor
            title.append(BrandIcons.attachment(part.icon, font: font, color: color))
            title.append(NSAttributedString(string: " ", attributes: [.font: font]))
            if let remaining = part.remainingPercent, style != .percentOnly {
                title.append(MiniMeter.attachment(remainingPercent: remaining, style: style, font: font, color: color))
            } else {
                title.append(NSAttributedString(string: part.text, attributes: [.font: font, .foregroundColor: color]))
            }
        }
        button.attributedTitle = title.length == 0 ? NSAttributedString(string: "AI —", attributes: [.font: font]) : title
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
        case .stale: return "login"
        case .rateLimited: return "…"
        case .notLoggedIn: return "—"
        case .error: return "!"
        }
    }

    /// Lowest remaining % across the Claude windows the user chose to show in
    /// the menu bar; nil when limits are absent or both windows are hidden.
    private func lowestClaudeRemaining(_ snap: UsageSnapshot) -> Double? {
        guard let l = snap.claudeLimits, case .ok = l.state else { return nil }
        let s = AppSettings.shared
        var values: [Double] = []
        if s.showFiveHourInMenuBar, let w = l.fiveHour { values.append(w.remainingPercent) }
        if s.showWeeklyInMenuBar, let w = l.sevenDay { values.append(w.remainingPercent) }
        return values.min()
    }

    /// Codex has no live API here — the reading is whatever the last Codex
    /// session logged. Weekly window only; Codex retired its 5-hour window.
    /// Returns nil when even that is missing.
    private func codexTitleValue(_ snap: UsageSnapshot) -> (text: String, remaining: Double)? {
        guard let l = snap.codexLimits else { return nil }
        if let s = l.secondary, !isExpired(s) {
            return (AppSettings.shared.displayMode.shortText(remaining: s.remainingPercent), s.remainingPercent)
        }
        return nil
    }

    private func isExpired(_ w: LimitWindow) -> Bool {
        if let r = w.resetsAt { return r <= Date() }
        return false
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
        case .rateLimited: print("Claude limits: rate limited (429) — retry later")
        case .stale: print("Claude limits: login expired (run claude to sign in)")
        case .notLoggedIn: print("Claude limits: not logged in")
        case .error(let m): print("Claude limits: error \(m)")
        }
    }
    if let x = snap.codex {
        print("Codex: total=\(formatTokens(x.totalTokens)) in=\(x.inputTokens) cached=\(x.cachedInputTokens) out=\(x.outputTokens) reasoning=\(x.reasoningTokens) sessions=\(x.sessionCount)")
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
