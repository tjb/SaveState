#if os(macOS)
import Foundation
import SaveStateProtocol
import Testing
@testable import SaveStateClientKit

private let sampleProbe = ProbeDescription(key: "item-count", label: "Items", section: nil, value: .int(3))

/// `SaveStateClient` against a fake app, to see exactly what it sends.
@Suite("SaveStateClient against a fake app")
struct SaveStateClientWireTests {
    private func fake(
        after delay: Duration = .zero,
        _ reply: @escaping @Sendable (WireRequest) -> WireResult = { _ in .probe(probe: sampleProbe) }
    ) async throws -> FakeEndpoint {
        try await FakeEndpoint(.replies(after: delay, reply: reply))
    }

    // MARK: - Protocol version

    @Test(arguments: [WireProtocol.version - 1, WireProtocol.version + 1])
    func anAppOnAnotherProtocolIsRejectedWithoutSendingAnything(version: Int) async throws {
        let endpoint = try await fake()
        var other = endpoint.app()
        other.endpoint.protocolVersion = version
        let app = other
        let client = SaveStateClient(timeout: .seconds(5))
        let calls: [@Sendable () async throws -> Void] = [
            { _ = try await client.describe(app) },
            { _ = try await client.read("on", in: app) },
            { try await client.set("on", to: .bool(true), in: app) },
            { try await client.runAction("run", in: app) },
            { try await client.applyScenario("expired-trial", in: app) },
            { _ = try await client.readProbe("item-count", in: app) },
            { _ = try await client.wait(forProbe: "item-count", until: .atLeast(value: .int(1)), in: app) }
        ]

        for call in calls {
            let error = await #expect(throws: BridgeError.self) { try await call() }
            #expect(error?.code == .protocolMismatch)
            #expect(error?.message == """
            Fake speaks protocol \(version), and this tool speaks \(WireProtocol.version). \
            Rebuild the app and this tool from the same SaveState version.
            """)
        }
        #expect(endpoint.log.all.isEmpty)
    }

    // MARK: - Odd answers

    @Test func theWrongKindOfResultThrowsABridgeError() async throws {
        let endpoint = try await fake { request in
            // Every request gets an answer meant for a different one.
            if case .describe = request { return .done }
            return .description(registry: RegistryDescription(controls: [], actions: [], scenarios: []))
        }
        let app = endpoint.app()
        let client = SaveStateClient(timeout: .seconds(5))
        let calls: [@Sendable () async throws -> Void] = [
            { _ = try await client.describe(app) },
            { _ = try await client.read("on", in: app) },
            { try await client.set("on", to: .bool(true), in: app) },
            { try await client.runAction("run", in: app) },
            { try await client.applyScenario("expired-trial", in: app) },
            { _ = try await client.readProbe("item-count", in: app) },
            { _ = try await client.wait(forProbe: "item-count", until: .atLeast(value: .int(1)), in: app) }
        ]

        for call in calls {
            let error = await #expect(throws: BridgeError.self) { try await call() }
            #expect(error?.code == .unexpectedResponse)
            #expect(error?.message.hasPrefix("The app sent an unexpected response: ") == true, "\(String(describing: error))")
        }
    }

    @Test func aBinaryFrameIsReadTheSameAsText() async throws {
        let registry = RegistryDescription(controls: [], actions: [], scenarios: [])
        let endpoint = try await FakeEndpoint(.answersInBinary(ResponseEnvelope(id: 1, result: .description(registry: registry))))

        let description = try await SaveStateClient(timeout: .seconds(5)).describe(endpoint.app())

        #expect(description == registry)
    }

    @Test func aFailureWithNoRequestIdentifierIsTheAppsWireError() async throws {
        let failure = WireError(code: .badRequest, message: "Bad message.")
        let endpoint = try await FakeEndpoint(.answers(ResponseEnvelope(id: nil, result: .failure(error: failure))))

        let error = await #expect(throws: WireError.self) { try await SaveStateClient(timeout: .seconds(5)).describe(endpoint.app()) }

        #expect(error == failure)
    }

    // MARK: - Error codes

    private static let emptyRegistry = WireResult.description(registry: RegistryDescription(controls: [], actions: [], scenarios: []))

    @Test(arguments: [
        (FakeEndpoint.Behavior.silent, BridgeError.Code.noResponse),
        (.neverUpgrades, .noResponse),
        (.closesAfterHello, .unreachable),
        (.closesAfterRequest, .unreachable),
        (.garbageHello, .unreadableReply),
        (.garbageResponse, .unreadableReply),
        (.answers(ResponseEnvelope(id: 99, result: emptyRegistry)), .unexpectedResponse),
        (.answers(ResponseEnvelope(id: 1, result: .done)), .unexpectedResponse)
    ])
    func eachTransportFailureHasItsCode(behavior: FakeEndpoint.Behavior, code: BridgeError.Code) async throws {
        let endpoint = try await FakeEndpoint(behavior)
        let client = SaveStateClient(timeout: .milliseconds(500))

        let error = await #expect(throws: BridgeError.self) { try await client.describe(endpoint.app()) }

        #expect(error?.code == code, "\(String(describing: error))")
    }

    @Test func anAppThatIsntListeningIsUnreachable() async throws {
        let endpoint = try await fake()
        var gone = endpoint.app()
        // Port 1 is privileged, so nothing in a test listens on it.
        gone.endpoint.port = 1
        let app = gone

        let error = await #expect(throws: BridgeError.self) { try await SaveStateClient(timeout: .seconds(5)).describe(app) }

        #expect(error?.code == .unreachable)
    }

    @Test func aRejectedConnectionIsTheAppsWireError() async throws {
        let endpoint = try await FakeEndpoint(.rejects(WireError(code: .unauthorized, message: "Stale token.")))

        let error = await #expect(throws: WireError.self) { try await SaveStateClient(timeout: .seconds(5)).describe(endpoint.app()) }

        #expect(error == WireError(code: .unauthorized, message: "Stale token."))
    }

    @Test func cancellingACallThrowsCancellationPromptly() async throws {
        let endpoint = try await FakeEndpoint(.silent)
        let app = endpoint.app()
        let client = SaveStateClient(timeout: .seconds(60))
        let start = ContinuousClock.now

        let call = Task { try await client.describe(app) }
        try await Task.sleep(for: .milliseconds(300))
        call.cancel()

        await #expect(throws: CancellationError.self) { try await call.value }
        #expect(ContinuousClock.now - start < .seconds(15))
    }

    @Test func anErrorReadsAsItsMessage() {
        let error = BridgeError(.appNotFound, "No app.")

        #expect("\(error)" == "No app.")
        #expect(error != BridgeError(.unknownKey, "No app."))
    }

    // MARK: - The client's own timeout

    @Test func aHugeTimeoutIsCappedRatherThanTrapping() async throws {
        let endpoint = try await fake()
        let client = SaveStateClient(timeout: .seconds(Int64.max))

        // Without the cap, the timer's sleep traps converting this to nanoseconds.
        let probe = try await client.readProbe("item-count", in: endpoint.app())

        #expect(client.timeout == SaveStateClient.maximumTimeout)
        #expect(SaveStateClient.maximumTimeout == .seconds(86_400))
        #expect(SaveStateClient(timeout: .seconds(86_399)).timeout == .seconds(86_399))
        #expect(probe == sampleProbe)
    }

    @Test func aZeroTimeoutFailsAtOnceWithNoResponse() async throws {
        let endpoint = try await fake(after: .milliseconds(500))

        let error = await #expect(throws: BridgeError.self) {
            try await SaveStateClient(timeout: .zero).readProbe("item-count", in: endpoint.app())
        }

        #expect(error?.code == .noResponse)
    }

    @Test func eachCallSendsItsRequest() async throws {
        let endpoint = try await fake { request in
            switch request {
            case .describe: return .description(registry: RegistryDescription(controls: [], actions: [], scenarios: []))
            case .set, .runAction, .applyScenario: return .done
            default: return .probe(probe: sampleProbe)
            }
        }
        let app = endpoint.app()
        let client = SaveStateClient(timeout: .seconds(5))

        _ = try await client.describe(app)
        try await client.set("on", to: .null, persist: true, in: app)
        try await client.set("count", to: .int(2), in: app)
        try await client.runAction("run", in: app)
        try await client.applyScenario("expired-trial", in: app)
        _ = try await client.readProbe("item-count", in: app)

        #expect(endpoint.log.all == [
            .describe,
            .set(key: "on", value: .null, persist: true),
            .set(key: "count", value: .int(2), persist: false),
            .runAction(key: "run"),
            .applyScenario(key: "expired-trial"),
            .readProbe(key: "item-count")
        ])
    }

    // MARK: - Wait timeouts

    @Test(arguments: [Duration.zero, .milliseconds(-1), .seconds(-5), .milliseconds(30_001), .seconds(31), .seconds(30) + .nanoseconds(1)])
    func aWaitTimeoutOutOfRangeIsRejectedBeforeSending(timeout: Duration) async throws {
        let endpoint = try await fake()
        let client = SaveStateClient(timeout: .seconds(5))

        let error = await #expect(throws: BridgeError.self) {
            try await client.wait(forProbe: "item-count", until: .atLeast(value: .int(1)), timeout: timeout, in: endpoint.app())
        }

        #expect(error?.code == .invalidArgument)
        #expect(error?.message.hasPrefix("A wait's timeout must be more than 0 and at most 30 seconds.") == true, "\(String(describing: error))")
        #expect(endpoint.log.all.isEmpty)
    }

    @Test(arguments: [
        (Duration.seconds(30), 30_000),
        (.seconds(10), 10_000),
        (.milliseconds(2500), 2500),
        (.microseconds(2_007_400), 2007),
        (.microseconds(1500), 2),
        // A half rounds up, not to the even neighbor.
        (.microseconds(2500), 3),
        (.microseconds(1_499_600), 1500),
        (.microseconds(100), 1),
        (.nanoseconds(1), 1)
    ])
    func forwardsTheWaitTimeoutInMilliseconds(timeout: Duration, milliseconds: Int) async throws {
        let endpoint = try await fake()
        let client = SaveStateClient(timeout: .seconds(5))

        let probe = try await client.wait(forProbe: "item-count", until: .atLeast(value: .int(1)), timeout: timeout, in: endpoint.app())

        #expect(probe == sampleProbe)
        #expect(endpoint.log.all == [.wait(key: "item-count", condition: .atLeast(value: .int(1)), timeoutMilliseconds: milliseconds)])
    }

    @Test func theDefaultWaitTimeoutIsTenSeconds() async throws {
        let endpoint = try await fake()

        _ = try await SaveStateClient(timeout: .seconds(5)).wait(forProbe: "item-count", until: .equals(value: .bool(true)), in: endpoint.app())

        #expect(endpoint.log.all == [.wait(key: "item-count", condition: .equals(value: .bool(true)), timeoutMilliseconds: 10_000)])
    }

    @Test func theMaximumWaitTimeoutIsThirtySeconds() {
        #expect(SaveStateClient.maximumWaitTimeout == .seconds(30))
        #expect(SaveStateClient().timeout == .seconds(30))
    }

    // MARK: - How long it waits for the app

    @Test func aWaitOutlastsTheClientsTimeout() async throws {
        // After the client's own timeout, within the wait's plus its slack.
        let endpoint = try await fake(after: .milliseconds(1500))
        let client = SaveStateClient(timeout: .milliseconds(500))

        let probe = try await client.wait(forProbe: "item-count", until: .atLeast(value: .int(1)), timeout: .seconds(2), in: endpoint.app())

        #expect(probe == sampleProbe)
    }

    @Test func aWaitOutlastsItsOwnTimeoutByTheSlack() async throws {
        // After the wait's own timeout, within its slack, so the app's answer
        // (here a probe, as if it met the condition at the last moment) still
        // arrives rather than racing the client giving up.
        let endpoint = try await fake(after: .seconds(2))
        let client = SaveStateClient(timeout: .milliseconds(500))

        let probe = try await client.wait(forProbe: "item-count", until: .atLeast(value: .int(1)), timeout: .seconds(1), in: endpoint.app())

        #expect(probe == sampleProbe)
    }

    @Test func otherCallsStillTimeOutOnTheClientsTimeout() async throws {
        // The same slow app, so the test above proves the wait's own timeout.
        let endpoint = try await fake(after: .milliseconds(1500))
        let client = SaveStateClient(timeout: .milliseconds(500))

        let error = await #expect(throws: BridgeError.self) {
            try await client.readProbe("item-count", in: endpoint.app())
        }

        #expect(error?.code == .noResponse)
        #expect(error?.message.contains("didn't answer in time") == true)
    }

    @Test func aShortWaitStillGetsTheClientsTimeout() async throws {
        // Slower than the wait plus its slack, within the client's own timeout.
        let endpoint = try await fake(after: .milliseconds(5500))
        let client = SaveStateClient(timeout: .seconds(10))

        let probe = try await client.wait(forProbe: "item-count", until: .atLeast(value: .int(1)), timeout: .milliseconds(100), in: endpoint.app())

        #expect(probe == sampleProbe)
    }
}
#endif
