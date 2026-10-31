import Foundation
import SaveStateProtocol

/// Declares the controls, actions, and scenarios a `SaveStateRegistry` exposes.
///
/// You receive one in the closure you pass to `SaveStateRegistry.init`. Key
/// paths point into the model you gave the registry. Keys are stable
/// identifiers that agents and tests use; labels are display text only.
@MainActor
public final class RegistryBuilder<Model: AnyObject> {
    private let model: Model
    private var currentSection: String?
    private(set) var controls: [Control] = []
    private(set) var actions: [RegisteredAction] = []
    private(set) var scenarios: [RegisteredScenario] = []

    init(model: Model) {
        self.model = model
    }

    // MARK: - Sections

    /// Groups the controls, actions, and scenarios declared in `content` under
    /// a title. A nested section replaces the title until it ends.
    public func section(_ title: String, _ content: () -> Void) {
        let enclosingSection = currentSection
        currentSection = title
        content()
        currentSection = enclosingSection
    }

    // MARK: - Controls

    /// An on/off control bound to a `Bool` property.
    public func toggle(
        _ label: String,
        key: String,
        _ keyPath: ReferenceWritableKeyPath<Model, Bool>,
        requiresRelaunch: Bool = false
    ) {
        addControl(
            key: key,
            label: label,
            kind: .toggle,
            requiresRelaunch: requiresRelaunch,
            binding: KeyPathBinding(model: model, keyPath: keyPath)
        )
    }

    /// An on/off/no-override control bound to a `Bool?` property, where `nil`
    /// means "use the real value".
    ///
    /// - Parameter real: Returns the real value, so the registry can report
    ///   the effective value when there is no override.
    public func triState(
        _ label: String,
        key: String,
        _ keyPath: ReferenceWritableKeyPath<Model, Bool?>,
        real: (() -> Bool)? = nil,
        requiresRelaunch: Bool = false
    ) {
        let readReal: (() -> ControlValue)? = real.map { getReal in
            { ControlValue.bool(getReal()) }
        }
        addControl(
            key: key,
            label: label,
            kind: .triState,
            requiresRelaunch: requiresRelaunch,
            binding: KeyPathBinding(model: model, keyPath: keyPath),
            readReal: readReal
        )
    }

    /// A control that picks one case of a `String`-backed enum.
    public func choice<Value: RawRepresentable & CaseIterable>(
        _ label: String,
        key: String,
        _ keyPath: ReferenceWritableKeyPath<Model, Value>,
        requiresRelaunch: Bool = false
    ) where Value.RawValue == String {
        let options = Value.allCases.map { $0.rawValue }
        addControl(
            key: key,
            label: label,
            kind: .choice(options: options),
            requiresRelaunch: requiresRelaunch,
            binding: ChoiceBinding(model: model, keyPath: keyPath)
        )
    }

    /// A free-text control bound to a `String` property.
    public func text(
        _ label: String,
        key: String,
        _ keyPath: ReferenceWritableKeyPath<Model, String>,
        requiresRelaunch: Bool = false
    ) {
        addControl(
            key: key,
            label: label,
            kind: .text,
            requiresRelaunch: requiresRelaunch,
            binding: KeyPathBinding(model: model, keyPath: keyPath)
        )
    }

    /// A whole-number control bound to an `Int` property.
    public func integer(
        _ label: String,
        key: String,
        _ keyPath: ReferenceWritableKeyPath<Model, Int>,
        requiresRelaunch: Bool = false
    ) {
        addControl(
            key: key,
            label: label,
            kind: .integer,
            requiresRelaunch: requiresRelaunch,
            binding: KeyPathBinding(model: model, keyPath: keyPath)
        )
    }

    /// A decimal control bound to a `Double` property.
    public func decimal(
        _ label: String,
        key: String,
        _ keyPath: ReferenceWritableKeyPath<Model, Double>,
        requiresRelaunch: Bool = false
    ) {
        addControl(
            key: key,
            label: label,
            kind: .decimal,
            requiresRelaunch: requiresRelaunch,
            binding: KeyPathBinding(model: model, keyPath: keyPath)
        )
    }

    /// A date control bound to a `Date?` property, where `nil` means "use the
    /// real value".
    ///
    /// - Parameter real: Returns the real value, so the registry can report
    ///   the effective value when there is no override.
    public func date(
        _ label: String,
        key: String,
        _ keyPath: ReferenceWritableKeyPath<Model, Date?>,
        real: (() -> Date)? = nil,
        requiresRelaunch: Bool = false
    ) {
        let readReal: (() -> ControlValue)? = real.map { getReal in
            { ControlValue.date(getReal()) }
        }
        addControl(
            key: key,
            label: label,
            kind: .date,
            requiresRelaunch: requiresRelaunch,
            binding: KeyPathBinding(model: model, keyPath: keyPath),
            readReal: readReal
        )
    }

    /// A control that moves `SaveStateClock`. Its value is the date the clock
    /// was moved to, or `.null` when it runs on real time. Its effective value
    /// is `SaveStateClock.now`.
    ///
    /// A persisted override restarts from its date at each launch, so every
    /// launch begins in the same state.
    public func clock(_ label: String = "Clock", key: String = "clock") {
        addControl(
            key: key,
            label: label,
            kind: .date,
            requiresRelaunch: false,
            binding: ClockBinding(),
            defaultValue: .null,
            readEffective: { ControlValue.date(SaveStateClock.now) }
        )
    }

    // MARK: - Actions and scenarios

    /// A named piece of work, such as seeding data or resetting onboarding.
    ///
    /// - Parameter destructive: Marks actions that destroy data, so clients
    ///   ask before running them.
    public func action(
        _ label: String,
        key: String,
        destructive: Bool = false,
        perform: @escaping @MainActor () async throws -> Void
    ) {
        guard !actions.contains(where: { $0.key == key }) else {
            assertionFailure("SaveState: duplicate action key \"\(key)\"")
            return
        }
        actions.append(
            RegisteredAction(
                key: key,
                label: label,
                section: currentSection,
                isDestructive: destructive,
                perform: perform
            )
        )
    }

    /// A named state, such as `expired-trial`, that `apply` sets up by changing
    /// the model, moving the clock, or doing any other setup work.
    ///
    /// - Parameter summary: What the scenario sets up. Agents read it to pick
    ///   a scenario, so say what the app will show.
    public func scenario(
        _ label: String,
        key: String,
        summary: String? = nil,
        apply: @escaping @MainActor (Model) async throws -> Void
    ) {
        guard !scenarios.contains(where: { $0.key == key }) else {
            assertionFailure("SaveState: duplicate scenario key \"\(key)\"")
            return
        }
        scenarios.append(
            RegisteredScenario(
                key: key,
                label: label,
                section: currentSection,
                summary: summary,
                runner: ScenarioRunner(model: model, apply: apply)
            )
        )
    }

    // MARK: - Private

    private func addControl(
        key: String,
        label: String,
        kind: ControlKind,
        requiresRelaunch: Bool,
        binding: any ControlBinding,
        defaultValue: ControlValue? = nil,
        readReal: (() -> ControlValue)? = nil,
        readEffective: (() -> ControlValue)? = nil
    ) {
        guard !controls.contains(where: { $0.key == key }) else {
            assertionFailure("SaveState: duplicate control key \"\(key)\"")
            return
        }
        controls.append(
            Control(
                key: key,
                label: label,
                section: currentSection,
                kind: kind,
                requiresRelaunch: requiresRelaunch,
                defaultValue: defaultValue ?? binding.read(),
                binding: binding,
                readReal: readReal,
                readEffective: readEffective
            )
        )
    }
}

/// A registered control: its metadata plus the binding that reaches the app.
struct Control {
    let key: String
    let label: String
    let section: String?
    let kind: ControlKind
    let requiresRelaunch: Bool
    let defaultValue: ControlValue
    let binding: any ControlBinding
    /// Reads the real value, for controls whose `.null` means "no override".
    let readReal: (() -> ControlValue)?
    /// Reads the effective value, for controls that compute it themselves.
    let readEffective: (() -> ControlValue)?
}

struct RegisteredAction {
    let key: String
    let label: String
    let section: String?
    let isDestructive: Bool
    let perform: @MainActor () async throws -> Void
}

struct RegisteredScenario {
    let key: String
    let label: String
    let section: String?
    let summary: String?
    let runner: any ScenarioRunning
}

@MainActor
protocol ScenarioRunning: AnyObject {
    func run() async throws
}

@MainActor
final class ScenarioRunner<Model: AnyObject>: ScenarioRunning {
    private let model: Model
    private let apply: @MainActor (Model) async throws -> Void

    init(model: Model, apply: @escaping @MainActor (Model) async throws -> Void) {
        self.model = model
        self.apply = apply
    }

    func run() async throws {
        try await apply(model)
    }
}
