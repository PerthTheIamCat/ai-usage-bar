import Foundation

/// Plain-text summary of a snapshot, for the popover's "Copy Usage Report"
/// button — pasteable into an expense note, a Slack message, etc.
enum UsageReport {
    static func generate(_ snap: UsageSnapshot) -> String {
        var lines: [String] = []
        let df = DateFormatter()
        df.dateStyle = .medium
        lines.append("AI Usage Bar — Usage Report")
        lines.append(df.string(from: snap.updatedAt))
        lines.append("")

        var totalUSD = 0.0

        if let c = snap.claude {
            let usd = Pricing.claudeCostUSD(c)
            totalUSD += usd
            lines.append("Claude Code")
            lines.append("  Total tokens: \(formatTokens(c.total)) (in \(c.inputTokens), out \(c.outputTokens), cache write \(formatTokens(c.cacheCreationTokens)), cache read \(formatTokens(c.cacheReadTokens)))")
            lines.append("  Sessions: \(c.sessionCount)")
            if let model = c.lastModel { lines.append("  Last model: \(model)") }
            appendSessions(c.sessions, to: &lines)
            lines.append("  Est. cost: \(formatUSD(usd)) (\(formatTHB(usd)))")
            lines.append("")
        }

        if let x = snap.codex {
            let usd = Pricing.codexCostUSD(x)
            totalUSD += usd
            lines.append("Codex")
            lines.append("  Total tokens: \(formatTokens(x.totalTokens)) (in \(x.inputTokens), cached \(x.cachedInputTokens), out \(x.outputTokens), reasoning \(x.reasoningTokens))")
            lines.append("  Sessions: \(x.sessionCount)")
            appendSessions(x.sessions, to: &lines)
            lines.append("  Est. cost: \(formatUSD(usd)) (\(formatTHB(usd)))")
            lines.append("")
        }

        if let g = snap.antigravity {
            let usd = Pricing.antigravityCostUSD(g)
            totalUSD += usd
            lines.append("Antigravity")
            lines.append("  Prompts: \(g.totalPrompts) (\(g.sessionCount) sessions)")
            lines.append("  Est. cost: \(formatUSD(usd)) (\(formatTHB(usd)))")
            lines.append("")
        }

        if snap.claude == nil, snap.codex == nil, snap.antigravity == nil {
            lines.append("No AI CLI detected.")
            lines.append("")
        }

        lines.append("Total est. cost today: \(formatUSD(totalUSD)) (\(formatTHB(totalUSD)))")
        return lines.joined(separator: "\n")
    }

    private static func appendSessions(_ sessions: [SessionActivity], to lines: inout [String]) {
        guard !sessions.isEmpty else { return }
        let settings = AppSettings.shared
        lines.append("  Sessions today:")
        for session in sessions {
            let id = settings.showSessionIdentifiers ? String(session.id.prefix(12)) : "hidden"
            let time = session.lastActivityAt?.formatted(date: .omitted, time: .shortened) ?? "—"
            let workspace = settings.showSessionWorkspace ? session.workspace.map { " · \($0)" } ?? "" : ""
            lines.append("    \(id) · \(time)\(workspace) · \(formatTokens(session.tokenTotal)) tokens · \(formatUSD(session.estimatedCostUSD))")
            if !session.skills.isEmpty {
                let label = session.inferredSkills.isEmpty ? "Skills" : "Skills (inferred)"
                lines.append("      \(label): \(formatSessionActivityDetails(session.skills, costs: session.skillCosts))")
            }
            if !session.tools.isEmpty {
                lines.append("      Tools: \(formatSessionActivityDetails(session.tools, costs: session.toolCosts))")
            }
        }
    }

    static func generateJSON(_ snap: UsageSnapshot) -> String {
        var providers: [String: Any] = [:]
        if let claude = snap.claude { providers["claude"] = providerObject(claude.sessions) }
        if let codex = snap.codex { providers["codex"] = providerObject(codex.sessions) }
        let object: [String: Any] = [
            "updated_at": ISO8601DateFormatter().string(from: snap.updatedAt),
            "providers": providers,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8)
        else { return "{}" }
        return text
    }

    static func generateCSV(_ snap: UsageSnapshot) -> String {
        var lines = ["provider,session_id,last_activity,workspace,tokens,estimated_cost_usd,skills,tools"]
        if let claude = snap.claude { appendCSV("claude", sessions: claude.sessions, to: &lines) }
        if let codex = snap.codex { appendCSV("codex", sessions: codex.sessions, to: &lines) }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func providerObject(_ sessions: [SessionActivity]) -> [[String: Any]] {
        let settings = AppSettings.shared
        return sessions.map { session in
            var object: [String: Any] = [
                "session_id": settings.showSessionIdentifiers ? session.id : "hidden",
                "last_activity": session.lastActivityAt.map(ISO8601DateFormatter().string(from:)) ?? NSNull(),
                "tokens": session.tokenTotal,
                "estimated_cost_usd": session.estimatedCostUSD,
                "skills": session.skills,
                "tools": session.tools,
            ]
            if settings.showSessionWorkspace, let workspace = session.workspace {
                object["workspace"] = workspace
            }
            object["skill_costs_usd"] = session.skillCosts
            object["tool_costs_usd"] = session.toolCosts
            return object
        }
    }

    private static func appendCSV(_ provider: String, sessions: [SessionActivity], to lines: inout [String]) {
        let settings = AppSettings.shared
        for session in sessions {
            let id = settings.showSessionIdentifiers ? session.id : "hidden"
            let lastActivity = session.lastActivityAt.map { ISO8601DateFormatter().string(from: $0) } ?? ""
            let workspace = settings.showSessionWorkspace ? session.workspace ?? "" : ""
            lines.append([
                provider,
                id,
                lastActivity,
                workspace,
                String(session.tokenTotal),
                String(format: "%.6f", session.estimatedCostUSD),
                formatSessionActivityDetails(session.skills, costs: session.skillCosts),
                formatSessionActivityDetails(session.tools, costs: session.toolCosts),
            ].map(csvField).joined(separator: ","))
        }
    }

    private static func csvField(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }
}
