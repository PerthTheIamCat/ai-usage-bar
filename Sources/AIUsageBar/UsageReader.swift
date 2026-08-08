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
    private static let sessionCacheLock = NSLock()
    private static var claudeSessionCache: (fingerprint: String, value: [SessionActivity])?
    private static var claudeTokenEventsCache: (fingerprint: String, value: [(date: Date, tokens: Int)])?
    private static var codexSessionCache: (fingerprint: String, value: [SessionActivity])?

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

    private static func localHour(_ date: Date) -> Int {
        Calendar.current.component(.hour, from: date)
    }

    private static func readHourlyUsage() -> HourlyUsage {
        var usage = HourlyUsage()

        // Claude assistant records contain the actual token usage for each
        // completed response.
        if FileManager.default.fileExists(atPath: claudeDir.path) {
            for file in filesModifiedToday(under: claudeDir, ext: "jsonl") {
                forEachLine(of: file) { line in
                    guard fastContains(line, "\"usage\""), fastContains(line, "\"assistant\""),
                          let data = line.data(using: .utf8),
                          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          (obj["type"] as? String) == "assistant",
                          let ts = obj["timestamp"] as? String,
                          isTodayLocal(isoTimestamp: ts),
                          let message = obj["message"] as? [String: Any],
                          let tokenUsage = message["usage"] as? [String: Any],
                          let date = parseISO(ts)
                    else { return }
                    let tokens = ["input_tokens", "output_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"]
                        .reduce(0) { $0 + ((tokenUsage[$1] as? Int) ?? 0) }
                    usage.claude[localHour(date)] += tokens
                }
            }
        }

        // Codex token_count events are cumulative per session; add only the
        // delta between consecutive readings to avoid counting the same turn
        // repeatedly.
        if FileManager.default.fileExists(atPath: codexDir.path) {
            for file in filesModifiedToday(under: codexDir, ext: "jsonl") {
                var previous = 0
                forEachLine(of: file) { line in
                    guard fastContains(line, "\"token_count\""),
                          let data = line.data(using: .utf8),
                          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
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
                guard let data = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let timestampMS = obj["timestamp"] as? Double
                else { return }
                let date = Date(timeIntervalSince1970: timestampMS / 1000.0)
                if Calendar.current.isDateInToday(date) { usage.antigravity[localHour(date)] += 1 }
            }
        }
        return usage
    }

    private static func filesModifiedToday(under root: URL, ext: String) -> [URL] {
        filesModified(under: root, ext: ext, sinceDaysAgo: 1)
    }

    /// Claude tokens recorded in `(from, to]`. Used to project a limit
    /// percentage forward between the Desktop app's occasional samples: the
    /// weighting Anthropic applies is not public, so the caller calibrates a
    /// percent-per-token rate from the user's own consecutive samples rather
    /// than assuming one.
    static func claudeTokens(from: Date, to: Date) -> Int {
        guard from < to else { return 0 }
        var total = 0
        for event in claudeTokenEvents() where event.date > from && event.date <= to {
            total += event.tokens
        }
        return total
    }

    /// Today's Claude token usage as timestamped events, from a single pass
    /// over the logs and cached until those files change. The projection
    /// calibrates across many intervals, and re-scanning the logs once per
    /// interval would put back exactly the cost the byte scanner removed.
    static func claudeTokenEvents() -> [(date: Date, tokens: Int)] {
        guard FileManager.default.fileExists(atPath: claudeDir.path) else { return [] }
        let files = filesModifiedToday(under: claudeDir, ext: "jsonl")
        let fingerprint = filesFingerprint(files)

        sessionCacheLock.lock()
        if let cached = claudeTokenEventsCache, cached.fingerprint == fingerprint {
            sessionCacheLock.unlock()
            return cached.value
        }
        sessionCacheLock.unlock()

        var events: [(date: Date, tokens: Int)] = []
        for file in files {
            forEachLine(of: file) { line in
                guard fastContains(line, "\"usage\""), fastContains(line, "\"assistant\""),
                      let data = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      (obj["type"] as? String) == "assistant",
                      let ts = obj["timestamp"] as? String,
                      let date = parseISO(ts),
                      let message = obj["message"] as? [String: Any],
                      let usage = message["usage"] as? [String: Any]
                else { return }
                let tokens = ["input_tokens", "output_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"]
                    .reduce(0) { $0 + ((usage[$1] as? Int) ?? 0) }
                if tokens > 0 { events.append((date: date, tokens: tokens)) }
            }
        }
        events.sort { $0.date < $1.date }

        sessionCacheLock.lock()
        claudeTokenEventsCache = (fingerprint, events)
        sessionCacheLock.unlock()
        return events
    }

    /// Files modified within the last `days` local days (1 = today only).
    /// Backs both the today-only readers and the 7-/30-day period aggregates.
    private static func filesModified(under root: URL, ext: String, sinceDaysAgo days: Int) -> [URL] {
        let fm = FileManager.default
        let cutoff = Calendar.current.startOfDay(for: Date()).addingTimeInterval(-Double(days - 1) * 86400)
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

    private static func forEachLine(of url: URL, _ body: (String) -> Void) {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let text = String(data: data, encoding: .utf8)
        else { return }
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            body(String(line))
        }
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
        guard let first = needle.first else { return true }
        guard haystack.count >= needle.count else { return false }
        let limit = haystack.count - needle.count
        var i = 0
        while i <= limit {
            if haystack[i] == first {
                var j = 1
                while j < needle.count, haystack[i + j] == needle[j] { j += 1 }
                if j == needle.count { return true }
            }
            i += 1
        }
        return false
    }

    private static let todayPrefixesUTC: [String] = {
        // Local "today" can span two UTC dates; timestamps in logs are UTC.
        let fmt = DateFormatter()
        // Log timestamps are Gregorian; the device locale may use another
        // calendar (e.g. Thai Buddhist year 2569), so pin the formatter.
        fmt.calendar = Calendar(identifier: .gregorian)
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.timeZone = TimeZone(identifier: "UTC")
        let start = Calendar.current.startOfDay(for: Date())
        let end = start.addingTimeInterval(24 * 3600 - 1)
        return Array(Set([fmt.string(from: start), fmt.string(from: end)]))
    }()

    private static func isTodayLocal(isoTimestamp: String) -> Bool {
        guard todayPrefixesUTC.contains(where: { isoTimestamp.hasPrefix($0) }) else { return false }
        guard let date = parseISO(isoTimestamp) else { return false }
        return Calendar.current.isDateInToday(date)
    }

    /// Generalized day-range check for the 7-day/30-day period aggregates.
    /// Unlike `isTodayLocal` this skips the UTC-prefix fast path — it only
    /// runs on the slow (30-minute) period-stats cadence, not every tick.
    private static func isWithinLastDays(isoTimestamp: String, days: Int) -> Bool {
        guard let date = parseISO(isoTimestamp) else { return false }
        let cutoff = Calendar.current.startOfDay(for: Date()).addingTimeInterval(-Double(days - 1) * 86400)
        return date >= cutoff
    }

    private static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlain = ISO8601DateFormatter()

    private static func parseISO(_ s: String) -> Date? {
        isoFrac.date(from: s) ?? isoPlain.date(from: s)
    }

    // MARK: - Claude Code

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
        // Dedupe streamed/rewritten entries: same request may appear multiple
        // times; keep the last occurrence per key.
        var perKey: [String: (input: Int, output: Int, cacheW: Int, cacheR: Int, model: String?, ts: String, skills: [String])] = [:]
        var sessions = Set<String>()

        for file in files {
            var fileMatched = false
            forEachLine(of: file) { line in
                guard fastContains(line, "\"usage\""), fastContains(line, "\"assistant\"") else { return }
                guard let data = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      (obj["type"] as? String) == "assistant",
                      let ts = obj["timestamp"] as? String,
                      isIncluded(ts),
                      let message = obj["message"] as? [String: Any],
                      let u = message["usage"] as? [String: Any]
                else { return }
                fileMatched = true
                let key = (obj["requestId"] as? String)
                    ?? (message["id"] as? String)
                    ?? (obj["uuid"] as? String)
                    ?? UUID().uuidString
                perKey[key] = (
                    input: u["input_tokens"] as? Int ?? 0,
                    output: u["output_tokens"] as? Int ?? 0,
                    cacheW: u["cache_creation_input_tokens"] as? Int ?? 0,
                    cacheR: u["cache_read_input_tokens"] as? Int ?? 0,
                    model: message["model"] as? String,
                    ts: ts,
                    skills: skillInvocations(in: message)
                )
            }
            if fileMatched { sessions.insert(file.path) }
        }

        var latestTS = ""
        for (_, e) in perKey {
            usage.inputTokens += e.input
            usage.outputTokens += e.output
            usage.cacheCreationTokens += e.cacheW
            usage.cacheReadTokens += e.cacheR
            let model = e.model ?? "unknown"
            var m = usage.perModel[model] ?? ModelTokens()
            m.input += e.input
            m.output += e.output
            m.cacheWrite += e.cacheW
            m.cacheRead += e.cacheR
            usage.perModel[model] = m
            for skill in e.skills {
                usage.skillCounts[skill, default: 0] += 1
                if let date = parseISO(e.ts) {
                    usage.skillLastUsed[skill] = max(usage.skillLastUsed[skill] ?? .distantPast, date)
                }
            }
            if e.ts > latestTS, let m = e.model {
                latestTS = e.ts
                usage.lastModel = m
            }
        }
        usage.sessionCount = sessions.count
        if includeSessions {
            usage.sessions = readClaudeSessions(matching: isIncluded, files: files)
        }
        return usage
    }

    private struct ClaudeSessionRequest {
        var inputTokens: Int
        var outputTokens: Int
        var cacheWrite: Int
        var cacheRead: Int
        var model: String?
        var timestamp: String
        var skills: [String]
        var tools: [String]
        var costUSD: Double
    }

    /// Reads only today's session metadata and tool names. Prompt and tool
    /// input content is deliberately ignored and never enters the model.
    private static func readClaudeSessions(
        matching isIncluded: (String) -> Bool,
        files: [URL]
    ) -> [SessionActivity] {
        let fingerprint = filesFingerprint(files)
        sessionCacheLock.lock()
        if let cached = claudeSessionCache, cached.fingerprint == fingerprint {
            sessionCacheLock.unlock()
            return cached.value
        }
        sessionCacheLock.unlock()

        var result: [SessionActivity] = []

        for file in files {
            let sessionID = file.deletingPathExtension().lastPathComponent
            var customName: String?
            var generatedName: String?
            var workspace: String?
            var requests: [String: ClaudeSessionRequest] = [:]

            forEachLine(of: file) { line in
                guard let data = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { return }

                // Claude stores session titles in lightweight metadata
                // records: `custom-title` when the user renamed the session,
                // `ai-title` for the automatic one. Both are titles rather
                // than prompt text. Read them independently of today's usage
                // filter so a session titled yesterday keeps its name when it
                // is active today, and keep them apart so a later automatic
                // title never overwrites a name the user chose.
                switch obj["type"] as? String {
                case "custom-title": customName = normalizedSessionName(obj["customTitle"]) ?? customName
                case "ai-title": generatedName = normalizedSessionName(obj["aiTitle"]) ?? generatedName
                default: break
                }
                if workspace == nil,
                   let cwd = obj["cwd"] as? String,
                   !cwd.isEmpty
                {
                    workspace = URL(fileURLWithPath: cwd).lastPathComponent
                }

                guard (obj["type"] as? String) == "assistant",
                      let timestamp = obj["timestamp"] as? String,
                      isIncluded(timestamp),
                      let message = obj["message"] as? [String: Any]
                else { return }

                let skills = skillInvocations(in: message)
                let tools = toolInvocations(in: message)
                let tokenUsage = message["usage"] as? [String: Any] ?? [:]
                guard message["usage"] is [String: Any] || !skills.isEmpty || !tools.isEmpty
                else { return }

                let key = (obj["requestId"] as? String)
                    ?? (message["id"] as? String)
                    ?? (obj["uuid"] as? String)
                    ?? UUID().uuidString
                requests[key] = ClaudeSessionRequest(
                    inputTokens: tokenUsage["input_tokens"] as? Int ?? 0,
                    outputTokens: tokenUsage["output_tokens"] as? Int ?? 0,
                    cacheWrite: tokenUsage["cache_creation_input_tokens"] as? Int ?? 0,
                    cacheRead: tokenUsage["cache_read_input_tokens"] as? Int ?? 0,
                    model: message["model"] as? String,
                    timestamp: timestamp,
                    skills: skills,
                    tools: tools,
                    costUSD: Pricing.claudeModelCostUSD(
                        ModelTokens(
                            input: tokenUsage["input_tokens"] as? Int ?? 0,
                            output: tokenUsage["output_tokens"] as? Int ?? 0,
                            cacheWrite: tokenUsage["cache_creation_input_tokens"] as? Int ?? 0,
                            cacheRead: tokenUsage["cache_read_input_tokens"] as? Int ?? 0),
                        model: message["model"] as? String ?? ""))
            }

            guard !requests.isEmpty else { continue }
            var session = SessionActivity(id: sessionID, name: customName ?? generatedName, workspace: workspace)
            for request in requests.values {
                let date = parseISO(request.timestamp)
                let isLatest: Bool
                if let date, let last = session.lastActivityAt {
                    isLatest = date >= last
                } else {
                    isLatest = true
                }
                if let date {
                    if session.startedAt == nil || date < session.startedAt! {
                        session.startedAt = date
                    }
                    if session.lastActivityAt == nil || date > session.lastActivityAt! {
                        session.lastActivityAt = date
                    }
                }
                session.tokenTotal += request.inputTokens + request.outputTokens
                    + request.cacheWrite + request.cacheRead
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

        let sorted = result.sorted {
            ($0.lastActivityAt ?? .distantPast) > ($1.lastActivityAt ?? .distantPast)
        }
        sessionCacheLock.lock()
        claudeSessionCache = (fingerprint, sorted)
        sessionCacheLock.unlock()
        return sorted
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
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey]
        ) else { return nil }
        var files: [(URL, Date)] = []
        for case let url as URL in en {
            guard url.pathExtension == "jsonl",
                  let v = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                  v.isRegularFile == true, let m = v.contentModificationDate, m >= cutoff
            else { continue }
            files.append((url, m))
        }
        for (url, _) in files.sorted(by: { $0.1 > $1.1 }) {
            var found: [String: Any]?
            var foundTS: String?
            forEachLine(of: url) { line in
                guard fastContains(line, "\"rate_limits\""), fastContains(line, "\"token_count\"") else { return }
                guard let data = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let payload = obj["payload"] as? [String: Any],
                      let rl = payload["rate_limits"] as? [String: Any]
                else { return }
                // Early events in a session carry null windows; keep only
                // readings that actually contain a populated window.
                guard rl["primary"] is [String: Any] || rl["secondary"] is [String: Any] else { return }
                found = rl  // keep last (newest) populated reading in file
                foundTS = obj["timestamp"] as? String
            }
            if let rl = found {
                var limits = parseCodexLimits(rl)
                limits.asOf = foundTS.flatMap(parseISO)
                return limits
            }
        }
        return nil
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
        for file in files {
            // total_token_usage is cumulative per session; last event wins.
            var last: [String: Int]?
            var lastTS: String?
            forEachLine(of: file) { line in
                guard fastContains(line, "\"token_count\"") else { return }
                guard let data = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let payload = obj["payload"] as? [String: Any],
                      (payload["type"] as? String) == "token_count",
                      let info = payload["info"] as? [String: Any],
                      let total = info["total_token_usage"] as? [String: Any]
                else { return }
                last = total.compactMapValues { $0 as? Int }
                lastTS = obj["timestamp"] as? String
            }
            guard let t = last, let ts = lastTS, isIncluded(ts) else { continue }
            usage.inputTokens += t["input_tokens"] ?? 0
            usage.cachedInputTokens += t["cached_input_tokens"] ?? 0
            usage.outputTokens += t["output_tokens"] ?? 0
            usage.reasoningTokens += t["reasoning_output_tokens"] ?? 0
            usage.totalTokens += t["total_tokens"] ?? 0
            usage.sessionCount += 1
        }
        if includeSessions {
            usage.sessions = readCodexSessions(matching: isIncluded, files: files)
        }
        return usage
    }

    /// Codex has emitted both `function_call` and `custom_tool_call` records
    /// across CLI/Desktop versions, so accept both shapes. Skill names are
    /// intentionally marked as inferred because Codex does not currently
    /// emit a dedicated skill invocation event in these local logs.
    private static func readCodexSessions(
        matching isIncluded: (String) -> Bool,
        files: [URL]
    ) -> [SessionActivity] {
        let fingerprint = filesFingerprint(files)
        sessionCacheLock.lock()
        if let cached = codexSessionCache, cached.fingerprint == fingerprint {
            sessionCacheLock.unlock()
            return cached.value
        }
        sessionCacheLock.unlock()

        var result: [SessionActivity] = []

        for file in files {
            var sessionID = file.deletingPathExtension().lastPathComponent
            var sessionName: String?
            var workspace: String?
            var model: String?
            var startedAt: Date?
            var lastActivityAt: Date?
            var lastTotals: [String: Int]?
            var tools: [String: Int] = [:]
            var skills: [String: Int] = [:]
            var inferredSkills: Set<String> = []

            forEachLine(of: file) { line in
                guard let data = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let timestamp = obj["timestamp"] as? String,
                      let date = parseISO(timestamp),
                      let payload = obj["payload"] as? [String: Any]
                else { return }

                if (obj["type"] as? String) == "session_meta" {
                    if let id = payload["id"] as? String, !id.isEmpty { sessionID = id }
                    if let cwd = payload["cwd"] as? String, !cwd.isEmpty {
                        workspace = URL(fileURLWithPath: cwd).lastPathComponent
                    }
                    model = payload["model"] as? String ?? model
                }

                if let name = codexSessionName(in: obj, payload: payload) {
                    sessionName = name
                }

                guard isIncluded(timestamp) else { return }
                if startedAt == nil || date < startedAt! { startedAt = date }
                if lastActivityAt == nil || date > lastActivityAt! { lastActivityAt = date }

                if (obj["type"] as? String) == "event_msg",
                   (payload["type"] as? String) == "token_count",
                   let info = payload["info"] as? [String: Any],
                   let total = info["total_token_usage"] as? [String: Any]
                {
                    lastTotals = total.compactMapValues { $0 as? Int }
                }

                guard (obj["type"] as? String) == "response_item",
                      let payloadType = payload["type"] as? String,
                      payloadType == "function_call" || payloadType == "custom_tool_call",
                      let name = payload["name"] as? String,
                      !name.isEmpty
                else { return }

                tools[name, default: 0] += 1
                let argumentText = toolArgumentText(from: payload)
                for skill in inferredCodexSkills(in: argumentText) {
                    skills[skill, default: 0] += 1
                    inferredSkills.insert(skill)
                }
            }

            guard lastTotals != nil || !tools.isEmpty else { continue }
            var tokenUsage = CodexUsage()
            tokenUsage.inputTokens = lastTotals?["input_tokens"] ?? 0
            tokenUsage.cachedInputTokens = lastTotals?["cached_input_tokens"] ?? 0
            tokenUsage.outputTokens = lastTotals?["output_tokens"] ?? 0
            tokenUsage.reasoningTokens = lastTotals?["reasoning_output_tokens"] ?? 0
            tokenUsage.totalTokens = lastTotals?["total_tokens"] ?? 0
            let estimatedCost = Pricing.codexCostUSD(tokenUsage)
            let toolInvocationCount = tools.values.reduce(0, +)
            let skillInvocationCount = skills.values.reduce(0, +)
            let toolCosts = Dictionary(uniqueKeysWithValues: tools.map { name, count in
                (name, estimatedCost * Double(count) / Double(max(1, toolInvocationCount)))
            })
            let skillCosts = Dictionary(uniqueKeysWithValues: skills.map { name, count in
                (name, estimatedCost * Double(count) / Double(max(1, skillInvocationCount)))
            })
            let session = SessionActivity(
                id: sessionID,
                name: sessionName,
                startedAt: startedAt,
                lastActivityAt: lastActivityAt,
                tokenTotal: tokenUsage.totalTokens,
                estimatedCostUSD: estimatedCost,
                model: model,
                workspace: workspace,
                skills: skills,
                skillCosts: skillCosts,
                inferredSkills: inferredSkills,
                tools: tools,
                toolCosts: toolCosts)
            result.append(session)
        }

        let sorted = result.sorted {
            ($0.lastActivityAt ?? .distantPast) > ($1.lastActivityAt ?? .distantPast)
        }
        sessionCacheLock.lock()
        codexSessionCache = (fingerprint, sorted)
        sessionCacheLock.unlock()
        return sorted
    }

    private static func codexSessionName(in object: [String: Any], payload: [String: Any]) -> String? {
        guard object["type"] as? String == "event_msg",
              payload["type"] as? String == "thread_name_updated"
        else { return nil }
        return normalizedSessionName(payload["thread_name"])
    }

    private static func filesFingerprint(_ files: [URL]) -> String {
        files.map { file in
            let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let modified = values?.contentModificationDate?.timeIntervalSince1970 ?? -1
            let size = values?.fileSize ?? -1
            return "\(file.path)|\(modified)|\(size)"
        }
        .joined(separator: "|")
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
        let five = readAntigravityLimit(shortWindow: true)
        let weekly = readAntigravityLimit(shortWindow: false)
        usage.fiveHour = five?.window
        usage.weekly = weekly?.window
        usage.asOf = [five?.asOf, weekly?.asOf].compactMap { $0 }.max()
        guard FileManager.default.fileExists(atPath: historyFile.path) else {
            usage.isWorking = antigravityIsWorking()
            return usage
        }
        var uniqueSessions = Set<String>()
        forEachLine(of: historyFile) { line in
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let timestampMS = obj["timestamp"] as? Double
            else { return }
            let date = Date(timeIntervalSince1970: timestampMS / 1000.0)
            if Calendar.current.isDateInToday(date) {
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
        let fm = FileManager.default
        let trend = dailyTrend(days: 30)
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
        let todayStart = Calendar.current.startOfDay(for: Date())
        out.days = (0..<days).map { todayStart.addingTimeInterval(-Double(days - 1 - $0) * 86400) }

        let fm = FileManager.default
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
        return DailyHistoryStore.backfill(out)
    }

    /// Index into a `days`-length bucket array (0 = oldest, `days - 1` =
    /// today) for a given ISO timestamp, or nil if it falls outside range.
    private static func dailyBucketIndex(_ isoTimestamp: String, days: Int, todayStart: Date) -> Int? {
        guard let date = parseISO(isoTimestamp) else { return nil }
        let dayStart = Calendar.current.startOfDay(for: date)
        let offsetFromToday = Calendar.current.dateComponents([.day], from: dayStart, to: todayStart).day ?? 0
        let index = days - 1 - offsetFromToday
        return (0..<days).contains(index) ? index : nil
    }

    private static func claudeDailyBuckets(days: Int) -> (tokens: [Int], costUSD: [Double]) {
        let files = filesModified(under: claudeDir, ext: "jsonl", sinceDaysAgo: days)
        var perKey: [String: (tokens: ModelTokens, model: String?, ts: String)] = [:]
        for file in files {
            forEachLine(of: file) { line in
                guard fastContains(line, "\"usage\""), fastContains(line, "\"assistant\"") else { return }
                guard let data = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      (obj["type"] as? String) == "assistant",
                      let ts = obj["timestamp"] as? String,
                      isWithinLastDays(isoTimestamp: ts, days: days),
                      let message = obj["message"] as? [String: Any],
                      let u = message["usage"] as? [String: Any]
                else { return }
                let key = (obj["requestId"] as? String) ?? (message["id"] as? String) ?? (obj["uuid"] as? String) ?? UUID().uuidString
                let tokens = ModelTokens(
                    input: u["input_tokens"] as? Int ?? 0,
                    output: u["output_tokens"] as? Int ?? 0,
                    cacheWrite: u["cache_creation_input_tokens"] as? Int ?? 0,
                    cacheRead: u["cache_read_input_tokens"] as? Int ?? 0
                )
                perKey[key] = (tokens, message["model"] as? String, ts)
            }
        }
        var tokenBuckets = Array(repeating: 0, count: days)
        var costBuckets = Array(repeating: 0.0, count: days)
        let todayStart = Calendar.current.startOfDay(for: Date())
        for (_, e) in perKey {
            guard let index = dailyBucketIndex(e.ts, days: days, todayStart: todayStart) else { continue }
            tokenBuckets[index] += e.tokens.input + e.tokens.output + e.tokens.cacheWrite + e.tokens.cacheRead
            costBuckets[index] += Pricing.claudeModelCostUSD(e.tokens, model: e.model ?? "")
        }
        return (tokenBuckets, costBuckets)
    }

    private static func codexDailyBuckets(days: Int) -> (tokens: [Int], costUSD: [Double]) {
        var tokenBuckets = Array(repeating: 0, count: days)
        var costBuckets = Array(repeating: 0.0, count: days)
        let todayStart = Calendar.current.startOfDay(for: Date())
        for file in filesModified(under: codexDir, ext: "jsonl", sinceDaysAgo: days) {
            // total_token_usage is cumulative per session; last event wins.
            var last: [String: Int]?
            var lastTS: String?
            forEachLine(of: file) { line in
                guard fastContains(line, "\"token_count\"") else { return }
                guard let data = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let payload = obj["payload"] as? [String: Any],
                      (payload["type"] as? String) == "token_count",
                      let info = payload["info"] as? [String: Any],
                      let total = info["total_token_usage"] as? [String: Any]
                else { return }
                last = total.compactMapValues { $0 as? Int }
                lastTS = obj["timestamp"] as? String
            }
            guard let t = last, let ts = lastTS, isWithinLastDays(isoTimestamp: ts, days: days),
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
        let todayStart = Calendar.current.startOfDay(for: Date())
        forEachLine(of: historyFile) { line in
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let timestampMS = obj["timestamp"] as? Double
            else { return }
            let date = Date(timeIntervalSince1970: timestampMS / 1000.0)
            let dayStart = Calendar.current.startOfDay(for: date)
            let offsetFromToday = Calendar.current.dateComponents([.day], from: dayStart, to: todayStart).day ?? 0
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
    private static func readAntigravityLimit(shortWindow: Bool) -> (window: LimitWindow, asOf: Date)? {
        let fm = FileManager.default
        let roots = [
            antigravityDir.appendingPathComponent("cache"),
            antigravityDir.appendingPathComponent("state"),
            antigravityDir
        ]
        var newest: (window: LimitWindow, modified: Date)?
        for root in roots {
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
                    guard isShort == shortWindow else { continue }
                    let window = LimitWindow(usedPercent: max(0, min(100, (1 - candidate.remaining) * 100)), resetsAt: candidate.reset)
                    if newest == nil || modified > newest!.modified { newest = (window, modified) }
                }
            }
        }
        return newest.map { ($0.window, $0.modified) }
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

    private static func antigravityIsWorking() -> Bool {
        let logs = antigravityDir.appendingPathComponent("log")
        guard let files = try? FileManager.default.contentsOfDirectory(at: logs, includingPropertiesForKeys: [.contentModificationDateKey], options: .skipsHiddenFiles),
              let file = files.filter({ $0.pathExtension == "log" }).max(by: { modifiedDate($0) < modifiedDate($1) }),
              let data = try? Data(contentsOf: file), let text = String(data: data, encoding: .utf8)
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
