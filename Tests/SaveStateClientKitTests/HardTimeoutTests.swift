#if os(macOS)
import Foundation
import SaveStateProtocol
import Synchronization
import Testing
@testable import SaveStateClientKit

/// A socket whose sends and receives never return, even after it's closed, the way
/// URLSession behaved under one toolchain's test runner (issue #27).
private final class SocketThatNeverCallsBack: AppSocket {
    private let parked = Mutex<[CheckedContinuation<Void, any Error>]>([])
    private let closes = Mutex(0)

    /// Sends and receives that are waiting.
    var pendingCalls: Int { parked.withLock { $0.count } }

    /// How many times the client closed the socket.
    var closeCount: Int { closes.withLock { $0 } }

    func send(_ text: String) async throws {
        try await park()
    }

    func receive() async throws -> URLSessionWebSocketTask.Message {
        try await park()
        return .string("")
    }

    func close() {
        // Deliberately leaves every pending call waiting.
        closes.withLock { $0 += 1 }
    }

    /// Fails every pending call, so a test leaves nothing waiting behind it.
    func release() {
        let waiting = parked.withLock { parked in
            defer { parked = [] }
            return parked
        }
        for continuation in waiting {
            continuation.resume(throwing: URLError(.cancelled))
        }
    }

    private func park() async throws {
        try await withCheckedThrowingContinuation { continuation in
            parked.withLock { $0.append(continuation) }
        }
    }
}

/// The outcome of a call that might never return, read without waiting on the call.
///
/// A broken client never returns from these tests, and awaiting it would hang the
/// run. A time limit trait doesn't help: it cancels the test and still waits for it.
private final class Outcome<Value: Sendable>: Sendable {
    private let result = Mutex<Result<Value, any Error>?>(nil)

    func record(_ body: () async throws -> Value) async {
        let settled: Result<Value, any Error>
        do {
            settled = .success(try await body())
        } catch {
            settled = .failure(error)
        }
        result.withLock { $0 = settled }
    }

    /// The call's result, or nil if it hasn't returned within `limit`.
    func result(within limit: Duration) async throws -> Result<Value, any Error>? {
        let deadline = ContinuousClock.now + limit
        while ContinuousClock.now < deadline {
            if let settled = result.withLock({ $0 }) { return settled }
            try await Task.sleep(for: .milliseconds(10))
        }
        return nil
    }
}

/// The client's timeout and cancellation return without waiting for the socket.
@Suite("A timeout doesn't wait for the socket")
struct HardTimeoutTests {
    private let app = DiscoveredApp(
        endpoint: EndpointInfo(
            protocolVersion: WireProtocol.version,
            port: 1,
            token: "token",
            bundleIdentifier: "fake.app",
            appName: "Fake",
            processIdentifier: 1
        ),
        deviceIdentifier: "device"
    )

    @Test func aTimeoutReturnsWhileTheSocketIsStillPending() async throws {
        let socket = SocketThatNeverCallsBack()
        defer { socket.release() }
        let app = app
        let outcome = Outcome<WireResult>()

        Task { await outcome.record { try await AppClient.send(.describe, over: socket, app: app, timeout: .milliseconds(100)) } }
        let result = try #require(try await outcome.result(within: .seconds(30)), "The call never returned.")

        #expect(throws: BridgeError(.noResponse, "Fake didn't answer in time. It may be suspended: bring it to the foreground.")) {
            try result.get()
        }
        #expect(socket.closeCount == 1)
    }

    @Test func cancellingReturnsWhileTheSocketIsStillPending() async throws {
        let socket = SocketThatNeverCallsBack()
        defer { socket.release() }
        let app = app
        let outcome = Outcome<WireResult>()

        let call = Task { await outcome.record { try await AppClient.send(.describe, over: socket, app: app, timeout: .seconds(3600)) } }
        while socket.pendingCalls == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        call.cancel()
        let result = try #require(try await outcome.result(within: .seconds(30)), "The call never returned.")

        #expect(throws: CancellationError.self) { try result.get() }
        #expect(socket.closeCount == 1)
        #expect(socket.pendingCalls == 1)
    }

    @Test func onlyTheFirstOutcomeCounts() async throws {
        let outcome = FirstOutcome<Int>()

        outcome.finish(.success(1))
        outcome.finish(.success(2))
        outcome.finish(.failure(CancellationError()))

        #expect(try await outcome.value == 1)
    }

    @Test func aWaiterGetsAnOutcomeThatArrivesLater() async throws {
        let outcome = FirstOutcome<Int>()

        async let value = outcome.value
        await Task.yield()
        outcome.finish(.success(7))

        #expect(try await value == 7)
    }
}
#endif
