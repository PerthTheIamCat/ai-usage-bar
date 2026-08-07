import Foundation
import Combine

/// Backs the popover's SwiftUI content. AppDelegate publishes into this on
/// every refresh tick instead of rebuilding an NSMenu from scratch.
final class UsageViewModel: ObservableObject {
    @Published var snapshot = UsageSnapshot()
    @Published var claudeLimitsProblem: String?
    @Published var lastGoodClaudeFetchedAt: Date?
    @Published var nextRefreshAt = Date()
    /// Short-lived progress text shown in the popover footer while a local
    /// usage snapshot is being assembled.
    @Published var loadingMessage: String?
    let refreshInterval: TimeInterval

    init(refreshInterval: TimeInterval) {
        self.refreshInterval = refreshInterval
    }
}
