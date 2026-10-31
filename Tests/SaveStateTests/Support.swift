import Foundation
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

/// A store in its own `UserDefaults` suite, so tests never share values.
func makeStore() -> OverrideStore {
    OverrideStore(suiteName: "SaveStateTests.\(UUID().uuidString)")
}

@MainActor
func makeRegistry(
    model: DebugModel,
    store: OverrideStore = makeStore(),
    isEnabled: Bool = true
) -> SaveStateRegistry {
    SaveStateRegistry(model: model, store: store, isEnabled: isEnabled) { r in
        r.section("Onboarding") {
            r.toggle("Show onboarding", key: "onboarding", \.showsOnboarding)
        }
        r.section("Purchases") {
            r.triState("Premium", key: "premium", \.premiumOverride, real: { model.isEntitled })
            r.date("Trial ends", key: "trial-end", \.trialEndOverride)
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
        r.scenario("expired-trial", "Trial ended; the paywall shows") { state in
            state.premiumOverride = false
            state.trialEndOverride = Date(timeIntervalSince1970: 1_800_000_000)
        }
        r.scenario("broken", "Always throws") { _ in
            throw TestError.failed
        }
    }
}
