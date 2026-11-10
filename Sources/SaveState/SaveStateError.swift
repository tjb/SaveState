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
    /// The action is destructive and the caller didn't allow destructive actions.
    case destructiveActionNotAllowed(String)
    /// The control's kind doesn't accept this value.
    case invalidValue(key: String, value: ControlValue, kind: ControlKind)
    /// No probe has this key.
    case unknownProbe(String)
    /// The condition can't apply to the probe's value, such as `atLeast` on a
    /// Boolean. A wait throws this at once instead of waiting.
    case invalidCondition(key: String, condition: ProbeCondition, value: ControlValue)
    /// The probe didn't meet the condition before the timeout.
    case timedOut(key: String, timeout: Duration)
}
