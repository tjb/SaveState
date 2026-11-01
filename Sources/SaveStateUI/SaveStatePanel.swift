import SaveState
import SwiftUI

/// The debug panel: every control in a registry, then its actions and scenarios.
///
/// ``SaveStateOverlay`` presents it in a popover. It has a fixed width and scrolls
/// its own content, so if you present it yourself, use a popover or sheet rather
/// than embedding it in a list. Changes made here persist across relaunches until
/// they're reset. It shows nothing when the registry is disabled.
public struct SaveStatePanel: View {
    private let registry: SaveStateRegistry

    @State private var runState: PanelRunState
    @State private var session = PanelSession()

    /// Creates the panel for a registry.
    public init(registry: SaveStateRegistry) {
        self.init(registry: registry, runState: PanelRunState())
    }

    init(registry: SaveStateRegistry, runState: PanelRunState) {
        self.registry = registry
        _runState = State(initialValue: runState)
    }

    public var body: some View {
        if model.isVisible {
            panel(registry.describe())
        }
    }

    private var model: PanelModel {
        PanelModel(registry: registry, runState: runState, session: session)
    }

    private func panel(_ description: RegistryDescription) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            header(PanelStatus(description))
            if let message = runState.message {
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
            model.confirmationTitleKey,
            isPresented: Binding(
                get: { session.actionToConfirm != nil },
                set: { if !$0 { model.cancelConfirmation() } }
            ),
            presenting: session.actionToConfirm
        ) { action in
            Button("Run", role: .destructive) {
                model.confirm(action)
            }
            .accessibilityIdentifier("saveState.confirmAction")
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("This action destroys data.")
        }
    }

    // MARK: - Header

    private func header(_ status: PanelStatus) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Debug Panel")
                    .font(.headline)
                Spacer()
                Button("Reset All") { model.resetAll() }
                    .controlSize(.small)
                    .overlayPanelButtonStyle()
                    .disabled(!status.canResetAll)
                    .accessibilityIdentifier("saveState.resetAll")
            }
            Group {
                if status.isAtDefault {
                    Label(status.textKey, systemImage: status.systemImage)
                        .foregroundStyle(.secondary)
                } else {
                    Label(status.textKey, systemImage: status.systemImage)
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
                        resetAllCount: session.resetAllCount,
                        change: { model.change($0, of: control) },
                        reset: { model.reset(control) }
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
            model.request(action)
        } label: {
            HStack {
                Text(action.label)
                    // Glass buttons don't color destructive roles themselves.
                    .foregroundStyle(action.isDestructive ? .red : .primary)
                Spacer()
                if model.isRunning(action.key) {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .overlayPanelButtonStyle()
        .disabled(model.isBusy)
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
            model.apply(scenario)
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
                if model.isRunning(scenario.key) {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .overlayPanelButtonStyle()
        .buttonBorderShape(.roundedRectangle(radius: 12))
        .disabled(model.isBusy)
        .accessibilityIdentifier("saveState.scenario.\(scenario.key)")
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .accessibilityAddTraits(.isHeader)
    }
}
