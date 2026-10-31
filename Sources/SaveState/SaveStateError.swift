import SaveStateProtocol

/// Errors a `SaveStateRegistry` throws.
public enum SaveStateError: Error, Equatable, Sendable {
    /// The registry is disabled, so it accepts no changes.
    case disabled
    /// No control has this key.
    case unknownControl(String)
    /// No action has this key.
    case unknownAction(String)
    /// No scenario has this key.
    case unknownScenario(String)
    /// The control's kind doesn't accept this value.
    case invalidValue(key: String, value: ControlValue, kind: ControlKind)
}
