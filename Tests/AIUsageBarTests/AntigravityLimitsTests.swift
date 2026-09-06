import XCTest
@testable import AIUsageBar

final class AntigravityLimitsTests: XCTestCase {
    private let observedAt = Date(timeIntervalSince1970: 1_700_000_000)

    func testParsesDocumentedSnakeCaseQuotaBuckets() throws {
        let payload = #"{"quota":{"gemini-5h":{"remaining_fraction":0.72,"reset_time":"2026-09-05T23:00:00Z"},"gemini-weekly":{"remaining_fraction":0.41,"reset_time":"2026-09-10T12:00:00Z"}}}"#
        let snapshot = try XCTUnwrap(
            AntigravityLimitsReader.parseStatusLinePayload(Data(payload.utf8), observedAt: observedAt))

        XCTAssertEqual(try XCTUnwrap(snapshot.fiveHour).usedPercent, 28, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(snapshot.weekly).usedPercent, 59, accuracy: 0.001)
        XCTAssertEqual(snapshot.fiveHour?.resetsAt, UsageReader.parseISO("2026-09-05T23:00:00Z"))
        XCTAssertEqual(snapshot.weekly?.resetsAt, UsageReader.parseISO("2026-09-10T12:00:00Z"))
    }

    func testUsesResetSecondsForUnlabelledShortWindow() throws {
        let payload = #"{"quota":{"primary":{"remaining_fraction":0.5,"reset_in_seconds":3600},"secondary":{"remaining_fraction":0.8,"reset_in_seconds":604800}}}"#
        let snapshot = try XCTUnwrap(
            AntigravityLimitsReader.parseStatusLinePayload(Data(payload.utf8), observedAt: observedAt))

        XCTAssertEqual(try XCTUnwrap(snapshot.fiveHour).usedPercent, 50, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(snapshot.weekly).usedPercent, 20, accuracy: 0.001)
        XCTAssertEqual(snapshot.fiveHour?.resetsAt, observedAt.addingTimeInterval(3600))
        XCTAssertEqual(snapshot.weekly?.resetsAt, observedAt.addingTimeInterval(604800))
    }

    func testIgnoresMalformedQuotaEntries() {
        let payload = #"{"quota":{"bad":{"remaining_fraction":2},"missing":{},"wrong":{"remaining_fraction":"0.4"}}}"#
        XCTAssertNil(AntigravityLimitsReader.parseStatusLinePayload(Data(payload.utf8), observedAt: observedAt))
    }
}
