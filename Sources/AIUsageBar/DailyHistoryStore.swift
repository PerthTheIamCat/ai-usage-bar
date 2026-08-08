import Foundation

/// A local day-by-day rollup that survives source logs being pruned.
///
/// Claude Code (and Codex) delete local session logs after roughly a month,
/// but `dailyTrend`/`periodCosts` compute their numbers by rescanning those
/// logs from scratch every time. Once Claude prunes a day's file, that day
/// silently drops to zero in every chart from then on — even though the app
/// measured it correctly while the file still existed, possibly repeatedly,
/// over the weeks before it aged out. This stores each day's totals the
/// first time they're observed with real activity, so a later rescan that
/// finds nothing still has something to fall back to.
enum DailyHistoryStore {
    struct DayEntry: Codable {
        var claudeTokens = 0
        var claudeCostUSD = 0.0
        var codexTokens = 0
        var codexCostUSD = 0.0
        var antigravityPrompts = 0
        var antigravityCostUSD = 0.0
    }

    static let defaultFileURL: URL = {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AIUsageBar", isDirectory: true)
            .appendingPathComponent("daily-history.json")
    }()

    private static let lock = NSLock()

    /// Local calendar day, matching the local-day buckets `dailyTrend` itself
    /// uses (`Calendar.current.startOfDay`) — a UTC key here would drift a
    /// day off from what's on screen for anyone not on UTC.
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        return f
    }()

    private static func load(_ fileURL: URL) -> [String: DayEntry] {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([String: DayEntry].self, from: data)
        else { return [:] }
        return decoded
    }

    private static func save(_ store: [String: DayEntry], _ fileURL: URL) {
        guard let data = try? JSONEncoder().encode(store) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }

    /// Merges a freshly scanned `DailyTrend` into the store. Only days with
    /// some real activity are written — an all-zero day is indistinguishable
    /// from "not scanned yet" and would just be noise on disk. Today is
    /// included, so it starts accumulating immediately rather than only
    /// being captured once it's already in the past. `fileURL` is only ever
    /// overridden by tests, to keep them off this Mac's real history file.
    static func record(_ trend: DailyTrend, fileURL: URL = defaultFileURL) {
        lock.lock(); defer { lock.unlock() }
        var store = load(fileURL)
        var changed = false
        for i in trend.days.indices {
            let hasActivity = trend.claudeTokens[i] > 0 || trend.codexTokens[i] > 0 || trend.antigravityPrompts[i] > 0
            guard hasActivity else { continue }
            store[dayFormatter.string(from: trend.days[i])] = DayEntry(
                claudeTokens: trend.claudeTokens[i], claudeCostUSD: trend.claudeCostUSD[i],
                codexTokens: trend.codexTokens[i], codexCostUSD: trend.codexCostUSD[i],
                antigravityPrompts: trend.antigravityPrompts[i], antigravityCostUSD: trend.antigravityCostUSD[i])
            changed = true
        }
        // Nothing had any activity — writing out an unchanged (or freshly
        // empty) file on every call would mean a disk write every refresh
        // for a provider that simply isn't in use.
        guard changed else { return }
        save(store, fileURL)
    }

    /// Fills any day in `trend` that the live scan came back all-zero for
    /// with whatever was previously recorded for that day, if anything was.
    /// A day the live scan actually measured — even a genuinely quiet one —
    /// is left untouched; this only backstops days the source no longer has.
    static func backfill(_ trend: DailyTrend, fileURL: URL = defaultFileURL) -> DailyTrend {
        lock.lock()
        let store = load(fileURL)
        lock.unlock()
        guard !store.isEmpty else { return trend }

        var out = trend
        for i in trend.days.indices {
            let hasLiveActivity = trend.claudeTokens[i] > 0 || trend.codexTokens[i] > 0 || trend.antigravityPrompts[i] > 0
            guard !hasLiveActivity, let saved = store[dayFormatter.string(from: trend.days[i])] else { continue }
            out.claudeTokens[i] = saved.claudeTokens
            out.claudeCostUSD[i] = saved.claudeCostUSD
            out.codexTokens[i] = saved.codexTokens
            out.codexCostUSD[i] = saved.codexCostUSD
            out.antigravityPrompts[i] = saved.antigravityPrompts
            out.antigravityCostUSD[i] = saved.antigravityCostUSD
        }
        return out
    }
}
