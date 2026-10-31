// Everything in this module is Debug-only. Outside DEBUG it compiles to nothing,
// so a Release binary carries no server and no open port.
#if DEBUG
import Foundation
import Network
import SaveState
import SaveStateProtocol

/// The endpoint the `savestate` bridge talks to, so coding agents can reach an
/// app's registry.
///
/// Start it once at launch. Its API exists only in Debug builds, so guard both the
/// import and the call:
///
/// ```swift
/// #if DEBUG
/// import SaveStateAgent
/// #endif
///
/// #if DEBUG
/// Task { try? await AgentEndpoint.start(registry: registry) }
/// #endif
/// ```
///
/// It listens on the loopback interface, and every connection must first present
/// a token that's new at each launch. The token and port are in a file in the
/// app's data container, readable only by the owning user.
@MainActor
public final class AgentEndpoint {
    private static var current: AgentEndpoint?
    /// The latest start, which the next one waits for, so overlapping starts run
    /// one at a time and leave exactly one endpoint.
    private static var latestStart: Task<AgentEndpoint?, any Error>?

    /// What the endpoint wrote to its endpoint file.
    public let info: EndpointInfo

    private let registry: SaveStateRegistry
    private let listener: NWListener
    private let fileURL: URL
    private var connections: [ObjectIdentifier: AgentConnection] = [:]
    private var isStopped = false

    /// Starts the endpoint, replacing one already running, and returns once it's
    /// listening and its file is written.
    ///
    /// - Parameters:
    ///   - registry: The registry clients read and change.
    ///   - container: The directory `EndpointInfo.relativePath` is relative to.
    ///     In the simulator it defaults to the app's data container. A Mac has no
    ///     per-app container, so there you must pass one.
    /// - Returns: The endpoint, or `nil` where it doesn't run: when the registry
    ///   is disabled, on a Mac with no container given, and on any physical device,
    ///   where nothing listens. A running endpoint stops in those cases too.
    @discardableResult
    public static func start(
        registry: SaveStateRegistry,
        container: URL? = nil
    ) async throws -> AgentEndpoint? {
        #if targetEnvironment(simulator) || os(macOS)
        let previous = latestStart
        let start = Task { @MainActor in
            _ = try? await previous?.value
            current?.stop()
            guard registry.isEnabled, let container = container ?? defaultContainer else { return nil as AgentEndpoint? }
            let endpoint = try await AgentEndpoint(registry: registry, container: container)
            current = endpoint
            return endpoint
        }
        latestStart = start
        return try await start.value
        #else
        return nil
        #endif
    }

    /// Where the endpoint runs by default. It's an allowlist, so a new platform
    /// or device stays closed until someone decides otherwise.
    private static var defaultContainer: URL? {
        #if targetEnvironment(simulator)
        return URL(fileURLWithPath: NSHomeDirectory())
        #else
        return nil
        #endif
    }

    private init(registry: SaveStateRegistry, container: URL) async throws {
        self.registry = registry
        fileURL = container.appendingPathComponent(EndpointInfo.relativePath)
        listener = try NWListener(using: Self.makeParameters())

        let port = try await Self.waitUntilReady(listener)
        let bundle = Bundle.main
        info = EndpointInfo(
            protocolVersion: WireProtocol.version,
            port: port,
            token: Self.makeToken(),
            bundleIdentifier: bundle.bundleIdentifier ?? ProcessInfo.processInfo.processName,
            appName: (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                ?? ProcessInfo.processInfo.processName,
            processIdentifier: ProcessInfo.processInfo.processIdentifier
        )
        do {
            try writeEndpointFile()
        } catch {
            listener.cancel()
            throw error
        }
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated {
                self?.accept(connection)
            }
        }
        listener.stateUpdateHandler = nil
    }

    /// Stops listening, closes every connection, and removes the endpoint file.
    ///
    /// Stopping again does nothing, so a replaced endpoint can't remove the file of
    /// the one that replaced it.
    public func stop() {
        guard !isStopped else { return }
        isStopped = true
        listener.newConnectionHandler = nil
        listener.cancel()
        for connection in connections.values {
            connection.close()
        }
        connections.removeAll()
        try? FileManager.default.removeItem(at: fileURL)
        if Self.current === self {
            Self.current = nil
        }
    }

    // MARK: - Setup

    private static func makeParameters() -> NWParameters {
        let webSocket = NWProtocolWebSocket.Options()
        webSocket.autoReplyPing = true
        webSocket.maximumMessageSize = 1 << 20
        let parameters = NWParameters.tcp
        parameters.defaultProtocolStack.applicationProtocols.insert(webSocket, at: 0)
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        return parameters
    }

    /// Waits for the listener to bind and returns its port.
    private static func waitUntilReady(_ listener: NWListener) async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            // Called on the main queue, one state at a time.
            nonisolated(unsafe) var pending: CheckedContinuation<UInt16, any Error>? = continuation
            // NWListener needs a handler to start. Nothing can arrive yet, because
            // no client knows the port until the endpoint file exists.
            listener.newConnectionHandler = { $0.cancel() }
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if let port = listener.port?.rawValue {
                        pending?.resume(returning: port)
                    } else {
                        pending?.resume(throwing: NWError.posix(.EADDRNOTAVAIL))
                    }
                    pending = nil
                case .failed(let error), .waiting(let error):
                    pending?.resume(throwing: error)
                    pending = nil
                case .cancelled:
                    pending?.resume(throwing: CancellationError())
                    pending = nil
                default:
                    break
                }
            }
            listener.start(queue: .main)
        }
    }

    private static func makeToken() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<32)
            .map { _ in String(format: "%02x", UInt8.random(in: .min ... .max, using: &generator)) }
            .joined()
    }

    private func writeEndpointFile() throws {
        let manager = FileManager.default
        try manager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        // Created empty and private first, so the token is never world-readable.
        try? manager.removeItem(at: fileURL)
        guard manager.createFile(atPath: fileURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        try handle.write(contentsOf: try JSONEncoder().encode(info))
    }

    // MARK: - Connections

    private func accept(_ connection: NWConnection) {
        let agentConnection = AgentConnection(connection: connection, token: info.token, registry: registry) { [weak self] closed in
            self?.connections[ObjectIdentifier(closed)] = nil
        }
        connections[ObjectIdentifier(agentConnection)] = agentConnection
        agentConnection.start()
    }
}

/// One client: its hello, then its requests, answered one at a time and in order.
@MainActor
private final class AgentConnection {
    private static let helloTimeout: Duration = .seconds(5)

    private let connection: NWConnection
    private let token: String
    private let registry: SaveStateRegistry
    private let onClose: (AgentConnection) -> Void
    private var isAuthenticated = false
    private var isClosed = false

    init(
        connection: NWConnection,
        token: String,
        registry: SaveStateRegistry,
        onClose: @escaping (AgentConnection) -> Void
    ) {
        self.connection = connection
        self.token = token
        self.registry = registry
        self.onClose = onClose
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                switch state {
                case .failed, .cancelled:
                    self?.close()
                default:
                    break
                }
            }
        }
        connection.start(queue: .main)
        receive()
        Task { [weak self] in
            try? await Task.sleep(for: Self.helloTimeout)
            guard let self, !self.isAuthenticated else { return }
            self.close()
        }
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        connection.cancel()
        onClose(self)
    }

    private func receive() {
        connection.receiveMessage { [weak self] data, context, _, error in
            MainActor.assumeIsolated {
                guard let self else { return }
                let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
                    as? NWProtocolWebSocket.Metadata
                guard error == nil, metadata?.opcode != .close else {
                    self.close()
                    return
                }
                guard let data, metadata?.opcode == .text || metadata?.opcode == .binary else {
                    self.receive()
                    return
                }
                self.handle(data)
            }
        }
    }

    private func handle(_ data: Data) {
        guard isAuthenticated else {
            handleHello(data)
            return
        }
        Task {
            await answer(data)
            if !isClosed {
                receive()
            }
        }
    }

    private func handleHello(_ data: Data) {
        guard let hello = try? JSONDecoder().decode(ClientHello.self, from: data) else {
            reject(WireError(code: .unauthorized, message: "Send a hello first."))
            return
        }
        guard Self.isEqual(hello.token, token) else {
            reject(WireError(code: .unauthorized, message: "The token is wrong."))
            return
        }
        guard hello.protocolVersion == WireProtocol.version else {
            reject(WireError(
                code: .protocolMismatch,
                message: "The app speaks protocol \(WireProtocol.version), the client \(hello.protocolVersion)."
            ))
            return
        }
        isAuthenticated = true
        send(ServerHello.accepted)
        receive()
    }

    private func reject(_ error: WireError) {
        send(ServerHello.rejected(error: error)) { [weak self] in
            self?.close()
        }
    }

    private func answer(_ data: Data) async {
        do {
            let envelope = try JSONDecoder().decode(RequestEnvelope.self, from: data)
            let result = await perform(envelope.request)
            let response = ResponseEnvelope(id: envelope.id, result: result)
            guard (try? JSONEncoder().encode(response)) != nil else {
                // JSON can't carry a non-finite number, such as a model's NaN.
                send(ResponseEnvelope(id: envelope.id, result: .failure(error: WireError(
                    code: .operationFailed,
                    message: "The app's response can't be encoded. Check for a control holding NaN or infinity."
                ))))
                return
            }
            send(response)
        } catch {
            send(ResponseEnvelope(id: nil, result: .failure(error: WireError(
                code: .badRequest,
                message: "The message isn't a request: \(error)"
            ))))
        }
    }

    private func perform(_ request: WireRequest) async -> WireResult {
        do {
            switch request {
            case .describe:
                return .description(registry: registry.describe())
            case .read(let key):
                guard let control = registry.describe().controls.first(where: { $0.key == key }) else {
                    throw SaveStateError.unknownControl(key)
                }
                return .control(control: control)
            case .set(let key, let value, let persist):
                try registry.set(value, forKey: key, persist: persist)
                return .done
            case .runAction(let key):
                try await registry.runAction(key)
                return .done
            case .applyScenario(let key):
                try await registry.applyScenario(key)
                return .done
            }
        } catch let error as SaveStateError {
            return .failure(error: WireError(saveStateError: error))
        } catch {
            return .failure(error: WireError(code: .operationFailed, message: String(describing: error)))
        }
    }

    private func send(_ message: some Encodable, then completion: (@MainActor () -> Void)? = nil) {
        guard !isClosed, let data = try? JSONEncoder().encode(message) else { return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "message", metadata: [metadata])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { _ in
            MainActor.assumeIsolated {
                completion?()
            }
        })
    }

    /// Compares without returning early, so timing doesn't reveal the token.
    private static func isEqual(_ left: String, _ right: String) -> Bool {
        let leftBytes = Array(left.utf8)
        let rightBytes = Array(right.utf8)
        guard leftBytes.count == rightBytes.count else { return false }
        return zip(leftBytes, rightBytes).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

private extension WireError {
    init(saveStateError error: SaveStateError) {
        switch error {
        case .disabled:
            self.init(code: .disabled, message: "The registry is disabled.")
        case .unknownControl(let key):
            self.init(code: .unknownControl, message: "No control has the key \"\(key)\".")
        case .unknownAction(let key):
            self.init(code: .unknownAction, message: "No action has the key \"\(key)\".")
        case .unknownScenario(let key):
            self.init(code: .unknownScenario, message: "No scenario has the key \"\(key)\".")
        case .destructiveActionNotAllowed(let key):
            self.init(
                code: .destructiveActionNotAllowed,
                message: "The action \"\(key)\" is destructive, so a person has to run it."
            )
        case .invalidValue(let key, let value, let kind):
            self.init(code: .invalidValue, message: "The control \"\(key)\" of kind \(kind) can't take \(value).")
        }
    }
}
#endif
