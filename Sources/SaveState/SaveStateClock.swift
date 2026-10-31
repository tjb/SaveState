import Foundation
import Synchronization

/// A clock you can move while debugging.
///
/// Read `SaveStateClock.now` instead of `Date()` wherever "now" decides
/// behavior: trial expiry, streaks, "last opened" checks. With no override it
/// returns `Date()`.
///
/// An override is time travel, not a frozen clock: time keeps running forward
/// from the moment you set. Overrides come from an enabled `SaveStateRegistry`
/// (its `clock()` control) or from your own debug code, so a Release build
/// without an enabled registry always reads real time.
///
/// It is safe to read from any thread or task.
public enum SaveStateClock {
    private static let storedOffset = Mutex<TimeInterval?>(nil)

    /// The current date, shifted by the override when one is set.
    public static var now: Date {
        guard let offset = storedOffset.withLock({ $0 }) else { return Date() }
        return Date(timeIntervalSinceNow: offset)
    }

    /// The overridden current date, or `nil` when the clock runs on real time.
    ///
    /// Setting a date moves the clock there, and time keeps running from it.
    /// Setting `nil` returns the clock to real time.
    public static var overrideDate: Date? {
        get {
            storedOffset.withLock({ $0 }).map { Date(timeIntervalSinceNow: $0) }
        }
        set {
            let offset = newValue?.timeIntervalSinceNow
            storedOffset.withLock { $0 = offset }
        }
    }
}
