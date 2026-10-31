import Observation
import SaveStateUI

/// A premium manager written for PremiumToggle, which keeps working on SaveState.
@MainActor
@Observable
final class DemoPremiumManager: PremiumStatusProvider {
    var isPremium: Bool { debugOverride ?? false }
    private(set) var debugOverride: Bool?

    private let storage = PremiumDebugOverride()

    init() {
        debugOverride = storage.value
    }

    func setDebugOverride(_ value: Bool?) {
        storage.value = value
        debugOverride = value
    }
}
