// Everything in this module is Debug-only. Outside DEBUG it compiles to
// nothing, so a Release binary carries no server and no open port.
//
// v0.1 adds the loopback WebSocket server, the per-launch token, and the
// endpoint file the bridge discovers through the app's data container.
#if DEBUG
import SaveState
import SaveStateProtocol
#endif
