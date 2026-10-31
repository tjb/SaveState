/// A snapshot of an app's registry: every control with its current values,
/// every action, and every scenario.
///
/// This is what the `savestate_describe` MCP tool returns to agents.
public struct RegistryDescription: Codable, Hashable, Sendable {
    /// The controls, in declaration order.
    public var controls: [ControlDescription]
    /// The actions, in declaration order.
    public var actions: [ActionDescription]
    /// The scenarios, in declaration order.
    public var scenarios: [ScenarioDescription]

    public init(
        controls: [ControlDescription],
        actions: [ActionDescription],
        scenarios: [ScenarioDescription]
    ) {
        self.controls = controls
        self.actions = actions
        self.scenarios = scenarios
    }
}

/// One control and its values at the moment of the snapshot.
public struct ControlDescription: Codable, Hashable, Sendable {
    /// The stable identifier agents and tests address the control by.
    public var key: String
    /// Display text for people. Never matched on.
    public var label: String
    /// The section the control was declared in, if any.
    public var section: String?
    /// The control's kind, which decides the values it accepts.
    public var kind: ControlKind
    /// The control's own value: the override for optional controls, otherwise the setting.
    public var value: ControlValue
    /// The real value, for controls that report one.
    public var realValue: ControlValue?
    /// The value the app acts on: the real value when an optional control has no override.
    public var effectiveValue: ControlValue
    /// The value the control had when the registry was created.
    public var defaultValue: ControlValue
    /// Whether a change takes effect only after the app relaunches.
    public var requiresRelaunch: Bool

    public init(
        key: String,
        label: String,
        section: String?,
        kind: ControlKind,
        value: ControlValue,
        realValue: ControlValue?,
        effectiveValue: ControlValue,
        defaultValue: ControlValue,
        requiresRelaunch: Bool
    ) {
        self.key = key
        self.label = label
        self.section = section
        self.kind = kind
        self.value = value
        self.realValue = realValue
        self.effectiveValue = effectiveValue
        self.defaultValue = defaultValue
        self.requiresRelaunch = requiresRelaunch
    }
}

/// One action an agent or person can run.
public struct ActionDescription: Codable, Hashable, Sendable {
    /// The stable identifier the action is run by.
    public var key: String
    /// Display text for people. Never matched on.
    public var label: String
    /// The section the action was declared in, if any.
    public var section: String?
    /// Whether the action destroys data, so clients should ask before running it.
    public var isDestructive: Bool

    public init(key: String, label: String, section: String?, isDestructive: Bool) {
        self.key = key
        self.label = label
        self.section = section
        self.isDestructive = isDestructive
    }
}

/// One named scenario.
public struct ScenarioDescription: Codable, Hashable, Sendable {
    /// The stable identifier the scenario is applied by, such as `expired-trial`.
    public var key: String
    /// What the scenario sets up, for people and agents choosing one.
    public var summary: String

    public init(key: String, summary: String) {
        self.key = key
        self.summary = summary
    }
}
