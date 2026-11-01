import Foundation
import Testing
@testable import SaveState

/// `SaveStateClock` is process-wide, so every test that moves it lives in this
/// serialized suite and puts it back on real time when it finishes.
@Suite("Clock", .serialized)
@MainActor
struct ClockTests {
    private let scratch = ScratchDefaults()

    @Test func readsRealTimeWithoutAnOverride() {
        SaveStateClock.overrideDate = nil

        #expect(SaveStateClock.overrideDate == nil)
        #expect(abs(SaveStateClock.now.timeIntervalSinceNow) < 1)
    }

    @Test func overrideMovesNowAndNilRestoresRealTime() {
        defer { SaveStateClock.overrideDate = nil }
        let target = Date().addingTimeInterval(8 * 86_400)

        SaveStateClock.overrideDate = target
        #expect(SaveStateClock.overrideDate == target)
        #expect(abs(SaveStateClock.now.timeIntervalSince(target)) < 1)

        SaveStateClock.overrideDate = nil
        #expect(abs(SaveStateClock.now.timeIntervalSinceNow) < 1)
    }

    @Test func nowRunsForwardWhileTheOverrideStaysFixed() async throws {
        defer { SaveStateClock.overrideDate = nil }
        let target = Date(timeIntervalSince1970: 1_800_000_000)

        SaveStateClock.overrideDate = target
        try await Task.sleep(for: .milliseconds(100))

        #expect(SaveStateClock.overrideDate == target)
        let elapsed = SaveStateClock.now.timeIntervalSince(target)
        #expect(elapsed > 0.05)
        #expect(elapsed < 30)
    }

    @Test func clockControlMovesTheClock() throws {
        defer { SaveStateClock.overrideDate = nil }
        SaveStateClock.overrideDate = nil
        let registry = SaveStateRegistry(model: DebugModel(), store: scratch.store, isEnabled: true) { r in
            r.clock()
        }
        let target = Date(timeIntervalSince1970: 1_800_000_000)

        try registry.set(.date(target), forKey: "clock")

        #expect(SaveStateClock.overrideDate == target)
        #expect(registry.changedKeys == ["clock"])
        let control = try #require(registry.describe().controls.first)
        #expect(control.key == "clock")
        #expect(control.kind == .clock)
        #expect(control.value == .date(target))
        #expect(control.realValue == nil)
        #expect(control.defaultValue == .null)
        guard case .date(let effective) = control.effectiveValue else {
            Issue.record("Expected the clock's effective value to be a date")
            return
        }
        #expect(effective >= target)
        #expect(effective.timeIntervalSince(target) < 30)

        try registry.reset("clock")

        #expect(SaveStateClock.overrideDate == nil)
        #expect(registry.changedKeys.isEmpty)
        let value = try registry.value(forKey: "clock")
        #expect(value == .null)
        guard case .date(let realNow) = try registry.effectiveValue(forKey: "clock") else {
            Issue.record("Expected the clock's effective value to be a date")
            return
        }
        #expect(abs(realNow.timeIntervalSinceNow) < 1)
    }

    @Test func clockValueIsStableBetweenReads() async throws {
        defer { SaveStateClock.overrideDate = nil }
        let registry = SaveStateRegistry(model: DebugModel(), store: scratch.store, isEnabled: true) { r in
            r.clock()
        }
        try registry.set(.date(Date(timeIntervalSince1970: 1_800_000_000)), forKey: "clock")

        let first = try registry.value(forKey: "clock")
        try await Task.sleep(for: .milliseconds(20))
        let second = try registry.value(forKey: "clock")

        #expect(first == second)
    }

    @Test func clockControlRejectsNonDates() {
        defer { SaveStateClock.overrideDate = nil }
        let registry = SaveStateRegistry(model: DebugModel(), store: scratch.store, isEnabled: true) { r in
            r.clock()
        }

        #expect(throws: SaveStateError.invalidValue(key: "clock", value: .bool(true), kind: .clock)) {
            try registry.set(.bool(true), forKey: "clock")
        }
    }

    @Test func persistedClockOverrideRestartsFromItsDateAtLaunch() throws {
        defer { SaveStateClock.overrideDate = nil }
        let store = scratch.store
        let target = Date(timeIntervalSince1970: 1_800_000_000)
        let first = SaveStateRegistry(model: DebugModel(), store: store, isEnabled: true) { r in
            r.clock()
        }
        try first.set(.date(target), forKey: "clock", persist: true)
        SaveStateClock.overrideDate = nil

        _ = SaveStateRegistry(model: DebugModel(), store: store, isEnabled: true) { r in
            r.clock()
        }

        let restored = try #require(SaveStateClock.overrideDate)
        #expect(ControlValue.date(restored) == .date(target))
    }

    private func makeClockRegistry(store: OverrideStore, isEnabled: Bool = true) -> SaveStateRegistry {
        SaveStateRegistry(model: DebugModel(), store: store, isEnabled: isEnabled) { r in
            r.clock()
        }
    }

    @Test func aSessionClockValueDoesNotReturnAtLaunch() throws {
        defer { SaveStateClock.overrideDate = nil }
        let store = scratch.store
        try makeClockRegistry(store: store).set(.date(Date(timeIntervalSince1970: 1_800_000_000)), forKey: "clock")
        SaveStateClock.overrideDate = nil

        _ = makeClockRegistry(store: store)

        #expect(SaveStateClock.overrideDate == nil)
    }

    @Test func aResetClockValueDoesNotReturnAtLaunch() throws {
        defer { SaveStateClock.overrideDate = nil }
        let store = scratch.store
        let first = makeClockRegistry(store: store)
        try first.set(.date(Date(timeIntervalSince1970: 1_800_000_000)), forKey: "clock", persist: true)
        try first.reset("clock")

        _ = makeClockRegistry(store: store)

        #expect(SaveStateClock.overrideDate == nil)
    }

    @Test func aPersistedNullReturnsTheClockToRealTimeAtLaunch() throws {
        defer { SaveStateClock.overrideDate = nil }
        let store = scratch.store
        try makeClockRegistry(store: store).set(.null, forKey: "clock", persist: true)
        SaveStateClock.overrideDate = Date(timeIntervalSince1970: 1_800_000_000)

        _ = makeClockRegistry(store: store)

        #expect(SaveStateClock.overrideDate == nil)
    }

    @Test func aRestoredClockRunsForwardFromItsDate() throws {
        defer { SaveStateClock.overrideDate = nil }
        let store = scratch.store
        let target = Date(timeIntervalSince1970: 1_800_000_000)
        store.save(.date(target), forKey: "clock", in: .persisted)

        _ = makeClockRegistry(store: store)

        let elapsed = SaveStateClock.now.timeIntervalSince(target)
        #expect(elapsed >= 0)
        #expect(elapsed < 30)
    }

    @Test func aStoredValueTheClockRefusesIsDropped() {
        defer { SaveStateClock.overrideDate = nil }
        SaveStateClock.overrideDate = nil
        let store = scratch.store
        store.save(.string("tomorrow"), forKey: "clock", in: .persisted)

        _ = makeClockRegistry(store: store)

        #expect(SaveStateClock.overrideDate == nil)
        #expect(store.value(forKey: "clock", in: .persisted) == nil)
    }

    @Test func aDisabledRegistryDoesNotMoveTheClock() {
        defer { SaveStateClock.overrideDate = nil }
        SaveStateClock.overrideDate = nil
        let store = scratch.store
        store.save(.date(Date(timeIntervalSince1970: 1_800_000_000)), forKey: "clock", in: .persisted)

        _ = makeClockRegistry(store: store, isEnabled: false)

        #expect(SaveStateClock.overrideDate == nil)
    }

    @Test func aClockMovedBeforeTheRegistryCountsAsChangedAndResetsToRealTime() throws {
        defer { SaveStateClock.overrideDate = nil }
        SaveStateClock.overrideDate = Date(timeIntervalSince1970: 1_800_000_000)
        let registry = makeClockRegistry(store: scratch.store)
        #expect(registry.changedKeys == ["clock"])

        try registry.reset("clock")

        #expect(SaveStateClock.overrideDate == nil)
    }

    @Test func aScenarioThatMovesTheClockShowsAsChanged() async throws {
        defer { SaveStateClock.overrideDate = nil }
        SaveStateClock.overrideDate = nil
        let target = Date(timeIntervalSince1970: 1_800_000_000)
        let registry = SaveStateRegistry(model: DebugModel(), store: scratch.store, isEnabled: true) { r in
            r.clock()
            r.scenario("Future", key: "future") { _ in
                SaveStateClock.overrideDate = target
            }
        }

        try await registry.applyScenario("future")

        #expect(registry.changedKeys == ["clock"])
    }

    @Test func aFailedScenarioKeepsTheClockItMoved() async {
        defer { SaveStateClock.overrideDate = nil }
        SaveStateClock.overrideDate = nil
        let target = Date(timeIntervalSince1970: 1_800_000_000)
        let registry = SaveStateRegistry(model: DebugModel(), store: scratch.store, isEnabled: true) { r in
            r.clock()
            r.scenario("Future", key: "future") { _ in
                SaveStateClock.overrideDate = target
                throw TestError.failed
            }
        }

        await #expect(throws: TestError.failed) {
            try await registry.applyScenario("future")
        }

        #expect(SaveStateClock.overrideDate == target)
    }

    @Test func clockControlRefusesADateJSONWouldChange() {
        defer { SaveStateClock.overrideDate = nil }
        SaveStateClock.overrideDate = nil
        let registry = makeClockRegistry(store: scratch.store)
        let beforeYearOne = ControlValue.date(Date(timeIntervalSince1970: -62_200_000_000))

        #expect(throws: SaveStateError.invalidValue(key: "clock", value: beforeYearOne, kind: .clock)) {
            try registry.set(beforeYearOne, forKey: "clock", persist: true)
        }

        #expect(SaveStateClock.overrideDate == nil)
    }

    @Test func clockBindingIgnoresAValueThatIsNotADateOrNull() {
        defer { SaveStateClock.overrideDate = nil }
        let target = Date(timeIntervalSince1970: 1_800_000_000)
        SaveStateClock.overrideDate = target

        ClockBinding().write(.string("tomorrow"))

        #expect(SaveStateClock.overrideDate == target)
    }

    @Test func clockBindingClearsOnNull() {
        defer { SaveStateClock.overrideDate = nil }
        SaveStateClock.overrideDate = Date(timeIntervalSince1970: 1_800_000_000)

        ClockBinding().write(.null)

        #expect(SaveStateClock.overrideDate == nil)
    }
}
