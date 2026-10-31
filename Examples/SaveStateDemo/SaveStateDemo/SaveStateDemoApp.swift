import SaveState
import SaveStateUI
import SwiftUI

@main
struct SaveStateDemoApp: App {
    @State private var state: DemoState
    @State private var registry: SaveStateRegistry
    @State private var premiumManager = DemoPremiumManager(
        allowsDebugOverride: !Self.launchArguments.contains("-premiumToggleBlocked")
    )

    private static let launchArguments = ProcessInfo.processInfo.arguments

    init() {
        let state = DemoState()
        _state = State(initialValue: state)
        _registry = State(initialValue: DemoState.makeRegistry(for: state))
    }

    var body: some Scene {
        WindowGroup {
            // UI tests pass these to exercise the PremiumToggle shim on its own.
            if Self.launchArguments.contains("-premiumToggleShim") {
                DemoContentView(state: state)
                    .premiumToggle(premiumManager, isEnabled: !Self.launchArguments.contains("-premiumToggleHidden"))
            } else {
                DemoContentView(state: state)
                    .saveStateOverlay(registry)
            }
        }
    }
}
