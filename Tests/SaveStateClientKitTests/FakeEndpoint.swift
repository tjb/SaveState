#if os(macOS)
import Foundation
import Network
import SaveStateProtocol
import Synchronization
@testable import SaveStateClientKit

// A copy of the CLI's harness in CLI/Tests/SaveStateBridgeKitTests: test targets
// in different packages can't share code. Change both together.

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
        /// Accepts the hello, then answers each request with what `reply` returns
        /// for it, after `delay`, the way an app finishing a wait looks.
        case replies(after: Duration = .zero, reply: @Sendable (WireRequest) -> WireResult)
    }

    /// The requests the endpoint received, in order, across every connection.
    final class RequestLog: Sendable {
        private let requests = Mutex<[WireRequest]>([])

        var all: [WireRequest] {
            requests.withLock { $0 }
        }

        func record(_ data: Data?) {
            guard let data, let envelope = try? JSONDecoder().decode(RequestEnvelope.self, from: data) else { return }
            requests.withLock { $0.append(envelope.request) }
        }
    }

    /// What this endpoint received.
    let log = RequestLog()

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
        let log = log
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            Self.serve(connection, behavior: behavior, step: 0, log: log)
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

    /// Stops listening, so the port closes while the test still holds the endpoint.
    func stop() {
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

    private static func serve(_ connection: NWConnection, behavior: Behavior, step: Int, log: RequestLog) {
        switch behavior {
        case .neverUpgrades:
            return
        case .replies(let delay, let reply):
            serveReplies(on: connection, after: delay, with: reply, step: step, log: log)
        default:
            serveScripted(connection, behavior: behavior, step: step)
        }
    }

    private static func serveReplies(
        on connection: NWConnection,
        after delay: Duration,
        with reply: @escaping @Sendable (WireRequest) -> WireResult,
        step: Int,
        log: RequestLog
    ) {
        connection.receiveMessage { content, _, _, error in
            guard error == nil else { return }
            if step == 0 {
                send(ServerHello.accepted, on: connection)
                serveReplies(on: connection, after: delay, with: reply, step: 1, log: log)
                return
            }
            log.record(content)
            answer(content, after: delay, with: reply, on: connection)
        }
    }

    private static func serveScripted(_ connection: NWConnection, behavior: Behavior, step: Int) {
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
                serveScripted(connection, behavior: behavior, step: 1)
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

    private static func answer(
        _ content: Data?,
        after delay: Duration,
        with reply: @Sendable (WireRequest) -> WireResult,
        on connection: NWConnection
    ) {
        guard let content, let envelope = try? JSONDecoder().decode(RequestEnvelope.self, from: content) else { return }
        let answer = ResponseEnvelope(id: envelope.id, result: reply(envelope.request))
        let nanoseconds = delay.components.seconds * 1_000_000_000 + delay.components.attoseconds / 1_000_000_000
        DispatchQueue.global().asyncAfter(deadline: .now() + .nanoseconds(Int(nanoseconds))) {
            send(answer, on: connection)
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
#endif
