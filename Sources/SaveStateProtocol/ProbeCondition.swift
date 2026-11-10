/// What a wait for a probe waits for, such as `.atLeast(value: .int(5))`.
///
/// It encodes as JSON such as `{"atLeast": {"value": {"type": "int", "value": 5}}}`.
///
/// Integers and doubles compare by number, so `.int(5)` equals `.double(5)`. A
/// date probe also takes a `.string` holding an ISO 8601 date with a time zone.
/// `atLeast` and `atMost` apply only to numbers and dates.
///
/// Adding a case is a breaking wire change: bump `WireProtocol.version`.
public enum ProbeCondition: Codable, Hashable, Sendable {
    /// The probe's value equals `value`.
    case equals(value: ControlValue)
    /// The probe's value differs from `value`.
    case notEquals(value: ControlValue)
    /// The probe's value is `value` or more. Numbers and dates only.
    case atLeast(value: ControlValue)
    /// The probe's value is `value` or less. Numbers and dates only.
    case atMost(value: ControlValue)

    /// The value the condition compares against.
    public var value: ControlValue {
        switch self {
        case .equals(let value), .notEquals(let value), .atLeast(let value), .atMost(let value):
            return value
        }
    }

    /// Whether a probe's value meets the condition, or `nil` when the condition
    /// can't apply to it, such as `atLeast` on a Boolean or `equals` between a
    /// Boolean and a number.
    public func isMet(by probeValue: ControlValue) -> Bool? {
        switch (self, Operands(probeValue, value)) {
        case (_, nil), (.atLeast, .unordered?), (.atMost, .unordered?):
            return nil
        case (.equals, .ordered(let order)?):
            return order == .same
        case (.notEquals, .ordered(let order)?):
            return order != .same
        case (.atLeast, .ordered(let order)?):
            return order == .same || order == .greater
        case (.atMost, .ordered(let order)?):
            return order == .same || order == .less
        case (.equals, .unordered(let isEqual)?):
            return isEqual
        case (.notEquals, .unordered(let isEqual)?):
            return !isEqual
        }
    }
}

/// How a probe's value relates to a condition's value.
private enum Operands {
    enum Order {
        case less
        case same
        case greater
        /// Neither less, equal, nor greater, as with NaN.
        case none
    }

    /// Numbers and dates, which have an order.
    case ordered(Order)
    /// Booleans and strings, which are only equal or not.
    case unordered(isEqual: Bool)

    /// `nil` when the two values can't be compared.
    init?(_ value: ControlValue, _ target: ControlValue) {
        switch (value, target) {
        case (.int(let left), .int(let right)):
            self = .ordered(Self.order(left, right))
        case (.int(let left), .double(let right)):
            self = .ordered(Self.order(Double(left), right))
        case (.double(let left), .int(let right)):
            self = .ordered(Self.order(left, Double(right)))
        case (.double(let left), .double(let right)):
            self = .ordered(Self.order(left, right))
        case (.date(let left), .date(let right)):
            self = .ordered(Self.order(DateCoding.milliseconds(of: left), DateCoding.milliseconds(of: right)))
        case (.date, .string(let text)):
            guard let date = ControlValue(iso8601Date: text) else { return nil }
            self.init(value, date)
        case (.bool(let left), .bool(let right)):
            self = .unordered(isEqual: left == right)
        case (.string(let left), .string(let right)):
            self = .unordered(isEqual: left == right)
        default:
            return nil
        }
    }

    private static func order<Number: Comparable>(_ left: Number, _ right: Number) -> Order {
        if left < right { return .less }
        if left > right { return .greater }
        return left == right ? .same : .none
    }
}
