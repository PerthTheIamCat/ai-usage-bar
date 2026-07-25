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

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .bar: return "Bar"
        case .ring: return "Ring"
        case .percentOnly: return "Percent only"
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
        static let showCacheHitRate = "showCacheHitRate"
        static let showModelBreakdown = "showModelBreakdown"
        static let showAvgPerSession = "showAvgPerSession"
        static let showPeriodCost = "showPeriodCost"
        static let showSkillsUsed = "showSkillsUsed"
        static let menuBarHiddenProviders = "menuBarHiddenProviders"
        static let limitStyle = "limitStyle"
        static let budgetEnabled = "budgetEnabled"
        static let budgetAmountUSD = "budgetAmountUSD"
        static let budgetPeriod = "budgetPeriod"
        static let notificationsEnabled = "notificationsEnabled"
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
        if shown { menuBarHiddenProviders.remove(kind) } else { menuBarHiddenProviders.insert(kind) }
    }

    /// How limit windows are drawn in the menu bar — bar, ring, or plain text.
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

    private init() {
        let d = UserDefaults.standard
        displayMode = UsageDisplayMode(rawValue: d.string(forKey: Keys.displayMode) ?? "") ?? .remaining
        let stored = d.double(forKey: Keys.warnBelowRemaining)
        warnBelowRemaining = stored > 0 ? stored : 20
        showFiveHourInMenuBar = d.object(forKey: Keys.showFiveHourInMenuBar) as? Bool ?? true
        showWeeklyInMenuBar = d.object(forKey: Keys.showWeeklyInMenuBar) as? Bool ?? true
        let rate = d.double(forKey: Keys.thbPerUSD)
        thbPerUSD = rate > 0 ? rate : 33
        thbAutoFetch = d.object(forKey: Keys.thbAutoFetch) as? Bool ?? true
        thbLastFetched = d.object(forKey: Keys.thbLastFetched) as? Date

        let storedOrder = (d.array(forKey: Keys.providerOrder) as? [String])?.compactMap(ProviderKind.init(rawValue:)) ?? []
        var order = storedOrder
        for kind in ProviderKind.allCases where !order.contains(kind) { order.append(kind) }
        providerOrder = order

        showCacheHitRate = d.object(forKey: Keys.showCacheHitRate) as? Bool ?? true
        showModelBreakdown = d.object(forKey: Keys.showModelBreakdown) as? Bool ?? true
        showAvgPerSession = d.object(forKey: Keys.showAvgPerSession) as? Bool ?? true
        showPeriodCost = d.object(forKey: Keys.showPeriodCost) as? Bool ?? true
        showSkillsUsed = d.object(forKey: Keys.showSkillsUsed) as? Bool ?? true

        let hiddenRaw = (d.array(forKey: Keys.menuBarHiddenProviders) as? [String]) ?? []
        menuBarHiddenProviders = Set(hiddenRaw.compactMap(ProviderKind.init(rawValue:)))

        limitStyle = LimitStyle(rawValue: d.string(forKey: Keys.limitStyle) ?? "") ?? .bar

        budgetEnabled = d.object(forKey: Keys.budgetEnabled) as? Bool ?? false
        let storedBudget = d.double(forKey: Keys.budgetAmountUSD)
        budgetAmountUSD = storedBudget > 0 ? storedBudget : 10
        budgetPeriod = BudgetPeriod(rawValue: d.string(forKey: Keys.budgetPeriod) ?? "") ?? .day

        notificationsEnabled = d.object(forKey: Keys.notificationsEnabled) as? Bool ?? true
    }
}
