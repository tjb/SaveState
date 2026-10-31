import ArgumentParser
import SaveStateBridgeKit

@main
struct SaveStateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "savestate",
        abstract: "Drive SaveState scenarios in running iOS apps.",
        version: Bridge.version,
        subcommands: [MCPServerCommand.self]
    )
}

struct MCPServerCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mcp",
        abstract: "Run the SaveState MCP server over stdio for coding agents."
    )

    func run() async throws {
        try await Bridge.runMCPServer()
    }
}
