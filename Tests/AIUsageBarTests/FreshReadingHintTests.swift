import XCTest
@testable import AIUsageBar

final class FreshReadingHintTests: XCTestCase {
    func testEachProviderNamesItsOwnTool() {
        XCTAssertTrue(freshReadingHint(for: .codex).contains("Codex"))
        XCTAssertTrue(freshReadingHint(for: .antigravity).contains("Antigravity"))
        XCTAssertTrue(freshReadingHint(for: .claude).contains("Claude Code"))
    }

    func testUnknownProviderFallsBackToClaudeGuidance() {
        XCTAssertEqual(freshReadingHint(for: nil), freshReadingHint(for: .claude))
    }
}
