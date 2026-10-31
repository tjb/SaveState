import Foundation
import Observation
import Testing
@testable import SaveState

@Suite("Registry")
@MainActor
struct RegistryTests {
    private let scratch = ScratchDefaults()

    // MARK: - Describing

    @Test func describeReportsEveryDeclarationInOrder() throws {
        let model = DebugModel()
        model.isEntitled = true
        let description = makeRegistry(model: model, store: scratch.store).describe()

        #expect(description.controls.map(\.key) == [
            "onboarding", "premium", "trial-end", "env", "greeting", "launches", "discount"
        ])
        #expect(description.actions.map(\.key) == ["count", "erase"])
        #expect(description.actions.map(\.isDestructive) == [false, true])
        #expect(description.scenarios.map(\.key) == ["expired-trial", "broken"])

        let premium = try #require(description.controls.first(where: { $0.key == "premium" }))
        #expect(premium.label == "Premium")
        #expect(premium.section == "Purchases")
        #expect(premium.kind == .triState)
        #expect(premium.value == .null)
        #expect(premium.realValue == .bool(true))
        #expect(premium.effectiveValue == .bool(true))
        #expect(premium.defaultValue == .null)
        #expect(!premium.requiresRelaunch)
        #expect(premium.nextLaunchValue == nil)

        let environment = try #require(description.controls.first(where: { $0.key == "env" }))
        #expect(environment.kind == .choice(options: ["staging", "production"]))
        #expect(environment.section == nil)
        #expect(environment.value == .string("production"))
        #expect(environment.realValue == nil)
        #expect(environment.requiresRelaunch)

        let expiredTrial = try #require(description.scenarios.first)
        #expect(expiredTrial.label == "Expired trial")
        #expect(expiredTrial.section == "Purchases")
        #expect(expiredTrial.summary == "The trial ended, so the paywall shows.")
        #expect(description.scenarios.last?.summary == nil)
    }

    @Test func sectionsNestAndRestore() {
        let registry = SaveStateRegistry(model: DebugModel(), store: scratch.store, isEnabled: true) { r in
            r.section("Outer") {
                r.section("Inner") {
                    r.toggle("A", key: "a", \.showsOnboarding)
                }
                r.text("B", key: "b", \.greeting)
            }
            r.integer("C", key: "c", \.launchCount)
        }

        #expect(registry.describe().controls.map(\.section) == ["Inner", "Outer", nil])
    }

    // MARK: - Setting

    @Test func setWritesTheModel() throws {
        let model = DebugModel()
        let registry = makeRegistry(model: model, store: scratch.store)
        let trialEnd = Date(timeIntervalSince1970: 1_800_000_000)

        try registry.set(.bool(true), forKey: "onboarding")
        try registry.set(.bool(true), forKey: "premium")
        try registry.set(.date(trialEnd), forKey: "trial-end")
        try registry.set(.string("staging"), forKey: "env")
        try registry.set(.string("Hi"), forKey: "greeting")
        try registry.set(.int(3), forKey: "launches")
        try registry.set(.double(0.25), forKey: "discount")

        #expect(model.showsOnboarding)
        #expect(model.premiumOverride == true)
        #expect(model.trialEndOverride == trialEnd)
        #expect(model.environment == .staging)
        #expect(model.greeting == "Hi")
        #expect(model.launchCount == 3)
        #expect(model.discount == 0.25)

        let environment = try registry.value(forKey: "env")
        #expect(environment == .string("staging"))
    }

    @Test func nullClearsOptionalOverrides() throws {
        let model = DebugModel()
        let registry = makeRegistry(model: model, store: scratch.store)

        try registry.set(.bool(false), forKey: "premium")
        try registry.set(.date(Date(timeIntervalSince1970: 0)), forKey: "trial-end")
        try registry.set(.null, forKey: "premium")
        try registry.set(.null, forKey: "trial-end")

        #expect(model.premiumOverride == nil)
        #expect(model.trialEndOverride == nil)
    }

    @Test func decimalControlsAcceptWholeNumbers() throws {
        let model = DebugModel()
        let registry = makeRegistry(model: model, store: scratch.store)

        try registry.set(.int(2), forKey: "discount")

        #expect(model.discount == 2)
        let discount = try registry.value(forKey: "discount")
        #expect(discount == .double(2))
    }

    @Test func invalidValuesThrowAndChangeNothing() {
        let model = DebugModel()
        let registry = makeRegistry(model: model, store: scratch.store)

        #expect(throws: SaveStateError.invalidValue(key: "onboarding", value: .int(1), kind: .toggle)) {
            try registry.set(.int(1), forKey: "onboarding")
        }
        #expect(throws: SaveStateError.invalidValue(
            key: "env",
            value: .string("qa"),
            kind: .choice(options: ["staging", "production"])
        )) {
            try registry.set(.string("qa"), forKey: "env")
        }
        #expect(throws: SaveStateError.invalidValue(key: "greeting", value: .null, kind: .text)) {
            try registry.set(.null, forKey: "greeting")
        }
        #expect(throws: SaveStateError.invalidValue(key: "discount", value: .double(.infinity), kind: .decimal)) {
            try registry.set(.double(.infinity), forKey: "discount")
        }

        #expect(!model.showsOnboarding)
        #expect(model.environment == .production)
        #expect(model.greeting == "Hello")
        #expect(model.discount == 0)
    }

    @Test func batchSetIsAllOrNothing() throws {
        let model = DebugModel()
        let registry = makeRegistry(model: model, store: scratch.store)

        #expect(throws: SaveStateError.invalidValue(key: "launches", value: .string("many"), kind: .integer)) {
            try registry.set(["onboarding": .bool(true), "launches": .string("many")])
        }
        #expect(throws: SaveStateError.unknownControl("nope")) {
            try registry.set(["onboarding": .bool(true), "nope": .int(1)])
        }
        #expect(!model.showsOnboarding)
        #expect(model.launchCount == 0)

        try registry.set(["onboarding": .bool(true), "launches": .int(4)])

        #expect(model.showsOnboarding)
        #expect(model.launchCount == 4)
    }

    @Test func batchSetReportsTheFirstBadEntryInDeclarationOrder() {
        let registry = makeRegistry(model: DebugModel(), store: scratch.store)

        #expect(throws: SaveStateError.invalidValue(key: "onboarding", value: .int(1), kind: .toggle)) {
            try registry.set(["discount": .string("x"), "launches": .null, "onboarding": .int(1)])
        }
        #expect(throws: SaveStateError.unknownControl("a")) {
            try registry.set(["z": .null, "a": .null, "onboarding": .int(1)])
        }
    }

    @Test func unknownKeysThrow() async {
        let registry = makeRegistry(model: DebugModel(), store: scratch.store)

        #expect(throws: SaveStateError.unknownControl("nope")) {
            try registry.set(.bool(true), forKey: "nope")
        }
        #expect(throws: SaveStateError.unknownControl("nope")) {
            try registry.value(forKey: "nope")
        }
        #expect(throws: SaveStateError.unknownControl("nope")) {
            try registry.reset("nope")
        }
        await #expect(throws: SaveStateError.unknownAction("nope")) {
            try await registry.runAction("nope")
        }
        await #expect(throws: SaveStateError.unknownScenario("nope")) {
            try await registry.applyScenario("nope")
        }
    }

    @Test func effectiveValueFallsBackToTheRealValue() throws {
        let model = DebugModel()
        model.isEntitled = true
        let registry = makeRegistry(model: model, store: scratch.store)

        let real = try registry.effectiveValue(forKey: "premium")
        #expect(real == .bool(true))

        try registry.set(.bool(false), forKey: "premium")
        let overridden = try registry.effectiveValue(forKey: "premium")
        #expect(overridden == .bool(false))

        let noReal = try registry.effectiveValue(forKey: "trial-end")
        #expect(noReal == .null)
    }

    // MARK: - Resetting

    @Test func resetRestoresDeclaredValues() throws {
        let store = scratch.store
        let model = DebugModel()
        let registry = makeRegistry(model: model, store: store)
        #expect(registry.changedKeys.isEmpty)

        try registry.set(.bool(true), forKey: "onboarding", persist: true)
        try registry.set(.string("Hi"), forKey: "greeting")
        try registry.set(.string("staging"), forKey: "env")
        #expect(registry.changedKeys == ["onboarding", "env", "greeting"])

        try registry.reset("onboarding")
        #expect(!model.showsOnboarding)
        #expect(store.value(forKey: "onboarding", in: .persisted) == nil)
        #expect(registry.changedKeys == ["env", "greeting"])

        try registry.resetAll()
        #expect(model.greeting == "Hello")
        #expect(model.environment == .production)
        #expect(store.value(forKey: "env", in: .nextLaunch) == nil)
        #expect(registry.changedKeys.isEmpty)
    }

    // MARK: - Relaunching

    @Test func persistedValuesSurviveRelaunchAndSessionValuesDont() throws {
        let store = scratch.store
        let first = makeRegistry(model: DebugModel(), store: store)
        try first.set(.bool(true), forKey: "onboarding", persist: true)
        try first.set(.string("Hi"), forKey: "greeting")

        let model = DebugModel()
        let relaunched = makeRegistry(model: model, store: store)

        #expect(model.showsOnboarding)
        #expect(model.greeting == "Hello")
        #expect(relaunched.changedKeys == ["onboarding"])
    }

    @Test func sessionValuesOnRelaunchControlsApplyAtTheNextLaunchOnly() throws {
        let store = scratch.store
        let first = makeRegistry(model: DebugModel(), store: store)
        try first.set(.string("staging"), forKey: "env")

        let nextLaunch = DebugModel()
        _ = makeRegistry(model: nextLaunch, store: store)
        #expect(nextLaunch.environment == .staging)

        let launchAfter = DebugModel()
        _ = makeRegistry(model: launchAfter, store: store)
        #expect(launchAfter.environment == .production)
    }

    @Test func aNextLaunchValueTakesPriorityOnceOverAPersistedOne() throws {
        let store = scratch.store
        let first = makeRegistry(model: DebugModel(), store: store)
        try first.set(.string("staging"), forKey: "env", persist: true)
        try first.set(.string("production"), forKey: "env")

        let nextLaunch = DebugModel()
        _ = makeRegistry(model: nextLaunch, store: store)
        #expect(nextLaunch.environment == .production)

        let launchAfter = DebugModel()
        _ = makeRegistry(model: launchAfter, store: store)
        #expect(launchAfter.environment == .staging)
    }

    @Test func describeReportsWhatTheNextLaunchRestores() throws {
        let registry = makeRegistry(model: DebugModel(), store: scratch.store)

        try registry.set(.bool(true), forKey: "onboarding", persist: true)
        try registry.set(.string("Hi"), forKey: "greeting")
        try registry.set(.string("staging"), forKey: "env")

        let controls = registry.describe().controls
        #expect(controls.first(where: { $0.key == "onboarding" })?.nextLaunchValue == .bool(true))
        #expect(controls.first(where: { $0.key == "greeting" })?.nextLaunchValue == nil)
        #expect(controls.first(where: { $0.key == "env" })?.nextLaunchValue == .string("staging"))
    }

    @Test func restoreDropsValuesTheControlNoLongerAccepts() {
        let store = scratch.store
        store.save(.string("qa"), forKey: "env", in: .persisted)
        store.save(.int(1), forKey: "onboarding", in: .persisted)
        store.save(.string("qa"), forKey: "env", in: .nextLaunch)

        let model = DebugModel()
        _ = makeRegistry(model: model, store: store)

        #expect(model.environment == .production)
        #expect(!model.showsOnboarding)
        #expect(store.value(forKey: "env", in: .persisted) == nil)
        #expect(store.value(forKey: "env", in: .nextLaunch) == nil)
        #expect(store.value(forKey: "onboarding", in: .persisted) == nil)
    }

    @Test func storeDropsUndecodableData() throws {
        let defaults = try #require(UserDefaults(suiteName: scratch.suiteName))
        let store = scratch.store
        let defaultsKey = store.defaultsKey(forKey: "onboarding", in: .persisted)
        defaults.set(Data("not json".utf8), forKey: defaultsKey)

        #expect(store.value(forKey: "onboarding", in: .persisted) == nil)
        #expect(defaults.data(forKey: defaultsKey) == nil)
    }

    // MARK: - Actions and scenarios

    @Test func runActionPerformsTheAction() async throws {
        let model = DebugModel()
        let registry = makeRegistry(model: model, store: scratch.store)

        try await registry.runAction("count")
        try await registry.runAction("count")

        #expect(model.actionRuns == 2)
    }

    @Test func destructiveActionsNeedPermission() async throws {
        let model = DebugModel()
        model.actionRuns = 5
        let registry = makeRegistry(model: model, store: scratch.store)

        await #expect(throws: SaveStateError.destructiveActionNotAllowed("erase")) {
            try await registry.runAction("erase")
        }
        #expect(model.actionRuns == 5)

        try await registry.runAction("erase", allowDestructive: true)
        #expect(model.actionRuns == 0)
    }

    @Test func applyScenarioSetsUpItsState() async throws {
        let model = DebugModel()
        model.isEntitled = true
        let registry = makeRegistry(model: model, store: scratch.store)

        try await registry.applyScenario("expired-trial")

        #expect(model.premiumOverride == false)
        #expect(model.trialEndOverride == Date(timeIntervalSince1970: 1_800_000_000))
        let premium = try registry.effectiveValue(forKey: "premium")
        #expect(premium == .bool(false))
        #expect(registry.changedKeys == ["premium", "trial-end"])
    }

    @Test func scenarioErrorsReachTheCaller() async {
        let registry = makeRegistry(model: DebugModel(), store: scratch.store)

        await #expect(throws: TestError.failed) {
            try await registry.applyScenario("broken")
        }
    }

    // MARK: - Observing and gating

    @Test func changesThroughTheRegistryNotifyObservers() throws {
        let registry = makeRegistry(model: DebugModel(), store: scratch.store)
        let changed = ChangeFlag()

        withObservationTracking {
            _ = registry.describe()
        } onChange: {
            changed.raise()
        }
        #expect(!changed.isRaised)

        try registry.set(.bool(true), forKey: "onboarding")

        #expect(changed.isRaised)
    }

    @Test func disabledRegistryRejectsChangesAndIgnoresStoredValues() async {
        let store = scratch.store
        store.save(.bool(true), forKey: "onboarding", in: .persisted)
        let model = DebugModel()

        let registry = makeRegistry(model: model, store: store, isEnabled: false)

        #expect(!registry.isEnabled)
        #expect(!model.showsOnboarding)
        #expect(registry.describe().controls.count == 7)
        #expect(throws: SaveStateError.disabled) {
            try registry.set(.bool(true), forKey: "onboarding")
        }
        #expect(throws: SaveStateError.disabled) {
            try registry.reset("onboarding")
        }
        #expect(throws: SaveStateError.disabled) {
            try registry.resetAll()
        }
        await #expect(throws: SaveStateError.disabled) {
            try await registry.runAction("count")
        }
        await #expect(throws: SaveStateError.disabled) {
            try await registry.applyScenario("expired-trial")
        }
        #expect(!model.showsOnboarding)
        #expect(model.actionRuns == 0)
        #expect(store.value(forKey: "onboarding", in: .persisted) == .bool(true))
    }

    @Test func aPersistedValueThatWouldReturnCountsAsChanged() throws {
        let model = DebugModel()
        let registry = makeRegistry(model: model, store: scratch.store)

        try registry.set(.string("staging"), forKey: "env", persist: true)
        try registry.set(.string("production"), forKey: "env")

        #expect(registry.changedKeys == ["env"])
        let control = try #require(registry.describe().controls.first { $0.key == "env" })
        #expect(control.isChanged)

        try registry.reset("env")

        #expect(registry.changedKeys.isEmpty)
    }

    @Test func aDiscardingStoreLeavesTheBackingStoreAlone() throws {
        let store = scratch.store
        let discarding = OverrideStore(suiteName: scratch.suiteName, isDiscarding: true)
        store.save(.bool(true), forKey: "seeded", in: .persisted)
        let key = store.defaultsKey(forKey: "onboarding", in: .persisted)
        let defaults = try #require(UserDefaults(suiteName: scratch.suiteName))

        let model = DebugModel()
        let registry = SaveStateRegistry(model: model, store: discarding, isEnabled: true) { r in
            r.toggle("Show onboarding", key: "onboarding", \.showsOnboarding)
            r.toggle("Seeded", key: "seeded", \.isEntitled)
        }
        #expect(!model.isEntitled, "Nothing is restored from a discarding store")

        try registry.set(.bool(true), forKey: "onboarding", persist: true)
        #expect(defaults.object(forKey: key) == nil, "Writes aren't kept")
        #expect(registry.describe().controls.first { $0.key == "onboarding" }?.nextLaunchValue == nil)

        try registry.reset("seeded")
        #expect(store.value(forKey: "seeded", in: .persisted) == .bool(true), "Resets remove nothing")
    }
}
