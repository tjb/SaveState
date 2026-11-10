import Foundation
import SaveStateProtocol
import Testing

private let noon = Date(timeIntervalSince1970: 1_800_000_000)
private let noonText = "2027-01-15T08:00:00Z"

/// A condition, a probe's value, and whether the value meets it, or `nil` when
/// the condition can't apply.
private struct Case: CustomTestStringConvertible, Sendable {
    let condition: ProbeCondition
    let value: ControlValue
    let expected: Bool?

    var testDescription: String { "\(condition) on \(value)" }
}

private func cases(
    _ value: ControlValue,
    _ target: ControlValue,
    equals: Bool?,
    atLeast: Bool?,
    atMost: Bool?
) -> [Case] {
    [
        Case(condition: .equals(value: target), value: value, expected: equals),
        Case(condition: .notEquals(value: target), value: value, expected: equals.map { !$0 }),
        Case(condition: .atLeast(value: target), value: value, expected: atLeast),
        Case(condition: .atMost(value: target), value: value, expected: atMost)
    ]
}

private let numberCases: [Case] =
    cases(.int(5), .int(5), equals: true, atLeast: true, atMost: true)
    + cases(.int(4), .int(5), equals: false, atLeast: false, atMost: true)
    + cases(.int(6), .int(5), equals: false, atLeast: true, atMost: false)
    + cases(.int(5), .double(5), equals: true, atLeast: true, atMost: true)
    + cases(.int(5), .double(5.5), equals: false, atLeast: false, atMost: true)
    + cases(.int(5), .double(4.5), equals: false, atLeast: true, atMost: false)
    + cases(.double(5), .int(5), equals: true, atLeast: true, atMost: true)
    + cases(.double(5.5), .int(5), equals: false, atLeast: true, atMost: false)
    + cases(.double(4.5), .int(5), equals: false, atLeast: false, atMost: true)
    + cases(.double(0.5), .double(0.5), equals: true, atLeast: true, atMost: true)
    + cases(.double(0.25), .double(0.5), equals: false, atLeast: false, atMost: true)
    + cases(.double(0.75), .double(0.5), equals: false, atLeast: true, atMost: false)
    // NaN is neither less, equal, nor greater than anything.
    + cases(.double(.nan), .double(0.5), equals: false, atLeast: false, atMost: false)
    + cases(.double(.nan), .int(1), equals: false, atLeast: false, atMost: false)

private let dateCases: [Case] =
    cases(.date(noon), .date(noon), equals: true, atLeast: true, atMost: true)
    + cases(.date(noon), .date(noon.addingTimeInterval(1)), equals: false, atLeast: false, atMost: true)
    + cases(.date(noon), .date(noon.addingTimeInterval(-1)), equals: false, atLeast: true, atMost: false)
    // Dates compare at millisecond precision, as `ControlValue` does.
    + cases(.date(noon), .date(noon.addingTimeInterval(0.0001)), equals: true, atLeast: true, atMost: true)
    + cases(.date(noon), .string(noonText), equals: true, atLeast: true, atMost: true)
    + cases(.date(noon), .string("2027-01-15T08:00:00.500Z"), equals: false, atLeast: false, atMost: true)
    + cases(.date(noon), .string("2027-01-15T07:59:59.500Z"), equals: false, atLeast: true, atMost: false)
    // The same instant written in another time zone.
    + cases(.date(noon), .string("2027-01-15T10:00:00+02:00"), equals: true, atLeast: true, atMost: true)

private let unorderedCases: [Case] =
    cases(.bool(true), .bool(true), equals: true, atLeast: nil, atMost: nil)
    + cases(.bool(true), .bool(false), equals: false, atLeast: nil, atMost: nil)
    + cases(.string("ready"), .string("ready"), equals: true, atLeast: nil, atMost: nil)
    + cases(.string("ready"), .string("busy"), equals: false, atLeast: nil, atMost: nil)

private let mismatchedCases: [Case] =
    cases(.bool(true), .int(1), equals: nil, atLeast: nil, atMost: nil)
    + cases(.int(1), .bool(true), equals: nil, atLeast: nil, atMost: nil)
    + cases(.int(1), .string("1"), equals: nil, atLeast: nil, atMost: nil)
    + cases(.string("1"), .int(1), equals: nil, atLeast: nil, atMost: nil)
    + cases(.string(noonText), .date(noon), equals: nil, atLeast: nil, atMost: nil)
    + cases(.date(noon), .int(1_800_000_000), equals: nil, atLeast: nil, atMost: nil)
    + cases(.int(1), .date(noon), equals: nil, atLeast: nil, atMost: nil)
    + cases(.date(noon), .string("tomorrow"), equals: nil, atLeast: nil, atMost: nil)
    // ISO 8601 here needs a time zone, so a local time is ambiguous.
    + cases(.date(noon), .string("2027-01-15T08:00:00"), equals: nil, atLeast: nil, atMost: nil)
    + cases(.date(noon), .null, equals: nil, atLeast: nil, atMost: nil)
    + cases(.null, .null, equals: nil, atLeast: nil, atMost: nil)
    + cases(.bool(true), .double(1), equals: nil, atLeast: nil, atMost: nil)

@Suite("Probe conditions")
struct ProbeConditionTests {
    @Test(arguments: numberCases)
    private func numbersCompareByValue(_ testCase: Case) {
        #expect(testCase.condition.isMet(by: testCase.value) == testCase.expected)
    }

    @Test(arguments: dateCases)
    private func datesCompareByInstant(_ testCase: Case) {
        #expect(testCase.condition.isMet(by: testCase.value) == testCase.expected)
    }

    @Test(arguments: unorderedCases)
    private func boolsAndStringsOnlyCompareForEquality(_ testCase: Case) {
        #expect(testCase.condition.isMet(by: testCase.value) == testCase.expected)
    }

    @Test(arguments: mismatchedCases)
    private func mismatchedTypesCantApply(_ testCase: Case) {
        #expect(testCase.condition.isMet(by: testCase.value) == nil)
    }

    @Test(arguments: [
        ProbeCondition.equals(value: .int(1)),
        .notEquals(value: .int(1)),
        .atLeast(value: .int(1)),
        .atMost(value: .int(1))
    ])
    func everyConditionExposesItsValue(_ condition: ProbeCondition) {
        #expect(condition.value == .int(1))
    }

    @Test(arguments: [
        (ProbeCondition.equals(value: .int(5)), #"{"equals":{"value":{"type":"int","value":5}}}"#),
        (.notEquals(value: .bool(true)), #"{"notEquals":{"value":{"type":"bool","value":true}}}"#),
        (.atLeast(value: .double(0.5)), #"{"atLeast":{"value":{"type":"double","value":0.5}}}"#),
        (.atMost(value: .string(noonText)), #"{"atMost":{"value":{"type":"string","value":"2027-01-15T08:00:00Z"}}}"#)
    ])
    func conditionsEncodeStably(_ condition: ProbeCondition, expected: String) throws {
        #expect(try json(condition) == expected)
    }

    /// Decodes literal JSON, because a round trip would use one set of keys on
    /// both sides and pass under any rename.
    @Test(arguments: [
        (#"{"equals":{"value":{"type":"int","value":5}}}"#, ProbeCondition.equals(value: .int(5))),
        (#"{"notEquals":{"value":{"type":"bool","value":true}}}"#, .notEquals(value: .bool(true))),
        (#"{"atLeast":{"value":{"type":"double","value":0.5}}}"#, .atLeast(value: .double(0.5))),
        (#"{"atMost":{"value":{"type":"date","value":"2027-01-15T08:00:00.000Z"}}}"#, .atMost(value: .date(noon)))
    ])
    func conditionsDecodeFromTheirPinnedJSON(_ text: String, expected: ProbeCondition) throws {
        #expect(try JSONDecoder().decode(ProbeCondition.self, from: Data(text.utf8)) == expected)
    }

    @Test(arguments: [
        "{}",
        #"{"between":{"value":{"type":"int","value":5}}}"#,
        #"{"equals":{}}"#,
        #"{"equals":{"value":5}}"#
    ])
    func badConditionsFailToDecode(_ text: String) {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(ProbeCondition.self, from: Data(text.utf8))
        }
    }
}
