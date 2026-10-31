/// Build information for gating debug features.
public enum SaveStateBuild {
    /// `true` when SaveState was compiled in a Debug configuration.
    ///
    /// Xcode builds Swift packages as Release for custom configurations such as
    /// Staging or QA, so pass your own flag to `SaveStateRegistry` there.
    public static let isDebug: Bool = {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }()
}
