import Foundation

/// A single usage window (5-hour session or 7-day weekly).
struct LimitWindow {
    var usedPercent: Double   // 0-100
    var resetsAt: Date?

    var remainingPercent: Double { max(0, 100 - usedPercent) }
}

struct ClaudeLimits {
    enum State { case ok, stale, notLoggedIn, rateLimited(retryAfter: TimeInterval?), error(String) }
    var state: State = .error("unknown")
    var fiveHour: LimitWindow?
    var sevenDay: LimitWindow?
    var fetchedAt: Date?
}

struct CodexLimits {
    var planType: String?
    var primary: LimitWindow?    // 5-hour
    var secondary: LimitWindow?  // weekly
    var asOf: Date?              // timestamp of the log reading (may be old)
}

func humanReset(_ date: Date?) -> String {
    guard let date else { return "—" }
    let secs = date.timeIntervalSinceNow
    if secs <= 0 { return "now" }
    return humanDuration(secs)
}

/// "3d 17h" / "4h 12m" / "9m" for a positive duration in seconds.
func humanDuration(_ secs: Double) -> String {
    let s = Int(max(0, secs))
    let h = s / 3600, m = (s % 3600) / 60
    if h >= 24 { return "\(h / 24)d \(h % 24)h" }
    if h > 0 { return "\(h)h \(m)m" }
    return "\(m)m"
}

func humanAgo(_ date: Date?) -> String {
    guard let date else { return "unknown" }
    let secs = -date.timeIntervalSinceNow
    if secs < 60 { return "just now" }
    return humanDuration(secs) + " ago"
}
