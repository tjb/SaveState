import Foundation
import SaveState

/// Items that share a section, in the order the section first appears.
struct OverlayGroup<Item>: Identifiable {
    /// The section's title, or `nil` for items declared outside any section.
    let title: String?
    var items: [Item]

    var id: String? { title }

    /// Groups items by section. A section declared in two places shows once,
    /// where it first appears, so declaration order decides the panel's order.
    static func grouping(_ items: [Item], section: (Item) -> String?) -> [OverlayGroup<Item>] {
        var groups: [OverlayGroup<Item>] = []
        for item in items {
            let title = section(item)
            if let index = groups.firstIndex(where: { $0.title == title }) {
                groups[index].items.append(item)
            } else {
                groups.append(OverlayGroup(title: title, items: [item]))
            }
        }
        return groups
    }
}

extension ControlDescription {
    /// Whether the control has anything to reset: its value differs from its
    /// default, or a later launch would restore a value that does.
    var isChanged: Bool {
        if value != defaultValue { return true }
        guard let nextLaunchValue else { return false }
        return nextLaunchValue != defaultValue
    }
}

/// Converts between the text in an editor and a control's value.
enum ControlText {
    /// The text an editor shows for a value.
    static func text(for value: ControlValue, locale: Locale = .current) -> String {
        switch value {
        case .string(let text):
            return text
        case .int(let number):
            return String(number)
        case .double(let number):
            return decimalFormatter(locale: locale).string(from: NSNumber(value: number)) ?? String(number)
        case .null, .bool, .date:
            return ""
        }
    }

    /// The value typed text stands for, or `nil` when the kind can't accept it.
    static func value(from text: String, kind: ControlKind, locale: Locale = .current) -> ControlValue? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case .text:
            return .string(text)
        case .integer:
            return Int(trimmed).map(ControlValue.int)
        case .decimal:
            guard let number = decimalFormatter(locale: locale).number(from: trimmed)?.doubleValue,
                  number.isFinite
            else { return nil }
            return .double(number)
        case .toggle, .triState, .choice, .date, .clock:
            return nil
        }
    }

    private static func decimalFormatter(locale: Locale) -> NumberFormatter {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.maximumFractionDigits = 15
        return formatter
    }
}
