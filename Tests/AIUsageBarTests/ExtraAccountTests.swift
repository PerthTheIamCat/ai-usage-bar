import XCTest
@testable import AIUsageBar

final class ExtraAccountTests: XCTestCase {
    func testMakeIDSlugifiesName() {
        XCTAssertEqual(ExtraAccount.makeID(provider: .claude, name: "My Work!", existing: []), "claude-my-work")
    }

    func testMakeIDFallsBackWhenNameHasNoAsciiLetters() {
        XCTAssertEqual(ExtraAccount.makeID(provider: .codex, name: "งาน", existing: []), "codex-account")
    }

    func testMakeIDIsUnique() {
        let id = ExtraAccount.makeID(provider: .claude, name: "work", existing: ["claude-work", "claude-work-2"])
        XCTAssertEqual(id, "claude-work-3")
    }

    func testIDValidationRejectsPathCharacters() {
        XCTAssertTrue(ExtraAccount.isValidID("claude-work-2"))
        XCTAssertFalse(ExtraAccount.isValidID("../x"))
        XCTAssertFalse(ExtraAccount.isValidID(""))
    }

    func testSnapshotURLRejectsUnsafeID() {
        XCTAssertNil(ClaudeLimitsReader.accountSnapshotURL(accountID: "a/b"))
        XCTAssertEqual(ClaudeLimitsReader.accountSnapshotURL(accountID: "claude-work")?.lastPathComponent,
                       "claude-statusline-claude-work.json")
    }

    func testLogsDirByProvider() {
        let claude = ExtraAccount(id: "claude-a", provider: .claude, name: "A", path: "/tmp/c")
        let codex = ExtraAccount(id: "codex-a", provider: .codex, name: "A", path: "/tmp/x")
        XCTAssertEqual(claude.logsDir.path, "/tmp/c/projects")
        XCTAssertEqual(codex.logsDir.path, "/tmp/x/sessions")
    }
}
