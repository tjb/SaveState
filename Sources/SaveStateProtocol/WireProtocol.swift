/// The versioned wire protocol between an app's `SaveStateAgent` endpoint and
/// the Mac-side `savestate` bridge.
///
/// MCP lives only in the bridge; apps speak this smaller protocol, so a new
/// MCP spec revision never forces an app rebuild. Bump `version` on any
/// breaking change to the message format.
public enum WireProtocol {
    /// The protocol version this build speaks.
    public static let version = 1
}
