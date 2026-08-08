import XCTest
@testable import AIUsageBar

final class DailyHistoryStoreTests: XCTestCase {
    private var fileURL: URL!

    override func setUp() {
        super.setUp()
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("DailyHistoryStoreTests-\(UUID().uuidString).json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: fileURL)
        fileURL = nil
        super.tearDown()
    }

    /// A trend over `days` days (oldest first) with a single day's worth of
    /// Claude activity set at `activeIndex`, everything else zero — matches
    /// the all-zero-elsewhere shape `dailyTrend` actually produces.
    private func trend(days: Int, activeIndex: Int? = nil, claudeTokens: Int = 1000, claudeCostUSD: Double = 5.0) -> DailyTrend {
        var t = DailyTrend()
        let todayStart = Calendar.current.startOfDay(for: Date())
        t.days = (0..<days).map { todayStart.addingTimeInterval(-Double(days - 1 - $0) * 86400) }
        t.claudeTokens = Array(repeating: 0, count: days)
        t.claudeCostUSD = Array(repeating: 0, count: days)
        t.codexTokens = Array(repeating: 0, count: days)
        t.codexCostUSD = Array(repeating: 0, count: days)
        t.antigravityPrompts = Array(repeating: 0, count: days)
        t.antigravityCostUSD = Array(repeating: 0, count: days)
        if let activeIndex {
            t.claudeTokens[activeIndex] = claudeTokens
            t.claudeCostUSD[activeIndex] = claudeCostUSD
        }
        return t
    }

    func testRecordThenBackfillRecoversAPrunedDay() {
        // Day 0 had real activity when first observed...
        let firstScan = trend(days: 3, activeIndex: 0, claudeTokens: 5000, claudeCostUSD: 12.5)
        DailyHistoryStore.record(firstScan, fileURL: fileURL)

        // ...but a later scan's source log for day 0 is gone (Claude pruned
        // it), so the live rescan comes back all-zero for that day.
        let laterScan = trend(days: 3, activeIndex: nil)
        let result = DailyHistoryStore.backfill(laterScan, fileURL: fileURL)

        XCTAssertEqual(result.claudeTokens[0], 5000, "pruned day should be recovered from the store")
        XCTAssertEqual(result.claudeCostUSD[0], 12.5, accuracy: 0.001)
    }

    func testBackfillNeverOverwritesLiveData() {
        // Store has an old, different value for day 0...
        DailyHistoryStore.record(trend(days: 3, activeIndex: 0, claudeTokens: 999), fileURL: fileURL)

        // ...but the live scan actually measured something for day 0 this
        // time (e.g. the log still exists and now has more in it).
        let live = trend(days: 3, activeIndex: 0, claudeTokens: 7777, claudeCostUSD: 20.0)
        let result = DailyHistoryStore.backfill(live, fileURL: fileURL)

        XCTAssertEqual(result.claudeTokens[0], 7777, "live data must win over whatever was stored")
    }

    func testGenuinelyQuietDayIsNotTreatedAsMissing() {
        // Nothing was ever recorded for this day (store never saw activity).
        let live = trend(days: 3, activeIndex: nil)
        let result = DailyHistoryStore.backfill(live, fileURL: fileURL)

        // An empty store means there's nothing to backfill from — a quiet
        // day stays quiet (zero), not silently defaulting to something else.
        XCTAssertEqual(result.claudeTokens[0], 0)
        XCTAssertEqual(result.claudeTokens[1], 0)
        XCTAssertEqual(result.claudeTokens[2], 0)
    }

    func testRecordSkipsAllZeroDays() {
        // A day with zero activity everywhere should not be written at all —
        // it's indistinguishable from "not scanned yet."
        DailyHistoryStore.record(trend(days: 3, activeIndex: nil), fileURL: fileURL)

        let data = try? Data(contentsOf: fileURL)
        XCTAssertNil(data, "recording an all-zero trend should not create a history file")
    }

    func testMultipleRecordsMergeByDayInsteadOfOverwritingTheWholeStore() {
        DailyHistoryStore.record(trend(days: 3, activeIndex: 0, claudeTokens: 1000), fileURL: fileURL)
        DailyHistoryStore.record(trend(days: 3, activeIndex: 1, claudeTokens: 2000), fileURL: fileURL)

        // A third scan, today only, finds both earlier days pruned.
        let laterScan = trend(days: 3, activeIndex: nil)
        let result = DailyHistoryStore.backfill(laterScan, fileURL: fileURL)

        XCTAssertEqual(result.claudeTokens[0], 1000, "first recorded day should survive a later, unrelated record() call")
        XCTAssertEqual(result.claudeTokens[1], 2000, "second recorded day should also survive")
    }
}
