#if DEBUG
import Observation
import SaveState
import SwiftUI

private enum PreviewEnvironment: String, CaseIterable {
    case staging
    case production
}

@MainActor
@Observable
private final class PreviewState {
    var showsOnboarding = false
    var premiumOverride: Bool?
    var trialEndOverride: Date?
    var environment = PreviewEnvironment.production
    var greeting = "Welcome back"
    var projectLimit = 3
    var discount = 0.15
    var pendingUploads = 2
    var isConnected = true
    var syncProgress = 0.4
    var screen = "home"
    var lastSync = Date(timeIntervalSince1970: 1_790_000_000)
}

/// A registry with one control of every kind, and one probe of every type.
@MainActor
private func makePreviewRegistry(isEnabled: Bool = true) -> SaveStateRegistry {
    let state = PreviewState()
    return SaveStateRegistry(
        model: state,
        store: OverrideStore(suiteName: "SaveStateUI.Previews"),
        isEnabled: isEnabled
    ) { r in
        r.section("Purchases") {
            r.triState("Premium", key: "premium", \.premiumOverride, real: { false })
            r.date("Trial ends", key: "trial-end", \.trialEndOverride, real: { .now })
            r.decimal("Discount", key: "discount", \.discount)
        }
        r.section("Sync") {
            r.probe("Connected", key: "connected") { state.isConnected }
            r.probe("Pending uploads", key: "pending-uploads") { state.pendingUploads }
            r.probe("Progress", key: "sync-progress") { state.syncProgress }
            r.probe("Last sync", key: "last-sync") { state.lastSync }
        }
        r.probe("Screen", key: "screen") { state.screen }
        r.section("App") {
            r.toggle("Show onboarding", key: "onboarding", \.showsOnboarding)
            r.choice("Environment", key: "env", \.environment, requiresRelaunch: true)
            r.text("Greeting", key: "greeting", \.greeting)
            r.integer("Project limit", key: "project-limit", \.projectLimit)
        }
        r.clock()
        r.action("Seed data", key: "seed") {}
        r.action("Erase data", key: "erase", destructive: true) {}
        r.scenario(
            "Expired trial",
            key: "expired-trial",
            summary: "The trial ended yesterday, so the paywall shows."
        ) { state in
            state.premiumOverride = false
        }
        r.action("Upload one", key: "upload-one") {
            state.pendingUploads = max(0, state.pendingUploads - 1)
        }
    }
}

#Preview("Panel") {
    SaveStatePanel(registry: makePreviewRegistry())
}

#Preview("Floating button") {
    Color.clear
        .saveStateOverlay(makePreviewRegistry())
}

#Preview("Disabled shows nothing") {
    Text("No button or panel appears when the registry is disabled.")
        .saveStateOverlay(makePreviewRegistry(isEnabled: false))
}
#endif
