import Foundation

/// A control's value in a form that crosses the wire between an app's
/// `SaveStateAgent` endpoint and the `savestate` bridge.
///
/// It encodes as JSON such as `{"type": "bool", "value": true}`. Dates encode
/// as ISO 8601 strings with fractional seconds.
public enum ControlValue: Hashable, Sendable {
    /// No value. Optional controls use it to mean "no override, use the real value".
    case null
    /// A Boolean value.
    case bool(Bool)
    /// A string value. Choice controls use the option's raw value.
    case string(String)
    /// A whole number.
    case int(Int)
    /// A floating-point number.
    case double(Double)
    /// A date.
    case date(Date)
}

extension ControlValue: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
        case value
    }

    private enum ValueType: String, Codable {
        case null
        case bool
        case string
        case int
        case double
        case date
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(ValueType.self, forKey: .type) {
        case .null:
            self = .null
        case .bool:
            self = .bool(try container.decode(Bool.self, forKey: .value))
        case .string:
            self = .string(try container.decode(String.self, forKey: .value))
        case .int:
            self = .int(try container.decode(Int.self, forKey: .value))
        case .double:
            self = .double(try container.decode(Double.self, forKey: .value))
        case .date:
            let text = try container.decode(String.self, forKey: .value)
            guard let date = Self.makeDateFormatter().date(from: text) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .value,
                    in: container,
                    debugDescription: "Expected an ISO 8601 date but found \(text)."
                )
            }
            self = .date(date)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .null:
            try container.encode(ValueType.null, forKey: .type)
        case .bool(let value):
            try container.encode(ValueType.bool, forKey: .type)
            try container.encode(value, forKey: .value)
        case .string(let value):
            try container.encode(ValueType.string, forKey: .type)
            try container.encode(value, forKey: .value)
        case .int(let value):
            try container.encode(ValueType.int, forKey: .type)
            try container.encode(value, forKey: .value)
        case .double(let value):
            try container.encode(ValueType.double, forKey: .type)
            try container.encode(value, forKey: .value)
        case .date(let value):
            try container.encode(ValueType.date, forKey: .type)
            try container.encode(Self.makeDateFormatter().string(from: value), forKey: .value)
        }
    }

    private static func makeDateFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }
}
