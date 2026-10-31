import Foundation
import SaveState
import Testing
@testable import SaveStateUI

@Suite("Control row")
struct ControlRowModelTests {
    @Test func anUnchangedRowShowsNoResetOrMarkers() {
        let model = ControlRowModel(control: describedControl())

        #expect(!model.showsReset)
        #expect(!model.showsMarkers)
        #expect(!model.showsChangedMarker)
        #expect(!model.showsRelaunchMarker)
    }

    @Test func aChangedRowShowsResetAndTheChangedMarkerOnly() {
        let model = ControlRowModel(control: describedControl(isChanged: true))

        #expect(model.showsReset)
        #expect(model.showsMarkers)
        #expect(model.showsChangedMarker)
        #expect(!model.showsRelaunchMarker)
    }

    @Test func aRelaunchRowShowsItsMarkerWithoutOfferingReset() {
        let model = ControlRowModel(control: describedControl(requiresRelaunch: true))

        #expect(model.showsMarkers)
        #expect(model.showsRelaunchMarker)
        #expect(!model.showsChangedMarker)
        #expect(!model.showsReset)
    }

    @Test(arguments: [
        (ControlValue.bool(true), true),
        (ControlValue.bool(false), false),
        (ControlValue.null, false),
        (ControlValue.string("true"), false)
    ])
    func onlyTrueTurnsTheToggleOn(value: ControlValue, isOn: Bool) {
        #expect(ControlRowModel(control: describedControl(value: value)).isOn == isOn)
    }

    @Test func thePickerSelectsTheStringValue() {
        let control = describedControl(kind: .choice(options: ["a", "b"]), value: .string("b"))

        #expect(ControlRowModel(control: control).selectedOption == "b")
    }

    @Test func thePickerSelectsNothingForAValueThatIsNotAString() {
        let control = describedControl(kind: .choice(options: ["a"]), value: .null)

        #expect(ControlRowModel(control: control).selectedOption == "")
    }

    /// UI tests find rows by these, so they can't change.
    @Test func identifiersKeepTheirContract() {
        let model = ControlRowModel(control: describedControl(key: "env"))

        #expect(model.rowIdentifier == "saveState.row.env")
        #expect(model.editorIdentifier == "saveState.control.env")
        #expect(model.resetIdentifier == "saveState.reset.env")
        #expect(model.changedIdentifier == "saveState.changed.env")
        #expect(model.relaunchIdentifier == "saveState.relaunch.env")
        #expect(ControlRowModel.clearIdentifier(editor: model.editorIdentifier) == "saveState.control.env.clear")
        #expect(ControlRowModel.setIdentifier(editor: model.editorIdentifier) == "saveState.control.env.set")
        #expect(ControlRowModel.nowIdentifier(editor: model.editorIdentifier) == "saveState.control.env.now")
    }
}

@Suite("Tri-state editor")
struct TriStateEditorTests {
    @Test func segmentsMapToOnOffAndNoOverride() {
        #expect(TriStateOption.all.map(\.title) == ["On", "Off", "Real"])
        #expect(TriStateOption.all.map(\.value) == [.bool(true), .bool(false), .null])
    }

    @Test func theCaptionReportsARealValueOfOn() {
        let control = describedControl(kind: .triState, value: .null, realValue: .bool(true))

        #expect(TriStateOption.realCaption(for: control) == "Real value: on")
    }

    @Test func theCaptionReportsARealValueOfOff() {
        let control = describedControl(kind: .triState, value: .bool(true), realValue: .bool(false))

        #expect(TriStateOption.realCaption(for: control) == "Real value: off")
    }

    @Test func thereIsNoCaptionWithoutARealValue() {
        let control = describedControl(kind: .triState, value: .bool(true))

        #expect(TriStateOption.realCaption(for: control) == nil)
    }
}

@Suite("Text draft")
struct TextDraftTests {
    private let american = Locale(identifier: "en_US")

    private func integer(_ value: Int) -> ControlDescription {
        describedControl(kind: .integer, value: .int(value))
    }

    private func decimal(_ value: Double) -> ControlDescription {
        describedControl(kind: .decimal, value: .double(value))
    }

    @Test func aDraftStartsWithTheValuesText() {
        let draft = TextDraft(value: .int(3), locale: american)

        #expect(draft.text == "3")
        #expect(!draft.isInvalid)
    }

    @Test func applyingEditedTextReturnsTheNewValue() {
        var draft = TextDraft(value: .int(3), locale: american)
        draft.text = "12"

        #expect(draft.apply(to: integer(3)) == .int(12))
        #expect(!draft.isInvalid)
    }

    @Test func applyingUneditedTextWritesNothing() {
        var draft = TextDraft(value: .int(3), locale: american)

        #expect(draft.apply(to: integer(3)) == nil)
        #expect(!draft.isInvalid)
    }

    /// 1/3 displays rounded, so writing the text back would change the value.
    @Test func applyingARoundedDecimalUneditedWritesNothing() throws {
        let third = 1.0 / 3.0
        var draft = TextDraft(value: .double(third), locale: american)
        let parsed = try #require(ControlText.value(from: draft.text, kind: .decimal, locale: american))
        #expect(parsed != .double(third))

        #expect(draft.apply(to: decimal(third)) == nil)
    }

    @Test func applyingInvalidTextWritesNothingAndFlagsTheDraft() {
        var draft = TextDraft(value: .int(3), locale: american)
        draft.text = "12abc"

        #expect(draft.apply(to: integer(3)) == nil)
        #expect(draft.isInvalid)
    }

    @Test func anInvalidDraftKeepsWhatWasTyped() {
        var draft = TextDraft(value: .int(3), locale: american)
        draft.text = "12abc"

        _ = draft.apply(to: integer(3))

        #expect(draft.text == "12abc")
    }

    @Test func fixingAnInvalidDraftClearsTheFlagAndApplies() {
        var draft = TextDraft(value: .int(3), locale: american)
        draft.text = "abc"
        _ = draft.apply(to: integer(3))
        draft.text = "4"

        #expect(draft.apply(to: integer(3)) == .int(4))
        #expect(!draft.isInvalid)
    }

    @Test func retypingTheCurrentValueClearsTheFlagWithoutWriting() {
        var draft = TextDraft(value: .int(3), locale: american)
        draft.text = "abc"
        _ = draft.apply(to: integer(3))
        draft.text = "3"

        #expect(draft.apply(to: integer(3)) == nil)
        #expect(!draft.isInvalid)
    }

    @Test func discardingShowsTheValueAndClearsTheFlag() {
        var draft = TextDraft(value: .int(3), locale: american)
        draft.text = "abc"
        _ = draft.apply(to: integer(3))

        draft.discard(showing: .int(3))

        #expect(draft.text == "3")
        #expect(!draft.isInvalid)
    }

    @Test func aValueChangedElsewhereReplacesTheDraft() {
        var draft = TextDraft(value: .int(3), locale: american)
        draft.text = "half-typ"

        draft.discard(showing: .int(9))

        #expect(draft.text == "9")
    }

    @Test func aDiscardedDraftHasNothingToWrite() {
        var draft = TextDraft(value: .int(3), locale: american)
        draft.text = "7"

        draft.discard(showing: .int(3))

        #expect(draft.apply(to: integer(3)) == nil)
    }

    @Test func decimalsFollowTheDraftsLocale() {
        let german = Locale(identifier: "de_DE")
        var draft = TextDraft(value: .double(1.5), locale: german)
        #expect(draft.text == "1,5")
        draft.text = "2,5"

        #expect(draft.apply(to: decimal(1.5)) == .double(2.5))
    }

    @Test func textMayBeClearedToEmpty() {
        var draft = TextDraft(value: .string("hi"), locale: american)
        draft.text = ""

        #expect(draft.apply(to: describedControl(kind: .text, value: .string("hi"))) == .string(""))
        #expect(!draft.isInvalid)
    }

    @Test func emptyNumbersAreInvalid() {
        var draft = TextDraft(value: .int(3), locale: american)
        draft.text = ""

        #expect(draft.apply(to: integer(3)) == nil)
        #expect(draft.isInvalid)
    }

    @Test func theHintNamesWhatTheKindAccepts() {
        #expect(TextDraft.invalidMessage(for: .integer) == "Enter a whole number.")
        #expect(TextDraft.invalidMessage(for: .decimal) == "Enter a number.")
    }
}

@Suite("Date editor")
struct DateEditorTests {
    private let override = Date(timeIntervalSince1970: 1_000)
    private let real = Date(timeIntervalSince1970: 2_000)
    private let now = Date(timeIntervalSince1970: 3_000)

    private func model(value: ControlValue = .null, realValue: ControlValue? = nil) -> DateEditorModel {
        DateEditorModel(control: describedControl(kind: .date, value: value, realValue: realValue))
    }

    @Test func anOverrideShowsThePicker() {
        #expect(model(value: .date(override)).date == override)
    }

    @Test func noOverrideShowsTheSetButton() {
        #expect(model(realValue: .date(real)).date == nil)
    }

    @Test func thePlaceholderSaysNotSetWithoutARealValue() {
        #expect(model().placeholder == "Not set")
    }

    @Test func thePlaceholderSaysUsingRealValueWithOne() {
        #expect(model(realValue: .date(real)).placeholder == "Using real value")
    }

    @Test func setPicksTheRealDateWhenThereIsOne() {
        #expect(model(realValue: .date(real)).dateForSet(now: now) == real)
    }

    @Test func setPicksNowWithoutARealDate() {
        #expect(model().dateForSet(now: now) == now)
    }

    @Test func theCaptionFormatsTheRealDate() {
        let expected = real.formatted(date: .abbreviated, time: .shortened)

        #expect(model(realValue: .date(real)).realCaption == "Real value: \(expected)")
    }

    @Test func thereIsNoCaptionWithoutARealDate() {
        #expect(model(value: .date(override)).realCaption == nil)
    }

    @Test func aRealValueThatIsNotADateIsIgnored() {
        let editor = model(realValue: .bool(true))

        #expect(editor.realDate == nil)
        #expect(editor.dateForSet(now: now) == now)
    }
}

@Suite("Clock editor")
struct ClockEditorTests {
    private let moved = Date(timeIntervalSince1970: 1_000)
    private let now = Date(timeIntervalSince1970: 500_000)

    private func model(value: ControlValue) -> ClockEditorModel {
        ClockEditorModel(control: describedControl(kind: .clock, value: value))
    }

    @Test func aDateMeansTheClockHasMoved() {
        let editor = model(value: .date(moved))

        #expect(editor.isMoved)
        #expect(editor.movedDate == moved)
    }

    @Test func nullMeansRealTime() {
        let editor = model(value: .null)

        #expect(!editor.isMoved)
        #expect(editor.movedDate == nil)
    }

    @Test func thePickerShowsTheMovedDate() {
        #expect(model(value: .date(moved)).pickerDate(now: now) == moved)
    }

    @Test func thePickerShowsTheRunningTimeWhenNotMoved() {
        #expect(model(value: .null).pickerDate(now: now) == now)
    }

    @Test func jumpsCoverTheCommonAmountsInOrder() {
        #expect(ClockJump.all.map(\.title) == ["-1d", "+1d", "+1w", "+30d"])
        #expect(ClockJump.all.map(\.interval) == [-86_400, 86_400, 604_800, 2_592_000])
    }

    @Test func jumpsHaveSpokenLabels() {
        #expect(ClockJump.all.map(\.accessibilityLabel) == [
            "Back one day", "Forward one day", "Forward one week", "Forward thirty days"
        ])
    }

    @Test func aJumpLandsRelativeToTheRunningClock() throws {
        let back = try #require(ClockJump.all.first { $0.title == "-1d" })

        #expect(back.target(from: now) == Date(timeIntervalSince1970: 500_000 - 86_400))
    }
}
