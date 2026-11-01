import XCTest

/// Drives `.premiumToggle` end to end against a provider that persists its own
/// override, the way an app written for PremiumToggle does.
@MainActor
final class PremiumToggleShimUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    private func launch(_ arguments: String...) {
        app.launchArguments = ["-premiumToggleShim"] + arguments
        app.launch()
    }

    /// Clears any override an earlier test left behind.
    private func launchAndOpenCleanPanel() {
        launch()
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
        XCTAssertTrue(app.buttons["saveState.resetAll"].waitForExistence(timeout: 15))
    }

    private var changedMarker: XCUIElement {
        app.descendants(matching: .any)["saveState.changed.premium"].firstMatch
    }

    private var status: XCUIElement {
        app.descendants(matching: .any)["premiumToggle.status"].firstMatch
    }

    func testOverridePersistsThroughTheProviderAndResetsToRealStatus() {
        launchAndOpenCleanPanel()
        XCTAssertFalse(changedMarker.exists)
        XCTAssertEqual(status.label, "Premium is off")

        app.segmentedControls["saveState.control.premium"].buttons["On"].tap()
        XCTAssertTrue(changedMarker.waitForExistence(timeout: 15))
        XCTAssertEqual(status.label, "Premium is on")
        XCTAssertEqual(app.buttons["premiumToggle.button"].value as? String, "Premium on")

        app.terminate()
        app.launch()
        XCTAssertEqual(app.buttons["premiumToggle.button"].value as? String, "Premium on")
        openPanel()
        XCTAssertTrue(changedMarker.exists, "A restored override must not become the default")

        app.buttons["saveState.reset.premium"].tap()
        XCTAssertTrue(changedMarker.waitForNonExistence(timeout: 15))
        XCTAssertEqual(app.buttons["premiumToggle.button"].value as? String, "Premium off")
    }

    func testAProviderThatBlocksOverridesGetsALockedPanel() {
        launch("-premiumToggleBlocked")
        let button = app.buttons["premiumToggle.button"]
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        button.tap()

        let note = app.descendants(matching: .any)["premiumToggle.disabled"].firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 15))
        XCTAssertTrue(status.exists)
        XCTAssertFalse(app.segmentedControls["saveState.control.premium"].exists)
    }

    func testIsEnabledFalseShowsNoButton() {
        launch("-premiumToggleHidden")
        XCTAssertTrue(app.navigationBars.firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["premiumToggle.button"].exists)
    }
}
