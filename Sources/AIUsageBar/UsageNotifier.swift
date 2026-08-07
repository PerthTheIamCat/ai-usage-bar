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
        let center = UNUserNotificationCenter.current()
        // macOS keeps the user's notification decision. Read it first so a
        // denied app does not call requestAuthorization on every launch and
        // fill the diagnostic log with the same permission error.
        center.getNotificationSettings { [weak self] settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional:
                self?.setAuthorized(true)
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
                    self?.setAuthorized(granted)
                    if let error {
                        appLog("notifications: authorization request failed — \(error.localizedDescription)")
                    }
                }
            case .denied:
                self?.setAuthorized(false)
                appLog("notifications: permission denied by macOS — enable it in System Settings")
            @unknown default:
                self?.setAuthorized(false)
            }
        }
    }

    private func setAuthorized(_ value: Bool) {
        DispatchQueue.main.async { [weak self] in
            self?.authorized = value
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
        checkLargeSession(provider: "Claude", sessions: snap.claude?.sessions ?? [])
        checkLargeSession(provider: "Codex", sessions: snap.codex?.sessions ?? [])
        checkBudget(snap)
    }

    private func checkLargeSession(provider: String, sessions: [SessionActivity]) {
        let settings = AppSettings.shared
        guard settings.sessionAlertEnabled, settings.sessionAlertThreshold > 0,
              let largest = sessions.max(by: { $0.tokenTotal < $1.tokenTotal })
        else { return }
        let key = "large-session-\(provider.lowercased())-\(largest.id)"
        let isLarge = Double(largest.tokenTotal) >= settings.sessionAlertThreshold
        if isLarge, !firedKeys.contains(key) {
            firedKeys.insert(key)
            notify(
                id: key,
                title: "Large \(provider) session",
                body: "\(formatTokens(largest.tokenTotal)) tokens · estimated \(formatUSD(largest.estimatedCostUSD))")
        } else if !isLarge {
            firedKeys.remove(key)
        }
    }

    private func checkWindow(key: String, name: String, window: LimitWindow?, warnBelow: Double) {
        // A window with no reset time is still a valid reading — the Claude
        // Desktop snapshot never carries one. Only a reset that has already
        // passed means the percentage is stale and not worth alerting on.
        // Never alert on a projected figure — an estimate that overshoots
        // would fire a warning the real reading then contradicts.
        guard let window, !window.isEstimated else { return }
        if let resetsAt = window.resetsAt, resetsAt <= Date() { return }
        let low = window.remainingPercent < warnBelow
        if low, !firedKeys.contains(key) {
            firedKeys.insert(key)
            let resetNote = window.resetsAt.map { " · resets in \(humanReset($0))" } ?? ""
            notify(id: key, title: "\(name) running low",
                   body: "\(Int(window.remainingPercent.rounded()))% remaining\(resetNote)")
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
