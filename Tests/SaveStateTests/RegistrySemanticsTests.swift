import Foundation
import Testing
@testable import SaveState

@Suite("Setting")
@MainActor
struct RegistrySettingTests {
    private let scratch = ScratchDefaults()

    @Test func valuesAreWrittenInDeclarationOrder() throws {
        let model = WriteLogModel()
        let registry = makeOrderedRegistry(model: model, store: scratch.store)

        try registry.set(["alpha": .bool(true), "mike": .bool(true), "zulu": .bool(true)])

        #expect(model.writes == ["zulu", "alpha", "mike"])
    }

    @Test func aBatchSetDoesNotPersistByDefault() throws {
        let store = scratch.store
        let registry = makeRegistry(model: DebugModel(), store: store)

        try registry.set(["greeting": .string("Hi")])

        #expect(store.value(forKey: "greeting", in: .persisted) == nil)
    }

    @Test func aSingleSetDoesNotPersistByDefault() throws {
        let store = scratch.store
        let registry = makeRegistry(model: DebugModel(), store: store)

        try registry.set(.string("Hi"), forKey: "greeting")

        #expect(store.value(forKey: "greeting", in: .persisted) == nil)
    }

    @Test func aDefaultBatchSetIsGoneAfterARelaunch() throws {
        let store = scratch.store
        try makeRegistry(model: DebugModel(), store: store).set(["greeting": .string("Hi")])
        let relaunched = DebugModel()

        _ = makeRegistry(model: relaunched, store: store)

        #expect(relaunched.greeting == "Hello")
    }

    @Test func aBadValueLeavesEveryModelValueUnchanged() {
        let model = WriteLogModel()
        let registry = makeOrderedRegistry(model: model, store: scratch.store)

        #expect(throws: SaveStateError.self) {
            try registry.set(["zulu": .bool(true), "alpha": .bool(true), "mike": .int(1)])
        }

        #expect(model.writes.isEmpty)
    }

    @Test func aBadValueStoresNothing() {
        let store = scratch.store
        let registry = makeOrderedRegistry(model: WriteLogModel(), store: store)

        #expect(throws: SaveStateError.self) {
            try registry.set(["zulu": .bool(true), "mike": .int(1)], persist: true)
        }

        #expect(store.value(forKey: "zulu", in: .persisted) == nil)
    }

    @Test func anUnknownKeyStoresNothing() {
        let store = scratch.store
        let registry = makeOrderedRegistry(model: WriteLogModel(), store: store)

        #expect(throws: SaveStateError.unknownControl("nope")) {
            try registry.set(["zulu": .bool(true), "nope": .bool(true)], persist: true)
        }

        #expect(store.value(forKey: "zulu", in: .persisted) == nil)
    }

    @Test func aBadValueOnARelaunchControlLeavesNothingForTheNextLaunch() {
        let store = scratch.store
        let registry = makeRegistry(model: DebugModel(), store: store)

        #expect(throws: SaveStateError.self) {
            try registry.set(["env": .string("staging"), "launches": .string("many")])
        }

        #expect(store.value(forKey: "env", in: .nextLaunch) == nil)
    }

    @Test func anUnknownKeyIsReportedBeforeABadValue() {
        let registry = makeRegistry(model: DebugModel(), store: scratch.store)

        #expect(throws: SaveStateError.unknownControl("nope")) {
            try registry.set(["onboarding": .int(1), "nope": .int(1)])
        }
    }

    @Test func anEmptyBatchChangesNothing() throws {
        let model = WriteLogModel()
        let registry = makeOrderedRegistry(model: model, store: scratch.store)

        try registry.set([:], persist: true)

        #expect(model.writes.isEmpty)
    }

    @Test func aBatchPersistsEveryValue() throws {
        let store = scratch.store
        let registry = makeOrderedRegistry(model: WriteLogModel(), store: store)

        try registry.set(["zulu": .bool(true), "mike": .bool(true)], persist: true)

        #expect(store.value(forKey: "zulu", in: .persisted) == .bool(true))
        #expect(store.value(forKey: "mike", in: .persisted) == .bool(true))
    }

    @Test func theNormalizedValueIsWhatGetsStored() throws {
        let store = scratch.store
        let registry = makeRegistry(model: DebugModel(), store: store)

        try registry.set(.int(2), forKey: "discount", persist: true)

        #expect(store.value(forKey: "discount", in: .persisted) == .double(2))
    }

    @Test func aDateJSONWouldChangeIsRefused() {
        let model = DebugModel()
        let registry = makeRegistry(model: model, store: scratch.store)
        let beforeYearOne = ControlValue.date(Date(timeIntervalSince1970: -62_200_000_000))

        #expect(throws: SaveStateError.invalidValue(key: "trial-end", value: beforeYearOne, kind: .date)) {
            try registry.set(beforeYearOne, forKey: "trial-end", persist: true)
        }

        #expect(model.trialEndOverride == nil)
    }

    @Test func aSessionValueStoresNothingOnAnOrdinaryControl() throws {
        let store = scratch.store
        let registry = makeRegistry(model: DebugModel(), store: store)

        try registry.set(.string("Hi"), forKey: "greeting")

        #expect(store.value(forKey: "greeting", in: .persisted) == nil)
        #expect(store.value(forKey: "greeting", in: .nextLaunch) == nil)
    }

    @Test func aSessionValueOnARelaunchControlAppliesNowAsWell() throws {
        let model = DebugModel()
        let registry = makeRegistry(model: model, store: scratch.store)

        try registry.set(.string("staging"), forKey: "env")

        #expect(model.environment == .staging)
    }

    @Test func persistingReplacesAPendingNextLaunchValue() throws {
        let store = scratch.store
        let registry = makeRegistry(model: DebugModel(), store: store)
        try registry.set(.string("staging"), forKey: "env")

        try registry.set(.string("production"), forKey: "env", persist: true)

        #expect(store.value(forKey: "env", in: .nextLaunch) == nil)
        #expect(store.value(forKey: "env", in: .persisted) == .string("production"))
    }

    @Test func aSessionValueLeavesAPersistedValueInPlace() throws {
        let store = scratch.store
        let registry = makeRegistry(model: DebugModel(), store: store)
        try registry.set(.string("Persisted"), forKey: "greeting", persist: true)

        try registry.set(.string("Session"), forKey: "greeting")

        #expect(store.value(forKey: "greeting", in: .persisted) == .string("Persisted"))
    }
}

@Suite("Restoring")
@MainActor
struct RegistryRestoringTests {
    private let scratch = ScratchDefaults()

    private func corrupt(_ key: String, in slot: OverrideStore.Slot) throws {
        let defaults = try #require(UserDefaults(suiteName: scratch.suiteName))
        defaults.set(Data("not json".utf8), forKey: scratch.store.defaultsKey(forKey: key, in: slot))
    }

    @Test func storedValuesAreRestoredInDeclarationOrder() {
        let store = scratch.store
        store.save(.bool(true), forKey: "alpha", in: .persisted)
        store.save(.bool(true), forKey: "mike", in: .nextLaunch)
        store.save(.bool(true), forKey: "zulu", in: .persisted)
        let model = WriteLogModel()

        _ = makeOrderedRegistry(model: model, store: store)

        #expect(model.writes == ["zulu", "alpha", "mike"])
    }

    @Test func aControlWithNothingStoredIsNotWritten() {
        let store = scratch.store
        store.save(.bool(true), forKey: "alpha", in: .persisted)
        let model = WriteLogModel()

        _ = makeOrderedRegistry(model: model, store: store)

        #expect(model.writes == ["alpha"])
    }

    @Test func aRefusedNextLaunchValueFallsBackToThePersistedValue() {
        let store = scratch.store
        store.save(.string("removed"), forKey: "env", in: .nextLaunch)
        store.save(.string("staging"), forKey: "env", in: .persisted)
        let model = DebugModel()

        _ = makeRegistry(model: model, store: store)

        #expect(model.environment == .staging)
        #expect(store.value(forKey: "env", in: .nextLaunch) == nil)
        #expect(store.value(forKey: "env", in: .persisted) == .string("staging"))
    }

    @Test func anUndecodableNextLaunchValueFallsBackToThePersistedValue() throws {
        let store = scratch.store
        try corrupt("env", in: .nextLaunch)
        store.save(.string("staging"), forKey: "env", in: .persisted)
        let model = DebugModel()

        _ = makeRegistry(model: model, store: store)

        #expect(model.environment == .staging)
    }

    @Test func anAppliedNextLaunchValueDoesNotDisturbThePersistedValue() {
        let store = scratch.store
        store.save(.string("production"), forKey: "env", in: .nextLaunch)
        store.save(.string("staging"), forKey: "env", in: .persisted)

        _ = makeRegistry(model: DebugModel(), store: store)

        #expect(store.value(forKey: "env", in: .persisted) == .string("staging"))
    }

    @Test func aDroppedValueLeavesTheDeclaredValueAndLaterControlsRestore() {
        let store = scratch.store
        store.save(.string("removed"), forKey: "env", in: .persisted)
        store.save(.string("Restored"), forKey: "greeting", in: .persisted)
        let model = DebugModel()

        _ = makeRegistry(model: model, store: store)

        #expect(model.environment == .production)
        #expect(model.greeting == "Restored")
    }

    @Test func aDroppedValueNoLongerCountsAsChanged() {
        let store = scratch.store
        store.save(.string("removed"), forKey: "env", in: .persisted)

        let registry = makeRegistry(model: DebugModel(), store: store)

        #expect(registry.changedKeys.isEmpty)
    }

    @Test func aValueOfAKindTheControlChangedFromIsDropped() {
        let store = scratch.store
        store.save(.string("not a number"), forKey: "launches", in: .persisted)
        let model = DebugModel()

        _ = makeRegistry(model: model, store: store)

        #expect(model.launchCount == 0)
        #expect(store.value(forKey: "launches", in: .persisted) == nil)
    }

    @Test func aStoredWholeNumberRestoresIntoADecimal() {
        let store = scratch.store
        store.save(.int(3), forKey: "discount", in: .persisted)
        let model = DebugModel()

        _ = makeRegistry(model: model, store: store)

        #expect(model.discount == 3)
    }

    @Test func aPersistedNullClearsAnOverrideTheModelStartsWith() throws {
        let store = scratch.store
        let first = DebugModel()
        first.premiumOverride = true
        try makeRegistry(model: first, store: store).set(.null, forKey: "premium", persist: true)

        let relaunched = DebugModel()
        relaunched.premiumOverride = true
        _ = makeRegistry(model: relaunched, store: store)

        #expect(relaunched.premiumOverride == nil)
    }

    @Test func storedValuesForRemovedControlsAreLeftAlone() {
        let store = scratch.store
        store.save(.bool(true), forKey: "retired", in: .persisted)

        let registry = makeRegistry(model: DebugModel(), store: store)

        #expect(registry.changedKeys.isEmpty)
        #expect(store.value(forKey: "retired", in: .persisted) == .bool(true))
    }

    @Test func aDisabledRegistryKeepsANextLaunchValueForLater() {
        let store = scratch.store
        store.save(.string("staging"), forKey: "env", in: .nextLaunch)
        let model = DebugModel()

        _ = makeRegistry(model: model, store: store, isEnabled: false)

        #expect(model.environment == .production)
        #expect(store.value(forKey: "env", in: .nextLaunch) == .string("staging"))
    }

    @Test func describePrefersTheNextLaunchValueOverThePersistedOne() throws {
        let registry = makeRegistry(model: DebugModel(), store: scratch.store)
        try registry.set(.string("production"), forKey: "env", persist: true)
        try registry.set(.string("staging"), forKey: "env")

        let control = try #require(registry.describe().controls.first { $0.key == "env" })

        #expect(control.nextLaunchValue == .string("staging"))
    }

    @Test func describeFallsBackToThePersistedValueAfterTheNextLaunchIsConsumed() throws {
        let store = scratch.store
        store.save(.string("production"), forKey: "env", in: .nextLaunch)
        store.save(.string("staging"), forKey: "env", in: .persisted)

        let registry = makeRegistry(model: DebugModel(), store: store)

        let control = try #require(registry.describe().controls.first { $0.key == "env" })
        #expect(control.nextLaunchValue == .string("staging"))
    }
}

@Suite("Changes and resets")
@MainActor
struct RegistryResetTests {
    private let scratch = ScratchDefaults()

    @Test func resetAllWritesInDeclarationOrder() throws {
        let model = WriteLogModel()
        let registry = makeOrderedRegistry(model: model, store: scratch.store)
        try registry.set(["alpha": .bool(true)])
        model.clearWrites()

        try registry.resetAll()

        #expect(model.writes == ["zulu", "alpha", "mike"])
    }

    @Test func resetReturnsToTheDeclaredValueNotTheRestoredOne() throws {
        let store = scratch.store
        store.save(.string("Restored"), forKey: "greeting", in: .persisted)
        let model = DebugModel()
        model.greeting = "Declared"
        let registry = makeRegistry(model: model, store: store)
        #expect(model.greeting == "Restored")

        try registry.reset("greeting")

        #expect(model.greeting == "Declared")
    }

    @Test func resetClearsBothSlots() throws {
        let store = scratch.store
        let registry = makeRegistry(model: DebugModel(), store: store)
        try registry.set(.string("staging"), forKey: "env", persist: true)
        try registry.set(.string("production"), forKey: "env")

        try registry.reset("env")

        #expect(store.value(forKey: "env", in: .persisted) == nil)
        #expect(store.value(forKey: "env", in: .nextLaunch) == nil)
    }

    @Test func resetLeavesOtherControls() throws {
        let model = DebugModel()
        let registry = makeRegistry(model: model, store: scratch.store)
        try registry.set(["greeting": .string("Hi"), "launches": .int(3)], persist: true)

        try registry.reset("greeting")

        #expect(model.launchCount == 3)
        #expect(registry.changedKeys == ["launches"])
    }

    @Test func aResetValueDoesNotReturnAtTheNextLaunch() throws {
        let store = scratch.store
        let registry = makeRegistry(model: DebugModel(), store: store)
        try registry.set(.string("Hi"), forKey: "greeting", persist: true)
        try registry.resetAll()

        let relaunched = DebugModel()
        _ = makeRegistry(model: relaunched, store: store)

        #expect(relaunched.greeting == "Hello")
    }

    @Test func settingTheDefaultValueIsNotAChange() throws {
        let registry = makeRegistry(model: DebugModel(), store: scratch.store)

        try registry.set(.string("Hello"), forKey: "greeting", persist: true)

        #expect(registry.changedKeys.isEmpty)
    }

    @Test func changingBackToTheDefaultClearsTheChange() throws {
        let registry = makeRegistry(model: DebugModel(), store: scratch.store)
        try registry.set(.string("Hi"), forKey: "greeting")

        try registry.set(.string("Hello"), forKey: "greeting")

        #expect(registry.changedKeys.isEmpty)
    }

    @Test func aRestoredValueCountsAsChanged() {
        let store = scratch.store
        store.save(.string("Hi"), forKey: "greeting", in: .persisted)

        let registry = makeRegistry(model: DebugModel(), store: store)

        #expect(registry.changedKeys == ["greeting"])
    }

    @Test func aPendingNextLaunchValueCountsAsChangedWhileTheLiveValueIsTheDefault() throws {
        let model = DebugModel()
        let registry = makeRegistry(model: model, store: scratch.store)
        try registry.set(.string("staging"), forKey: "env")

        model.environment = .production

        #expect(registry.changedKeys == ["env"])
    }

    @Test func changedKeysFollowDeclarationOrder() throws {
        let registry = makeOrderedRegistry(model: WriteLogModel(), store: scratch.store)

        try registry.set(["mike": .bool(true), "alpha": .bool(true), "zulu": .bool(true)])

        #expect(registry.changedKeys == ["zulu", "alpha", "mike"])
    }

    @Test func describeReportsEachActionsKeyLabelSectionAndDestructiveness() {
        let registry = SaveStateRegistry(model: DebugModel(), store: scratch.store, isEnabled: true) { r in
            r.section("Data") {
                r.action("Erase everything", key: "erase", destructive: true) {}
            }
            r.action("Seed the data", key: "seed") {}
        }

        #expect(registry.describe().actions == [
            ActionDescription(key: "erase", label: "Erase everything", section: "Data", isDestructive: true),
            ActionDescription(key: "seed", label: "Seed the data", section: nil, isDestructive: false)
        ])
    }

    @Test func describeReportsIsChanged() throws {
        let registry = makeRegistry(model: DebugModel(), store: scratch.store)

        try registry.set(.string("Hi"), forKey: "greeting")

        let changed = registry.describe().controls.filter(\.isChanged).map(\.key)
        #expect(changed == ["greeting"])
    }

    @Test func describeReportsTheDeclaredDefaultAfterARestore() throws {
        let store = scratch.store
        store.save(.string("Restored"), forKey: "greeting", in: .persisted)

        let registry = makeRegistry(model: DebugModel(), store: store)

        let control = try #require(registry.describe().controls.first { $0.key == "greeting" })
        #expect(control.defaultValue == .string("Hello"))
        #expect(control.value == .string("Restored"))
    }

    @Test func aDiscardingStoreStillAppliesValuesForThisLaunch() throws {
        let model = DebugModel()
        let registry = makeRegistry(model: model, store: .discarding)

        try registry.set(.string("Hi"), forKey: "greeting", persist: true)

        #expect(model.greeting == "Hi")
    }

    @Test func aDiscardingStoreStillResetsTheModel() throws {
        let model = DebugModel()
        let registry = makeRegistry(model: model, store: .discarding)
        try registry.set(.string("Hi"), forKey: "greeting", persist: true)

        try registry.reset("greeting")

        #expect(model.greeting == "Hello")
    }
}

@Suite("Actions and scenarios")
@MainActor
struct RegistryOperationTests {
    private let scratch = ScratchDefaults()

    private func makeFailingRegistry(model: DebugModel) -> SaveStateRegistry {
        SaveStateRegistry(model: model, store: scratch.store, isEnabled: true) { r in
            r.text("Greeting", key: "greeting", \.greeting)
            r.action("Fail", key: "fail") {
                model.actionRuns += 1
                throw TestError.failed
            }
            r.scenario("Half done", key: "half-done") { state in
                state.greeting = "Partial"
                throw TestError.failed
            }
            r.scenario("Sets persisted-looking state", key: "plain") { state in
                state.greeting = "Scenario"
            }
        }
    }

    @Test func actionErrorsReachTheCaller() async {
        let model = DebugModel()
        let registry = makeFailingRegistry(model: model)

        await #expect(throws: TestError.failed) {
            try await registry.runAction("fail")
        }

        #expect(model.actionRuns == 1)
    }

    @Test func aDestructiveActionRefusalComesBeforeRunning() async {
        let model = DebugModel()
        model.actionRuns = 3
        let registry = makeRegistry(model: model, store: scratch.store)

        await #expect(throws: SaveStateError.destructiveActionNotAllowed("erase")) {
            try await registry.runAction("erase", allowDestructive: false)
        }

        #expect(model.actionRuns == 3)
    }

    @Test func allowDestructiveAlsoRunsOrdinaryActions() async throws {
        let model = DebugModel()
        let registry = makeRegistry(model: model, store: scratch.store)

        try await registry.runAction("count", allowDestructive: true)

        #expect(model.actionRuns == 1)
    }

    @Test func aFailedScenarioKeepsItsPartialChanges() async {
        let model = DebugModel()
        let registry = makeFailingRegistry(model: model)

        await #expect(throws: TestError.failed) {
            try await registry.applyScenario("half-done")
        }

        #expect(model.greeting == "Partial")
    }

    @Test func aFailedScenarioCanBeResetAway() async throws {
        let model = DebugModel()
        let registry = makeFailingRegistry(model: model)
        await #expect(throws: TestError.failed) {
            try await registry.applyScenario("half-done")
        }
        #expect(registry.changedKeys == ["greeting"])

        try registry.resetAll()

        #expect(model.greeting == "Hello")
        #expect(registry.changedKeys.isEmpty)
    }

    @Test func aFailedScenarioLeavesTheRegistryUsable() async throws {
        let model = DebugModel()
        let registry = makeFailingRegistry(model: model)
        await #expect(throws: TestError.failed) {
            try await registry.applyScenario("half-done")
        }

        try await registry.applyScenario("plain")

        #expect(model.greeting == "Scenario")
    }

    @Test func scenarioChangesLastOnlyForThisLaunch() async throws {
        let store = scratch.store
        try await makeRegistry(model: DebugModel(), store: store).applyScenario("expired-trial")

        let relaunched = DebugModel()
        _ = makeRegistry(model: relaunched, store: store)

        #expect(relaunched.premiumOverride == nil)
        #expect(relaunched.trialEndOverride == nil)
    }

    @Test func aDisabledRegistryReportsDisabledBeforeUnknownKeys() async {
        let registry = makeRegistry(model: DebugModel(), store: scratch.store, isEnabled: false)

        #expect(throws: SaveStateError.disabled) {
            try registry.set(.bool(true), forKey: "nope")
        }
        #expect(throws: SaveStateError.disabled) {
            try registry.reset("nope")
        }
        await #expect(throws: SaveStateError.disabled) {
            try await registry.runAction("nope")
        }
        await #expect(throws: SaveStateError.disabled) {
            try await registry.applyScenario("nope")
        }
    }

    @Test func aDisabledRegistryStillReadsValues() throws {
        let model = DebugModel()
        model.greeting = "Real"
        let registry = makeRegistry(model: model, store: scratch.store, isEnabled: false)

        let value = try registry.value(forKey: "greeting")

        #expect(value == .string("Real"))
    }

    @Test func effectiveValueThrowsForAnUnknownKey() {
        let registry = makeRegistry(model: DebugModel(), store: scratch.store)

        #expect(throws: SaveStateError.unknownControl("nope")) {
            try registry.effectiveValue(forKey: "nope")
        }
    }
}
