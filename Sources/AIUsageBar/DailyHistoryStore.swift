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

    /// A trend longer than the live 30-day scan, built from everything the
    /// store has recorded with the live trend laid over it (live data wins
    /// for the days it covers). `days == nil` means "all": from the earliest
    /// recorded day through today. Days with nothing recorded stay zero.
    static func extendedTrend(days: Int?, live: DailyTrend, fileURL: URL = defaultFileURL) -> DailyTrend {
        lock.lock()
        let store = load(fileURL)
        lock.unlock()

        let calendar = Calendar.current
        let todayStart = calendar.startOfDay(for: live.days.last ?? Date())

        var count = days ?? live.days.count
        if days == nil, let earliest = store.keys.min().flatMap({ dayFormatter.date(from: $0) }) {
            let span = calendar.dateComponents([.day], from: calendar.startOfDay(for: earliest), to: todayStart).day ?? 0
            count = max(count, span + 1)
        }
        count = max(count, 1)

        var out = DailyTrend()
        out.days = (0..<count).map { calendar.date(byAdding: .day, value: -(count - 1 - $0), to: todayStart) ?? todayStart }
        out.claudeTokens = Array(repeating: 0, count: count)
        out.claudeCostUSD = Array(repeating: 0, count: count)
        out.codexTokens = Array(repeating: 0, count: count)
        out.codexCostUSD = Array(repeating: 0, count: count)
        out.antigravityPrompts = Array(repeating: 0, count: count)
        out.antigravityCostUSD = Array(repeating: 0, count: count)

        var liveByDay: [String: Int] = [:]
        for (i, day) in live.days.enumerated() { liveByDay[dayFormatter.string(from: day)] = i }

        for i in out.days.indices {
            let key = dayFormatter.string(from: out.days[i])
            if let j = liveByDay[key] {
                let hasLive = live.claudeTokens[j] > 0 || live.codexTokens[j] > 0 || live.antigravityPrompts[j] > 0
                if hasLive {
                    out.claudeTokens[i] = live.claudeTokens[j]
                    out.claudeCostUSD[i] = live.claudeCostUSD[j]
                    out.codexTokens[i] = live.codexTokens[j]
                    out.codexCostUSD[i] = live.codexCostUSD[j]
                    out.antigravityPrompts[i] = live.antigravityPrompts[j]
                    out.antigravityCostUSD[i] = live.antigravityCostUSD[j]
                    continue
                }
            }
            if let saved = store[key] {
                out.claudeTokens[i] = saved.claudeTokens
                out.claudeCostUSD[i] = saved.claudeCostUSD
                out.codexTokens[i] = saved.codexTokens
                out.codexCostUSD[i] = saved.codexCostUSD
                out.antigravityPrompts[i] = saved.antigravityPrompts
                out.antigravityCostUSD[i] = saved.antigravityCostUSD
            }
        }
        return out
    }

    /// One CSV row per recorded day, oldest first, for exporting the full
    /// rollup rather than just the 30-day window the charts show.
    static func generateCSV(fileURL: URL = defaultFileURL) -> String {
        lock.lock()
        let store = load(fileURL)
        lock.unlock()
        var lines = ["date,claude_tokens,claude_cost_usd,codex_tokens,codex_cost_usd,antigravity_prompts,antigravity_cost_usd"]
        for day in store.keys.sorted() {
            guard let e = store[day] else { continue }
            lines.append([
                day,
                String(e.claudeTokens), String(format: "%.6f", e.claudeCostUSD),
                String(e.codexTokens), String(format: "%.6f", e.codexCostUSD),
                String(e.antigravityPrompts), String(format: "%.6f", e.antigravityCostUSD),
            ].joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
