import Foundation
import SaveState

/// A `UserDefaults` suite for one test, removed when the test ends.
final class ScratchSuite: Sendable {
    let name = "SaveStateUITests.\(UUID().uuidString)"

    deinit {
        UserDefaults.standard.removePersistentDomain(forName: name)
    }
}

/// Builds a control's description directly, for testing models that only read one.
func describedControl(
    key: String = "key",
    label: String? = nil,
    section: String? = nil,
    kind: ControlKind = .toggle,
    value: ControlValue = .bool(false),
    realValue: ControlValue? = nil,
    requiresRelaunch: Bool = false,
    isChanged: Bool = false
) -> ControlDescription {
    ControlDescription(
        key: key,
        label: label ?? key,
        section: section,
        kind: kind,
        value: value,
        realValue: realValue,
        effectiveValue: value,
        defaultValue: value,
        requiresRelaunch: requiresRelaunch,
        nextLaunchValue: nil,
        isChanged: isChanged
    )
}
