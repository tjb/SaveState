import Foundation
import Observation
import Synchronization
import Testing
@testable import SaveState

/// A way SwiftUI can read the registry in a view's body.
enum RegistryRead: CaseIterable, Sendable {
    case describe
    case value
    case effectiveValue
    case changedKeys

    @MainActor
    func perform(on registry: SaveStateRegistry) {
        switch self {
        case .describe:
            _ = registry.describe()
        case .value:
            _ = try? registry.value(forKey: "greeting")
        case .effectiveValue:
            _ = try? registry.effectiveValue(forKey: "greeting")
        case .changedKeys:
            _ = registry.changedKeys
        }
    }
}

/// A call that changes state through the registry, including calls that throw
/// after work has started and may have changed the model.
enum RegistryChange: CaseIterable, Sendable {
    case setOne
    case setBatch
    case reset
    case resetAll
    case runAction
    case runFailingAction
    case applyScenario
    case applyFailingScenario

    @MainActor
    func perform(on registry: SaveStateRegistry) async {
        switch self {
        case .setOne:
            try? registry.set(.string("Hi"), forKey: "greeting")
        case .setBatch:
            try? registry.set(["greeting": .string("Hi")])
        case .reset:
            try? registry.reset("greeting")
        case .resetAll:
            try? registry.resetAll()
        case .runAction:
            try? await registry.runAction("work")
        case .runFailingAction:
            try? await registry.runAction("fail")
        case .applyScenario:
            try? await registry.applyScenario("work")
        case .applyFailingScenario:
            try? await registry.applyScenario("fail")
        }
    }
}

/// A call the registry refuses before changing anything.
enum RegistryRefusal: CaseIterable, Sendable {
    case badValue
    case unknownControl
    case unknownReset
    case unknownAction
    case destructiveAction
    case unknownScenario

    @MainActor
    func perform(on registry: SaveStateRegistry) async {
        switch self {
        case .badValue:
            try? registry.set(.int(1), forKey: "greeting")
        case .unknownControl:
            try? registry.set(.int(1), forKey: "nope")
        case .unknownReset:
            try? registry.reset("nope")
        case .unknownAction:
            try? await registry.runAction("nope")
        case .destructiveAction:
            try? await registry.runAction("erase")
        case .unknownScenario:
            try? await registry.applyScenario("nope")
        }
    }
}

@Suite("Observation")
@MainActor
struct RegistryObservationTests {
    private let scratch = ScratchDefaults()

    private func makeObservedRegistry(model: DebugModel, isEnabled: Bool = true) -> SaveStateRegistry {
        SaveStateRegistry(model: model, store: scratch.store, isEnabled: isEnabled) { r in
            r.text("Greeting", key: "greeting", \.greeting)
            r.action("Work", key: "work") {
                model.actionRuns += 1
            }
            r.action("Fail", key: "fail") {
                throw TestError.failed
            }
            r.action("Erase", key: "erase", destructive: true) {
                model.actionRuns = 0
            }
            r.scenario("Work", key: "work") { state in
                state.greeting = "Scenario"
            }
            r.scenario("Fail", key: "fail") { _ in
                throw TestError.failed
            }
        }
    }

    @Test(arguments: RegistryRead.allCases, RegistryChange.allCases)
    func everyChangeNotifiesEveryRead(read: RegistryRead, change: RegistryChange) async {
        let registry = makeObservedRegistry(model: DebugModel())
        let changed = ChangeFlag()
        withObservationTracking {
            read.perform(on: registry)
        } onChange: {
            changed.raise()
        }

        await change.perform(on: registry)

        #expect(changed.isRaised)
    }

    @Test(arguments: RegistryRefusal.allCases)
    func aRefusedCallDoesNotNotify(refusal: RegistryRefusal) async {
        let registry = makeObservedRegistry(model: DebugModel())
        let changed = ChangeFlag()
        withObservationTracking {
            _ = registry.describe()
        } onChange: {
            changed.raise()
        }

        await refusal.perform(on: registry)

        #expect(!changed.isRaised)
    }

    @Test(arguments: RegistryChange.allCases)
    func aDisabledRegistryDoesNotNotify(change: RegistryChange) async {
        let registry = makeObservedRegistry(model: DebugModel(), isEnabled: false)
        let changed = ChangeFlag()
        withObservationTracking {
            _ = registry.describe()
        } onChange: {
            changed.raise()
        }

        await change.perform(on: registry)

        #expect(!changed.isRaised)
    }

    @Test func theNotificationComesAfterASetIsWritten() throws {
        let model = DebugModel()
        let registry = makeObservedRegistry(model: model)
        let seen = Mutex<String?>(nil)
        withObservationTracking {
            _ = registry.describe()
        } onChange: {
            let greeting = MainActor.assumeIsolated { model.greeting }
            seen.withLock { $0 = greeting }
        }

        try registry.set(.string("Hi"), forKey: "greeting")

        #expect(seen.withLock { $0 } == "Hi")
    }

    @Test func theNotificationComesAfterAResetIsWritten() throws {
        let model = DebugModel()
        let registry = makeObservedRegistry(model: model)
        try registry.set(.string("Hi"), forKey: "greeting")
        let seen = Mutex<String?>(nil)
        withObservationTracking {
            _ = registry.describe()
        } onChange: {
            let greeting = MainActor.assumeIsolated { model.greeting }
            seen.withLock { $0 = greeting }
        }

        try registry.reset("greeting")

        #expect(seen.withLock { $0 } == "Hello")
    }

    @Test func theNotificationComesAfterAResetAllIsWritten() throws {
        let model = DebugModel()
        let registry = makeObservedRegistry(model: model)
        try registry.set(.string("Hi"), forKey: "greeting")
        let seen = Mutex<String?>(nil)
        withObservationTracking {
            _ = registry.describe()
        } onChange: {
            let greeting = MainActor.assumeIsolated { model.greeting }
            seen.withLock { $0 = greeting }
        }

        try registry.resetAll()

        #expect(seen.withLock { $0 } == "Hello")
    }

    @Test func theNotificationComesAfterAnActionFinishes() async throws {
        let model = DebugModel()
        let registry = makeObservedRegistry(model: model)
        let seen = Mutex<Int?>(nil)
        withObservationTracking {
            _ = registry.describe()
        } onChange: {
            let runs = MainActor.assumeIsolated { model.actionRuns }
            seen.withLock { $0 = runs }
        }

        try await registry.runAction("work")

        #expect(seen.withLock { $0 } == 1)
    }

    @Test func theNotificationComesAfterAScenarioFinishes() async throws {
        let model = DebugModel()
        let registry = makeObservedRegistry(model: model)
        let seen = Mutex<String?>(nil)
        withObservationTracking {
            _ = registry.describe()
        } onChange: {
            let greeting = MainActor.assumeIsolated { model.greeting }
            seen.withLock { $0 = greeting }
        }

        try await registry.applyScenario("work")

        #expect(seen.withLock { $0 } == "Scenario")
    }
}
