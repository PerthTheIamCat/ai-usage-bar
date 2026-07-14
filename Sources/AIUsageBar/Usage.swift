import Foundation

struct ClaudeUsage {
    var inputTokens = 0
    var outputTokens = 0
    var cacheCreationTokens = 0
    var cacheReadTokens = 0
    var sessionCount = 0
    var lastModel: String?

    var total: Int { inputTokens + outputTokens + cacheCreationTokens + cacheReadTokens }
}

struct CodexUsage {
    var inputTokens = 0
    var cachedInputTokens = 0
    var outputTokens = 0
    var reasoningTokens = 0
    var totalTokens = 0
    var sessionCount = 0
}

struct UsageSnapshot {
    var claude: ClaudeUsage?  // nil = not detected
    var codex: CodexUsage?    // nil = not detected
    var claudeLimits: ClaudeLimits?
    var codexLimits: CodexLimits?
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
