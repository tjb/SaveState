import SwiftUI

// Liquid Glass on iOS 26 and macOS 26, material everywhere older. Both platforms
// appear in each check because `*` would otherwise let macOS 15 reach the glass
// APIs, which it doesn't have.

extension View {
    /// The floating button's look: tinted glass, or a material circle.
    @ViewBuilder
    func overlayFloatingButtonStyle() -> some View {
        if #available(iOS 26, macOS 26, *) {
            self
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.circle)
                .controlSize(.large)
                .tint(.red)
        } else {
            self.buttonStyle(MaterialCircleButtonStyle())
        }
    }

    /// The look of the panel's buttons: glass, or a bordered button that lets
    /// the panel's material show through.
    @ViewBuilder
    func overlayPanelButtonStyle() -> some View {
        if #available(iOS 26, macOS 26, *) {
            self.buttonStyle(.glass)
        } else {
            self.buttonStyle(.bordered)
        }
    }

    /// The panel's background. System popovers are already glass on iOS 26.
    @ViewBuilder
    func overlayPanelBackground() -> some View {
        if #available(iOS 26, macOS 26, *) {
            self
        } else {
            self.presentationBackground(.regularMaterial)
        }
    }
}

/// The floating button's look before Liquid Glass.
private struct MaterialCircleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.red)
            .frame(minWidth: 48, minHeight: 48)
            .background(.regularMaterial, in: Circle())
            .overlay(Circle().strokeBorder(.separator, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}
