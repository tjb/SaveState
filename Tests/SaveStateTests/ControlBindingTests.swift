import Foundation
import Testing
@testable import SaveState

@Suite("ControlValueConvertible")
struct ControlValueConvertibleTests {
    private static let date = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func boolConvertsOnlyFromBool() {
        #expect(Bool(controlValue: .bool(true)) == true)
        #expect(Bool(controlValue: .int(1)) == nil)
    }

    @Test func stringConvertsOnlyFromString() {
        #expect(String(controlValue: .string("a")) == "a")
        #expect(String(controlValue: .int(1)) == nil)
    }

    @Test func intConvertsOnlyFromInt() {
        #expect(Int(controlValue: .int(1)) == 1)
        #expect(Int(controlValue: .double(1)) == nil)
    }

    @Test func doubleConvertsFromDoubleAndInt() {
        #expect(Double(controlValue: .double(1.5)) == 1.5)
        #expect(Double(controlValue: .int(2)) == 2)
        #expect(Double(controlValue: .string("2")) == nil)
    }

    @Test func dateConvertsOnlyFromDate() {
        #expect(Date(controlValue: .date(Self.date)) == Self.date)
        #expect(Date(controlValue: .null) == nil)
    }

    @Test func eachTypeProducesItsOwnCase() {
        #expect(true.controlValue == .bool(true))
        #expect("a".controlValue == .string("a"))
        #expect(1.controlValue == .int(1))
        #expect(1.5.controlValue == .double(1.5))
        #expect(Self.date.controlValue == .date(Self.date))
    }

    @Test func nilProducesNull() {
        #expect(Bool?.none.controlValue == .null)
    }

    @Test func someProducesTheWrappedValue() {
        #expect(Bool?.some(false).controlValue == .bool(false))
    }

    @Test func optionalConvertsNullToNil() throws {
        let converted = try #require(Bool?(controlValue: .null))

        #expect(converted == nil)
    }

    @Test func optionalConvertsTheWrappedType() throws {
        let converted = try #require(Bool?(controlValue: .bool(true)))

        #expect(converted == true)
    }

    @Test func optionalRefusesAnotherType() {
        #expect(Bool?(controlValue: .int(1)) == nil)
    }
}

@Suite("Bindings")
@MainActor
struct BindingTests {
    @Test func keyPathBindingReadsTheModel() {
        let model = DebugModel()
        model.greeting = "Hi"
        let binding = KeyPathBinding(model: model, keyPath: \DebugModel.greeting)

        #expect(binding.read() == .string("Hi"))
    }

    @Test func keyPathBindingWritesTheModel() {
        let model = DebugModel()
        let binding = KeyPathBinding(model: model, keyPath: \DebugModel.greeting)

        binding.write(.string("Hi"))

        #expect(model.greeting == "Hi")
    }

    @Test func keyPathBindingIgnoresAValueOfTheWrongType() {
        let model = DebugModel()
        let binding = KeyPathBinding(model: model, keyPath: \DebugModel.greeting)

        binding.write(.int(1))

        #expect(model.greeting == "Hello")
    }

    @Test func optionalBindingClearsOnNull() {
        let model = DebugModel()
        model.premiumOverride = true
        let binding = KeyPathBinding(model: model, keyPath: \DebugModel.premiumOverride)

        binding.write(.null)

        #expect(model.premiumOverride == nil)
    }

    @Test func optionalBindingKeepsItsValueOnTheWrongType() {
        let model = DebugModel()
        model.premiumOverride = true
        let binding = KeyPathBinding(model: model, keyPath: \DebugModel.premiumOverride)

        binding.write(.string("no"))

        #expect(model.premiumOverride == true)
    }

    @Test func choiceBindingReadsTheRawValue() {
        let binding = ChoiceBinding(model: DebugModel(), keyPath: \DebugModel.environment)

        #expect(binding.read() == .string("production"))
    }

    @Test func choiceBindingWritesAKnownCase() {
        let model = DebugModel()
        let binding = ChoiceBinding(model: model, keyPath: \DebugModel.environment)

        binding.write(.string("staging"))

        #expect(model.environment == .staging)
    }

    @Test(arguments: [ControlValue.string("qa"), .string("Staging"), .int(0), .null])
    func choiceBindingIgnoresAnythingElse(_ value: ControlValue) {
        let model = DebugModel()
        let binding = ChoiceBinding(model: model, keyPath: \DebugModel.environment)

        binding.write(value)

        #expect(model.environment == .production)
    }
}
