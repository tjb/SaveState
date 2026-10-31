import Foundation

/// A control's value in a form that crosses the wire between an app's
/// `SaveStateAgent` endpoint and the `savestate` bridge.
///
/// It encodes as JSON such as `{"type": "bool", "value": true}`. Dates encode
/// as ISO 8601 strings in UTC with milliseconds, and decode with or without
/// fractional seconds. Dates compare at millisecond precision, so a date
/// survives a round trip through JSON unchanged.
///
/// Adding a case is a breaking wire change: bump `WireProtocol.version`.
public enum ControlValue: Sendable {
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

extension ControlValue: Hashable {
    /// Compares values of the same case. Dates compare at millisecond precision.
    public static func == (lhs: ControlValue, rhs: ControlValue) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null):
            return true
        case (.bool(let left), .bool(let right)):
            return left == right
        case (.string(let left), .string(let right)):
            return left == right
        case (.int(let left), .int(let right)):
            return left == right
        case (.double(let left), .double(let right)):
            return left == right
        case (.date(let left), .date(let right)):
            return DateCoding.milliseconds(of: left) == DateCoding.milliseconds(of: right)
        default:
            return false
        }
    }

    /// Hashes the value consistently with `==`.
    public func hash(into hasher: inout Hasher) {
        switch self {
        case .null:
            hasher.combine(0)
        case .bool(let value):
            hasher.combine(1)
            hasher.combine(value)
        case .string(let value):
            hasher.combine(2)
            hasher.combine(value)
        case .int(let value):
            hasher.combine(3)
            hasher.combine(value)
        case .double(let value):
            hasher.combine(4)
            hasher.combine(value)
        case .date(let value):
            hasher.combine(5)
            hasher.combine(DateCoding.milliseconds(of: value))
        }
    }
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

    /// Decodes a value from `{"type": ..., "value": ...}`.
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
            guard let date = DateCoding.date(from: text) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .value,
                    in: container,
                    debugDescription: "Expected an ISO 8601 date but found \(text)."
                )
            }
            self = .date(date)
        }
    }

    /// Encodes the value as `{"type": ..., "value": ...}`.
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
            try container.encode(DateCoding.string(from: value), forKey: .value)
        }
    }
}

/// Millisecond-precision ISO 8601 dates.
enum DateCoding {
    /// The date in whole milliseconds since 1970, rounded to the nearest.
    static func milliseconds(of date: Date) -> Int64 {
        let milliseconds = (date.timeIntervalSince1970 * 1000).rounded()
        guard milliseconds.isFinite else { return milliseconds > 0 ? .max : .min }
        return Int64(max(min(milliseconds, 9.2e18), -9.2e18))
    }

    /// Formats a date such as `2027-01-15T08:00:00.250Z`.
    ///
    /// The milliseconds are computed here rather than by the formatter, which
    /// truncates, so every date in the same millisecond formats the same way.
    static func string(from date: Date) -> String {
        let milliseconds = Self.milliseconds(of: date)
        var seconds = milliseconds / 1000
        var fraction = milliseconds % 1000
        if fraction < 0 {
            seconds -= 1
            fraction += 1000
        }
        // The formatter ends whole seconds in UTC with "Z", which goes after
        // the milliseconds instead.
        let whole = String(
            makeFormatter(fractionalSeconds: false)
                .string(from: Date(timeIntervalSince1970: TimeInterval(seconds)))
                .dropLast()
        )
        let digits = String(fraction)
        let padding = String(repeating: "0", count: 3 - digits.count)
        return "\(whole).\(padding)\(digits)Z"
    }

    /// Parses an ISO 8601 date with or without fractional seconds.
    static func date(from text: String) -> Date? {
        makeFormatter(fractionalSeconds: true).date(from: text)
            ?? makeFormatter(fractionalSeconds: false).date(from: text)
    }

    private static func makeFormatter(fractionalSeconds: Bool) -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = fractionalSeconds
            ? [.withInternetDateTime, .withFractionalSeconds]
            : [.withInternetDateTime]
        return formatter
    }
}
