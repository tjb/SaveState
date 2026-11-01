import Foundation
import MCP
import Network
import SaveStateProtocol
import Testing
@testable import SaveStateBridgeKit

/// A loopback server that misbehaves on demand, to reach failures the real endpoint
/// can't produce.
final class FakeEndpoint: Sendable {
    enum Behavior: Sendable {
        /// Accepts TCP and never completes the WebSocket upgrade, the way an app with
        /// a blocked main queue looks.
        case neverUpgrades
        /// Upgrades, then never answers, the way an app stopped in a debugger looks.
        case silent
        /// Upgrades, then hangs up when the hello arrives.
        case closesAfterHello
        /// Answers the hello with something that isn't JSON.
        case garbageHello
        /// Rejects the hello with this error.
        case rejects(WireError)
        /// Accepts the hello, then answers with this envelope.
        case answers(ResponseEnvelope)
        /// Accepts the hello, then hangs up when the request arrives.
        case closesAfterRequest
        /// Accepts the hello, then answers with something that isn't JSON.
        case garbageResponse
        /// Accepts the hello, then answers with this envelope in a binary frame.
        case answersInBinary(ResponseEnvelope)
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "FakeEndpoint")
    let port: UInt16

    init(_ behavior: Behavior) async throws {
        let parameters: NWParameters
        if case .neverUpgrades = behavior {
            parameters = .tcp
        } else {
            parameters = .tcp
            parameters.defaultProtocolStack.applicationProtocols.insert(NWProtocolWebSocket.Options(), at: 0)
        }
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        let queue = queue
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            Self.serve(connection, behavior: behavior, step: 0)
        }
        port = try await withCheckedThrowingContinuation { continuation in
            nonisolated(unsafe) var pending: CheckedContinuation<UInt16, any Error>? = continuation
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    pending?.resume(returning: listener.port?.rawValue ?? 0)
                    pending = nil
                case .failed(let error):
                    pending?.resume(throwing: error)
                    pending = nil
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    deinit {
        listener.cancel()
    }

    func app() -> DiscoveredApp {
        DiscoveredApp(
            endpoint: EndpointInfo(
                protocolVersion: WireProtocol.version,
                port: port,
                token: "token",
                bundleIdentifier: "fake.app",
                appName: "Fake",
                processIdentifier: ProcessInfo.processInfo.processIdentifier
            ),
            deviceIdentifier: "DEVICE"
        )
    }

    private static func serve(_ connection: NWConnection, behavior: Behavior, step: Int) {
        if case .neverUpgrades = behavior { return }
        connection.receiveMessage { _, _, _, error in
            guard error == nil else { return }
            switch (behavior, step) {
            case (.closesAfterHello, _), (.closesAfterRequest, 1):
                connection.cancel()
            case (.garbageHello, _), (.garbageResponse, 1):
                send(Data("not json".utf8), on: connection)
            case (.rejects(let wireError), _):
                send(ServerHello.rejected(error: wireError), on: connection)
            case (.answers, 0), (.closesAfterRequest, 0), (.garbageResponse, 0), (.answersInBinary, 0):
                send(ServerHello.accepted, on: connection)
                serve(connection, behavior: behavior, step: 1)
            case (.answersInBinary(let envelope), _):
                guard let data = try? JSONEncoder().encode(envelope) else { return }
                send(data, on: connection, opcode: .binary)
            case (.answers(let envelope), _):
                send(envelope, on: connection)
            default:
                break
            }
        }
    }

    private static func send(_ message: some Encodable, on connection: NWConnection) {
        guard let data = try? JSONEncoder().encode(message) else { return }
        send(data, on: connection)
    }

    private static func send(_ data: Data, on connection: NWConnection, opcode: NWProtocolWebSocket.Opcode = .text) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: opcode)
        let context = NWConnection.ContentContext(identifier: "message", metadata: [metadata])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .idempotent)
    }
}

private func text(_ result: CallTool.Result) -> String {
    result.content.compactMap { content -> String? in
        if case .text(let text, _, _) = content { return text }
        return nil
    }
    .joined()
}

@Suite("Misbehaving endpoints")
struct MisbehavingEndpointTests {
    private func call(
        _ behavior: FakeEndpoint.Behavior,
        timeout: Duration = .seconds(5),
        tool: String = "savestate_describe",
        arguments: [String: Value] = [:]
    ) async throws -> CallTool.Result {
        let endpoint = try await FakeEndpoint(behavior)
        let app = endpoint.app()
        let tools = BridgeTools(timeout: timeout) { [app] }
        let result = await tools.call(tool, arguments: arguments)
        _ = endpoint
        return result
    }

    @Test func aSilentAppTimesOutOnTime() async throws {
        let start = ContinuousClock.now

        let result = try await call(.silent, timeout: .seconds(1))

        #expect(result.isError == true)
        #expect(text(result).contains("didn't answer in time"))
        #expect(ContinuousClock.now - start < .seconds(15))
    }

    @Test func anAppThatNeverUpgradesTimesOutOnTime() async throws {
        let start = ContinuousClock.now

        let result = try await call(.neverUpgrades, timeout: .seconds(1))

        #expect(result.isError == true)
        #expect(text(result).contains("didn't answer in time"))
        #expect(ContinuousClock.now - start < .seconds(15))
    }

    @Test func cancellingACallStopsItPromptly() async throws {
        let endpoint = try await FakeEndpoint(.silent)
        let app = endpoint.app()
        let tools = BridgeTools(timeout: .seconds(60)) { [app] }
        let start = ContinuousClock.now

        let call = Task { await tools.call("savestate_describe", arguments: [:]) }
        try await Task.sleep(for: .milliseconds(300))
        call.cancel()
        _ = await call.value

        #expect(ContinuousClock.now - start < .seconds(15))
    }

    @Test func anAppThatHangsUpSaysToRelaunch() async throws {
        let result = try await call(.closesAfterHello)

        #expect(result.isError == true)
        #expect(text(result).contains("relaunch"), "\(text(result))")
        #expect(!text(result).contains("NSPOSIXErrorDomain"))
    }

    @Test func anAppThatDiesMidRequestSaysToRelaunch() async throws {
        let result = try await call(.closesAfterRequest)

        #expect(result.isError == true)
        #expect(text(result).contains("relaunch"), "\(text(result))")
    }

    @Test func anUnreadableReplySaysToRebuild() async throws {
        let result = try await call(.garbageHello)

        #expect(result.isError == true)
        #expect(text(result).contains("Rebuild"), "\(text(result))")
        #expect(!text(result).contains("DecodingError"))
    }

    @Test func aRejectedVersionSaysToRebuild() async throws {
        let result = try await call(.rejects(WireError(code: .protocolMismatch, message: "Versions differ.")))

        #expect(result.isError == true)
        #expect(text(result).contains("Versions differ."))
        #expect(text(result).contains("Rebuild"))
    }

    @Test func aRejectedTokenSaysTheAppMayHaveRelaunched() async throws {
        let result = try await call(.rejects(WireError(code: .unauthorized, message: "The token is wrong.")))

        #expect(result.isError == true)
        #expect(text(result).contains("relaunched"))
    }

    @Test func aReplyToADifferentRequestIsNotAccepted() async throws {
        let wrong = ResponseEnvelope(id: 99, result: .description(registry: RegistryDescription(controls: [], actions: [], scenarios: [])))

        let result = try await call(.answers(wrong))

        #expect(result.isError == true)
        #expect(text(result).contains("different request"))
    }

    @Test func aFailureWithNoRequestIdentifierIsReported() async throws {
        let failure = ResponseEnvelope(id: nil, result: .failure(error: WireError(code: .badRequest, message: "Bad message.")))

        let result = try await call(.answers(failure))

        #expect(result.isError == true)
        #expect(text(result).contains("Bad message."))
    }

    @Test func theWrongKindOfResultIsReported() async throws {
        let wrong = ResponseEnvelope(id: 1, result: .done)

        let result = try await call(.answers(wrong))

        #expect(result.isError == true)
        #expect(text(result).contains("unexpected response"))
    }

    @Test func aGarbledResponseAfterTheHelloSaysToRebuild() async throws {
        let result = try await call(.garbageResponse)

        #expect(result.isError == true)
        #expect(text(result).contains("Rebuild"), "\(text(result))")
    }

    @Test func aBinaryFrameIsReadTheSameAsText() async throws {
        let registry = RegistryDescription(controls: [], actions: [], scenarios: [])
        let envelope = ResponseEnvelope(id: 1, result: .description(registry: registry))

        let result = try await call(.answersInBinary(envelope))

        #expect(result.isError != true, "\(text(result))")
        #expect(text(result).contains("scenarios"))
    }

    @Test func aReadAnsweredWithTheWrongResultIsReported() async throws {
        let result = try await call(.answers(ResponseEnvelope(id: 1, result: .done)), tool: "savestate_read", arguments: ["key": "on"])

        #expect(result.isError == true)
        #expect(text(result).contains("unexpected response"))
    }

    @Test func anActionAnsweredWithTheWrongResultIsNotReportedAsRun() async throws {
        let wrong = ResponseEnvelope(id: 1, result: .description(registry: RegistryDescription(controls: [], actions: [], scenarios: [])))

        let result = try await call(.answers(wrong), tool: "savestate_run_action", arguments: ["key": "run"])

        #expect(result.isError == true)
        #expect(text(result).contains("unexpected response"))
    }

    @Test func aScenarioAnsweredWithTheWrongResultIsNotReportedAsApplied() async throws {
        let wrong = ResponseEnvelope(id: 1, result: .description(registry: RegistryDescription(controls: [], actions: [], scenarios: [])))

        let result = try await call(.answers(wrong), tool: "savestate_apply_scenario", arguments: ["key": "expired-trial"])

        #expect(result.isError == true)
        #expect(!text(result).contains("Applied"))
    }

    @Test func aRequestFailureOfAnyOtherCodeKeepsTheAppsOwnMessage() async throws {
        let failure = ResponseEnvelope(id: 1, result: .failure(error: WireError(code: .unknownScenario, message: "No scenario has the key.")))

        let result = try await call(.answers(failure), tool: "savestate_apply_scenario", arguments: ["key": "nope"])

        #expect(result.isError == true)
        #expect(text(result) == "No scenario has the key.")
    }
}

/// How `BridgeTools` reports failures that don't come from an app.
@Suite("Bridge tool arguments and failures")
struct BridgeToolFailureTests {
    private struct Unexpected: Error, CustomStringConvertible {
        var description: String { "something unexpected" }
    }

    private func app(protocolVersion: Int = WireProtocol.version) -> DiscoveredApp {
        DiscoveredApp(
            endpoint: EndpointInfo(
                protocolVersion: protocolVersion,
                port: 1,
                token: "t",
                bundleIdentifier: "one.app",
                appName: "One",
                processIdentifier: 1
            ),
            deviceIdentifier: "DEVICE"
        )
    }

    @Test func aNonStringAppArgumentIsRejected() async {
        let running = app()
        let tools = BridgeTools(timeout: .seconds(1)) { [running] }

        let result = await tools.call("savestate_list_apps", arguments: ["app": 3])

        #expect(result.isError == true)
        #expect(text(result) == "app must be a string.")
    }

    @Test func aNonStringKeyIsRejected() async {
        let tools = BridgeTools(timeout: .seconds(1)) { [] }

        let result = await tools.call("savestate_read", arguments: ["key": 3])

        #expect(text(result) == "key must be a string.")
    }

    @Test func aMissingKeyIsRejectedBeforeAnyAppIsContacted() async {
        let tools = BridgeTools(timeout: .seconds(1)) { [] }

        let result = await tools.call("savestate_apply_scenario", arguments: [:])

        #expect(text(result) == "This tool needs key.")
    }

    @Test func anUnknownErrorIsStillAnErrorResult() async {
        let tools = BridgeTools(timeout: .seconds(1)) { throw Unexpected() }

        let result = await tools.call("savestate_list_apps", arguments: [:])

        #expect(result.isError == true)
        #expect(text(result) == "something unexpected")
    }

    @Test func aFutureAppIsStillListedSoTheAgentCanSeeIt() async {
        let future = app(protocolVersion: WireProtocol.version + 1)
        let tools = BridgeTools(timeout: .seconds(1)) { [future] }

        let result = await tools.call("savestate_list_apps", arguments: [:])

        #expect(result.isError != true)
        #expect(text(result).contains("one.app"))
    }

    @Test func listingSeveralAppsNeedsNoArgument() async {
        let first = app()
        var second = app()
        second.endpoint.bundleIdentifier = "two.app"
        let running = [first, second]
        let tools = BridgeTools(timeout: .seconds(1)) { running }

        let result = await tools.call("savestate_list_apps", arguments: [:])

        #expect(text(result).contains("one.app"))
        #expect(text(result).contains("two.app"))
    }
}
