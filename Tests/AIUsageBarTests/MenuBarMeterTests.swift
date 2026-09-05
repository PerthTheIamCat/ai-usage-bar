import AppKit
import XCTest
@testable import AIUsageBar

final class MenuBarMeterTests: XCTestCase {
    private func render(_ style: LimitStyle, fiveHour: Double?, weekly: Double?,
                        mode: UsageDisplayMode = .used) throws -> Data {
        let image = MiniMeter.image(windows: [
            MenuBarWindow(kind: .fiveHour, remainingPercent: fiveHour),
            MenuBarWindow(kind: .weekly, remainingPercent: weekly)
        ], style: style, mode: mode, warnBelow: 20)
        return try XCTUnwrap(image.tiffRepresentation)
    }

    func testEitherWindowChangesTheRenderedMeter() throws {
        for style in [LimitStyle.bar, .ring, .percentOnly, .barAndPercent, .ringAndPercent] {
            let baseline = try render(style, fiveHour: 80, weekly: 60)
            XCTAssertNotEqual(baseline, try render(style, fiveHour: 40, weekly: 60), style.rawValue)
            XCTAssertNotEqual(baseline, try render(style, fiveHour: 80, weekly: 30), style.rawValue)
            XCTAssertNotEqual(baseline, try render(style, fiveHour: 80, weekly: 60, mode: .remaining), style.rawValue)
        }
    }

    func testMissingWindowDoesNotLookLikeZeroUsage() throws {
        for style in LimitStyle.allCases {
            XCTAssertNotEqual(try render(style, fiveHour: nil, weekly: 60),
                              try render(style, fiveHour: 100, weekly: 60), style.rawValue)
        }
    }

    func testInvalidReadingsBecomeMissingAndValuesAreClamped() {
        XCTAssertNil(MenuBarWindow(kind: .weekly, remainingPercent: .nan).validRemaining)
        XCTAssertNil(MenuBarWindow(kind: .weekly, remainingPercent: .infinity).validRemaining)
        XCTAssertEqual(MenuBarWindow(kind: .weekly, remainingPercent: -10).validRemaining, 0)
        XCTAssertEqual(MenuBarWindow(kind: .weekly, remainingPercent: 110).validRemaining, 100)
    }
}
