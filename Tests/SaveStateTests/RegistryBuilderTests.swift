import Foundation
import Testing
@testable import SaveState

@Suite("RegistryBuilder")
@MainActor
struct RegistryBuilderTests {
    private let scratch = ScratchDefaults()

    // MARK: - Sections

    @Test func actionsAndScenariosTakeTheEnclosingSection() {
        let builder = RegistryBuilder(model: DebugModel())

        builder.section("Outer") {
            builder.section("Inner") {
                builder.action("A", key: "inner-action") {}
                builder.scenario("S", key: "inner-scenario") { _ in }
            }
            builder.action("B", key: "outer-action") {}
            builder.scenario("T", key: "outer-scenario") { _ in }
        }
        builder.action("C", key: "bare-action") {}
        builder.scenario("U", key: "bare-scenario") { _ in }

        #expect(builder.actions.map(\.section) == ["Inner", "Outer", nil])
        #expect(builder.scenarios.map(\.section) == ["Inner", "Outer", nil])
    }

    @Test func aSectionRestoresAfterASiblingEnds() {
        let builder = RegistryBuilder(model: DebugModel())

        builder.section("Outer") {
            builder.section("First") {}
            builder.toggle("A", key: "after-first", \.showsOnboarding)
            builder.section("Second") {
                builder.text("B", key: "in-second", \.greeting)
            }
            builder.integer("C", key: "after-second", \.launchCount)
        }

        #expect(builder.controls.map(\.section) == ["Outer", "Second", "Outer"])
    }

    // MARK: - Declaring

    @Test func relaunchIsOffUnlessRequested() {
        let builder = RegistryBuilder(model: DebugModel())

        builder.toggle("T", key: "toggle", \.showsOnboarding)
        builder.triState("S", key: "tri", \.premiumOverride)
        builder.choice("C", key: "choice", \.environment)
        builder.text("X", key: "text", \.greeting)
        builder.integer("I", key: "int", \.launchCount)
        builder.decimal("D", key: "decimal", \.discount)
        builder.date("A", key: "date", \.trialEndOverride)

        #expect(builder.controls.count == 7)
        #expect(builder.controls.allSatisfy { !$0.requiresRelaunch })
    }

    @Test func everyControlTypeCanRequireARelaunch() {
        let builder = RegistryBuilder(model: DebugModel())

        builder.toggle("T", key: "toggle", \.showsOnboarding, requiresRelaunch: true)
        builder.triState("S", key: "tri", \.premiumOverride, requiresRelaunch: true)
        builder.choice("C", key: "choice", \.environment, requiresRelaunch: true)
        builder.text("X", key: "text", \.greeting, requiresRelaunch: true)
        builder.integer("I", key: "int", \.launchCount, requiresRelaunch: true)
        builder.decimal("D", key: "decimal", \.discount, requiresRelaunch: true)
        builder.date("A", key: "date", \.trialEndOverride, requiresRelaunch: true)

        #expect(builder.controls.count == 7)
        #expect(builder.controls.allSatisfy { $0.requiresRelaunch })
    }

    @Test func defaultsAreTheModelsValuesAtDeclaration() {
        let model = DebugModel()
        model.greeting = "Declared"
        model.launchCount = 9
        let builder = RegistryBuilder(model: model)

        builder.text("X", key: "text", \.greeting)
        builder.integer("I", key: "int", \.launchCount)
        model.greeting = "Later"

        #expect(builder.controls.map(\.defaultValue) == [.string("Declared"), .int(9)])
    }

    @Test func aChoiceOffersEveryCaseInOrder() {
        let builder = RegistryBuilder(model: DebugModel())

        builder.choice("C", key: "choice", \.environment)

        #expect(builder.controls.first?.kind == .choice(options: ["staging", "production"]))
    }

    /// Only inspects metadata, so it doesn't touch the process-wide clock.
    @Test func aClockControlDefaultsItsKeyAndLabel() throws {
        let builder = RegistryBuilder(model: DebugModel())

        builder.clock()

        let control = try #require(builder.controls.first)
        #expect(control.key == "clock")
        #expect(control.label == "Clock")
    }

    @Test func aClockControlAcceptsACustomKeyAndLabel() throws {
        let builder = RegistryBuilder(model: DebugModel())

        builder.clock("Time", key: "time")

        let control = try #require(builder.controls.first)
        #expect(control.key == "time")
        #expect(control.label == "Time")
    }

    @Test func actionsAreNotDestructiveByDefault() {
        let builder = RegistryBuilder(model: DebugModel())

        builder.action("A", key: "plain") {}

        #expect(builder.actions.first?.isDestructive == false)
    }

    @Test func keysOnlyHaveToBeUniqueWithinTheirCategory() {
        let builder = RegistryBuilder(model: DebugModel())

        builder.toggle("T", key: "shared", \.showsOnboarding)
        builder.action("A", key: "shared") {}
        builder.scenario("S", key: "shared") { _ in }

        #expect(builder.controls.map(\.key) == ["shared"])
        #expect(builder.actions.map(\.key) == ["shared"])
        #expect(builder.scenarios.map(\.key) == ["shared"])
    }

    // MARK: - Real values

    @Test func aTriStateWithoutARealValueReportsNull() throws {
        let registry = SaveStateRegistry(model: DebugModel(), store: scratch.store, isEnabled: true) { r in
            r.triState("S", key: "tri", \.premiumOverride)
        }

        let control = try #require(registry.describe().controls.first)
        #expect(control.realValue == nil)
        #expect(control.effectiveValue == .null)
    }

    @Test func aDateFallsBackToItsRealValue() throws {
        let real = Date(timeIntervalSince1970: 1_700_000_000)
        let registry = SaveStateRegistry(model: DebugModel(), store: scratch.store, isEnabled: true) { r in
            r.date("A", key: "date", \.trialEndOverride, real: { real })
        }

        let control = try #require(registry.describe().controls.first)
        #expect(control.realValue == .date(real))
        #expect(control.effectiveValue == .date(real))
    }

    @Test func aDateOverrideBeatsItsRealValue() throws {
        let override = Date(timeIntervalSince1970: 1_800_000_000)
        let registry = SaveStateRegistry(model: DebugModel(), store: scratch.store, isEnabled: true) { r in
            r.date("A", key: "date", \.trialEndOverride, real: { Date(timeIntervalSince1970: 0) })
        }

        try registry.set(.date(override), forKey: "date")

        let effective = try registry.effectiveValue(forKey: "date")
        #expect(effective == .date(override))
    }

    @Test func theRealValueIsReadAtEachDescribe() throws {
        let model = DebugModel()
        let registry = SaveStateRegistry(model: model, store: scratch.store, isEnabled: true) { r in
            r.triState("S", key: "tri", \.premiumOverride, real: { model.isEntitled })
        }

        model.isEntitled = true

        #expect(registry.describe().controls.first?.effectiveValue == .bool(true))
    }

    @Test func aFalseOverrideIsNotTreatedAsNoOverride() throws {
        let model = DebugModel()
        model.isEntitled = true
        let registry = SaveStateRegistry(model: model, store: scratch.store, isEnabled: true) { r in
            r.triState("S", key: "tri", \.premiumOverride, real: { model.isEntitled })
        }

        try registry.set(.bool(false), forKey: "tri")

        let effective = try registry.effectiveValue(forKey: "tri")
        #expect(effective == .bool(false))
    }

    // MARK: - Lifetime

    @Test func theRegistryKeepsItsModelAlive() throws {
        let registry = SaveStateRegistry(model: DebugModel(), store: scratch.store, isEnabled: true) { r in
            r.text("X", key: "text", \.greeting)
        }

        try registry.set(.string("Still here"), forKey: "text")

        let value = try registry.value(forKey: "text")
        #expect(value == .string("Still here"))
    }

    @Test func aScenarioReceivesTheRegistrysModel() async throws {
        let model = DebugModel()
        let received = ModelBox()
        let registry = SaveStateRegistry(model: model, store: scratch.store, isEnabled: true) { r in
            r.scenario("S", key: "capture") { state in
                received.model = state
            }
        }

        try await registry.applyScenario("capture")

        #expect(received.model === model)
    }
}

@MainActor
private final class ModelBox {
    var model: DebugModel?
}

@Suite("Build")
@MainActor
struct SaveStateBuildTests {
    @Test func isDebugMatchesTheBuildConfiguration() {
        #if DEBUG
        #expect(SaveStateBuild.isDebug)
        #else
        #expect(!SaveStateBuild.isDebug)
        #endif
    }

    @Test func aRegistryIsEnabledByDefaultOnlyInDebug() {
        let scratch = ScratchDefaults()

        let registry = SaveStateRegistry(model: DebugModel(), store: scratch.store) { _ in }

        #expect(registry.isEnabled == SaveStateBuild.isDebug)
    }
}

// Duplicate keys hit `assertionFailure`, which stops the process in Debug and
// does nothing in Release, so these need Debug and a child process. Exit tests
// aren't available on iOS.
#if DEBUG && os(macOS)
@Suite("Duplicate keys")
struct DuplicateKeyTests {
    @Test func aDuplicateControlKeyStopsADebugBuild() async throws {
        let result = await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
            await MainActor.run {
                let builder = RegistryBuilder(model: DebugModel())
                builder.toggle("A", key: "same", \.showsOnboarding)
                builder.text("B", key: "same", \.greeting)
            }
        }

        let output = String(bytes: try #require(result).standardErrorContent, encoding: .utf8) ?? ""
        #expect(output.contains(#"duplicate control key "same""#))
    }

    @Test func aDuplicateActionKeyStopsADebugBuild() async throws {
        let result = await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
            await MainActor.run {
                let builder = RegistryBuilder(model: DebugModel())
                builder.action("A", key: "same") {}
                builder.action("B", key: "same") {}
            }
        }

        let output = String(bytes: try #require(result).standardErrorContent, encoding: .utf8) ?? ""
        #expect(output.contains(#"duplicate action key "same""#))
    }

    @Test func aDuplicateScenarioKeyStopsADebugBuild() async throws {
        let result = await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
            await MainActor.run {
                let builder = RegistryBuilder(model: DebugModel())
                builder.scenario("A", key: "same") { _ in }
                builder.scenario("B", key: "same") { _ in }
            }
        }

        let output = String(bytes: try #require(result).standardErrorContent, encoding: .utf8) ?? ""
        #expect(output.contains(#"duplicate scenario key "same""#))
    }

    @Test func distinctKeysDoNotStopTheProcess() async {
        await #expect(processExitsWith: .success) {
            await MainActor.run {
                let builder = RegistryBuilder(model: DebugModel())
                builder.toggle("A", key: "one", \.showsOnboarding)
                builder.text("B", key: "two", \.greeting)
                builder.action("C", key: "three") {}
                builder.action("D", key: "four") {}
                builder.scenario("E", key: "five") { _ in }
                builder.scenario("F", key: "six") { _ in }
            }
        }
    }
}
#elseif !DEBUG
// Reachable only with `swift test -c release -Xswiftc -enable-testing`.
@Suite("Duplicate keys")
@MainActor
struct DuplicateKeyTests {
    @Test func theFirstDeclarationWinsInARelease() {
        let builder = RegistryBuilder(model: DebugModel())

        builder.toggle("First", key: "same", \.showsOnboarding)
        builder.text("Second", key: "same", \.greeting)
        builder.action("First", key: "same") {}
        builder.action("Second", key: "same") {}
        builder.scenario("First", key: "same") { _ in }
        builder.scenario("Second", key: "same") { _ in }

        #expect(builder.controls.map(\.label) == ["First"])
        #expect(builder.actions.map(\.label) == ["First"])
        #expect(builder.scenarios.map(\.label) == ["First"])
    }
}
#endif
