import Observation
import SaveStateUI

/// A premium manager written for PremiumToggle, which keeps working on SaveState.
@MainActor
@Observable
final class DemoPremiumManager: PremiumStatusProvider {
    var isPremium: Bool { debugOverride ?? false }
    private(set) var debugOverride: Bool?

    let allowsDebugOverride: Bool
    private let storage = PremiumDebugOverride()

    init(allowsDebugOverride: Bool) {
        self.allowsDebugOverride = allowsDebugOverride
        if allowsDebugOverride {
            debugOverride = storage.value
        }
    }

    func setDebugOverride(_ value: Bool?) {
        guard allowsDebugOverride else { return }
        storage.value = value
        debugOverride = value
    }
}
