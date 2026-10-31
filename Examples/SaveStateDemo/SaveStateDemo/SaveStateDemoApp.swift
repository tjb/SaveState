import SaveState
import SaveStateUI
import SwiftUI

@main
struct SaveStateDemoApp: App {
    @State private var state: DemoState
    @State private var registry: SaveStateRegistry

    init() {
        let state = DemoState()
        _state = State(initialValue: state)
        _registry = State(initialValue: DemoState.makeRegistry(for: state))
    }

    var body: some Scene {
        WindowGroup {
            DemoContentView(state: state)
                .saveStateOverlay(registry)
        }
    }
}
