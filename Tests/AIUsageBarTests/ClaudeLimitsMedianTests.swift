import XCTest
@testable import AIUsageBar

final class ClaudeLimitsMedianTests: XCTestCase {
    func testEmptyReturnsNil() {
        XCTAssertNil(ClaudeLimitsReader.median([]))
    }

    func testSingleValue() {
        XCTAssertEqual(ClaudeLimitsReader.median([7]), 7)
    }

    func testOddCountReturnsMiddleValue() {
        XCTAssertEqual(ClaudeLimitsReader.median([3, 1, 2]), 2)
    }

    func testEvenCountAveragesTheTwoMiddleValues() {
        XCTAssertEqual(ClaudeLimitsReader.median([1, 2, 3, 4]), 2.5)
    }

    func testUnsortedInputIsSortedFirst() {
        XCTAssertEqual(ClaudeLimitsReader.median([9, 1, 5, 3, 7]), 5)
    }

    func testOutlierDoesNotDragTheMedianLikeItWouldAMean() {
        // One wildly unusual interval (a burst on a different model, or
        // usage from a device this Mac can't see) shouldn't move the
        // calibration much — the whole reason median was chosen over mean.
        let values = [1.0, 1.1, 0.9, 1.0, 50.0]
        XCTAssertEqual(ClaudeLimitsReader.median(values), 1.0)
    }
}
