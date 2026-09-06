import Foundation

/// Captures Antigravity CLI's documented status-line payload. The CLI already
/// has an authenticated connection to the quota service, so AI Usage Bar does
/// not need to read credentials or call the private quota endpoint itself.
enum AntigravityLimitsReader {
    static let statusLineSnapshotURL: URL = {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AIUsageBar", isDirectory: true)
            .appendingPathComponent("antigravity-statusline.json")
    }()

    private static let staleAfter: TimeInterval = 30 * 60

    struct Snapshot: Equatable {
        var fiveHour: LimitWindow?
        var weekly: LimitWindow?
        var observedAt: Date

        static func == (lhs: Snapshot, rhs: Snapshot) -> Bool {
            lhs.observedAt == rhs.observedAt
                && lhs.fiveHour?.usedPercent == rhs.fiveHour?.usedPercent
                && lhs.fiveHour?.resetsAt == rhs.fiveHour?.resetsAt
                && lhs.weekly?.usedPercent == rhs.weekly?.usedPercent
                && lhs.weekly?.resetsAt == rhs.weekly?.resetsAt
        }
    }

    /// Parses the documented `quota` object. Kept separate from disk I/O so
    /// the bucket naming and snake_case fields have a deterministic test seam.
    static func parseStatusLinePayload(_ data: Data, observedAt: Date = Date()) -> Snapshot? {
        guard let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let quota = payload["quota"] as? [String: Any]
        else { return nil }
        return parseQuota(quota, observedAt: observedAt)
    }

    /// Entry point used by the Antigravity CLI status-line command. Persist
    /// only derived percentages and reset timestamps, never session metadata.
    @discardableResult
    static func captureStatusLineInput(_ data: Data) -> String {
        guard let snapshot = parseStatusLinePayload(data) else {
            return "Antigravity · waiting for quota"
        }

        var record: [String: Any] = [
            "observed_at": snapshot.observedAt.timeIntervalSince1970,
        ]
        if let fiveHour = snapshot.fiveHour {
            record["five_hour_used"] = fiveHour.usedPercent
            if let reset = fiveHour.resetsAt {
                record["five_hour_reset"] = reset.timeIntervalSince1970
            }
        }
        if let weekly = snapshot.weekly {
            record["weekly_used"] = weekly.usedPercent
            if let reset = weekly.resetsAt {
                record["weekly_reset"] = reset.timeIntervalSince1970
            }
        }
        if let encoded = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) {
            do {
                let directory = statusLineSnapshotURL.deletingLastPathComponent()
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try encoded.write(to: statusLineSnapshotURL, options: .atomic)
            } catch {
                // Keep Antigravity's own status line useful if the app cannot
                // write its optional local cache.
            }
        }
        return statusLineText(snapshot)
    }

    static func fetch() -> Snapshot? {
        guard let data = try? Data(contentsOf: statusLineSnapshotURL),
              let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let observed = number(record["observed_at"])
        else { return nil }

        let snapshot = Snapshot(
            fiveHour: window(used: number(record["five_hour_used"]), reset: number(record["five_hour_reset"])),
            weekly: window(used: number(record["weekly_used"]), reset: number(record["weekly_reset"])),
            observedAt: Date(timeIntervalSince1970: observed))
        guard snapshot.fiveHour != nil || snapshot.weekly != nil else { return nil }
        return snapshot
    }

    static func isStale(_ snapshot: Snapshot, now: Date = Date()) -> Bool {
        now.timeIntervalSince(snapshot.observedAt) > staleAfter
    }

    private static func parseQuota(_ quota: [String: Any], observedAt: Date) -> Snapshot? {
        var fiveHourCandidates: [LimitWindow] = []
        var weeklyCandidates: [LimitWindow] = []
        for (key, raw) in quota {
            guard let bucket = raw as? [String: Any],
                  let remaining = number(bucket["remaining_fraction"]),
                  (0...1).contains(remaining)
            else { continue }

            let reset: Date?
            if let resetString = bucket["reset_time"] as? String {
                reset = UsageReader.parseISO(resetString) ?? ISO8601DateFormatter().date(from: resetString)
            } else if let seconds = number(bucket["reset_in_seconds"]) {
                reset = observedAt.addingTimeInterval(seconds)
            } else {
                reset = nil
            }
            let window = LimitWindow(
                usedPercent: (1 - remaining) * 100,
                resetsAt: reset)
            let normalized = key.lowercased()
            if normalized.contains("week") || normalized.contains("7d") {
                weeklyCandidates.append(window)
            } else if normalized.contains("5h") || normalized.contains("session") || normalized.contains("short") {
                fiveHourCandidates.append(window)
            } else if let reset, reset.timeIntervalSince(observedAt) > 0,
                      reset.timeIntervalSince(observedAt) <= 12 * 3600 {
                fiveHourCandidates.append(window)
            } else {
                weeklyCandidates.append(window)
            }
        }

        let fiveHour = fiveHourCandidates.min { $0.usedPercent < $1.usedPercent }
        let weekly = weeklyCandidates.min { $0.usedPercent < $1.usedPercent }
        guard fiveHour != nil || weekly != nil else { return nil }
        return Snapshot(fiveHour: fiveHour, weekly: weekly, observedAt: observedAt)
    }

    private static func window(used: Double?, reset: Double?) -> LimitWindow? {
        guard let used, used.isFinite else { return nil }
        return LimitWindow(
            usedPercent: max(0, min(100, used)),
            resetsAt: reset.map(Date.init(timeIntervalSince1970:)))
    }

    private static func number(_ raw: Any?) -> Double? {
        if let value = raw as? Double { return value }
        if let value = raw as? Int { return Double(value) }
        if let value = raw as? NSNumber { return value.doubleValue }
        return nil
    }

    private static func statusLineText(_ snapshot: Snapshot) -> String {
        let values = [
            snapshot.fiveHour.map { "5h \(Int($0.remainingPercent))% left" },
            snapshot.weekly.map { "W \(Int($0.remainingPercent))% left" },
        ].compactMap { $0 }
        return values.isEmpty ? "Antigravity · waiting for quota" : "AI Usage Bar · " + values.joined(separator: " · ")
    }
}
