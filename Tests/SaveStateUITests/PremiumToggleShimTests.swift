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

    /// The provider owns the override, so the control reports what the provider
    /// holds rather than what was asked for.
    @Test func aProviderThatRefusesAnOverrideStillShowsNoOverride() throws {
        let manager = SampleManager(allowsDebugOverride: false, storage: storage)
        let registry = PremiumProviderModel.makeRegistry(for: manager)

        try registry.set(.bool(true), forKey: "premium", persist: true)

        let control = try premium(registry)
        #expect(control.value == .null)
        #expect(!control.isChanged)
    }

    @Test func storageKeepsOverridesUnderACustomKeyApart() {
        let other = PremiumDebugOverride(suiteName: suiteName, key: "other")

        other.value = false

        #expect(other.key == "other")
        #expect(other.value == false)
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

@Suite("PremiumToggle shim display")
@MainActor
struct PremiumToggleModelTests {
    private let scratch = ScratchSuite()
    private var storage: PremiumDebugOverride { PremiumDebugOverride(suiteName: scratch.name) }

    @Test func aFreeProviderReportsPremiumOff() {
        let model = PremiumToggleModel(provider: SampleManager(storage: storage))

        #expect(model.statusText == "Premium is off")
        #expect(model.statusImage == "crown")
        #expect(model.accessibilityValue == "Premium off")
    }

    @Test func anEntitledProviderReportsPremiumOn() {
        let manager = SampleManager(storage: storage)
        manager.isEntitled = true

        let model = PremiumToggleModel(provider: manager)

        #expect(model.statusText == "Premium is on")
        #expect(model.statusImage == "crown.fill")
        #expect(model.accessibilityValue == "Premium on")
    }

    @Test func statusFollowsTheOverrideRatherThanEntitlement() {
        let manager = SampleManager(storage: storage)
        manager.isEntitled = true
        manager.setDebugOverride(false)

        #expect(PremiumToggleModel(provider: manager).statusText == "Premium is off")
    }

    @Test func statusReadsTheProviderEachTime() {
        let manager = SampleManager(storage: storage)
        let model = PremiumToggleModel(provider: manager)

        manager.setDebugOverride(true)

        #expect(model.statusText == "Premium is on")
    }

    @Test func aProviderThatAcceptsOverridesGetsTheOpenPanel() {
        let manager = SampleManager(allowsDebugOverride: true, storage: storage)

        #expect(PremiumToggleModel(provider: manager).panelMode == .open)
    }

    @Test func aProviderThatBlocksOverridesGetsTheLockedPanel() {
        let manager = SampleManager(allowsDebugOverride: false, storage: storage)

        #expect(PremiumToggleModel(provider: manager).panelMode == .locked)
    }

    @Test func providersAcceptOverridesByDefault() {
        #expect(PremiumToggleModel(provider: MinimalProvider()).panelMode == .open)
    }

    @Test func theOverlayIsHiddenWhenNotEnabled() {
        let manager = SampleManager(storage: storage)

        #expect(PremiumToggleModel.overlay(for: manager, isEnabled: false) == nil)
    }

    @Test func theOverlayShowsWhenEnabled() {
        let manager = SampleManager(storage: storage)

        #expect(PremiumToggleModel.overlay(for: manager, isEnabled: true) != nil)
    }

    /// A Debug run can only check the first branch, so a flag hard-coded to `true`
    /// fails only under `swift test -c release -Xswiftc -enable-testing`.
    @Test func theBuildFlagMatchesHowThisPackageWasCompiled() {
        #if DEBUG
        #expect(PremiumToggleBuild.isDebug)
        #else
        #expect(!PremiumToggleBuild.isDebug)
        #endif
    }
}

/// Implements only what `PremiumStatusProvider` requires.
@MainActor
@Observable
private final class MinimalProvider: PremiumStatusProvider {
    var isPremium: Bool { false }
    var debugOverride: Bool? { nil }

    func setDebugOverride(_ value: Bool?) {}
}

@Suite("PremiumToggle shim's registry")
@MainActor
struct PremiumToggleShimRegistryTests {
    /// The shim's own `isEnabled` decides visibility, so its registry stays enabled
    /// in every configuration. This can only fail in a Release test run.
    @Test func theRegistryIsEnabledInEveryConfiguration() {
        let storage = PremiumDebugOverride(suiteName: "SaveStateUITests.\(UUID().uuidString)")
        let manager = SampleManager(storage: storage)

        #expect(PremiumProviderModel.makeRegistry(for: manager).isEnabled)
    }
}
