import Foundation
import Testing
@testable import SaveState

/// `SaveStateClock` is process-wide, so every test that moves it lives in this
/// serialized suite and puts it back on real time when it finishes.
@Suite("Clock", .serialized)
@MainActor
struct ClockTests {
    @Test func readsRealTimeWithoutAnOverride() {
        SaveStateClock.overrideDate = nil

        #expect(SaveStateClock.overrideDate == nil)
        #expect(abs(SaveStateClock.now.timeIntervalSinceNow) < 1)
    }

    @Test func overrideMovesNowAndNilRestoresRealTime() {
        defer { SaveStateClock.overrideDate = nil }
        let target = Date().addingTimeInterval(8 * 86_400)

        SaveStateClock.overrideDate = target
        #expect(abs(SaveStateClock.now.timeIntervalSince(target)) < 1)

        SaveStateClock.overrideDate = nil
        #expect(abs(SaveStateClock.now.timeIntervalSinceNow) < 1)
    }

    @Test func overrideKeepsTicking() async throws {
        defer { SaveStateClock.overrideDate = nil }
        let target = Date(timeIntervalSince1970: 1_800_000_000)

        SaveStateClock.overrideDate = target
        try await Task.sleep(for: .milliseconds(100))

        let elapsed = SaveStateClock.now.timeIntervalSince(target)
        #expect(elapsed > 0.05)
        #expect(elapsed < 30)
    }

    @Test func clockControlMovesTheClock() throws {
        defer { SaveStateClock.overrideDate = nil }
        SaveStateClock.overrideDate = nil
        let registry = SaveStateRegistry(model: DebugModel(), store: makeStore(), isEnabled: true) { r in
            r.clock()
        }
        let target = Date().addingTimeInterval(-30 * 86_400)

        try registry.set(.date(target), forKey: "clock")

        let override = try #require(SaveStateClock.overrideDate)
        #expect(abs(override.timeIntervalSince(target)) < 1)
        #expect(registry.changedKeys == ["clock"])
        let control = try #require(registry.describe().controls.first)
        #expect(control.key == "clock")
        #expect(control.kind == .date)
        #expect(control.defaultValue == .null)

        try registry.reset("clock")

        #expect(SaveStateClock.overrideDate == nil)
        #expect(registry.changedKeys.isEmpty)
        let value = try registry.value(forKey: "clock")
        #expect(value == .null)
        guard case .date(let effective) = try registry.effectiveValue(forKey: "clock") else {
            Issue.record("Expected the clock's effective value to be a date")
            return
        }
        #expect(abs(effective.timeIntervalSinceNow) < 1)
    }

    @Test func clockControlRejectsNonDates() {
        defer { SaveStateClock.overrideDate = nil }
        let registry = SaveStateRegistry(model: DebugModel(), store: makeStore(), isEnabled: true) { r in
            r.clock()
        }

        #expect(throws: SaveStateError.invalidValue(key: "clock", value: .bool(true), kind: .date)) {
            try registry.set(.bool(true), forKey: "clock")
        }
    }

    @Test func persistedClockOverrideSurvivesRelaunch() throws {
        defer { SaveStateClock.overrideDate = nil }
        let store = makeStore()
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
        #expect(abs(restored.timeIntervalSince(target)) < 1)
    }
}
