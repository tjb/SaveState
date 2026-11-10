import Foundation
import Observation
import SaveStateProtocol

/// The registry of an app's debug state: its controls, actions, scenarios, and
/// probes.
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
///     r.scenario(
///         "Expired trial",
///         key: "expired-trial",
///         summary: "The trial ended yesterday, so the paywall shows."
///     ) { state in
///         state.premiumOverride = false
///         SaveStateClock.overrideDate = .now.addingTimeInterval(8 * 86_400)
///     }
/// }
/// ```
///
/// The overlay, the agent endpoint, UI test launch arguments, and previews all
/// read and change state through the registry. It is observable: SwiftUI views
/// that read it update after every change made through it.
@MainActor
@Observable
public final class SaveStateRegistry {
    /// Whether the registry accepts changes. When `false`, stored values
    /// aren't restored and every change throws `SaveStateError.disabled`.
    public let isEnabled: Bool

    private let store: OverrideStore
    private let controls: [Control]
    private let actions: [RegisteredAction]
    private let scenarios: [RegisteredScenario]
    private let probes: [RegisteredProbe]

    /// Bumped after every change made through the registry, so observers of
    /// anything that reads it are notified.
    private var revision = 0

    /// How often a probe wait checks state that isn't observable. Tests lengthen
    /// it to tell an observation wake from a tick.
    @ObservationIgnored var probeWaitTick: Duration = .milliseconds(100)

    /// Creates a registry and restores stored values into the model.
    ///
    /// - Parameters:
    ///   - model: The object your controls bind to, usually a `@MainActor`
    ///     `@Observable` class holding debug state.
    ///   - store: Where values that outlast a launch live.
    ///   - isEnabled: Defaults to `true` only in Debug builds. Pass your own
    ///     flag for QA or TestFlight builds.
    ///   - declare: Declares the controls, actions, scenarios, and probes.
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
        probes = builder.probes
        if isEnabled {
            restoreStoredValues()
        }
    }

    // MARK: - Reading

    /// A snapshot of every control with its current values, every action,
    /// every scenario, and every probe with its current value. It reads every
    /// probe, so a SwiftUI view that calls it updates when an observable
    /// probe changes.
    public func describe() -> RegistryDescription {
        observeChanges()
        return RegistryDescription(
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
                ScenarioDescription(
                    key: scenario.key,
                    label: scenario.label,
                    section: scenario.section,
                    summary: scenario.summary
                )
            },
            probes: probes.map { probeDescription(of: $0, value: $0.read()) }
        )
    }

    /// One control with its current values.
    public func control(forKey key: String) throws -> ControlDescription {
        observeChanges()
        return controlDescription(of: try registeredControl(forKey: key))
    }

    /// One probe with its current value. Reads only that probe.
    ///
    /// Probes are read-only, so this works when the registry is disabled.
    public func probe(forKey key: String) throws -> ProbeDescription {
        observeChanges()
        let probe = try registeredProbe(forKey: key)
        return probeDescription(of: probe, value: probe.read())
    }

    /// Waits until a probe meets a condition, and returns the probe with the
    /// value that met it.
    ///
    /// It checks at once, then again whenever an observable value the probe
    /// reads changes, and every 100 ms for state that isn't observable. At the
    /// deadline it checks one last time. Probes are read-only, so this works
    /// when the registry is disabled.
    ///
    /// - Throws: `SaveStateError.unknownProbe` for an unknown key and
    ///   `SaveStateError.invalidCondition` when the condition can't apply to the
    ///   probe's value, both before waiting. `SaveStateError.timedOut` when the
    ///   timeout passes first, and `CancellationError` when the task is
    ///   cancelled.
    public func wait(
        forProbe key: String,
        until condition: ProbeCondition,
        timeout: Duration
    ) async throws -> ProbeDescription {
        let probe = try registeredProbe(forKey: key)
        let value = try await ProbeWait(
            key: key,
            condition: condition,
            timeout: timeout,
            tick: probeWaitTick,
            read: probe.read
        ).run()
        return probeDescription(of: probe, value: value)
    }

    /// The control's own value: the override for optional controls, otherwise
    /// the setting.
    public func value(forKey key: String) throws -> ControlValue {
        observeChanges()
        return try registeredControl(forKey: key).binding.read()
    }

    /// The value the app should act on: the real value when an optional
    /// control has no override.
    public func effectiveValue(forKey key: String) throws -> ControlValue {
        observeChanges()
        return effectiveValue(of: try registeredControl(forKey: key))
    }

    /// The keys of controls with anything to reset, in declaration order: the
    /// value differs from the one they had when the registry was created, or a
    /// stored value that differs would return at a later launch.
    public var changedKeys: [String] {
        observeChanges()
        return controls.filter { isChanged($0) }.map { $0.key }
    }

    // MARK: - Changing

    /// Sets one control.
    ///
    /// - Parameter persist: Keeps the value across relaunches until you reset
    ///   the control. When `false`, the value lasts for this launch, except on
    ///   a control that requires a relaunch: there it lasts through the next
    ///   launch, so relaunching applies it once. Either way, a value persisted
    ///   earlier returns at later launches.
    public func set(_ value: ControlValue, forKey key: String, persist: Bool = false) throws {
        try set([key: value], persist: persist)
    }

    /// Sets several controls at once.
    ///
    /// Every key and value is checked before any is written, so one bad entry
    /// leaves every control unchanged. Values are written in declaration order.
    ///
    /// - Parameter persist: Applies to every value, as in `set(_:forKey:persist:)`.
    public func set(_ values: [String: ControlValue], persist: Bool = false) throws {
        guard isEnabled else { throw SaveStateError.disabled }
        let unknownKeys = values.keys.filter { key in !controls.contains { $0.key == key } }
        if let unknownKey = unknownKeys.min() {
            throw SaveStateError.unknownControl(unknownKey)
        }
        var pending: [(control: Control, value: ControlValue)] = []
        for control in controls {
            guard let value = values[control.key] else { continue }
            guard let normalized = control.kind.normalize(value) else {
                throw SaveStateError.invalidValue(key: control.key, value: value, kind: control.kind)
            }
            pending.append((control: control, value: normalized))
        }
        defer { revision += 1 }
        for change in pending {
            change.control.binding.write(change.value)
            storeValue(change.value, for: change.control, persist: persist)
        }
    }

    /// Returns a control to the value it had when the registry was created and
    /// forgets any stored value.
    public func reset(_ key: String) throws {
        guard isEnabled else { throw SaveStateError.disabled }
        let control = try registeredControl(forKey: key)
        defer { revision += 1 }
        restoreDefault(of: control)
    }

    /// Resets every control.
    public func resetAll() throws {
        guard isEnabled else { throw SaveStateError.disabled }
        defer { revision += 1 }
        for control in controls {
            restoreDefault(of: control)
        }
    }

    /// Runs an action.
    ///
    /// - Parameter allowDestructive: Pass `true` to run an action declared
    ///   `destructive`, after a person has confirmed it. Otherwise those
    ///   actions throw `SaveStateError.destructiveActionNotAllowed`.
    public func runAction(_ key: String, allowDestructive: Bool = false) async throws {
        guard isEnabled else { throw SaveStateError.disabled }
        guard let action = actions.first(where: { $0.key == key }) else {
            throw SaveStateError.unknownAction(key)
        }
        guard allowDestructive || !action.isDestructive else {
            throw SaveStateError.destructiveActionNotAllowed(key)
        }
        defer { revision += 1 }
        try await action.perform()
    }

    /// Applies a scenario.
    ///
    /// Changes the scenario makes to the model directly last for this launch.
    public func applyScenario(_ key: String) async throws {
        guard isEnabled else { throw SaveStateError.disabled }
        guard let scenario = scenarios.first(where: { $0.key == key }) else {
            throw SaveStateError.unknownScenario(key)
        }
        defer { revision += 1 }
        try await scenario.runner.run()
    }

    // MARK: - Private

    private func observeChanges() {
        _ = revision
    }

    private func registeredControl(forKey key: String) throws -> Control {
        guard let control = controls.first(where: { $0.key == key }) else {
            throw SaveStateError.unknownControl(key)
        }
        return control
    }

    private func registeredProbe(forKey key: String) throws -> RegisteredProbe {
        guard let probe = probes.first(where: { $0.key == key }) else {
            throw SaveStateError.unknownProbe(key)
        }
        return probe
    }

    private func probeDescription(of probe: RegisteredProbe, value: ControlValue) -> ProbeDescription {
        ProbeDescription(key: probe.key, label: probe.label, section: probe.section, value: value)
    }

    private func effectiveValue(of control: Control) -> ControlValue {
        if let readEffective = control.readEffective {
            return readEffective()
        }
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
            requiresRelaunch: control.requiresRelaunch,
            nextLaunchValue: store.value(forKey: control.key, in: .nextLaunch)
                ?? store.value(forKey: control.key, in: .persisted),
            isChanged: isChanged(control)
        )
    }

    private func isChanged(_ control: Control) -> Bool {
        let values = [control.binding.read()]
            + OverrideStore.Slot.allCases.compactMap { store.value(forKey: control.key, in: $0) }
        return values.contains { $0 != control.defaultValue }
    }

    private func storeValue(_ value: ControlValue, for control: Control, persist: Bool) {
        if persist {
            store.save(value, forKey: control.key, in: .persisted)
            store.remove(forKey: control.key, in: .nextLaunch)
        } else if control.requiresRelaunch {
            store.save(value, forKey: control.key, in: .nextLaunch)
        }
    }

    private func restoreDefault(of control: Control) {
        control.binding.write(control.defaultValue)
        store.removeAll(forKey: control.key)
    }

    /// Applies each control's stored value: a next-launch value once, which
    /// this consumes, otherwise the persisted value. Values the control no
    /// longer accepts, such as a removed choice, are dropped.
    private func restoreStoredValues() {
        for control in controls {
            if let value = store.value(forKey: control.key, in: .nextLaunch) {
                store.remove(forKey: control.key, in: .nextLaunch)
                if let normalized = control.kind.normalize(value) {
                    control.binding.write(normalized)
                    continue
                }
            }
            guard let value = store.value(forKey: control.key, in: .persisted) else { continue }
            if let normalized = control.kind.normalize(value) {
                control.binding.write(normalized)
            } else {
                store.remove(forKey: control.key, in: .persisted)
            }
        }
    }
}
