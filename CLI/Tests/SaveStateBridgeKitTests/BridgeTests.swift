import Foundation
import MCP
import SaveStateProtocol
import Testing
@testable import SaveStateBridgeKit

@Test func bridgeSpeaksTheCurrentWireProtocol() {
    #expect(Bridge.protocolVersion == WireProtocol.version)
}

private func text(_ content: [Tool.Content]) -> String {
    content.compactMap { item -> String? in
        if case .text(let text, _, _) = item { return text }
        return nil
    }
    .joined()
}

/// What `Client.callTool` returned, in a form a test's closure can hand back.
private struct ToolOutcome: Sendable {
    var content: [Tool.Content]
    var isError: Bool?
}

private let sampleApp = DiscoveredApp(
    endpoint: EndpointInfo(
        protocolVersion: WireProtocol.version,
        port: 1,
        token: "secret-token",
        bundleIdentifier: "sample.app",
        appName: "Sample",
        processIdentifier: 1
    ),
    deviceIdentifier: "DEVICE"
)

/// Whether `Bridge.serve` has returned.
private actor ServingFinished {
    private(set) var value = false

    func record() {
        value = true
    }
}

/// Drives the server the way a coding agent does: a real MCP client, over the SDK's
/// in-memory transport, so requests and results pass through JSON-RPC encoding.
@Suite("MCP server")
struct BridgeServerTests {
    private func withClient<Output: Sendable>(
        tools: BridgeTools = BridgeTools(timeout: .seconds(5)) { [] },
        _ body: @Sendable (Client) async throws -> Output
    ) async throws -> Output {
        let (clientSide, serverSide) = await InMemoryTransport.createConnectedPair()
        let server = await Bridge.makeServer(tools: tools)
        try await server.start(transport: serverSide)
        let client = Client(name: "test", version: "1")
        _ = try await client.connect(transport: clientSide)
        let output = try await body(client)
        await client.disconnect()
        await server.stop()
        return output
    }

    private func callTool(
        _ client: Client,
        _ name: String,
        _ arguments: [String: Value]? = nil
    ) async throws -> ToolOutcome {
        let (content, isError) = try await client.callTool(name: name, arguments: arguments)
        return ToolOutcome(content: content, isError: isError)
    }

    // MARK: - Initialize

    @Test func initializeIdentifiesTheServerAndOffersTools() async throws {
        let (clientSide, serverSide) = await InMemoryTransport.createConnectedPair()
        let server = await Bridge.makeServer(tools: BridgeTools { [] })
        try await server.start(transport: serverSide)
        let client = Client(name: "test", version: "1")

        let result = try await client.connect(transport: clientSide)

        #expect(result.serverInfo.name == "savestate")
        #expect(result.serverInfo.version == Bridge.version)
        #expect(result.capabilities.tools != nil)
        await client.disconnect()
        await server.stop()
    }

    // MARK: - tools/list

    @Test func listingReturnsEveryDefinedToolByName() async throws {
        let names = try await withClient { client in
            try await client.listTools().tools.map(\.name)
        }

        #expect(names == BridgeTools.definitions.map(\.name))
        #expect(names.contains("savestate_apply_scenario"))
    }

    @Test func listedSchemasSurviveTheWire() async throws {
        let tools = try await withClient { client in
            try await client.listTools().tools
        }

        let set = try #require(tools.first { $0.name == "savestate_set" })
        #expect(set.inputSchema.objectValue?["required"] == ["key", "value"])
        #expect(set.inputSchema.objectValue?["additionalProperties"] == false)
        #expect(set.inputSchema.objectValue?["properties"]?.objectValue?["persist"] != nil)
    }

    // MARK: - tools/call

    @Test func aCallReturnsTheToolsOutput() async throws {
        let tools = BridgeTools(timeout: .seconds(5)) { [sampleApp] }

        let result = try await withClient(tools: tools) { client in
            try await callTool(client, "savestate_list_apps")
        }

        #expect(result.isError != true)
        #expect(text(result.content).contains("sample.app"))
        #expect(!text(result.content).contains("secret-token"))
    }

    @Test func aCallPassesItsArgumentsToTheTool() async throws {
        let tools = BridgeTools(timeout: .seconds(5)) { [sampleApp] }

        let result = try await withClient(tools: tools) { client in
            try await callTool(client, "savestate_list_apps", ["device": "OTHER"])
        }

        #expect(result.isError != true)
        #expect(!text(result.content).contains("sample.app"))
    }

    @Test func aToolFailureComesBackAsAnErrorResultNotAProtocolFailure() async throws {
        // `callTool` throws on a JSON-RPC error, so reaching the checks means the
        // failure arrived as a result the agent can read.
        let result = try await withClient { client in
            try await callTool(client, "savestate_describe")
        }

        #expect(result.isError == true)
        #expect(text(result.content).contains("No SaveState apps are running"))
    }

    @Test func anUnknownToolComesBackAsAnErrorResult() async throws {
        let result = try await withClient { client in
            try await callTool(client, "savestate_nope")
        }

        #expect(result.isError == true)
        #expect(text(result.content).contains("savestate_nope"))
    }

    @Test func anAppThatMisbehavesComesBackAsAnErrorResult() async throws {
        let endpoint = try await FakeEndpoint(.rejects(WireError(code: .unauthorized, message: "The token is wrong.")))
        let app = endpoint.app()
        let tools = BridgeTools(timeout: .seconds(5)) { [app] }

        let result = try await withClient(tools: tools) { client in
            try await callTool(client, "savestate_describe")
        }

        #expect(result.isError == true)
        #expect(text(result.content).contains("The token is wrong."))
    }

    @Test func theServerKeepsAnsweringAfterAToolFails() async throws {
        let result = try await withClient { client in
            _ = try await callTool(client, "savestate_nope")
            return try await callTool(client, "savestate_list_apps")
        }

        #expect(result.isError != true)
    }

    // MARK: - Lifetime

    @Test(.timeLimit(.minutes(1))) func servingLastsWhileTheClientIsConnected() async throws {
        let (clientSide, serverSide) = await InMemoryTransport.createConnectedPair()
        let finished = ServingFinished()
        let serving = Task {
            try await Bridge.serve(tools: BridgeTools { [] }, over: serverSide)
            await finished.record()
        }
        let client = Client(name: "test", version: "1")
        _ = try await client.connect(transport: clientSide)
        _ = try await client.listTools()

        // A whole request has gone both ways, so a serve that didn't wait is done.
        #expect(await finished.value == false)

        await client.disconnect()
        _ = await serving.result
    }

    @Test(.timeLimit(.minutes(1))) func servingEndsWhenTheClientDisconnects() async throws {
        let (clientSide, serverSide) = await InMemoryTransport.createConnectedPair()
        let serving = Task {
            try await Bridge.serve(tools: BridgeTools { [] }, over: serverSide)
        }
        let client = Client(name: "test", version: "1")
        _ = try await client.connect(transport: clientSide)
        #expect(try await client.listTools().tools.isEmpty == false)

        await client.disconnect()

        let ended = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                _ = await serving.result
                return true
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(5))
                return false
            }
            let first = await group.next() ?? false
            serving.cancel()
            group.cancelAll()
            return first
        }
        #expect(ended)
    }
}
