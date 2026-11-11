import Foundation
import MCP
import SaveState
@testable import SaveStateAgent
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
    var pending = 0
    var connected = false
    var screen = "home"
    var progress = 0.25
    var lastSync = Date(timeIntervalSince1970: 1_800_000_000)
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
            r.probe("Pending uploads", key: "pending") { model.pending }
            r.probe("Connected", key: "connected") { model.connected }
            r.probe("Screen", key: "screen") { model.screen }
            r.probe("Progress", key: "progress") { model.progress }
            r.probe("Last sync", key: "last-sync") { model.lastSync }
        }
        return try #require(try await AgentEndpoint.start(registry: registry, container: scratch.container()))
    }

    private func call(_ name: String, _ arguments: [String: Value] = [:]) async -> CallTool.Result {
        await tools.call(name, arguments: arguments)
    }

    // MARK: - The tools

    @Test func advertisesTheSevenTools() {
        #expect(Set(BridgeTools.definitions.map(\.name)) == [
            "savestate_list_apps",
            "savestate_describe",
            "savestate_set",
            "savestate_run_action",
            "savestate_apply_scenario",
            "savestate_read",
            "savestate_wait"
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

    // MARK: - Probes

    @Test func describesProbes() async throws {
        let endpoint = try await start()
        defer { endpoint.stop() }

        let result = await call("savestate_describe")

        #expect(text(result).contains("\"probes\""))
        #expect(text(result).contains("Pending uploads"))
    }

    @Test func readFallsBackToAProbe() async throws {
        let endpoint = try await start()
        defer { endpoint.stop() }
        model.pending = 4

        let result = await call("savestate_read", ["key": "pending"])

        #expect(result.isError != true, "\(text(result))")
        #expect(text(result).contains("Pending uploads"))
        #expect(text(result).contains("\"value\" : 4"), "\(text(result))")
        // A probe has no realValue or effectiveValue, so this is the probe's encoding.
        #expect(!text(result).contains("effectiveValue"))
    }

    @Test func readStillPrefersAControl() async throws {
        let endpoint = try await start()
        defer { endpoint.stop() }

        let result = await call("savestate_read", ["key": "count"])

        #expect(text(result).contains("effectiveValue"))
    }

    @Test func readOfAKeyNeitherHasSaysSo() async throws {
        let endpoint = try await start()
        defer { endpoint.stop() }

        let result = await call("savestate_read", ["key": "nope"])

        #expect(result.isError == true)
        #expect(text(result) == "No control or probe has the key \"nope\". Call savestate_describe to see the keys.")
    }

    @Test func waitsUntilAProbeEqualsAValue() async throws {
        let endpoint = try await start()
        defer { endpoint.stop() }
        let model = model
        let change = Task { @MainActor in
            try await Task.sleep(for: .milliseconds(200))
            model.connected = true
        }
        defer { change.cancel() }

        let result = await call("savestate_wait", ["key": "connected", "condition": "equals", "value": true])

        #expect(result.isError != true, "\(text(result))")
        #expect(text(result).contains("\"value\" : true"), "\(text(result))")
        #expect(model.connected)
    }

    @Test func waitsUntilAProbeDiffers() async throws {
        let endpoint = try await start()
        defer { endpoint.stop() }

        let result = await call("savestate_wait", ["key": "screen", "condition": "notEquals", "value": "loading"])

        #expect(result.isError != true, "\(text(result))")
        #expect(text(result).contains("\"home\""))
    }

    @Test func waitsUntilANumberIsAtLeast() async throws {
        let endpoint = try await start()
        defer { endpoint.stop() }
        model.pending = 5

        let int = await call("savestate_wait", ["key": "pending", "condition": "atLeast", "value": 3])
        let double = await call("savestate_wait", ["key": "progress", "condition": "atLeast", "value": 0.25])

        #expect(int.isError != true, "\(text(int))")
        #expect(text(int).contains("\"value\" : 5"), "\(text(int))")
        #expect(double.isError != true, "\(text(double))")
    }

    @Test func waitsUntilADateIsAtMost() async throws {
        let endpoint = try await start()
        defer { endpoint.stop() }

        let result = await call(
            "savestate_wait",
            ["key": "last-sync", "condition": "atMost", "value": "2030-01-01T00:00:00Z"]
        )

        #expect(result.isError != true, "\(text(result))")
        #expect(text(result).contains("Last sync"))
    }

    @Test func aWaitThatTimesOutSaysWhatToTry() async throws {
        let endpoint = try await start()
        defer { endpoint.stop() }

        let result = await call(
            "savestate_wait",
            ["key": "pending", "condition": "equals", "value": 99, "timeoutSeconds": 0.2]
        )

        #expect(result.isError == true)
        #expect(text(result).contains("didn't meet the condition within 200 ms"), "\(text(result))")
        #expect(text(result).contains("savestate_read"))
        #expect(text(result).contains("longer timeoutSeconds"))
    }

    @Test func aConditionThatCantApplySaysWhichDo() async throws {
        let endpoint = try await start()
        defer { endpoint.stop() }

        let result = await call("savestate_wait", ["key": "connected", "condition": "atLeast", "value": true])

        #expect(result.isError == true)
        #expect(text(result).contains("can't apply"), "\(text(result))")
        #expect(text(result).contains("atLeast and atMost apply only to numbers and dates"))
    }

    @Test func aWaitForAnUnknownProbeSaysToDescribe() async throws {
        let endpoint = try await start()
        defer { endpoint.stop() }

        let result = await call("savestate_wait", ["key": "nope", "condition": "equals", "value": 0])

        #expect(result.isError == true)
        #expect(text(result).contains("No probe has the key \"nope\""), "\(text(result))")
        #expect(text(result).contains("Call savestate_describe"))
    }

    @Test func aWaitForAControlSaysItIsAControl() async throws {
        let endpoint = try await start()
        defer { endpoint.stop() }

        let result = await call("savestate_wait", ["key": "count", "condition": "equals", "value": 0])

        #expect(result.isError == true)
        #expect(text(result) == """
        "count" is a control, not a probe. savestate_wait waits only on probes; read a control with savestate_read.
        """)
    }

    @Test func aDataURLStringWaitsAsText() async throws {
        let endpoint = try await start()
        defer { endpoint.stop() }
        let url = "data:text/plain;base64,aGk="
        model.screen = url
        // Decoded from JSON, because that's where the SDK turns it into data.
        let value = try JSONDecoder().decode(Value.self, from: JSONEncoder().encode(url))

        let result = await call("savestate_wait", ["key": "screen", "condition": "equals", "value": value])

        #expect(result.isError != true, "\(text(result))")
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

    @Test func aCallLeavesNoConnectionOpen() async throws {
        let endpoint = try await start()
        defer { endpoint.stop() }

        #expect(await call("savestate_describe").isError != true)

        // Discovery's port check opens a connection that never says hello, which the
        // endpoint drops at its 5 second hello timeout. A connection the call itself
        // left open has said hello, so it would outlast this wait.
        var waited = Duration.zero
        while endpoint.connectionCount > 0, waited < .seconds(8) {
            try await Task.sleep(for: .milliseconds(50))
            waited += .milliseconds(50)
        }
        #expect(endpoint.connectionCount == 0)
    }

    @Test func aSetWithNoValueLeavesTheOverrideAlone() async throws {
        let endpoint = try await start()
        defer { endpoint.stop() }
        model.premium = true

        let result = await call("savestate_set", ["key": "premium"])

        #expect(result.isError == true)
        #expect(model.premium == true)
    }

    @Test func successMessagesNameWhatRan() async throws {
        let endpoint = try await start()
        defer { endpoint.stop() }

        #expect(text(await call("savestate_run_action", ["key": "run"])).contains("run"))
        #expect(text(await call("savestate_apply_scenario", ["key": "expired-trial"])).contains("expired-trial"))
    }

    @Test func runActionsDescriptionWarnsAboutDestructiveActions() throws {
        let tool = try #require(BridgeTools.definitions.first { $0.name == "savestate_run_action" })

        #expect(tool.description?.contains("destructive") == true)
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

        // A listener closes asynchronously, so the port may stay open for a moment.
        var apps = AppDiscovery.apps(on: [scratch.device])
        var waited = Duration.zero
        while !apps.isEmpty, waited < .seconds(3) {
            try await Task.sleep(for: .milliseconds(25))
            waited += .milliseconds(25)
            apps = AppDiscovery.apps(on: [scratch.device])
        }
        #expect(apps.isEmpty)
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
        let tools = BridgeTools(timeout: .seconds(5)) { throw BridgeError(.discoveryFailed, "Check that Xcode is installed.") }

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
        // Wait until the port is really closed: a listener closes asynchronously.
        var waited = Duration.zero
        while !AppDiscovery.apps(on: [scratch.device]).isEmpty, waited < .seconds(3) {
            try await Task.sleep(for: .milliseconds(25))
            waited += .milliseconds(25)
        }
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
