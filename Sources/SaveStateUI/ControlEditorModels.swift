import Foundation
import SaveState
import SwiftUI

/// What one row shows around its editor, and the identifiers UI tests find it by.
struct ControlRowModel {
    let control: ControlDescription

    var showsReset: Bool { control.isChanged }
    var showsMarkers: Bool { showsChangedMarker || showsRelaunchMarker }
    var showsChangedMarker: Bool { control.isChanged }
    var showsRelaunchMarker: Bool { control.requiresRelaunch }

    /// The toggle's state. Only `.bool(true)` is on.
    var isOn: Bool { control.value == .bool(true) }

    /// The picker's selection, or an empty string when the value isn't a string.
    var selectedOption: String {
        if case .string(let option) = control.value { return option }
        return ""
    }

    var rowIdentifier: String { "saveState.row.\(control.key)" }
    var editorIdentifier: String { "saveState.control.\(control.key)" }
    var resetIdentifier: String { "saveState.reset.\(control.key)" }
    var changedIdentifier: String { "saveState.changed.\(control.key)" }
    var relaunchIdentifier: String { "saveState.relaunch.\(control.key)" }

    static func clearIdentifier(editor: String) -> String { "\(editor).clear" }
    static func setIdentifier(editor: String) -> String { "\(editor).set" }
    static func nowIdentifier(editor: String) -> String { "\(editor).now" }
}

/// One segment of the tri-state picker.
struct TriStateOption {
    let title: String
    let value: ControlValue

    static let all = [
        TriStateOption(title: "On", value: .bool(true)),
        TriStateOption(title: "Off", value: .bool(false)),
        TriStateOption(title: "Real", value: .null)
    ]

    /// The segment's title as SwiftUI shows it, as a localization key.
    var titleKey: LocalizedStringKey {
        LocalizedStringKey(title)
    }

    /// The caption under the picker, when the control reports a real value.
    static func realCaption(for control: ControlDescription) -> String? {
        guard case .bool(let real)? = control.realValue else { return nil }
        return "Real value: \(real ? "on" : "off")"
    }

    /// The caption as SwiftUI shows it, as a localization key.
    static func realCaptionKey(for control: ControlDescription) -> LocalizedStringKey? {
        guard case .bool(let real)? = control.realValue else { return nil }
        return "Real value: \(real ? "on" : "off")"
    }
}

/// The text in a text or number editor and whether it failed to apply. Changes
/// apply when you finish typing rather than on each keystroke, so half-typed
/// values never reach the app or storage.
struct TextDraft: Equatable {
    var text: String
    private(set) var isInvalid = false
    private let locale: Locale

    init(value: ControlValue, locale: Locale = .current) {
        self.locale = locale
        text = ControlText.text(for: value, locale: locale)
    }

    /// Replaces what was typed with the text for a value, after that value
    /// changes elsewhere or a reset discards the draft.
    mutating func discard(showing value: ControlValue) {
        text = ControlText.text(for: value, locale: locale)
        isInvalid = false
    }

    /// Whether the text differs from what the editor shows for a value, so there's
    /// typing a reset would discard. Invalid text counts.
    func isEdited(comparedTo value: ControlValue) -> Bool {
        text != ControlText.text(for: value, locale: locale)
    }

    /// Finishes typing.
    ///
    /// - Returns: The value to write, or `nil` when there's nothing to write
    ///   because the text is unedited or invalid.
    mutating func apply(to control: ControlDescription) -> ControlValue? {
        // Displayed numbers are rounded, so unedited text must not write back.
        guard isEdited(comparedTo: control.value) else {
            isInvalid = false
            return nil
        }
        guard let value = ControlText.value(from: text, kind: control.kind, locale: locale) else {
            isInvalid = true
            return nil
        }
        isInvalid = false
        return value
    }

    /// The hint shown under an invalid draft.
    static func invalidMessage(for kind: ControlKind) -> String {
        kind == .integer ? "Enter a whole number." : "Enter a number."
    }

    /// The hint as SwiftUI shows it, as a localization key.
    static func invalidMessageKey(for kind: ControlKind) -> LocalizedStringKey {
        LocalizedStringKey(invalidMessage(for: kind))
    }
}

/// What a date editor shows and which date its Set button picks.
struct DateEditorModel {
    let control: ControlDescription

    /// The override being edited, or `nil` when the Set button shows instead.
    var date: Date? {
        if case .date(let date) = control.value { return date }
        return nil
    }

    var realDate: Date? {
        if case .date(let date)? = control.realValue { return date }
        return nil
    }

    /// Shown in place of the picker when there's no override.
    var placeholder: String {
        control.realValue == nil ? "Not set" : "Using real value"
    }

    /// The placeholder as SwiftUI shows it, as a localization key.
    var placeholderKey: LocalizedStringKey {
        LocalizedStringKey(placeholder)
    }

    /// The caption as SwiftUI shows it, as a localization key.
    var realCaptionKey: LocalizedStringKey? {
        realDate.map { "Real value: \($0.formatted(date: .abbreviated, time: .shortened))" }
    }

    /// The caption under the editor, when the control reports a real date.
    var realCaption: String? {
        realDate.map { "Real value: \($0.formatted(date: .abbreviated, time: .shortened))" }
    }

    /// Set starts from the real date when there is one, so the override begins
    /// where the app already is.
    func dateForSet(now: Date) -> Date {
        realDate ?? now
    }
}

/// A button that moves the clock by a fixed amount.
struct ClockJump {
    private static let day: TimeInterval = 86_400

    let title: String
    let accessibilityLabel: String
    let interval: TimeInterval

    static let all = [
        ClockJump(title: "-1d", accessibilityLabel: "Back one day", interval: -day),
        ClockJump(title: "+1d", accessibilityLabel: "Forward one day", interval: day),
        ClockJump(title: "+1w", accessibilityLabel: "Forward one week", interval: 7 * day),
        ClockJump(title: "+30d", accessibilityLabel: "Forward thirty days", interval: 30 * day)
    ]

    /// Where the jump lands. Jumps add up, because they start from the running
    /// clock rather than real time.
    func target(from now: Date) -> Date {
        now.addingTimeInterval(interval)
    }
}

/// Whether the clock control has moved the clock, and what its picker shows.
struct ClockEditorModel {
    let control: ControlDescription

    var movedDate: Date? {
        if case .date(let date) = control.value { return date }
        return nil
    }

    var isMoved: Bool { movedDate != nil }

    /// The date the clock was moved to, or the running time when it hasn't moved.
    func pickerDate(now: Date) -> Date {
        movedDate ?? now
    }
}
