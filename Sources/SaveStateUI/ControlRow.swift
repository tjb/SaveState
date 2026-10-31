import SaveState
import SwiftUI

/// One control: its label, its markers, a reset button, and its editor.
struct ControlRow: View {
    let control: ControlDescription
    let resetAllCount: Int
    let change: (ControlValue) -> Void
    let reset: () -> Void

    @State private var resetCount = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                title
                Spacer(minLength: 4)
                if control.isChanged {
                    resetButton
                }
                inlineEditor
            }
            editorBelow
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("saveState.row.\(control.key)")
    }

    private var title: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(control.label)
                .font(.subheadline)
                // Every editor carries the label for VoiceOver.
                .accessibilityHidden(true)
            if control.isChanged || control.requiresRelaunch {
                HStack(spacing: 8) {
                    if control.isChanged {
                        Label("Changed", systemImage: "wrench.and.screwdriver")
                            .foregroundStyle(.orange)
                            .accessibilityIdentifier("saveState.changed.\(control.key)")
                    }
                    if control.requiresRelaunch {
                        Label("Applies on relaunch", systemImage: "arrow.clockwise.circle")
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("saveState.relaunch.\(control.key)")
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
        .accessibilityIdentifier("saveState.reset.\(control.key)")
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
        "saveState.control.\(control.key)"
    }

    private var boolBinding: Binding<Bool> {
        Binding(
            get: { control.value == .bool(true) },
            set: { change(.bool($0)) }
        )
    }

    private var stringBinding: Binding<String> {
        Binding(
            get: {
                if case .string(let option) = control.value { return option }
                return ""
            },
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
                Text("On").tag(ControlValue.bool(true))
                Text("Off").tag(ControlValue.bool(false))
                Text("Real").tag(ControlValue.null)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityIdentifier(identifier)

            if case .bool(let real)? = control.realValue {
                Text("Real value: \(real ? "on" : "off")")
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

    @State private var draft: String
    @State private var isInvalid = false
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
        _draft = State(initialValue: ControlText.text(for: control.value))
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
                    draft = ControlText.text(for: value)
                    isInvalid = false
                }
                .onChange(of: resetToken) {
                    draft = ControlText.text(for: control.value)
                    isInvalid = false
                }
                .onDisappear(perform: applyDraft)
                .accessibilityIdentifier(identifier)
            if isInvalid {
                Text(control.kind == .integer ? "Enter a whole number." : "Enter a number.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private var field: some View {
        let textField = TextField(control.label, text: $draft)
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
        // Displayed numbers are rounded, so unedited text must not write back.
        guard draft != ControlText.text(for: control.value) else {
            isInvalid = false
            return
        }
        guard let value = ControlText.value(from: draft, kind: control.kind) else {
            isInvalid = true
            return
        }
        isInvalid = false
        change(value)
    }
}

// MARK: - Dates

private struct DateEditor: View {
    let control: ControlDescription
    let change: (ControlValue) -> Void
    let identifier: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if case .date(let date) = control.value {
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
                    .accessibilityIdentifier("\(identifier).clear")
                }
            } else {
                HStack {
                    Text(control.realValue == nil ? "Not set" : "Using real value")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Set") {
                        change(.date(realDate ?? SaveStateClock.now))
                    }
                    .accessibilityLabel("Set \(control.label)")
                    .controlSize(.small)
                    .overlayPanelButtonStyle()
                    .accessibilityIdentifier("\(identifier).set")
                }
            }
            if let realDate {
                Text("Real value: \(realDate.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var realDate: Date? {
        if case .date(let date)? = control.realValue { return date }
        return nil
    }
}

// MARK: - Clock

/// Moves `SaveStateClock`: shows the running time, jumps by common amounts,
/// picks a date, or returns to real time.
private struct ClockEditor: View {
    private static let day: TimeInterval = 86_400

    let control: ControlDescription
    let change: (ControlValue) -> Void
    let identifier: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                Text(SaveStateClock.now.formatted(date: .abbreviated, time: .standard))
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(isMoved ? .orange : .secondary)
                    .accessibilityIdentifier("\(identifier).now")
            }
            HStack(spacing: 6) {
                jump("-1d", accessibilityLabel: "Back one day", by: -Self.day)
                jump("+1d", accessibilityLabel: "Forward one day", by: Self.day)
                jump("+1w", accessibilityLabel: "Forward one week", by: 7 * Self.day)
                jump("+30d", accessibilityLabel: "Forward thirty days", by: 30 * Self.day)
            }
            HStack {
                DatePicker(
                    control.label,
                    selection: Binding(
                        get: { movedDate ?? SaveStateClock.now },
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
                .disabled(!isMoved)
                .accessibilityIdentifier("\(identifier).clear")
            }
        }
    }

    private var movedDate: Date? {
        if case .date(let date) = control.value { return date }
        return nil
    }

    private var isMoved: Bool {
        movedDate != nil
    }

    private func jump(_ title: String, accessibilityLabel: String, by interval: TimeInterval) -> some View {
        Button(title) {
            change(.date(SaveStateClock.now.addingTimeInterval(interval)))
        }
        .font(.caption.monospacedDigit())
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .controlSize(.small)
        .overlayPanelButtonStyle()
        .accessibilityLabel(accessibilityLabel)
    }
}
