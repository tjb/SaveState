import XCTest

/// Drives `.premiumToggle` end to end against a provider that persists its own
/// override, the way an app written for PremiumToggle does.
@MainActor
final class PremiumToggleShimUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-premiumToggleShim"]
        app.launch()
        openPanel()
        let resetAll = app.buttons["saveState.resetAll"]
        if resetAll.isEnabled {
            resetAll.tap()
        }
    }

    private func openPanel() {
        let button = app.buttons["premiumToggle.button"]
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        button.tap()
        XCTAssertTrue(app.buttons["saveState.resetAll"].waitForExistence(timeout: 5))
    }

    private var changedMarker: XCUIElement {
        app.descendants(matching: .any)["saveState.changed.premium"].firstMatch
    }

    func testOverridePersistsThroughTheProviderAndResetsToRealStatus() {
        XCTAssertFalse(changedMarker.exists)

        app.segmentedControls["saveState.control.premium"].buttons["On"].tap()
        XCTAssertTrue(changedMarker.waitForExistence(timeout: 2))
        XCTAssertEqual(app.buttons["premiumToggle.button"].value as? String, "Premium on")

        app.terminate()
        app.launch()
        XCTAssertEqual(app.buttons["premiumToggle.button"].value as? String, "Premium on")
        openPanel()
        XCTAssertTrue(changedMarker.exists, "A restored override must not become the default")

        app.buttons["saveState.reset.premium"].tap()
        XCTAssertTrue(changedMarker.waitForNonExistence(timeout: 2))
        XCTAssertEqual(app.buttons["premiumToggle.button"].value as? String, "Premium off")
    }
}
