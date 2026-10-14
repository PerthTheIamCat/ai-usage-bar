import XCTest
@testable import AIUsageBar

final class WindowWarnThresholdTests: XCTestCase {
    private var savedOverrides: [String: Double] = [:]
    private var savedGlobal = 20.0

    override func setUp() {
        super.setUp()
        savedOverrides = AppSettings.shared.warnBelowOverrides
        savedGlobal = AppSettings.shared.warnBelowRemaining
        AppSettings.shared.warnBelowOverrides = [:]
        AppSettings.shared.warnBelowRemaining = 20
    }

    override func tearDown() {
        AppSettings.shared.warnBelowOverrides = savedOverrides
        AppSettings.shared.warnBelowRemaining = savedGlobal
        super.tearDown()
    }

    func testWindowWithoutOverrideFollowsGlobal() {
        let s = AppSettings.shared
        XCTAssertEqual(s.warnBelow(.claude, .fiveHour), 20)
        s.warnBelowRemaining = 35
        XCTAssertEqual(s.warnBelow(.codex, .weekly), 35)
    }

    func testOverrideAppliesOnlyToItsOwnWindow() {
        let s = AppSettings.shared
        s.setWarnBelowOverride(10, .claude, .fiveHour)
        XCTAssertEqual(s.warnBelow(.claude, .fiveHour), 10)
        XCTAssertEqual(s.warnBelow(.claude, .weekly), 20)
        XCTAssertEqual(s.warnBelow(.codex, .fiveHour), 20)
    }

    func testClearingOverrideRestoresGlobal() {
        let s = AppSettings.shared
        s.setWarnBelowOverride(45, .antigravity, .weekly)
        s.setWarnBelowOverride(nil, .antigravity, .weekly)
        XCTAssertNil(s.warnBelowOverride(.antigravity, .weekly))
        XCTAssertEqual(s.warnBelow(.antigravity, .weekly), 20)
    }

    func testLimitColorUsesPerWindowThreshold() {
        XCTAssertEqual(limitColor(15, warnBelow: 10), .systemOrange)
        XCTAssertEqual(limitColor(15, warnBelow: 25), .systemRed)
        XCTAssertEqual(limitColor(15), .systemRed, "no override falls back to the global 20%")
    }
}
