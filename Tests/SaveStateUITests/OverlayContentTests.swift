import Foundation
import SaveState
import Testing
@testable import SaveStateUI

private func control(
    key: String = "key",
    section: String? = nil,
    kind: ControlKind = .toggle,
    value: ControlValue = .bool(false),
    defaultValue: ControlValue = .bool(false),
    nextLaunchValue: ControlValue? = nil
) -> ControlDescription {
    ControlDescription(
        key: key,
        label: key,
        section: section,
        kind: kind,
        value: value,
        realValue: nil,
        effectiveValue: value,
        defaultValue: defaultValue,
        requiresRelaunch: false,
        nextLaunchValue: nextLaunchValue
    )
}

@Suite("Overlay content")
struct OverlayContentTests {
    @Test func groupsFollowDeclarationOrderAndMergeRepeatedSections() {
        let groups = OverlayGroup.grouping(
            [
                control(key: "a", section: "One"),
                control(key: "b"),
                control(key: "c", section: "Two"),
                control(key: "d", section: "One"),
                control(key: "e")
            ],
            section: \.section
        )

        #expect(groups.map(\.title) == ["One", nil, "Two"])
        #expect(groups.map { $0.items.map(\.key) } == [["a", "d"], ["b", "e"], ["c"]])
    }

    @Test func aControlAtItsDefaultIsUnchanged() {
        #expect(!control().isChanged)
        #expect(!control(nextLaunchValue: .bool(false)).isChanged)
    }

    @Test func aDifferentValueIsChanged() {
        #expect(control(value: .bool(true)).isChanged)
    }

    @Test func aStoredValueThatWouldReturnNextLaunchIsChanged() {
        #expect(control(nextLaunchValue: .bool(true)).isChanged)
    }
}

@Suite("Control text")
struct ControlTextTests {
    private let us = Locale(identifier: "en_US")
    private let germany = Locale(identifier: "de_DE")

    @Test func integersParseWholeNumbersOnly() {
        #expect(ControlText.value(from: " -12 ", kind: .integer) == .int(-12))
        #expect(ControlText.value(from: "1.5", kind: .integer) == nil)
        #expect(ControlText.value(from: "", kind: .integer) == nil)
        #expect(ControlText.value(from: "99999999999999999999", kind: .integer) == nil)
    }

    @Test func decimalsFollowTheLocale() {
        #expect(ControlText.value(from: "-1.5", kind: .decimal, locale: us) == .double(-1.5))
        #expect(ControlText.value(from: "1,5", kind: .decimal, locale: germany) == .double(1.5))
        #expect(ControlText.text(for: .double(1.5), locale: germany) == "1,5")
    }

    @Test func decimalsRejectWhatIsNotAFiniteNumber() {
        #expect(ControlText.value(from: "12abc", kind: .decimal, locale: us) == nil)
        #expect(ControlText.value(from: "", kind: .decimal, locale: us) == nil)
        #expect(ControlText.value(from: "∞", kind: .decimal, locale: us) == nil)
        #expect(ControlText.value(from: "NaN", kind: .decimal, locale: us) == nil)
    }

    @Test func decimalsRoundTripTheirDisplayedText() {
        for number in [0.0, 0.15, -3.25, 1234567.5] {
            let text = ControlText.text(for: .double(number), locale: us)
            #expect(ControlText.value(from: text, kind: .decimal, locale: us) == .double(number))
        }
    }

    @Test func textKeepsItsWhitespace() {
        #expect(ControlText.value(from: " hi ", kind: .text) == .string(" hi "))
    }
}
