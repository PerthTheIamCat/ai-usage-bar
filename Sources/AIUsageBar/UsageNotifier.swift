import Foundation
import UserNotifications

/// Fires a native notification once per threshold crossing — not repeatedly
/// on every refresh tick while a window stays low — for limit windows
/// dropping below the warn threshold and the budget alert going over.
/// Matches the app's existing "only interrupt for something that needs
/// attention" philosophy (see the ⚠︎ status notes, which are similarly
/// state-driven rather than routine).
final class UsageNotifier {
    static let shared = UsageNotifier()

    private var authorized = false
    /// Crossing keys already notified this launch; a window clearing back
    /// above threshold removes its key so a later re-crossing can notify again.
    private var firedKeys = Set<String>()

    private init() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
            self?.authorized = granted
            if let error { appLog("notifications: authorization request failed — \(error.localizedDescription)") }
        }
    }

    func check(_ snap: UsageSnapshot) {
        guard AppSettings.shared.notificationsEnabled else { return }
        let warnBelow = AppSettings.shared.warnBelowRemaining
        checkWindow(key: "claude-5h", name: "Claude 5-hour window", window: snap.claudeLimits?.fiveHour, warnBelow: warnBelow)
        checkWindow(key: "claude-week", name: "Claude weekly window", window: snap.claudeLimits?.sevenDay, warnBelow: warnBelow)
        checkWindow(key: "codex-week", name: "Codex weekly window", window: snap.codexLimits?.secondary, warnBelow: warnBelow)
        checkWindow(key: "antigravity-5h", name: "Antigravity 5-hour window", window: snap.antigravity?.fiveHour, warnBelow: warnBelow)
        checkWindow(key: "antigravity-week", name: "Antigravity weekly window", window: snap.antigravity?.weekly, warnBelow: warnBelow)
        checkBudget(snap)
    }

    private func checkWindow(key: String, name: String, window: LimitWindow?, warnBelow: Double) {
        guard let window, let resetsAt = window.resetsAt, resetsAt > Date() else { return }
        let low = window.remainingPercent < warnBelow
        if low, !firedKeys.contains(key) {
            firedKeys.insert(key)
            notify(id: key, title: "\(name) running low",
                   body: "\(Int(window.remainingPercent.rounded()))% remaining · resets in \(humanReset(resetsAt))")
        } else if !low {
            firedKeys.remove(key)
        }
    }

    private func checkBudget(_ snap: UsageSnapshot) {
        let s = AppSettings.shared
        guard s.budgetEnabled, s.budgetAmountUSD > 0 else {
            firedKeys.remove("budget")
            return
        }
        let spend: Double
        switch s.budgetPeriod {
        case .day:
            spend = (snap.claude.map(Pricing.claudeCostUSD) ?? 0)
                + (snap.codex.map(Pricing.codexCostUSD) ?? 0)
                + (snap.antigravity.map(Pricing.antigravityCostUSD) ?? 0)
        case .month:
            guard let pc = snap.periodCosts else { return }
            spend = (pc.claudeUSD30 ?? 0) + (pc.codexUSD30 ?? 0) + (pc.antigravityUSD30 ?? 0)
        }
        let over = spend >= s.budgetAmountUSD
        if over, !firedKeys.contains("budget") {
            firedKeys.insert("budget")
            notify(id: "budget", title: "Over budget",
                   body: "\(formatUSD(spend)) of \(formatUSD(s.budgetAmountUSD)) (\(s.budgetPeriod.displayName.lowercased()))")
        } else if !over {
            firedKeys.remove("budget")
        }
    }

    private func notify(id: String, title: String, body: String) {
        guard authorized else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
        appLog("notifications: sent \"\(title)\"")
    }
}
