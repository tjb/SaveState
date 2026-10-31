import Foundation
import SaveStateProtocol
import Testing

/// A date and the exact text it must encode as.
struct DateCase: Sendable, CustomTestStringConvertible {
    let seconds: TimeInterval
    let text: String

    var testDescription: String { text }
}

@Suite("ControlValue decoding")
struct ControlValueDecodingTests {
    @Test(arguments: [
        #"{"value":true}"#,
        #"{"type":"bool"}"#,
        #"{"type":"string"}"#,
        #"{"type":"int"}"#,
        #"{"type":"double"}"#,
        #"{"type":"date"}"#,
        #"{"type":"bool","value":null}"#,
        #"{"type":"bool","value":1}"#,
        #"{"type":"string","value":1}"#,
        #"{"type":"int","value":2.5}"#,
        #"{"type":"int","value":1e30}"#,
        #"{"type":"double","value":"1"}"#,
        #"{"type":"date","value":1800000000}"#,
        #"{"type":"date","value":""}"#,
        #"{"type":"Bool","value":true}"#,
        #"{"type":1}"#,
        "[]",
        "true"
    ])
    func malformedJSONFailsToDecode(_ text: String) {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(ControlValue.self, from: Data(text.utf8))
        }
    }

    @Test func aBadDateReportsTheValueKeyAndTheText() throws {
        let data = Data(#"{"type":"date","value":"yesterday"}"#.utf8)

        let error = try #require(throws: DecodingError.self) {
            try JSONDecoder().decode(ControlValue.self, from: data)
        }

        guard case .dataCorrupted(let context) = error else {
            Issue.record("Expected dataCorrupted but got \(error)")
            return
        }
        #expect(context.codingPath.map(\.stringValue) == ["value"])
        #expect(context.debugDescription.contains("yesterday"))
    }

    @Test func nullIgnoresAnyValue() throws {
        let data = Data(#"{"type":"null","value":"ignored"}"#.utf8)

        let value = try JSONDecoder().decode(ControlValue.self, from: data)

        #expect(value == .null)
    }

    @Test func aDoubleAcceptsAWholeJSONNumber() throws {
        let data = Data(#"{"type":"double","value":3}"#.utf8)

        let value = try JSONDecoder().decode(ControlValue.self, from: data)

        #expect(value == .double(3))
    }
}

@Suite("ControlValue encoding")
struct ControlValueEncodingTests {
    @Test func stringsEncodeAsTypeAndValue() throws {
        let text = try json(ControlValue.string("staging"))

        #expect(text == #"{"type":"string","value":"staging"}"#)
    }

    @Test func doublesEncodeAsTypeAndValue() throws {
        let text = try json(ControlValue.double(0.5))

        #expect(text == #"{"type":"double","value":0.5}"#)
    }

    @Test(arguments: [
        ControlValue.int(.max),
        .int(.min),
        .double(0.1),
        .double(-1e300),
        .double(.leastNonzeroMagnitude),
        .string(""),
        .string("\"quoted\" \n 日本語 🎮"),
        .bool(false)
    ])
    func extremeValuesRoundTripExactly(_ value: ControlValue) throws {
        let decoded = try roundTrip(value)

        #expect(decoded == value)
    }

    @Test func aNonFiniteDoubleCannotBeEncoded() {
        #expect(throws: EncodingError.self) {
            try JSONEncoder().encode(ControlValue.double(.nan))
        }
    }
}

@Suite("ControlValue dates")
struct ControlValueDateTests {
    @Test(arguments: [
        DateCase(seconds: 0, text: "1970-01-01T00:00:00.000Z"),
        DateCase(seconds: 0.005, text: "1970-01-01T00:00:00.005Z"),
        DateCase(seconds: 0.05, text: "1970-01-01T00:00:00.050Z"),
        DateCase(seconds: 0.9996, text: "1970-01-01T00:00:01.000Z"),
        DateCase(seconds: 59.9996, text: "1970-01-01T00:01:00.000Z"),
        DateCase(seconds: -1, text: "1969-12-31T23:59:59.000Z"),
        DateCase(seconds: -1.5, text: "1969-12-31T23:59:58.500Z"),
        DateCase(seconds: -0.001, text: "1969-12-31T23:59:59.999Z"),
        DateCase(seconds: 1_835_395_200, text: "2028-02-29T00:00:00.000Z"),
        DateCase(seconds: Date.distantPast.timeIntervalSince1970, text: "0001-01-01T00:00:00.000Z"),
        DateCase(seconds: Date.distantFuture.timeIntervalSince1970, text: "4001-01-01T00:00:00.000Z"),
        DateCase(seconds: 253_402_300_800, text: "10000-01-01T00:00:00.000Z")
    ])
    func datesEncodeExactlyAndRoundTrip(_ dateCase: DateCase) throws {
        let value = ControlValue.date(Date(timeIntervalSince1970: dateCase.seconds))

        let text = try json(value)
        let decoded = try roundTrip(value)

        #expect(text == #"{"type":"date","value":"\#(dateCase.text)"}"#)
        #expect(decoded == value)
    }

    @Test func everyMillisecondOfASecondRoundTrips() throws {
        for millisecond in 0..<1000 {
            let seconds = 1_800_000_000 + Double(millisecond) / 1000
            let value = ControlValue.date(Date(timeIntervalSince1970: seconds))

            let decoded = try roundTrip(value)

            #expect(decoded == value, "Millisecond \(millisecond)")
        }
    }

    @Test(arguments: [
        "2027-01-15T08:00:00Z",
        "2027-01-15T08:00:00.000Z",
        "2027-01-15T09:00:00+01:00",
        "2027-01-15T03:30:00-04:30"
    ])
    func iso8601TextParsesToTheSameInstant(_ text: String) {
        #expect(ControlValue(iso8601Date: text) == .date(Date(timeIntervalSince1970: 1_800_000_000)))
    }

    @Test func iso8601TextKeepsFractionalSeconds() {
        let value = ControlValue(iso8601Date: "2027-01-15T08:00:00.250Z")

        #expect(value == .date(Date(timeIntervalSince1970: 1_800_000_000.25)))
    }

    @Test(arguments: ["", "yesterday", "2027-01-15", "2027-01-15T08:00:00", "2027-13-15T08:00:00Z", "1800000000"])
    func nonISO8601TextParsesToNothing(_ text: String) {
        #expect(ControlValue(iso8601Date: text) == nil)
    }
}

@Suite("ControlValue equality and hashing")
struct ControlValueHashingTests {
    /// Pairs that must compare equal, and so must hash equal.
    static let equalPairs: [[ControlValue]] = [
        [.null, .null],
        [.bool(true), .bool(true)],
        [.string("a"), .string("a")],
        [.int(1), .int(1)],
        [.double(1.5), .double(1.5)],
        [.double(0.0), .double(-0.0)],
        [
            .date(Date(timeIntervalSince1970: 1_800_000_000.2346)),
            .date(Date(timeIntervalSince1970: 1_800_000_000.2349))
        ],
        [
            .date(Date(timeIntervalSince1970: 1_800_000_000.9996)),
            .date(Date(timeIntervalSince1970: 1_800_000_001.0004))
        ]
    ]

    @Test(arguments: equalPairs)
    func equalValuesHashEqually(_ pair: [ControlValue]) {
        #expect(pair[0] == pair[1])
        #expect(pair[0].hashValue == pair[1].hashValue)
    }

    @Test func equalValuesCollapseInASet() {
        #expect(Set(Self.equalPairs.flatMap { $0 }).count == Self.equalPairs.count)
    }

    @Test(arguments: [
        [ControlValue.int(1), .double(1)],
        [.string("true"), .bool(true)],
        [.string("1"), .int(1)],
        [.null, .bool(false)],
        [.null, .string("")],
        [.bool(true), .bool(false)],
        [.int(1), .int(2)],
        [.double(1), .double(2)],
        [.string("a"), .string("A")],
        [.date(Date(timeIntervalSince1970: 0.0004)), .date(Date(timeIntervalSince1970: 0.0006))]
    ])
    func differentValuesAreUnequal(_ pair: [ControlValue]) {
        #expect(pair[0] != pair[1])
    }

    // Whole milliseconds beyond Int64 would trap on conversion without the
    // clamp, and a NaN date would trap without the finiteness guard. A trap
    // ends the test run, so it can't pass silently.

    @Test(arguments: [1e17, -1e17])
    func aDateBeyondTheMillisecondRangeComparesAndHashesWithoutTrapping(_ seconds: TimeInterval) {
        let value = ControlValue.date(Date(timeIntervalSince1970: seconds))

        #expect(value == value)
        #expect(Set([value, value]).count == 1)
    }

    @Test func datesBeyondTheRangeOnOppositeSidesAreUnequal() {
        let future = ControlValue.date(Date(timeIntervalSince1970: 1e17))
        let past = ControlValue.date(Date(timeIntervalSince1970: -1e17))

        #expect(future != past)
    }

    @Test func aNaNDateComparesAndHashesWithoutTrapping() {
        let value = ControlValue.date(Date(timeIntervalSince1970: .nan))

        #expect(value == value)
        #expect(Set([value, value]).count == 1)
    }

    /// Without the finiteness guard, an infinite date would clamp onto the same
    /// instant as the farthest finite date.
    @Test(arguments: [(TimeInterval.infinity, 1e17), (-TimeInterval.infinity, -1e17)])
    func anInfiniteDateIsUnequalToTheFarthestFiniteDate(infinite: TimeInterval, finite: TimeInterval) {
        let infiniteDate = ControlValue.date(Date(timeIntervalSince1970: infinite))
        let finiteDate = ControlValue.date(Date(timeIntervalSince1970: finite))

        #expect(infiniteDate != finiteDate)
    }

    @Test func oppositeInfiniteDatesAreUnequal() {
        let future = ControlValue.date(Date(timeIntervalSince1970: .infinity))
        let past = ControlValue.date(Date(timeIntervalSince1970: -.infinity))

        #expect(future != past)
    }

    @Test func nanIsNotEqualToItself() {
        #expect(ControlValue.double(.nan) != .double(.nan))
    }

    @Test func everySampleValueIsDistinct() {
        #expect(Set(sampleValues).count == sampleValues.count)
    }
}
