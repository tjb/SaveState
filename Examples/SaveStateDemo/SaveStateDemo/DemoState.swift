import Foundation
import Observation
import SaveState

enum ServerEnvironment: String, CaseIterable {
    case staging
    case production
}

/// The app state the demo's debug controls bind to.
@MainActor
@Observable
final class DemoState {
    /// When the trial really ends: a week after this launch.
    let realTrialEnd = Date().addingTimeInterval(7 * 86_400) // swiftlint:disable:this demo_reads_savestate_clock
    /// Stands in for a real StoreKit entitlement.
    let isEntitled = false

    var premiumOverride: Bool?
    var trialEndOverride: Date?
    var showsTips = true
    var environment = ServerEnvironment.production
    var greeting = "Welcome back"
    var projectLimit = 3
    var discount = 0.0
    var seededProjects = 0

    var isPremium: Bool {
        premiumOverride ?? isEntitled
    }

    var trialEnd: Date {
        trialEndOverride ?? realTrialEnd
    }

    static func makeRegistry(for state: DemoState, isEnabled: Bool = SaveStateBuild.isDebug) -> SaveStateRegistry {
        SaveStateRegistry(model: state, isEnabled: isEnabled) { r in
            r.section("Purchases") {
                r.triState("Premium", key: "premium", \.premiumOverride, real: { state.isEntitled })
                r.date("Trial ends", key: "trial-end", \.trialEndOverride, real: { state.realTrialEnd })
                r.decimal("Discount", key: "discount", \.discount)
            }
            r.section("App") {
                r.toggle("Show tips", key: "tips", \.showsTips)
                r.choice("Environment", key: "env", \.environment, requiresRelaunch: true)
                r.text("Greeting", key: "greeting", \.greeting)
                r.integer("Project limit", key: "project-limit", \.projectLimit)
            }
            r.clock()
            r.action("Seed projects", key: "seed") {
                state.seededProjects += 5
            }
            // Far longer than any UI test takes. The next launch ends it, so tests can't
            // race it finishing.
            r.action("Sync slowly", key: "slow-sync") {
                try await Task.sleep(for: .seconds(600))
            }
            r.action("Erase projects", key: "erase", destructive: true) {
                state.seededProjects = 0
            }
            r.scenario(
                "Expired trial",
                key: "expired-trial",
                summary: "The trial ended yesterday, so the paywall shows."
            ) { state in
                state.premiumOverride = false
                state.trialEndOverride = nil
                SaveStateClock.overrideDate = state.realTrialEnd.addingTimeInterval(86_400)
            }
        }
    }
}
