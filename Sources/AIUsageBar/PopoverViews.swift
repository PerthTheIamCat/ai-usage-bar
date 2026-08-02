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
        NoteText(text: "\(name): window reset — reopen CLI for fresh reading")
    } else {
        LimitRow(name: name, window: w)
    }
}

private struct SessionActivityRow: View {
    let session: SessionActivity
    @ObservedObject private var settings = AppSettings.shared
    @State private var isExpanded = false

    private var shortID: String {
        settings.showSessionIdentifiers ? String(session.id.prefix(12)) : "hidden"
    }

    private var timeText: String {
        session.lastActivityAt?.formatted(date: .omitted, time: .shortened) ?? "—"
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 4) {
                if !session.skills.isEmpty {
                    Text(session.inferredSkills.isEmpty ? "Skills · associated est. cost" : "Skills (inferred) · associated est. cost")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(formatSessionActivityDetails(session.skills, costs: session.skillCosts))
                        .font(.system(size: 11))
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !session.tools.isEmpty {
                    Text("Tools · associated est. cost")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(formatSessionActivityDetails(session.tools, costs: session.toolCosts))
                        .font(.system(size: 11))
                        .fixedSize(horizontal: false, vertical: true)
                }
                if session.skills.isEmpty && session.tools.isEmpty {
                    NoteText(text: "No Skill/tool calls recorded")
                }
            }
            .padding(.bottom, 4)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("Session \(shortID)")
                        .font(.system(size: 12, weight: .medium).monospaced())
                    Spacer()
                    Text(timeText)
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    if settings.showSessionWorkspace, let workspace = session.workspace, !workspace.isEmpty {
                        Text(workspace)
                    }
                    if let model = session.model, !model.isEmpty {
                        Text(model)
                    }
                    Text("· \(formatTokens(session.tokenTotal)) tokens")
                    if session.estimatedCostUSD > 0 {
                        Text("· \(formatUSD(session.estimatedCostUSD))")
                    }
                }
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
        }
        .font(.system(size: 12))
        .padding(.vertical, 2)
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
                        CaptionText(title: "Sessions today · skills & tools")
                        ForEach(c.sessions) { session in
                            SessionActivityRow(session: session)
                        }
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
                NoteText(text: "No local Claude statusline data — configure the bridge")
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
                        CaptionText(title: "Sessions today · skills & tools")
                        ForEach(x.sessions) { session in
                            SessionActivityRow(session: session)
                        }
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
    case provider(ProviderKind)
    case analytics
}

private struct SidebarRow: View {
    let icon: NSImage?
    let title: String
    let selected: Bool
    var body: some View {
        HStack(spacing: 8) {
            if let icon {
                Image(nsImage: icon).renderingMode(.template).resizable().frame(width: 15, height: 15)
            } else {
                Image(systemName: "chart.line.uptrend.xyaxis").frame(width: 15, height: 15)
            }
            Text(title).font(.system(size: 12, weight: selected ? .semibold : .regular))
            Spacer()
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
        case .provider(let kind): return kind.displayName
        case .analytics: return "Analytics"
        }
    }
    private func icon(for pane: PopoverPane) -> NSImage? {
        switch pane {
        case .provider(let kind): return kind.icon
        case .analytics: return nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(tabs, id: \.self) { pane in
                Button {
                    selection = pane
                } label: {
                    SidebarRow(icon: icon(for: pane), title: title(for: pane), selected: selection == pane)
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(width: 130)
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
            RefreshCountdownRepresentable(
                updatedAt: viewModel.snapshot.updatedAt,
                nextFire: viewModel.nextRefreshAt,
                interval: viewModel.refreshInterval
            )
            .frame(height: 20)
            .id(viewModel.nextRefreshAt)

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
        _selection = State(initialValue: Self.initialSelection(for: viewModel.snapshot))
    }

    private var tabs: [PopoverPane] {
        var t: [PopoverPane] = AppSettings.shared.providerOrder.compactMap { kind -> PopoverPane? in
            guard AppSettings.shared.isShownInPopover(kind) else { return nil }
            switch kind {
            case .claude: return viewModel.snapshot.claude != nil ? .provider(kind) : nil
            case .codex: return viewModel.snapshot.codex != nil ? .provider(kind) : nil
            case .antigravity: return viewModel.snapshot.antigravity != nil ? .provider(kind) : nil
            }
        }
        t.append(.analytics)
        return t
    }

    private static func initialSelection(for snap: UsageSnapshot) -> PopoverPane {
        for kind in AppSettings.shared.providerOrder {
            guard AppSettings.shared.isShownInPopover(kind) else { continue }
            switch kind {
            case .claude: if snap.claude != nil { return .provider(.claude) }
            case .codex: if snap.codex != nil { return .provider(.codex) }
            case .antigravity: if snap.antigravity != nil { return .provider(.antigravity) }
            }
        }
        return .analytics
    }

    var body: some View {
        HStack(spacing: 0) {
            PopoverSidebar(tabs: tabs, selection: $selection)
            Divider()
            VStack(spacing: 0) {
                Group {
                    switch selection {
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
        .onChange(of: viewModel.snapshot.updatedAt) { _ in
            // If the currently selected provider disappears (stopped being
            // detected), fall back instead of showing a dead pane.
            if case .provider = selection, !tabs.contains(selection) {
                selection = tabs.first ?? .analytics
            }
        }
    }
}
