import Foundation
import Combine

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

/// UserDefaults-backed app settings, observable from SwiftUI.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private enum Keys {
        static let displayMode = "displayMode"
        static let warnBelowRemaining = "warnBelowRemaining"
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

    private init() {
        let d = UserDefaults.standard
        displayMode = UsageDisplayMode(rawValue: d.string(forKey: Keys.displayMode) ?? "") ?? .remaining
        let stored = d.double(forKey: Keys.warnBelowRemaining)
        warnBelowRemaining = stored > 0 ? stored : 20
    }
}
