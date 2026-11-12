// The client runs on a Mac and compiles to nothing on iOS.
#if os(macOS)
import Foundation
import SaveStateProtocol
import Synchronization

/// Sends one request to an app's endpoint and returns its result.
///
/// Each request opens its own connection. Apps relaunch often, and a new connection
/// always uses the current port and token.
enum AppClient {
    private static let session = URLSession(configuration: .ephemeral)

    static func send(
        _ request: WireRequest,
        to app: DiscoveredApp,
        timeout: Duration
    ) async throws -> WireResult {
        guard let url = URL(string: "ws://127.0.0.1:\(app.endpoint.port)") else {
            throw BridgeError(.unreachable, "The app's endpoint file has a bad port.")
        }
        let task = session.webSocketTask(with: url)
        task.resume()
        return try await send(request, over: WebSocket(task: task), app: app, timeout: timeout)
    }

    /// Runs one exchange over `socket` and returns as soon as it ends, the timeout
    /// passes, or the caller is cancelled, whichever comes first.
    ///
    /// The timeout is hard: it never waits for the socket to finish a pending send or
    /// receive after closing it. URLSession doesn't always call back for a cancelled
    /// WebSocket task (issue #27), so waiting for that could hang the call forever.
    /// The abandoned exchange ends in the background whenever the socket lets it.
    static func send(
        _ request: WireRequest,
        over socket: some AppSocket,
        app: DiscoveredApp,
        timeout: Duration
    ) async throws -> WireResult {
        let outcome = FirstOutcome<WireResult>()
        let exchanging = Task {
            do {
                outcome.finish(.success(try await exchange(request, over: socket, app: app)))
            } catch {
                outcome.finish(.failure(error))
            }
        }
        let timing = Task {
            // A cancelled sleep means the call already ended another way.
            guard (try? await Task.sleep(for: timeout)) != nil else { return }
            outcome.finish(.failure(BridgeError(
                .noResponse,
                "\(app.endpoint.appName) didn't answer in time. It may be suspended: bring it to the foreground."
            )))
        }
        defer {
            timing.cancel()
            exchanging.cancel()
            socket.close()
        }
        return try await withTaskCancellationHandler {
            try await outcome.value
        } onCancel: {
            outcome.finish(.failure(CancellationError()))
        }
    }

    private static func exchange(
        _ request: WireRequest,
        over socket: some AppSocket,
        app: DiscoveredApp
    ) async throws -> WireResult {
        do {
            try await send(
                ClientHello(protocolVersion: WireProtocol.version, token: app.endpoint.token),
                over: socket
            )
            if case .rejected(let error) = try await receive(ServerHello.self, over: socket) {
                throw error
            }
            let identifier = 1
            try await send(RequestEnvelope(id: identifier, request: request), over: socket)
            let response = try await receive(ResponseEnvelope.self, over: socket)
            guard response.id == identifier else {
                if case .failure(let error) = response.result { throw error }
                throw BridgeError(.unexpectedResponse, "The app answered a different request.")
            }
            return response.result
        } catch let error as BridgeError {
            throw error
        } catch let error as WireError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch is DecodingError {
            throw BridgeError(
                .unreadableReply,
                "\(app.endpoint.appName) sent a reply this tool can't read. Rebuild the app and this tool from the same SaveState version."
            )
        } catch {
            // A closed socket arrives as a POSIX error, a refused one as a URLError.
            throw BridgeError(
                .unreachable,
                "Couldn't reach \(app.endpoint.appName): \(error.localizedDescription) It may have quit: relaunch it."
            )
        }
    }

    private static func send(_ message: some Encodable, over socket: some AppSocket) async throws {
        try await socket.send(String(bytes: try JSONEncoder().encode(message), encoding: .utf8) ?? "")
    }

    private static func receive<Message: Decodable>(
        _ type: Message.Type,
        over socket: some AppSocket
    ) async throws -> Message {
        switch try await socket.receive() {
        case .string(let text):
            return try JSONDecoder().decode(type, from: Data(text.utf8))
        case .data(let data):
            return try JSONDecoder().decode(type, from: data)
        @unknown default:
            throw BridgeError(.unreadableReply, "The app sent a message this tool can't read.")
        }
    }
}

/// The connection one request travels over. In use it's a URLSession WebSocket;
/// tests swap in sockets that misbehave in ways a real server can't arrange.
protocol AppSocket: Sendable {
    /// Sends one text frame.
    func send(_ text: String) async throws
    /// Waits for the next frame.
    func receive() async throws -> URLSessionWebSocketTask.Message
    /// Closes the connection once the request is over, however it ended. A pending
    /// send or receive should then fail, but nothing waits for it to.
    func close()
}

/// A URLSession WebSocket task as an `AppSocket`.
struct WebSocket: AppSocket {
    let task: URLSessionWebSocketTask

    func send(_ text: String) async throws {
        try await task.send(.string(text))
    }

    func receive() async throws -> URLSessionWebSocketTask.Message {
        try await task.receive()
    }

    func close() {
        task.cancel(with: .normalClosure, reason: nil)
    }
}

/// Hands the first of several racing outcomes to one waiter and drops the rest.
final class FirstOutcome<Value: Sendable>: Sendable {
    private enum State {
        case pending(CheckedContinuation<Value, any Error>?)
        case finished(Result<Value, any Error>)
    }

    private let state = Mutex(State.pending(nil))

    /// Settles the outcome, unless an earlier call already did.
    func finish(_ result: Result<Value, any Error>) {
        // The waiter, if one is already waiting. A later one finds the result itself.
        let waiter: CheckedContinuation<Value, any Error>? = state.withLock { state in
            guard case .pending(let waiter) = state else { return nil }
            state = .finished(result)
            return waiter
        }
        waiter?.resume(with: result)
    }

    /// The first outcome, waiting for one if none has arrived yet. Read it once.
    var value: Value {
        get async throws {
            try await withCheckedThrowingContinuation { continuation in
                let settled: Result<Value, any Error>? = state.withLock { state in
                    switch state {
                    case .pending:
                        state = .pending(continuation)
                        return nil
                    case .finished(let result):
                        return result
                    }
                }
                if let settled { continuation.resume(with: settled) }
            }
        }
    }
}
#endif
