import MCP
import SaveStateClientKit

/// The Mac-side bridge: discovers running SaveState apps and serves the
/// SaveState MCP tools to coding agents.
///
/// It's `package` rather than `public`, along with ``BridgeTools``, so the
/// SaveStateBridgeKit library's public API never includes the MCP SDK's types:
/// other tools depend on ``SaveStateClient``, and the SDK can change freely.
package enum Bridge {
    /// The bridge version.
    package static let version = "0.2.1"

    /// The wire protocol version the bridge speaks to app endpoints.
    package static let protocolVersion = WireProtocol.version

    /// Runs an MCP server over stdio until the client disconnects.
    ///
    /// It serves `savestate_list_apps`, `savestate_describe`, `savestate_set`,
    /// `savestate_run_action`, `savestate_apply_scenario`, `savestate_read`, and
    /// `savestate_wait`.
    package static func runMCPServer(tools: BridgeTools = BridgeTools()) async throws {
        try await serve(tools: tools, over: StdioTransport())
    }

    /// Serves the tools over a transport until the client disconnects.
    static func serve(tools: BridgeTools, over transport: any Transport) async throws {
        let server = await makeServer(tools: tools)
        try await server.start(transport: transport)
        await server.waitUntilCompleted()
    }

    /// Creates a server with the tools' handlers registered, not yet connected.
    static func makeServer(tools: BridgeTools) async -> Server {
        let server = Server(
            name: "savestate",
            version: version,
            capabilities: .init(tools: .init(listChanged: false))
        )
        await server.withMethodHandler(ListTools.self) { _ in
            .init(tools: BridgeTools.definitions)
        }
        await server.withMethodHandler(CallTool.self) { parameters in
            await tools.call(parameters.name, arguments: parameters.arguments ?? [:])
        }
        return server
    }
}
