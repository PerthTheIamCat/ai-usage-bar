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
        /// Only the Desktop app keeps a history, so only it can be
        /// calibrated against earlier samples. Oldest first, newest last.
        var recentSamples: [(at: Date, fiveHourUsed: Double)] = []
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
        // The Desktop app only samples every few minutes, so between samples
        // the five-hour figure sits still while usage keeps climbing. Project
        // it forward from tokens actually logged since the sample; the weekly
        // window moves far too slowly for this to be worth doing.
        if let measured = limits.fiveHour,
           let projected = projectedFiveHour(measured, stored: stored) {
            limits.fiveHour = projected
        }

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
            source: .desktopApp,
            recentSamples: recentDesktopSamples(samples))
    }

    /// How many recent samples the projection calibrates against. Each new
    /// reading pushes the oldest one out, so the rate keeps re-fitting to how
    /// this account is actually being consumed rather than staying pinned to
    /// whatever the first measurement happened to be.
    private static let calibrationWindow = 16

    /// The most recent samples, oldest first, newest last.
    private static func recentDesktopSamples(_ samples: [[String: Any]]) -> [(at: Date, fiveHourUsed: Double)] {
        samples.suffix(calibrationWindow).compactMap { sample in
            guard let ms = number(sample["t"]),
                  let usage = sample["u"] as? [String: Any],
                  let fh = number(usage["fh"])
            else { return nil }
            return (Date(timeIntervalSince1970: ms / 1000), fh)
        }
    }

    /// Projects the five-hour window forward from the newest sample using the
    /// tokens logged since it. The rate comes from the user's own previous
    /// interval — how much the percentage moved for the tokens spent in it —
    /// so it adapts to their plan and model mix instead of assuming a formula.
    /// Returns nil whenever there is nothing solid to calibrate against.
    private static func projectedFiveHour(_ measured: LimitWindow, stored: StoredStatusLine) -> LimitWindow? {
        guard stored.source == .desktopApp else { return nil }
        let samples = stored.recentSamples
        guard samples.count >= 2 else { return nil }

        // Fit the rate over every usable interval in the window rather than
        // just the last one. Intervals where the percentage fell are skipped:
        // the five-hour window had rolled over, so the drop says nothing about
        // consumption per token.
        // Token history only reaches back as far as the logs still on disk for
        // today. An interval that starts before that would have its tokens
        // undercounted and would fit an inflated rate, so leave it out.
        guard let coverageStart = UsageReader.claudeTokenEvents().first?.date else { return nil }

        var rates: [Double] = []
        var deltas: [Double] = []
        for (previous, current) in zip(samples, samples.dropFirst()) {
            let percentDelta = current.fiveHourUsed - previous.fiveHourUsed
            guard percentDelta > 0, previous.at < current.at, previous.at >= coverageStart else { continue }
            let tokens = UsageReader.claudeTokens(from: previous.at, to: current.at)
            guard tokens > 0 else { continue }
            rates.append(percentDelta / Double(tokens))
            deltas.append(percentDelta)
        }
        guard let ratePerToken = median(rates), let typicalDelta = median(deltas) else { return nil }

        let sinceTokens = UsageReader.claudeTokens(from: stored.observedAt, to: Date())
        guard sinceTokens > 0 else { return nil }

        // Never project further than a typical interval's movement past the
        // sample — a real reading lands before then anyway, and that bounds
        // how wrong a single odd interval can make this.
        let ceiling = measured.usedPercent + typicalDelta
        let projected = min(measured.usedPercent + ratePerToken * Double(sinceTokens), ceiling)
        guard projected > measured.usedPercent else { return nil }

        var window = measured
        window.usedPercent = min(100, projected)
        window.isEstimated = true
        return window
    }

    /// Median rather than mean: one interval with an unusual mix of models, or
    /// usage from a device this Mac cannot see, would drag an average around.
    private static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? (sorted[middle - 1] + sorted[middle]) / 2
            : sorted[middle]
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
