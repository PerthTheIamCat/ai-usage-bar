import Foundation

struct LimitWindow: Equatable {
    var usedPercent: Double   // 0-100
    var resetsAt: Date?
    /// True when `usedPercent` was projected forward from the last real
    /// reading rather than read from a source. Displayed with a "~" so an
    /// estimate is never mistaken for a measurement, and deliberately not
    /// used to raise limit notifications.
    var isEstimated = false
    var resetDescription: String? = nil

    var remainingPercent: Double { max(0, 100 - usedPercent) }
}

/// A model group in Antigravity (e.g. "Gemini Models", "Claude and GPT models").
struct AntigravityModelGroup: Identifiable, Equatable {
    var id: String { name }
    var name: String
    var description: String?
    var weekly: LimitWindow?
    var fiveHour: LimitWindow?
}

struct ClaudeLimits {
    enum State {
        case ok
        case stale
        case unavailable
        case error(String)
    }
    /// Which local snapshot the reading came from — the Claude Code CLI's
    /// statusLine bridge, or the Claude Desktop app's own local usage file.
    enum Source {
        case statusLineBridge
        case desktopApp
    }
    var state: State = .error("unknown")
    var fiveHour: LimitWindow?
    var sevenDay: LimitWindow?
    var fetchedAt: Date?
    var source: Source?
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

/// The wall-clock time of a reset: "13:02" within the next day, otherwise
/// with the weekday ("Sun 13:02") so a weekly reset isn't ambiguous.
func resetClock(_ date: Date, now: Date = Date()) -> String {
    let time = date.formatted(date: .omitted, time: .shortened)
    if date.timeIntervalSince(now) < 20 * 3600, Calendar.current.isDate(date, inSameDayAs: now) { return time }
    return date.formatted(.dateTime.weekday(.abbreviated)) + " " + time
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
