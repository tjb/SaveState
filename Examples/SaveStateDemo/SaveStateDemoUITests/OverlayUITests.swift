import XCTest

/// Drives the overlay through real taps, including the parts unit tests can't
/// reach: presenting the popover, the confirmation alert, and relaunching.
///
/// These use XCTest because XCUITest requires it.
@MainActor
final class OverlayUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-saveStateSlowAction"]
        app.launch()
        openPanel()
        let resetAll = app.buttons["saveState.resetAll"]
        if resetAll.isEnabled {
            resetAll.tap()
        }
    }

    private func openPanel() {
        let button = app.buttons["saveState.button"]
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        button.tap()
        XCTAssertTrue(app.buttons["saveState.resetAll"].waitForExistence(timeout: 15))
    }

    /// Dismisses the popover by tapping the page behind it. With the keyboard
    /// up, the first tap may only end editing.
    private func closePanel() {
        let resetAll = app.buttons["saveState.resetAll"]
        for _ in 0..<3 where resetAll.exists {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.04, dy: 0.3)).tap()
            _ = resetAll.waitForNonExistence(timeout: 2)
        }
        XCTAssertFalse(resetAll.exists)
    }

    private func relaunch() {
        app.terminate()
        app.launch()
        openPanel()
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    /// Drags the panel's content until the element sits in its visible band.
    private func scroll(to identifier: String) {
        let target = element(identifier)
        let top = app.buttons["saveState.resetAll"].frame.maxY + 40
        let bottom = app.buttons["saveState.button"].frame.minY - 16
        func isVisible() -> Bool {
            target.exists && target.frame.minY > top && target.frame.maxY < bottom
        }
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.22, dy: 0.0))
            .withOffset(CGVector(dx: 0, dy: bottom - 20))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.22, dy: 0.0))
            .withOffset(CGVector(dx: 0, dy: top + 80))
        for _ in 0..<8 where !isVisible() {
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        XCTAssertTrue(isVisible(), "\(identifier) isn't reachable")
    }

    /// Taps a switch until its value changes. A tap sometimes has no effect on CI
    /// runners, for a reason that isn't known yet, so this works around that, and
    /// records each miss so the cause can be found. A switch that never responds
    /// still fails.
    private func toggle(_ control: XCUIElement) {
        let before = control.value as? String ?? ""
        for attempt in 1...3 {
            control.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            // An expectation can only be waited on once, so each try needs its own.
            let changed = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "value != %@", before),
                object: control
            )
            if XCTWaiter.wait(for: [changed], timeout: 5) == .completed { return }
            // A stall can outlast the wait, and tapping again would flip it back.
            if control.value as? String != before { return }
            print("savestate-missed-tap: \(control.identifier) stayed at \(before) after tap \(attempt)")
            recordState(named: "Missed tap \(attempt)")
        }
        XCTFail("\(control.identifier) stayed at \(before) after three taps")
    }

    /// Keeps a screenshot and the accessibility hierarchy in the test results.
    private func recordState(named name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        let hierarchy = XCTAttachment(string: app.debugDescription)
        for attachment in [screenshot, hierarchy] {
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    func testOverlayChangesPersistAcrossRelaunchUntilReset() {
        let tips = app.switches["saveState.control.tips"]
        scroll(to: "saveState.control.tips")
        XCTAssertFalse(element("saveState.changed.tips").exists)

        toggle(tips)
        XCTAssertTrue(element("saveState.changed.tips").waitForExistence(timeout: 15))

        relaunch()

        scroll(to: "saveState.control.tips")
        XCTAssertTrue(element("saveState.changed.tips").exists)
        app.buttons["saveState.reset.tips"].tap()
        XCTAssertTrue(element("saveState.changed.tips").waitForNonExistence(timeout: 15))
    }

    func testRelaunchControlIsMarked() {
        scroll(to: "saveState.control.env")
        XCTAssertTrue(element("saveState.relaunch.env").exists)
        XCTAssertFalse(element("saveState.relaunch.tips").exists)
    }

    func testTextAppliesWhenThePanelClosesMidEdit() {
        scroll(to: "saveState.control.greeting")
        let field = app.textFields["saveState.control.greeting"]
        field.tap()
        field.typeText("!")
        closePanel()
        XCTAssertTrue(app.staticTexts["Greeting, Welcome back!"].waitForExistence(timeout: 15))

        openPanel()
        scroll(to: "saveState.control.greeting")
        XCTAssertTrue(element("saveState.changed.greeting").exists)
    }

    func testInvalidNumberIsRejected() {
        scroll(to: "saveState.control.project-limit")
        let field = app.textFields["saveState.control.project-limit"]
        field.tap()
        field.typeText("x\n")
        XCTAssertTrue(app.staticTexts["Enter a whole number."].waitForExistence(timeout: 15))
        XCTAssertFalse(element("saveState.changed.project-limit").exists)
    }

    func testResetAllDiscardsAnUnappliedDraft() {
        scroll(to: "saveState.control.tips")
        toggle(app.switches["saveState.control.tips"])
        scroll(to: "saveState.control.greeting")
        let field = app.textFields["saveState.control.greeting"]
        field.tap()
        field.typeText("!")
        app.buttons["saveState.resetAll"].tap()
        closePanel()
        let greeting = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Greeting,'")).firstMatch
        XCTAssertTrue(greeting.waitForExistence(timeout: 15), "The greeting row never appeared")
        XCTAssertEqual(greeting.label, "Greeting, Welcome back")
    }

    func testResetAllDiscardsADraftWhenNothingElseChanged() {
        scroll(to: "saveState.control.greeting")
        let field = app.textFields["saveState.control.greeting"]
        let resetAll = app.buttons["saveState.resetAll"]
        XCTAssertFalse(resetAll.isEnabled)
        field.tap()
        field.typeText("!")
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: resetAll)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 15), .completed, "Typing didn't enable Reset All")

        resetAll.tap()
        let disabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == false"), object: resetAll)
        XCTAssertEqual(XCTWaiter.wait(for: [disabled], timeout: 15), .completed, "Reset All stayed enabled")
        closePanel()
        let greeting = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Greeting,'")).firstMatch
        XCTAssertTrue(greeting.waitForExistence(timeout: 15), "The greeting row never appeared")
        XCTAssertEqual(greeting.label, "Greeting, Welcome back")
    }

    func testResetAllIsDisabledWithNothingToReset() {
        XCTAssertFalse(app.buttons["saveState.resetAll"].isEnabled)
    }

    func testButtonsStayDisabledDuringARunEvenAfterReopeningThePanel() {
        scroll(to: "saveState.action.slow-sync")
        let seed = app.buttons["saveState.action.seed"]
        XCTAssertTrue(seed.isEnabled)

        app.buttons["saveState.action.slow-sync"].tap()
        XCTAssertFalse(seed.isEnabled)

        closePanel()
        openPanel()
        scroll(to: "saveState.action.seed")
        XCTAssertFalse(seed.isEnabled, "Reopening must not allow a second run")
        // Unit tests cover the run finishing. Waiting for it here is unreliable: the
        // spinner keeps the app from going idle, so queries time out on slow runners.
    }

    func testDestructiveActionAsksFirst() {
        scroll(to: "saveState.action.seed")
        app.buttons["saveState.action.seed"].tap()
        XCTAssertTrue(element("saveState.message").waitForExistence(timeout: 15))

        scroll(to: "saveState.action.erase")
        app.buttons["saveState.action.erase"].tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 15))
        alert.buttons["Cancel"].firstMatch.tap()
        XCTAssertTrue(alert.waitForNonExistence(timeout: 15))
        closePanel()
        XCTAssertTrue(app.staticTexts["Seeded projects, 5"].waitForExistence(timeout: 15))

        openPanel()
        scroll(to: "saveState.action.erase")
        app.buttons["saveState.action.erase"].tap()
        XCTAssertTrue(alert.waitForExistence(timeout: 15))
        alert.buttons["Run"].firstMatch.tap()
        XCTAssertTrue(alert.waitForNonExistence(timeout: 15))
        closePanel()
        XCTAssertTrue(app.staticTexts["Seeded projects, 0"].waitForExistence(timeout: 15))
    }

    func testExpiredTrialScenarioShowsThePaywall() {
        scroll(to: "saveState.scenario.expired-trial")
        app.buttons["saveState.scenario.expired-trial"].tap()
        XCTAssertTrue(element("saveState.message").waitForExistence(timeout: 15))
        closePanel()
        XCTAssertTrue(element("demo.paywall").waitForExistence(timeout: 15))

        openPanel()
        app.buttons["saveState.resetAll"].tap()
        closePanel()
        XCTAssertTrue(element("demo.trial").waitForExistence(timeout: 15))
    }

    /// Holds the panel open so `simctl io` can capture it. Runs only when
    /// xcodebuild is given `TEST_RUNNER_SAVESTATE_HOLD_SECONDS`.
    func testHoldPanelOpenForScreenshot() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let seconds = environment["SAVESTATE_HOLD_SECONDS"].flatMap(TimeInterval.init) else {
            throw XCTSkip("SAVESTATE_HOLD_SECONDS isn't set")
        }
        if environment["SAVESTATE_HOLD_SCROLL"] != nil {
            scroll(to: "saveState.scenario.expired-trial")
        }
        print("SAVESTATE_PANEL_OPEN")
        Thread.sleep(forTimeInterval: seconds)
    }
}
