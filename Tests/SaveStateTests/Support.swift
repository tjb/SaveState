import Foundation
import Synchronization
@testable import SaveState

enum ServerEnvironment: String, CaseIterable, Sendable {
    case staging
    case production
}

enum TestError: Error {
    case failed
}

@MainActor
final class DebugModel {
    var showsOnboarding = false
    var premiumOverride: Bool?
    var trialEndOverride: Date?
    var environment = ServerEnvironment.production
    var greeting = "Hello"
    var launchCount = 0
    var discount = 0.0
    var isEntitled = false
    var actionRuns = 0
}

/// A `UserDefaults` suite for one test, removed when the test's suite instance
/// goes away. Every registry in a test that shares it sees the same stored
/// values, the way relaunches of one app do.
final class ScratchDefaults: Sendable {
    let suiteName = "SaveStateTests.\(UUID().uuidString)"

    var store: OverrideStore {
        OverrideStore(suiteName: suiteName)
    }

    deinit {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
    }
}

/// Records whether an observation's change handler ran.
final class ChangeFlag: Sendable {
    private let raised = Mutex(false)

    var isRaised: Bool {
        raised.withLock { $0 }
    }

    func raise() {
        raised.withLock { $0 = true }
    }
}

@MainActor
func makeRegistry(
    model: DebugModel,
    store: OverrideStore,
    isEnabled: Bool = true
) -> SaveStateRegistry {
    SaveStateRegistry(model: model, store: store, isEnabled: isEnabled) { r in
        r.section("Onboarding") {
            r.toggle("Show onboarding", key: "onboarding", \.showsOnboarding)
        }
        r.section("Purchases") {
            r.triState("Premium", key: "premium", \.premiumOverride, real: { model.isEntitled })
            r.date("Trial ends", key: "trial-end", \.trialEndOverride)
            r.scenario(
                "Expired trial",
                key: "expired-trial",
                summary: "The trial ended, so the paywall shows."
            ) { state in
                state.premiumOverride = false
                state.trialEndOverride = Date(timeIntervalSince1970: 1_800_000_000)
            }
        }
        r.choice("Environment", key: "env", \.environment, requiresRelaunch: true)
        r.text("Greeting", key: "greeting", \.greeting)
        r.integer("Launch count", key: "launches", \.launchCount)
        r.decimal("Discount", key: "discount", \.discount)
        r.action("Count", key: "count") {
            model.actionRuns += 1
        }
        r.action("Erase", key: "erase", destructive: true) {
            model.actionRuns = 0
        }
        r.scenario("Broken", key: "broken") { _ in
            throw TestError.failed
        }
    }
}
