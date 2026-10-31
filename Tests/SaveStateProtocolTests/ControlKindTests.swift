import Foundation
import SaveStateProtocol
import Testing

/// A kind and the sample values it accepts. Every other sample must be refused.
struct KindAcceptance: Sendable, CustomTestStringConvertible {
    let kind: ControlKind
    let accepted: [ControlValue]

    var testDescription: String { "\(kind)" }
}

@Suite("ControlKind")
struct ControlKindTests {
    private static let date = Date(timeIntervalSince1970: 1_800_000_000)
    private static let samples: [ControlValue] = [
        .null, .bool(true), .string("a"), .int(1), .double(1.5), .date(date)
    ]

    @Test(arguments: [
        KindAcceptance(kind: .toggle, accepted: [.bool(true)]),
        KindAcceptance(kind: .triState, accepted: [.null, .bool(true)]),
        KindAcceptance(kind: .choice(options: ["a"]), accepted: [.string("a")]),
        KindAcceptance(kind: .text, accepted: [.string("a")]),
        KindAcceptance(kind: .integer, accepted: [.int(1)]),
        KindAcceptance(kind: .decimal, accepted: [.int(1), .double(1.5)]),
        KindAcceptance(kind: .date, accepted: [.null, .date(date)]),
        KindAcceptance(kind: .clock, accepted: [.null, .date(date)])
    ])
    func eachKindAcceptsOnlyItsOwnValues(_ acceptance: KindAcceptance) {
        for sample in Self.samples {
            let isAccepted = acceptance.kind.normalize(sample) != nil
            #expect(isAccepted == acceptance.accepted.contains(sample), "\(sample)")
        }
    }

    @Test func aChoiceWithNoOptionsAcceptsNothing() {
        #expect(ControlKind.choice(options: []).normalize(.string("")) == nil)
    }

    @Test func choiceOptionsMatchCaseSensitively() {
        #expect(ControlKind.choice(options: ["staging"]).normalize(.string("Staging")) == nil)
    }

    @Test(arguments: [ControlKind.date, .clock])
    func dateKindsRefuseNonFiniteDates(_ kind: ControlKind) {
        #expect(kind.normalize(.date(Date(timeIntervalSince1970: .infinity))) == nil)
        #expect(kind.normalize(.date(Date(timeIntervalSince1970: -.infinity))) == nil)
        #expect(kind.normalize(.date(Date(timeIntervalSince1970: .nan))) == nil)
    }

    /// JSON has no era, so a date before year 1 would come back as a different
    /// date, and the formatter overflows on very distant years.
    @Test(arguments: [ControlKind.date, .clock], [-62_200_000_000.0, -1e12, 1e15])
    func dateKindsRefuseDatesThatJSONWouldChange(_ kind: ControlKind, seconds: TimeInterval) {
        #expect(kind.normalize(.date(Date(timeIntervalSince1970: seconds))) == nil)
    }

    @Test(arguments: [ControlKind.date, .clock], [Date.distantPast, Date.distantFuture])
    func dateKindsAcceptTheDistantDates(_ kind: ControlKind, date: Date) {
        #expect(kind.normalize(.date(date)) == .date(date))
    }

    @Test func decimalsConvertTheLargestWholeNumbers() {
        #expect(ControlKind.decimal.normalize(.int(.max)) == .double(Double(Int.max)))
    }

    @Test func decimalsRefuseNegativeInfinity() {
        #expect(ControlKind.decimal.normalize(.double(-.infinity)) == nil)
    }

    // MARK: - Coding

    @Test(arguments: [
        (ControlKind.toggle, "toggle"),
        (.triState, "triState"),
        (.text, "text"),
        (.integer, "integer"),
        (.decimal, "decimal"),
        (.date, "date"),
        (.clock, "clock")
    ])
    func kindsEncodeTheirStableTypeName(_ kind: ControlKind, name: String) throws {
        let text = try json(kind)

        #expect(text == #"{"type":"\#(name)"}"#)
    }

    @Test(arguments: [
        #"{"type":"choice"}"#,
        #"{"type":"choice","options":"a"}"#,
        #"{"type":"choice","options":[1]}"#,
        #"{"type":"slider"}"#,
        #"{"options":["a"]}"#,
        "[]"
    ])
    func malformedKindsFailToDecode(_ text: String) {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(ControlKind.self, from: Data(text.utf8))
        }
    }

    @Test func choiceOptionsKeepTheirOrder() throws {
        let kind = ControlKind.choice(options: ["z", "a", "m"])

        let decoded = try roundTrip(kind)

        #expect(decoded == kind)
    }

    @Test func choicesWithDifferentOptionOrdersAreDifferentKinds() {
        #expect(ControlKind.choice(options: ["a", "b"]) != .choice(options: ["b", "a"]))
    }
}
