import Foundation
import Combine
import AppKit

extension Notification.Name {
    /// Posted whenever a setting changes so the status item re-renders.
    static let usageSettingsChanged = Notification.Name("usageSettingsChanged")
}

/// How percentages are presented everywhere (menu-bar title, menu rows, bars).
enum UsageDisplayMode: String, CaseIterable, Identifiable {
    case remaining  // "84% left"
    case used       // "16% used"

    var id: String { rawValue }

    /// Short form for the menu-bar title.
    func shortText(remaining: Double) -> String {
        switch self {
        case .remaining: return "\(Int(remaining.rounded()))%"
        case .used: return "\(Int((100 - remaining).rounded()))%"
        }
    }

    /// Long form for menu limit rows.
    func rowText(remaining: Double) -> String {
        switch self {
        case .remaining: return "\(Int(remaining.rounded()))% left"
        case .used: return "\(Int((100 - remaining).rounded()))% used"
        }
    }
}

/// How a limit window's remaining capacity is drawn in the compact menu-bar
/// title. The popover always shows the full bar meter regardless.
enum LimitStyle: String, CaseIterable, Identifiable {
    case bar        // small inline capsule meter
    case ring       // small inline circular arc meter
    case percentOnly // colored percentage text only, no meter graphic
    case barAndPercent
    case ringAndPercent
    case dotAndPercent

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .bar: return "Bar"
        case .ring: return "Ring"
        case .percentOnly: return "Percent only"
        case .barAndPercent: return "Bar + percent"
        case .ringAndPercent: return "Ring + percent"
        case .dotAndPercent: return "Dot + percent"
        }
    }

    var showsMeter: Bool { self != .percentOnly }

    var showsPercent: Bool {
        switch self {
        case .percentOnly, .barAndPercent, .ringAndPercent, .dotAndPercent: return true
        case .bar, .ring: return false
        }
    }
}

enum LimitWindowKind: String, CaseIterable, Identifiable, Codable {
    case fiveHour
    case weekly

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .fiveHour: return "5-hour window"
        case .weekly: return "Weekly window"
        }
    }
}

enum ProviderDetailKind: String, CaseIterable, Identifiable, Codable {
    case tokenBreakdown
    case cacheHitRate
    case modelBreakdown
    case averagePerSession
    case periodCost
    case skillsUsed
    case sessionActivity

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .tokenBreakdown: return "Token breakdown"
        case .cacheHitRate: return "Cache hit rate"
        case .modelBreakdown: return "Per-model breakdown"
        case .averagePerSession: return "Average per session"
        case .periodCost: return "7-day / 30-day cost"
        case .skillsUsed: return "Skills used today"
        case .sessionActivity: return "Skills & tools by session"
        }
    }
}

/// Rolling window a budget alert is measured against. "Month" is a rolling
/// 30 days (reuses the existing 30-day cost aggregate), not the calendar month.
enum BudgetPeriod: String, CaseIterable, Identifiable {
    case day, month

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .day: return "Per day"
        case .month: return "Per 30 days"
        }
    }
}

/// A detected usage provider. Order here is the fallback default order;
/// users can reorder in Settings › Providers, which drives both the
/// status-bar segment order and the dropdown section order.
enum ProviderKind: String, CaseIterable, Identifiable, Codable {
    case claude, codex, antigravity

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .antigravity: return "Antigravity"
        }
    }

    var icon: NSImage {
        switch self {
        case .claude: return BrandIcons.claude
        case .codex: return BrandIcons.codex
        case .antigravity: return BrandIcons.gemini
        }
    }

    var supportedLimitWindows: [LimitWindowKind] {
        [.fiveHour, .weekly]
    }

    var supportedDetails: [ProviderDetailKind] {
        switch self {
        case .claude:
            return [.tokenBreakdown, .cacheHitRate, .modelBreakdown, .averagePerSession, .periodCost, .skillsUsed, .sessionActivity]
        case .codex:
            return [.tokenBreakdown, .cacheHitRate, .averagePerSession, .periodCost, .sessionActivity]
        case .antigravity:
            return [.averagePerSession, .periodCost]
        }
    }
}

/// UserDefaults-backed app settings, observable from SwiftUI.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private enum Keys {
        static let displayMode = "displayMode"
        static let warnBelowRemaining = "warnBelowRemaining"
        static let showFiveHourInMenuBar = "showFiveHourInMenuBar"
        static let showWeeklyInMenuBar = "showWeeklyInMenuBar"
        static let thbPerUSD = "thbPerUSD"
        static let thbAutoFetch = "thbAutoFetch"
        static let thbLastFetched = "thbLastFetched"
        static let providerOrder = "providerOrder"
        static let providerLimitStyles = "providerLimitStyles"
        static let providerVisibleWindows = "providerVisibleWindows"
        static let popoverHiddenProviders = "popoverHiddenProviders"
        static let providerDetails = "providerDetails"
        static let showCacheHitRate = "showCacheHitRate"
        static let showModelBreakdown = "showModelBreakdown"
        static let showAvgPerSession = "showAvgPerSession"
        static let showPeriodCost = "showPeriodCost"
        static let showSkillsUsed = "showSkillsUsed"
        static let showSessionActivity = "showSessionActivity"
        static let menuBarHiddenProviders = "menuBarHiddenProviders"
        static let limitStyle = "limitStyle"
        static let budgetEnabled = "budgetEnabled"
        static let budgetAmountUSD = "budgetAmountUSD"
        static let budgetPeriod = "budgetPeriod"
        static let notificationsEnabled = "notificationsEnabled"
        static let showSessionIdentifiers = "showSessionIdentifiers"
        static let showSessionWorkspace = "showSessionWorkspace"
        static let sessionAlertEnabled = "sessionAlertEnabled"
        static let sessionAlertThreshold = "sessionAlertThreshold"
    }

    @Published var displayMode: UsageDisplayMode {
        didSet {
            UserDefaults.standard.set(displayMode.rawValue, forKey: Keys.displayMode)
            NotificationCenter.default.post(name: .usageSettingsChanged, object: nil)
        }
    }

    /// Turn the title/bars red when a window's *remaining* capacity drops
    /// below this percentage (stored in remaining terms in both modes).
    @Published var warnBelowRemaining: Double {
        didSet {
            UserDefaults.standard.set(warnBelowRemaining, forKey: Keys.warnBelowRemaining)
            NotificationCenter.default.post(name: .usageSettingsChanged, object: nil)
        }
    }

    /// Which Claude windows are shown at all — both in the menu-bar title
    /// and as rows in the dropdown.
    @Published var showFiveHourInMenuBar: Bool {
        didSet {
            UserDefaults.standard.set(showFiveHourInMenuBar, forKey: Keys.showFiveHourInMenuBar)
            NotificationCenter.default.post(name: .usageSettingsChanged, object: nil)
        }
    }

    @Published var showWeeklyInMenuBar: Bool {
        didSet {
            UserDefaults.standard.set(showWeeklyInMenuBar, forKey: Keys.showWeeklyInMenuBar)
            NotificationCenter.default.post(name: .usageSettingsChanged, object: nil)
        }
    }

    /// Exchange rate for the estimated-cost rows (THB per 1 USD). Kept as
    /// the effective/displayed rate whether it came from a live fetch or a
    /// manual override, and as the offline fallback when a fetch fails.
    @Published var thbPerUSD: Double {
        didSet {
            UserDefaults.standard.set(thbPerUSD, forKey: Keys.thbPerUSD)
            NotificationCenter.default.post(name: .usageSettingsChanged, object: nil)
        }
    }

    /// When true, `thbPerUSD` is kept in sync with a live fetched rate
    /// (see ExchangeRate.swift) instead of the manually-typed value.
    @Published var thbAutoFetch: Bool {
        didSet {
            UserDefaults.standard.set(thbAutoFetch, forKey: Keys.thbAutoFetch)
            NotificationCenter.default.post(name: .usageSettingsChanged, object: nil)
        }
    }

    /// When the live rate was last successfully fetched; nil if never (or
    /// always manual). Purely informational, so it doesn't trigger a re-render.
    @Published var thbLastFetched: Date? {
        didSet {
            if let thbLastFetched {
                UserDefaults.standard.set(thbLastFetched, forKey: Keys.thbLastFetched)
            } else {
                UserDefaults.standard.removeObject(forKey: Keys.thbLastFetched)
            }
        }
    }

    /// Left-to-right order of provider segments in the status bar, and
    /// top-to-bottom order of sections in the dropdown. User-reorderable in
    /// Settings › Providers.
    @Published var providerOrder: [ProviderKind] {
        didSet {
            UserDefaults.standard.set(providerOrder.map(\.rawValue), forKey: Keys.providerOrder)
            NotificationCenter.default.post(name: .usageSettingsChanged, object: nil)
        }
    }

    func moveProvider(fromOffsets: IndexSet, toOffset: Int) {
        providerOrder.move(fromOffsets: fromOffsets, toOffset: toOffset)
    }

    /// Menu-bar style per provider. The existing `limitStyle` value remains
    /// the migration/default style for installs created before per-provider
    /// styles existed.
    @Published var providerLimitStyles: [ProviderKind: LimitStyle] {
        didSet {
            UserDefaults.standard.set(
                Dictionary(uniqueKeysWithValues: providerLimitStyles.map { ($0.key.rawValue, $0.value.rawValue) }),
                forKey: Keys.providerLimitStyles)
            NotificationCenter.default.post(name: .usageSettingsChanged, object: nil)
        }
    }

    func limitStyle(for kind: ProviderKind) -> LimitStyle {
        providerLimitStyles[kind] ?? limitStyle
    }

    func setLimitStyle(_ style: LimitStyle, for kind: ProviderKind) {
        providerLimitStyles[kind] = style
    }

    /// Limit windows shown for each provider in both the menu bar and its
    /// popover pane. The old Claude-only switches are migrated below.
    @Published var providerVisibleWindows: [ProviderKind: Set<LimitWindowKind>] {
        didSet {
            let raw = Dictionary(uniqueKeysWithValues: providerVisibleWindows.map {
                ($0.key.rawValue, $0.value.map(\.rawValue))
            })
            UserDefaults.standard.set(raw, forKey: Keys.providerVisibleWindows)
            NotificationCenter.default.post(name: .usageSettingsChanged, object: nil)
        }
    }

    func isLimitWindowShown(_ window: LimitWindowKind, for kind: ProviderKind) -> Bool {
        providerVisibleWindows[kind]?.contains(window) ?? true
    }

    func setLimitWindowShown(_ window: LimitWindowKind, for kind: ProviderKind, _ shown: Bool) {
        var windows = providerVisibleWindows[kind] ?? Set(LimitWindowKind.allCases)
        if shown { windows.insert(window) } else { windows.remove(window) }
        providerVisibleWindows[kind] = windows
    }

    /// Providers excluded from the compact status-bar title, independent of
    /// `providerOrder` (which still governs their order everywhere they do
    /// appear, including the popover's sidebar — this only hides the
    /// menu-bar segment).
    @Published var menuBarHiddenProviders: Set<ProviderKind> {
        didSet {
            UserDefaults.standard.set(menuBarHiddenProviders.map(\.rawValue), forKey: Keys.menuBarHiddenProviders)
            NotificationCenter.default.post(name: .usageSettingsChanged, object: nil)
        }
    }

    func isShownInMenuBar(_ kind: ProviderKind) -> Bool { !menuBarHiddenProviders.contains(kind) }

    func setShownInMenuBar(_ kind: ProviderKind, _ shown: Bool) {
        var hidden = menuBarHiddenProviders
        if shown { hidden.remove(kind) } else { hidden.insert(kind) }
        menuBarHiddenProviders = hidden
    }

    /// Providers can remain in the menu bar while being hidden from the
    /// popover sidebar, or vice versa.
    @Published var popoverHiddenProviders: Set<ProviderKind> {
        didSet {
            UserDefaults.standard.set(popoverHiddenProviders.map(\.rawValue), forKey: Keys.popoverHiddenProviders)
            NotificationCenter.default.post(name: .usageSettingsChanged, object: nil)
        }
    }

    func isShownInPopover(_ kind: ProviderKind) -> Bool { !popoverHiddenProviders.contains(kind) }

    func setShownInPopover(_ kind: ProviderKind, _ shown: Bool) {
        var hidden = popoverHiddenProviders
        if shown { hidden.remove(kind) } else { hidden.insert(kind) }
        popoverHiddenProviders = hidden
    }

    /// Detail rows are independently configurable per provider. The global
    /// switches below remain master switches for backward compatibility.
    @Published var providerDetails: [ProviderKind: Set<ProviderDetailKind>] {
        didSet {
            let raw = Dictionary(uniqueKeysWithValues: providerDetails.map {
                ($0.key.rawValue, $0.value.map(\.rawValue))
            })
            UserDefaults.standard.set(raw, forKey: Keys.providerDetails)
            NotificationCenter.default.post(name: .usageSettingsChanged, object: nil)
        }
    }

    func showsDetail(_ detail: ProviderDetailKind, for kind: ProviderKind) -> Bool {
        guard globalDetailEnabled(detail) else { return false }
        return providerDetails[kind]?.contains(detail) ?? true
    }

    func setDetailShown(_ detail: ProviderDetailKind, for kind: ProviderKind, _ shown: Bool) {
        var details = providerDetails[kind] ?? Set(kind.supportedDetails)
        if shown { details.insert(detail) } else { details.remove(detail) }
        providerDetails[kind] = details
    }

    private func globalDetailEnabled(_ detail: ProviderDetailKind) -> Bool {
        switch detail {
        case .tokenBreakdown: return true
        case .cacheHitRate: return showCacheHitRate
        case .modelBreakdown: return showModelBreakdown
        case .averagePerSession: return showAvgPerSession
        case .periodCost: return showPeriodCost
        case .skillsUsed: return showSkillsUsed
        case .sessionActivity: return showSessionActivity
        }
    }

    /// Migration/default style for installs created before styles became
    /// configurable per provider. New changes should use `providerLimitStyles`.
    @Published var limitStyle: LimitStyle {
        didSet {
            UserDefaults.standard.set(limitStyle.rawValue, forKey: Keys.limitStyle)
            NotificationCenter.default.post(name: .usageSettingsChanged, object: nil)
        }
    }

    // MARK: - Budget alert
    // Warns (menu bar + a popover banner) once estimated spend crosses 80%
    // of this amount for the selected rolling period.

    @Published var budgetEnabled: Bool {
        didSet {
            UserDefaults.standard.set(budgetEnabled, forKey: Keys.budgetEnabled)
            NotificationCenter.default.post(name: .usageSettingsChanged, object: nil)
        }
    }

    @Published var budgetAmountUSD: Double {
        didSet {
            UserDefaults.standard.set(budgetAmountUSD, forKey: Keys.budgetAmountUSD)
            NotificationCenter.default.post(name: .usageSettingsChanged, object: nil)
        }
    }

    @Published var budgetPeriod: BudgetPeriod {
        didSet {
            UserDefaults.standard.set(budgetPeriod.rawValue, forKey: Keys.budgetPeriod)
            NotificationCenter.default.post(name: .usageSettingsChanged, object: nil)
        }
    }

    /// Native notification when a limit window drops below the warn
    /// threshold or the budget alert goes over — still gated by the system
    /// notification permission regardless of this being on.
    @Published var notificationsEnabled: Bool {
        didSet {
            UserDefaults.standard.set(notificationsEnabled, forKey: Keys.notificationsEnabled)
            NotificationCenter.default.post(name: .usageSettingsChanged, object: nil)
        }
    }

    // MARK: - Session privacy and alerts

    @Published var showSessionIdentifiers: Bool {
        didSet {
            UserDefaults.standard.set(showSessionIdentifiers, forKey: Keys.showSessionIdentifiers)
            NotificationCenter.default.post(name: .usageSettingsChanged, object: nil)
        }
    }

    @Published var showSessionWorkspace: Bool {
        didSet {
            UserDefaults.standard.set(showSessionWorkspace, forKey: Keys.showSessionWorkspace)
            NotificationCenter.default.post(name: .usageSettingsChanged, object: nil)
        }
    }

    @Published var sessionAlertEnabled: Bool {
        didSet {
            UserDefaults.standard.set(sessionAlertEnabled, forKey: Keys.sessionAlertEnabled)
            NotificationCenter.default.post(name: .usageSettingsChanged, object: nil)
        }
    }

    @Published var sessionAlertThreshold: Double {
        didSet {
            UserDefaults.standard.set(sessionAlertThreshold, forKey: Keys.sessionAlertThreshold)
            NotificationCenter.default.post(name: .usageSettingsChanged, object: nil)
        }
    }

    // MARK: - Optional dropdown rows
    // The core rows (limit windows, today's tokens, Est. cost) always show;
    // these extras can be hidden individually to cut clutter.

    @Published var showCacheHitRate: Bool {
        didSet {
            UserDefaults.standard.set(showCacheHitRate, forKey: Keys.showCacheHitRate)
            NotificationCenter.default.post(name: .usageSettingsChanged, object: nil)
        }
    }

    @Published var showModelBreakdown: Bool {
        didSet {
            UserDefaults.standard.set(showModelBreakdown, forKey: Keys.showModelBreakdown)
            NotificationCenter.default.post(name: .usageSettingsChanged, object: nil)
        }
    }

    @Published var showAvgPerSession: Bool {
        didSet {
            UserDefaults.standard.set(showAvgPerSession, forKey: Keys.showAvgPerSession)
            NotificationCenter.default.post(name: .usageSettingsChanged, object: nil)
        }
    }

    @Published var showPeriodCost: Bool {
        didSet {
            UserDefaults.standard.set(showPeriodCost, forKey: Keys.showPeriodCost)
            NotificationCenter.default.post(name: .usageSettingsChanged, object: nil)
        }
    }

    /// Claude Code `Skill` invocation counts for today (see `ClaudeUsage.skillCounts`).
    @Published var showSkillsUsed: Bool {
        didSet {
            UserDefaults.standard.set(showSkillsUsed, forKey: Keys.showSkillsUsed)
            NotificationCenter.default.post(name: .usageSettingsChanged, object: nil)
        }
    }

    /// Per-session skill/tool summaries parsed from local provider logs.
    @Published var showSessionActivity: Bool {
        didSet {
            UserDefaults.standard.set(showSessionActivity, forKey: Keys.showSessionActivity)
            NotificationCenter.default.post(name: .usageSettingsChanged, object: nil)
        }
    }

    /// The app shipped under `com.perth.aiusagebar` up to 0.9.0. macOS ended
    /// up holding state against that identifier which stopped it from ever
    /// being granted a menu bar slot — the app ran but its icon never
    /// appeared, and nothing user-writable (preferences, Control Center,
    /// Launch Services) could clear it. The bundle identifier changed to
    /// break out of that state, which also moves the preferences domain, so
    /// settings are carried over once on first launch under the new one.
    private static let legacyDomain = "com.perth.aiusagebar"
    private static let migrationFlag = "migratedFromLegacyBundleDomain"

    private static func migrateLegacyDomainIfNeeded() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: migrationFlag) else { return }
        defer { d.set(true, forKey: migrationFlag) }
        guard Bundle.main.bundleIdentifier != legacyDomain,
              let legacy = d.persistentDomain(forName: legacyDomain), !legacy.isEmpty
        else { return }
        for (key, value) in legacy where d.object(forKey: key) == nil {
            d.set(value, forKey: key)
        }
    }

    private init() {
        Self.migrateLegacyDomainIfNeeded()
        let d = UserDefaults.standard
        displayMode = UsageDisplayMode(rawValue: d.string(forKey: Keys.displayMode) ?? "") ?? .remaining
        let stored = d.double(forKey: Keys.warnBelowRemaining)
        warnBelowRemaining = stored > 0 ? stored : 20
        let legacyShowFiveHour = d.object(forKey: Keys.showFiveHourInMenuBar) as? Bool ?? true
        let legacyShowWeekly = d.object(forKey: Keys.showWeeklyInMenuBar) as? Bool ?? true
        showFiveHourInMenuBar = legacyShowFiveHour
        showWeeklyInMenuBar = legacyShowWeekly
        let rate = d.double(forKey: Keys.thbPerUSD)
        thbPerUSD = rate > 0 ? rate : 33
        thbAutoFetch = d.object(forKey: Keys.thbAutoFetch) as? Bool ?? true
        thbLastFetched = d.object(forKey: Keys.thbLastFetched) as? Date

        let storedOrder = (d.array(forKey: Keys.providerOrder) as? [String])?.compactMap(ProviderKind.init(rawValue:)) ?? []
        var order = storedOrder
        for kind in ProviderKind.allCases where !order.contains(kind) { order.append(kind) }
        providerOrder = order

        let legacyShowCacheHitRate = d.object(forKey: Keys.showCacheHitRate) as? Bool ?? true
        let legacyShowModelBreakdown = d.object(forKey: Keys.showModelBreakdown) as? Bool ?? true
        let legacyShowAvgPerSession = d.object(forKey: Keys.showAvgPerSession) as? Bool ?? true
        let legacyShowPeriodCost = d.object(forKey: Keys.showPeriodCost) as? Bool ?? true
        let legacyShowSkillsUsed = d.object(forKey: Keys.showSkillsUsed) as? Bool ?? true
        let legacyShowSessionActivity = d.object(forKey: Keys.showSessionActivity) as? Bool ?? true
        showCacheHitRate = legacyShowCacheHitRate
        showModelBreakdown = legacyShowModelBreakdown
        showAvgPerSession = legacyShowAvgPerSession
        showPeriodCost = legacyShowPeriodCost
        showSkillsUsed = legacyShowSkillsUsed
        showSessionActivity = legacyShowSessionActivity

        let hiddenRaw = (d.array(forKey: Keys.menuBarHiddenProviders) as? [String]) ?? []
        menuBarHiddenProviders = Set(hiddenRaw.compactMap(ProviderKind.init(rawValue:)))

        let legacyStyle = LimitStyle(rawValue: d.string(forKey: Keys.limitStyle) ?? "") ?? .bar
        limitStyle = legacyStyle
        let styleRaw = d.dictionary(forKey: Keys.providerLimitStyles) as? [String: String] ?? [:]
        var styles: [ProviderKind: LimitStyle] = [:]
        for kind in ProviderKind.allCases {
            styles[kind] = LimitStyle(rawValue: styleRaw[kind.rawValue] ?? "") ?? legacyStyle
        }
        providerLimitStyles = styles

        let visibleRaw = d.dictionary(forKey: Keys.providerVisibleWindows) as? [String: [String]] ?? [:]
        var visibleWindows: [ProviderKind: Set<LimitWindowKind>] = [:]
        for kind in ProviderKind.allCases {
            if let raw = visibleRaw[kind.rawValue] {
                visibleWindows[kind] = Set(raw.compactMap(LimitWindowKind.init(rawValue:)))
            } else if kind == .claude {
                var migrated = Set<LimitWindowKind>()
                if legacyShowFiveHour { migrated.insert(.fiveHour) }
                if legacyShowWeekly { migrated.insert(.weekly) }
                visibleWindows[kind] = migrated
            } else {
                visibleWindows[kind] = Set(LimitWindowKind.allCases)
            }
        }
        providerVisibleWindows = visibleWindows

        let popoverHiddenRaw = (d.array(forKey: Keys.popoverHiddenProviders) as? [String]) ?? []
        popoverHiddenProviders = Set(popoverHiddenRaw.compactMap(ProviderKind.init(rawValue:)))

        let detailsRaw = d.dictionary(forKey: Keys.providerDetails) as? [String: [String]] ?? [:]
        var detailsByProvider: [ProviderKind: Set<ProviderDetailKind>] = [:]
        for kind in ProviderKind.allCases {
            if let raw = detailsRaw[kind.rawValue] {
                detailsByProvider[kind] = Set(raw.compactMap(ProviderDetailKind.init(rawValue:)))
            } else {
                var defaults = Set(kind.supportedDetails)
                if !legacyShowCacheHitRate { defaults.remove(.cacheHitRate) }
                if !legacyShowModelBreakdown { defaults.remove(.modelBreakdown) }
                if !legacyShowAvgPerSession { defaults.remove(.averagePerSession) }
                if !legacyShowPeriodCost { defaults.remove(.periodCost) }
                if !legacyShowSkillsUsed { defaults.remove(.skillsUsed) }
                if !legacyShowSessionActivity { defaults.remove(.sessionActivity) }
                detailsByProvider[kind] = defaults
            }
        }
        providerDetails = detailsByProvider

        budgetEnabled = d.object(forKey: Keys.budgetEnabled) as? Bool ?? false
        let storedBudget = d.double(forKey: Keys.budgetAmountUSD)
        budgetAmountUSD = storedBudget > 0 ? storedBudget : 10
        budgetPeriod = BudgetPeriod(rawValue: d.string(forKey: Keys.budgetPeriod) ?? "") ?? .day

        notificationsEnabled = d.object(forKey: Keys.notificationsEnabled) as? Bool ?? true
        showSessionIdentifiers = d.object(forKey: Keys.showSessionIdentifiers) as? Bool ?? true
        showSessionWorkspace = d.object(forKey: Keys.showSessionWorkspace) as? Bool ?? true
        sessionAlertEnabled = d.object(forKey: Keys.sessionAlertEnabled) as? Bool ?? false
        let storedSessionThreshold = d.double(forKey: Keys.sessionAlertThreshold)
        sessionAlertThreshold = storedSessionThreshold > 0 ? storedSessionThreshold : 5_000_000
    }
}
