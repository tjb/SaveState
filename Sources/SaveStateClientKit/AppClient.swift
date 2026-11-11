// The client runs on a Mac and compiles to nothing on iOS.
#if os(macOS)
import Foundation
import SaveStateProtocol

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
        defer { task.cancel(with: .normalClosure, reason: nil) }

        return try await withThrowingTaskGroup(of: WireResult.self) { group in
            group.addTask {
                // The socket ignores task cancellation, and the group can't return
                // until this finishes, so cancelling has to reach the socket.
                try await withTaskCancellationHandler {
                    try await exchange(request, over: task, app: app)
                } onCancel: {
                    task.cancel(with: .normalClosure, reason: nil)
                }
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw BridgeError(
                    .noResponse,
                    "\(app.endpoint.appName) didn't answer in time. It may be suspended: bring it to the foreground."
                )
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw BridgeError(.noResponse, "The request ended without a result.")
            }
            return result
        }
    }

    private static func exchange(
        _ request: WireRequest,
        over task: URLSessionWebSocketTask,
        app: DiscoveredApp
    ) async throws -> WireResult {
        do {
            try await send(
                ClientHello(protocolVersion: WireProtocol.version, token: app.endpoint.token),
                over: task
            )
            if case .rejected(let error) = try await receive(ServerHello.self, over: task) {
                throw error
            }
            let identifier = 1
            try await send(RequestEnvelope(id: identifier, request: request), over: task)
            let response = try await receive(ResponseEnvelope.self, over: task)
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

    private static func send(_ message: some Encodable, over task: URLSessionWebSocketTask) async throws {
        let text = String(bytes: try JSONEncoder().encode(message), encoding: .utf8) ?? ""
        try await task.send(.string(text))
    }

    private static func receive<Message: Decodable>(
        _ type: Message.Type,
        over task: URLSessionWebSocketTask
    ) async throws -> Message {
        switch try await task.receive() {
        case .string(let text):
            return try JSONDecoder().decode(type, from: Data(text.utf8))
        case .data(let data):
            return try JSONDecoder().decode(type, from: data)
        @unknown default:
            throw BridgeError(.unreadableReply, "The app sent a message this tool can't read.")
        }
    }
}
#endif
