import Foundation
import SaveStateProtocol

/// Reads and writes one control's value in the app.
@MainActor
protocol ControlBinding: AnyObject {
    func read() -> ControlValue
    func write(_ value: ControlValue)
}

/// Swift types that map to and from a `ControlValue`.
protocol ControlValueConvertible {
    var controlValue: ControlValue { get }
    init?(controlValue: ControlValue)
}

extension Bool: ControlValueConvertible {
    var controlValue: ControlValue { .bool(self) }

    init?(controlValue: ControlValue) {
        guard case .bool(let value) = controlValue else { return nil }
        self = value
    }
}

extension String: ControlValueConvertible {
    var controlValue: ControlValue { .string(self) }

    init?(controlValue: ControlValue) {
        guard case .string(let value) = controlValue else { return nil }
        self = value
    }
}

extension Int: ControlValueConvertible {
    var controlValue: ControlValue { .int(self) }

    init?(controlValue: ControlValue) {
        guard case .int(let value) = controlValue else { return nil }
        self = value
    }
}

extension Double: ControlValueConvertible {
    var controlValue: ControlValue { .double(self) }

    init?(controlValue: ControlValue) {
        switch controlValue {
        case .double(let value):
            self = value
        case .int(let value):
            self = Double(value)
        default:
            return nil
        }
    }
}

extension Date: ControlValueConvertible {
    var controlValue: ControlValue { .date(self) }

    init?(controlValue: ControlValue) {
        guard case .date(let value) = controlValue else { return nil }
        self = value
    }
}

extension Optional: ControlValueConvertible where Wrapped: ControlValueConvertible {
    var controlValue: ControlValue {
        switch self {
        case .some(let wrapped):
            return wrapped.controlValue
        case .none:
            return .null
        }
    }

    init?(controlValue: ControlValue) {
        if case .null = controlValue {
            self = .none
        } else if let wrapped = Wrapped(controlValue: controlValue) {
            self = .some(wrapped)
        } else {
            return nil
        }
    }
}

/// Binds a control to a property of the registry's model.
@MainActor
final class KeyPathBinding<Model: AnyObject, Value: ControlValueConvertible>: ControlBinding {
    private let model: Model
    private let keyPath: ReferenceWritableKeyPath<Model, Value>

    init(model: Model, keyPath: ReferenceWritableKeyPath<Model, Value>) {
        self.model = model
        self.keyPath = keyPath
    }

    func read() -> ControlValue {
        model[keyPath: keyPath].controlValue
    }

    func write(_ value: ControlValue) {
        guard let newValue = Value(controlValue: value) else { return }
        model[keyPath: keyPath] = newValue
    }
}

/// Binds a choice control to a `String`-backed enum property of the model.
@MainActor
final class ChoiceBinding<Model: AnyObject, Value: RawRepresentable>: ControlBinding
where Value.RawValue == String {
    private let model: Model
    private let keyPath: ReferenceWritableKeyPath<Model, Value>

    init(model: Model, keyPath: ReferenceWritableKeyPath<Model, Value>) {
        self.model = model
        self.keyPath = keyPath
    }

    func read() -> ControlValue {
        .string(model[keyPath: keyPath].rawValue)
    }

    func write(_ value: ControlValue) {
        guard case .string(let rawValue) = value, let newValue = Value(rawValue: rawValue) else { return }
        model[keyPath: keyPath] = newValue
    }
}

/// Binds the clock control to `SaveStateClock.overrideDate`.
@MainActor
final class ClockBinding: ControlBinding {
    func read() -> ControlValue {
        SaveStateClock.overrideDate.map(ControlValue.date) ?? .null
    }

    func write(_ value: ControlValue) {
        switch value {
        case .date(let date):
            SaveStateClock.overrideDate = date
        case .null:
            SaveStateClock.overrideDate = nil
        default:
            break
        }
    }
}
