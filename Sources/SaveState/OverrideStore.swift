import Foundation
import SaveStateProtocol

/// Where a registry keeps control values that outlast the current launch.
///
/// Values live in a `UserDefaults` suite as JSON, under keys that start with
/// the prefix and end with the control's key.
public struct OverrideStore: Sendable {
    /// The standard `UserDefaults`, with keys prefixed `savestate.`.
    public static let standard = OverrideStore()

    /// A store that keeps nothing, for controls whose model persists its own
    /// values. Nothing is restored at launch, and `persist` has no effect.
    public static let discarding = OverrideStore(isDiscarding: true)

    /// How long a stored value lasts.
    enum Slot: String, CaseIterable {
        /// Restored at every launch until reset.
        case persisted = "value."
        /// Restored at the next launch only.
        case nextLaunch = "next-launch."
    }

    private let suiteName: String?
    private let prefix: String
    private let isDiscarding: Bool

    /// - Parameters:
    ///   - suiteName: A `UserDefaults` suite, or `nil` for `.standard`. Use an
    ///     App Group suite to share values with extensions.
    ///   - prefix: Starts every key SaveState writes.
    public init(suiteName: String? = nil, prefix: String = "savestate.") {
        self.init(suiteName: suiteName, prefix: prefix, isDiscarding: false)
    }

    init(suiteName: String? = nil, prefix: String = "savestate.", isDiscarding: Bool) {
        self.suiteName = suiteName
        self.prefix = prefix
        self.isDiscarding = isDiscarding
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
        guard !isDiscarding else { return nil }
        let defaultsKey = defaultsKey(forKey: key, in: slot)
        guard let data = defaults.data(forKey: defaultsKey) else { return nil }
        guard let value = try? JSONDecoder().decode(ControlValue.self, from: data) else {
            defaults.removeObject(forKey: defaultsKey)
            return nil
        }
        return value
    }

    func save(_ value: ControlValue, forKey key: String, in slot: Slot) {
        guard !isDiscarding else { return }
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: defaultsKey(forKey: key, in: slot))
    }

    func remove(forKey key: String, in slot: Slot) {
        guard !isDiscarding else { return }
        defaults.removeObject(forKey: defaultsKey(forKey: key, in: slot))
    }

    func removeAll(forKey key: String) {
        for slot in Slot.allCases {
            remove(forKey: key, in: slot)
        }
    }
}
