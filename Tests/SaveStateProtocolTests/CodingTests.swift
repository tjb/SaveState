import Foundation
import SaveStateProtocol
import Testing

private let sampleValues: [ControlValue] = [
    .null,
    .bool(true),
    .string("staging"),
    .int(42),
    .double(0.5),
    .date(Date(timeIntervalSince1970: 1_800_000_000.25)),
]

private let sampleKinds: [ControlKind] = [
    .toggle,
    .triState,
    .choice(options: ["staging", "production"]),
    .text,
    .integer,
    .decimal,
    .date,
    .clock,
]

private func json(_ value: some Encodable) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    return String(decoding: try encoder.encode(value), as: UTF8.self)
}

private func roundTrip<Value: Codable>(_ value: Value) throws -> Value {
    try JSONDecoder().decode(Value.self, from: JSONEncoder().encode(value))
}

@Suite("Coding")
struct CodingTests {
    @Test(arguments: sampleValues)
    func valuesRoundTrip(_ value: ControlValue) throws {
        let decoded = try roundTrip(value)
        #expect(decoded == value)
    }

    @Test func valuesEncodeAsTypeAndValue() throws {
        let null = try json(ControlValue.null)
        let bool = try json(ControlValue.bool(true))
        let int = try json(ControlValue.int(42))
        let date = try json(ControlValue.date(Date(timeIntervalSince1970: 1_800_000_000.25)))

        #expect(null == #"{"type":"null"}"#)
        #expect(bool == #"{"type":"bool","value":true}"#)
        #expect(int == #"{"type":"int","value":42}"#)
        #expect(date == #"{"type":"date","value":"2027-01-15T08:00:00.250Z"}"#)
    }

    @Test func datesKeepMillisecondsAndEncodeInUTC() throws {
        let beforeEpoch = try json(ControlValue.date(Date(timeIntervalSince1970: -0.5)))
        let subMillisecond = try json(ControlValue.date(Date(timeIntervalSince1970: 1_800_000_000.2346)))

        #expect(beforeEpoch == #"{"type":"date","value":"1969-12-31T23:59:59.500Z"}"#)
        #expect(subMillisecond == #"{"type":"date","value":"2027-01-15T08:00:00.235Z"}"#)
    }

    @Test func datesCompareAtMillisecondPrecision() throws {
        let date = Date(timeIntervalSince1970: 1_800_000_000.2346)

        #expect(ControlValue.date(date) == .date(Date(timeIntervalSince1970: 1_800_000_000.235)))
        #expect(ControlValue.date(date) != .date(Date(timeIntervalSince1970: 1_800_000_000.236)))
        #expect(Set([ControlValue.date(date), .date(Date(timeIntervalSince1970: 1_800_000_000.2349))]).count == 1)
        let decoded = try roundTrip(ControlValue.date(date))
        #expect(decoded == .date(date))
    }

    @Test func datesDecodeWithoutFractionalSeconds() throws {
        let data = Data(#"{"type":"date","value":"2027-01-15T08:00:00Z"}"#.utf8)

        let value = try JSONDecoder().decode(ControlValue.self, from: data)

        #expect(value == .date(Date(timeIntervalSince1970: 1_800_000_000)))
    }

    @Test func malformedValuesFailToDecode() {
        let badDate = Data(#"{"type":"date","value":"yesterday"}"#.utf8)
        let unknownType = Data(#"{"type":"color","value":"red"}"#.utf8)
        let mismatchedValue = Data(#"{"type":"int","value":"three"}"#.utf8)

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(ControlValue.self, from: badDate)
        }
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(ControlValue.self, from: unknownType)
        }
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(ControlValue.self, from: mismatchedValue)
        }
    }

    @Test(arguments: sampleKinds)
    func kindsRoundTrip(_ kind: ControlKind) throws {
        let decoded = try roundTrip(kind)
        #expect(decoded == kind)
    }

    @Test func kindsEncodeAsTypeAndOptions() throws {
        let toggle = try json(ControlKind.toggle)
        let choice = try json(ControlKind.choice(options: ["staging", "production"]))

        #expect(toggle == #"{"type":"toggle"}"#)
        #expect(choice == #"{"options":["staging","production"],"type":"choice"}"#)
    }

    @Test func descriptionsRoundTrip() throws {
        let description = RegistryDescription(
            controls: [
                ControlDescription(
                    key: "premium",
                    label: "Premium",
                    section: "Purchases",
                    kind: .triState,
                    value: .null,
                    realValue: .bool(true),
                    effectiveValue: .bool(true),
                    defaultValue: .null,
                    requiresRelaunch: false,
                    nextLaunchValue: nil
                ),
                ControlDescription(
                    key: "env",
                    label: "Environment",
                    section: nil,
                    kind: .choice(options: ["staging", "production"]),
                    value: .string("production"),
                    realValue: nil,
                    effectiveValue: .string("production"),
                    defaultValue: .string("production"),
                    requiresRelaunch: true,
                    nextLaunchValue: .string("staging")
                ),
            ],
            actions: [
                ActionDescription(key: "erase", label: "Erase", section: nil, isDestructive: true),
            ],
            scenarios: [
                ScenarioDescription(
                    key: "expired-trial",
                    label: "Expired trial",
                    section: "Purchases",
                    summary: "The trial ended, so the paywall shows."
                ),
                ScenarioDescription(key: "fresh-install", label: "Fresh install", section: nil, summary: nil),
            ]
        )

        let decoded = try roundTrip(description)
        #expect(decoded == description)
    }
}

@Suite("Normalize")
struct NormalizeTests {
    @Test func acceptsMatchingValues() {
        let date = Date(timeIntervalSince1970: 0)

        #expect(ControlKind.toggle.normalize(.bool(true)) == .bool(true))
        #expect(ControlKind.triState.normalize(.bool(false)) == .bool(false))
        #expect(ControlKind.triState.normalize(.null) == .null)
        #expect(ControlKind.choice(options: ["a", "b"]).normalize(.string("b")) == .string("b"))
        #expect(ControlKind.text.normalize(.string("")) == .string(""))
        #expect(ControlKind.integer.normalize(.int(-3)) == .int(-3))
        #expect(ControlKind.decimal.normalize(.double(1.5)) == .double(1.5))
        #expect(ControlKind.date.normalize(.date(date)) == .date(date))
        #expect(ControlKind.date.normalize(.null) == .null)
        #expect(ControlKind.clock.normalize(.date(date)) == .date(date))
        #expect(ControlKind.clock.normalize(.null) == .null)
    }

    @Test func convertsWholeNumbersForDecimals() {
        #expect(ControlKind.decimal.normalize(.int(2)) == .double(2))
    }

    @Test func rejectsMismatchedValues() {
        #expect(ControlKind.toggle.normalize(.null) == nil)
        #expect(ControlKind.toggle.normalize(.int(1)) == nil)
        #expect(ControlKind.choice(options: ["a", "b"]).normalize(.string("c")) == nil)
        #expect(ControlKind.text.normalize(.null) == nil)
        #expect(ControlKind.integer.normalize(.double(1)) == nil)
        #expect(ControlKind.decimal.normalize(.string("1")) == nil)
        #expect(ControlKind.decimal.normalize(.double(.nan)) == nil)
        #expect(ControlKind.decimal.normalize(.double(.infinity)) == nil)
        #expect(ControlKind.date.normalize(.string("2027-01-15")) == nil)
        #expect(ControlKind.clock.normalize(.string("2027-01-15")) == nil)
    }
}
