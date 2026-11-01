#if os(macOS)
import AppKit
import SaveState
import SwiftUI
import Testing
@testable import SaveStateUI

@MainActor
private final class Model {
    var isOn = false
}

/// Hosts the real views, so these reach the gates inside their bodies.
@Suite("View visibility")
@MainActor
struct ViewVisibilityTests {
    private func registry(isEnabled: Bool) -> SaveStateRegistry {
        SaveStateRegistry(model: Model(), store: .discarding, isEnabled: isEnabled) { r in
            r.toggle("On", key: "on", \.isOn)
        }
    }

    private func size(of view: some View) -> CGSize {
        let host = NSHostingView(rootView: view)
        host.layoutSubtreeIfNeeded()
        return host.fittingSize
    }

    @Test func aDisabledRegistrysOverlayShowsNothing() {
        #expect(size(of: SaveStateOverlay(registry: registry(isEnabled: false))) == .zero)
    }

    @Test func anEnabledRegistrysOverlayShowsItsButton() {
        #expect(size(of: SaveStateOverlay(registry: registry(isEnabled: true))).height > 0)
    }

    @Test func aDisabledRegistrysPanelShowsNothing() {
        #expect(size(of: SaveStatePanel(registry: registry(isEnabled: false))) == .zero)
    }

    @Test func anEnabledRegistrysPanelShowsItsControls() {
        #expect(size(of: SaveStatePanel(registry: registry(isEnabled: true))).height > 0)
    }
}
#endif
