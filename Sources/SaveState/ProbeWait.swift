import Observation
import SaveStateProtocol

/// One wait for a probe to meet a condition. `SaveStateRegistry.wait` runs it.
///
/// It checks the probe, then sleeps until something could have changed it: an
/// observable value the probe read, a regular tick for state that isn't
/// observable, or the deadline. Each of those only wakes the loop, which does
/// every read itself on the main actor.
@MainActor
struct ProbeWait {
    let key: String
    let condition: ProbeCondition
    let timeout: Duration
    var tick: Duration = .milliseconds(100)
    let read: @MainActor () -> ControlValue

    /// Returns the first value that meets the condition.
    func run() async throws -> ControlValue {
        try Task.checkCancellation()
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        // Only the latest wake matters, since every wake leads to a fresh read.
        let (wakes, wake) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        defer { wake.finish() }
        let tick = tick
        return try await withThrowingTaskGroup(of: Void.self) { group in
            // Cancelled before the group waits for its children, so neither outlives the wait.
            defer { group.cancelAll() }
            group.addTask {
                while (try? await Task.sleep(for: tick)) != nil {
                    wake.yield()
                }
            }
            group.addTask {
                if (try? await clock.sleep(until: deadline)) != nil {
                    wake.yield()
                }
            }
            var wakeups = wakes.makeAsyncIterator()
            while true {
                let checkedAt = clock.now
                let value = withObservationTracking({ read() }, onChange: { wake.yield() })
                guard let isMet = condition.isMet(by: value) else {
                    throw SaveStateError.invalidCondition(key: key, condition: condition, value: value)
                }
                if isMet {
                    return value
                }
                guard checkedAt < deadline else {
                    throw SaveStateError.timedOut(key: key, timeout: timeout)
                }
                // Returns `nil` once the task is cancelled.
                _ = await wakeups.next()
                try Task.checkCancellation()
            }
        }
    }
}
