import Foundation
import Synchronization

/// A clock you can move while debugging.
///
/// Read `SaveStateClock.now` instead of `Date()` wherever "now" decides
/// behavior: trial expiry, streaks, "last opened" checks. With no override it
/// returns `Date()`.
///
/// An override is time travel, not a frozen clock: `now` starts at the date
/// you set and keeps running forward. Overrides come from an enabled
/// `SaveStateRegistry` (its `clock()` control) or from your own debug code, so
/// a Release build without an enabled registry always reads real time.
///
/// It is safe to read from any thread or task.
public enum SaveStateClock {
    private struct Override: Sendable {
        /// The date the clock was moved to.
        var start: Date
        /// The real time when it was moved.
        var realStart: Date
    }

    private static let storedOverride = Mutex<Override?>(nil)

    /// The current date: real time, or the override's date plus the time that
    /// has passed since it was set.
    public static var now: Date {
        let realNow = Date()
        guard let override = storedOverride.withLock({ $0 }) else { return realNow }
        return override.start.addingTimeInterval(realNow.timeIntervalSince(override.realStart))
    }

    /// The date the clock was last moved to, or `nil` when it runs on real
    /// time.
    ///
    /// This stays fixed while `now` runs forward from it. Setting a date moves
    /// the clock there; setting `nil` returns it to real time.
    public static var overrideDate: Date? {
        get {
            storedOverride.withLock({ $0 })?.start
        }
        set {
            let override = newValue.map { Override(start: $0, realStart: Date()) }
            storedOverride.withLock { $0 = override }
        }
    }
}
