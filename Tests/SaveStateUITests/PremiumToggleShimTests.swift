import Foundation
import Observation
import SaveState
import Testing
@testable import SaveStateUI

/// The provider pattern from PremiumToggle's README.
@MainActor
@Observable
private final class SampleManager: PremiumStatusProvider {
    var isPremium: Bool { debugOverride ?? isEntitled }
    private(set) var debugOverride: Bool?
    var isEntitled = false

    let allowsDebugOverride: Bool
    private let storage: PremiumDebugOverride

    init(allowsDebugOverride: Bool = true, storage: PremiumDebugOverride) {
        self.allowsDebugOverride = allowsDebugOverride
        self.storage = storage
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

/// A `UserDefaults` suite for one test, removed when the test ends.
private final class ScratchSuite: Sendable {
    let name = "SaveStateUITests.\(UUID().uuidString)"

    deinit {
        UserDefaults.standard.removePersistentDomain(forName: name)
    }
}

@Suite("PremiumToggle shim")
@MainActor
struct PremiumToggleShimTests {
    private let scratch = ScratchSuite()
    private var suiteName: String { scratch.name }
    private var storage: PremiumDebugOverride { PremiumDebugOverride(suiteName: suiteName) }

    private func premium(_ registry: SaveStateRegistry) throws -> ControlDescription {
        try #require(registry.describe().controls.first { $0.key == "premium" })
    }

    @Test func noOverrideIsTheDefault() throws {
        let registry = PremiumProviderModel.makeRegistry(for: SampleManager(storage: storage))

        let control = try premium(registry)
        #expect(control.kind == .triState)
        #expect(control.value == .null)
        #expect(!control.isChanged)
    }

    @Test func settingWritesThroughTheProvider() throws {
        let manager = SampleManager(storage: storage)
        let registry = PremiumProviderModel.makeRegistry(for: manager)

        try registry.set(.bool(true), forKey: "premium", persist: true)

        #expect(manager.isPremium)
        #expect(storage.value == true)
        #expect(try premium(registry).isChanged)
    }

    @Test func aRestoredOverrideShowsAsChangedAndResetsToRealStatus() throws {
        storage.value = true
        let manager = SampleManager(storage: storage)
        let registry = PremiumProviderModel.makeRegistry(for: manager)

        #expect(try premium(registry).value == .bool(true))
        #expect(try premium(registry).isChanged)

        try registry.resetAll()

        #expect(manager.debugOverride == nil)
        #expect(storage.value == nil)
        #expect(!manager.isPremium)
    }

    @Test func creatingARegistryLeavesTheProviderAlone() {
        storage.value = false
        let manager = SampleManager(storage: storage)

        _ = PremiumProviderModel.makeRegistry(for: manager)

        #expect(manager.debugOverride == false)
        #expect(storage.value == false)
    }

    @Test func aChangeMadeOutsideThePanelIsVisible() throws {
        let manager = SampleManager(storage: storage)
        let registry = PremiumProviderModel.makeRegistry(for: manager)

        manager.setDebugOverride(true)

        #expect(try premium(registry).value == .bool(true))
    }

    @Test func aProviderThatBlocksOverridesStaysUnchanged() throws {
        let manager = SampleManager(allowsDebugOverride: false, storage: storage)
        let registry = PremiumProviderModel.makeRegistry(for: manager)

        try registry.set(.bool(true), forKey: "premium", persist: true)

        #expect(manager.debugOverride == nil)
        #expect(storage.value == nil)
    }

    @Test func storageRoundTripsUnderTheKeyPremiumToggleUsed() {
        #expect(PremiumDebugOverride.defaultKey == "debug_premium_override")
        storage.value = true
        let raw = UserDefaults(suiteName: suiteName)?.object(forKey: "debug_premium_override")
        #expect(raw as? Bool == true)
        storage.value = nil
        #expect(storage.value == nil)
    }
}
