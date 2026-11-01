import Foundation
import MCP
import SaveStateProtocol
import Testing
@testable import SaveStateBridgeKit

@Suite("Control value conversion")
struct ControlValueConversionTests {
    private static let flavors = ControlKind.choice(options: ["sweet", "sour"])

    private func message(_ json: Value, _ kind: ControlKind) -> String? {
        do {
            _ = try ControlValueConversion.value(from: json, kind: kind)
            return nil
        } catch {
            return (error as? BridgeError)?.message
        }
    }

    // MARK: - Accepted

    @Test func aWholeNumberBecomesADecimal() throws {
        #expect(try ControlValueConversion.value(from: .int(2), kind: .decimal) == .double(2))
    }

    @Test func aWholeDoubleBecomesAnInteger() throws {
        #expect(try ControlValueConversion.value(from: .double(3), kind: .integer) == .int(3))
    }

    @Test func nullClearsATriState() throws {
        #expect(try ControlValueConversion.value(from: .null, kind: .triState) == .null)
    }

    @Test func aDateStringKeepsItsFractionalSeconds() throws {
        let value = try ControlValueConversion.value(from: .string("2027-01-15T08:00:00.250Z"), kind: .clock)

        #expect(value == .date(Date(timeIntervalSince1970: 1_800_000_000.25)))
    }

    @Test func aChoiceTakesAListedOption() throws {
        #expect(try ControlValueConversion.value(from: .string("sour"), kind: Self.flavors) == .string("sour"))
    }

    @Test func aChoiceOptionShapedLikeADataURLIsRestoredToText() throws {
        let url = "data:text/plain;base64,aGk="
        let kind = ControlKind.choice(options: [url])
        let decoded = try JSONDecoder().decode(Value.self, from: JSONEncoder().encode(url))

        #expect(try ControlValueConversion.value(from: decoded, kind: kind) == .string(url))
    }

    // MARK: - Rejected, with what the agent reads

    @Test func aRejectedToggleNamesTheKindTheValueAndWhatItTakes() {
        #expect(message(.int(1), .toggle) == "A toggle control can't take 1. It takes true or false.")
    }

    @Test func aRejectedTriStateMentionsNull() {
        #expect(message(.string("maybe"), .triState) == "A tri-state control can't take \"maybe\". It takes true, false, or null for the real value.")
    }

    @Test func aRejectedChoiceListsItsOptions() {
        #expect(message(.string("bitter"), Self.flavors) == "A choice control can't take \"bitter\". It takes one of: sweet, sour.")
    }

    @Test func aRejectedTextDescribesNull() {
        #expect(message(.null, .text) == "A text control can't take null. It takes a string.")
    }

    @Test func aFractionIsRejectedByAnInteger() {
        #expect(message(.double(1.5), .integer)?.contains("integer control can't take 1.5. It takes a whole number.") == true)
    }

    @Test func aBoolIsRejectedByADecimal() {
        #expect(message(.bool(true), .decimal) == "A decimal control can't take true. It takes a number.")
    }

    @Test func aDoubleTooLargeForAnIntIsRejected() {
        #expect(message(.double(1e300), .integer) != nil)
    }

    @Test func infinityIsRejectedByADecimal() {
        #expect(message(.double(.infinity), .decimal) != nil)
    }

    @Test func aRejectedDateShowsTheFormat() {
        #expect(message(.string("tomorrow"), .date)?.contains("2027-01-15T08:00:00Z, or null for the real value") == true)
    }

    @Test func aRejectedClockShowsTheFormat() {
        #expect(message(.int(5), .clock)?.contains("A clock control") == true)
        #expect(message(.int(5), .clock)?.contains("or null for real time") == true)
    }

    @Test func anArrayIsDescribedInTheRejection() {
        #expect(message(.array([.int(1)]), .text) == "A text control can't take an array. It takes a string.")
    }

    @Test func anObjectIsDescribedInTheRejection() {
        #expect(message(.object(["a": .int(1)]), .text) == "A text control can't take an object. It takes a string.")
    }

    @Test func binaryDataIsRejectedOutsideTextAndChoice() {
        #expect(message(.data(Data([1])), .integer)?.contains("can't take binary data. It takes a whole number.") == true)
    }
}
