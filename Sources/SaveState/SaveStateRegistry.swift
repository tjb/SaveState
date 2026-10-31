import Foundation
import SaveStateProtocol

/// The registry of an app's debug state: its controls, actions, and scenarios.
///
/// Create one at launch, binding controls to the model that holds your debug
/// state:
///
/// ```swift
/// let registry = SaveStateRegistry(model: debugState) { r in
///     r.section("Purchases") {
///         r.triState("Premium", key: "premium", \.premiumOverride, real: { store.isEntitled })
///     }
///     r.choice("Environment", key: "env", \.environment, requiresRelaunch: true)
///     r.clock()
///     r.action("Reset onboarding", key: "reset-onboarding", destructive: true) {
///         onboarding.reset()
///     }
///     r.scenario("expired-trial", "Trial ended yesterday; the paywall shows") { state in
///         state.premiumOverride = false
///         SaveStateClock.overrideDate = .now.addingTimeInterval(8 * 86_400)
///     }
/// }
/// ```
///
/// The overlay, the agent endpoint, UI test launch arguments, and previews all
/// read and change state through the registry.
@MainActor
public final class SaveStateRegistry {
    /// Whether the registry accepts changes. When `false`, persisted values
    /// aren't restored and every change throws `SaveStateError.disabled`.
    public let isEnabled: Bool

    private let store: OverrideStore
    private let controls: [Control]
    private let actions: [RegisteredAction]
    private let scenarios: [RegisteredScenario]

    /// Creates a registry and restores persisted values into the model.
    ///
    /// - Parameters:
    ///   - model: The object your controls bind to, usually a `@MainActor`
    ///     `@Observable` class holding debug state.
    ///   - store: Where persisted values live.
    ///   - isEnabled: Defaults to `true` only in Debug builds. Pass your own
    ///     flag for QA or TestFlight builds.
    ///   - declare: Declares the controls, actions, and scenarios.
    public init<Model: AnyObject>(
        model: Model,
        store: OverrideStore = .standard,
        isEnabled: Bool = SaveStateBuild.isDebug,
        declare: (RegistryBuilder<Model>) -> Void
    ) {
        let builder = RegistryBuilder(model: model)
        declare(builder)
        self.isEnabled = isEnabled
        self.store = store
        controls = builder.controls
        actions = builder.actions
        scenarios = builder.scenarios
        if isEnabled {
            restorePersistedValues()
        }
    }

    // MARK: - Reading

    /// A snapshot of every control with its current values, every action, and
    /// every scenario.
    public func describe() -> RegistryDescription {
        RegistryDescription(
            controls: controls.map { controlDescription(of: $0) },
            actions: actions.map { action in
                ActionDescription(
                    key: action.key,
                    label: action.label,
                    section: action.section,
                    isDestructive: action.isDestructive
                )
            },
            scenarios: scenarios.map { scenario in
                ScenarioDescription(key: scenario.key, summary: scenario.summary)
            }
        )
    }

    /// The control's own value: the override for optional controls, otherwise
    /// the setting.
    public func value(forKey key: String) throws -> ControlValue {
        try control(forKey: key).binding.read()
    }

    /// The value the app should act on: the real value when an optional
    /// control has no override.
    public func effectiveValue(forKey key: String) throws -> ControlValue {
        effectiveValue(of: try control(forKey: key))
    }

    /// The keys of controls whose value differs from the value they had when
    /// the registry was created.
    public var changedKeys: [String] {
        controls.filter { $0.binding.read() != $0.defaultValue }.map { $0.key }
    }

    // MARK: - Changing

    /// Sets one control.
    ///
    /// - Parameter persist: Keeps the value across relaunches. Agent writes
    ///   default to `false`, so a relaunch clears them. A value persisted
    ///   earlier stays stored and returns on relaunch until you reset the
    ///   control or persist a new value.
    public func set(_ value: ControlValue, forKey key: String, persist: Bool = false) throws {
        try set([key: value], persist: persist)
    }

    /// Sets several controls at once. Every key and value is checked before
    /// any is written, so one bad entry leaves every control unchanged.
    public func set(_ values: [String: ControlValue], persist: Bool = false) throws {
        guard isEnabled else { throw SaveStateError.disabled }
        var pending: [(control: Control, value: ControlValue)] = []
        for (key, value) in values {
            let control = try self.control(forKey: key)
            guard let normalized = control.kind.normalize(value) else {
                throw SaveStateError.invalidValue(key: key, value: value, kind: control.kind)
            }
            pending.append((control: control, value: normalized))
        }
        for change in pending {
            change.control.binding.write(change.value)
            if persist {
                store.save(change.value, forKey: change.control.key)
            }
        }
    }

    /// Returns a control to the value it had when the registry was created and
    /// forgets any persisted value.
    public func reset(_ key: String) throws {
        guard isEnabled else { throw SaveStateError.disabled }
        restoreDefault(of: try control(forKey: key))
    }

    /// Resets every control.
    public func resetAll() throws {
        guard isEnabled else { throw SaveStateError.disabled }
        for control in controls {
            restoreDefault(of: control)
        }
    }

    /// Runs an action.
    public func runAction(_ key: String) async throws {
        guard isEnabled else { throw SaveStateError.disabled }
        guard let action = actions.first(where: { $0.key == key }) else {
            throw SaveStateError.unknownAction(key)
        }
        try await action.perform()
    }

    /// Applies a scenario.
    public func applyScenario(_ key: String) async throws {
        guard isEnabled else { throw SaveStateError.disabled }
        guard let scenario = scenarios.first(where: { $0.key == key }) else {
            throw SaveStateError.unknownScenario(key)
        }
        try await scenario.runner.run()
    }

    // MARK: - Private

    private func control(forKey key: String) throws -> Control {
        guard let control = controls.first(where: { $0.key == key }) else {
            throw SaveStateError.unknownControl(key)
        }
        return control
    }

    private func effectiveValue(of control: Control) -> ControlValue {
        let value = control.binding.read()
        if value == .null, let realValue = control.readReal?() {
            return realValue
        }
        return value
    }

    private func controlDescription(of control: Control) -> ControlDescription {
        ControlDescription(
            key: control.key,
            label: control.label,
            section: control.section,
            kind: control.kind,
            value: control.binding.read(),
            realValue: control.readReal?(),
            effectiveValue: effectiveValue(of: control),
            defaultValue: control.defaultValue,
            requiresRelaunch: control.requiresRelaunch
        )
    }

    private func restoreDefault(of control: Control) {
        control.binding.write(control.defaultValue)
        store.remove(forKey: control.key)
    }

    private func restorePersistedValues() {
        for control in controls {
            guard let stored = store.load(forKey: control.key) else { continue }
            if let value = control.kind.normalize(stored) {
                control.binding.write(value)
            } else {
                store.remove(forKey: control.key)
            }
        }
    }
}
