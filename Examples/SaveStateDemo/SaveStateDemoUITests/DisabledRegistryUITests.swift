import XCTest

/// A disabled registry must leave no trace of the overlay.
@MainActor
final class DisabledRegistryUITests: XCTestCase {
    func testADisabledRegistryShowsNoOverlay() {
        let app = XCUIApplication()
        app.launchArguments = ["-saveStateDisabled"]
        app.launch()

        XCTAssertTrue(app.navigationBars.firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["saveState.button"].exists)
    }
}
