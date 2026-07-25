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
            lines.append("  Est. cost: \(formatUSD(usd)) (\(formatTHB(usd)))")
            lines.append("")
        }

        if let x = snap.codex {
            let usd = Pricing.codexCostUSD(x)
            totalUSD += usd
            lines.append("Codex")
            lines.append("  Total tokens: \(formatTokens(x.totalTokens)) (in \(x.inputTokens), cached \(x.cachedInputTokens), out \(x.outputTokens), reasoning \(x.reasoningTokens))")
            lines.append("  Sessions: \(x.sessionCount)")
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
}
