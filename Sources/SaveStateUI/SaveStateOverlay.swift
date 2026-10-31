import SaveState
import SwiftUI

/// A floating ladybug button that opens a ``SaveStatePanel``.
///
/// Most apps attach it with ``SwiftUICore/View/saveStateOverlay(_:alignment:)``.
/// It shows nothing when the registry is disabled.
public struct SaveStateOverlay: View {
    private let registry: SaveStateRegistry
    @State private var isPanelPresented = false
    @State private var runState = PanelRunState()

    /// Creates the button for a registry.
    public init(registry: SaveStateRegistry) {
        self.registry = registry
    }

    public var body: some View {
        if registry.isEnabled {
            Button {
                isPanelPresented.toggle()
            } label: {
                Label("SaveState Debug Panel", systemImage: "ladybug.fill")
                    .labelStyle(.iconOnly)
                    .font(.title2)
            }
            .overlayFloatingButtonStyle()
            .accessibilityValue(accessibilityValue)
            .accessibilityIdentifier("saveState.button")
            .popover(isPresented: $isPanelPresented) {
                SaveStatePanel(registry: registry, runState: runState)
                    .presentationCompactAdaptation(.popover)
                    .overlayPanelBackground()
            }
        }
    }

    private var accessibilityValue: String {
        let count = registry.describe().controls.filter(\.isChanged).count
        return count == 1 ? "1 control changed" : "\(count) controls changed"
    }
}

public extension View {
    /// Overlays a ``SaveStateOverlay`` button that opens the registry's debug
    /// panel. Nothing shows when the registry is disabled.
    ///
    /// - Parameters:
    ///   - registry: The registry the panel renders and changes.
    ///   - alignment: Where the button sits. Defaults to the bottom-trailing
    ///     corner. In a `TabView` app, attach it inside a tab or pick another
    ///     alignment so it doesn't cover the tab bar.
    func saveStateOverlay(
        _ registry: SaveStateRegistry,
        alignment: Alignment = .bottomTrailing
    ) -> some View {
        overlay(alignment: alignment) {
            SaveStateOverlay(registry: registry)
                .padding()
        }
    }
}
