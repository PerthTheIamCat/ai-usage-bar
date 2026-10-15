import Foundation
import SwiftUI
import Combine

/// Evolution stage of the companion based on lifetime tokens burned.
enum EvolutionStage: Int, CaseIterable, Identifiable, Comparable {
    case seedling = 1     // 0 - 250K
    case apprentice = 2   // 250K - 2M
    case master = 3       // 2M - 15M
    case legend = 4       // 15M+

    var id: Int { rawValue }

    static func < (lhs: EvolutionStage, rhs: EvolutionStage) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var title: String {
        switch self {
        case .seedling: return "Seedling Coder"
        case .apprentice: return "Apprentice Coder"
        case .master: return "Master Artisan"
        case .legend: return "Stardew Legend"
        }
    }

    var badgeIcon: String {
        switch self {
        case .seedling: return "🌱"
        case .apprentice: return "🌿"
        case .master: return "🌾"
        case .legend: return "👑"
        }
    }

    var requiredTokens: Int {
        switch self {
        case .seedling: return 0
        case .apprentice: return 250_000
        case .master: return 2_000_000
        case .legend: return 15_000_000
        }
    }

    var nextStageTargetTokens: Int? {
        switch self {
        case .seedling: return 250_000
        case .apprentice: return 2_000_000
        case .master: return 15_000_000
        case .legend: return nil
        }
    }

    static func stage(for tokens: Int) -> EvolutionStage {
        if tokens >= EvolutionStage.legend.requiredTokens {
            return .legend
        } else if tokens >= EvolutionStage.master.requiredTokens {
            return .master
        } else if tokens >= EvolutionStage.apprentice.requiredTokens {
            return .apprentice
        } else {
            return .seedling
        }
    }
}

/// A retro 8-bit style achievement trophy.
struct Achievement: Identifiable, Equatable {
    let id: String
    let title: String
    let icon: String
    let description: String
    var unlockedAt: Date?

    var isUnlocked: Bool {
        unlockedAt != nil
    }
}

/// Manages lifetime tokens, companion growth/evolution stages, and achievement unlocks.
final class ProgressionStore: ObservableObject {
    static let shared = ProgressionStore()

    private enum Keys {
        static let unlockedAchievements = "unlockedAchievements"
        static let lastKnownLifetimeTokens = "lastKnownLifetimeTokens"
    }

    @Published var lifetimeTokens: Int = 0
    @Published var currentStage: EvolutionStage = .seedling
    @Published var progressToNextStage: Double = 0.0
    @Published var unlockedAchievements: [String: Date] = [:]

    // Catalog of all achievements
    static let catalog: [Achievement] = [
        Achievement(id: "first_sprout", title: "First Sprout", icon: "🌱", description: "Consume your first 1,000 tokens."),
        Achievement(id: "token_millionaire", title: "Token Millionaire", icon: "🚀", description: "Burn 1,000,000 cumulative tokens."),
        Achievement(id: "ten_millionaire", title: "Ten-Millionaire", icon: "💎", description: "Reach 10,000,000 lifetime tokens."),
        Achievement(id: "speed_demon", title: "Speed Demon", icon: "⚡️", description: "Generate > 50,000 tokens in a single active hour."),
        Achievement(id: "midnight_oil", title: "Midnight Oil", icon: "🌙", description: "Code with AI between 12:00 AM and 5:00 AM."),
        Achievement(id: "security_first", title: "Security First", icon: "🛡️", description: "Run a security audit subagent check."),
        Achievement(id: "duckling_parade", title: "Duckling Parade", icon: "🐣", description: "Have subagents parading alongside your companion."),
        Achievement(id: "frugal_genius", title: "Frugal Genius", icon: "💰", description: "Save over $5.00 in a single day via prompt caching."),
        Achievement(id: "edge_dancer", title: "Edge Dancer", icon: "🧘", description: "Survive a rate limit window below 5% without lockout."),
        Achievement(id: "grandmaster", title: "Grandmaster Hacker", icon: "👑", description: "Ascend to Stage 4 Legend (15M+ tokens).")
    ]

    private init() {
        loadAchievements()
        recalculateLifetimeTokens(liveSnapshotTokens: 0)
    }

    private func loadAchievements() {
        let d = UserDefaults.standard
        if let stored = d.dictionary(forKey: Keys.unlockedAchievements) as? [String: Date] {
            unlockedAchievements = stored
        }
    }

    private func saveAchievements() {
        UserDefaults.standard.set(unlockedAchievements, forKey: Keys.unlockedAchievements)
    }

    /// Calculates total lifetime tokens from historical DailyHistoryStore + today's active tokens.
    func recalculateLifetimeTokens(liveSnapshotTokens: Int) {
        // Read historical tokens from daily history
        let fileURL = DailyHistoryStore.defaultFileURL
        var historicalTokens = 0
        if let data = try? Data(contentsOf: fileURL),
           let store = try? JSONDecoder().decode([String: DailyHistoryStore.DayEntry].self, from: data) {
            for entry in store.values {
                let antigravityTokens = entry.antigravityPrompts * 2300 // estimated tokens per prompt
                historicalTokens += entry.claudeTokens + entry.codexTokens + antigravityTokens
            }
        }

        let total = max(historicalTokens, liveSnapshotTokens)
        lifetimeTokens = total

        // Evaluate stage
        let newStage = EvolutionStage.stage(for: total)
        if newStage > currentStage {
            let oldStage = currentStage
            currentStage = newStage
            onLevelUp(from: oldStage, to: newStage)
        } else {
            currentStage = newStage
        }

        // Calculate progress to next stage
        if let target = currentStage.nextStageTargetTokens {
            let base = currentStage.requiredTokens
            let currentInStage = total - base
            let neededInStage = target - base
            progressToNextStage = min(1.0, max(0.0, Double(currentInStage) / Double(neededInStage)))
        } else {
            progressToNextStage = 1.0
        }
    }

    /// Evaluates all achievement criteria against the current snapshot and lifetime stats.
    func evaluate(snapshot: UsageSnapshot) {
        let todayTokens = (snapshot.claude?.total ?? 0)
            + (snapshot.codex?.totalTokens ?? 0)
            + ((snapshot.antigravity?.totalPrompts ?? 0) * 2300)

        recalculateLifetimeTokens(liveSnapshotTokens: todayTokens)

        // 1. First Sprout (>= 1,000 tokens)
        if lifetimeTokens >= 1_000 {
            unlock("first_sprout")
        }

        // 2. Token Millionaire (>= 1,000,000 tokens)
        if lifetimeTokens >= 1_000_000 {
            unlock("token_millionaire")
        }

        // 3. Ten-Millionaire (>= 10,000,000 tokens)
        if lifetimeTokens >= 10_000_000 {
            unlock("ten_millionaire")
        }

        // 4. Grandmaster Hacker (Stage 4)
        if currentStage == .legend {
            unlock("grandmaster")
        }

        // 5. Speed Demon (> 50,000 in an hour)
        if snapshot.hourlyUsage.claude.contains(where: { $0 > 50_000 })
            || snapshot.hourlyUsage.codex.contains(where: { $0 > 50_000 }) {
            unlock("speed_demon")
        }

        // 6. Midnight Oil (between midnight and 5am)
        let hour = Calendar.current.component(.hour, from: Date())
        if (hour >= 0 && hour < 5) && todayTokens > 100 {
            unlock("midnight_oil")
        }

        // 7. Security First (subagent running)
        if snapshot.activeSubagents.contains(where: { $0.role.lowercased().contains("audit") || $0.id.contains("audit") }) {
            unlock("security_first")
        }

        // 8. Duckling Parade (>= 2 subagents)
        if snapshot.activeSubagents.count >= 2 {
            unlock("duckling_parade")
        }

        // 9. Frugal Genius (cache savings > $5.00)
        let claudeCacheTokens = Double(snapshot.claude?.cacheReadTokens ?? 0)
        let cacheSavedUSD = (claudeCacheTokens * 2.7) / 1_000_000 // roughly $2.70 per MTok saved
        if cacheSavedUSD >= 5.0 {
            unlock("frugal_genius")
        }

        // 10. Edge Dancer (< 5% remaining and not locked out)
        if let fiveHour = snapshot.claudeLimits?.fiveHour, fiveHour.remainingPercent < 5.0, fiveHour.remainingPercent > 0 {
            unlock("edge_dancer")
        }
    }

    /// Unlock an achievement if not already unlocked
    func unlock(_ achievementID: String) {
        guard unlockedAchievements[achievementID] == nil else { return }
        let now = Date()
        unlockedAchievements[achievementID] = now
        saveAchievements()

        if let achievement = Self.catalog.first(where: { $0.id == achievementID }) {
            DispatchQueue.main.async {
                CompanionManager.shared.triggerAction(
                    .celebrating,
                    speechText: "🏆 Unlocked: [\(achievement.title)]!",
                    icon: achievement.icon
                )
            }
        }
    }

    private func onLevelUp(from old: EvolutionStage, to new: EvolutionStage) {
        DispatchQueue.main.async {
            CompanionManager.shared.triggerAction(
                .celebrating,
                speechText: "✨ EVOLVED to \(new.title)!",
                icon: new.badgeIcon
            )
        }
    }

    /// Returns achievements list merged with unlock timestamps.
    var achievementsList: [Achievement] {
        Self.catalog.map { item in
            var copy = item
            copy.unlockedAt = unlockedAchievements[item.id]
            return copy
        }
    }

    /// Test helper to simulate unlocking an achievement
    func simulateUnlockTest() {
        let locked = Self.catalog.filter { unlockedAchievements[$0.id] == nil }
        if let next = locked.first {
            unlock(next.id)
        } else if let first = Self.catalog.first {
            unlockedAchievements.removeValue(forKey: first.id)
            unlock(first.id)
        }
    }

    /// Test helper to simulate level up
    func simulateLevelUpTest() {
        let nextStageRaw = (currentStage.rawValue % EvolutionStage.allCases.count) + 1
        if let nextStage = EvolutionStage(rawValue: nextStageRaw) {
            let old = currentStage
            currentStage = nextStage
            onLevelUp(from: old, to: nextStage)
        }
    }
}
