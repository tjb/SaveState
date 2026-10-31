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

    func sendBinary(_ data: Data) async throws {
        try await task.send(.data(data))
    }

    /// Waits for the server's pong, and throws if the connection ends first.
    func ping() async throws {
        let task = task
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            task.sendPing { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    /// Disconnects abruptly, as a bridge that was killed would.
    func disconnect() {
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

/// Lets a test hold an action open and see when it arrives.
private actor Gate {
    private var hasArrived = false
    private var isReleased = false
    private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    /// Called by the action: reports arrival, then waits for the release.
    func arrive() async {
        hasArrived = true
        arrivalWaiters.forEach { $0.resume() }
        arrivalWaiters.removeAll()
        if !isReleased {
            await withCheckedContinuation { releaseWaiters.append($0) }
        }
    }

    func waitForArrival() async {
        if !hasArrived {
            await withCheckedContinuation { arrivalWaiters.append($0) }
        }
    }

    func release() {
        isReleased = true
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters.removeAll()
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

#if os(macOS)
/// The TCP addresses this process listens on, such as `127.0.0.1:8080`, as the
/// system reports them. This sees the bound socket itself, so it doesn't depend on
/// which network interfaces the machine has. Bounded, so a stuck `lsof` fails the
/// test rather than hanging it.
private func listeningAddresses() throws -> Set<String> {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
    process.arguments = ["-nP", "-a", "-p", "\(ProcessInfo.processInfo.processIdentifier)", "-iTCP", "-sTCP:LISTEN", "-Fn"]
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    try process.run()
    let timer = DispatchWorkItem { process.terminate() }
    DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: timer)
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    timer.cancel()
    return Set(
        (String(bytes: data, encoding: .utf8) ?? "")
            .split(separator: "\n")
            .filter { $0.hasPrefix("n") }
            .map { String($0.dropFirst()) }
    )
}
#endif

/// This Mac's first non-loopback IPv4 address, if it has one.
private func nonLoopbackAddress() -> String? {
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

/// Ways a presented token can differ from the real one.
private enum WrongToken: String, CaseIterable, CustomTestStringConvertible {
    case empty
    case missingLastCharacter
    case oneCharacterTooLong
    case wrongFirstCharacter
    case wrongMiddleCharacter
    case wrongLastCharacter

    var testDescription: String { rawValue }

    func applied(to token: String) -> String {
        func changed(_ character: Character) -> String { character == "0" ? "1" : "0" }
        let middle = token.index(token.startIndex, offsetBy: token.count / 2)
        switch self {
        case .empty:
            return ""
        case .missingLastCharacter:
            return String(token.dropLast())
        case .oneCharacterTooLong:
            return token + "0"
        case .wrongFirstCharacter:
            return changed(token[token.startIndex]) + token.dropFirst()
        case .wrongMiddleCharacter:
            return token[..<middle] + changed(token[middle]) + token[token.index(after: middle)...]
        case .wrongLastCharacter:
            return token.dropLast() + changed(token[token.index(before: token.endIndex)])
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

    @Test func theEndpointFilesDirectoryIsPrivate() async throws {
        let endpoint = try await start()
        defer { endpoint.stop() }

        let folder = scratch.container.appendingPathComponent(EndpointInfo.relativePath).deletingLastPathComponent()
        let attributes = try FileManager.default.attributesOfItem(atPath: folder.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
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

    #if os(macOS)
    @Test func aFailedWriteLeavesNothingListening() async throws {
        let notADirectory = scratch.container.appendingPathComponent("file")
        try FileManager.default.createDirectory(at: scratch.container, withIntermediateDirectories: true)
        try Data().write(to: notADirectory)
        let before = try listeningAddresses()

        await #expect(throws: (any Error).self) {
            try await AgentEndpoint.start(registry: makeRegistry(), container: notADirectory)
        }

        // The cancelled listener closes its socket on its own schedule.
        let deadline = ContinuousClock.now + .seconds(2)
        var added = try listeningAddresses().subtracting(before)
        while !added.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
            added = try listeningAddresses().subtracting(before)
        }
        #expect(added.isEmpty)
    }
    #endif

    @Test func aContainerItCantCreateTheFileInThrowsTheWriteError() async throws {
        // The directory exists but is read-only, so only creating the file can fail.
        let folder = scratch.container
            .appendingPathComponent(EndpointInfo.relativePath)
            .deletingLastPathComponent()
        let manager = FileManager.default
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        try manager.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
        defer { try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path) }

        await #expect(throws: CocoaError(.fileWriteUnknown)) {
            try await AgentEndpoint.start(registry: makeRegistry(), container: scratch.container)
        }
    }

    @Test func aStaleFileIsReplaced() async throws {
        let url = scratch.container.appendingPathComponent(EndpointInfo.relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("left behind by a crash".utf8).write(to: url)

        let endpoint = try await start()
        defer { endpoint.stop() }

        let info = try JSONDecoder().decode(EndpointInfo.self, from: Data(contentsOf: url))
        #expect(info == endpoint.info)
    }

    @Test func aStaleWorldReadableFileDoesNotKeepItsPermissions() async throws {
        let url = scratch.container.appendingPathComponent(EndpointInfo.relativePath)
        let manager = FileManager.default
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        #expect(manager.createFile(atPath: url.path, contents: Data("stale".utf8), attributes: [.posixPermissions: 0o644]))

        let endpoint = try await start()
        defer { endpoint.stop() }

        let attributes = try manager.attributesOfItem(atPath: url.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func stoppingTwiceLeavesALaterEndpointsFile() async throws {
        let first = try await start()
        first.stop()
        let second = try await start()
        defer { second.stop() }

        first.stop()

        let url = scratch.container.appendingPathComponent(EndpointInfo.relativePath)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test func stoppingClosesConnectedClients() async throws {
        let endpoint = try await start()
        let client = try await connect(endpoint)

        endpoint.stop()

        #expect(await client.isClosedByServer())
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

    @Test(arguments: WrongToken.allCases)
    private func aTokenThatDiffersAnywhereIsRejected(_ wrongToken: WrongToken) async throws {
        let endpoint = try await start()
        defer { endpoint.stop() }
        let client = try Client(port: endpoint.info.port)
        let wrong = wrongToken.applied(to: endpoint.info.token)
        #expect(wrong != endpoint.info.token)

        try await client.send(ClientHello(protocolVersion: WireProtocol.version, token: wrong))

        guard case .rejected(let error) = try await client.receive(ServerHello.self) else {
            Issue.record("Expected a rejection")
            return
        }
        #expect(error.code == .unauthorized)
    }

    @Test func anAuthenticatedClientOutlivesTheHelloTimeout() async throws {
        let endpoint = try await start()
        defer { endpoint.stop() }
        let client = try await connect(endpoint)

        // Longer than the endpoint's 5 second hello timeout.
        try await Task.sleep(for: .seconds(6))

        #expect(try await perform(.runAction(key: "run"), on: client) == .done)
    }

    @Test func aHelloInABinaryFrameIsAccepted() async throws {
        let endpoint = try await start()
        defer { endpoint.stop() }
        let client = try Client(port: endpoint.info.port)
        let hello = ClientHello(protocolVersion: WireProtocol.version, token: endpoint.info.token)

        try await client.sendBinary(try JSONEncoder().encode(hello))

        #expect(try await client.receive(ServerHello.self) == .accepted)
    }

    @Test func aPingBeforeHelloIsAnsweredAndDoesNotCountAsAHello() async throws {
        let endpoint = try await start()
        defer { endpoint.stop() }
        let client = try Client(port: endpoint.info.port)

        try await client.ping()

        try await client.send(ClientHello(protocolVersion: WireProtocol.version, token: endpoint.info.token))
        #expect(try await client.receive(ServerHello.self) == .accepted)
    }

    // MARK: - Requests

    @Test func aResponseCarriesItsRequestsIdentifier() async throws {
        let endpoint = try await start()
        defer { endpoint.stop() }
        let client = try await connect(endpoint)

        try await client.send(RequestEnvelope(id: 42, request: .runAction(key: "run")))

        #expect(try await client.receive(ResponseEnvelope.self).id == 42)
    }

    @Test func aSecondHelloAfterAuthenticatingIsABadRequest() async throws {
        let endpoint = try await start()
        defer { endpoint.stop() }
        let client = try await connect(endpoint)

        try await client.send(ClientHello(protocolVersion: WireProtocol.version, token: endpoint.info.token))

        #expect(failureCode(try await client.receive(ResponseEnvelope.self).result) == .badRequest)
    }

    @Test func pipelinedRequestsAreAnsweredInOrder() async throws {
        let registry = SaveStateRegistry(model: model, store: OverrideStore(suiteName: scratch.suiteName), isEnabled: true) { r in
            r.toggle("On", key: "on", \.isOn)
            r.action("Slow", key: "slow") { try await Task.sleep(for: .milliseconds(200)) }
        }
        let endpoint = try await start(registry)
        defer { endpoint.stop() }
        let client = try await connect(endpoint)

        try await client.send(RequestEnvelope(id: 1, request: .runAction(key: "slow")))
        try await client.send(RequestEnvelope(id: 2, request: .read(key: "on")))

        #expect(try await client.receive(ResponseEnvelope.self).id == 1)
        #expect(try await client.receive(ResponseEnvelope.self).id == 2)
    }

    // MARK: - Disconnection

    /// A registry whose `wait` action holds the request open until the test releases it.
    private func makeGatedRegistry(_ gate: Gate) -> SaveStateRegistry {
        let model = model
        return SaveStateRegistry(model: model, store: OverrideStore(suiteName: scratch.suiteName), isEnabled: true) { r in
            r.action("Wait", key: "wait") {
                await gate.arrive()
                model.runs += 1
            }
            r.action("Other", key: "other") { model.scenarioRuns += 1 }
        }
    }

    /// Polls, because the held action finishes on its own schedule after release.
    private func actionFinished(within limit: Duration = .seconds(2)) async -> Bool {
        let deadline = ContinuousClock.now + limit
        while model.runs == 0, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return model.runs == 1
    }

    @Test(.timeLimit(.minutes(1))) func aClientThatDisconnectsMidRequestLeavesTheEndpointServing() async throws {
        let gate = Gate()
        let endpoint = try await start(makeGatedRegistry(gate))
        defer { endpoint.stop() }
        let leaving = try await connect(endpoint)
        try await leaving.send(RequestEnvelope(id: 1, request: .runAction(key: "wait")))
        await gate.waitForArrival()

        leaving.disconnect()
        await gate.release()

        #expect(await actionFinished())
        let next = try await connect(endpoint)
        #expect(try await perform(.runAction(key: "other"), on: next) == .done)
    }

    @Test(.timeLimit(.minutes(1))) func stoppingMidRequestFinishesTheWorkAndAnswersNobody() async throws {
        let gate = Gate()
        let endpoint = try await start(makeGatedRegistry(gate))
        let client = try await connect(endpoint)
        try await client.send(RequestEnvelope(id: 1, request: .runAction(key: "wait")))
        await gate.waitForArrival()

        endpoint.stop()
        await gate.release()

        #expect(await actionFinished())
        // A response would decode here instead of throwing.
        await #expect(throws: (any Error).self) {
            try await client.receive(ResponseEnvelope.self)
        }
    }

    @Test func anIdleClientDisconnectingLeavesOthersConnected() async throws {
        let endpoint = try await start()
        defer { endpoint.stop() }
        let leaving = try await connect(endpoint)
        let staying = try await connect(endpoint)

        leaving.disconnect()

        #expect(try await perform(.runAction(key: "run"), on: staying) == .done)
    }

    @Test func aMessageOverTheSizeLimitClosesOnlyThatConnection() async throws {
        let endpoint = try await start()
        defer { endpoint.stop() }
        let oversized = try await connect(endpoint)
        let other = try await connect(endpoint)

        try? await oversized.sendRaw(String(repeating: "x", count: (1 << 20) + 1))

        #expect(await oversized.isClosedByServer(within: .seconds(3)))
        #expect(try await perform(.runAction(key: "run"), on: other) == .done)
    }

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

    #if os(macOS)
    @Test func theListeningSocketIsBoundToLoopbackOnly() async throws {
        let endpoint = try await start()
        defer { endpoint.stop() }
        let port = endpoint.info.port

        let addresses = try listeningAddresses().filter { $0.hasSuffix(":\(port)") }

        #expect(addresses == ["127.0.0.1:\(port)"])
    }
    #endif

    /// Disabled, so reported as skipped, on a machine with no other interface.
    @Test(.enabled(if: nonLoopbackAddress() != nil))
    func theEndpointCantBeReachedFromAnotherInterface() async throws {
        let address = try #require(nonLoopbackAddress())
        let endpoint = try await start()
        defer { endpoint.stop() }
        #expect(canConnect(host: "127.0.0.1", port: endpoint.info.port))

        #expect(!canConnect(host: address, port: endpoint.info.port))
    }
}
#endif
