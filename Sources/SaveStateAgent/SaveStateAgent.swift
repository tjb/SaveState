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
    /// How many clients are connected, so tests can see closed ones are released.
    var connectionCount: Int { connections.count }
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

    /// The longest a `wait` request may take, so a client can't hold one open forever.
    static let maximumWaitTimeout: Duration = .seconds(30)

    /// A `wait` request's timeout, clamped to zero through `maximumWaitTimeout`.
    static func waitTimeout(milliseconds: Int) -> Duration {
        min(max(.milliseconds(milliseconds), .zero), maximumWaitTimeout)
    }

    private func accept(_ connection: NWConnection) {
        let agentConnection = AgentConnection(connection: connection, token: info.token, registry: registry) { [weak self] closed in
            self?.connections[ObjectIdentifier(closed)] = nil
        }
        connections[ObjectIdentifier(agentConnection)] = agentConnection
        agentConnection.start()
    }
}

/// One client: its hello, then its requests, answered one at a time and in order.
///
/// It keeps a receive pending while it answers, so it sees a client leave even
/// during a long wait, and queues requests that arrive meanwhile.
@MainActor
private final class AgentConnection {
    private static let helloTimeout: Duration = .seconds(5)

    private let connection: NWConnection
    private let token: String
    private let registry: SaveStateRegistry
    private let onClose: (AgentConnection) -> Void
    private var isAuthenticated = false
    private var isClosed = false
    /// Requests that arrived while another was being answered.
    private var queuedRequests: [Data] = []
    /// The request being answered, cancelled when the connection closes.
    private var inFlight: Task<Void, Never>?

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
        inFlight?.cancel()
        inFlight = nil
        queuedRequests.removeAll()
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
        queuedRequests.append(data)
        answerNextRequest()
        // Keep reading while a request is answered, so the next one queues and a close is noticed.
        receive()
    }

    private func answerNextRequest() {
        guard inFlight == nil, !isClosed, !queuedRequests.isEmpty else { return }
        let data = queuedRequests.removeFirst()
        inFlight = Task {
            await answer(data)
            inFlight = nil
            answerNextRequest()
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
                return .control(control: try registry.control(forKey: key))
            case .set(let key, let value, let persist):
                try registry.set(value, forKey: key, persist: persist)
                return .done
            case .runAction(let key):
                // Unstructured, so closing the connection doesn't cancel the app's work halfway.
                let registry = registry
                try await Task { try await registry.runAction(key) }.value
                return .done
            case .applyScenario(let key):
                let registry = registry
                try await Task { try await registry.applyScenario(key) }.value
                return .done
            case .readProbe(let key):
                return .probe(probe: try registry.probe(forKey: key))
            case .wait(let key, let condition, let timeoutMilliseconds):
                return .probe(probe: try await registry.wait(
                    forProbe: key,
                    until: condition,
                    timeout: AgentEndpoint.waitTimeout(milliseconds: timeoutMilliseconds)
                ))
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

extension WireError {
    /// The error sent to the bridge for a registry error. Messages name values
    /// as the agent wrote them, such as `true` or `"idle"`, not as Swift prints them.
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
        case .unknownProbe(let key):
            self.init(code: .unknownProbe, message: "No probe has the key \"\(key)\".")
        case .invalidCondition(let key, let condition, let value):
            self.init(
                code: .invalidCondition,
                message: """
                \(Self.describe(condition)) can't apply to the probe "\(key)", whose value is \(Self.describe(value)) \
                (\(Self.kind(of: value))).
                """
            )
        case .timedOut(let key, let timeout):
            let milliseconds = timeout.components.seconds * 1000 + timeout.components.attoseconds / 1_000_000_000_000_000
            self.init(
                code: .timedOut,
                message: "The probe \"\(key)\" didn't meet the condition within \(milliseconds) ms."
            )
        }
    }

    /// A condition as the tool's arguments name it, such as `atLeast 3`.
    private static func describe(_ condition: ProbeCondition) -> String {
        let name = switch condition {
        case .equals: "equals"
        case .notEquals: "notEquals"
        case .atLeast: "atLeast"
        case .atMost: "atMost"
        }
        return "\(name) \(describe(condition.value))"
    }

    /// A value in its JSON form, with a date as an ISO 8601 string.
    private static func describe(_ value: ControlValue) -> String {
        switch value {
        case .null: "null"
        case .bool(let flag): String(flag)
        case .int(let number): String(number)
        case .double(let number): String(number)
        case .string(let text): "\"\(text)\""
        case .date(let date): "\"\(date.formatted(.iso8601))\""
        }
    }

    private static func kind(of value: ControlValue) -> String {
        switch value {
        case .null: "no value"
        case .bool: "a Boolean"
        case .int, .double: "a number"
        case .string: "a string"
        case .date: "a date"
        }
    }
}
#endif
