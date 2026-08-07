import SwiftUI
import AppKit

// MARK: - NSViewRepresentable wrappers around the existing drawing code
// (MenuViews.swift) — reused as-is rather than reimplemented in SwiftUI.

private struct LimitBarRepresentable: NSViewRepresentable {
    let remainingPercent: Double
    func makeNSView(context: Context) -> LimitBarView {
        let v = LimitBarView()
        v.remainingPercent = remainingPercent
        return v
    }
    func updateNSView(_ nsView: LimitBarView, context: Context) {
        nsView.remainingPercent = remainingPercent
    }
}

private struct HourlyChartRepresentable: NSViewRepresentable {
    let usage: HourlyUsage
    func makeNSView(context: Context) -> HourlyUsageChartView { HourlyUsageChartView(usage: usage) }
    // HourlyUsageChartView's data is set once at init; the call site forces a
    // fresh instance via `.id(usage.values)` when the data actually changes.
    func updateNSView(_ nsView: HourlyUsageChartView, context: Context) {}
}

private struct DailyTrendChartRepresentable: NSViewRepresentable {
    let trend: DailyTrend
    func makeNSView(context: Context) -> DailyTrendChartView { DailyTrendChartView(trend: trend) }
    // Same story — call site uses `.id()` keyed on the range + day count.
    func updateNSView(_ nsView: DailyTrendChartView, context: Context) {}
}

private struct CalendarHeatmapRepresentable: NSViewRepresentable {
    let trend: DailyTrend
    func makeNSView(context: Context) -> CalendarHeatmapView { CalendarHeatmapView(trend: trend) }
    func updateNSView(_ nsView: CalendarHeatmapView, context: Context) {}
}

private struct RefreshCountdownRepresentable: NSViewRepresentable {
    let updatedAt: Date
    let nextFire: Date
    let interval: TimeInterval
    func makeNSView(context: Context) -> RefreshCountdownView {
        RefreshCountdownView(updatedAt: updatedAt, nextFire: nextFire, interval: interval)
    }
    // Same story as the chart above — call site uses `.id(nextFire)`.
    func updateNSView(_ nsView: RefreshCountdownView, context: Context) {}
}

// MARK: - Basic rows (SwiftUI equivalents of the old NSMenuItem factories)

struct CaptionText: View {
    let title: String
    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
    }
}

struct NoteText: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct StatRow: View {
    let name: String
    let value: String
    var body: some View {
        HStack {
            Text(name).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 8)
            Text(value).font(.system(size: 13, weight: .medium).monospacedDigit()).lineLimit(1)
        }
    }
}

/// Two independent label/value pairs side by side, matching the old
/// `statPairItem` layout: `label value    label value`.
struct StatPairRow: View {
    let name1: String
    let value1: String
    let name2: String?
    let value2: String?

    init(_ name1: String, _ value1: String, _ name2: String? = nil, _ value2: String? = nil) {
        self.name1 = name1; self.value1 = value1; self.name2 = name2; self.value2 = value2
    }

    var body: some View {
        HStack(spacing: 20) {
            StatRow(name: name1, value: value1).frame(maxWidth: .infinity)
            if let name2, let value2 {
                StatRow(name: name2, value: value2).frame(maxWidth: .infinity)
            } else {
                Spacer()
            }
        }
    }
}

struct PaneHeader: View {
    let title: String
    var icon: NSImage? = nil
    var iconTint: Color? = nil
    var body: some View {
        HStack(spacing: 8) {
            if let icon {
                Image(nsImage: icon)
                    .renderingMode(.template)
                    .resizable()
                    .frame(width: 18, height: 18)
                    .foregroundStyle(iconTint ?? Color.primary)
            }
            Text(title).font(.system(size: 16, weight: .bold))
            Spacer()
        }
        .padding(.bottom, 2)
    }
}

/// Always the capsule-bar layout — Settings › General › Limit style only
/// affects the compact menu-bar title, not the popover (the popover has
/// room to just always show the full bar + reset caption).
struct LimitRow: View {
    let name: String
    let window: LimitWindow

    var body: some View {
        let remaining = window.remainingPercent
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(name).font(.system(size: 13, weight: .medium))
                Spacer()
                Text(AppSettings.shared.displayMode.rowText(remaining: remaining))
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Color(nsColor: limitColor(remaining)))
            }
            LimitBarRepresentable(remainingPercent: remaining)
                .frame(height: 5)
            Text("resets in \(humanReset(window.resetsAt))")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

/// A limit window row, or a "window reset" note in its place once the
/// stored percentage has rolled past its reset time and is meaningless.
@ViewBuilder
func limitRowOrNote(_ name: String, _ w: LimitWindow) -> some View {
    if let r = w.resetsAt, r <= Date() {
        NoteText(text: "\(name): window reset — use Claude Code or the Desktop app for a fresh reading")
    } else {
        LimitRow(name: name, window: w)
    }
}

/// Shown when neither the Claude Code statusLine bridge nor the Desktop
/// app's local usage file has a reading yet. The Desktop app needs no setup
/// — this only offers to wire up the CLI bridge, and only when it isn't
/// already configured.
struct ClaudeStatusLineSetupPrompt: View {
    @State private var setupState = ClaudeStatusLineSetup.currentState()
    @State private var resultMessage: String?
    @State private var resultIsError = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch setupState {
            case .configured:
                NoteText(text: "Status line bridge is configured — open Claude Code once to send a reading, or use the Desktop app.")
            case .notConfigured:
                NoteText(text: "No local Claude reading yet. The Desktop app needs no setup — open it and use Claude once. For Claude Code (CLI), set up the status line bridge:")
                Button("Set Up Status Line Bridge") {
                    let result = ClaudeStatusLineSetup.install()
                    switch result {
                    case .success:
                        resultMessage = "Bridge installed. Restart Claude Code, then send a message to get a reading."
                        resultIsError = false
                        setupState = ClaudeStatusLineSetup.currentState()
                    case .failure(let error):
                        resultMessage = error.errorDescription
                        resultIsError = true
                    }
                }
                .font(.system(size: 11))
            }
            if let resultMessage {
                Text(resultMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(resultIsError ? Color.red : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Overview (default landing pane — "how much do I have left")

/// A slimmer limit row for cards: label, thin bar, and percent on one line,
/// no reset caption. `ProviderSummaryCard` shows reset time once for the
/// tighter of the two windows instead of repeating it per row.
private struct MiniLimitRow: View {
    let label: String
    let window: LimitWindow
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 46, alignment: .leading)
            LimitBarRepresentable(remainingPercent: window.remainingPercent)
                .frame(height: 5)
            // The meter already fills according to the display mode, so the
            // number has to follow it — printing "left" next to a bar drawn
            // as "used" made the same window read 11% here and 89% in the
            // menu bar.
            Text(settings.displayMode.shortText(remaining: window.remainingPercent))
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(Color(nsColor: limitColor(window.remainingPercent)))
                .frame(width: 34, alignment: .trailing)
        }
    }
}

/// One card per detected provider: identity, remaining-capacity bars, and a
/// single "today" line — nothing else. Tapping opens that provider's full
/// detail pane (token breakdown, sessions, skills, etc.), which now lives
/// one click away instead of being the default view.
private struct ProviderSummaryCard: View {
    let kind: ProviderKind
    let title: String
    let icon: NSImage
    let iconTint: Color?
    let fiveHour: LimitWindow?
    let weekly: LimitWindow?
    let problem: String?
    let todayLine: String?
    let onTap: () -> Void

    private var tightestReset: Date? {
        [fiveHour, weekly].compactMap { $0 }
            .min { $0.remainingPercent < $1.remainingPercent }?
            .resetsAt
    }

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(nsImage: icon)
                        .renderingMode(.template)
                        .resizable()
                        .frame(width: 16, height: 16)
                        .foregroundStyle(iconTint ?? Color.primary)
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }

                if let problem {
                    NoteText(text: problem)
                } else if fiveHour == nil && weekly == nil {
                    NoteText(text: "No limit data yet")
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        if let w = fiveHour { MiniLimitRow(label: "5-hour", window: w) }
                        if let w = weekly { MiniLimitRow(label: "Weekly", window: w) }
                    }
                    if let reset = tightestReset {
                        Text("resets in \(humanReset(reset))")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                    }
                }

                if let todayLine {
                    Text(todayLine)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The single lowest-remaining window across every shown provider — the
/// answer to "how much AI usage do I actually have left right now."
private struct HeroRemainingCard: View {
    let providerTitle: String
    let windowLabel: String
    let window: LimitWindow
    @ObservedObject private var settings = AppSettings.shared

    /// The window shown is the same either way — it is the tightest one. Only
    /// the framing flips, so the headline never contradicts the menu bar.
    private var shownFraction: Double {
        let value = settings.displayMode == .used ? 100 - window.remainingPercent : window.remainingPercent
        return value / 100
    }

    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle()
                    .stroke(Color.secondary.opacity(0.15), lineWidth: 7)
                Circle()
                    .trim(from: 0, to: max(0.003, shownFraction))
                    .stroke(Color(nsColor: limitColor(window.remainingPercent)),
                            style: StrokeStyle(lineWidth: 7, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text(settings.displayMode.shortText(remaining: window.remainingPercent))
                    .font(.system(size: 16, weight: .bold).monospacedDigit())
            }
            .frame(width: 60, height: 60)

            VStack(alignment: .leading, spacing: 3) {
                Text(settings.displayMode == .used ? "Highest used" : "Lowest remaining")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("\(providerTitle) · \(windowLabel)")
                    .font(.system(size: 14, weight: .semibold))
                Text("resets in \(humanReset(window.resetsAt))")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
    }
}

struct OverviewPane: View {
    let snap: UsageSnapshot
    let claudeLimitsProblem: String?
    let onSelectProvider: (ProviderKind) -> Void
    @ObservedObject private var settings = AppSettings.shared

    private struct Card {
        let kind: ProviderKind
        let title: String
        let fiveHour: LimitWindow?
        let weekly: LimitWindow?
        let problem: String?
        let todayLine: String?
    }

    private func shown(_ windowKind: LimitWindowKind, for kind: ProviderKind, _ window: LimitWindow?) -> LimitWindow? {
        settings.isLimitWindowShown(windowKind, for: kind) ? window : nil
    }

    private var cards: [Card] {
        settings.providerOrder.compactMap { kind -> Card? in
            guard settings.isShownInPopover(kind) else { return nil }
            switch kind {
            case .claude:
                guard let c = snap.claude else { return nil }
                let limits = snap.claudeLimits
                let isUsable: Bool = { if case .ok = limits?.state { return true }; return false }()
                return Card(
                    kind: kind, title: "Claude Code",
                    fiveHour: isUsable ? shown(.fiveHour, for: kind, limits?.fiveHour) : nil,
                    weekly: isUsable ? shown(.weekly, for: kind, limits?.sevenDay) : nil,
                    problem: claudeLimitsProblem ?? (isUsable ? nil : "No local reading yet — tap for setup"),
                    todayLine: "\(formatTokens(c.total)) tokens · \(formatUSD(Pricing.claudeCostUSD(c))) today")
            case .codex:
                guard let x = snap.codex else { return nil }
                let limits = snap.codexLimits
                return Card(
                    kind: kind, title: limits?.planType.map { "Codex (\($0))" } ?? "Codex",
                    fiveHour: shown(.fiveHour, for: kind, limits?.primary),
                    weekly: shown(.weekly, for: kind, limits?.secondary),
                    problem: limits == nil ? "No limit data yet — run codex once" : nil,
                    todayLine: "\(formatTokens(x.totalTokens)) tokens · \(formatUSD(Pricing.codexCostUSD(x))) today")
            case .antigravity:
                guard let g = snap.antigravity else { return nil }
                return Card(
                    kind: kind, title: "Antigravity",
                    fiveHour: shown(.fiveHour, for: kind, g.fiveHour),
                    weekly: shown(.weekly, for: kind, g.weekly),
                    problem: (g.fiveHour == nil && g.weekly == nil) ? "No quota data yet — use Antigravity once" : nil,
                    todayLine: "\(g.totalPrompts) prompts · \(formatUSD(Pricing.antigravityCostUSD(g))) today")
            }
        }
    }

    /// The single tightest (lowest-remaining) window across every card,
    /// ignoring ones already past their reset (meaningless) or hidden by a
    /// problem state.
    private var tightest: (title: String, label: String, window: LimitWindow)? {
        var best: (title: String, label: String, window: LimitWindow)?
        for card in cards {
            for (label, w) in [("5-hour", card.fiveHour), ("Weekly", card.weekly)] {
                // Skip only windows already known to have rolled over. A nil
                // reset means "unknown", not "expired" — the Claude Desktop
                // snapshot carries no reset time, so requiring one here hid
                // every Claude window from the headline.
                guard let w else { continue }
                if let reset = w.resetsAt, reset <= Date() { continue }
                if let current = best, current.window.remainingPercent <= w.remainingPercent { continue }
                best = (card.title, label, w)
            }
        }
        return best
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                PaneHeader(title: "Overview")

                if let tightest {
                    HeroRemainingCard(providerTitle: tightest.title, windowLabel: tightest.label, window: tightest.window)
                }

                if cards.isEmpty {
                    NoteText(text: "No AI CLI detected yet. Looked for ~/.claude, ~/.codex and ~/.gemini.")
                } else {
                    ForEach(cards, id: \.kind.id) { card in
                        ProviderSummaryCard(
                            kind: card.kind, title: card.title, icon: card.kind.icon,
                            iconTint: card.kind == .claude ? Color(nsColor: BrandIcons.claudeBrandColor)
                                : card.kind == .antigravity ? Color(nsColor: BrandIcons.geminiBrandColor) : nil,
                            fiveHour: card.fiveHour, weekly: card.weekly,
                            problem: card.problem, todayLine: card.todayLine,
                            onTap: { onSelectProvider(card.kind) })
                    }
                }
                NoteText(text: "Tap a provider for token breakdowns, sessions, and cost trends.")
                Spacer(minLength: 0)
            }
            .padding(16)
        }
    }
}

// MARK: - Provider panes

struct ClaudePane: View {
    let snap: UsageSnapshot
    let claudeLimitsProblem: String?
    let lastGoodClaudeFetchedAt: Date?
    @ObservedObject private var settings = AppSettings.shared

    private var c: ClaudeUsage? { snap.claude }
    private var costUSD: Double { c.map(Pricing.claudeCostUSD) ?? 0 }

    private var problemText: String? {
        guard let problem = claudeLimitsProblem else { return nil }
        var text = "⚠︎ \(problem)"
        if let goodAt = lastGoodClaudeFetchedAt {
            text += " · showing data from \(humanAgo(goodAt))"
        }
        return text
    }

    private var modelBreakdown: [(model: String, total: Int, costUSD: Double)] {
        guard let c else { return [] }
        return c.perModel
            .map { (model: $0.key,
                    total: $0.value.input + $0.value.output + $0.value.cacheWrite + $0.value.cacheRead,
                    costUSD: Pricing.claudeModelCostUSD($0.value, model: $0.key)) }
            .sorted { $0.costUSD > $1.costUSD }
    }

    /// Sorted most-recently-used first — answers "what did I just use" as
    /// well as "which skills, how often."
    private var skillBreakdown: [(skill: String, count: Int, lastUsed: Date?)] {
        guard let c else { return [] }
        return c.skillCounts
            .map { (skill: $0.key, count: $0.value, lastUsed: c.skillLastUsed[$0.key]) }
            .sorted { ($0.lastUsed ?? .distantPast) > ($1.lastUsed ?? .distantPast) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let c {
                    PaneHeader(title: "Claude Code", icon: BrandIcons.claude, iconTint: Color(nsColor: BrandIcons.claudeBrandColor))
                    if let problemText { NoteText(text: problemText) }
                    claudeLimitsSection

                    CaptionText(title: "Today's tokens")
                    StatPairRow("Total", formatTokens(c.total), "Sessions", "\(c.sessionCount)")
                    if settings.showsDetail(.tokenBreakdown, for: .claude) {
                        StatPairRow("Input", formatTokens(c.inputTokens), "Output", formatTokens(c.outputTokens))
                        StatPairRow("Cache write", formatTokens(c.cacheCreationTokens), "Cache read", formatTokens(c.cacheReadTokens))
                    }

                    if settings.showsDetail(.cacheHitRate, for: .claude) {
                        StatRow(name: "Cache hit rate", value: "\(Int(Pricing.claudeCacheHitRatePercent(c).rounded()))%")
                    }

                    if settings.showsDetail(.modelBreakdown, for: .claude) && modelBreakdown.count > 1 {
                        CaptionText(title: "By model")
                        ForEach(modelBreakdown, id: \.model) { m in
                            StatRow(name: m.model, value: "\(formatTokens(m.total)) · \(formatUSD(m.costUSD))")
                        }
                    }

                    if settings.showsDetail(.skillsUsed, for: .claude) && !skillBreakdown.isEmpty {
                        CaptionText(title: "Skills used today · most recent first")
                        ForEach(skillBreakdown, id: \.skill) { s in
                            StatRow(name: s.skill, value: "\(s.count)× · \(s.lastUsed.map(humanAgo) ?? "—")")
                        }
                    }

                    if settings.showsDetail(.sessionActivity, for: .claude) && !c.sessions.isEmpty {
                        SessionActivitySection(title: "Sessions today · skills & tools", sessions: c.sessions)
                    }

                    if let m = c.lastModel {
                        StatRow(name: "Last model", value: m)
                    }

                    if settings.showsDetail(.averagePerSession, for: .claude) {
                        StatRow(name: "Avg/session",
                                value: "\(formatTokens(c.total / max(1, c.sessionCount))) · \(formatUSD(costUSD / Double(max(1, c.sessionCount))))")
                    }
                    StatRow(name: "Est. cost", value: "\(formatTHB(costUSD)) · \(formatUSD(costUSD))")

                    if settings.showsDetail(.periodCost, for: .claude), let pc = snap.periodCosts, let d7 = pc.claudeUSD7, let d30 = pc.claudeUSD30 {
                        StatPairRow("7-day", formatUSD(d7), "30-day", formatUSD(d30))
                    }
                } else {
                    PaneHeader(title: "Claude Code")
                    NoteText(text: "Not detected.")
                }
                Spacer(minLength: 0)
            }
            .padding(16)
        }
    }

    @ViewBuilder
    private var claudeLimitsSection: some View {
        if let l = snap.claudeLimits {
            switch l.state {
            case .ok:
                if settings.isLimitWindowShown(.fiveHour, for: .claude), let w = l.fiveHour { limitRowOrNote("5-hour", w) }
                if settings.isLimitWindowShown(.weekly, for: .claude), let w = l.sevenDay { limitRowOrNote("Weekly", w) }
                if !settings.isLimitWindowShown(.fiveHour, for: .claude)
                    && !settings.isLimitWindowShown(.weekly, for: .claude) {
                    NoteText(text: "Both windows hidden — enable in Settings › Providers")
                }
            case .unavailable:
                ClaudeStatusLineSetupPrompt()
            case .stale:
                NoteText(text: "Local Claude statusline data is stale — use Claude Code again")
            case .error(let message):
                NoteText(text: "Claude local limits unavailable — \(message)")
            }
        } else {
            NoteText(text: "Fetching limits…")
        }
    }
}

struct CodexPane: View {
    let snap: UsageSnapshot
    @ObservedObject private var settings = AppSettings.shared

    private var x: CodexUsage? { snap.codex }
    private var costUSD: Double { x.map(Pricing.codexCostUSD) ?? 0 }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let x {
                    let title = snap.codexLimits?.planType.map { "Codex (\($0))" } ?? "Codex"
                    PaneHeader(title: title, icon: BrandIcons.codex)
                    codexLimitsSection

                    CaptionText(title: "Today's tokens")
                    StatPairRow("Total", formatTokens(x.totalTokens), "Sessions", "\(x.sessionCount)")

                    if settings.showsDetail(.tokenBreakdown, for: .codex) {
                        StatPairRow("Input", formatTokens(x.inputTokens), "Cached in", formatTokens(x.cachedInputTokens))
                        StatPairRow("Output", formatTokens(x.outputTokens), "Reasoning", formatTokens(x.reasoningTokens))
                    }
                    if settings.showsDetail(.cacheHitRate, for: .codex) {
                        StatRow(name: "Cache hit rate", value: "\(Int(Pricing.codexCacheHitRatePercent(x).rounded()))%")
                    }
                    if settings.showsDetail(.sessionActivity, for: .codex) && !x.sessions.isEmpty {
                        SessionActivitySection(title: "Sessions today · skills & tools", sessions: x.sessions)
                    }
                    if settings.showsDetail(.averagePerSession, for: .codex) {
                        StatRow(name: "Avg/session",
                                value: "\(formatTokens(x.totalTokens / max(1, x.sessionCount))) · \(formatUSD(costUSD / Double(max(1, x.sessionCount))))")
                    }
                    StatRow(name: "Est. cost", value: "\(formatTHB(costUSD)) · \(formatUSD(costUSD))")
                    if settings.showsDetail(.periodCost, for: .codex), let pc = snap.periodCosts, let d7 = pc.codexUSD7, let d30 = pc.codexUSD30 {
                        StatPairRow("7-day", formatUSD(d7), "30-day", formatUSD(d30))
                    }
                } else {
                    PaneHeader(title: "Codex")
                    NoteText(text: "Not detected.")
                }
                Spacer(minLength: 0)
            }
            .padding(16)
        }
    }

    @ViewBuilder
    private var codexLimitsSection: some View {
        if let l = snap.codexLimits {
            CaptionText(title: "Limits · as of \(humanAgo(l.asOf))")
            let settings = AppSettings.shared
            if settings.isLimitWindowShown(.fiveHour, for: .codex), let w = l.primary { limitRowOrNote("5-hour", w) }
            if settings.isLimitWindowShown(.weekly, for: .codex), let w = l.secondary { limitRowOrNote("Weekly", w) }
        } else {
            NoteText(text: "No limit data yet — run codex once")
        }
    }
}

struct AntigravityPane: View {
    let snap: UsageSnapshot
    @ObservedObject private var settings = AppSettings.shared

    private var g: AntigravityUsage? { snap.antigravity }
    private var costUSD: Double { g.map(Pricing.antigravityCostUSD) ?? 0 }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let g {
                    PaneHeader(title: "Antigravity", icon: BrandIcons.gemini, iconTint: Color(nsColor: BrandIcons.geminiBrandColor))
                    antigravityLimitsSection(g)

                    CaptionText(title: "Today's activity")
                    StatPairRow("Prompts", "\(g.totalPrompts)", "Sessions", "\(g.sessionCount)")
                    if settings.showsDetail(.averagePerSession, for: .antigravity) {
                        StatRow(name: "Avg/session",
                                value: "\(g.totalPrompts / max(1, g.sessionCount))P · \(formatUSD(costUSD / Double(max(1, g.sessionCount))))")
                    }
                    StatRow(name: "Est. cost", value: "\(formatTHB(costUSD)) · \(formatUSD(costUSD))")
                    if settings.showsDetail(.periodCost, for: .antigravity), let pc = snap.periodCosts, let d7 = pc.antigravityUSD7, let d30 = pc.antigravityUSD30 {
                        StatPairRow("7-day", formatUSD(d7), "30-day", formatUSD(d30))
                    }
                } else {
                    PaneHeader(title: "Antigravity")
                    NoteText(text: "Not detected.")
                }
                Spacer(minLength: 0)
            }
            .padding(16)
        }
    }

    @ViewBuilder
    private func antigravityLimitsSection(_ g: AntigravityUsage) -> some View {
        let settings = AppSettings.shared
        let fiveHour = settings.isLimitWindowShown(.fiveHour, for: .antigravity) ? g.fiveHour : nil
        let weekly = settings.isLimitWindowShown(.weekly, for: .antigravity) ? g.weekly : nil
        if fiveHour == nil && weekly == nil {
            NoteText(text: "No quota data yet — use Antigravity once to refresh it")
        } else {
            if let w = fiveHour { limitRowOrNote("5-hour", w) }
            if let w = weekly { limitRowOrNote("Weekly", w) }
        }
    }
}

private let weekdaySymbols = Calendar.current.weekdaySymbols // index 0 = Sunday, matching Calendar's 1-based .weekday component - 1

struct AnalyticsPane: View {
    let snap: UsageSnapshot
    @State private var trendDays = 7

    private var hasAnyProvider: Bool {
        snap.claude != nil || snap.codex != nil || snap.antigravity != nil
    }

    /// The cached 30-day trend covers both range options — a 7-day view is
    /// just its last 7 entries, so switching ranges doesn't need a re-fetch.
    private func trend(for days: Int) -> DailyTrend? {
        guard let full = snap.dailyTrend, full.days.count >= days else { return nil }
        var sliced = DailyTrend()
        sliced.days = Array(full.days.suffix(days))
        sliced.claudeTokens = Array(full.claudeTokens.suffix(days))
        sliced.claudeCostUSD = Array(full.claudeCostUSD.suffix(days))
        sliced.codexTokens = Array(full.codexTokens.suffix(days))
        sliced.codexCostUSD = Array(full.codexCostUSD.suffix(days))
        sliced.antigravityPrompts = Array(full.antigravityPrompts.suffix(days))
        sliced.antigravityCostUSD = Array(full.antigravityCostUSD.suffix(days))
        return sliced
    }

    /// nil when the alert is off, or spend hasn't reached 80% of budget yet.
    private var budgetBanner: (text: String, isOver: Bool)? {
        let s = AppSettings.shared
        guard s.budgetEnabled, s.budgetAmountUSD > 0 else { return nil }
        let spend: Double
        let periodLabel: String
        switch s.budgetPeriod {
        case .day:
            spend = (snap.claude.map(Pricing.claudeCostUSD) ?? 0)
                + (snap.codex.map(Pricing.codexCostUSD) ?? 0)
                + (snap.antigravity.map(Pricing.antigravityCostUSD) ?? 0)
            periodLabel = "today"
        case .month:
            guard let pc = snap.periodCosts else { return nil }
            spend = (pc.claudeUSD30 ?? 0) + (pc.codexUSD30 ?? 0) + (pc.antigravityUSD30 ?? 0)
            periodLabel = "in the last 30 days"
        }
        let fraction = spend / s.budgetAmountUSD
        guard fraction >= 0.8 else { return nil }
        let verb = fraction >= 1 ? "Over budget" : "Near budget"
        return ("\(verb) — \(formatUSD(spend)) of \(formatUSD(s.budgetAmountUSD)) \(periodLabel)", fraction >= 1)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let budget = budgetBanner {
                    Text(budget.text)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(budget.isOver ? Color.red : Color.orange)
                    Divider()
                }

                if !hasAnyProvider {
                    PaneHeader(title: "No AI CLI detected")
                    NoteText(text: "Looked for ~/.claude, ~/.codex and ~/.gemini")
                    Divider()
                }

                PaneHeader(title: "Today")
                if let peak = snap.hourlyUsage.peakHour {
                    NoteText(text: "Peak activity: \(String(format: "%02d:00", peak)) · \(formatTokens(snap.hourlyUsage.values[peak])) units")
                }
                HourlyChartRepresentable(usage: snap.hourlyUsage)
                    .frame(height: 148)
                    .id(snap.hourlyUsage.values)

                Divider().padding(.vertical, 4)

                HStack {
                    PaneHeader(title: "Trend")
                    Spacer()
                    Picker("", selection: $trendDays) {
                        Text("7 days").tag(7)
                        Text("30 days").tag(30)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 150)
                }
                if let trend = trend(for: trendDays) {
                    if let busiest = trend.busiestWeekday, trend.days.count > 7 {
                        NoteText(text: "Busiest day: \(weekdaySymbols[busiest.weekday - 1])")
                    }
                    DailyTrendChartRepresentable(trend: trend)
                        .frame(height: 140)
                        .id(trendDays)
                } else {
                    NoteText(text: "Still gathering trend data — check back in a bit.")
                }

                if let full = snap.dailyTrend {
                    Divider().padding(.vertical, 4)
                    PaneHeader(title: "Activity")
                    CalendarHeatmapRepresentable(trend: full)
                        .frame(height: 120)
                        .id(full.days.count)
                }
                Spacer(minLength: 0)
            }
            .padding(16)
        }
    }
}

// MARK: - Sidebar

enum PopoverPane: Hashable {
    case overview
    case provider(ProviderKind)
    case analytics
}

private struct SidebarRow: View {
    let icon: NSImage?
    let systemIcon: String
    let title: String
    let selected: Bool
    var body: some View {
        HStack(spacing: 8) {
            if let icon {
                Image(nsImage: icon).renderingMode(.template).resizable().frame(width: 15, height: 15)
            } else {
                Image(systemName: systemIcon).frame(width: 15, height: 15)
            }
            // Fixed weight with the selected state carried by the background
            // instead: switching to semibold on selection widens the text
            // enough to wrap onto a second line and the row visibly jumps.
            Text(title)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(selected ? Color.primary : Color.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? Color.accentColor.opacity(0.18) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
    }
}

struct PopoverSidebar: View {
    let tabs: [PopoverPane]
    @Binding var selection: PopoverPane

    private func title(for pane: PopoverPane) -> String {
        switch pane {
        case .overview: return "Overview"
        case .provider(let kind): return kind.displayName
        case .analytics: return "Analytics"
        }
    }
    private func icon(for pane: PopoverPane) -> NSImage? {
        switch pane {
        case .overview: return nil
        case .provider(let kind): return kind.icon
        case .analytics: return nil
        }
    }
    private func systemIcon(for pane: PopoverPane) -> String {
        switch pane {
        case .overview: return "gauge.medium"
        case .provider: return ""
        case .analytics: return "chart.line.uptrend.xyaxis"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(tabs, id: \.self) { pane in
                Button {
                    selection = pane
                } label: {
                    SidebarRow(icon: icon(for: pane), systemIcon: systemIcon(for: pane), title: title(for: pane), selected: selection == pane)
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        // Wide enough for the longest tab name ("Claude Code") on one line.
        .frame(width: 152)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

// MARK: - Footer (always visible, regardless of selected tab)

struct PopoverFooter: View {
    @ObservedObject var viewModel: UsageViewModel
    let appVersion: String
    let onRefresh: () -> Void
    let onCheckForUpdates: () -> Void
    let onExportReport: () -> Void
    let onExportJSON: () -> Void
    let onExportCSV: () -> Void
    let onSaveCSV: () -> Void
    let onSettings: () -> Void
    let onQuit: () -> Void

    @State private var justCopied = false

    private func copy(_ action: () -> Void) {
        action()
        justCopied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { justCopied = false }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            if let loadingMessage = viewModel.loadingMessage {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text(loadingMessage)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(height: 20)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Loading usage data")
                .accessibilityValue(loadingMessage)
            } else {
                RefreshCountdownRepresentable(
                    updatedAt: viewModel.snapshot.updatedAt,
                    nextFire: viewModel.nextRefreshAt,
                    interval: viewModel.refreshInterval
                )
                .frame(height: 20)
                .id(viewModel.nextRefreshAt)
            }

            Text("AI Usage Bar v\(appVersion)")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Button("Refresh Now", action: onRefresh)
                Button("Check for Updates…", action: onCheckForUpdates)
                Spacer()
            }
            HStack(spacing: 8) {
                Menu {
                    Button("Copy Markdown report") { copy(onExportReport) }
                    Button("Copy JSON") { copy(onExportJSON) }
                    Button("Copy CSV") { copy(onExportCSV) }
                    Divider()
                    Button("Save CSV…", action: onSaveCSV)
                } label: {
                    Label(justCopied ? "Copied!" : "Export…", systemImage: "square.and.arrow.up")
                }
                Spacer()
            }
            HStack(spacing: 8) {
                Button("Settings…", action: onSettings)
                Spacer()
                Button("Quit", action: onQuit)
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .font(.system(size: 12))
        .padding(EdgeInsets(top: 8, leading: 16, bottom: 12, trailing: 16))
    }
}

// MARK: - Root

struct PopoverContentView: View {
    @ObservedObject var viewModel: UsageViewModel
    @ObservedObject private var settings = AppSettings.shared
    @State private var selection: PopoverPane
    let appVersion: String
    let onRefresh: () -> Void
    let onCheckForUpdates: () -> Void
    let onExportReport: () -> Void
    let onExportJSON: () -> Void
    let onExportCSV: () -> Void
    let onSaveCSV: () -> Void
    let onSettings: () -> Void
    let onQuit: () -> Void

    init(
        viewModel: UsageViewModel, appVersion: String,
        onRefresh: @escaping () -> Void, onCheckForUpdates: @escaping () -> Void,
        onExportReport: @escaping () -> Void, onExportJSON: @escaping () -> Void,
        onExportCSV: @escaping () -> Void, onSaveCSV: @escaping () -> Void,
        onSettings: @escaping () -> Void, onQuit: @escaping () -> Void
    ) {
        self.viewModel = viewModel
        self.appVersion = appVersion
        self.onRefresh = onRefresh
        self.onCheckForUpdates = onCheckForUpdates
        self.onExportReport = onExportReport
        self.onExportJSON = onExportJSON
        self.onExportCSV = onExportCSV
        self.onSaveCSV = onSaveCSV
        self.onSettings = onSettings
        self.onQuit = onQuit
        _selection = State(initialValue: .overview)
    }

    private var tabs: [PopoverPane] {
        var t: [PopoverPane] = [.overview]
        t += settings.providerOrder.compactMap { kind -> PopoverPane? in
            guard settings.isShownInPopover(kind) else { return nil }
            switch kind {
            case .claude: return viewModel.snapshot.claude != nil ? .provider(kind) : nil
            case .codex: return viewModel.snapshot.codex != nil ? .provider(kind) : nil
            case .antigravity: return viewModel.snapshot.antigravity != nil ? .provider(kind) : nil
            }
        }
        t.append(.analytics)
        return t
    }

    private func repairSelection() {
        if !tabs.contains(selection) {
            selection = .overview
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            PopoverSidebar(tabs: tabs, selection: $selection)
            Divider()
            VStack(spacing: 0) {
                Group {
                    switch selection {
                    case .overview:
                        OverviewPane(snap: viewModel.snapshot, claudeLimitsProblem: viewModel.claudeLimitsProblem, onSelectProvider: { selection = .provider($0) })
                    case .provider(.claude):
                        ClaudePane(snap: viewModel.snapshot, claudeLimitsProblem: viewModel.claudeLimitsProblem, lastGoodClaudeFetchedAt: viewModel.lastGoodClaudeFetchedAt)
                    case .provider(.codex):
                        CodexPane(snap: viewModel.snapshot)
                    case .provider(.antigravity):
                        AntigravityPane(snap: viewModel.snapshot)
                    case .analytics:
                        AnalyticsPane(snap: viewModel.snapshot)
                    }
                }
                .frame(maxHeight: .infinity)
                PopoverFooter(viewModel: viewModel, appVersion: appVersion, onRefresh: onRefresh, onCheckForUpdates: onCheckForUpdates, onExportReport: onExportReport, onExportJSON: onExportJSON, onExportCSV: onExportCSV, onSaveCSV: onSaveCSV, onSettings: onSettings, onQuit: onQuit)
            }
            .frame(width: 380)
        }
        .frame(height: 480)
        .onChange(of: settings.popoverHiddenProviders) { _ in
            repairSelection()
        }
        .onChange(of: settings.providerOrder) { _ in
            repairSelection()
        }
        .onChange(of: viewModel.snapshot.updatedAt) { _ in
            // If the currently selected provider disappears (stopped being
            // detected), fall back instead of showing a dead pane.
            repairSelection()
        }
    }
}
