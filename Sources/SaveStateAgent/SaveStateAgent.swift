// Everything in this module is Debug-only. Outside DEBUG it compiles to
// nothing, so a Release binary carries no server and no open port.
#if DEBUG
import SaveState
import SaveStateProtocol

/// The Debug-only endpoint that lets the `savestate` bridge reach a running app.
///
/// v0.1 adds the loopback WebSocket server, the per-launch token, and the
/// endpoint file the bridge discovers through the app's data container.
public enum SaveStateAgent {
    /// The wire protocol version this endpoint speaks.
    public static let protocolVersion = WireProtocol.version
}
#endif
