import Foundation
import MCP
import SaveState
import SaveStateAgent
import SaveStateProtocol
import Testing
@testable import SaveStateBridgeKit

private enum Flavor: String, CaseIterable {
    case sweet
    case sour
}

private enum Boom: Error {
    case failed
}

@MainActor
private final class Model {
    var isOn = false
    var premium: Bool?
    var flavor = Flavor.sweet
    var name = "Ada"
    var count = 0
    var ratio = 0.5
    var trialEnd: Date?
    var runs = 0
}

/// A fake simulator's data folder, removed when the test ends.
private final class Scratch: Sendable {
    let suiteName = "SaveStateBridgeTests.\(UUID().uuidString)"
    let dataPath = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)

    func container(_ name: String = "app") -> URL {
        dataPath.appendingPathComponent("Containers/Data/Application/\(name)")
    }

    var device: SimulatorDevice {
        SimulatorDevice(identifier: "DEVICE", dataPath: dataPath)
    }

    deinit {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: dataPath)
    }
}

private func text(_ result: CallTool.Result) -> String {
    result.content.compactMap { content -> String? in
        if case .text(let text, _, _) = content { return text }
        return nil
    }
    .joined()
}

/// Exercises the tools against a real endpoint, through real discovery.
@Suite("Bridge tools", .serialized)
@MainActor
struct BridgeToolsTests {
    private let scratch = Scratch()
    private let model = Model()

    private var tools: BridgeTools {
        let device = scratch.device
        return BridgeTools(timeout: .seconds(5)) { AppDiscovery.apps(on: [device]) }
    }

    private func start() async throws -> AgentEndpoint {
        let model = model
        let registry = SaveStateRegistry(
            model: model,
            store: OverrideStore(suiteName: scratch.suiteName),
            isEnabled: true
        ) { r in
            r.toggle("On", key: "on", \.isOn)
            r.triState("Premium", key: "premium", \.premium)
            r.choice("Flavor", key: "flavor", \.flavor, requiresRelaunch: true)
            r.text("Name", key: "name", \.name)
            r.integer("Count", key: "count", \.count)
            r.decimal("Ratio", key: "ratio", \.ratio)
            r.date("Trial ends", key: "trial-end", \.trialEnd)
            r.clock()
            r.action("Run", key: "run") { model.runs += 1 }
            r.action("Erase", key: "erase", destructive: true) { model.runs = 0 }
            r.action("Throw", key: "throw") { throw Boom.failed }
            r.scenario("Expired", key: "expired-trial") { state in state.premium = false }
        }
        return try #require(try await AgentEndpoint.start(registry: registry, container: scratch.container()))
    }

    private func call(_ name: String, _ arguments: [String: Value] = [:]) async -> CallTool.Result {
        await tools.call(name, arguments: arguments)
    }

    // MARK: - The tools

    @Test func advertisesTheSixTools() {
        #expect(Set(BridgeTools.definitions.map(\.name)) == [
            "savestate_list_apps",
            "savestate_describe",
            "savestate_set",
            "savestate_run_action",
            "savestate_apply_scenario",
            "savestate_read"
        ])
    }

    @Test func listsAppsWithoutTheirTokens() async throws {
        let endpoint = try await start()
        defer { endpoint.stop() }

        let result = await call("savestate_list_apps")

        #expect(result.isError != true)
        #expect(text(result).contains(endpoint.info.bundleIdentifier))
        #expect(text(result).contains("DEVICE"))
        #expect(!text(result).contains(endpoint.info.token))
    }

    @Test func describes() async throws {
        let endpoint = try await start()
        defer { endpoint.stop() }

        let result = await call("savestate_describe")

        #expect(result.isError != true)
        #expect(text(result).contains("expired-trial"))
        #expect(text(result).contains("flavor"))
    }

    @Test func appliesAScenario() async throws {
        let endpoint = try await start()
        defer { endpoint.stop() }

        let result = await call("savestate_apply_scenario", ["key": "expired-trial"])

        #expect(result.isError != true)
        #expect(model.premium == false)
    }

    @Test func runsAnActionAndRefusesDestructiveOnes() async throws {
        let endpoint = try await start()
        defer { endpoint.stop() }

        #expect(await call("savestate_run_action", ["key": "run"]).isError != true)
        #expect(model.runs == 1)

        let refused = await call("savestate_run_action", ["key": "erase"])
        #expect(refused.isError == true)
        #expect(text(refused).contains("destructive"))
        #expect(model.runs == 1)
    }

    @Test func reportsAnActionThatThrows() async throws {
        let endpoint = try await start()
        defer { endpoint.stop() }

        #expect(await call("savestate_run_action", ["key": "throw"]).isError == true)
    }

    @Test func readsAControl() async throws {
        let endpoint = try await start()
        defer { endpoint.stop() }
        model.count = 7

        let result = await call("savestate_read", ["key": "count"])

        #expect(result.isError != true)
        #expect(text(result).contains("7"))
        #expect(await call("savestate_read", ["key": "nope"]).isError == true)
    }

    // MARK: - Setting

    @Test func setsEveryKindFromPlainJSON() async throws {
        let endpoint = try await start()
        defer { endpoint.stop() }
        defer { SaveStateClock.overrideDate = nil }

        let values: [(String, Value)] = [
            ("on", .bool(true)),
            ("premium", .bool(true)),
            ("flavor", .string("sour")),
            ("name", .string("Grace")),
            ("count", .int(3)),
            ("ratio", .double(0.25)),
            ("trial-end", .string("2027-01-15T08:00:00Z")),
            ("clock", .string("2027-01-15T08:00:00.250Z"))
        ]
        for (key, value) in values {
            let result = await call("savestate_set", ["key": .string(key), "value": value])
            #expect(result.isError != true, "\(key): \(text(result))")
        }

        #expect(model.isOn)
        #expect(model.premium == true)
        #expect(model.flavor == .sour)
        #expect(model.name == "Grace")
        #expect(model.count == 3)
        #expect(model.ratio == 0.25)
        #expect(model.trialEnd == Date(timeIntervalSince1970: 1_800_000_000))
        #expect(SaveStateClock.overrideDate == Date(timeIntervalSince1970: 1_800_000_000.25))

        for key in ["premium", "trial-end", "clock"] {
            #expect(await call("savestate_set", ["key": .string(key), "value": .null]).isError != true)
        }
        #expect(model.premium == nil)
        #expect(model.trialEnd == nil)
        #expect(SaveStateClock.overrideDate == nil)
    }

    @Test func aSetIsSessionScopedUnlessPersisted() async throws {
        let endpoint = try await start()
        defer { endpoint.stop() }
        let store = OverrideStore(suiteName: scratch.suiteName)
        func relaunched() -> Bool {
            let model = Model()
            _ = SaveStateRegistry(model: model, store: store, isEnabled: true) { r in r.toggle("On", key: "on", \.isOn) }
            return model.isOn
        }

        let session = await call("savestate_set", ["key": "on", "value": true])
        #expect(text(session).contains("this launch"))
        #expect(!relaunched())

        let persisted = await call("savestate_set", ["key": "on", "value": true, "persist": true])
        #expect(text(persisted).contains("persists"))
        #expect(relaunched())
    }

    @Test func aSetToARelaunchControlSaysToRelaunch() async throws {
        let endpoint = try await start()
        defer { endpoint.stop() }

        let result = await call("savestate_set", ["key": "flavor", "value": "sour"])
        #expect(text(result).contains("Relaunch"))

        let persisted = await call("savestate_set", ["key": "flavor", "value": "sour", "persist": true])
        #expect(text(persisted).contains("Relaunch"))
        #expect(text(persisted).contains("persists"))
    }

    @Test func aWholeNumberCanArriveAsADouble() async throws {
        let endpoint = try await start()
        defer { endpoint.stop() }

        #expect(await call("savestate_set", ["key": "count", "value": .double(3)]).isError != true)
        #expect(model.count == 3)
    }

    @Test func aStringShapedLikeADataURLSetsAsText() async throws {
        let endpoint = try await start()
        defer { endpoint.stop() }
        let url = "data:text/plain;base64,aGk="
        // Decoded from JSON, because that's where the SDK turns it into data.
        let value = try JSONDecoder().decode(Value.self, from: JSONEncoder().encode(url))

        let result = await call("savestate_set", ["key": "name", "value": value])

        #expect(result.isError != true, "\(text(result))")
        #expect(model.name == url)
    }

    @Test func aMisspelledArgumentIsRejected() async throws {
        let endpoint = try await start()
        defer { endpoint.stop() }

        let result = await call("savestate_set", ["key": "on", "value": true, "persisted": true])

        #expect(result.isError == true)
        #expect(text(result).contains("persisted"))
        #expect(text(result).contains("persist,") || text(result).contains("persist."))
        #expect(!model.isOn)
    }

    @Test(arguments: [
        ("on", Value.string("yes")),
        ("flavor", Value.string("bitter")),
        ("count", Value.double(1.5)),
        ("count", Value.string("3")),
        ("ratio", Value.string("1")),
        ("name", Value.null),
        ("trial-end", Value.string("tomorrow")),
        ("clock", Value.int(5))
    ])
    func aBadValueExplainsWhatTheControlTakes(key: String, value: Value) async throws {
        let endpoint = try await start()
        defer { endpoint.stop() }

        let result = await call("savestate_set", ["key": .string(key), "value": value])

        #expect(result.isError == true)
        #expect(text(result).contains("takes"), "\(text(result))")
    }

    @Test func aSetExplainsAnUnknownKeyAndMissingArguments() async throws {
        let endpoint = try await start()
        defer { endpoint.stop() }

        let unknown = await call("savestate_set", ["key": "nope", "value": true])
        #expect(unknown.isError == true)
        #expect(text(unknown).contains("flavor"))
        #expect(await call("savestate_set", ["key": "on"]).isError == true)
        #expect(await call("savestate_set", ["value": true]).isError == true)
        #expect(await call("savestate_set", ["key": "on", "value": true, "persist": "yes"]).isError == true)
    }

    // MARK: - Choosing an app

    @Test func noRunningAppsSaysWhatToDo() async {
        let result = await call("savestate_describe")

        #expect(result.isError == true)
        #expect(text(result).contains("AgentEndpoint.start"))
    }

    @Test func anUnknownToolIsAnError() async {
        #expect(await call("savestate_nope").isError == true)
    }

    @Test func aStaleFileFromADeadProcessIsSkipped() throws {
        let stale = EndpointInfo(
            protocolVersion: WireProtocol.version,
            port: 1,
            token: "t",
            bundleIdentifier: "dead.app",
            appName: "Dead",
            processIdentifier: Int32.max
        )
        try write(stale, to: "dead")

        #expect(AppDiscovery.apps(on: [scratch.device]).isEmpty)
    }

    @Test func aReusedProcessIdentifierWithAClosedPortIsSkipped() async throws {
        let endpoint = try await start()
        var ghost = endpoint.info
        // This process is alive, but nothing listens once the endpoint stops.
        ghost.bundleIdentifier = "ghost.app"
        endpoint.stop()
        try write(ghost, to: "ghost")

        #expect(AppDiscovery.apps(on: [scratch.device]).isEmpty)
    }

    @Test func aDeviceArgumentPicksBetweenSimulators() async throws {
        let endpoint = try await start()
        defer { endpoint.stop() }
        let info = endpoint.info
        let onFirst = DiscoveredApp(endpoint: info, deviceIdentifier: "FIRST")
        var broken = info
        broken.port = 1
        let onSecond = DiscoveredApp(endpoint: broken, deviceIdentifier: "SECOND")
        let tools = BridgeTools(timeout: .seconds(5)) { [onFirst, onSecond] }

        let ambiguous = await tools.call("savestate_describe", arguments: [:])
        #expect(ambiguous.isError == true)
        #expect(text(ambiguous).contains("SECOND"))

        let chosen = await tools.call("savestate_describe", arguments: ["device": "FIRST"])
        #expect(chosen.isError != true)

        let other = await tools.call("savestate_describe", arguments: ["device": "SECOND"])
        #expect(other.isError == true)
        #expect(text(other).contains("relaunch"))

        let unknown = await tools.call("savestate_describe", arguments: ["device": "THIRD"])
        #expect(unknown.isError == true)
        #expect(text(unknown).contains("No running app"))
    }

    @Test func listingAppliesTheFilters() async throws {
        let endpoint = try await start()
        defer { endpoint.stop() }
        let first = DiscoveredApp(endpoint: endpoint.info, deviceIdentifier: "FIRST")
        let second = DiscoveredApp(endpoint: endpoint.info, deviceIdentifier: "SECOND")
        let tools = BridgeTools(timeout: .seconds(5)) { [first, second] }

        let result = await tools.call("savestate_list_apps", arguments: ["device": "SECOND"])

        #expect(text(result).contains("SECOND"))
        #expect(!text(result).contains("FIRST"))
    }

    @Test func aDiscoveryFailureIsReportedOnEveryTool() async {
        let tools = BridgeTools(timeout: .seconds(5)) { throw BridgeError("Check that Xcode is installed.") }

        for name in ["savestate_list_apps", "savestate_describe"] {
            let result = await tools.call(name, arguments: [:])
            #expect(result.isError == true)
            #expect(text(result).contains("Xcode"))
        }
    }

    @Test func severalAppsNeedAnAppArgument() async throws {
        let endpoint = try await start()
        defer { endpoint.stop() }
        var other = endpoint.info
        other.bundleIdentifier = "other.app"
        try write(other, to: "other")

        let ambiguous = await call("savestate_describe")
        #expect(ambiguous.isError == true)
        #expect(text(ambiguous).contains("other.app"))

        let chosen = await call("savestate_describe", ["app": .string(endpoint.info.bundleIdentifier)])
        #expect(chosen.isError != true)

        let missing = await call("savestate_describe", ["app": "absent.app"])
        #expect(missing.isError == true)
    }

    @Test func aDifferentProtocolVersionSaysToRebuild() async throws {
        let endpoint = try await start()
        defer { endpoint.stop() }
        var future = endpoint.info
        future.protocolVersion = WireProtocol.version + 1
        let discovered = DiscoveredApp(endpoint: future, deviceIdentifier: "DEVICE")
        let tools = BridgeTools(timeout: .seconds(5)) { [discovered] }

        let result = await tools.call("savestate_apply_scenario", arguments: ["key": "expired-trial"])

        #expect(result.isError == true)
        #expect(text(result).contains("Rebuild"))
        #expect(model.premium == nil)
    }

    @Test func aWrongTokenSaysTheAppMayHaveRelaunched() async throws {
        let endpoint = try await start()
        defer { endpoint.stop() }
        var stale = endpoint.info
        stale.token = "wrong"
        let discovered = DiscoveredApp(endpoint: stale, deviceIdentifier: "DEVICE")
        let tools = BridgeTools(timeout: .seconds(5)) { [discovered] }

        let result = await tools.call("savestate_apply_scenario", arguments: ["key": "expired-trial"])

        #expect(result.isError == true)
        #expect(text(result).contains("relaunched"))
        #expect(model.premium == nil)
    }

    @Test func aDeadPortSaysTheAppMayHaveQuit() async throws {
        let endpoint = try await start()
        let info = endpoint.info
        endpoint.stop()
        let tools = BridgeTools(timeout: .seconds(5)) {
            [DiscoveredApp(endpoint: info, deviceIdentifier: "DEVICE")]
        }

        let result = await tools.call("savestate_describe", arguments: [:])

        #expect(result.isError == true)
        #expect(text(result).contains("relaunch"))
    }

    // MARK: - Through a real MCP client

    // These live in this serialized suite because a new AgentEndpoint replaces the
    // process's running one.
    private func connectedClient() async throws -> (Client, Server) {
        let (clientSide, serverSide) = await InMemoryTransport.createConnectedPair()
        let server = await Bridge.makeServer(tools: tools)
        try await server.start(transport: serverSide)
        let client = Client(name: "test", version: "1")
        _ = try await client.connect(transport: clientSide)
        return (client, server)
    }

    @Test func anAgentAppliesAScenarioOverMCP() async throws {
        let endpoint = try await start()
        defer { endpoint.stop() }
        let (client, server) = try await connectedClient()

        let (_, isError) = try await client.callTool(name: "savestate_apply_scenario", arguments: ["key": "expired-trial"])

        #expect(isError != true)
        #expect(model.premium == false)
        await client.disconnect()
        await server.stop()
    }

    @Test func aDataURLStringSurvivesTheMCPWireAsText() async throws {
        let endpoint = try await start()
        defer { endpoint.stop() }
        let (client, server) = try await connectedClient()
        let url = "data:text/plain;base64,aGk="

        let (_, isError) = try await client.callTool(name: "savestate_set", arguments: ["key": "name", "value": .string(url)])

        #expect(isError != true)
        #expect(model.name == url)
        await client.disconnect()
        await server.stop()
    }

    private func write(_ info: EndpointInfo, to container: String) throws {
        let file = scratch.container(container).appendingPathComponent(EndpointInfo.relativePath)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(info).write(to: file)
    }
}

@Suite("Simulator listing")
struct SimulatorListingTests {
    @Test func aToolPastItsDeadlineIsStoppedAndReported() {
        let start = ContinuousClock.now

        #expect(throws: BridgeError.self) {
            _ = try AppDiscovery.runTool(URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"], deadline: 0.2)
        }

        #expect(ContinuousClock.now - start < .seconds(5))
    }

    @Test func aFailingToolIsReported() {
        #expect(throws: BridgeError.self) {
            _ = try AppDiscovery.runTool(URL(fileURLWithPath: "/usr/bin/false"), arguments: [])
        }
    }

    @Test func aToolsOutputIsReturned() throws {
        let data = try AppDiscovery.runTool(URL(fileURLWithPath: "/bin/echo"), arguments: ["hi"])

        #expect(String(bytes: data, encoding: .utf8) == "hi\n")
    }

    @Test func malformedListingsThrow() {
        #expect(throws: (any Error).self) {
            _ = try AppDiscovery.parseDevices(Data("not json".utf8))
        }
    }

    @Test func keepsOnlyBootedDevices() throws {
        let json = """
        {"devices":{"iOS-27":[
          {"udid":"A","state":"Booted","dataPath":"/a","name":"One"},
          {"udid":"B","state":"Shutdown","dataPath":"/b","name":"Two"}
        ],"iOS-18":[]}}
        """
        let devices = try AppDiscovery.parseDevices(Data(json.utf8))

        #expect(devices == [SimulatorDevice(identifier: "A", dataPath: URL(fileURLWithPath: "/a"))])
    }
}
