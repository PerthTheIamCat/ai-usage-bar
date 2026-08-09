import XCTest
@testable import AIUsageBar

/// The incremental reader is the load-bearing part of the app's energy
/// behaviour: it is what makes a growing 34 MB session log cost only the bytes
/// appended since the last refresh. If it ever hands back the wrong region,
/// usage silently double-counts or goes missing, so its edges are pinned here.
final class IncrementalFileCacheTests: XCTestCase {
    private var url: URL!

    override func setUp() {
        super.setUp()
        url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-usage-bar-inc-\(UUID().uuidString).jsonl")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: url)
        super.tearDown()
    }

    private func write(_ text: String) { try? text.write(to: url, atomically: true, encoding: .utf8) }
    private func append(_ text: String) {
        guard let handle = try? FileHandle(forWritingTo: url) else { return XCTFail("cannot append") }
        handle.seekToEndOfFile()
        handle.write(Data(text.utf8))
        try? handle.close()
    }
    private func text(_ read: IncrementalRead?) -> String? {
        read.map { String(decoding: $0.data, as: UTF8.self) }
    }

    func testFirstReadReturnsEverything() {
        write("a\nb\n")
        let read = incrementalRead(of: url, from: 0)
        XCTAssertEqual(text(read), "a\nb\n")
        XCTAssertEqual(read?.consumed, 4)
        XCTAssertEqual(read?.isReset, false)
    }

    func testSecondReadReturnsOnlyTheAppendedBytes() {
        write("a\nb\n")
        let first = incrementalRead(of: url, from: 0)
        append("c\nd\n")
        let second = incrementalRead(of: url, from: first!.consumed)
        XCTAssertEqual(text(second), "c\nd\n")
        XCTAssertEqual(second?.consumed, 8)
    }

    func testUnchangedFileReadsNothing() {
        write("a\nb\n")
        let first = incrementalRead(of: url, from: 0)
        XCTAssertNil(incrementalRead(of: url, from: first!.consumed))
    }

    func testPartialTrailingLineIsLeftForNextTime() {
        // The writer is mid-append: the last line has no newline yet. Consuming
        // it now would both fail to parse and lose the record forever.
        write("a\nb\npartial")
        let read = incrementalRead(of: url, from: 0)
        XCTAssertEqual(text(read), "a\nb\n")
        XCTAssertEqual(read?.consumed, 4)

        append("-rest\n")
        let next = incrementalRead(of: url, from: read!.consumed)
        XCTAssertEqual(text(next), "partial-rest\n")
    }

    func testShrunkFileIsReReadWholeAndFlaggedAsReset() {
        write("aaaa\nbbbb\ncccc\n")
        let first = incrementalRead(of: url, from: 0)
        XCTAssertEqual(first?.isReset, false)

        write("x\n")
        let second = incrementalRead(of: url, from: first!.consumed)
        XCTAssertEqual(text(second), "x\n")
        XCTAssertEqual(second?.isReset, true)
    }

    func testEmptyAndMissingFilesReadNothing() {
        write("")
        XCTAssertNil(incrementalRead(of: url, from: 0))
        try? FileManager.default.removeItem(at: url)
        XCTAssertNil(incrementalRead(of: url, from: 0))
    }

    // MARK: - Cache

    func testCacheParsesEachLineExactlyOnceAcrossAppends() {
        let cache = IncrementalFileCache<[String]>()
        write("one\ntwo\n")
        var state = cache.states(for: [url], initial: { [] }, consume: consumeLines)
        XCTAssertEqual(state.first, ["one", "two"])

        append("three\n")
        state = cache.states(for: [url], initial: { [] }, consume: consumeLines)
        XCTAssertEqual(state.first, ["one", "two", "three"], "appended line must be added, not re-added")

        // No change at all: the state must be handed back untouched.
        state = cache.states(for: [url], initial: { [] }, consume: consumeLines)
        XCTAssertEqual(state.first, ["one", "two", "three"])
    }

    func testCacheDiscardsStateWhenAFileIsReplaced() {
        let cache = IncrementalFileCache<[String]>()
        write("old-a\nold-b\nold-c\n")
        _ = cache.states(for: [url], initial: { [] }, consume: consumeLines)

        write("new\n")
        let state = cache.states(for: [url], initial: { [] }, consume: consumeLines)
        XCTAssertEqual(state.first, ["new"], "a rewritten file must not keep the old file's records")
    }

    func testCacheKeepsFilesIndependentAndOrdered() throws {
        let cache = IncrementalFileCache<[String]>()
        let other = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-usage-bar-inc-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: other) }
        write("a\n")
        try "b\n".write(to: other, atomically: true, encoding: .utf8)

        let states = cache.states(for: [url, other], initial: { [] }, consume: consumeLines)
        XCTAssertEqual(states, [["a"], ["b"]])
    }

    /// `URL` caches resource values on the instance, so a long-lived URL keeps
    /// reporting the size and mtime it had when it was first asked. Several of
    /// the paths the change signature is built from are `static let`s, and
    /// this trap silently froze both the signature and the limits watcher
    /// before it was caught — so pin the behaviour rather than the reasoning.
    func testFileStampFollowsAFileThatGrows() {
        write("a\n")
        let stable = url!               // deliberately reused, as the app's static URLs are
        let before = UsageReader.fileStamp(stable)
        append("bbbbbbbbbb\n")
        XCTAssertNotEqual(UsageReader.fileStamp(stable), before)
    }

    private func consumeLines(_ data: Data, _ state: inout [String]) {
        UsageReader.forEachLine(in: data) { line in
            state.append(String(decoding: line, as: UTF8.self))
        }
    }
}
