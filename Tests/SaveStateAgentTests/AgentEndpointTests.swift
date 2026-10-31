#if DEBUG
import Foundation
import SaveState
import SaveStateProtocol
import Testing
@testable import SaveStateAgent

private enum Mode: String, CaseIterable {
    case fast
    case slow
}

@MainActor
private final class Model {
    var isOn = false
    var mode = Mode.fast
    var runs = 0
    var scenarioRuns = 0
}

private enum Boom: Error {
    case failed
}

/// A scratch container and `UserDefaults` suite, removed when the test ends.
private final class Scratch: Sendable {
    let suiteName = "SaveStateAgentTests.\(UUID().uuidString)"
    let container = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)

    deinit {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: container)
    }
}

/// A plain WebSocket client, independent of the server's implementation.
private final class Client: Sendable {
    private let task: URLSessionWebSocketTask

    init(port: UInt16, host: String = "127.0.0.1") throws {
        let url = try #require(URL(string: "ws://\(host):\(port)"))
        task = URLSession.shared.webSocketTask(with: url)
        task.resume()
    }

    deinit {
        task.cancel(with: .goingAway, reason: nil)
    }

    func sendRaw(_ text: String) async throws {
        try await task.send(.string(text))
    }

    func send(_ message: some Encodable) async throws {
        try await sendRaw(String(bytes: try JSONEncoder().encode(message), encoding: .utf8) ?? "")
    }

    func receive<Message: Decodable>(_ type: Message.Type) async throws -> Message {
        switch try await task.receive() {
        case .string(let text):
            return try JSONDecoder().decode(type, from: Data(text.utf8))
        case .data(let data):
            return try JSONDecoder().decode(type, from: data)
        @unknown default:
            throw Boom.failed
        }
    }

    /// Whether the server has closed the connection.
    func isClosedByServer() async -> Bool {
        do {
            _ = try await task.receive()
            return false
        } catch {
            return true
        }
    }
}

@Suite("Agent endpoint", .serialized)
@MainActor
struct AgentEndpointTests {
    private let scratch = Scratch()
    private let model = Model()

    private func makeRegistry(isEnabled: Bool = true) -> SaveStateRegistry {
        let model = model
        return SaveStateRegistry(
            model: model,
            store: OverrideStore(suiteName: scratch.suiteName),
            isEnabled: isEnabled
        ) { r in
            r.toggle("On", key: "on", \.isOn)
            r.choice("Mode", key: "mode", \.mode, requiresRelaunch: true)
            r.action("Run", key: "run") { model.runs += 1 }
            r.action("Erase", key: "erase", destructive: true) { model.runs = 0 }
            r.action("Throw", key: "throw") { throw Boom.failed }
            r.scenario("Expired", key: "expired") { state in state.scenarioRuns += 1 }
        }
    }

    private func start(_ registry: SaveStateRegistry? = nil) async throws -> AgentEndpoint {
        try #require(try await AgentEndpoint.start(registry: registry ?? makeRegistry(), container: scratch.container))
    }

    private func connect(_ endpoint: AgentEndpoint) async throws -> Client {
        let client = try Client(port: endpoint.info.port)
        try await client.send(ClientHello(protocolVersion: WireProtocol.version, token: endpoint.info.token))
        #expect(try await client.receive(ServerHello.self) == .accepted)
        return client
    }

    private func perform(_ request: WireRequest, on client: Client, id: Int = 1) async throws -> WireResult {
        try await client.send(RequestEnvelope(id: id, request: request))
        let response = try await client.receive(ResponseEnvelope.self)
        #expect(response.id == id)
        return response.result
    }

    private func failureCode(_ result: WireResult) -> WireError.Code? {
        if case .failure(let error) = result { return error.code }
        return nil
    }

    // MARK: - Endpoint file

    @Test func writesAPrivateEndpointFile() async throws {
        let endpoint = try await start()
        defer { endpoint.stop() }

        let url = scratch.container.appendingPathComponent(EndpointInfo.relativePath)
        let info = try JSONDecoder().decode(EndpointInfo.self, from: Data(contentsOf: url))
        #expect(info == endpoint.info)
        #expect(info.protocolVersion == WireProtocol.version)
        #expect(info.processIdentifier == ProcessInfo.processInfo.processIdentifier)
        #expect(info.token.count == 64)

        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func stopRemovesTheFileAndRefusesConnections() async throws {
        let endpoint = try await start()
        let url = scratch.container.appendingPathComponent(EndpointInfo.relativePath)
        let port = endpoint.info.port

        endpoint.stop()

        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(await (try Client(port: port)).isClosedByServer())
    }

    @Test func eachStartHasANewToken() async throws {
        let first = try await start()
        let token = first.info.token
        let second = try await start()
        defer { second.stop() }

        #expect(second.info.token != token)
    }

    @Test func aDisabledRegistryDoesNotStart() async throws {
        let endpoint = try await AgentEndpoint.start(
            registry: makeRegistry(isEnabled: false),
            container: scratch.container
        )

        #expect(endpoint == nil)
        let url = scratch.container.appendingPathComponent(EndpointInfo.relativePath)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: - Authentication

    @Test func aWrongTokenIsRejectedAndClosed() async throws {
        let endpoint = try await start()
        defer { endpoint.stop() }
        let client = try Client(port: endpoint.info.port)

        try await client.send(ClientHello(protocolVersion: WireProtocol.version, token: "wrong"))

        guard case .rejected(let error) = try await client.receive(ServerHello.self) else {
            Issue.record("Expected a rejection")
            return
        }
        #expect(error.code == .unauthorized)
        #expect(await client.isClosedByServer())
    }

    @Test func aRequestBeforeHelloDoesNothing() async throws {
        let endpoint = try await start()
        defer { endpoint.stop() }
        let client = try Client(port: endpoint.info.port)

        try await client.send(RequestEnvelope(id: 1, request: .applyScenario(key: "expired")))

        guard case .rejected(let error) = try await client.receive(ServerHello.self) else {
            Issue.record("Expected a rejection")
            return
        }
        #expect(error.code == .unauthorized)
        #expect(model.scenarioRuns == 0)
        #expect(await client.isClosedByServer())
    }

    @Test func aDifferentProtocolVersionIsRejected() async throws {
        let endpoint = try await start()
        defer { endpoint.stop() }
        let client = try Client(port: endpoint.info.port)

        try await client.send(ClientHello(protocolVersion: WireProtocol.version + 1, token: endpoint.info.token))

        guard case .rejected(let error) = try await client.receive(ServerHello.self) else {
            Issue.record("Expected a rejection")
            return
        }
        #expect(error.code == .protocolMismatch)
    }

    // MARK: - Requests

    @Test func describesAndReads() async throws {
        let endpoint = try await start()
        defer { endpoint.stop() }
        let client = try await connect(endpoint)

        guard case .description(let description) = try await perform(.describe, on: client) else {
            Issue.record("Expected a description")
            return
        }
        #expect(description.controls.map(\.key) == ["on", "mode"])
        #expect(description.scenarios.map(\.key) == ["expired"])

        guard case .control(let control) = try await perform(.read(key: "on"), on: client) else {
            Issue.record("Expected a control")
            return
        }
        #expect(control.value == .bool(false))
        #expect(failureCode(try await perform(.read(key: "nope"), on: client)) == .unknownControl)
    }

    @Test func aSessionWriteDoesNotOutlastTheLaunch() async throws {
        let endpoint = try await start()
        defer { endpoint.stop() }
        let client = try await connect(endpoint)

        #expect(try await perform(.set(key: "on", value: .bool(true), persist: false), on: client) == .done)

        #expect(model.isOn)
        let relaunched = Model()
        _ = SaveStateRegistry(model: relaunched, store: OverrideStore(suiteName: scratch.suiteName), isEnabled: true) { r in
            r.toggle("On", key: "on", \.isOn)
        }
        #expect(!relaunched.isOn)
    }

    @Test func aPersistedWriteOutlastsTheLaunch() async throws {
        let endpoint = try await start()
        defer { endpoint.stop() }
        let client = try await connect(endpoint)

        #expect(try await perform(.set(key: "on", value: .bool(true), persist: true), on: client) == .done)

        let relaunched = Model()
        _ = SaveStateRegistry(model: relaunched, store: OverrideStore(suiteName: scratch.suiteName), isEnabled: true) { r in
            r.toggle("On", key: "on", \.isOn)
        }
        #expect(relaunched.isOn)
    }

    @Test func aBadValueIsReported() async throws {
        let endpoint = try await start()
        defer { endpoint.stop() }
        let client = try await connect(endpoint)

        let result = try await perform(.set(key: "on", value: .string("x"), persist: false), on: client)

        #expect(failureCode(result) == .invalidValue)
    }

    @Test func destructiveActionsAreRefused() async throws {
        let endpoint = try await start()
        defer { endpoint.stop() }
        let client = try await connect(endpoint)
        model.runs = 3

        let result = try await perform(.runAction(key: "erase"), on: client)

        #expect(failureCode(result) == .destructiveActionNotAllowed)
        #expect(model.runs == 3)
    }

    @Test func runsActionsAndReportsTheirFailures() async throws {
        let endpoint = try await start()
        defer { endpoint.stop() }
        let client = try await connect(endpoint)

        #expect(try await perform(.runAction(key: "run"), on: client) == .done)
        #expect(model.runs == 1)
        #expect(failureCode(try await perform(.runAction(key: "throw"), on: client)) == .operationFailed)
        #expect(failureCode(try await perform(.runAction(key: "nope"), on: client)) == .unknownAction)
    }

    @Test func appliesScenarios() async throws {
        let endpoint = try await start()
        defer { endpoint.stop() }
        let client = try await connect(endpoint)

        #expect(try await perform(.applyScenario(key: "expired"), on: client) == .done)
        #expect(model.scenarioRuns == 1)
        #expect(failureCode(try await perform(.applyScenario(key: "nope"), on: client)) == .unknownScenario)
    }

    @Test func aMalformedMessageIsReportedAndTheConnectionSurvives() async throws {
        let endpoint = try await start()
        defer { endpoint.stop() }
        let client = try await connect(endpoint)

        try await client.sendRaw("not json")
        let response = try await client.receive(ResponseEnvelope.self)

        #expect(response.id == nil)
        #expect(failureCode(response.result) == .badRequest)
        #expect(try await perform(.runAction(key: "run"), on: client) == .done)
    }

    // MARK: - Network exposure

    @Test func onlyListensOnLoopback() async throws {
        let endpoint = try await start()
        defer { endpoint.stop() }
        guard let address = Self.nonLoopbackAddress() else { return }

        #expect(await (try Client(port: endpoint.info.port, host: address)).isClosedByServer())
    }

    /// This Mac's first non-loopback IPv4 address, if it has one.
    private static func nonLoopbackAddress() -> String? {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0 else { return nil }
        defer { freeifaddrs(first) }
        var next = first
        while let current = next {
            defer { next = current.pointee.ifa_next }
            guard let address = current.pointee.ifa_addr,
                  address.pointee.sa_family == sa_family_t(AF_INET),
                  current.pointee.ifa_flags & UInt32(IFF_LOOPBACK) == 0,
                  current.pointee.ifa_flags & UInt32(IFF_UP) != 0
            else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else {
                continue
            }
            return String(bytes: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, encoding: .utf8)
        }
        return nil
    }
}
#endif
