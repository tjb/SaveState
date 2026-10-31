import Foundation
import SaveStateProtocol

/// Where a registry keeps control values that should survive a relaunch.
///
/// Values live in a `UserDefaults` suite, each under the prefix plus the
/// control's key, encoded as JSON.
public struct OverrideStore: Sendable {
    /// The standard `UserDefaults`, with keys prefixed `savestate.`.
    public static let standard = OverrideStore()

    private let suiteName: String?
    private let prefix: String

    /// - Parameters:
    ///   - suiteName: A `UserDefaults` suite, or `nil` for `.standard`. Use an
    ///     App Group suite to share values with extensions.
    ///   - prefix: Prepended to each control key.
    public init(suiteName: String? = nil, prefix: String = "savestate.") {
        self.suiteName = suiteName
        self.prefix = prefix
    }

    private var defaults: UserDefaults {
        suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    }

    func load(forKey key: String) -> ControlValue? {
        guard let data = defaults.data(forKey: prefix + key) else { return nil }
        guard let value = try? JSONDecoder().decode(ControlValue.self, from: data) else {
            remove(forKey: key)
            return nil
        }
        return value
    }

    func save(_ value: ControlValue, forKey key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: prefix + key)
    }

    func remove(forKey key: String) {
        defaults.removeObject(forKey: prefix + key)
    }
}
