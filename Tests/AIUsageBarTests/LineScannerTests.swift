import XCTest
@testable import AIUsageBar

/// Every log reader in `UsageReader` now goes through `forEachLine` and, for
/// the very large Codex session logs, `tail`. A bug in either would show up as
/// usage quietly reading zero rather than as a crash, so both are pinned down
/// here directly.
final class LineScannerTests: XCTestCase {
    private func lines(_ text: String, markers: [StaticString] = []) -> [String] {
        var out: [String] = []
        UsageReader.forEachLine(in: Data(text.utf8), containingAll: markers) { line in
            out.append(String(decoding: line, as: UTF8.self))
        }
        return out
    }

    func testSplitsOnNewlinesAndSkipsEmptyLines() {
        XCTAssertEqual(lines("a\nb\nc"), ["a", "b", "c"])
        XCTAssertEqual(lines("a\n\nb\n"), ["a", "b"])
        XCTAssertEqual(lines(""), [])
        XCTAssertEqual(lines("\n\n"), [])
    }

    func testFinalLineWithoutTrailingNewlineIsStillYielded() {
        XCTAssertEqual(lines("only"), ["only"])
        XCTAssertEqual(lines("first\nlast"), ["first", "last"])
    }

    func testStripsCarriageReturns() {
        XCTAssertEqual(lines("a\r\nb\r\n"), ["a", "b"])
        XCTAssertEqual(lines("\r\n"), [])
    }

    func testMarkerFilterKeepsOnlyLinesContainingEveryMarker() {
        let text = """
        {"type":"assistant","message":{"usage":{}}}
        {"type":"user"}
        {"type":"assistant"}
        {"usage":{}}
        """
        XCTAssertEqual(
            lines(text, markers: ["\"usage\"", "\"assistant\""]),
            ["{\"type\":\"assistant\",\"message\":{\"usage\":{}}}"])
    }

    func testMarkerFilterMatchesAcrossMultiByteContent() {
        // The filter works on UTF-8 bytes; non-ASCII content in a line must
        // neither hide nor fake a match.
        let text = """
        {"text":"ประสิทธิภาพ","type":"assistant","usage":1}
        {"text":"ประสิทธิภาพ","type":"user"}
        """
        XCTAssertEqual(lines(text, markers: ["\"assistant\""]).count, 1)
    }

    func testLinesArriveAsExactUTF8Bytes() {
        var parsed: [String: Any]?
        UsageReader.forEachLine(in: Data(#"{"a":"ค่า"}"#.utf8)) { line in
            parsed = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
        }
        XCTAssertEqual(parsed?["a"] as? String, "ค่า")
    }

    func testTailReturnsWholeFileWhenSmallerThanLimit() throws {
        let url = try write("one\ntwo\nthree\n")
        defer { try? FileManager.default.removeItem(at: url) }
        let data = try XCTUnwrap(UsageReader.tail(of: url, maxBytes: 1024))
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "one\ntwo\nthree\n")
    }

    func testTailDropsThePartialLeadingLine() throws {
        let url = try write("aaaaaaaaaa\nbbbbbbbbbb\ncccccccccc\n")
        defer { try? FileManager.default.removeItem(at: url) }
        // The file is 33 bytes, so 25 bytes back lands inside the first line;
        // that partial line must be discarded rather than handed over
        // half-parsed, leaving the two whole lines after it.
        let data = try XCTUnwrap(UsageReader.tail(of: url, maxBytes: 25))
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "bbbbbbbbbb\ncccccccccc\n")
    }

    func testTailKeepsTheLastLineWhichIsWhatCallersWant() throws {
        let filler = String(repeating: "{\"noise\":1}\n", count: 5000)
        let url = try write(filler + "{\"rate_limits\":{\"primary\":{}}}\n")
        defer { try? FileManager.default.removeItem(at: url) }
        let data = try XCTUnwrap(UsageReader.tail(of: url, maxBytes: 4096))
        XCTAssertTrue(lines(String(decoding: data, as: UTF8.self)).last?.contains("rate_limits") == true)
    }

    func testTailOfMissingFileIsNil() {
        let missing = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-usage-bar-does-not-exist.jsonl")
        XCTAssertNil(UsageReader.tail(of: missing, maxBytes: 1024))
    }

    private func write(_ contents: String) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-usage-bar-\(UUID().uuidString).jsonl")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
