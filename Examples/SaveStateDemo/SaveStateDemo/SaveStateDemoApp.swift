import SaveState
import SaveStateUI
import SwiftUI

@main
struct SaveStateDemoApp: App {
    @State private var state: DemoState
    @State private var registry: SaveStateRegistry
    @State private var premiumManager = DemoPremiumManager()

    init() {
        let state = DemoState()
        _state = State(initialValue: state)
        _registry = State(initialValue: DemoState.makeRegistry(for: state))
    }

    var body: some Scene {
        WindowGroup {
            // UI tests pass this to exercise the PremiumToggle shim on its own.
            if ProcessInfo.processInfo.arguments.contains("-premiumToggleShim") {
                DemoContentView(state: state)
                    .premiumToggle(premiumManager)
            } else {
                DemoContentView(state: state)
                    .saveStateOverlay(registry)
            }
        }
    }
}
