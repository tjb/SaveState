import SaveState
import SwiftUI

/// The debug panel: every control in a registry, then its actions and scenarios.
///
/// ``SaveStateOverlay`` presents it in a popover. Use it directly to show the
/// panel somewhere else, such as a settings screen. Changes made here persist
/// across relaunches until they're reset. It shows nothing when the registry is
/// disabled.
public struct SaveStatePanel: View {
    private let registry: SaveStateRegistry

    @State private var message: PanelMessage?
    @State private var runningKey: String?
    @State private var actionToConfirm: ActionDescription?

    /// Creates the panel for a registry.
    public init(registry: SaveStateRegistry) {
        self.registry = registry
    }

    public var body: some View {
        if registry.isEnabled {
            panel(registry.describe())
        }
    }

    private func panel(_ description: RegistryDescription) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            header(changedCount: description.controls.filter(\.isChanged).count)
            if let message {
                messageLabel(message)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    controls(description.controls)
                    actions(description.actions)
                    scenarios(description.scenarios)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                // Keeps the edges of glass controls from clipping at the scroll view.
                .padding(.horizontal, 2)
            }
            .padding(.horizontal, -2)
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: 480)
        }
        .padding()
        .frame(width: 340)
        // The panel has a fixed width, so keep the largest sizes from
        // squeezing the controls.
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .alert(
            "Run \(actionToConfirm?.label ?? "action")?",
            isPresented: Binding(
                get: { actionToConfirm != nil },
                set: { if !$0 { actionToConfirm = nil } }
            ),
            presenting: actionToConfirm
        ) { action in
            Button("Run", role: .destructive) {
                run(action, allowDestructive: true)
            }
            .accessibilityIdentifier("saveState.confirmAction")
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("This action destroys data.")
        }
    }

    // MARK: - Header

    private func header(changedCount: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Debug Panel")
                    .font(.headline)
                Spacer()
                Button("Reset All", action: resetAll)
                    .controlSize(.small)
                    .overlayPanelButtonStyle()
                    .disabled(changedCount == 0)
                    .accessibilityIdentifier("saveState.resetAll")
            }
            Group {
                if changedCount == 0 {
                    Label("Everything at its default", systemImage: "checkmark.seal")
                        .foregroundStyle(.secondary)
                } else {
                    Label(
                        changedCount == 1 ? "1 control changed" : "\(changedCount) controls changed",
                        systemImage: "wrench.and.screwdriver"
                    )
                    .foregroundStyle(.orange)
                }
            }
            .font(.footnote)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("saveState.status")
        }
    }

    private func messageLabel(_ message: PanelMessage) -> some View {
        Label(message.text, systemImage: message.isError ? "exclamationmark.triangle" : "checkmark.circle")
            .font(.footnote)
            .foregroundStyle(message.isError ? .red : .green)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("saveState.message")
    }

    // MARK: - Sections

    @ViewBuilder
    private func controls(_ controls: [ControlDescription]) -> some View {
        ForEach(OverlayGroup.grouping(controls, section: \.section)) { group in
            VStack(alignment: .leading, spacing: 12) {
                if let title = group.title {
                    sectionHeader(title)
                }
                ForEach(group.items, id: \.key) { control in
                    ControlRow(
                        control: control,
                        change: { change($0, of: control) },
                        reset: { reset(control) }
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func actions(_ actions: [ActionDescription]) -> some View {
        if !actions.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                sectionHeader("Actions")
                ForEach(OverlayGroup.grouping(actions, section: \.section)) { group in
                    if let title = group.title {
                        Text(title).font(.footnote).foregroundStyle(.secondary)
                    }
                    ForEach(group.items, id: \.key) { action in
                        actionButton(action)
                    }
                }
            }
        }
    }

    private func actionButton(_ action: ActionDescription) -> some View {
        Button(role: action.isDestructive ? .destructive : nil) {
            if action.isDestructive {
                actionToConfirm = action
            } else {
                run(action, allowDestructive: false)
            }
        } label: {
            HStack {
                Text(action.label)
                    // Glass buttons don't color destructive roles themselves.
                    .foregroundStyle(action.isDestructive ? .red : .primary)
                Spacer()
                if runningKey == action.key {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .overlayPanelButtonStyle()
        .disabled(runningKey != nil)
        .accessibilityIdentifier("saveState.action.\(action.key)")
    }

    @ViewBuilder
    private func scenarios(_ scenarios: [ScenarioDescription]) -> some View {
        if !scenarios.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                sectionHeader("Scenarios")
                ForEach(OverlayGroup.grouping(scenarios, section: \.section)) { group in
                    if let title = group.title {
                        Text(title).font(.footnote).foregroundStyle(.secondary)
                    }
                    ForEach(group.items, id: \.key) { scenario in
                        scenarioButton(scenario)
                    }
                }
            }
        }
    }

    private func scenarioButton(_ scenario: ScenarioDescription) -> some View {
        Button {
            apply(scenario)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(scenario.label)
                    if let summary = scenario.summary {
                        Text(summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer()
                if runningKey == scenario.key {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .overlayPanelButtonStyle()
        .buttonBorderShape(.roundedRectangle(radius: 12))
        .disabled(runningKey != nil)
        .accessibilityIdentifier("saveState.scenario.\(scenario.key)")
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .accessibilityAddTraits(.isHeader)
    }

    // MARK: - Changing

    private func change(_ value: ControlValue, of control: ControlDescription) {
        perform { try registry.set(value, forKey: control.key, persist: true) }
    }

    private func reset(_ control: ControlDescription) {
        perform { try registry.reset(control.key) }
    }

    private func resetAll() {
        perform { try registry.resetAll() }
    }

    private func perform(_ change: () throws -> Void) {
        do {
            try change()
            message = nil
        } catch {
            message = PanelMessage(text: String(describing: error), isError: true)
        }
    }

    private func run(_ action: ActionDescription, allowDestructive: Bool) {
        runInBackground(key: action.key, success: "Ran \(action.label)") {
            try await registry.runAction(action.key, allowDestructive: allowDestructive)
        }
    }

    private func apply(_ scenario: ScenarioDescription) {
        runInBackground(key: scenario.key, success: "Applied \(scenario.label)") {
            try await registry.applyScenario(scenario.key)
        }
    }

    private func runInBackground(
        key: String,
        success: String,
        work: @escaping @MainActor () async throws -> Void
    ) {
        runningKey = key
        message = nil
        Task {
            defer { runningKey = nil }
            do {
                try await work()
                message = PanelMessage(text: success, isError: false)
            } catch {
                message = PanelMessage(text: String(describing: error), isError: true)
            }
        }
    }
}

/// A line at the top of the panel reporting how the last operation went.
private struct PanelMessage {
    let text: String
    let isError: Bool
}
