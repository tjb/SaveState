import Foundation
import Observation
import SaveState
import SwiftUI

// PremiumToggle's public API on top of SaveState, so existing apps keep their
// `.premiumToggle(manager)` call. Names match PremiumToggle 1.x. The panel is
// SaveState's, so it offers On, Off, and Real instead of a toggle and a button.
//
// The provider stays the only owner of the override. It persists the value
// itself, so the registry behind the panel stores nothing.

/// Build information used for safe defaults.
public enum PremiumToggleBuild {
    /// `true` when this package was compiled with the `DEBUG` flag.
    ///
    /// Custom configurations such as Staging or QA build packages as Release.
    /// Pass an explicit `isEnabled` to `premiumToggle(_:alignment:isEnabled:)`
    /// to show the panel there.
    public static var isDebug: Bool { SaveStateBuild.isDebug }
}

/// A type that reports premium status and accepts a debug override.
///
/// Conform your existing premium manager and mark it `@Observable` so the
/// debug panel updates when `isPremium` changes.
///
/// After `setDebugOverride(v)`, a conformer should report `debugOverride == v`
/// and `isPremium == v ?? realStatus`. A conformer whose
/// ``allowsDebugOverride`` is `false` ignores the call.
@MainActor
public protocol PremiumStatusProvider: AnyObject, Observable {
    /// Whether premium features are unlocked, including any debug override.
    var isPremium: Bool { get }

    /// The active debug override, or `nil` when real status is in effect.
    var debugOverride: Bool? { get }

    /// Whether this provider currently accepts debug overrides.
    ///
    /// The debug panel disables its controls when this is `false`. Defaults to
    /// `true`; return `PremiumToggleBuild.isDebug` or your own flag to block
    /// overrides in Release builds.
    var allowsDebugOverride: Bool { get }

    /// Forces premium on or off, or clears the override when `nil`.
    func setDebugOverride(_ value: Bool?)
}

public extension PremiumStatusProvider {
    /// Accepts overrides by default.
    var allowsDebugOverride: Bool { true }
}

/// Persists a premium debug override in `UserDefaults` so it survives relaunches.
///
/// It does no build gating itself. Check your provider's `allowsDebugOverride`
/// before reading or writing it.
public struct PremiumDebugOverride: Sendable {
    /// The key used when none is given.
    public static let defaultKey = "debug_premium_override"

    private let suiteName: String?
    /// The `UserDefaults` key the override is stored under.
    public let key: String

    /// - Parameters:
    ///   - suiteName: A `UserDefaults` suite, or `nil` for `.standard`.
    ///   - key: The key the override is stored under.
    public init(suiteName: String? = nil, key: String = defaultKey) {
        self.suiteName = suiteName
        self.key = key
    }

    private var defaults: UserDefaults {
        suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    }

    /// The stored override, or `nil` when none is set. Setting `nil` removes it.
    public var value: Bool? {
        get { defaults.object(forKey: key) as? Bool }
        nonmutating set {
            if let newValue {
                defaults.set(newValue, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
    }
}

/// Connects a provider to a registry control.
@MainActor
final class PremiumProviderModel {
    private let provider: any PremiumStatusProvider
    /// Reads report no override until the control is declared, because the
    /// registry takes a control's default from its first read. "No override" is
    /// always the default here, even when the provider restored one at launch,
    /// so that reset returns to real status.
    private var isDeclared = false

    init(provider: any PremiumStatusProvider) {
        self.provider = provider
    }

    var debugOverride: Bool? {
        get { isDeclared ? provider.debugOverride : nil }
        set { provider.setDebugOverride(newValue) }
    }

    /// Creates the registry the panel renders for a provider.
    static func makeRegistry(for provider: any PremiumStatusProvider) -> SaveStateRegistry {
        let model = PremiumProviderModel(provider: provider)
        let registry = SaveStateRegistry(model: model, store: .discarding, isEnabled: true) { r in
            r.triState("Premium", key: "premium", \.debugOverride)
        }
        model.isDeclared = true
        return registry
    }
}

/// What the shim's button and panel show for a provider. It reads the provider
/// on each access, so a view that uses it while rendering observes the provider.
@MainActor
struct PremiumToggleModel {
    /// Whether the panel offers controls or explains why it can't.
    enum PanelMode: Equatable {
        case open
        case locked
    }

    let provider: any PremiumStatusProvider

    /// The overlay for a provider, or `nil` when it shouldn't show.
    static func overlay<Provider: PremiumStatusProvider>(
        for provider: Provider,
        isEnabled: Bool
    ) -> PremiumToggleOverlay<Provider>? {
        isEnabled ? PremiumToggleOverlay(provider: provider) : nil
    }

    var panelMode: PanelMode {
        provider.allowsDebugOverride ? .open : .locked
    }

    var statusText: String {
        provider.isPremium ? "Premium is on" : "Premium is off"
    }

    /// The status as SwiftUI shows it, as a localization key.
    var statusTextKey: LocalizedStringKey {
        LocalizedStringKey(statusText)
    }

    var statusImage: String {
        provider.isPremium ? "crown.fill" : "crown"
    }

    var accessibilityValue: String {
        provider.isPremium ? "Premium on" : "Premium off"
    }
}

/// A floating ladybug button that opens a panel for overriding premium status.
///
/// Most apps attach it with ``SwiftUICore/View/premiumToggle(_:alignment:isEnabled:)``.
public struct PremiumToggleOverlay<Provider: PremiumStatusProvider>: View {
    private let provider: Provider

    /// Creates the button for the given provider.
    public init(provider: Provider) {
        self.provider = provider
    }

    public var body: some View {
        PremiumToggleButton(provider: provider)
            // The registry is bound to one provider, so a new provider needs a new one.
            .id(ObjectIdentifier(provider))
    }
}

private struct PremiumToggleButton<Provider: PremiumStatusProvider>: View {
    let provider: Provider

    @State private var registry: SaveStateRegistry
    @State private var isPanelPresented = false

    init(provider: Provider) {
        self.provider = provider
        _registry = State(initialValue: PremiumProviderModel.makeRegistry(for: provider))
    }

    private var model: PremiumToggleModel {
        PremiumToggleModel(provider: provider)
    }

    var body: some View {
        Button {
            isPanelPresented.toggle()
        } label: {
            Label("Premium Debug Panel", systemImage: "ladybug.fill")
                .labelStyle(.iconOnly)
                .font(.title2)
        }
        .overlayFloatingButtonStyle()
        .accessibilityValue(model.accessibilityValue)
        .accessibilityIdentifier("premiumToggle.button")
        .popover(isPresented: $isPanelPresented) {
            panel
                .presentationCompactAdaptation(.popover)
                .overlayPanelBackground()
        }
    }

    @ViewBuilder
    private var panel: some View {
        if model.panelMode == .open {
            VStack(alignment: .leading, spacing: 0) {
                status
                    .padding([.horizontal, .top])
                SaveStatePanel(registry: registry)
            }
        } else {
            VStack(alignment: .leading, spacing: 12) {
                Text("Debug Panel")
                    .font(.headline)
                status
                Label("Overrides disabled in this build", systemImage: "lock")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("premiumToggle.disabled")
            }
            .padding()
            .frame(minWidth: 240, alignment: .leading)
        }
    }

    /// The status the app acts on. The registry can't report it as a real value,
    /// because `isPremium` includes any override.
    private var status: some View {
        Label(model.statusTextKey, systemImage: model.statusImage)
        .font(.footnote)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("premiumToggle.status")
    }
}

public extension View {
    /// Overlays a ``PremiumToggleOverlay`` button for overriding premium status.
    ///
    /// - Parameters:
    ///   - provider: The premium manager the panel controls.
    ///   - alignment: Where the button sits. Defaults to the bottom-trailing
    ///     corner. In a `TabView` app, attach it inside a tab or pick another
    ///     alignment so it doesn't cover the tab bar.
    ///   - isEnabled: Whether to show the button. Defaults to Debug builds only.
    func premiumToggle(
        _ provider: some PremiumStatusProvider,
        alignment: Alignment = .bottomTrailing,
        isEnabled: Bool = PremiumToggleBuild.isDebug
    ) -> some View {
        overlay(alignment: alignment) {
            if let overlay = PremiumToggleModel.overlay(for: provider, isEnabled: isEnabled) {
                overlay
                    .padding()
            }
        }
    }
}
