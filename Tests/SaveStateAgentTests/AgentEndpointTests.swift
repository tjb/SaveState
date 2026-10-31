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
    var ratio = 1.0
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

    /// Whether the server closes the connection promptly. The limit is well below
    /// the hello timeout, which would otherwise close it for an unrelated reason.
    func isClosedByServer(within limit: Duration = .seconds(1)) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            let task = task
            group.addTask {
                do {
                    while true {
                        _ = try await task.receive()
                    }
                } catch {
                    return true
                }
            }
            group.addTask {
                try? await Task.sleep(for: limit)
                task.cancel(with: .goingAway, reason: nil)
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            task.cancel(with: .goingAway, reason: nil)
            return result
        }
    }
}

/// Whether a plain TCP connection to the address succeeds, with no server-side
/// behavior involved beyond accepting it.
private func canConnect(host: String, port: UInt16) -> Bool {
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else { return false }
    defer { close(descriptor) }
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else { return false }
    return withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
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
        #expect(!canConnect(host: "127.0.0.1", port: port))
    }

    @Test func stoppingAReplacedEndpointLeavesTheNewOnesFile() async throws {
        let first = try await start()
        let second = try await start()
        defer { second.stop() }
        let url = scratch.container.appendingPathComponent(EndpointInfo.relativePath)

        first.stop()

        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(canConnect(host: "127.0.0.1", port: second.info.port))
        #expect(!canConnect(host: "127.0.0.1", port: first.info.port))
    }

    @Test func overlappingStartsLeaveOneEndpoint() async throws {
        let registry = makeRegistry()
        let container = scratch.container
        async let one = AgentEndpoint.start(registry: registry, container: container)
        async let two = AgentEndpoint.start(registry: registry, container: container)
        let endpoints = try await [one, two].compactMap { $0 }
        #expect(endpoints.count == 2)
        defer { endpoints.forEach { $0.stop() } }

        let url = container.appendingPathComponent(EndpointInfo.relativePath)
        let info = try JSONDecoder().decode(EndpointInfo.self, from: Data(contentsOf: url))
        let open = endpoints.filter { canConnect(host: "127.0.0.1", port: $0.info.port) }
        #expect(open.count == 1)
        #expect(open.first?.info == info)
    }

    @Test func startingWithADisabledRegistryStopsTheRunningEndpoint() async throws {
        let endpoint = try await start()
        let port = endpoint.info.port

        let replacement = try await AgentEndpoint.start(
            registry: makeRegistry(isEnabled: false),
            container: scratch.container
        )

        #expect(replacement == nil)
        #expect(!canConnect(host: "127.0.0.1", port: port))
    }

    @Test func aMacWithNoContainerDoesNotStart() async throws {
        #expect(try await AgentEndpoint.start(registry: makeRegistry()) == nil)
    }

    @Test func aFailedWriteThrowsAndLaterStartsSucceed() async throws {
        let notADirectory = scratch.container.appendingPathComponent("file")
        try FileManager.default.createDirectory(at: scratch.container, withIntermediateDirectories: true)
        try Data().write(to: notADirectory)

        await #expect(throws: (any Error).self) {
            try await AgentEndpoint.start(registry: makeRegistry(), container: notADirectory)
        }

        let endpoint = try await start()
        defer { endpoint.stop() }
        #expect(canConnect(host: "127.0.0.1", port: endpoint.info.port))
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

    @Test func aConnectionThatNeverSaysHelloIsClosed() async throws {
        let endpoint = try await start()
        defer { endpoint.stop() }
        let silent = try Client(port: endpoint.info.port)

        #expect(await silent.isClosedByServer(within: .seconds(7)))
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

    @Test func aSessionWriteToARelaunchControlLastsThroughTheNextLaunchOnly() async throws {
        let endpoint = try await start()
        defer { endpoint.stop() }
        let client = try await connect(endpoint)
        let store = OverrideStore(suiteName: scratch.suiteName)

        #expect(try await perform(.set(key: "mode", value: .string("slow"), persist: false), on: client) == .done)

        func relaunch() -> Mode {
            let relaunched = Model()
            _ = SaveStateRegistry(model: relaunched, store: store, isEnabled: true) { r in
                r.choice("Mode", key: "mode", \.mode, requiresRelaunch: true)
            }
            return relaunched.mode
        }
        #expect(relaunch() == .slow)
        #expect(relaunch() == .fast)
    }

    @Test func anUnencodableResponseReportsAFailure() async throws {
        let model = model
        model.ratio = .infinity
        let registry = SaveStateRegistry(model: model, store: OverrideStore(suiteName: scratch.suiteName), isEnabled: true) { r in
            r.decimal("Ratio", key: "ratio", \.ratio)
            r.toggle("On", key: "on", \.isOn)
        }
        let endpoint = try await start(registry)
        defer { endpoint.stop() }
        let client = try await connect(endpoint)

        #expect(failureCode(try await perform(.describe, on: client)) == .operationFailed)
        guard case .control = try await perform(.read(key: "on"), on: client) else {
            Issue.record("Other controls should still be readable")
            return
        }
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
        #expect(canConnect(host: "127.0.0.1", port: endpoint.info.port))
        // A machine with no other interface has nothing to check.
        guard let address = Self.nonLoopbackAddress() else { return }

        #expect(!canConnect(host: address, port: endpoint.info.port))
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
