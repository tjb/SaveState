import Observation
import SaveState
import SwiftUI

/// A line at the top of the panel reporting how the last operation went.
struct PanelMessage: Equatable {
    let text: String
    let isError: Bool
}

/// The action or scenario in progress and how the last one went. It outlives the
/// popover, so closing and reopening the panel can't start a second run or lose a
/// failure.
@MainActor
@Observable
final class PanelRunState {
    var runningKey: String?
    var message: PanelMessage?
}

/// State that lasts as long as one presentation of the panel, so closing the
/// popover drops a pending confirmation.
@MainActor
@Observable
final class PanelSession {
    /// Bumped by Reset All, which discards drafts even when no value changes.
    var resetAllCount = 0
    /// The controls whose editors hold typing that hasn't applied yet.
    var editedDraftKeys: Set<String> = []
    /// The destructive action waiting for a person to confirm it.
    var actionToConfirm: ActionDescription?
}

/// What the panel's header says about the registry's controls.
struct PanelStatus: Equatable {
    let changedCount: Int
    /// Whether an editor holds typing that hasn't applied, which Reset All discards.
    let hasEditedDrafts: Bool

    init(changedCount: Int, hasEditedDrafts: Bool = false) {
        self.changedCount = changedCount
        self.hasEditedDrafts = hasEditedDrafts
    }

    init(_ description: RegistryDescription, hasEditedDrafts: Bool = false) {
        self.init(
            changedCount: description.controls.filter(\.isChanged).count,
            hasEditedDrafts: hasEditedDrafts
        )
    }

    var isAtDefault: Bool { changedCount == 0 }

    var canResetAll: Bool { changedCount != 0 || hasEditedDrafts }

    var text: String {
        isAtDefault ? "Everything at its default" : accessibilityValue
    }

    /// The status as SwiftUI shows it. String literals here are localization keys,
    /// so a host app's translations apply.
    var textKey: LocalizedStringKey {
        if isAtDefault { return "Everything at its default" }
        return changedCount == 1 ? "1 control changed" : "\(changedCount) controls changed"
    }

    var systemImage: String {
        isAtDefault ? "checkmark.seal" : "wrench.and.screwdriver"
    }

    /// The floating button's value, which states the count even when it's zero.
    var accessibilityValue: String {
        changedCount == 1 ? "1 control changed" : "\(changedCount) controls changed"
    }
}

/// The panel's decisions and the changes it makes to a registry. Views build one
/// while rendering; what lasts lives in the run state and the session.
@MainActor
struct PanelModel {
    let registry: SaveStateRegistry
    let runState: PanelRunState
    let session: PanelSession

    /// A disabled registry shows nothing.
    var isVisible: Bool { registry.isEnabled }

    /// Whether a run is in progress, which blocks starting another.
    var isBusy: Bool { runState.runningKey != nil }

    func isRunning(_ key: String) -> Bool {
        runState.runningKey == key
    }

    var confirmationTitle: String {
        "Run \(session.actionToConfirm?.label ?? "action")?"
    }

    /// The alert's title as SwiftUI shows it, as a localization key.
    var confirmationTitleKey: LocalizedStringKey {
        "Run \(session.actionToConfirm?.label ?? "action")?"
    }

    // MARK: - Changing

    /// Writes a value from an editor. Changes made in the panel persist.
    func change(_ value: ControlValue, of control: ControlDescription) {
        perform { try registry.set(value, forKey: control.key, persist: true) }
    }

    func reset(_ control: ControlDescription) {
        perform { try registry.reset(control.key) }
    }

    /// Records whether a control's editor holds typing that hasn't applied.
    func noteDraft(isEdited: Bool, of control: ControlDescription) {
        if isEdited {
            session.editedDraftKeys.insert(control.key)
        } else {
            session.editedDraftKeys.remove(control.key)
        }
    }

    func resetAll() {
        perform { try registry.resetAll() }
        session.resetAllCount += 1
    }

    private func perform(_ change: () throws -> Void) {
        do {
            try change()
            runState.message = nil
        } catch {
            runState.message = PanelMessage(text: String(describing: error), isError: true)
        }
    }

    // MARK: - Running

    /// Responds to a tap on an action: a destructive action waits for
    /// confirmation, and any other runs now.
    ///
    /// - Returns: The run, or `nil` when the action is waiting for confirmation.
    @discardableResult
    func request(_ action: ActionDescription) -> Task<Void, Never>? {
        guard !action.isDestructive else {
            session.actionToConfirm = action
            return nil
        }
        return run(action, allowDestructive: false)
    }

    /// Runs an action a person has just confirmed.
    ///
    /// It takes the action the alert presented, because SwiftUI may clear the
    /// alert's binding before calling its button.
    @discardableResult
    func confirm(_ action: ActionDescription) -> Task<Void, Never> {
        session.actionToConfirm = nil
        return run(action, allowDestructive: true)
    }

    func cancelConfirmation() {
        session.actionToConfirm = nil
    }

    @discardableResult
    func apply(_ scenario: ScenarioDescription) -> Task<Void, Never> {
        let registry = registry
        return runInBackground(key: scenario.key, success: "Applied \(scenario.label)") {
            try await registry.applyScenario(scenario.key)
        }
    }

    private func run(_ action: ActionDescription, allowDestructive: Bool) -> Task<Void, Never> {
        let registry = registry
        return runInBackground(key: action.key, success: "Ran \(action.label)") {
            try await registry.runAction(action.key, allowDestructive: allowDestructive)
        }
    }

    private func runInBackground(
        key: String,
        success: String,
        work: @escaping @MainActor () async throws -> Void
    ) -> Task<Void, Never> {
        runState.runningKey = key
        runState.message = nil
        // Captures the run state rather than the view, so a run that outlasts
        // the popover still reports to the panel when it reopens.
        return Task { [runState] in
            defer { runState.runningKey = nil }
            do {
                try await work()
                runState.message = PanelMessage(text: success, isError: false)
            } catch {
                runState.message = PanelMessage(text: String(describing: error), isError: true)
            }
        }
    }
}
