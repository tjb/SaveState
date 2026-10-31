import Foundation

/// The kind of a control, which decides the values it accepts.
///
/// It encodes as JSON such as `{"type": "toggle"}` or
/// `{"type": "choice", "options": ["staging", "production"]}`.
///
/// Adding a case is a breaking wire change: bump `WireProtocol.version`.
public enum ControlKind: Hashable, Sendable {
    /// On or off. Accepts `.bool`.
    case toggle
    /// On, off, or no override. Accepts `.bool` or `.null`.
    case triState
    /// One of a fixed set of options. Accepts `.string` holding one of them.
    case choice(options: [String])
    /// Free text. Accepts `.string`.
    case text
    /// A whole number. Accepts `.int`.
    case integer
    /// A finite decimal number. Accepts `.double`, or `.int` converted to a double.
    case decimal
    /// A date, or no override. Accepts `.null`, or a `.date` that JSON can carry
    /// unchanged, which leaves out dates before year 1 and in very distant years.
    case date
    /// The app's clock, moved through `SaveStateClock`. Accepts `.null` for real
    /// time, or a `.date` that JSON can carry unchanged.
    case clock

    /// Returns `value` in the form this kind stores, or `nil` when this kind
    /// doesn't accept it.
    public func normalize(_ value: ControlValue) -> ControlValue? {
        switch (self, value) {
        case (.toggle, .bool),
             (.triState, .bool),
             (.triState, .null),
             (.text, .string),
             (.integer, .int),
             (.date, .null),
             (.clock, .null):
            return value
        case (.decimal, .double(let number)):
            return number.isFinite ? value : nil
        case (.date, .date(let date)), (.clock, .date(let date)):
            return DateCoding.survivesRoundTrip(date) ? value : nil
        case (.choice(let options), .string(let option)):
            return options.contains(option) ? value : nil
        case (.decimal, .int(let number)):
            return .double(Double(number))
        default:
            return nil
        }
    }
}

extension ControlKind: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
        case options
    }

    private enum KindType: String, Codable {
        case toggle
        case triState
        case choice
        case text
        case integer
        case decimal
        case date
        case clock
    }

    /// Decodes a kind from `{"type": ...}`, plus `options` for a choice.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(KindType.self, forKey: .type) {
        case .toggle:
            self = .toggle
        case .triState:
            self = .triState
        case .choice:
            self = .choice(options: try container.decode([String].self, forKey: .options))
        case .text:
            self = .text
        case .integer:
            self = .integer
        case .decimal:
            self = .decimal
        case .date:
            self = .date
        case .clock:
            self = .clock
        }
    }

    /// Encodes the kind as `{"type": ...}`, plus `options` for a choice.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .toggle:
            try container.encode(KindType.toggle, forKey: .type)
        case .triState:
            try container.encode(KindType.triState, forKey: .type)
        case .choice(let options):
            try container.encode(KindType.choice, forKey: .type)
            try container.encode(options, forKey: .options)
        case .text:
            try container.encode(KindType.text, forKey: .type)
        case .integer:
            try container.encode(KindType.integer, forKey: .type)
        case .decimal:
            try container.encode(KindType.decimal, forKey: .type)
        case .date:
            try container.encode(KindType.date, forKey: .type)
        case .clock:
            try container.encode(KindType.clock, forKey: .type)
        }
    }
}
