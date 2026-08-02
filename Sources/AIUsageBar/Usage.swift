import Foundation

/// Token counts for a single model, used for per-model cost pricing.
struct ModelTokens {
    var input = 0
    var output = 0
    var cacheWrite = 0
    var cacheRead = 0
}

/// A privacy-preserving summary of one local CLI session. It intentionally
/// stores names/counts and timestamps, not prompt, response, or tool input
/// content.
struct SessionActivity: Identifiable {
    let id: String
    var startedAt: Date?
    var lastActivityAt: Date?
    var tokenTotal = 0
    var estimatedCostUSD = 0.0
    var model: String?
    var workspace: String?
    var skills: [String: Int] = [:]
    var skillCosts: [String: Double] = [:]
    /// Codex skill names are inferred from tool arguments that reference a
    /// skill's SKILL.md; Claude records explicit Skill tool calls.
    var inferredSkills: Set<String> = []
    var tools: [String: Int] = [:]
    var toolCosts: [String: Double] = [:]

    init(id: String, startedAt: Date? = nil, lastActivityAt: Date? = nil,
         tokenTotal: Int = 0, estimatedCostUSD: Double = 0, model: String? = nil,
         workspace: String? = nil, skills: [String: Int] = [:],
         skillCosts: [String: Double] = [:], inferredSkills: Set<String> = [],
         tools: [String: Int] = [:], toolCosts: [String: Double] = [:]) {
        self.id = id
        self.startedAt = startedAt
        self.lastActivityAt = lastActivityAt
        self.tokenTotal = tokenTotal
        self.estimatedCostUSD = estimatedCostUSD
        self.model = model
        self.workspace = workspace
        self.skills = skills
        self.skillCosts = skillCosts
        self.inferredSkills = inferredSkills
        self.tools = tools
        self.toolCosts = toolCosts
    }
}

struct ClaudeUsage {
    var inputTokens = 0
    var outputTokens = 0
    var cacheCreationTokens = 0
    var cacheReadTokens = 0
    var sessionCount = 0
    var lastModel: String?
    /// Per-model breakdown of the same totals; keyed by model ID.
    var perModel: [String: ModelTokens] = [:]
    /// Invocation counts for Claude Code `Skill` tool calls, keyed by skill name.
    var skillCounts: [String: Int] = [:]
    /// Most recent invocation time per skill — pairs with `skillCounts` for
    /// a "what did I just use" view, not just an aggregate total.
    var skillLastUsed: [String: Date] = [:]
    /// Session-level names/counts parsed from today's local JSONL files.
    var sessions: [SessionActivity] = []

    var total: Int { inputTokens + outputTokens + cacheCreationTokens + cacheReadTokens }
}

struct CodexUsage {
    var inputTokens = 0
    var cachedInputTokens = 0
    var outputTokens = 0
    var reasoningTokens = 0
    var totalTokens = 0
    var sessionCount = 0
    /// Session-level tool calls parsed from today's local JSONL files.
    var sessions: [SessionActivity] = []
}

struct AntigravityUsage {
    var totalPrompts = 0
    var sessionCount = 0
    var fiveHour: LimitWindow?
    var weekly: LimitWindow?
    var isWorking = false
}

/// Today's activity by hour, split per provider so the chart can show which
/// tool a burst of activity actually came from instead of one blended line.
struct HourlyUsage {
    var claude = Array(repeating: 0, count: 24)
    var codex = Array(repeating: 0, count: 24)
    var antigravity = Array(repeating: 0, count: 24)

    /// Combined signal, for call sites that just want "activity" regardless
    /// of provider (e.g. peak-hour note).
    var values: [Int] { (0..<24).map { claude[$0] + codex[$0] + antigravity[$0] } }

    var total: Int { values.reduce(0, +) }
    var peakHour: Int? {
        guard let peak = values.max(), peak > 0 else { return nil }
        return values.firstIndex(of: peak)
    }
}

/// Per-day totals for the trailing `days.count` days (oldest first, today
/// last), for the Analytics trend chart. Every array is always exactly
/// `days.count` long — zero-filled for a day/provider with no activity —
/// so consumers can index without bounds-checking.
struct DailyTrend {
    var days: [Date] = []
    var claudeTokens: [Int] = []
    var claudeCostUSD: [Double] = []
    var codexTokens: [Int] = []
    var codexCostUSD: [Double] = []
    var antigravityPrompts: [Int] = []
    var antigravityCostUSD: [Double] = []

    var totalTokens: [Int] { (0..<days.count).map { claudeTokens[$0] + codexTokens[$0] } }
    var totalCostUSD: [Double] { (0..<days.count).map { claudeCostUSD[$0] + codexCostUSD[$0] + antigravityCostUSD[$0] } }

    /// Weekday (1 = Sunday...7 = Saturday, per `Calendar.component(.weekday:)`)
    /// with the highest summed token+prompt activity across this range, and
    /// its total. nil when there's no activity at all in range.
    var busiestWeekday: (weekday: Int, total: Int)? {
        var byWeekday: [Int: Int] = [:]
        let calendar = Calendar.current
        for (index, day) in days.enumerated() {
            let weekday = calendar.component(.weekday, from: day)
            byWeekday[weekday, default: 0] += totalTokens[index] + antigravityPrompts[index]
        }
        guard let best = byWeekday.max(by: { $0.value < $1.value }), best.value > 0 else { return nil }
        return (best.key, best.value)
    }
}

/// 7-/30-day cumulative estimated cost per provider (USD). Populated only
/// when a snapshot opts in via `includePeriodStats` — see UsageReader.swift.
struct PeriodCosts {
    var claudeUSD7: Double?
    var claudeUSD30: Double?
    var codexUSD7: Double?
    var codexUSD30: Double?
    var antigravityUSD7: Double?
    var antigravityUSD30: Double?
}

struct UsageSnapshot {
    var claude: ClaudeUsage?       // nil = not detected
    var codex: CodexUsage?         // nil = not detected
    var antigravity: AntigravityUsage? // nil = not detected
    var claudeLimits: ClaudeLimits?
    var codexLimits: CodexLimits?
    var hourlyUsage = HourlyUsage()
    var periodCosts: PeriodCosts?
    var dailyTrend: DailyTrend?
    var updatedAt = Date()
}

func formatTokens(_ n: Int) -> String {
    let v = Double(n)
    switch v {
    case ..<1_000: return "\(n)"
    case ..<1_000_000: return String(format: "%.1fK", v / 1_000)
    case ..<1_000_000_000: return String(format: "%.2fM", v / 1_000_000)
    default: return String(format: "%.2fB", v / 1_000_000_000)
    }
}

func formatSessionActivityCounts(_ counts: [String: Int]) -> String {
    counts
        .sorted { lhs, rhs in
            lhs.value == rhs.value ? lhs.key < rhs.key : lhs.value > rhs.value
        }
        .map { $0.value > 1 ? "\($0.key) ×\($0.value)" : $0.key }
        .joined(separator: ", ")
}

func formatSessionActivityDetails(_ counts: [String: Int], costs: [String: Double]) -> String {
    counts
        .sorted { lhs, rhs in
            lhs.value == rhs.value ? lhs.key < rhs.key : lhs.value > rhs.value
        }
        .map { item in
            let count = item.value > 1 ? " ×\(item.value)" : ""
            let cost = costs[item.key].map { " · ~\(formatUSD($0))" } ?? ""
            return item.key + count + cost
        }
        .joined(separator: ", ")
}
