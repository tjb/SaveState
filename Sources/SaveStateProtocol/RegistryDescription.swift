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

    /// Creates a snapshot.
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
    /// The value the app acts on: the real value when an optional control has
    /// no override. For a clock control, the app's current time.
    public var effectiveValue: ControlValue
    /// The value the control had when the registry was created.
    public var defaultValue: ControlValue
    /// Whether a change takes effect only after the app relaunches.
    public var requiresRelaunch: Bool
    /// The value the app's next launch restores, or `nil` when the next launch
    /// starts from the default.
    public var nextLaunchValue: ControlValue?
    /// Whether the control has anything to reset: its value differs from its
    /// default, or a stored value that differs would return at a later launch.
    public var isChanged: Bool

    /// Creates a control's snapshot.
    public init(
        key: String,
        label: String,
        section: String?,
        kind: ControlKind,
        value: ControlValue,
        realValue: ControlValue?,
        effectiveValue: ControlValue,
        defaultValue: ControlValue,
        requiresRelaunch: Bool,
        nextLaunchValue: ControlValue?,
        isChanged: Bool
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
        self.nextLaunchValue = nextLaunchValue
        self.isChanged = isChanged
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

    /// Creates an action's snapshot.
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
    /// Display text for people. Never matched on.
    public var label: String
    /// The section the scenario was declared in, if any.
    public var section: String?
    /// What the scenario sets up, for people and agents choosing one.
    public var summary: String?

    /// Creates a scenario's snapshot.
    public init(key: String, label: String, section: String?, summary: String?) {
        self.key = key
        self.label = label
        self.section = section
        self.summary = summary
    }
}
