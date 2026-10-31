import Foundation
import Testing
@testable import SaveState

@Suite("Registry")
@MainActor
struct RegistryTests {
    @Test func describeReportsEveryDeclarationInOrder() throws {
        let model = DebugModel()
        model.isEntitled = true
        let description = makeRegistry(model: model).describe()

        #expect(description.controls.map(\.key) == [
            "onboarding", "premium", "trial-end", "env", "greeting", "launches", "discount",
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

        let environment = try #require(description.controls.first(where: { $0.key == "env" }))
        #expect(environment.kind == .choice(options: ["staging", "production"]))
        #expect(environment.section == nil)
        #expect(environment.value == .string("production"))
        #expect(environment.realValue == nil)
        #expect(environment.requiresRelaunch)
    }

    @Test func sectionsNestAndRestore() {
        let registry = SaveStateRegistry(model: DebugModel(), store: makeStore(), isEnabled: true) { r in
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

    @Test func setWritesTheModel() throws {
        let model = DebugModel()
        let registry = makeRegistry(model: model)
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
        let registry = makeRegistry(model: model)

        try registry.set(.bool(false), forKey: "premium")
        try registry.set(.date(Date(timeIntervalSince1970: 0)), forKey: "trial-end")
        try registry.set(.null, forKey: "premium")
        try registry.set(.null, forKey: "trial-end")

        #expect(model.premiumOverride == nil)
        #expect(model.trialEndOverride == nil)
    }

    @Test func decimalControlsAcceptWholeNumbers() throws {
        let model = DebugModel()
        let registry = makeRegistry(model: model)

        try registry.set(.int(2), forKey: "discount")

        #expect(model.discount == 2)
        let discount = try registry.value(forKey: "discount")
        #expect(discount == .double(2))
    }

    @Test func invalidValuesThrowAndChangeNothing() {
        let model = DebugModel()
        let registry = makeRegistry(model: model)

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

        #expect(!model.showsOnboarding)
        #expect(model.environment == .production)
        #expect(model.greeting == "Hello")
    }

    @Test func batchSetIsAllOrNothing() throws {
        let model = DebugModel()
        let registry = makeRegistry(model: model)

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

    @Test func unknownKeysThrow() async {
        let registry = makeRegistry(model: DebugModel())

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
        let registry = makeRegistry(model: model)

        let real = try registry.effectiveValue(forKey: "premium")
        #expect(real == .bool(true))

        try registry.set(.bool(false), forKey: "premium")
        let overridden = try registry.effectiveValue(forKey: "premium")
        #expect(overridden == .bool(false))

        let noReal = try registry.effectiveValue(forKey: "trial-end")
        #expect(noReal == .null)
    }

    @Test func resetRestoresDeclaredValues() throws {
        let store = makeStore()
        let model = DebugModel()
        let registry = makeRegistry(model: model, store: store)
        #expect(registry.changedKeys.isEmpty)

        try registry.set(.bool(true), forKey: "onboarding", persist: true)
        try registry.set(.string("Hi"), forKey: "greeting")
        #expect(registry.changedKeys == ["onboarding", "greeting"])

        try registry.reset("onboarding")
        #expect(!model.showsOnboarding)
        #expect(store.load(forKey: "onboarding") == nil)
        #expect(registry.changedKeys == ["greeting"])

        try registry.resetAll()
        #expect(model.greeting == "Hello")
        #expect(registry.changedKeys.isEmpty)
    }

    @Test func onlyPersistedValuesSurviveRelaunch() throws {
        let store = makeStore()
        let first = makeRegistry(model: DebugModel(), store: store)
        try first.set(.bool(true), forKey: "onboarding", persist: true)
        try first.set(.string("staging"), forKey: "env")

        let model = DebugModel()
        let relaunched = makeRegistry(model: model, store: store)

        #expect(model.showsOnboarding)
        #expect(model.environment == .production)
        #expect(relaunched.changedKeys == ["onboarding"])
    }

    @Test func restoreDropsValuesTheControlNoLongerAccepts() {
        let store = makeStore()
        store.save(.string("qa"), forKey: "env")
        store.save(.int(1), forKey: "onboarding")

        let model = DebugModel()
        _ = makeRegistry(model: model, store: store)

        #expect(model.environment == .production)
        #expect(!model.showsOnboarding)
        #expect(store.load(forKey: "env") == nil)
        #expect(store.load(forKey: "onboarding") == nil)
    }

    @Test func storeDropsUndecodableData() throws {
        let suiteName = "SaveStateTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.set(Data("not json".utf8), forKey: "savestate.onboarding")

        let store = OverrideStore(suiteName: suiteName)

        #expect(store.load(forKey: "onboarding") == nil)
        #expect(defaults.data(forKey: "savestate.onboarding") == nil)
    }

    @Test func runActionPerformsTheAction() async throws {
        let model = DebugModel()
        let registry = makeRegistry(model: model)

        try await registry.runAction("count")
        try await registry.runAction("count")
        #expect(model.actionRuns == 2)

        try await registry.runAction("erase")
        #expect(model.actionRuns == 0)
    }

    @Test func applyScenarioSetsUpItsState() async throws {
        let model = DebugModel()
        model.isEntitled = true
        let registry = makeRegistry(model: model)

        try await registry.applyScenario("expired-trial")

        #expect(model.premiumOverride == false)
        #expect(model.trialEndOverride == Date(timeIntervalSince1970: 1_800_000_000))
        let premium = try registry.effectiveValue(forKey: "premium")
        #expect(premium == .bool(false))
        #expect(registry.changedKeys == ["premium", "trial-end"])
    }

    @Test func scenarioErrorsReachTheCaller() async {
        let registry = makeRegistry(model: DebugModel())

        await #expect(throws: TestError.failed) {
            try await registry.applyScenario("broken")
        }
    }

    @Test func disabledRegistryRejectsChangesAndIgnoresPersistedValues() async {
        let store = makeStore()
        store.save(.bool(true), forKey: "onboarding")
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
        #expect(store.load(forKey: "onboarding") == .bool(true))
    }
}
