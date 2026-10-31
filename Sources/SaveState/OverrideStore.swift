import Foundation
import SaveStateProtocol

/// Where a registry keeps control values that outlast the current launch.
///
/// Values live in a `UserDefaults` suite as JSON, under keys that start with
/// the prefix and end with the control's key.
public struct OverrideStore: Sendable {
    /// The standard `UserDefaults`, with keys prefixed `savestate.`.
    public static let standard = OverrideStore()

    /// How long a stored value lasts.
    enum Slot: String, CaseIterable {
        /// Restored at every launch until reset.
        case persisted = "value."
        /// Restored at the next launch only.
        case nextLaunch = "next-launch."
    }

    private let suiteName: String?
    private let prefix: String

    /// - Parameters:
    ///   - suiteName: A `UserDefaults` suite, or `nil` for `.standard`. Use an
    ///     App Group suite to share values with extensions.
    ///   - prefix: Starts every key SaveState writes.
    public init(suiteName: String? = nil, prefix: String = "savestate.") {
        self.suiteName = suiteName
        self.prefix = prefix
    }

    private var defaults: UserDefaults {
        suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    }

    /// The `UserDefaults` key for a control's slot. Slots start with different
    /// letters, so no two control keys share a defaults key.
    func defaultsKey(forKey key: String, in slot: Slot) -> String {
        prefix + slot.rawValue + key
    }

    func value(forKey key: String, in slot: Slot) -> ControlValue? {
        let defaultsKey = defaultsKey(forKey: key, in: slot)
        guard let data = defaults.data(forKey: defaultsKey) else { return nil }
        guard let value = try? JSONDecoder().decode(ControlValue.self, from: data) else {
            defaults.removeObject(forKey: defaultsKey)
            return nil
        }
        return value
    }

    func save(_ value: ControlValue, forKey key: String, in slot: Slot) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: defaultsKey(forKey: key, in: slot))
    }

    func remove(forKey key: String, in slot: Slot) {
        defaults.removeObject(forKey: defaultsKey(forKey: key, in: slot))
    }

    func removeAll(forKey key: String) {
        for slot in Slot.allCases {
            remove(forKey: key, in: slot)
        }
    }
}
