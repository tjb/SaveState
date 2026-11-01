import Foundation
import Observation
import SaveState
import Testing
@testable import SaveStateUI

@MainActor
@Observable
private final class PanelState {
    var flag = false
    var count = 1
    var name = "start"
    var ranKeys: [String] = []
}

private struct Boom: Error, CustomStringConvertible {
    var description: String { "boom" }
}

/// Holds a run open until the test releases it.
@MainActor
private final class Gate {
    private var isOpen = false
    private var waiter: CheckedContinuation<Void, Never>?

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiter = $0 }
    }

    func open() {
        isOpen = true
        waiter?.resume()
        waiter = nil
    }
}

/// A registry over a scratch store, and a panel model for it.
@MainActor
private final class Fixture {
    let scratch = ScratchSuite()
    let state = PanelState()
    let gate = Gate()
    let registry: SaveStateRegistry
    let runState = PanelRunState()
    let session = PanelSession()

    var model: PanelModel {
        PanelModel(registry: registry, runState: runState, session: session)
    }

    init(isEnabled: Bool = true) {
        let state = state
        let gate = gate
        registry = SaveStateRegistry(
            model: state,
            store: OverrideStore(suiteName: scratch.name),
            isEnabled: isEnabled,
            declare: { r in Self.declare(r, state: state, gate: gate) }
        )
    }

    /// A second launch: a new model and registry over the same store.
    func relaunchedState() -> PanelState {
        let state = PanelState()
        _ = SaveStateRegistry(
            model: state,
            store: OverrideStore(suiteName: scratch.name),
            isEnabled: true,
            declare: { r in Self.declare(r, state: state, gate: Gate()) }
        )
        return state
    }

    private static func declare(_ r: RegistryBuilder<PanelState>, state: PanelState, gate: Gate) {
        r.toggle("Flag", key: "flag", \.flag)
        r.integer("Count", key: "count", \.count)
        r.text("Name", key: "name", \.name)
        r.action("Seed", key: "seed") { state.ranKeys.append("seed") }
        r.action("Slow", key: "slow") {
            await gate.wait()
            state.ranKeys.append("slow")
        }
        r.action("Fail", key: "fail") { throw Boom() }
        r.action("Erase", key: "erase", destructive: true) { state.ranKeys.append("erase") }
        r.scenario("Trial", key: "trial") { model in model.flag = true }
        r.scenario("Broken", key: "broken") { _ in throw Boom() }
    }

    func control(_ key: String) throws -> ControlDescription {
        try #require(registry.describe().controls.first { $0.key == key })
    }

    func action(_ key: String) throws -> ActionDescription {
        try #require(registry.describe().actions.first { $0.key == key })
    }

    func scenario(_ key: String) throws -> ScenarioDescription {
        try #require(registry.describe().scenarios.first { $0.key == key })
    }
}

private let failure = PanelMessage(text: "boom", isError: true)

@Suite("Panel status")
struct PanelStatusTests {
    @Test func noChangesReadsAsDefault() {
        let status = PanelStatus(changedCount: 0)

        #expect(status.isAtDefault)
        #expect(status.text == "Everything at its default")
        #expect(status.systemImage == "checkmark.seal")
    }

    @Test func oneChangeIsSingular() {
        let status = PanelStatus(changedCount: 1)

        #expect(!status.isAtDefault)
        #expect(status.text == "1 control changed")
        #expect(status.systemImage == "wrench.and.screwdriver")
    }

    @Test func severalChangesArePlural() {
        #expect(PanelStatus(changedCount: 2).text == "2 controls changed")
    }

    @Test func resetAllNeedsSomethingToReset() {
        #expect(!PanelStatus(changedCount: 0).canResetAll)
        #expect(PanelStatus(changedCount: 1).canResetAll)
    }

    @Test func theButtonsValueStatesACountOfZero() {
        #expect(PanelStatus(changedCount: 0).accessibilityValue == "0 controls changed")
    }

    @Test func theButtonsValueIsSingularForOne() {
        #expect(PanelStatus(changedCount: 1).accessibilityValue == "1 control changed")
    }

    @MainActor
    @Test func countsOnlyTheChangedControls() throws {
        let fixture = Fixture()
        try fixture.registry.set(.bool(true), forKey: "flag")
        try fixture.registry.set(.int(9), forKey: "count")

        #expect(PanelStatus(fixture.registry.describe()).changedCount == 2)
    }
}

@Suite("Panel changes")
@MainActor
struct PanelChangeTests {
    @Test func changeWritesToTheModel() throws {
        let fixture = Fixture()

        fixture.model.change(.int(5), of: try fixture.control("count"))

        #expect(fixture.state.count == 5)
    }

    @Test func changesPersistAcrossLaunches() throws {
        let fixture = Fixture()

        fixture.model.change(.int(5), of: try fixture.control("count"))

        #expect(fixture.relaunchedState().count == 5)
    }

    @Test func aSuccessfulChangeClearsAnEarlierMessage() throws {
        let fixture = Fixture()
        fixture.runState.message = failure

        fixture.model.change(.int(5), of: try fixture.control("count"))

        #expect(fixture.runState.message == nil)
    }

    @Test func aRejectedChangeReportsAnErrorAndWritesNothing() throws {
        let fixture = Fixture()
        let control = try fixture.control("count")

        fixture.model.change(.string("nope"), of: control)

        #expect(fixture.state.count == 1)
        #expect(fixture.runState.message?.isError == true)
        #expect(fixture.runState.message?.text.isEmpty == false)
    }

    @Test func resetReturnsOnlyThatControlToItsDefault() throws {
        let fixture = Fixture()
        try fixture.registry.set(.int(5), forKey: "count", persist: true)
        try fixture.registry.set(.bool(true), forKey: "flag", persist: true)

        fixture.model.reset(try fixture.control("count"))

        #expect(fixture.state.count == 1)
        #expect(fixture.state.flag)
    }

    @Test func resetForgetsTheStoredValue() throws {
        let fixture = Fixture()
        try fixture.registry.set(.int(5), forKey: "count", persist: true)

        fixture.model.reset(try fixture.control("count"))

        #expect(fixture.relaunchedState().count == 1)
    }

    @Test func aFailedResetReportsAnError() {
        let fixture = Fixture()

        fixture.model.reset(describedControl(key: "missing"))

        #expect(fixture.runState.message?.isError == true)
    }

    @Test func resetAllReturnsEveryControlToItsDefault() throws {
        let fixture = Fixture()
        try fixture.registry.set(.int(5), forKey: "count", persist: true)
        try fixture.registry.set(.string("x"), forKey: "name", persist: true)

        fixture.model.resetAll()

        #expect(fixture.state.count == 1)
        #expect(fixture.state.name == "start")
        #expect(fixture.registry.changedKeys.isEmpty)
    }

    @Test func resetAllTellsRowsToDiscardTheirDrafts() {
        let fixture = Fixture()

        fixture.model.resetAll()
        fixture.model.resetAll()

        #expect(fixture.session.resetAllCount == 2)
    }

    @Test func aRefusedResetAllStillTellsRowsToDiscardTheirDrafts() {
        let fixture = Fixture(isEnabled: false)

        fixture.model.resetAll()

        #expect(fixture.session.resetAllCount == 1)
    }

    @Test func resetAllClearsAnEarlierMessage() {
        let fixture = Fixture()
        fixture.runState.message = failure

        fixture.model.resetAll()

        #expect(fixture.runState.message == nil)
    }
}

@Suite("Panel runs", .timeLimit(.minutes(1)))
@MainActor
struct PanelRunTests {
    @Test func anActionRunsAtOnceAndReportsSuccess() async throws {
        let fixture = Fixture()

        await fixture.model.request(try fixture.action("seed"))?.value

        #expect(fixture.state.ranKeys == ["seed"])
        #expect(fixture.runState.message == PanelMessage(text: "Ran Seed", isError: false))
    }

    @Test func aFailingActionReportsItsError() async throws {
        let fixture = Fixture()

        await fixture.model.request(try fixture.action("fail"))?.value

        #expect(fixture.runState.message == failure)
    }

    @Test func aFailedRunStopsBeingBusy() async throws {
        let fixture = Fixture()

        await fixture.model.request(try fixture.action("fail"))?.value

        #expect(fixture.runState.runningKey == nil)
    }

    @Test func aRunMarksItsKeyAsRunningUntilItEnds() async throws {
        let fixture = Fixture()
        let model = fixture.model

        let run = model.request(try fixture.action("slow"))

        #expect(model.isBusy)
        #expect(model.isRunning("slow"))
        #expect(!model.isRunning("seed"))

        fixture.gate.open()
        await run?.value

        #expect(!model.isBusy)
        #expect(!model.isRunning("slow"))
    }

    @Test func aRunClearsTheLastMessageWhenItStarts() async throws {
        let fixture = Fixture()
        fixture.runState.message = failure

        let run = fixture.model.request(try fixture.action("slow"))

        #expect(fixture.runState.message == nil)

        fixture.gate.open()
        await run?.value
    }

    /// Covers the model only. That `SaveStateOverlay` keeps one run state across
    /// presentations is view wiring, which no unit test here observes.
    @Test func aModelOverTheSameRunStateSeesARunAndItsResult() async throws {
        let fixture = Fixture()
        let run = fixture.model.request(try fixture.action("slow"))

        let reopened = PanelModel(registry: fixture.registry, runState: fixture.runState, session: PanelSession())

        #expect(reopened.isRunning("slow"))
        fixture.gate.open()
        await run?.value
        #expect(reopened.runState.message == PanelMessage(text: "Ran Slow", isError: false))
    }

    @Test func applyingAScenarioChangesTheModelAndReportsSuccess() async throws {
        let fixture = Fixture()

        await fixture.model.apply(try fixture.scenario("trial")).value

        #expect(fixture.state.flag)
        #expect(fixture.runState.message == PanelMessage(text: "Applied Trial", isError: false))
    }

    @Test func aFailingScenarioReportsItsError() async throws {
        let fixture = Fixture()

        await fixture.model.apply(try fixture.scenario("broken")).value

        #expect(fixture.runState.message == failure)
        #expect(fixture.runState.runningKey == nil)
    }
}

@Suite("Panel destructive confirmation", .timeLimit(.minutes(1)))
@MainActor
struct PanelConfirmationTests {
    @Test func requestingADestructiveActionDoesNotRunIt() async throws {
        let fixture = Fixture()

        let run = fixture.model.request(try fixture.action("erase"))
        await Task.yield()

        #expect(run == nil)
        #expect(fixture.state.ranKeys.isEmpty)
        #expect(fixture.runState.runningKey == nil)
    }

    @Test func requestingADestructiveActionAsksForConfirmation() throws {
        let fixture = Fixture()
        let erase = try fixture.action("erase")

        fixture.model.request(erase)

        #expect(fixture.session.actionToConfirm == erase)
        #expect(fixture.model.confirmationTitle == "Run Erase?")
    }

    @Test func confirmingRunsTheDestructiveAction() async throws {
        let fixture = Fixture()
        let erase = try fixture.action("erase")
        fixture.model.request(erase)

        await fixture.model.confirm(erase).value

        #expect(fixture.state.ranKeys == ["erase"])
        #expect(fixture.runState.message == PanelMessage(text: "Ran Erase", isError: false))
    }

    @Test func confirmingEndsTheConfirmation() async throws {
        let fixture = Fixture()
        let erase = try fixture.action("erase")
        fixture.model.request(erase)

        await fixture.model.confirm(erase).value

        #expect(fixture.session.actionToConfirm == nil)
    }

    @Test func cancellingEndsTheConfirmationWithoutRunning() async throws {
        let fixture = Fixture()
        fixture.model.request(try fixture.action("erase"))

        fixture.model.cancelConfirmation()
        await Task.yield()

        #expect(fixture.session.actionToConfirm == nil)
        #expect(fixture.state.ranKeys.isEmpty)
        #expect(fixture.runState.message == nil)
    }

    @Test func aNormalActionAsksForNoConfirmation() async throws {
        let fixture = Fixture()

        let run = fixture.model.request(try fixture.action("seed"))
        await run?.value

        #expect(run != nil)
        #expect(fixture.session.actionToConfirm == nil)
    }

    /// SwiftUI may clear the alert's binding before calling its button, so the
    /// presented action has to run with nothing pending.
    @Test func confirmingRunsTheActionWhenTheBindingWasAlreadyCleared() async throws {
        let fixture = Fixture()
        let erase = try fixture.action("erase")
        fixture.model.request(erase)
        fixture.session.actionToConfirm = nil

        await fixture.model.confirm(erase).value

        #expect(fixture.state.ranKeys == ["erase"])
    }

    @Test func theConfirmationTitleIsGenericWithNothingPending() {
        #expect(Fixture().model.confirmationTitle == "Run action?")
    }
}

@Suite("Panel with a disabled registry", .timeLimit(.minutes(1)))
@MainActor
struct PanelDisabledTests {
    private func disabledMessage() -> PanelMessage {
        PanelMessage(text: String(describing: SaveStateError.disabled), isError: true)
    }

    @Test func aDisabledRegistryShowsNothing() {
        #expect(!Fixture(isEnabled: false).model.isVisible)
    }

    @Test func anEnabledRegistryShows() {
        #expect(Fixture().model.isVisible)
    }

    @Test func changesAreRefusedAndReported() throws {
        let fixture = Fixture(isEnabled: false)

        fixture.model.change(.int(5), of: try fixture.control("count"))

        #expect(fixture.state.count == 1)
        #expect(fixture.runState.message == disabledMessage())
    }

    @Test func resetAllIsRefusedAndReported() {
        let fixture = Fixture(isEnabled: false)

        fixture.model.resetAll()

        #expect(fixture.runState.message == disabledMessage())
    }

    @Test func actionsDoNotRun() async throws {
        let fixture = Fixture(isEnabled: false)

        await fixture.model.request(try fixture.action("seed"))?.value

        #expect(fixture.state.ranKeys.isEmpty)
        #expect(fixture.runState.message == disabledMessage())
    }
}
