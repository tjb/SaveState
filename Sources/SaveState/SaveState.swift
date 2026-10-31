/// SaveState lets an app declare its debug state once, then reach it from the
/// in-app overlay, AI agents, UI tests, and SwiftUI previews.
///
/// This module holds the registry: controls, actions, probes, and scenarios.
/// It contains no networking code, so it is safe to link in every build.
public enum SaveState {
    /// The library version.
    public static let version = "0.0.0"
}
