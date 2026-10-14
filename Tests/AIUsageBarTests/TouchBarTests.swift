import XCTest
@testable import AIUsageBar

final class TouchBarTests: XCTestCase {
    func testHardwareDetectionReturnsStableValues() {
        XCTAssertFalse(TouchBarHardware.modelIdentifier.isEmpty)
        XCTAssertFalse(TouchBarHardware.modelDisplayName.isEmpty)
        XCTAssertEqual(TouchBarHardware.isAvailable(forceEnabled: true), true)
        XCTAssertEqual(TouchBarHardware.isAvailable(forceEnabled: false), TouchBarHardware.hasPhysicalTouchBar)
    }

    func testTouchBarHardwareModelDescriptions() {
        XCTAssertEqual(TouchBarHardware.modelDisplayName.isEmpty, false)
        // Verify current machine model format
        let model = TouchBarHardware.modelIdentifier
        XCTAssertTrue(model.starts(with: "Mac"), "Model should be a valid Mac model identifier, got \(model)")
    }

    func testTouchBarItemEquality() {
        let item1 = TouchBarProviderItem(id: "claude", kind: .claude, name: "Claude", icon: NSImage(), text: "80%", warning: false)
        let item2 = TouchBarProviderItem(id: "claude", kind: .claude, name: "Claude", icon: NSImage(), text: "80%", warning: false)
        let item3 = TouchBarProviderItem(id: "claude", kind: .claude, name: "Claude", icon: NSImage(), text: "40%", warning: true)

        XCTAssertEqual(item1, item2)
        XCTAssertNotEqual(item1, item3)
    }
}
