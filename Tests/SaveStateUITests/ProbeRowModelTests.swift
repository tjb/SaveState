import Foundation
import SaveState
import Testing
@testable import SaveStateUI

@Suite("Probe row")
struct ProbeRowModelTests {
    private let american = Locale(identifier: "en_US")
    private let germany = Locale(identifier: "de_DE")

    private func text(_ value: ControlValue, locale: Locale = Locale(identifier: "en_US"), timeZone: TimeZone = .gmt) -> String {
        ProbeRowModel(probe: describedProbe(value: value), locale: locale, timeZone: timeZone).valueText
    }

    @Test func boolsReadAsOnAndOff() {
        #expect(text(.bool(true)) == "On")
        #expect(text(.bool(false)) == "Off")
    }

    @Test func wholeNumbersShowWithoutGrouping() {
        #expect(text(.int(-12)) == "-12")
        #expect(text(.int(12_345), locale: germany) == "12345")
    }

    /// Decimals follow the locale the way the decimal control's editor does.
    @Test func decimalsFollowTheLocale() {
        #expect(text(.double(0.25), locale: american) == "0.25")
        #expect(text(.double(1.5), locale: germany) == "1,5")
        #expect(text(.double(1234.5), locale: american) == "1234.5")
    }

    @Test func stringsShowAsTheyAre() {
        #expect(text(.string(" home ")) == " home ")
    }

    @Test func anEmptyStringSaysSo() {
        #expect(text(.string("")) == "Empty")
    }

    @Test func datesFollowTheLocaleAndTimeZone() throws {
        let date = ControlValue.date(try #require(ISO8601DateFormatter().date(from: "2026-01-15T08:30:00Z")))

        let american = text(date, locale: american, timeZone: .gmt)
        let german = text(date, locale: germany, timeZone: .gmt)
        let tokyo = text(date, locale: germany, timeZone: try #require(TimeZone(identifier: "Asia/Tokyo")))

        #expect(american.contains("Jan 15, 2026"), "\(american)")
        #expect(american.contains("8:30"), "\(american)")
        #expect(german.contains("2026"), "\(german)")
        #expect(german.contains("15. Jan"), "\(german)")
        #expect(!german.contains("AM"), "\(german)")
        #expect(tokyo.contains("17:30"), "\(tokyo)")
    }

    @Test func aMissingValueSaysNotSet() {
        #expect(text(.null) == "Not set")
    }

    @Test(arguments: [
        (ControlValue.bool(true), true),
        (.null, true),
        (.string(""), true),
        (.string("home"), false),
        (.int(1), false),
        (.double(1), false),
        (.date(.distantPast), false)
    ])
    func onlyThePanelsOwnWordsAreTranslated(value: ControlValue, isPanelWord: Bool) {
        let model = ProbeRowModel(probe: describedProbe(value: value))

        #expect(model.isPanelWord == isPanelWord)
        #expect((model.valueKey != nil) == isPanelWord)
    }

    @Test func translatedWordsUseTheirTextAsTheKey() {
        #expect(ProbeRowModel(probe: describedProbe(value: .bool(false))).valueKey == "Off")
        #expect(ProbeRowModel(probe: describedProbe(value: .string(""))).valueKey == "Empty")
    }

    @Test func theAccessibilityValueIsTheShownTextAsAPlainString() throws {
        #expect(ProbeRowModel(probe: describedProbe(value: .int(1234)), locale: american).accessibilityValue == "1234")
        #expect(ProbeRowModel(probe: describedProbe(value: .string("home"))).accessibilityValue == "home")
        // With no translation, a panel word reads as itself.
        #expect(ProbeRowModel(probe: describedProbe(value: .bool(true)), bundle: try bundle(translating: [:])).accessibilityValue == "On")
    }

    @Test func theAccessibilityValueTranslatesOnlyThePanelsOwnWords() throws {
        let german = try bundle(translating: ["On": "Ein", "home": "Zuhause"])

        #expect(ProbeRowModel(probe: describedProbe(value: .bool(true)), bundle: german).accessibilityValue == "Ein")
        #expect(ProbeRowModel(probe: describedProbe(value: .string("home")), bundle: german).accessibilityValue == "home")
    }

    /// A bundle on disk whose strings table holds these translations.
    private func bundle(translating table: [String: String]) throws -> Bundle {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProbeRowModelTests-\(UUID().uuidString).bundle")
        let strings = root.appendingPathComponent("Contents/Resources/en.lproj", isDirectory: true)
        try FileManager.default.createDirectory(at: strings, withIntermediateDirectories: true)
        let body = table.map { "\"\($0.key)\" = \"\($0.value)\";" }.joined(separator: "\n")
        try Data(body.utf8).write(to: strings.appendingPathComponent("Localizable.strings"))
        return try #require(Bundle(url: root))
    }

    /// UI tests find rows by this, so it can't change.
    @Test func theIdentifierKeepsItsContract() {
        #expect(ProbeRowModel(probe: describedProbe(key: "item-count", value: .int(0))).rowIdentifier == "saveState.probe.item-count")
    }
}
