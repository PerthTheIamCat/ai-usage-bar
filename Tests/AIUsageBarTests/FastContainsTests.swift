import XCTest
@testable import AIUsageBar

/// `UsageReader.fastContains` exists purely as a faster substitute for
/// `String.contains` on the ASCII markers these log scanners check for. The
/// only thing that matters is that it agrees with `String.contains` on every
/// case that can actually occur — a byte-scan is worthless if it's wrong.
final class FastContainsTests: XCTestCase {
    private func assertAgrees(_ haystack: String, _ needle: StaticString, file: StaticString = #filePath, line: UInt = #line) {
        let expected = haystack.contains(needle.description)
        let actual = UsageReader.fastContains(haystack, needle)
        XCTAssertEqual(actual, expected,
                        "fastContains(\(haystack.debugDescription), \(needle.description.debugDescription)) = \(actual), expected \(expected)",
                        file: file, line: line)
    }

    func testFindsMarkerAtStart() {
        assertAgrees("\"usage\":{\"input_tokens\":5}", "\"usage\"")
    }

    func testFindsMarkerAtEnd() {
        assertAgrees("some text before \"assistant\"", "\"assistant\"")
    }

    func testFindsMarkerInMiddle() {
        assertAgrees("prefix \"token_count\" suffix", "\"token_count\"")
    }

    func testMarkerNotPresent() {
        assertAgrees("this line has neither marker", "\"usage\"")
    }

    func testEmptyHaystack() {
        assertAgrees("", "\"usage\"")
    }

    func testNeedleLongerThanHaystack() {
        assertAgrees("short", "\"a much longer needle than the haystack\"")
    }

    func testHaystackExactlyEqualsNeedle() {
        assertAgrees("\"rate_limits\"", "\"rate_limits\"")
    }

    func testPartialPrefixMatchIsNotAFalsePositive() {
        // "\"usage" alone should not satisfy a search for "\"usage\"".
        assertAgrees("\"usage", "\"usage\"")
    }

    func testRepeatedNearMissesBeforeARealMatch() {
        // Several almost-matches ("\"usag", "\"usage_", ...) before the real
        // marker — exercises the inner mismatch-and-retry loop.
        assertAgrees("\"usag\"usage_extra\"usage\"", "\"usage\"")
    }

    func testLongRealisticLogLine() {
        let line = String(repeating: "x", count: 5000) + "\"usage\":{\"input_tokens\":123,\"output_tokens\":45}" + String(repeating: "y", count: 5000)
        assertAgrees(line, "\"usage\"")
        assertAgrees(line, "\"rate_limits\"")
    }
}
