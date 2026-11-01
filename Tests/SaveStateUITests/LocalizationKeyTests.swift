import SaveState
import SwiftUI
import Testing
@testable import SaveStateUI

/// Text a host app can translate has to reach SwiftUI as a localization key. These
/// pin the keys, because a plain `String` would silently show English.
@Suite("Localization keys")
struct LocalizationKeyTests {
    private func control(real: ControlValue?, kind: ControlKind) -> ControlDescription {
        ControlDescription(
            key: "key",
            label: "Label",
            section: nil,
            kind: kind,
            value: .null,
            realValue: real,
            effectiveValue: .null,
            defaultValue: .null,
            requiresRelaunch: false,
            nextLaunchValue: nil,
            isChanged: false
        )
    }

    /// The key a translator sees. Interpolated keys can't be compared with `==`.
    private func catalogKey(_ key: LocalizedStringKey) -> String? {
        Mirror(reflecting: key).children.first { $0.label == "key" }?.value as? String
    }

    @Test func theStatusUsesPluralizableKeys() {
        #expect(PanelStatus(changedCount: 0).textKey == "Everything at its default")
        #expect(PanelStatus(changedCount: 1).textKey == "1 control changed")
        #expect(catalogKey(PanelStatus(changedCount: 3).textKey) == "%lld controls changed")
    }

    @Test func triStateOptionsUseKeys() {
        #expect(TriStateOption.all.map(\.titleKey) == ["On", "Off", "Real"])
    }

    @Test func theRealCaptionInterpolatesItsValue() {
        let key = TriStateOption.realCaptionKey(for: control(real: .bool(true), kind: .triState))

        #expect(key.map(catalogKey) == "Real value: %@")
        #expect(TriStateOption.realCaptionKey(for: control(real: nil, kind: .triState)) == nil)
    }

    @Test func invalidHintsUseKeys() {
        #expect(TextDraft.invalidMessageKey(for: .integer) == "Enter a whole number.")
        #expect(TextDraft.invalidMessageKey(for: .decimal) == "Enter a number.")
    }

    @Test func datePlaceholdersUseKeys() {
        #expect(DateEditorModel(control: control(real: nil, kind: .date)).placeholderKey == "Not set")
    }

    @Test func theDateCaptionInterpolatesItsValue() {
        let model = DateEditorModel(control: control(real: .date(.distantPast), kind: .date))

        #expect(model.realCaptionKey.map(catalogKey) == "Real value: %@")
    }
}
