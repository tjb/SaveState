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
    /// The run of the seed-projects scenario, kept so applying it again or erasing
    /// cancels the previous run.
    @ObservationIgnored private var seeding: Task<Void, Never>?

    var isPremium: Bool {
        premiumOverride ?? isEntitled
    }

    var trialEnd: Date {
        trialEndOverride ?? realTrialEnd
    }

    /// Restarts the count at zero, then adds a project every `interval` up to
    /// `count`. It returns at once, so a wait sees the count climb.
    func startSeeding(count: Int = 5, interval: Duration = .milliseconds(100)) {
        seeding?.cancel()
        seededProjects = 0
        seeding = Task { [weak self] in
            for _ in 0..<count {
                // A sleep that already finished doesn't throw, so check again: erase or
                // a new run may have cancelled this one while it waited for the main actor.
                guard (try? await Task.sleep(for: interval)) != nil, !Task.isCancelled else { return }
                self?.seededProjects += 1
            }
        }
    }

    /// Stops a seeding run, then adds `count` projects at once.
    func addProjects(_ count: Int = 5) {
        seeding?.cancel()
        seeding = nil
        seededProjects += count
    }

    /// Stops a seeding run and removes every project.
    func eraseProjects() {
        seeding?.cancel()
        seeding = nil
        seededProjects = 0
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
                state.addProjects()
            }
            // For UI tests only, since it disables the panel's buttons while it runs. It's
            // far longer than any test takes, and the next launch ends it, so tests can't
            // race it finishing.
            if ProcessInfo.processInfo.arguments.contains("-saveStateSlowAction") {
                r.action("Sync slowly", key: "slow-sync") {
                    try await Task.sleep(for: .seconds(600))
                }
            }
            r.action("Erase projects", key: "erase", destructive: true) {
                state.eraseProjects()
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
            r.scenario(
                "Seeded projects",
                key: "seed-projects",
                summary: "Starts from no projects and adds one every 100 ms until there are 5."
            ) { state in
                // Returns before the projects arrive; wait on item-count to see them.
                state.startSeeding()
            }
            r.probe("Projects", key: "item-count") { state.seededProjects }
        }
    }
}
