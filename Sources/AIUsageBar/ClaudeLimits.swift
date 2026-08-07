import Foundation

/// Reads the rate-limit snapshot written by Claude Code's local `statusLine`
/// command. AI Usage Bar deliberately does not call Claude's usage endpoint
/// and never reads Claude credentials.
enum ClaudeLimitsReader {
    static let statusLineSnapshotURL: URL = {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AIUsageBar", isDirectory: true)
            .appendingPathComponent("claude-statusline.json")
    }()

    /// The Claude Desktop app (not Claude Code) writes its own local plan-
    /// usage samples here. The statusLine bridge only fires from Claude Code
    /// CLI sessions, so people who only use the Desktop app would otherwise
    /// never see a limits reading — this file is the fallback source.
    static let desktopPlanUsageURL: URL = {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Claude", isDirectory: true)
            .appendingPathComponent("plan-usage-history.json")
    }()

    /// Claude Code updates status-line input after activity. If no activity
    /// has supplied a new snapshot for this long, keep the value visible as
    /// last-known data but mark it stale instead of trying to refresh it.
    private static let staleAfter: TimeInterval = 30 * 60
    private static let logLock = NSLock()
    private static var lastLogSignature: String?

    private struct StoredStatusLine {
        var observedAt: Date
        var rateLimits: [String: Any]
        var source: ClaudeLimits.Source
    }

    static func fetch() -> ClaudeLimits {
        // Prefer whichever local source has the freshest reading — a person
        // may use both the CLI and the Desktop app, and either can go quiet
        // while the other keeps updating.
        let candidates = [readStoredStatusLine(), readDesktopPlanUsage()].compactMap { $0 }
        guard let stored = candidates.max(by: { $0.observedAt < $1.observedAt }) else {
            logStatus(state: "unavailable", observedAt: nil, fiveHour: nil, weekly: nil,
                      message: "claude: no local statusline or Desktop-app snapshot found — configure the Claude Code bridge")
            return ClaudeLimits(state: .unavailable)
        }

        var limits = ClaudeLimits()
        limits.fetchedAt = stored.observedAt
        limits.source = stored.source
        limits.fiveHour = parseWindow(stored.rateLimits["five_hour"])
        limits.sevenDay = parseWindow(stored.rateLimits["seven_day"])

        let sourceLabel = stored.source == .desktopApp ? "Desktop app" : "statusline"
        guard limits.fiveHour != nil || limits.sevenDay != nil else {
            logStatus(state: "unavailable", observedAt: stored.observedAt, fiveHour: nil, weekly: nil,
                      message: "claude: local \(sourceLabel) snapshot has no rate-limit windows")
            limits.state = .unavailable
            return limits
        }

        let age = Date().timeIntervalSince(stored.observedAt)
        limits.state = age > staleAfter ? .stale : .ok
        let message: String
        switch limits.state {
        case .ok:
            message = "claude: local \(sourceLabel) limits — 5h \(pct(limits.fiveHour)) used, weekly \(pct(limits.sevenDay)) used"
        case .stale:
            message = "claude: local \(sourceLabel) limits stale — last update \(humanAgo(stored.observedAt))"
        case .unavailable:
            message = "claude: local \(sourceLabel) snapshot unavailable"
        case .error:
            message = "claude: local \(sourceLabel) limits error"
        }
        logStatus(state: stateLabel(limits.state), observedAt: stored.observedAt,
                  fiveHour: limits.fiveHour, weekly: limits.sevenDay, message: message)
        return limits
    }

    /// Entry point used by the Claude Code status-line command. Store only
    /// rate-limit data, not the rest of Claude Code's session metadata.
    @discardableResult
    static func captureStatusLineInput(_ data: Data) -> String {
        guard let input = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rateLimits = input["rate_limits"] as? [String: Any],
              rateLimits["five_hour"] is [String: Any] || rateLimits["seven_day"] is [String: Any]
        else {
            return "Claude · waiting for limits"
        }

        let record: [String: Any] = [
            "observed_at": Date().timeIntervalSince1970,
            "rate_limits": rateLimits,
        ]
        if let encoded = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) {
            do {
                let directory = statusLineSnapshotURL.deletingLastPathComponent()
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try encoded.write(to: statusLineSnapshotURL, options: .atomic)
            } catch {
                // Keep the status line useful even if the local snapshot cannot
                // be written; the menu-bar app will show the last good file.
            }
        }
        return statusLineText(rateLimits)
    }

    private static func readStoredStatusLine() -> StoredStatusLine? {
        guard let data = try? Data(contentsOf: statusLineSnapshotURL),
              let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let observed = number(record["observed_at"]),
              let rateLimits = record["rate_limits"] as? [String: Any]
        else { return nil }
        return StoredStatusLine(
            observedAt: Date(timeIntervalSince1970: observed),
            rateLimits: rateLimits,
            source: .statusLineBridge)
    }

    /// Claude Desktop periodically appends `{t, org, u: {fh, sd}}` samples to
    /// its own local history file — `fh`/`sd` are the five-hour/seven-day
    /// used percentages, 0-100. No reset time is included, unlike the
    /// statusLine bridge's `rate_limits` payload.
    private static func readDesktopPlanUsage() -> StoredStatusLine? {
        guard let data = try? Data(contentsOf: desktopPlanUsageURL),
              let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let samples = record["samples"] as? [[String: Any]],
              let last = samples.last,
              let ms = number(last["t"]),
              let usage = last["u"] as? [String: Any]
        else { return nil }

        var rateLimits: [String: Any] = [:]
        if let fh = number(usage["fh"]) { rateLimits["five_hour"] = ["used_percentage": fh] }
        if let sd = number(usage["sd"]) { rateLimits["seven_day"] = ["used_percentage": sd] }
        guard !rateLimits.isEmpty else { return nil }

        return StoredStatusLine(
            observedAt: Date(timeIntervalSince1970: ms / 1000),
            rateLimits: rateLimits,
            source: .desktopApp)
    }

    private static func parseWindow(_ raw: Any?) -> LimitWindow? {
        guard let d = raw as? [String: Any],
              let used = number(d["used_percentage"] ?? d["used_percent"])
        else { return nil }
        let reset = number(d["resets_at"]).map(Date.init(timeIntervalSince1970:))
        return LimitWindow(usedPercent: min(100, max(0, used)), resetsAt: reset)
    }

    private static func number(_ raw: Any?) -> Double? {
        (raw as? NSNumber)?.doubleValue
    }

    private static func pct(_ window: LimitWindow?) -> String {
        window.map { "\(Int($0.usedPercent))%" } ?? "n/a"
    }

    private static func stateLabel(_ state: ClaudeLimits.State) -> String {
        switch state {
        case .ok: return "ok"
        case .stale: return "stale"
        case .unavailable: return "unavailable"
        case .error: return "error"
        }
    }

    private static func logStatus(
        state: String,
        observedAt: Date?,
        fiveHour: LimitWindow?,
        weekly: LimitWindow?,
        message: String
    ) {
        let signature = "\(state)|\(observedAt?.timeIntervalSince1970 ?? -1)|\(fiveHour?.usedPercent ?? -1)|\(weekly?.usedPercent ?? -1)|\(fiveHour?.resetsAt?.timeIntervalSince1970 ?? -1)|\(weekly?.resetsAt?.timeIntervalSince1970 ?? -1)"
        logLock.lock()
        let changed = signature != lastLogSignature
        if changed { lastLogSignature = signature }
        logLock.unlock()
        if changed { appLog(message) }
    }

    private static func statusLineText(_ rateLimits: [String: Any]) -> String {
        var parts = ["Claude"]
        if let window = parseWindow(rateLimits["five_hour"]) {
            parts.append("5h \(Int(window.usedPercent))%")
        }
        if let window = parseWindow(rateLimits["seven_day"]) {
            parts.append("7d \(Int(window.usedPercent))%")
        }
        return parts.joined(separator: " · ")
    }
}
