import SaveState
import SaveStateUI
import SwiftUI
#if DEBUG
import SaveStateAgent
#endif

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
        // UI tests pass this to check that a disabled registry shows nothing.
        let isDisabled = ProcessInfo.processInfo.arguments.contains("-saveStateDisabled")
        let registry = DemoState.makeRegistry(for: state, isEnabled: !isDisabled)
        _registry = State(initialValue: registry)
        #if DEBUG
        Task { try? await AgentEndpoint.start(registry: registry) }
        #endif
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
