import XCTest
@testable import AIUsageBar

final class ClaudeLimitsMedianTests: XCTestCase {
    func testEmptyReturnsNil() {
        XCTAssertNil(ClaudeLimitsReader.median([]))
    }

    func testSingleValue() {
        XCTAssertEqual(ClaudeLimitsReader.median([7]), 7)
    }

    func testOddCountReturnsMiddleValue() {
        XCTAssertEqual(ClaudeLimitsReader.median([3, 1, 2]), 2)
    }

    func testEvenCountAveragesTheTwoMiddleValues() {
        XCTAssertEqual(ClaudeLimitsReader.median([1, 2, 3, 4]), 2.5)
    }

    func testUnsortedInputIsSortedFirst() {
        XCTAssertEqual(ClaudeLimitsReader.median([9, 1, 5, 3, 7]), 5)
    }

    func testOutlierDoesNotDragTheMedianLikeItWouldAMean() {
        // One wildly unusual interval (a burst on a different model, or
        // usage from a device this Mac can't see) shouldn't move the
        // calibration much — the whole reason median was chosen over mean.
        let values = [1.0, 1.1, 0.9, 1.0, 50.0]
        XCTAssertEqual(ClaudeLimitsReader.median(values), 1.0)
    }
}

/// The five-hour projection calibrates against these weights rather than raw
/// token totals. Fitted against three weeks of readings Claude Desktop
/// recorded locally and validated on a held-out half (r² 0.89 versus 0.07 for
/// raw totals), so the shape is worth pinning: a change here silently
/// re-tunes every depletion warning the app shows.
final class LimitUnitsTests: XCTestCase {
    func testCachedReadsDoNotCountTowardTheWindow() {
        let cacheOnly = ModelTokens(input: 0, output: 0, cacheWrite: 0, cacheRead: 1_000_000)
        XCTAssertEqual(UsageReader.limitUnits(cacheOnly), 0)
    }

    func testOutputCountsTenTimesFreshInput() {
        let output = ModelTokens(input: 0, output: 1000, cacheWrite: 0, cacheRead: 0)
        let input = ModelTokens(input: 1000, output: 0, cacheWrite: 0, cacheRead: 0)
        let cacheWrite = ModelTokens(input: 0, output: 0, cacheWrite: 1000, cacheRead: 0)
        XCTAssertEqual(UsageReader.limitUnits(output), 1000)
        XCTAssertEqual(UsageReader.limitUnits(input), 100)
        XCTAssertEqual(UsageReader.limitUnits(cacheWrite), 100)
    }

    /// Cache writes carry the "fresh input" signal for the turns that are
    /// almost entirely cache creation. Dropping them was what made the old
    /// fit overshoot by up to 97 points, so a turn made only of cache writes
    /// must not read as free.
    func testATurnOfPureCacheWritesIsNotFree() {
        let record = ModelTokens(input: 0, output: 0, cacheWrite: 200_000, cacheRead: 0)
        XCTAssertGreaterThan(UsageReader.limitUnits(record), 0)
    }

    func testWeightingIgnoresTheCacheReadsThatDominateTokenCounts() {
        // A real turn from these logs: almost all of the token count is cache
        // read, and the total is nearly 100x the weighted figure.
        let turn = ModelTokens(input: 4, output: 700, cacheWrite: 2_300, cacheRead: 120_000)
        XCTAssertEqual(turn.input + turn.output + turn.cacheWrite + turn.cacheRead, 123_004)
        XCTAssertEqual(UsageReader.limitUnits(turn), 930.4, accuracy: 0.01)
    }
}
