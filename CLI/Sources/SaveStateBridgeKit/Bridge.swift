import MCP
import SaveStateProtocol

/// The Mac-side bridge: discovers running SaveState apps and serves the
/// SaveState MCP tools to coding agents.
///
/// This is a library rather than part of the CLI executable so a future
/// Mac app can link the same logic.
public enum Bridge {
    /// The bridge version.
    public static let version = "0.0.0"

    /// The wire protocol version the bridge speaks to app endpoints.
    public static let protocolVersion = WireProtocol.version

    /// Runs an MCP server over stdio until the client disconnects.
    ///
    /// It advertises no tools yet. v0.1 adds `savestate_list_apps`,
    /// `savestate_describe`, `savestate_set`, `savestate_run_action`,
    /// `savestate_apply_scenario`, and `savestate_read`.
    public static func runMCPServer() async throws {
        let server = Server(
            name: "savestate",
            version: version,
            capabilities: .init(tools: .init(listChanged: false))
        )
        await server.withMethodHandler(ListTools.self) { _ in
            .init(tools: [])
        }
        try await server.start(transport: StdioTransport())
        await server.waitUntilCompleted()
    }
}
