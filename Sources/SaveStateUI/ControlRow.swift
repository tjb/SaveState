import SaveState
import SwiftUI

/// One control: its label, its markers, a reset button, and its editor.
struct ControlRow: View {
    let control: ControlDescription
    let resetAllCount: Int
    let change: (ControlValue) -> Void
    let reset: () -> Void

    @State private var resetCount = 0

    private var model: ControlRowModel {
        ControlRowModel(control: control)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                title
                Spacer(minLength: 4)
                if model.showsReset {
                    resetButton
                }
                inlineEditor
            }
            editorBelow
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(model.rowIdentifier)
    }

    private var title: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(control.label)
                .font(.subheadline)
                // Every editor carries the label for VoiceOver.
                .accessibilityHidden(true)
            if model.showsMarkers {
                HStack(spacing: 8) {
                    if model.showsChangedMarker {
                        Label("Changed", systemImage: "wrench.and.screwdriver")
                            .foregroundStyle(.orange)
                            .accessibilityIdentifier(model.changedIdentifier)
                    }
                    if model.showsRelaunchMarker {
                        Label("Applies on relaunch", systemImage: "arrow.clockwise.circle")
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier(model.relaunchIdentifier)
                    }
                }
                .font(.caption2)
            }
        }
    }

    private var resetButton: some View {
        Button {
            reset()
            resetCount += 1
        } label: {
            Label("Reset \(control.label)", systemImage: "arrow.uturn.backward")
                .labelStyle(.iconOnly)
                .font(.caption)
        }
        .buttonStyle(.borderless)
        .accessibilityIdentifier(model.resetIdentifier)
    }

    /// Editors small enough to share the title's line.
    @ViewBuilder
    private var inlineEditor: some View {
        switch control.kind {
        case .toggle:
            Toggle(control.label, isOn: boolBinding)
                .labelsHidden()
                .accessibilityIdentifier(editorIdentifier)
        case .choice(let options):
            Picker(control.label, selection: stringBinding) {
                ForEach(options, id: \.self) { option in
                    Text(option).tag(option)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .accessibilityIdentifier(editorIdentifier)
        case .triState, .text, .integer, .decimal, .date, .clock:
            EmptyView()
        }
    }

    @ViewBuilder
    private var editorBelow: some View {
        switch control.kind {
        case .toggle, .choice:
            EmptyView()
        case .triState:
            TriStateEditor(control: control, change: change, identifier: editorIdentifier)
        case .text, .integer, .decimal:
            TextEditorField(
                control: control,
                resetToken: resetCount + resetAllCount,
                change: change,
                identifier: editorIdentifier
            )
        case .date:
            DateEditor(control: control, change: change, identifier: editorIdentifier)
        case .clock:
            ClockEditor(control: control, change: change, identifier: editorIdentifier)
        }
    }

    private var editorIdentifier: String {
        model.editorIdentifier
    }

    private var boolBinding: Binding<Bool> {
        Binding(
            get: { model.isOn },
            set: { change(.bool($0)) }
        )
    }

    private var stringBinding: Binding<String> {
        Binding(
            get: { model.selectedOption },
            set: { change(.string($0)) }
        )
    }
}

// MARK: - Tri-state

private struct TriStateEditor: View {
    let control: ControlDescription
    let change: (ControlValue) -> Void
    let identifier: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker(control.label, selection: Binding(
                get: { control.value },
                set: { change($0) }
            )) {
                ForEach(TriStateOption.all, id: \.value) { option in
                    Text(option.title).tag(option.value)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityIdentifier(identifier)

            if let caption = TriStateOption.realCaption(for: control) {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Text and numbers

/// Edits text, whole numbers, and decimals. Changes apply when you finish
/// typing rather than on each keystroke, so half-typed values never reach the
/// app or storage.
private struct TextEditorField: View {
    let control: ControlDescription
    /// Changes on each reset, which discards the draft even when the reset
    /// leaves the value as it was.
    let resetToken: Int
    let change: (ControlValue) -> Void
    let identifier: String

    @State private var draft: TextDraft
    @FocusState private var isFocused: Bool

    init(
        control: ControlDescription,
        resetToken: Int,
        change: @escaping (ControlValue) -> Void,
        identifier: String
    ) {
        self.control = control
        self.resetToken = resetToken
        self.change = change
        self.identifier = identifier
        _draft = State(initialValue: TextDraft(value: control.value))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            field
                .textFieldStyle(.roundedBorder)
                .focused($isFocused)
                .onSubmit(applyDraft)
                .onChange(of: isFocused) { _, focused in
                    if !focused { applyDraft() }
                }
                .onChange(of: control.value) { _, value in
                    draft.discard(showing: value)
                }
                .onChange(of: resetToken) {
                    draft.discard(showing: control.value)
                }
                .onDisappear(perform: applyDraft)
                .accessibilityIdentifier(identifier)
            if draft.isInvalid {
                Text(TextDraft.invalidMessage(for: control.kind))
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private var field: some View {
        let textField = TextField(control.label, text: $draft.text)
        #if os(iOS)
        switch control.kind {
        case .integer, .decimal:
            // This keyboard has a minus sign and a return key; the number pads
            // have neither.
            textField
                .keyboardType(.numbersAndPunctuation)
                .autocorrectionDisabled()
        default:
            textField
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
        #else
        textField
        #endif
    }

    private func applyDraft() {
        if let value = draft.apply(to: control) {
            change(value)
        }
    }
}

// MARK: - Dates

private struct DateEditor: View {
    let control: ControlDescription
    let change: (ControlValue) -> Void
    let identifier: String

    private var model: DateEditorModel {
        DateEditorModel(control: control)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let date = model.date {
                HStack {
                    DatePicker(
                        control.label,
                        selection: Binding(get: { date }, set: { change(.date($0)) })
                    )
                    .labelsHidden()
                    .accessibilityIdentifier(identifier)
                    Spacer()
                    Button {
                        change(.null)
                    } label: {
                        Label("Clear \(control.label)", systemImage: "xmark.circle.fill")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier(ControlRowModel.clearIdentifier(editor: identifier))
                }
            } else {
                HStack {
                    Text(model.placeholder)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Set") {
                        change(.date(model.dateForSet(now: SaveStateClock.now)))
                    }
                    .accessibilityLabel("Set \(control.label)")
                    .controlSize(.small)
                    .overlayPanelButtonStyle()
                    .accessibilityIdentifier(ControlRowModel.setIdentifier(editor: identifier))
                }
            }
            if let caption = model.realCaption {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Clock

/// Moves `SaveStateClock`: shows the running time, jumps by common amounts,
/// picks a date, or returns to real time.
private struct ClockEditor: View {
    let control: ControlDescription
    let change: (ControlValue) -> Void
    let identifier: String

    private var model: ClockEditorModel {
        ClockEditorModel(control: control)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                Text(SaveStateClock.now.formatted(date: .abbreviated, time: .standard))
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(model.isMoved ? .orange : .secondary)
                    .accessibilityIdentifier(ControlRowModel.nowIdentifier(editor: identifier))
            }
            HStack(spacing: 6) {
                ForEach(ClockJump.all, id: \.title) { jump in
                    jumpButton(jump)
                }
            }
            HStack {
                DatePicker(
                    control.label,
                    selection: Binding(
                        get: { model.pickerDate(now: SaveStateClock.now) },
                        set: { change(.date($0)) }
                    )
                )
                .labelsHidden()
                .accessibilityIdentifier(identifier)
                Spacer()
                Button("Real Time") {
                    change(.null)
                }
                .lineLimit(1)
                .fixedSize()
                .controlSize(.small)
                .overlayPanelButtonStyle()
                .disabled(!model.isMoved)
                .accessibilityIdentifier(ControlRowModel.clearIdentifier(editor: identifier))
            }
        }
    }

    private func jumpButton(_ jump: ClockJump) -> some View {
        Button(jump.title) {
            change(.date(jump.target(from: SaveStateClock.now)))
        }
        .font(.caption.monospacedDigit())
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .controlSize(.small)
        .overlayPanelButtonStyle()
        .accessibilityLabel(jump.accessibilityLabel)
    }
}
