import Foundation

enum UsageReader {
    static let claudeDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/projects")
    static let codexDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".codex/sessions")
    static let antigravityDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".gemini/antigravity-cli")

    private static let codexLogLock = NSLock()
    private static var lastCodexLogSignature: String?
    // The old fingerprint-keyed result caches are gone: a fingerprint changes
    // the moment a session log is appended to, which during an actual coding
    // session is every tick — exactly when the cache needed to hold. The
    // per-file incremental parse caches below replace them and keep working
    // while a file grows.
    private static let codexLimitsCacheLock = NSLock()
    private static var codexLimitsCache: (fingerprint: String, value: CodexLimits?)?
    private static let trendCacheLock = NSLock()
    private static var dailyTrendCache: (fingerprint: String, days: Int, value: DailyTrend)?

    /// - Parameter includePeriodStats: when true, also computes the 7-/30-day
    ///   cost aggregates (see `periodCosts()`). Off by default since it's
    ///   meaningfully heavier than the today-only reads; the caller throttles
    ///   it on its own slower cadence.
    static func snapshot(
        includePeriodStats: Bool = false,
        progress: ((String) -> Void)? = nil
    ) -> UsageSnapshot {
        let fm = FileManager.default
        var snap = UsageSnapshot()
        progress?("Reading Claude logs…")
        if fm.fileExists(atPath: claudeDir.path) {
            snap.claude = readClaudeToday()
        }
        // This is a local snapshot supplied by Claude Code's statusLine
        // bridge, so reading it is cheap and safe on every refresh tick.
        // Avoid creating a noisy "bridge unavailable" log on machines that
        // do not have Claude Code at all.
        if fm.fileExists(atPath: claudeDir.path)
            || fm.fileExists(atPath: ClaudeLimitsReader.statusLineSnapshotURL.path)
        {
            snap.claudeLimits = ClaudeLimitsReader.fetch()
        }
        progress?("Reading Codex logs…")
        if fm.fileExists(atPath: codexDir.path) {
            let codexUsage = readCodexToday()
            let codexLimits = codexLimits()
            snap.codex = codexUsage
            snap.codexLimits = codexLimits
            logCodexSnapshot(codexUsage, limits: codexLimits)
        } else {
            logCodexStatus(
                "codex: local sessions directory not found — expected ~/.codex/sessions",
                signature: "missing")
        }
        progress?("Reading Antigravity logs…")
        if fm.fileExists(atPath: antigravityDir.path) {
            snap.antigravity = readAntigravityToday()
        }
        progress?("Reading activity timeline…")
        snap.hourlyUsage = readHourlyUsage()
        if includePeriodStats {
            progress?("Calculating 7/30-day costs…")
            snap.periodCosts = periodCosts()
            progress?("Calculating 30-day trend…")
            snap.dailyTrend = dailyTrend(days: 30)
        }
        progress?("Updating display…")
        snap.updatedAt = Date()
        return snap
    }

    /// Codex data is read from local JSONL files rather than an API, so it
    /// used to be invisible in the diagnostics log. Log only when the local
    /// reading changes to keep the log useful without adding a line every
    /// minute forever.
    private static func logCodexSnapshot(_ usage: CodexUsage, limits: CodexLimits?) {
        let limitSummary: String
        let primaryUsed = limits?.primary.map { Int($0.usedPercent) } ?? -1
        let secondaryUsed = limits?.secondary.map { Int($0.usedPercent) } ?? -1
        let asOf = limits?.asOf?.timeIntervalSince1970 ?? -1
        if let limits {
            let windows = [
                limits.primary.map { "5h \(Int($0.usedPercent))%" },
                limits.secondary.map { "weekly \(Int($0.usedPercent))%" },
            ].compactMap { $0 }.joined(separator: ", ")
            limitSummary = windows.isEmpty
                ? "limits=empty"
                : "limits=\(windows) as of \(humanAgo(limits.asOf))"
        } else {
            limitSummary = "limits=not found"
        }
        let signature = "\(usage.inputTokens)|\(usage.cachedInputTokens)|\(usage.outputTokens)|\(usage.reasoningTokens)|\(usage.totalTokens)|\(usage.sessionCount)|\(primaryUsed)|\(secondaryUsed)|\(asOf)"
        logCodexStatus(
            "codex: local logs read — \(formatTokens(usage.totalTokens)) tokens, \(usage.sessionCount) sessions, \(limitSummary)",
            signature: signature)
    }

    private static func logCodexStatus(_ message: String, signature: String) {
        codexLogLock.lock()
        let changed = signature != lastCodexLogSignature
        if changed { lastCodexLogSignature = signature }
        codexLogLock.unlock()
        guard changed else { return }
        appLog(message)
    }

    // MARK: - Shared helpers

    /// `Calendar.current` rebuilds a calendar from the user's preferences on
    /// every access, which is far too expensive to do once per log line.
    /// `autoupdatingCurrent` can be held onto and still follows changes to the
    /// user's locale, calendar and time zone.
    static let calendar = Calendar.autoupdatingCurrent

    private static func localHour(_ date: Date) -> Int {
        calendar.component(.hour, from: date)
    }

    /// Start-of-day for a date, memoised on the assumption that consecutive
    /// log records usually fall on the same day — which turns one
    /// `Calendar` call per line into roughly one per day of history.
    private struct DayBoundaryMemo {
        private var start = Date.distantFuture
        private var end = Date.distantPast

        mutating func dayStart(for date: Date) -> Date {
            if date >= start && date < end { return start }
            start = UsageReader.calendar.startOfDay(for: date)
            end = UsageReader.calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86400)
            return start
        }
    }

    private static func readHourlyUsage() -> HourlyUsage {
        var usage = HourlyUsage()

        // Claude assistant records contain the actual token usage for each
        // completed response. `claudeTokenEvents()` is exactly this scan and
        // is cached against the log files' mtimes, so reuse it instead of
        // parsing today's logs a second time in the same refresh.
        for event in claudeTokenEvents() where calendar.isDateInToday(event.date) {
            usage.claude[localHour(event.date)] += event.tokens
        }

        // Codex token_count events are cumulative per session; add only the
        // delta between consecutive readings to avoid counting the same turn
        // repeatedly.
        if FileManager.default.fileExists(atPath: codexDir.path) {
            for file in filesModifiedToday(under: codexDir, ext: "jsonl") {
                var previous = 0
                forEachLine(of: file, containingAll: ["\"token_count\""]) { line in
                    guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                          let ts = obj["timestamp"] as? String,
                          isTodayLocal(isoTimestamp: ts),
                          let payload = obj["payload"] as? [String: Any],
                          (payload["type"] as? String) == "token_count",
                          let info = payload["info"] as? [String: Any],
                          let totals = info["total_token_usage"] as? [String: Any],
                          let total = totals["total_tokens"] as? Int,
                          let date = parseISO(ts)
                    else { return }
                    let delta = max(0, total - previous)
                    usage.codex[localHour(date)] += delta
                    previous = max(previous, total)
                }
            }
        }

        if FileManager.default.fileExists(atPath: antigravityDir.path) {
            let historyFile = antigravityDir.appendingPathComponent("history.jsonl")
            forEachLine(of: historyFile) { line in
                guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      let timestampMS = obj["timestamp"] as? Double
                else { return }
                let date = Date(timeIntervalSince1970: timestampMS / 1000.0)
                if calendar.isDateInToday(date) { usage.antigravity[localHour(date)] += 1 }
            }
        }
        return usage
    }

    private static func filesModifiedToday(under root: URL, ext: String) -> [URL] {
        filesModified(under: root, ext: ext, sinceDaysAgo: 1)
    }

    /// Today's Claude token usage as timestamped events, from a single pass
    /// over the logs and cached until those files change. The projection
    /// calibrates across many intervals, and re-scanning the logs once per
    /// interval would put back exactly the cost the byte scanner removed.
    struct ClaudeTokenEvent {
        let date: Date
        /// Every token the turn reported — what the activity chart counts.
        let tokens: Int
        /// The same turn weighted for the five-hour window — what the limit
        /// projection calibrates against. See `limitUnits(_:)`.
        let limitUnits: Double
    }

    static func claudeTokenEvents() -> [ClaudeTokenEvent] {
        guard FileManager.default.fileExists(atPath: claudeDir.path) else { return [] }
        var events: [ClaudeTokenEvent] = []
        for entry in claudeFileStates(for: filesModifiedToday(under: claudeDir, ext: "jsonl")) {
            for record in entry.state.requests.values where record.hasUsage {
                guard let date = record.date, record.tokenTotal > 0 else { continue }
                events.append(ClaudeTokenEvent(
                    date: date, tokens: record.tokenTotal, limitUnits: record.limitUnits))
            }
        }
        events.sort { $0.date < $1.date }
        return events
    }

    /// Files modified within the last `days` local days (1 = today only).
    /// Backs both the today-only readers and the 7-/30-day period aggregates.
    private static let listingCacheLock = NSLock()
    private static var listingCache: [String: (at: Date, files: [URL])] = [:]
    /// One refresh asks for the same listing several times over — the change
    /// signature, then the limits read, then the usage read — and walking
    /// ~600 Codex session files costs a few milliseconds each time. Holding a
    /// listing for a couple of seconds collapses those into one walk while
    /// staying far fresher than the 60-second refresh it serves.
    private static let listingCacheTTL: TimeInterval = 2

    private static func filesModified(under root: URL, ext: String, sinceDaysAgo days: Int) -> [URL] {
        let key = "\(root.path)|\(ext)|\(days)"
        let now = Date()
        listingCacheLock.lock()
        if let cached = listingCache[key], now.timeIntervalSince(cached.at) < listingCacheTTL {
            listingCacheLock.unlock()
            return cached.files
        }
        listingCacheLock.unlock()

        let files = enumerateFilesModified(under: root, ext: ext, sinceDaysAgo: days)

        listingCacheLock.lock()
        listingCache[key] = (now, files)
        listingCacheLock.unlock()
        return files
    }

    private static func enumerateFilesModified(under root: URL, ext: String, sinceDaysAgo days: Int) -> [URL] {
        let fm = FileManager.default
        let cutoff = calendar.startOfDay(for: Date()).addingTimeInterval(-Double(days - 1) * 86400)
        guard let en = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey]
        ) else { return [] }
        var out: [URL] = []
        for case let url as URL in en {
            guard url.pathExtension == ext,
                  let vals = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                  vals.isRegularFile == true,
                  let mtime = vals.contentModificationDate,
                  mtime >= cutoff
            else { continue }
            out.append(url)
        }
        return out
    }

    /// Iterates a file's lines without ever materializing the whole file as a
    /// `String`. These logs reach 100+ MB and the previous path made three
    /// copies of every byte on disk: a full-file `String`, one `String` per
    /// line, then a re-encoded `Data` per line for `JSONSerialization`. Lines
    /// arrive as `Data` — what every caller actually wanted — and `markers`
    /// are matched against the raw bytes first, so a line that can't possibly
    /// be interesting costs no allocation at all.
    private static func forEachLine(
        of url: URL,
        containingAll markers: [StaticString] = [],
        _ body: (Data) -> Void
    ) {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return }
        forEachLine(in: data, containingAll: markers, body)
    }

    // Internal rather than private so the line splitter and its byte-level
    // marker filter can be tested directly — every reader in this file now
    // depends on it, so a regression here would silently zero out usage
    // rather than fail loudly.
    static func forEachLine(
        in data: Data,
        containingAll markers: [StaticString] = [],
        _ body: (Data) -> Void
    ) {
        forEachLineBytes(in: data) { line in
            guard markers.allSatisfy({ bytesContain(line, $0) }) else { return }
            body(Data(buffer: line))
        }
    }

    /// The allocation-free form. `body` gets a view straight into the mapped
    /// file, valid only for the duration of the call — copy out anything that
    /// needs to outlive it. Callers whose interest in a line can't be decided
    /// by one fixed set of markers (a line is worth parsing if it's *either*
    /// a usage record *or* a title record, say) use this and do their own
    /// byte tests, so an uninteresting line still costs no allocation.
    static func forEachLineBytes(in data: Data, _ body: (UnsafeBufferPointer<UInt8>) -> Void) {
        data.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            let count = raw.count
            var start = 0
            while start < count {
                let newline = memchr(base + start, 0x0A, count - start)
                let end = newline.map { UnsafeRawPointer($0) - UnsafeRawPointer(base) } ?? count
                var lineEnd = end
                if lineEnd > start, base[lineEnd - 1] == 0x0D { lineEnd -= 1 }
                if lineEnd > start {
                    body(UnsafeBufferPointer(start: base + start, count: lineEnd - start))
                }
                start = end + 1
            }
        }
    }

    /// Byte-level substring test against an ASCII marker.
    static func bytesContain(_ line: UnsafeBufferPointer<UInt8>, _ needle: StaticString) -> Bool {
        // A single-scalar `StaticString` has no pointer representation and
        // reading `utf8Start` off one would be undefined behavior. No call
        // site passes one; if a future one does, fail open (the JSON parse
        // downstream still rejects the extra lines) rather than misbehave.
        guard needle.hasPointerRepresentation else { return true }
        return fastBytesContains(
            line,
            UnsafeBufferPointer(start: needle.utf8Start, count: needle.utf8CodeUnitCount))
    }

    /// Last `maxBytes` of a file, advanced past the first partial line so the
    /// caller only ever sees whole lines.
    static func tail(of url: URL, maxBytes: Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        guard size > UInt64(maxBytes) else {
            try? handle.seek(toOffset: 0)
            return try? handle.readToEnd()
        }
        try? handle.seek(toOffset: size - UInt64(maxBytes))
        guard var data = try? handle.readToEnd() else { return nil }
        if let newline = data.firstIndex(of: 0x0A) {
            data = data.subdata(in: data.index(after: newline)..<data.endIndex)
        }
        return data
    }

    /// `String.contains` does Unicode-correct (grapheme-cluster) comparison,
    /// which is extremely slow on the multi-KB/MB JSONL lines these logs can
    /// contain. All our marker checks are plain ASCII literals, so a manual
    /// byte scan is orders of magnitude faster and avoids pegging the CPU
    /// while scanning weeks of history.
    // Internal rather than private so the byte scanner's correctness against
    // `String.contains` can be tested directly instead of only indirectly
    // through a full log-parsing call.
    static func fastContains(_ haystack: String, _ needle: StaticString) -> Bool {
        // `utf8Start` is only valid for the pointer representation, which
        // every multi-character literal uses; a single-scalar literal would
        // read garbage. All call sites pass multi-character markers, but
        // guard it explicitly so a future one-character needle fails safe
        // instead of hitting undefined behavior.
        guard needle.hasPointerRepresentation else { return haystack.contains(needle.description) }
        let needleBuffer = UnsafeBufferPointer(start: needle.utf8Start, count: needle.utf8CodeUnitCount)
        return haystack.utf8.withContiguousStorageIfAvailable { hay -> Bool in
            fastBytesContains(hay, needleBuffer)
        } ?? haystack.contains(needle.description)
    }

    private static func fastBytesContains(_ haystack: UnsafeBufferPointer<UInt8>, _ needle: UnsafeBufferPointer<UInt8>) -> Bool {
        guard let first = needle.first, let needleBase = needle.baseAddress else { return true }
        guard haystack.count >= needle.count, let hayBase = haystack.baseAddress else { return false }
        // `memchr`/`memcmp` are SIMD-accelerated; a hand-rolled byte loop over
        // 100+ MB of log is several times slower for exactly the same answer.
        let limit = haystack.count - needle.count
        var i = 0
        while i <= limit {
            guard let hit = memchr(hayBase + i, Int32(first), limit - i + 1) else { return false }
            let index = UnsafeRawPointer(hit) - UnsafeRawPointer(hayBase)
            if memcmp(hayBase + index, needleBase, needle.count) == 0 { return true }
            i = index + 1
        }
        return false
    }

    private static let utcDayFormatter: DateFormatter = {
        let fmt = DateFormatter()
        // Log timestamps are Gregorian; the device locale may use another
        // calendar (e.g. Thai Buddhist year 2569), so pin the formatter.
        fmt.calendar = Calendar(identifier: .gregorian)
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.timeZone = TimeZone(identifier: "UTC")
        return fmt
    }()

    private static let todayPrefixLock = NSLock()
    private static var todayPrefixes: (dayStart: Date, values: [String])?

    /// Local "today" can span two UTC dates; timestamps in logs are UTC.
    /// Recomputed whenever the local day rolls over — this app runs for days
    /// at a time, and a value computed once at launch would keep filtering
    /// against the launch day's dates after midnight, quietly reporting an
    /// empty "today" until the next relaunch.
    private static func todayPrefixesUTC() -> [String] {
        let dayStart = calendar.startOfDay(for: Date())
        todayPrefixLock.lock()
        defer { todayPrefixLock.unlock() }
        if let cached = todayPrefixes, cached.dayStart == dayStart { return cached.values }
        let end = dayStart.addingTimeInterval(24 * 3600 - 1)
        let values = Array(Set([utcDayFormatter.string(from: dayStart), utcDayFormatter.string(from: end)]))
        todayPrefixes = (dayStart, values)
        return values
    }

    private static func isTodayLocal(isoTimestamp: String) -> Bool {
        guard todayPrefixesUTC().contains(where: { isoTimestamp.hasPrefix($0) }) else { return false }
        guard let date = parseISO(isoTimestamp) else { return false }
        return calendar.isDateInToday(date)
    }

    /// Generalized day-range check for the 7-day/30-day period aggregates.
    /// Unlike `isTodayLocal` this skips the UTC-prefix fast path — it only
    /// runs on the slow (30-minute) period-stats cadence, not every tick.
    private static func isWithinLastDays(isoTimestamp: String, days: Int) -> Bool {
        guard let date = parseISO(isoTimestamp) else { return false }
        let cutoff = calendar.startOfDay(for: Date()).addingTimeInterval(-Double(days - 1) * 86400)
        return date >= cutoff
    }

    private static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlain = ISO8601DateFormatter()

    static func parseISO(_ s: String) -> Date? {
        fastParseISO(s) ?? isoFrac.date(from: s) ?? isoPlain.date(from: s)
    }

    /// `ISO8601DateFormatter` costs microseconds per call, which is real money
    /// at one call per log line — a large session log has hundreds of
    /// thousands. Both CLIs write plain
    /// `yyyy-MM-ddTHH:mm:ss[.fff](Z|±HH:MM)`, so parse that shape directly and
    /// leave the formatters as the fallback for anything unexpected.
    static func fastParseISO(_ s: String) -> Date? {
        let utf8 = Array(s.utf8)
        guard utf8.count >= 19 else { return nil }

        func digits(_ start: Int, _ count: Int) -> Int? {
            var value = 0
            for i in start..<(start + count) {
                let byte = utf8[i]
                guard byte >= 0x30, byte <= 0x39 else { return nil }
                value = value * 10 + Int(byte - 0x30)
            }
            return value
        }
        guard utf8[4] == 0x2D, utf8[7] == 0x2D,           // '-'
              utf8[10] == 0x54 || utf8[10] == 0x20,       // 'T' or ' '
              utf8[13] == 0x3A, utf8[16] == 0x3A,         // ':'
              let year = digits(0, 4), let month = digits(5, 2), let day = digits(8, 2),
              let hour = digits(11, 2), let minute = digits(14, 2), let second = digits(17, 2),
              (1...12).contains(month), (1...31).contains(day),
              hour < 24, minute < 60, second <= 60
        else { return nil }

        var index = 19
        var fraction = 0.0
        if index < utf8.count, utf8[index] == 0x2E {      // '.'
            index += 1
            var scale = 0.1
            var seen = 0
            while index < utf8.count, utf8[index] >= 0x30, utf8[index] <= 0x39 {
                fraction += Double(utf8[index] - 0x30) * scale
                scale /= 10
                index += 1
                seen += 1
            }
            guard seen > 0 else { return nil }
        }

        // A zone is required, matching `ISO8601DateFormatter`. Guessing UTC for
        // a zone-less timestamp would silently shift a reading by hours rather
        // than falling through to the formatter and being rejected.
        var offsetSeconds = 0
        guard index < utf8.count else { return nil }
        do {
            switch utf8[index] {
            case 0x5A, 0x7A:                              // 'Z' / 'z'
                index += 1
            case 0x2B, 0x2D:                              // '+' / '-'
                let sign = utf8[index] == 0x2D ? -1 : 1
                index += 1
                guard index + 1 < utf8.count, let offsetHour = digits(index, 2) else { return nil }
                index += 2
                if index < utf8.count, utf8[index] == 0x3A { index += 1 }
                let offsetMinute = (index + 1 < utf8.count) ? (digits(index, 2) ?? 0) : 0
                if index + 1 < utf8.count { index += 2 }
                offsetSeconds = sign * (offsetHour * 3600 + offsetMinute * 60)
            default:
                return nil
            }
        }
        guard index == utf8.count else { return nil }

        let epochDay = daysFromCivil(year: year, month: month, day: day)
        let seconds = Double(epochDay * 86_400 + hour * 3600 + minute * 60 + second - offsetSeconds)
        return Date(timeIntervalSince1970: seconds + fraction)
    }

    /// Days between 1970-01-01 and the given proleptic-Gregorian date, by the
    /// standard civil-from-days algorithm. Avoids `Calendar`, which is far too
    /// heavy to touch once per log line.
    private static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let y = year - (month <= 2 ? 1 : 0)
        let era = (y >= 0 ? y : y - 399) / 400
        let yearOfEra = y - era * 400
        let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    /// Pulls the top-level `"timestamp":"…"` value straight out of a line's
    /// bytes. Both CLIs write it as a plain string, and reading it this way
    /// keeps per-line bookkeeping (when a session started and last moved) off
    /// the JSON parser — which is the expensive part on the multi-megabyte
    /// tool-output lines these logs are mostly made of.
    static func rawTimestamp(in line: UnsafeBufferPointer<UInt8>) -> String? {
        let marker: StaticString = "\"timestamp\":\""
        guard marker.hasPointerRepresentation, let base = line.baseAddress else { return nil }
        let needle = UnsafeBufferPointer(start: marker.utf8Start, count: marker.utf8CodeUnitCount)
        guard line.count > needle.count else { return nil }
        var i = 0
        let limit = line.count - needle.count
        while i <= limit {
            guard let hit = memchr(base + i, Int32(needle[0]), limit - i + 1) else { return nil }
            let index = UnsafeRawPointer(hit) - UnsafeRawPointer(base)
            if memcmp(base + index, needle.baseAddress!, needle.count) == 0 {
                let valueStart = index + needle.count
                guard valueStart < line.count,
                      let close = memchr(base + valueStart, 0x22, line.count - valueStart)
                else { return nil }
                let valueEnd = UnsafeRawPointer(close) - UnsafeRawPointer(base)
                guard valueEnd > valueStart else { return nil }
                return String(decoding: UnsafeBufferPointer(start: base + valueStart, count: valueEnd - valueStart), as: UTF8.self)
            }
            i = index + 1
        }
        return nil
    }

    // MARK: - Claude Code

    /// One assistant turn, parsed once and then reused by every consumer.
    ///
    /// Today's totals, the session breakdown, the hourly timeline, the
    /// burn-rate token events and the 30-day trend all used to walk the same
    /// lines of the same files independently — up to four full parses of a
    /// 34 MB log per refresh. They all derive from this instead, and the
    /// records are kept per file so an append-only log is parsed once and
    /// then only ever extended.
    struct ClaudeRequestRecord {
        var tokens = ModelTokens()
        /// Session rows also count turns that only invoked tools, so a record
        /// can exist without a usage block; the token totals must not.
        var hasUsage = false
        var model: String?
        var timestamp = ""
        var date: Date?
        var skills: [String] = []
        var tools: [String] = []
        var costUSD = 0.0

        var tokenTotal: Int {
            tokens.input + tokens.output + tokens.cacheWrite + tokens.cacheRead
        }

        /// What this turn cost against Claude's five-hour window, in the
        /// weighting that window actually moves by — see
        /// `UsageReader.limitUnits`.
        var limitUnits: Double { UsageReader.limitUnits(tokens) }
    }

    /// Tokens weighted the way the five-hour rate limit consumes them.
    ///
    /// This is deliberately *not* the token total. On real usage here, 98% of
    /// every token counted is a cache read, and cache reads move the five-hour
    /// window barely at all — so calibrating against the total was fitting a
    /// rate against what is almost pure noise (r² 0.07 against the observed
    /// percentage moves). Output tokens dominate, fresh input — whether it
    /// arrives as `input_tokens` or as a cache write — counts about a tenth as
    /// much, and cached reads count for nothing.
    ///
    /// Weights were fitted against 1,198 readings Claude Desktop recorded over
    /// three weeks and validated on a held-out half of them (r² 0.89). Dropping
    /// the cache-write term is what breaks it worst: intervals that are almost
    /// entirely cache creation then look free and the projection overshoots by
    /// up to 97 points. The exact coefficients are not a knife edge — halving
    /// or doubling the 0.1 still beats weighting every token equally.
    ///
    /// Only the ratios matter to the caller: the projection fits its own scale
    /// factor per account, so a different plan or model mix is absorbed there.
    static func limitUnits(_ tokens: ModelTokens) -> Double {
        Double(tokens.output) + 0.1 * Double(tokens.input + tokens.cacheWrite)
    }

    struct ClaudeFileScanState {
        /// Dedupes streamed/rewritten entries: the same request can appear
        /// more than once, and the last occurrence wins.
        var requests: [String: ClaudeRequestRecord] = [:]
        var customName: String?
        var generatedName: String?
        var workspace: String?
    }

    private static let claudeFileCache = IncrementalFileCache<ClaudeFileScanState>()

    static func claudeFileStates(for files: [URL]) -> [(url: URL, state: ClaudeFileScanState)] {
        let states = claudeFileCache.states(
            for: files,
            initial: { ClaudeFileScanState() },
            consume: { data, state in consumeClaudeLines(data, into: &state) })
        return Array(zip(files, states)).map { (url: $0.0, state: $0.1) }
    }

    /// Reads only session metadata, token counts and tool names. Prompt and
    /// tool input content is deliberately ignored and never enters the model.
    private static func consumeClaudeLines(_ data: Data, into state: inout ClaudeFileScanState) {
        forEachLineBytes(in: data) { line in
            // Decide what a line could possibly be from its raw bytes, before
            // paying for a JSON parse. Each of these strings must appear
            // literally in a line the checks below would accept, so a line
            // failing all of them cannot be one we want.
            let mightBeAssistant = bytesContain(line, "\"assistant\"")
            let mightBeTitle = bytesContain(line, "-title\"")
            let mightHaveWorkspace = state.workspace == nil && bytesContain(line, "\"cwd\"")
            guard mightBeAssistant || mightBeTitle || mightHaveWorkspace else { return }

            guard let obj = try? JSONSerialization.jsonObject(with: Data(buffer: line)) as? [String: Any]
            else { return }

            // Claude stores session titles in lightweight metadata records:
            // `custom-title` when the user renamed the session, `ai-title` for
            // the automatic one. Both are titles rather than prompt text. Read
            // them independently of any date filter so a session titled
            // yesterday keeps its name when it is active today, and keep them
            // apart so a later automatic title never overwrites a name the
            // user chose.
            switch obj["type"] as? String {
            case "custom-title": state.customName = normalizedSessionName(obj["customTitle"]) ?? state.customName
            case "ai-title": state.generatedName = normalizedSessionName(obj["aiTitle"]) ?? state.generatedName
            default: break
            }
            if state.workspace == nil, let cwd = obj["cwd"] as? String, !cwd.isEmpty {
                state.workspace = URL(fileURLWithPath: cwd).lastPathComponent
            }

            guard (obj["type"] as? String) == "assistant",
                  let timestamp = obj["timestamp"] as? String,
                  let message = obj["message"] as? [String: Any]
            else { return }

            let skills = skillInvocations(in: message)
            let tools = toolInvocations(in: message)
            let usage = message["usage"] as? [String: Any]
            guard usage != nil || !skills.isEmpty || !tools.isEmpty else { return }

            let tokens = ModelTokens(
                input: usage?["input_tokens"] as? Int ?? 0,
                output: usage?["output_tokens"] as? Int ?? 0,
                cacheWrite: usage?["cache_creation_input_tokens"] as? Int ?? 0,
                cacheRead: usage?["cache_read_input_tokens"] as? Int ?? 0)
            let model = message["model"] as? String
            let key = (obj["requestId"] as? String)
                ?? (message["id"] as? String)
                ?? (obj["uuid"] as? String)
                ?? UUID().uuidString
            state.requests[key] = ClaudeRequestRecord(
                tokens: tokens,
                hasUsage: usage != nil,
                model: model,
                timestamp: timestamp,
                date: parseISO(timestamp),
                skills: skills,
                tools: tools,
                costUSD: Pricing.claudeModelCostUSD(tokens, model: model ?? ""))
        }
    }

    private static func readClaudeToday() -> ClaudeUsage {
        readClaude(matching: { isTodayLocal(isoTimestamp: $0) },
                   files: filesModifiedToday(under: claudeDir, ext: "jsonl"),
                   includeSessions: true)
    }

    private static func readClaude(
        matching isIncluded: (String) -> Bool,
        files: [URL],
        includeSessions: Bool = false
    ) -> ClaudeUsage {
        var usage = ClaudeUsage()
        let states = claudeFileStates(for: files)
        var perKey: [String: ClaudeRequestRecord] = [:]
        var sessions = Set<String>()

        for entry in states {
            var fileMatched = false
            for (key, record) in entry.state.requests
            where record.hasUsage && isIncluded(record.timestamp) {
                perKey[key] = record
                fileMatched = true
            }
            if fileMatched { sessions.insert(entry.url.path) }
        }

        var latestTS = ""
        for (_, e) in perKey {
            usage.inputTokens += e.tokens.input
            usage.outputTokens += e.tokens.output
            usage.cacheCreationTokens += e.tokens.cacheWrite
            usage.cacheReadTokens += e.tokens.cacheRead
            let model = e.model ?? "unknown"
            var m = usage.perModel[model] ?? ModelTokens()
            m.input += e.tokens.input
            m.output += e.tokens.output
            m.cacheWrite += e.tokens.cacheWrite
            m.cacheRead += e.tokens.cacheRead
            usage.perModel[model] = m
            for skill in e.skills {
                usage.skillCounts[skill, default: 0] += 1
                if let date = e.date {
                    usage.skillLastUsed[skill] = max(usage.skillLastUsed[skill] ?? .distantPast, date)
                }
            }
            if e.timestamp > latestTS, let m = e.model {
                latestTS = e.timestamp
                usage.lastModel = m
            }
        }
        usage.sessionCount = sessions.count
        if includeSessions {
            usage.sessions = claudeSessions(matching: isIncluded, states: states)
        }
        return usage
    }

    private static func claudeSessions(
        matching isIncluded: (String) -> Bool,
        states: [(url: URL, state: ClaudeFileScanState)]
    ) -> [SessionActivity] {
        var result: [SessionActivity] = []

        for entry in states {
            let requests = entry.state.requests.values.filter { isIncluded($0.timestamp) }
            guard !requests.isEmpty else { continue }
            var session = SessionActivity(
                id: entry.url.deletingPathExtension().lastPathComponent,
                name: entry.state.customName ?? entry.state.generatedName,
                workspace: entry.state.workspace)
            for request in requests {
                let isLatest: Bool
                if let date = request.date, let last = session.lastActivityAt {
                    isLatest = date >= last
                } else {
                    isLatest = true
                }
                if let date = request.date {
                    if session.startedAt == nil || date < session.startedAt! {
                        session.startedAt = date
                    }
                    if session.lastActivityAt == nil || date > session.lastActivityAt! {
                        session.lastActivityAt = date
                    }
                }
                session.tokenTotal += request.tokenTotal
                session.estimatedCostUSD += request.costUSD
                if isLatest {
                    session.model = request.model
                }
                for skill in request.skills {
                    session.skills[skill, default: 0] += 1
                }
                for tool in request.tools {
                    session.tools[tool, default: 0] += 1
                }
                let attributedCallCount = request.skills.count + request.tools.count
                if attributedCallCount > 0 {
                    let share = request.costUSD / Double(attributedCallCount)
                    for skill in request.skills { session.skillCosts[skill, default: 0] += share }
                    for tool in request.tools { session.toolCosts[tool, default: 0] += share }
                }
            }
            result.append(session)
        }

        return result.sorted {
            ($0.lastActivityAt ?? .distantPast) > ($1.lastActivityAt ?? .distantPast)
        }
    }

    /// Names of any Claude Code `Skill` tool calls in one assistant message's
    /// content array — e.g. `[{"type":"tool_use","name":"Skill","input":{"skill":"graphify"}}]`.
    private static func skillInvocations(in message: [String: Any]) -> [String] {
        guard let content = message["content"] as? [Any] else { return [] }
        return content.compactMap { item in
            guard let block = item as? [String: Any],
                  block["type"] as? String == "tool_use",
                  block["name"] as? String == "Skill",
                  let input = block["input"] as? [String: Any],
                  let skill = input["skill"] as? String
            else { return nil }
            return skill
        }
    }

    /// Tool names are useful at session level, while Skill calls get their own
    /// named bucket and are therefore excluded from this list.
    private static func toolInvocations(in message: [String: Any]) -> [String] {
        guard let content = message["content"] as? [Any] else { return [] }
        return content.compactMap { item in
            guard let block = item as? [String: Any],
                  block["type"] as? String == "tool_use",
                  let name = block["name"] as? String,
                  name != "Skill"
            else { return nil }
            return name
        }
    }

    private static func normalizedSessionName(_ value: Any?) -> String? {
        guard let raw = value as? String else { return nil }
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    /// Newest account-wide rate-limit snapshot Codex wrote to any recent
    /// session log. The 5h/weekly windows are account-global, so the freshest
    /// reading across all sessions is what we want (not just today's).
    static func codexLimits() -> CodexLimits? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: codexDir.path) else { return nil }
        let cutoff = Date().addingTimeInterval(-8 * 24 * 3600)
        guard let en = fm.enumerator(
            at: codexDir,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        ) else { return nil }
        var files: [(url: URL, modified: Date, size: Int)] = []
        for case let url as URL in en {
            guard url.pathExtension == "jsonl",
                  let v = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]),
                  v.isRegularFile == true, let m = v.contentModificationDate, m >= cutoff
            else { continue }
            files.append((url, m, v.fileSize ?? -1))
        }
        let ordered = files.sorted { $0.modified > $1.modified }

        // This runs on every refresh tick, and the candidate set is only the
        // handful of sessions touched in the last 8 days — so a stat-only
        // fingerprint of them is enough to skip the read entirely whenever
        // Codex hasn't written anything since the last tick.
        let fingerprint = ordered
            .map { "\($0.url.path)|\($0.modified.timeIntervalSince1970)|\($0.size)" }
            .joined(separator: "|")
        codexLimitsCacheLock.lock()
        if let cached = codexLimitsCache, cached.fingerprint == fingerprint {
            codexLimitsCacheLock.unlock()
            return cached.value
        }
        codexLimitsCacheLock.unlock()

        var result: CodexLimits?
        for file in ordered {
            if let limits = codexLimits(inFile: file.url) {
                result = limits
                break
            }
        }

        codexLimitsCacheLock.lock()
        codexLimitsCache = (fingerprint, result)
        codexLimitsCacheLock.unlock()
        return result
    }

    /// Codex session logs routinely exceed 100 MB, and the reading we want is
    /// the newest `rate_limits` in the file — which, since Codex appends, is
    /// always near the end. Read the tail rather than the whole file; only if
    /// the tail turns up nothing does the full scan run (and its result is
    /// then cached against the file's mtime anyway).
    private static let codexLimitsTailBytes = 2 * 1024 * 1024

    private static func codexLimits(inFile url: URL) -> CodexLimits? {
        if let limits = codexLimits(in: tail(of: url, maxBytes: codexLimitsTailBytes)) { return limits }
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
              size > codexLimitsTailBytes,
              let full = try? Data(contentsOf: url, options: .mappedIfSafe)
        else { return nil }
        return codexLimits(in: full)
    }

    private static func codexLimits(in data: Data?) -> CodexLimits? {
        guard let data else { return nil }
        var found: [String: Any]?
        var foundTS: String?
        forEachLine(in: data, containingAll: ["\"rate_limits\"", "\"token_count\""]) { line in
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let payload = obj["payload"] as? [String: Any],
                  let rl = payload["rate_limits"] as? [String: Any],
                  // Early events in a session carry null windows; keep only
                  // readings that actually contain a populated window.
                  rl["primary"] is [String: Any] || rl["secondary"] is [String: Any]
            else { return }
            found = rl  // keep last (newest) populated reading in file
            foundTS = obj["timestamp"] as? String
        }
        guard let rl = found else { return nil }
        var limits = parseCodexLimits(rl)
        limits.asOf = foundTS.flatMap(parseISO)
        return limits
    }

    private static func parseCodexLimits(_ rl: [String: Any]) -> CodexLimits {
        var out = CodexLimits()
        out.planType = rl["plan_type"] as? String
        func window(_ key: String) -> (window: LimitWindow, minutes: Double)? {
            guard let d = rl[key] as? [String: Any],
                  let pct = (d["used_percent"] as? Double) ?? (d["used_percent"] as? Int).map(Double.init)
            else { return nil }
            let reset = (d["resets_at"] as? Double).map { Date(timeIntervalSince1970: $0) }
                ?? (d["resets_at"] as? Int).map { Date(timeIntervalSince1970: Double($0)) }
            let minutes = (d["window_minutes"] as? Double)
                ?? (d["window_minutes"] as? Int).map(Double.init)
                ?? 0
            return (LimitWindow(usedPercent: pct, resetsAt: reset), minutes)
        }
        // Codex has changed which slot carries which window over time (the
        // 5-hour window was retired and weekly moved into "primary"), so
        // classify by window length instead of slot name: anything a day or
        // longer is the weekly limit, shorter ones are the session limit.
        for parsed in [window("primary"), window("secondary")].compactMap({ $0 }) {
            if parsed.minutes >= 24 * 60 || parsed.minutes == 0 {
                out.secondary = parsed.window   // weekly
            } else {
                out.primary = parsed.window     // legacy 5-hour
            }
        }
        return out
    }

    // MARK: - Codex

    /// A Codex session file's activity for one local day. Bucketed by day
    /// rather than pre-filtered to "today", so the cached parse of a file
    /// stays valid across midnight and can also serve the 30-day trend.
    struct CodexDayActivity {
        var startedAt: Date?
        var lastActivityAt: Date?
        /// `total_token_usage` is cumulative per session, so the last reading
        /// of the day is the day's figure — not a sum.
        var lastTotals: [String: Int]?
        var tools: [String: Int] = [:]
        var skills: [String: Int] = [:]
        var inferredSkills: Set<String> = []
    }

    struct CodexFileScanState {
        var sessionID: String?
        var sessionName: String?
        var workspace: String?
        var model: String?
        /// Last cumulative reading anywhere in the file, with its timestamp —
        /// what the today/period totals key off.
        var lastTotals: [String: Int]?
        var lastTS: String?
        var days: [Date: CodexDayActivity] = [:]
    }

    private static let codexFileCache = IncrementalFileCache<CodexFileScanState>()

    static func codexFileStates(for files: [URL]) -> [(url: URL, state: CodexFileScanState)] {
        let states = codexFileCache.states(
            for: files,
            initial: { CodexFileScanState() },
            consume: { data, state in consumeCodexLines(data, into: &state) })
        return Array(zip(files, states)).map { (url: $0.0, state: $0.1) }
    }

    /// Codex has emitted both `function_call` and `custom_tool_call` records
    /// across CLI/Desktop versions, so accept both shapes. Skill names are
    /// intentionally marked as inferred because Codex does not currently
    /// emit a dedicated skill invocation event in these local logs.
    private static func consumeCodexLines(_ data: Data, into state: inout CodexFileScanState) {
        var days = DayBoundaryMemo()
        forEachLineBytes(in: data) { line in
            // Every line contributes its timestamp to the day's first/last
            // activity, but only a few kinds carry anything else. Codex logs
            // are mostly multi-megabyte tool-output records, so the timestamp
            // is read from the raw bytes and the JSON parser is reserved for
            // lines that can actually match one of the cases below.
            guard let timestamp = rawTimestamp(in: line), let date = parseISO(timestamp) else { return }
            let dayStart = days.dayStart(for: date)
            var day = state.days[dayStart] ?? CodexDayActivity()
            if day.startedAt == nil || date < day.startedAt! { day.startedAt = date }
            if day.lastActivityAt == nil || date > day.lastActivityAt! { day.lastActivityAt = date }
            defer { state.days[dayStart] = day }

            let mightMatter = bytesContain(line, "\"session_meta\"")
                || bytesContain(line, "\"thread_name_updated\"")
                || bytesContain(line, "\"token_count\"")
                || bytesContain(line, "\"function_call\"")
                || bytesContain(line, "\"custom_tool_call\"")
            guard mightMatter else { return }

            guard let obj = try? JSONSerialization.jsonObject(with: Data(buffer: line)) as? [String: Any],
                  let payload = obj["payload"] as? [String: Any]
            else { return }

            if (obj["type"] as? String) == "session_meta" {
                if let id = payload["id"] as? String, !id.isEmpty { state.sessionID = id }
                if let cwd = payload["cwd"] as? String, !cwd.isEmpty {
                    state.workspace = URL(fileURLWithPath: cwd).lastPathComponent
                }
                state.model = payload["model"] as? String ?? state.model
            }

            if let name = codexSessionName(in: obj, payload: payload) {
                state.sessionName = name
            }

            if (obj["type"] as? String) == "event_msg",
               (payload["type"] as? String) == "token_count",
               let info = payload["info"] as? [String: Any],
               let total = info["total_token_usage"] as? [String: Any]
            {
                let totals = total.compactMapValues { $0 as? Int }
                day.lastTotals = totals
                state.lastTotals = totals
                state.lastTS = timestamp
            }

            guard (obj["type"] as? String) == "response_item",
                  let payloadType = payload["type"] as? String,
                  payloadType == "function_call" || payloadType == "custom_tool_call",
                  let name = payload["name"] as? String,
                  !name.isEmpty
            else { return }

            day.tools[name, default: 0] += 1
            for skill in inferredCodexSkills(in: toolArgumentText(from: payload)) {
                day.skills[skill, default: 0] += 1
                day.inferredSkills.insert(skill)
            }
        }
    }

    private static func readCodexToday() -> CodexUsage {
        readCodex(matching: { isTodayLocal(isoTimestamp: $0) },
                  files: filesModifiedToday(under: codexDir, ext: "jsonl"),
                  includeSessions: true)
    }

    private static func readCodex(
        matching isIncluded: (String) -> Bool,
        files: [URL],
        includeSessions: Bool = false
    ) -> CodexUsage {
        var usage = CodexUsage()
        let states = codexFileStates(for: files)
        for entry in states {
            guard let t = entry.state.lastTotals,
                  let ts = entry.state.lastTS,
                  isIncluded(ts)
            else { continue }
            usage.inputTokens += t["input_tokens"] ?? 0
            usage.cachedInputTokens += t["cached_input_tokens"] ?? 0
            usage.outputTokens += t["output_tokens"] ?? 0
            usage.reasoningTokens += t["reasoning_output_tokens"] ?? 0
            usage.totalTokens += t["total_tokens"] ?? 0
            usage.sessionCount += 1
        }
        if includeSessions {
            usage.sessions = codexSessions(on: calendar.startOfDay(for: Date()), states: states)
        }
        return usage
    }

    private static func codexSessions(
        on dayStart: Date,
        states: [(url: URL, state: CodexFileScanState)]
    ) -> [SessionActivity] {
        var result: [SessionActivity] = []
        for entry in states {
            guard let day = entry.state.days[dayStart],
                  day.lastTotals != nil || !day.tools.isEmpty
            else { continue }
            var tokenUsage = CodexUsage()
            tokenUsage.inputTokens = day.lastTotals?["input_tokens"] ?? 0
            tokenUsage.cachedInputTokens = day.lastTotals?["cached_input_tokens"] ?? 0
            tokenUsage.outputTokens = day.lastTotals?["output_tokens"] ?? 0
            tokenUsage.reasoningTokens = day.lastTotals?["reasoning_output_tokens"] ?? 0
            tokenUsage.totalTokens = day.lastTotals?["total_tokens"] ?? 0
            let estimatedCost = Pricing.codexCostUSD(tokenUsage)
            let toolInvocationCount = day.tools.values.reduce(0, +)
            let skillInvocationCount = day.skills.values.reduce(0, +)
            let toolCosts = Dictionary(uniqueKeysWithValues: day.tools.map { name, count in
                (name, estimatedCost * Double(count) / Double(max(1, toolInvocationCount)))
            })
            let skillCosts = Dictionary(uniqueKeysWithValues: day.skills.map { name, count in
                (name, estimatedCost * Double(count) / Double(max(1, skillInvocationCount)))
            })
            result.append(SessionActivity(
                id: entry.state.sessionID ?? entry.url.deletingPathExtension().lastPathComponent,
                name: entry.state.sessionName,
                startedAt: day.startedAt,
                lastActivityAt: day.lastActivityAt,
                tokenTotal: tokenUsage.totalTokens,
                estimatedCostUSD: estimatedCost,
                model: entry.state.model,
                workspace: entry.state.workspace,
                skills: day.skills,
                skillCosts: skillCosts,
                inferredSkills: day.inferredSkills,
                tools: day.tools,
                toolCosts: toolCosts))
        }
        return result.sorted {
            ($0.lastActivityAt ?? .distantPast) > ($1.lastActivityAt ?? .distantPast)
        }
    }

    private static func codexSessionName(in object: [String: Any], payload: [String: Any]) -> String? {
        guard object["type"] as? String == "event_msg",
              payload["type"] as? String == "thread_name_updated"
        else { return nil }
        return normalizedSessionName(payload["thread_name"])
    }

    private static func filesFingerprint(_ files: [URL]) -> String {
        files.map(fileStamp).joined(separator: "|")
    }

    static func fileStamp(_ file: URL) -> String {
        // Through a fresh `URL`, always. `URL` caches resource values on the
        // instance, and several of the paths this is called with are
        // `static let`s that live for the whole run — asking those directly
        // would return the mtime and size they had at first launch forever,
        // freezing the change signature this builds and stopping the app from
        // ever noticing new data.
        let file = URL(fileURLWithPath: file.path)
        let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let modified = values?.contentModificationDate?.timeIntervalSince1970 ?? -1
        let size = values?.fileSize ?? -1
        return "\(file.path)|\(modified)|\(size)"
    }

    /// Stat-only signature of every source `snapshot()` reads. When it is
    /// unchanged there is provably nothing new to parse, so the caller can
    /// skip the whole scan: an idle Mac then costs a few dozen `stat` calls a
    /// minute instead of re-reading and re-parsing the logs from scratch.
    /// Deliberately built from metadata only — no file is opened here.
    static func todaySourcesFingerprint() -> String {
        let fm = FileManager.default
        var parts: [String] = []
        parts.append("\(calendar.startOfDay(for: Date()).timeIntervalSince1970)")
        if fm.fileExists(atPath: claudeDir.path) {
            parts.append(filesFingerprint(filesModifiedToday(under: claudeDir, ext: "jsonl")))
        }
        parts.append(fileStamp(ClaudeLimitsReader.statusLineSnapshotURL))
        parts.append(fileStamp(ClaudeLimitsReader.desktopPlanUsageURL))
        if fm.fileExists(atPath: codexDir.path) {
            parts.append(filesFingerprint(filesModifiedToday(under: codexDir, ext: "jsonl")))
            // codexLimits() looks back 8 days, not just today.
            parts.append(filesFingerprint(filesModified(under: codexDir, ext: "jsonl", sinceDaysAgo: 8)))
        }
        if fm.fileExists(atPath: antigravityDir.path) {
            parts.append(fileStamp(antigravityDir.appendingPathComponent("history.jsonl")))
            for root in antigravityQuotaRoots {
                parts.append(filesFingerprint(filesModified(under: root, ext: "json", sinceDaysAgo: 8)))
            }
            parts.append(filesFingerprint(filesModified(under: antigravityDir.appendingPathComponent("log"), ext: "log", sinceDaysAgo: 2)))
        }
        return parts.joined(separator: "#")
    }

    private static func toolArgumentText(from payload: [String: Any]) -> String {
        for key in ["input", "arguments"] {
            if let text = payload[key] as? String { return text }
            if let value = payload[key],
               JSONSerialization.isValidJSONObject(value),
               let data = try? JSONSerialization.data(withJSONObject: value),
               let text = String(data: data, encoding: .utf8)
            {
                return text
            }
        }
        return ""
    }

    private static let codexSkillRegex = try? NSRegularExpression(
        pattern: #"(?:^|/)([A-Za-z0-9._-]+)/SKILL\.md(?:$|[^A-Za-z0-9._-])"#,
        options: [.caseInsensitive])

    private static func inferredCodexSkills(in text: String) -> [String] {
        guard !text.isEmpty, let regex = codexSkillRegex else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let skillRange = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[skillRange])
        }
    }

    private static func readAntigravityToday() -> AntigravityUsage {
        var usage = AntigravityUsage()
        let historyFile = antigravityDir.appendingPathComponent("history.jsonl")
        let limits = readAntigravityLimits()
        usage.fiveHour = limits.short?.window
        usage.weekly = limits.long?.window
        usage.asOf = [limits.short?.asOf, limits.long?.asOf].compactMap { $0 }.max()
        guard FileManager.default.fileExists(atPath: historyFile.path) else {
            usage.isWorking = antigravityIsWorking()
            return usage
        }
        var uniqueSessions = Set<String>()
        forEachLine(of: historyFile) { line in
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let timestampMS = obj["timestamp"] as? Double
            else { return }
            let date = Date(timeIntervalSince1970: timestampMS / 1000.0)
            if calendar.isDateInToday(date) {
                usage.totalPrompts += 1
                if let sessionID = obj["conversationId"] as? String {
                    uniqueSessions.insert(sessionID)
                }
            }
        }
        usage.sessionCount = uniqueSessions.count
        usage.isWorking = antigravityIsWorking()
        return usage
    }

    /// Prompt count over the last `daysBack` local days, for the 7-/30-day
    /// cost rows (Antigravity cost is priced per prompt, see Pricing.swift).
    /// 7-/30-day cumulative estimated cost per provider, for the dropdown's
    /// period-cost rows. Meaningfully heavier than the today-only reads (scans
    /// up to 30 days of logs), so callers should throttle this independently
    /// — see `includePeriodStats` on `snapshot(_:_:)`.
    /// Derived from `dailyTrend`'s own 30-day scan rather than a second,
    /// independent one — the per-day buckets it builds already apply the
    /// same per-model/per-token pricing this used to redo from scratch, so
    /// summing them is exactly equivalent, not an approximation. That also
    /// means this inherits `dailyTrend`'s backfill: a day whose log Claude
    /// has since pruned still counts here instead of quietly dropping out of
    /// the 7-/30-day totals.
    static func periodCosts() -> PeriodCosts {
        periodCosts(from: dailyTrend(days: 30))
    }

    /// Split out so a caller that also wants the trend itself computes the
    /// 30-day scan once instead of twice — that scan reads every log file
    /// modified in the last month, hundreds of megabytes for a heavy user.
    static func periodCosts(from trend: DailyTrend) -> PeriodCosts {
        let fm = FileManager.default
        var out = PeriodCosts()
        if fm.fileExists(atPath: claudeDir.path) {
            out.claudeUSD7 = trend.claudeCostUSD.suffix(7).reduce(0, +)
            out.claudeUSD30 = trend.claudeCostUSD.reduce(0, +)
        }
        if fm.fileExists(atPath: codexDir.path) {
            out.codexUSD7 = trend.codexCostUSD.suffix(7).reduce(0, +)
            out.codexUSD30 = trend.codexCostUSD.reduce(0, +)
        }
        if fm.fileExists(atPath: antigravityDir.path) {
            out.antigravityUSD7 = trend.antigravityCostUSD.suffix(7).reduce(0, +)
            out.antigravityUSD30 = trend.antigravityCostUSD.reduce(0, +)
        }
        return out
    }

    /// Per-day totals for the trailing `days` days (oldest first, today
    /// last), for the Analytics trend chart. Same throttling concern as
    /// `periodCosts()` — scans up to `days` days of logs.
    static func dailyTrend(days: Int) -> DailyTrend {
        var out = DailyTrend()
        let todayStart = calendar.startOfDay(for: Date())
        out.days = (0..<days).map { todayStart.addingTimeInterval(-Double(days - 1 - $0) * 86400) }

        let fm = FileManager.default
        // Stat-only fingerprint of everything this scan would read. Logs older
        // than today never change, so on an idle machine this makes the whole
        // month-wide rescan a no-op instead of re-reading and re-parsing every
        // file on each slow tick.
        let fingerprint = "\(todayStart.timeIntervalSince1970)|"
            + filesFingerprint(filesModified(under: claudeDir, ext: "jsonl", sinceDaysAgo: days))
            + "#" + filesFingerprint(filesModified(under: codexDir, ext: "jsonl", sinceDaysAgo: days))
            + "#" + fileStamp(antigravityDir.appendingPathComponent("history.jsonl"))
        trendCacheLock.lock()
        if let cached = dailyTrendCache, cached.days == days, cached.fingerprint == fingerprint {
            trendCacheLock.unlock()
            return cached.value
        }
        trendCacheLock.unlock()

        if fm.fileExists(atPath: claudeDir.path) {
            let (tokens, cost) = claudeDailyBuckets(days: days)
            out.claudeTokens = tokens
            out.claudeCostUSD = cost
        } else {
            out.claudeTokens = Array(repeating: 0, count: days)
            out.claudeCostUSD = Array(repeating: 0, count: days)
        }
        if fm.fileExists(atPath: codexDir.path) {
            let (tokens, cost) = codexDailyBuckets(days: days)
            out.codexTokens = tokens
            out.codexCostUSD = cost
        } else {
            out.codexTokens = Array(repeating: 0, count: days)
            out.codexCostUSD = Array(repeating: 0, count: days)
        }
        if fm.fileExists(atPath: antigravityDir.path) {
            let (prompts, cost) = antigravityDailyBuckets(days: days)
            out.antigravityPrompts = prompts
            out.antigravityCostUSD = cost
        } else {
            out.antigravityPrompts = Array(repeating: 0, count: days)
            out.antigravityCostUSD = Array(repeating: 0, count: days)
        }

        // Persist whatever this pass just measured while the source logs
        // still have it, then fill in any day the scan came back empty for
        // with whatever was captured before that day's log aged out and got
        // pruned. See DailyHistoryStore for why this exists at all.
        DailyHistoryStore.record(out)
        let filled = DailyHistoryStore.backfill(out)
        trendCacheLock.lock()
        dailyTrendCache = (fingerprint, days, filled)
        trendCacheLock.unlock()
        return filled
    }

    /// Index into a `days`-length bucket array (0 = oldest, `days - 1` =
    /// today) for a given ISO timestamp, or nil if it falls outside range.
    private static func dailyBucketIndex(_ isoTimestamp: String, days: Int, todayStart: Date) -> Int? {
        guard let date = parseISO(isoTimestamp) else { return nil }
        return dailyBucketIndex(date, days: days, todayStart: todayStart)
    }

    private static func dailyBucketIndex(_ date: Date, days: Int, todayStart: Date) -> Int? {
        let dayStart = calendar.startOfDay(for: date)
        let offsetFromToday = calendar.dateComponents([.day], from: dayStart, to: todayStart).day ?? 0
        let index = days - 1 - offsetFromToday
        return (0..<days).contains(index) ? index : nil
    }

    private static func claudeDailyBuckets(days: Int) -> (tokens: [Int], costUSD: [Double]) {
        // Same per-file cache the today-scan uses, so the month-wide pass only
        // parses files it has never seen (and the bytes appended since).
        var perKey: [String: ClaudeRequestRecord] = [:]
        for entry in claudeFileStates(for: filesModified(under: claudeDir, ext: "jsonl", sinceDaysAgo: days)) {
            for (key, record) in entry.state.requests
            where record.hasUsage && isWithinLastDays(isoTimestamp: record.timestamp, days: days) {
                perKey[key] = record
            }
        }
        var tokenBuckets = Array(repeating: 0, count: days)
        var costBuckets = Array(repeating: 0.0, count: days)
        let todayStart = calendar.startOfDay(for: Date())
        for (_, e) in perKey {
            guard let date = e.date,
                  let index = dailyBucketIndex(date, days: days, todayStart: todayStart)
            else { continue }
            tokenBuckets[index] += e.tokenTotal
            costBuckets[index] += e.costUSD
        }
        return (tokenBuckets, costBuckets)
    }

    private static func codexDailyBuckets(days: Int) -> (tokens: [Int], costUSD: [Double]) {
        var tokenBuckets = Array(repeating: 0, count: days)
        var costBuckets = Array(repeating: 0.0, count: days)
        let todayStart = calendar.startOfDay(for: Date())
        for entry in codexFileStates(for: filesModified(under: codexDir, ext: "jsonl", sinceDaysAgo: days)) {
            guard let t = entry.state.lastTotals,
                  let ts = entry.state.lastTS,
                  isWithinLastDays(isoTimestamp: ts, days: days),
                  let index = dailyBucketIndex(ts, days: days, todayStart: todayStart)
            else { continue }
            var usage = CodexUsage()
            usage.inputTokens = t["input_tokens"] ?? 0
            usage.cachedInputTokens = t["cached_input_tokens"] ?? 0
            usage.outputTokens = t["output_tokens"] ?? 0
            usage.reasoningTokens = t["reasoning_output_tokens"] ?? 0
            usage.totalTokens = t["total_tokens"] ?? 0
            tokenBuckets[index] += usage.totalTokens
            costBuckets[index] += Pricing.codexCostUSD(usage)
        }
        return (tokenBuckets, costBuckets)
    }

    private static func antigravityDailyBuckets(days: Int) -> (prompts: [Int], costUSD: [Double]) {
        var promptBuckets = Array(repeating: 0, count: days)
        let historyFile = antigravityDir.appendingPathComponent("history.jsonl")
        guard FileManager.default.fileExists(atPath: historyFile.path) else {
            return (promptBuckets, Array(repeating: 0, count: days))
        }
        let todayStart = calendar.startOfDay(for: Date())
        forEachLine(of: historyFile) { line in
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let timestampMS = obj["timestamp"] as? Double
            else { return }
            let date = Date(timeIntervalSince1970: timestampMS / 1000.0)
            let dayStart = calendar.startOfDay(for: date)
            let offsetFromToday = calendar.dateComponents([.day], from: dayStart, to: todayStart).day ?? 0
            let index = days - 1 - offsetFromToday
            guard (0..<days).contains(index) else { return }
            promptBuckets[index] += 1
        }
        let costBuckets = promptBuckets.map { count -> Double in
            var u = AntigravityUsage()
            u.totalPrompts = count
            return Pricing.antigravityCostUSD(u)
        }
        return (promptBuckets, costBuckets)
    }

    /// Antigravity stores quota responses in different cache locations across
    /// CLI versions. Read only JSON responses that contain the stable
    /// remainingFraction/resetTime pair, and classify the two windows by the
    /// time until reset (short = 5-hour, long = weekly).
    static let antigravityQuotaRoots: [URL] = [
        antigravityDir.appendingPathComponent("cache"),
        antigravityDir.appendingPathComponent("state"),
        antigravityDir
    ]

    /// Both windows come out of one pass. Reading and JSON-parsing every
    /// cached quota file twice per refresh — once asking for the short window
    /// and once for the long one — was pure duplicated work over identical
    /// bytes.
    private static func readAntigravityLimits() -> (short: (window: LimitWindow, asOf: Date)?, long: (window: LimitWindow, asOf: Date)?) {
        let fm = FileManager.default
        var newestShort: (window: LimitWindow, modified: Date)?
        var newestLong: (window: LimitWindow, modified: Date)?
        for root in antigravityQuotaRoots {
            guard let en = fm.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey]) else { continue }
            for case let url as URL in en {
                guard url.pathExtension == "json",
                      let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                      values.isRegularFile == true,
                      let modified = values.contentModificationDate,
                      let data = try? Data(contentsOf: url),
                      let object = try? JSONSerialization.jsonObject(with: data)
                else { continue }
                for candidate in quotaCandidates(in: object) {
                    // Classify by the window's length at capture time (reset
                    // minus the snapshot's own mtime), not by time-until-reset
                    // from now. A window classified relative to "now" drops
                    // out of both buckets the instant it rolls over but before
                    // Antigravity writes a fresh cache file, making the row
                    // vanish from the menu even though today's usage exists.
                    let duration = candidate.reset.timeIntervalSince(modified)
                    let isShort = duration > 0 && duration <= 12 * 3600
                    let window = LimitWindow(usedPercent: max(0, min(100, (1 - candidate.remaining) * 100)), resetsAt: candidate.reset)
                    if isShort {
                        if newestShort == nil || modified > newestShort!.modified { newestShort = (window, modified) }
                    } else {
                        if newestLong == nil || modified > newestLong!.modified { newestLong = (window, modified) }
                    }
                }
            }
        }
        return (newestShort.map { ($0.window, $0.modified) }, newestLong.map { ($0.window, $0.modified) })
    }

    private static func quotaCandidates(in object: Any) -> [(remaining: Double, reset: Date)] {
        var result: [(Double, Date)] = []
        func walk(_ value: Any) {
            if let dict = value as? [String: Any] {
                if let fraction = (dict["remainingFraction"] as? Double) ?? (dict["remainingFraction"] as? Int).map(Double.init),
                   let resetString = dict["resetTime"] as? String,
                   let reset = parseISO(resetString) ?? ISO8601DateFormatter().date(from: resetString),
                   fraction >= 0, fraction <= 1 {
                    result.append((fraction, reset))
                }
                dict.values.forEach(walk)
            } else if let array = value as? [Any] {
                array.forEach(walk)
            }
        }
        walk(object)
        return result
    }

    /// Only the tail is read: the markers below are appended as the stream
    /// starts and finishes, so the most recent pair is always at the end of
    /// the log, and `String.range(of:)` is Unicode-correct (i.e. slow) enough
    /// that running it four times over a whole multi-megabyte log every
    /// refresh was worth avoiding.
    private static let antigravityLogTailBytes = 256 * 1024

    private static func antigravityIsWorking() -> Bool {
        let logs = antigravityDir.appendingPathComponent("log")
        guard let files = try? FileManager.default.contentsOfDirectory(at: logs, includingPropertiesForKeys: [.contentModificationDateKey], options: .skipsHiddenFiles),
              let file = files.filter({ $0.pathExtension == "log" }).max(by: { modifiedDate($0) < modifiedDate($1) }),
              let data = tail(of: file, maxBytes: antigravityLogTailBytes),
              let text = String(data: data, encoding: .utf8)
        else { return false }
        let started = text.range(of: "Starting conversation update stream", options: .backwards)
            ?? text.range(of: "HandleUserInput called", options: .backwards)
        let finished = text.range(of: "Stream completed", options: .backwards)
            ?? text.range(of: "Stream goroutine exited", options: .backwards)
        return started != nil && (finished == nil || started!.lowerBound > finished!.lowerBound)
    }

    private static func modifiedDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }
}
