import Foundation

/// Captures Antigravity CLI and Desktop IDE quota payloads.
/// Supports live Connect RPC from the running Desktop app language_server,
/// CLI status-line bridge payloads, and local cached quota summaries.
enum AntigravityLimitsReader {
    static let statusLineSnapshotURL: URL = {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AIUsageBar", isDirectory: true)
            .appendingPathComponent("antigravity-statusline.json")
    }()

    static let quotaSummaryCacheURL: URL = {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AIUsageBar", isDirectory: true)
            .appendingPathComponent("antigravity-quota-summary.json")
    }()

    private static let staleAfter: TimeInterval = 30 * 60

    struct Snapshot: Equatable {
        var fiveHour: LimitWindow?
        var weekly: LimitWindow?
        var groups: [AntigravityModelGroup] = []
        var observedAt: Date

        static func == (lhs: Snapshot, rhs: Snapshot) -> Bool {
            lhs.observedAt == rhs.observedAt
                && lhs.fiveHour?.usedPercent == rhs.fiveHour?.usedPercent
                && lhs.fiveHour?.resetsAt == rhs.fiveHour?.resetsAt
                && lhs.weekly?.usedPercent == rhs.weekly?.usedPercent
                && lhs.weekly?.resetsAt == rhs.weekly?.resetsAt
                && lhs.groups == rhs.groups
        }
    }

    /// Parses both Connect RPC `groups` payloads and CLI snake_case `quota` payloads.
    static func parseStatusLinePayload(_ data: Data, observedAt: Date = Date()) -> Snapshot? {
        guard let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        // 1. Stored snapshot record (persisted by persistSnapshot)
        if payload["observed_at"] != nil || payload["five_hour_used"] != nil || payload["weekly_used"] != nil {
            if let snapshot = parseStoredRecord(payload, observedAt: observedAt) {
                return snapshot
            }
        }

        // 2. Connect RPC response containing model groups
        if let snapshot = parseConnectRPCResponse(payload, observedAt: observedAt) {
            return snapshot
        }

        // 3. Documented CLI quota object
        if let quota = payload["quota"] as? [String: Any] {
            return parseQuota(quota, observedAt: observedAt)
        }

        // 4. Stored snapshot fallback
        if let snapshot = parseStoredRecord(payload, observedAt: observedAt) {
            return snapshot
        }

        return nil
    }

    /// Entry point used by the Antigravity CLI status-line command. Persist
    /// derived percentages, reset timestamps, and model groups.
    @discardableResult
    static func captureStatusLineInput(_ data: Data) -> String {
        guard let snapshot = parseStatusLinePayload(data) else {
            return "Antigravity · waiting for quota"
        }
        persistSnapshot(snapshot, rawData: data)
        return statusLineText(snapshot)
    }

    static func fetch() -> Snapshot? {
        // 1. Prefer live Connect RPC from running Desktop App language_server
        if let live = fetchLiveQuota() {
            persistSnapshot(live.snapshot, rawData: live.rawData)
            return live.snapshot
        }

        // 2. Local cached quota summary (written by live probe or Chorus)
        if let data = try? Data(contentsOf: quotaSummaryCacheURL),
           let snapshot = parseStatusLinePayload(data) {
            return snapshot
        }

        let chorusSummary = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".chorus/cache/antigravity-quota-summary.json")
        if let data = try? Data(contentsOf: chorusSummary),
           let snapshot = parseStatusLinePayload(data) {
            return snapshot
        }

        // 3. StatusLine snapshot written by CLI bridge
        if let data = try? Data(contentsOf: statusLineSnapshotURL),
           let snapshot = parseStatusLinePayload(data) {
            return snapshot
        }

        return nil
    }

    static func isStale(_ snapshot: Snapshot, now: Date = Date()) -> Bool {
        now.timeIntervalSince(snapshot.observedAt) > staleAfter
    }

    /// Discovers running Antigravity Desktop language_server and queries Connect RPC.
    static func fetchLiveQuota() -> (snapshot: Snapshot, rawData: Data)? {
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-A", "-o", "pid,command"]
        let pipe = Pipe()
        ps.standardOutput = pipe
        guard (try? ps.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        ps.waitUntilExit()
        guard let output = String(data: data, encoding: .utf8) else { return nil }

        var targetPID: String?
        var csrfToken: String?
        for line in output.components(separatedBy: "\n") {
            if line.contains("language_server") && line.contains("--csrf_token") {
                let parts = line.split(whereSeparator: { $0.isWhitespace })
                if let pid = parts.first {
                    targetPID = String(pid)
                }
                if let range = line.range(of: "--csrf_token") {
                    let rest = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
                    if let token = rest.split(whereSeparator: { $0.isWhitespace }).first {
                        csrfToken = String(token)
                    }
                }
                break
            }
        }
        guard let pid = targetPID, let token = csrfToken else { return nil }

        let lsof = Process()
        lsof.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        lsof.arguments = ["-nP", "-p", pid]
        let lsofPipe = Pipe()
        lsof.standardOutput = lsofPipe
        guard (try? lsof.run()) != nil else { return nil }
        let lsofData = lsofPipe.fileHandleForReading.readDataToEndOfFile()
        lsof.waitUntilExit()
        guard let lsofOut = String(data: lsofData, encoding: .utf8) else { return nil }

        var ports: [Int] = []
        for line in lsofOut.components(separatedBy: "\n") {
            if line.contains("LISTEN") && line.contains("127.0.0.1:") {
                if let range = line.range(of: "127.0.0.1:") {
                    let rest = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
                    if let portStr = rest.split(whereSeparator: { !$0.isNumber }).first,
                       let p = Int(portStr) {
                        ports.append(p)
                    }
                }
            }
        }

        for port in ports {
            let curl = Process()
            curl.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
            curl.arguments = [
                "-k", "-s", "--max-time", "1",
                "-X", "POST",
                "https://127.0.0.1:\(port)/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary",
                "-H", "Content-Type: application/json",
                "-H", "x-codeium-csrf-token: \(token)",
                "-d", "{}"
            ]
            let curlPipe = Pipe()
            curl.standardOutput = curlPipe
            guard (try? curl.run()) != nil else { continue }
            let resData = curlPipe.fileHandleForReading.readDataToEndOfFile()
            curl.waitUntilExit()
            if let snapshot = parseStatusLinePayload(resData, observedAt: Date()) {
                return (snapshot, resData)
            }
        }
        return nil
    }

    private static func persistSnapshot(_ snapshot: Snapshot, rawData: Data? = nil) {
        let directory = statusLineSnapshotURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        if let raw = rawData, raw.count > 10 {
            try? raw.write(to: quotaSummaryCacheURL, options: .atomic)
        }

        var record: [String: Any] = [
            "observed_at": snapshot.observedAt.timeIntervalSince1970,
        ]
        if let fiveHour = snapshot.fiveHour {
            record["five_hour_used"] = fiveHour.usedPercent
            if let reset = fiveHour.resetsAt {
                record["five_hour_reset"] = reset.timeIntervalSince1970
            }
            if let desc = fiveHour.resetDescription {
                record["five_hour_desc"] = desc
            }
        }
        if let weekly = snapshot.weekly {
            record["weekly_used"] = weekly.usedPercent
            if let reset = weekly.resetsAt {
                record["weekly_reset"] = reset.timeIntervalSince1970
            }
            if let desc = weekly.resetDescription {
                record["weekly_desc"] = desc
            }
        }

        if !snapshot.groups.isEmpty {
            record["groups"] = snapshot.groups.map { g -> [String: Any] in
                var dict: [String: Any] = ["name": g.name]
                if let d = g.description { dict["description"] = d }
                if let w = g.weekly {
                    dict["weekly_used"] = w.usedPercent
                    if let r = w.resetsAt { dict["weekly_reset"] = r.timeIntervalSince1970 }
                    if let desc = w.resetDescription { dict["weekly_desc"] = desc }
                }
                if let f = g.fiveHour {
                    dict["five_hour_used"] = f.usedPercent
                    if let r = f.resetsAt { dict["five_hour_reset"] = r.timeIntervalSince1970 }
                    if let desc = f.resetDescription { dict["five_hour_desc"] = desc }
                }
                return dict
            }
        }

        if let encoded = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) {
            try? encoded.write(to: statusLineSnapshotURL, options: .atomic)
        }
    }

    private static func parseConnectRPCResponse(_ json: [String: Any], observedAt: Date) -> Snapshot? {
        let groupsArray: [[String: Any]]?
        if let resp = json["response"] as? [String: Any], let g = resp["groups"] as? [[String: Any]] {
            groupsArray = g
        } else if let g = json["groups"] as? [[String: Any]],
                  g.contains(where: { $0["displayName"] != nil || $0["buckets"] != nil }) {
            groupsArray = g
        } else {
            return nil
        }
        guard let groupsArray, !groupsArray.isEmpty else { return nil }

        var modelGroups: [AntigravityModelGroup] = []
        var primaryFiveHour: LimitWindow?
        var primaryWeekly: LimitWindow?

        for g in groupsArray {
            let name = g["displayName"] as? String ?? "Model Group"
            let desc = g["description"] as? String
            var groupWeekly: LimitWindow?
            var groupFiveHour: LimitWindow?

            if let buckets = g["buckets"] as? [[String: Any]] {
                for b in buckets {
                    guard let remFrac = number(b["remainingFraction"]) ?? number(b["remaining_fraction"]),
                          (0...1).contains(remFrac)
                    else { continue }
                    let usedPct = (1.0 - remFrac) * 100.0
                    let resetTime: Date?
                    if let resetStr = b["resetTime"] as? String ?? b["reset_time"] as? String {
                        resetTime = UsageReader.parseISO(resetStr) ?? ISO8601DateFormatter().date(from: resetStr)
                    } else if let sec = number(b["reset_in_seconds"]) {
                        resetTime = observedAt.addingTimeInterval(sec)
                    } else {
                        resetTime = nil
                    }
                    let resetDesc = b["description"] as? String
                    let window = LimitWindow(
                        usedPercent: max(0, min(100, usedPct)),
                        resetsAt: resetTime,
                        resetDescription: resetDesc)

                    let windowKind = (b["window"] as? String ?? "").lowercased()
                    let bucketId = (b["bucketId"] as? String ?? "").lowercased()
                    if windowKind == "weekly" || bucketId.contains("weekly") || bucketId.contains("7d") {
                        groupWeekly = window
                    } else if windowKind == "5h" || windowKind == "five_hour" || bucketId.contains("5h") {
                        groupFiveHour = window
                    }
                }
            }

            if name.contains("Gemini") {
                if primaryFiveHour == nil { primaryFiveHour = groupFiveHour }
                if primaryWeekly == nil { primaryWeekly = groupWeekly }
            }

            modelGroups.append(AntigravityModelGroup(
                name: name,
                description: desc,
                weekly: groupWeekly,
                fiveHour: groupFiveHour))
        }

        let topFiveHour = primaryFiveHour ?? modelGroups.compactMap(\.fiveHour).first
        let topWeekly = primaryWeekly ?? modelGroups.compactMap(\.weekly).first
        guard topFiveHour != nil || topWeekly != nil || !modelGroups.isEmpty else { return nil }
        return Snapshot(fiveHour: topFiveHour, weekly: topWeekly, groups: modelGroups, observedAt: observedAt)
    }

    private static func parseStoredRecord(_ record: [String: Any], observedAt: Date) -> Snapshot? {
        let observedTime = number(record["observed_at"]).map { Date(timeIntervalSince1970: $0) } ?? observedAt
        var groups: [AntigravityModelGroup] = []
        if let rawGroups = record["groups"] as? [[String: Any]] {
            for g in rawGroups {
                guard let name = g["name"] as? String else { continue }
                let desc = g["description"] as? String
                let weekly = window(used: number(g["weekly_used"]), reset: number(g["weekly_reset"]), desc: g["weekly_desc"] as? String)
                let fiveHour = window(used: number(g["five_hour_used"]), reset: number(g["five_hour_reset"]), desc: g["five_hour_desc"] as? String)
                groups.append(AntigravityModelGroup(name: name, description: desc, weekly: weekly, fiveHour: fiveHour))
            }
        }

        let fiveHour = window(used: number(record["five_hour_used"]), reset: number(record["five_hour_reset"]), desc: record["five_hour_desc"] as? String)
            ?? groups.compactMap(\.fiveHour).first
        let weekly = window(used: number(record["weekly_used"]), reset: number(record["weekly_reset"]), desc: record["weekly_desc"] as? String)
            ?? groups.compactMap(\.weekly).first

        guard fiveHour != nil || weekly != nil || !groups.isEmpty else { return nil }
        return Snapshot(fiveHour: fiveHour, weekly: weekly, groups: groups, observedAt: observedTime)
    }

    private static func parseQuota(_ quota: [String: Any], observedAt: Date) -> Snapshot? {
        var fiveHourCandidates: [LimitWindow] = []
        var weeklyCandidates: [LimitWindow] = []

        var geminiFiveHour: LimitWindow?
        var geminiWeekly: LimitWindow?
        var thirdPartyFiveHour: LimitWindow?
        var thirdPartyWeekly: LimitWindow?

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
                resetsAt: reset,
                resetDescription: bucket["description"] as? String)

            let normalized = key.lowercased()
            let isWeekly = normalized.contains("week") || normalized.contains("7d")
            let isShort = normalized.contains("5h") || normalized.contains("session") || normalized.contains("short")
                || (reset != nil && reset!.timeIntervalSince(observedAt) > 0 && reset!.timeIntervalSince(observedAt) <= 12 * 3600)

            if normalized.contains("gemini") {
                if isWeekly { geminiWeekly = window }
                else if isShort { geminiFiveHour = window }
            } else if normalized.contains("3p") || normalized.contains("claude") || normalized.contains("gpt") {
                if isWeekly { thirdPartyWeekly = window }
                else if isShort { thirdPartyFiveHour = window }
            }

            if isWeekly {
                weeklyCandidates.append(window)
            } else if isShort {
                fiveHourCandidates.append(window)
            } else {
                weeklyCandidates.append(window)
            }
        }

        var groups: [AntigravityModelGroup] = []
        if geminiWeekly != nil || geminiFiveHour != nil {
            groups.append(AntigravityModelGroup(
                name: "Gemini Models",
                description: "Models within this group: Gemini Flash, Gemini Pro",
                weekly: geminiWeekly,
                fiveHour: geminiFiveHour))
        }
        if thirdPartyWeekly != nil || thirdPartyFiveHour != nil {
            groups.append(AntigravityModelGroup(
                name: "Claude and GPT models",
                description: "Models within this group: Claude Opus, Claude Sonnet, GPT-OSS",
                weekly: thirdPartyWeekly,
                fiveHour: thirdPartyFiveHour))
        }

        let fiveHour = geminiFiveHour ?? fiveHourCandidates.min { $0.usedPercent < $1.usedPercent }
        let weekly = geminiWeekly ?? weeklyCandidates.min { $0.usedPercent < $1.usedPercent }
        guard fiveHour != nil || weekly != nil else { return nil }

        if groups.isEmpty {
            groups.append(AntigravityModelGroup(
                name: "Gemini Models",
                description: nil,
                weekly: weekly,
                fiveHour: fiveHour))
        }

        return Snapshot(fiveHour: fiveHour, weekly: weekly, groups: groups, observedAt: observedAt)
    }

    private static func window(used: Double?, reset: Double?, desc: String? = nil) -> LimitWindow? {
        guard let used, used.isFinite else { return nil }
        return LimitWindow(
            usedPercent: max(0, min(100, used)),
            resetsAt: reset.map(Date.init(timeIntervalSince1970:)),
            resetDescription: desc)
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
