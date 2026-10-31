import Foundation
import Testing
@testable import SaveState

@Suite("OverrideStore")
struct OverrideStoreTests {
    private let scratch = ScratchDefaults()

    private func defaults() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: scratch.suiteName))
    }

    // MARK: - Keys

    /// Stored values outlast app updates, so these keys can't change.
    @Test func defaultsKeysKeepTheirFormat() {
        let store = OverrideStore.standard

        #expect(store.defaultsKey(forKey: "env", in: .persisted) == "savestate.value.env")
        #expect(store.defaultsKey(forKey: "env", in: .nextLaunch) == "savestate.next-launch.env")
    }

    @Test func aCustomPrefixStartsEveryKey() {
        let store = OverrideStore(suiteName: scratch.suiteName, prefix: "qa.")

        #expect(store.defaultsKey(forKey: "env", in: .persisted) == "qa.value.env")
    }

    @Test func aControlKeyThatLooksLikeASlotDoesNotCollide() {
        let store = scratch.store

        store.save(.int(1), forKey: "next-launch.env", in: .persisted)
        store.save(.int(2), forKey: "value.env", in: .nextLaunch)

        #expect(store.value(forKey: "env", in: .persisted) == nil)
        #expect(store.value(forKey: "env", in: .nextLaunch) == nil)
        #expect(store.value(forKey: "next-launch.env", in: .persisted) == .int(1))
        #expect(store.value(forKey: "value.env", in: .nextLaunch) == .int(2))
    }

    // MARK: - Storing

    @Test(arguments: [
        ControlValue.null,
        .bool(false),
        .string("staging"),
        .int(-3),
        .double(0.25),
        .date(Date(timeIntervalSince1970: 1_800_000_000.25))
    ])
    func everyKindOfValueReadsBack(_ value: ControlValue) {
        let store = scratch.store

        store.save(value, forKey: "key", in: .persisted)

        #expect(store.value(forKey: "key", in: .persisted) == value)
    }

    @Test func anAbsentValueReadsAsNil() {
        #expect(scratch.store.value(forKey: "missing", in: .persisted) == nil)
    }

    @Test func savingReplacesTheEarlierValue() {
        let store = scratch.store

        store.save(.int(1), forKey: "key", in: .persisted)
        store.save(.int(2), forKey: "key", in: .persisted)

        #expect(store.value(forKey: "key", in: .persisted) == .int(2))
    }

    @Test func slotsHoldSeparateValues() {
        let store = scratch.store

        store.save(.int(1), forKey: "key", in: .persisted)
        store.save(.int(2), forKey: "key", in: .nextLaunch)

        #expect(store.value(forKey: "key", in: .persisted) == .int(1))
        #expect(store.value(forKey: "key", in: .nextLaunch) == .int(2))
    }

    @Test func aValueJSONCannotHoldLeavesTheEarlierValue() {
        let store = scratch.store
        store.save(.double(1), forKey: "key", in: .persisted)

        store.save(.double(.nan), forKey: "key", in: .persisted)

        #expect(store.value(forKey: "key", in: .persisted) == .double(1))
    }

    @Test func storesWithDifferentPrefixesDoNotShareValues() {
        let first = OverrideStore(suiteName: scratch.suiteName, prefix: "first.")
        let second = OverrideStore(suiteName: scratch.suiteName, prefix: "second.")

        first.save(.int(1), forKey: "key", in: .persisted)

        #expect(second.value(forKey: "key", in: .persisted) == nil)
    }

    @Test func storesInDifferentSuitesDoNotShareValues() {
        let other = ScratchDefaults()

        scratch.store.save(.int(1), forKey: "key", in: .persisted)

        #expect(other.store.value(forKey: "key", in: .persisted) == nil)
    }

    // MARK: - Removing

    @Test func removeLeavesTheOtherSlot() {
        let store = scratch.store
        store.save(.int(1), forKey: "key", in: .persisted)
        store.save(.int(2), forKey: "key", in: .nextLaunch)

        store.remove(forKey: "key", in: .nextLaunch)

        #expect(store.value(forKey: "key", in: .nextLaunch) == nil)
        #expect(store.value(forKey: "key", in: .persisted) == .int(1))
    }

    @Test func removeAllClearsEverySlot() {
        let store = scratch.store
        store.save(.int(1), forKey: "key", in: .persisted)
        store.save(.int(2), forKey: "key", in: .nextLaunch)

        store.removeAll(forKey: "key")

        #expect(store.value(forKey: "key", in: .persisted) == nil)
        #expect(store.value(forKey: "key", in: .nextLaunch) == nil)
    }

    @Test func removeAllLeavesOtherControls() {
        let store = scratch.store
        store.save(.int(1), forKey: "other", in: .persisted)

        store.removeAll(forKey: "key")

        #expect(store.value(forKey: "other", in: .persisted) == .int(1))
    }

    // MARK: - Bad data

    @Test(arguments: [#"{"type":"color","value":"red"}"#, #"{"type":"bool"}"#, "[]"])
    func jsonThatIsNotAValueIsDeleted(_ text: String) throws {
        let store = scratch.store
        let key = store.defaultsKey(forKey: "key", in: .nextLaunch)
        try defaults().set(Data(text.utf8), forKey: key)

        #expect(store.value(forKey: "key", in: .nextLaunch) == nil)
        #expect(try defaults().object(forKey: key) == nil)
    }

    @Test func aStoredObjectThatIsNotDataReadsAsNil() throws {
        let store = scratch.store
        try defaults().set("a string", forKey: store.defaultsKey(forKey: "key", in: .persisted))

        #expect(store.value(forKey: "key", in: .persisted) == nil)
    }

    // MARK: - Discarding

    @Test func aDiscardingStoreDoesNotWriteToTheSuite() {
        OverrideStore(suiteName: scratch.suiteName, isDiscarding: true).save(.int(1), forKey: "key", in: .persisted)

        #expect(scratch.store.value(forKey: "key", in: .persisted) == nil)
    }

    /// The registration domain lives in this process's memory, so this never
    /// writes to the real `UserDefaults.standard` domain.
    @Test func theSharedDiscardingStoreReadsNothing() throws {
        let key = "savestate-test-\(UUID().uuidString)"
        let stored = try JSONEncoder().encode(ControlValue.int(1))
        UserDefaults.standard.register(defaults: [
            OverrideStore.standard.defaultsKey(forKey: key, in: .persisted): stored
        ])

        #expect(OverrideStore.standard.value(forKey: key, in: .persisted) == .int(1))
        #expect(OverrideStore.discarding.value(forKey: key, in: .persisted) == nil)
    }

    @Test func aDiscardingStoreDoesNotReadTheSuite() {
        scratch.store.save(.int(1), forKey: "key", in: .persisted)

        let discarding = OverrideStore(suiteName: scratch.suiteName, isDiscarding: true)

        #expect(discarding.value(forKey: "key", in: .persisted) == nil)
    }

    @Test func aDiscardingStoreDoesNotRemoveFromTheSuite() {
        scratch.store.save(.int(1), forKey: "key", in: .persisted)

        OverrideStore(suiteName: scratch.suiteName, isDiscarding: true).removeAll(forKey: "key")

        #expect(scratch.store.value(forKey: "key", in: .persisted) == .int(1))
    }
}
