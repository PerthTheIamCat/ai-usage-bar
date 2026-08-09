import XCTest
@testable import AIUsageBar

/// `fastParseISO` replaces `ISO8601DateFormatter` on the hot path (once per
/// log line), so it has to agree with it exactly — including on the awkward
/// shapes: fractional seconds of any length, offsets, leap seconds.
final class TimestampParsingTests: XCTestCase {
    private let reference: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private let referencePlain = ISO8601DateFormatter()

    private func expected(_ s: String) -> Date? {
        reference.date(from: s) ?? referencePlain.date(from: s)
    }

    func testMatchesFoundationOnRealLogTimestamps() {
        let samples = [
            "2026-08-09T14:50:35Z",
            "2026-08-09T14:50:35.049Z",
            "2026-08-07T10:46:43.019Z",
            "1970-01-01T00:00:00Z",
            "2000-02-29T12:00:00Z",       // leap day
            "2024-12-31T23:59:59.999Z",
            "2026-01-01T00:00:00.000Z",
        ]
        for sample in samples {
            let fast = UsageReader.fastParseISO(sample)
            XCTAssertNotNil(fast, "did not parse \(sample)")
            guard let fast, let want = expected(sample) else { continue }
            XCTAssertEqual(fast.timeIntervalSince1970, want.timeIntervalSince1970, accuracy: 0.0005, sample)
        }
    }

    func testHandlesNumericOffsets() {
        for sample in ["2026-08-09T21:50:35+07:00", "2026-08-09T09:50:35-05:00"] {
            guard let fast = UsageReader.fastParseISO(sample), let want = expected(sample) else {
                return XCTFail("did not parse \(sample)")
            }
            XCTAssertEqual(fast.timeIntervalSince1970, want.timeIntervalSince1970, accuracy: 0.0005, sample)
        }
    }

    func testRejectsMalformedInputSoTheFormatterFallbackRuns() {
        let bad = ["", "not a date", "2026-08-09", "2026-13-09T00:00:00Z", "2026-08-09T25:00:00Z",
                   "2026-08-09T14:50:35", "2026-08-09T14:50:35.Z", "2026-08-09T14:50:35Zjunk"]
        for sample in bad {
            XCTAssertNil(UsageReader.fastParseISO(sample), "should not have parsed \(sample)")
        }
    }

    func testParseISOStillAcceptsWhatTheFastPathRejects() {
        // No zone at all: the fast path bails, the formatter fallback wins.
        XCTAssertNotNil(UsageReader.parseISO("2026-08-09T14:50:35Z"))
        XCTAssertNil(UsageReader.parseISO("nonsense"))
    }

    // MARK: - Raw timestamp extraction

    private func rawTimestamp(_ line: String) -> String? {
        var result: String?
        UsageReader.forEachLineBytes(in: Data(line.utf8)) { bytes in
            result = UsageReader.rawTimestamp(in: bytes)
        }
        return result
    }

    func testReadsTheTimestampWithoutParsingTheLine() {
        XCTAssertEqual(
            rawTimestamp(#"{"timestamp":"2026-08-07T10:46:43.019Z","type":"response_item"}"#),
            "2026-08-07T10:46:43.019Z")
    }

    func testFindsTheTimestampWhenItIsNotFirst() {
        XCTAssertEqual(
            rawTimestamp(#"{"type":"event_msg","timestamp":"2026-08-07T10:46:43Z"}"#),
            "2026-08-07T10:46:43Z")
    }

    func testReturnsNilWhenThereIsNoTimestamp() {
        XCTAssertNil(rawTimestamp(#"{"type":"event_msg"}"#))
        XCTAssertNil(rawTimestamp(#"{"timestamp":123}"#))
        XCTAssertNil(rawTimestamp(""))
    }

    func testIsNotFooledByASimilarKeyOrMultiByteContent() {
        XCTAssertNil(rawTimestamp(#"{"my_timestamp_thing":"nope"}"#))
        XCTAssertEqual(
            rawTimestamp(#"{"text":"ประสิทธิภาพ","timestamp":"2026-08-07T10:46:43Z"}"#),
            "2026-08-07T10:46:43Z")
    }
}
