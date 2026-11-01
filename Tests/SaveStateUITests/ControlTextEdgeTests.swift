import Foundation
import SaveState
import Testing
@testable import SaveStateUI

private let american = Locale(identifier: "en_US")
private let german = Locale(identifier: "de_DE")

private func decimalControl(_ value: Double) -> ControlDescription {
    ControlDescription(
        key: "ratio",
        label: "Ratio",
        section: nil,
        kind: .decimal,
        value: .double(value),
        realValue: nil,
        effectiveValue: .double(value),
        defaultValue: .double(value),
        requiresRelaunch: false,
        nextLaunchValue: nil,
        isChanged: false
    )
}

@Suite("Control text edges")
struct ControlTextEdgeTests {
    @Test func decimalsKeepTheirFractionDigits() {
        #expect(ControlText.text(for: .double(0.125), locale: american) == "0.125")
    }

    @Test func decimalsShowNoGroupingSeparators() {
        #expect(ControlText.text(for: .double(1_234_567.5), locale: american) == "1234567.5")
    }

    @Test func decimalsIgnoreSurroundingWhitespace() {
        #expect(ControlText.value(from: " 1.5 ", kind: .decimal, locale: american) == .double(1.5))
    }

    @Test func aNumberTooLargeToRepresentIsRefused() {
        let tooLarge = "1" + String(repeating: "0", count: 400)

        #expect(ControlText.value(from: tooLarge, kind: .decimal, locale: american) == nil)
    }

    @Test(arguments: [
        ControlKind.toggle,
        .triState,
        .choice(options: ["x"]),
        .date,
        .clock
    ])
    func kindsWithoutTextEditorsTakeNoText(kind: ControlKind) {
        #expect(ControlText.value(from: "x", kind: kind, locale: american) == nil)
    }

    @Test func anUneditedDraftInAnotherLocaleWritesNothing() {
        var draft = TextDraft(value: .double(1.5), locale: german)
        #expect(draft.text == "1,5")

        #expect(draft.apply(to: decimalControl(1.5)) == nil)
        #expect(!draft.isInvalid)
    }

    @Test func discardingShowsTheValueInTheDraftsLocale() {
        var draft = TextDraft(value: .double(1.5), locale: german)

        draft.discard(showing: .double(2.5))

        #expect(draft.text == "2,5")
    }
}
