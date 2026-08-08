import XCTest
@testable import AIUsageBar

final class BurnRateTrackerTests: XCTestCase {
    /// A fresh, uniquely-named suite per test so runs never see each other's
    /// data and never touch this Mac's real UserDefaults domain.
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "BurnRateTrackerTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    private func record(_ usedPercent: Double, minutesAgo: Double, now: Date) {
        BurnRateTracker.record(.claude, .fiveHour, usedPercent: usedPercent,
                                at: now.addingTimeInterval(-minutesAgo * 60), defaults: defaults)
    }

    func testLinearClimbProjectsCorrectDepletionTime() {
        let now = Date()
        // 10% -> 40% over 30 minutes = 1%/min. From 40% it should take
        // another 60 minutes to reach 100%.
        record(10, minutesAgo: 30, now: now)
        record(20, minutesAgo: 20, now: now)
        record(30, minutesAgo: 10, now: now)
        record(40, minutesAgo: 0, now: now)

        let farReset = now.addingTimeInterval(90 * 60)
        let forecast = BurnRateTracker.forecast(.claude, .fiveHour, resetsAt: farReset, now: now, defaults: defaults)
        XCTAssertNotNil(forecast)
        XCTAssertEqual(forecast!.percentPerMinute, 1.0, accuracy: 0.01)
        XCTAssertEqual(forecast!.etaToFull.timeIntervalSince(now), 60 * 60, accuracy: 5)
        XCTAssertTrue(forecast!.willDepleteBeforeReset, "60 min to full is well before a 90 min reset")
    }

    func testSamePaceDoesNotWarnWhenResetComesFirst() {
        let now = Date()
        record(10, minutesAgo: 30, now: now)
        record(20, minutesAgo: 20, now: now)
        record(30, minutesAgo: 10, now: now)
        record(40, minutesAgo: 0, now: now)

        // Same 60-minute depletion estimate as above, but the window resets
        // in 30 minutes — the reset wins, so this should not warn.
        let soonReset = now.addingTimeInterval(30 * 60)
        let forecast = BurnRateTracker.forecast(.claude, .fiveHour, resetsAt: soonReset, now: now, defaults: defaults)
        XCTAssertNotNil(forecast, "still climbing, so a forecast should exist")
        XCTAssertFalse(forecast!.willDepleteBeforeReset)
    }

    func testFlatNoiseNeverProjectsDepletion() {
        let now = Date()
        // Realistic sample noise around a steady ~42% — no real climb.
        record(42.0, minutesAgo: 30, now: now)
        record(41.5, minutesAgo: 20, now: now)
        record(42.3, minutesAgo: 10, now: now)
        record(42.1, minutesAgo: 0, now: now)

        let tightReset = now.addingTimeInterval(20 * 60)
        let forecast = BurnRateTracker.forecast(.claude, .fiveHour, resetsAt: tightReset, now: now, defaults: defaults)
        // Whether or not a forecast comes back, it must never claim
        // depletion from noise this small against a 20-minute reset.
        XCTAssertFalse(forecast?.willDepleteBeforeReset ?? false)
    }

    func testInsufficientSamplesReturnsNil() {
        let now = Date()
        record(10, minutesAgo: 5, now: now)
        record(20, minutesAgo: 0, now: now)
        // Only 2 samples — forecast requires at least 3.
        XCTAssertNil(BurnRateTracker.forecast(.claude, .fiveHour, resetsAt: nil, now: now, defaults: defaults))
    }

    func testNilResetNeverWarnsEvenWhileClimbing() {
        let now = Date()
        record(10, minutesAgo: 30, now: now)
        record(20, minutesAgo: 20, now: now)
        record(30, minutesAgo: 10, now: now)
        record(40, minutesAgo: 0, now: now)

        // The Claude Desktop source carries no reset time at all.
        let forecast = BurnRateTracker.forecast(.claude, .fiveHour, resetsAt: nil, now: now, defaults: defaults)
        XCTAssertNotNil(forecast)
        XCTAssertFalse(forecast!.willDepleteBeforeReset, "no known reset time means nothing to compare against")
    }

    func testBigDropClearsSamplesAsAWindowReset() {
        let now = Date()
        record(80, minutesAgo: 20, now: now)
        record(90, minutesAgo: 10, now: now)
        // Window rolled over — usage drops back down.
        record(5, minutesAgo: 0, now: now)

        // Only one sample should remain (the post-reset one), which is not
        // enough on its own to produce a forecast.
        XCTAssertNil(BurnRateTracker.forecast(.claude, .fiveHour, resetsAt: nil, now: now, defaults: defaults))
    }

    func testNearDuplicateSampleWithinThirtySecondsIsIgnored() {
        let now = Date()
        record(50, minutesAgo: 10, now: now)
        record(50.02, minutesAgo: 0.4, now: now) // 24s later, negligible change — should be skipped
        record(60, minutesAgo: 0, now: now)

        // If the near-duplicate had been kept, there would be 3 samples;
        // either way the fit should reflect the real 50->60 climb, not be
        // thrown off by a near-zero-duration segment.
        let forecast = BurnRateTracker.forecast(.claude, .fiveHour, resetsAt: now.addingTimeInterval(3600), now: now, defaults: defaults)
        XCTAssertNotNil(forecast)
        XCTAssertGreaterThan(forecast!.percentPerMinute, 0)
    }

    func testDifferentProvidersAndWindowsAreIndependent() {
        let now = Date()
        record(10, minutesAgo: 30, now: now) // .claude/.fiveHour, climbing
        record(20, minutesAgo: 20, now: now)
        record(30, minutesAgo: 10, now: now)
        record(40, minutesAgo: 0, now: now)

        // No samples ever recorded for Codex — must not see Claude's data.
        XCTAssertNil(BurnRateTracker.forecast(.codex, .fiveHour, resetsAt: nil, now: now, defaults: defaults))
        // No samples recorded for Claude's weekly window either.
        XCTAssertNil(BurnRateTracker.forecast(.claude, .weekly, resetsAt: nil, now: now, defaults: defaults))
    }
}
