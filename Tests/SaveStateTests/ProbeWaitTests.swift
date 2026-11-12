import Foundation
import Testing
@testable import SaveState

/// How long `body` takes.
@MainActor
private func timed<Result>(_ body: () async throws -> Result) async rethrows -> (Result, Duration) {
    let clock = ContinuousClock()
    let start = clock.now
    let result = try await body()
    return (result, clock.now - start)
}

/// Runs `body` and returns what it threw, or `nil` when it returned.
@MainActor
private func error(from body: () async throws -> some Any) async -> (any Error)? {
    do {
        _ = try await body()
        return nil
    } catch {
        return error
    }
}

/// Other suites share the main actor, so timing bounds leave room for a busy
/// machine. Each stays well below the interval that would pass it for the
/// wrong reason, such as a 10 second timeout.
@Suite("Waiting for probes", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct ProbeWaitTests {
    private let sync = SyncModel()
    private let plain = PlainModel()

    private func makePlainRegistry() -> SaveStateRegistry {
        let plain = plain
        return SaveStateRegistry(model: plain, store: ScratchDefaults().store, isEnabled: true) { r in
            r.probe("Count", key: "count") {
                plain.reads += 1
                return plain.count
            }
        }
    }

    // MARK: - Before waiting

    // These use a zero timeout instead of timing the call: a wait that had to wait
    // would throw timedOut, so passing proves the answer came before any waiting,
    // however busy the machine is.

    @Test func aProbeThatAlreadyMatchesReturnsAtOnce() async throws {
        let registry = makeProbeRegistry(sync: sync)
        sync.pendingUploads = 3

        let probe = try await registry.wait(forProbe: "sync.pending-uploads", until: .atLeast(value: .int(3)), timeout: .zero)

        #expect(probe == ProbeDescription(key: "sync.pending-uploads", label: "Pending uploads", section: "Sync", value: .int(3)))
    }

    @Test func anUnknownProbeThrowsBeforeWaiting() async {
        let registry = makeProbeRegistry(sync: sync)

        let thrown = await error {
            try await registry.wait(forProbe: "nope", until: .equals(value: .int(1)), timeout: .zero)
        }

        #expect(thrown as? SaveStateError == .unknownProbe("nope"))
    }

    @Test func aControlKeyIsAnUnknownProbe() async {
        let registry = makeProbeRegistry(sync: sync)

        let thrown = await error {
            try await registry.wait(forProbe: "connected-override", until: .equals(value: .bool(true)), timeout: .zero)
        }

        #expect(thrown as? SaveStateError == .unknownProbe("connected-override"))
    }

    @Test(arguments: [
        ("sync.connected", ProbeCondition.atLeast(value: .bool(true)), ControlValue.bool(false)),
        ("sync.connected", .equals(value: .int(1)), .bool(false)),
        ("status", .atMost(value: .string("z")), .string("idle")),
        ("sync.pending-uploads", .equals(value: .string("0")), .int(0)),
        ("last-sync", .atLeast(value: .string("yesterday")), .date(Date(timeIntervalSince1970: 1_800_000_000)))
    ])
    func anInapplicableConditionThrowsBeforeWaiting(key: String, condition: ProbeCondition, value: ControlValue) async {
        let registry = makeProbeRegistry(sync: sync)

        let thrown = await error { try await registry.wait(forProbe: key, until: condition, timeout: .zero) }

        #expect(thrown as? SaveStateError == .invalidCondition(key: key, condition: condition, value: value))
    }

    @Test func aDateProbeWaitsForAnISO8601String() async throws {
        let registry = makeProbeRegistry(sync: sync)

        let probe = try await registry.wait(
            forProbe: "last-sync",
            until: .atLeast(value: .string("2027-01-15T08:00:00Z")),
            timeout: .zero
        )

        #expect(probe.value == .date(Date(timeIntervalSince1970: 1_800_000_000)))
    }

    @Test func anIntegerProbeMatchesADoubleCondition() async throws {
        let registry = makeProbeRegistry(sync: sync)
        sync.pendingUploads = 2

        let probe = try await registry.wait(forProbe: "sync.pending-uploads", until: .equals(value: .double(2)), timeout: .zero)

        #expect(probe.value == .int(2))
    }

    // MARK: - Waking

    @Test func anObservableChangeWakesTheWait() async throws {
        let sync = sync
        // A tick and deadline far away, so only observation can wake it in time.
        let wait = ProbeWait(key: "pending", condition: .equals(value: .int(5)), timeout: .seconds(10), tick: .seconds(10)) {
            .int(sync.pendingUploads)
        }
        let task = Task { try await wait.run() }
        try await Task.sleep(for: .milliseconds(50))

        let (value, elapsed) = try await timed {
            sync.pendingUploads = 5
            return try await task.value
        }

        #expect(value == .int(5))
        // Far below the 10 seconds a missed wake would take, with room for a busy main actor.
        #expect(elapsed < .seconds(2))
    }

    @Test func aChangeThatDoesNotMatchKeepsWaiting() async throws {
        let sync = sync
        let wait = ProbeWait(key: "pending", condition: .atLeast(value: .int(3)), timeout: .seconds(10), tick: .seconds(10)) {
            .int(sync.pendingUploads)
        }
        let task = Task { try await wait.run() }
        try await Task.sleep(for: .milliseconds(20))

        let (value, elapsed) = try await timed {
            for count in 1...3 {
                sync.pendingUploads = count
                try await Task.sleep(for: .milliseconds(20))
            }
            return try await task.value
        }

        #expect(value == .int(3))
        // The 10 second tick or deadline would also return 3, so only a quick answer shows a wake.
        #expect(elapsed < .seconds(2))
    }

    @Test func registryWaitsWakeOnObservableChanges() async throws {
        let registry = makeProbeRegistry(sync: sync)
        // A tick far away, so only observation can wake it in time.
        registry.probeWaitTick = .seconds(10)
        let sync = sync
        Task {
            try? await Task.sleep(for: .milliseconds(30))
            sync.isConnected = true
        }

        let (probe, elapsed) = try await timed {
            try await registry.wait(forProbe: "sync.connected", until: .equals(value: .bool(true)), timeout: .seconds(10))
        }

        #expect(probe.value == .bool(true))
        #expect(elapsed < .seconds(2))
    }

    @Test func theTickSeesStateThatIsNotObservable() async throws {
        let registry = makePlainRegistry()
        let plain = plain
        Task {
            try? await Task.sleep(for: .milliseconds(30))
            plain.count = 5
        }

        let (probe, elapsed) = try await timed {
            try await registry.wait(forProbe: "count", until: .equals(value: .int(5)), timeout: .seconds(5))
        }

        #expect(probe.value == .int(5))
        // One tick is 100 ms. Without one, only the 5 second deadline would wake it.
        #expect(elapsed < .seconds(1))
        #expect(plain.reads >= 2)
    }

    // MARK: - Ending

    @Test func aWaitThatNeverMatchesTimesOutOnTime() async {
        let registry = makePlainRegistry()

        let (thrown, elapsed) = await timed {
            await error { try await registry.wait(forProbe: "count", until: .equals(value: .int(1)), timeout: .milliseconds(300)) }
        }

        #expect(thrown as? SaveStateError == .timedOut(key: "count", timeout: .milliseconds(300)))
        #expect(elapsed >= .milliseconds(300))
        // Room for a busy main actor, still far short of a missed deadline.
        #expect(elapsed < .seconds(2))
    }

    @Test func aZeroTimeoutChecksOnce() async {
        let registry = makePlainRegistry()

        let (thrown, elapsed) = await timed {
            await error { try await registry.wait(forProbe: "count", until: .equals(value: .int(1)), timeout: .zero) }
        }

        #expect(thrown as? SaveStateError == .timedOut(key: "count", timeout: .zero))
        #expect(plain.reads == 1)
        #expect(elapsed < .seconds(1))
    }

    @Test func aNegativeTimeoutChecksOnce() async {
        let registry = makePlainRegistry()

        let thrown = await error {
            try await registry.wait(forProbe: "count", until: .equals(value: .int(1)), timeout: .milliseconds(-5))
        }

        #expect(thrown as? SaveStateError == .timedOut(key: "count", timeout: .milliseconds(-5)))
        #expect(plain.reads == 1)
    }

    @Test func theDeadlineChecksOneLastTime() async throws {
        let plain = plain
        // No tick and nothing to observe, so only the deadline can see the change.
        let wait = ProbeWait(key: "count", condition: .equals(value: .int(1)), timeout: .milliseconds(200), tick: .seconds(10)) {
            .int(plain.count)
        }
        Task {
            try? await Task.sleep(for: .milliseconds(50))
            plain.count = 1
        }

        let (value, elapsed) = try await timed { try await wait.run() }

        #expect(value == .int(1))
        #expect(elapsed >= .milliseconds(200))
        #expect(elapsed < .seconds(5))
    }

    @Test func cancellingTheTaskThrowsCancellationErrorPromptly() async {
        let registry = makePlainRegistry()
        let task = Task {
            try await registry.wait(forProbe: "count", until: .equals(value: .int(1)), timeout: .seconds(10))
        }
        try? await Task.sleep(for: .milliseconds(50))

        let (thrown, elapsed) = await timed {
            task.cancel()
            return await error { try await task.value }
        }

        #expect(thrown is CancellationError)
        #expect(elapsed < .seconds(1))
    }

    @Test func anAlreadyCancelledTaskThrowsCancellationError() async {
        let registry = makePlainRegistry()
        plain.count = 1
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await registry.wait(forProbe: "count", until: .equals(value: .int(1)), timeout: .seconds(10))
        }

        #expect(await error { try await task.value } is CancellationError)
    }

    @Test func aFinishedWaitStopsReading() async throws {
        let registry = makePlainRegistry()
        _ = await error { try await registry.wait(forProbe: "count", until: .equals(value: .int(1)), timeout: .milliseconds(150)) }
        let reads = plain.reads

        try await Task.sleep(for: .milliseconds(300))

        #expect(plain.reads == reads)
    }
}
