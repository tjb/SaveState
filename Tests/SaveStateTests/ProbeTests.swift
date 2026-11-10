import Foundation
import Observation
import Testing
@testable import SaveState

/// Probe state that SwiftUI and waits can observe.
@MainActor
@Observable
final class SyncModel {
    var pendingUploads = 0
    var isConnected = false
    var progress = 0.0
    var status = "idle"
    var lastSync = Date(timeIntervalSince1970: 1_800_000_000)
}

/// Probe state that nothing can observe, so only a wait's tick sees it change.
@MainActor
final class PlainModel {
    var count = 0
    var reads = 0
}

@MainActor
func makeProbeRegistry(sync: SyncModel, isEnabled: Bool = true) -> SaveStateRegistry {
    SaveStateRegistry(model: sync, store: ScratchDefaults().store, isEnabled: isEnabled) { r in
        r.toggle("Connected", key: "connected-override", \.isConnected)
        r.section("Sync") {
            r.probe("Pending uploads", key: "sync.pending-uploads") { sync.pendingUploads }
            r.probe("Connected", key: "sync.connected") { sync.isConnected }
        }
        r.probe("Progress", key: "progress") { sync.progress }
        r.probe("Status", key: "status") { sync.status }
        r.probe("Last sync", key: "last-sync") { sync.lastSync }
    }
}

@Suite("Probes")
@MainActor
struct ProbeTests {
    private let sync = SyncModel()

    @Test func eachProbeTypeReportsItsValue() {
        let registry = makeProbeRegistry(sync: sync)

        let values = registry.describe().probes.map(\.value)

        #expect(values == [
            .int(0),
            .bool(false),
            .double(0),
            .string("idle"),
            .date(Date(timeIntervalSince1970: 1_800_000_000))
        ])
    }

    @Test func probesKeepTheirOrderLabelsAndSections() {
        let registry = makeProbeRegistry(sync: sync)

        let probes = registry.describe().probes

        #expect(probes.map(\.key) == ["sync.pending-uploads", "sync.connected", "progress", "status", "last-sync"])
        #expect(probes.map(\.label) == ["Pending uploads", "Connected", "Progress", "Status", "Last sync"])
        #expect(probes.map(\.section) == ["Sync", "Sync", nil, nil, nil])
    }

    @Test func probesAreReadAtEachDescribe() {
        let registry = makeProbeRegistry(sync: sync)

        sync.pendingUploads = 4

        #expect(registry.describe().probes.first?.value == .int(4))
    }

    @Test func readingOneProbeReadsOnlyThatProbe() throws {
        let plain = PlainModel()
        var otherReads = 0
        let registry = SaveStateRegistry(model: plain, store: ScratchDefaults().store, isEnabled: true) { r in
            r.probe("Count", key: "count") {
                plain.reads += 1
                return plain.count
            }
            r.probe("Other", key: "other") {
                otherReads += 1
                return true
            }
        }
        plain.count = 7

        let probe = try registry.probe(forKey: "count")

        #expect(probe == ProbeDescription(key: "count", label: "Count", section: nil, value: .int(7)))
        #expect(plain.reads == 1)
        #expect(otherReads == 0)
    }

    @Test func anUnknownProbeKeyThrows() {
        let registry = makeProbeRegistry(sync: sync)

        #expect(throws: SaveStateError.unknownProbe("nope")) {
            try registry.probe(forKey: "nope")
        }
    }

    @Test func aControlKeyIsNotAProbeKey() {
        let registry = makeProbeRegistry(sync: sync)

        #expect(throws: SaveStateError.unknownProbe("connected-override")) {
            try registry.probe(forKey: "connected-override")
        }
    }

    @Test func oneControlMatchesItsEntryInTheDescription() throws {
        let registry = makeRegistry(model: DebugModel(), store: ScratchDefaults().store)
        try registry.set(.string("Hi"), forKey: "greeting")

        let control = try registry.control(forKey: "greeting")

        #expect(control == registry.describe().controls.first { $0.key == "greeting" })
        #expect(control.value == .string("Hi"))
    }

    @Test func anUnknownControlKeyThrowsWhenReadAlone() {
        let registry = makeProbeRegistry(sync: sync)

        #expect(throws: SaveStateError.unknownControl("sync.connected")) {
            try registry.control(forKey: "sync.connected")
        }
    }

    @Test func aDisabledRegistryStillReadsProbes() async throws {
        let registry = makeProbeRegistry(sync: sync, isEnabled: false)
        sync.pendingUploads = 2

        #expect(registry.describe().probes.first?.value == .int(2))
        #expect(try registry.probe(forKey: "sync.pending-uploads").value == .int(2))
        let waited = try await registry.wait(
            forProbe: "sync.pending-uploads",
            until: .equals(value: .int(2)),
            timeout: .zero
        )
        #expect(waited.value == .int(2))
    }

    @Test func describeIsNotifiedWhenAnObservableProbeChanges() {
        let registry = makeProbeRegistry(sync: sync)
        let flag = ChangeFlag()
        withObservationTracking {
            _ = registry.describe()
        } onChange: {
            flag.raise()
        }

        sync.status = "uploading"

        #expect(flag.isRaised)
    }

    @Test func readingOneProbeIsNotifiedWhenItChanges() {
        let registry = makeProbeRegistry(sync: sync)
        let flag = ChangeFlag()
        withObservationTracking {
            _ = try? registry.probe(forKey: "sync.connected")
        } onChange: {
            flag.raise()
        }

        sync.isConnected = true

        #expect(flag.isRaised)
    }

    @Test func probesShareKeysWithActionsAndScenariosButNotControls() {
        let builder = RegistryBuilder(model: DebugModel())

        builder.probe("P", key: "shared") { true }
        builder.action("A", key: "shared") {}
        builder.scenario("S", key: "shared") { _ in }

        #expect(builder.probes.map(\.key) == ["shared"])
        #expect(builder.actions.map(\.key) == ["shared"])
        #expect(builder.scenarios.map(\.key) == ["shared"])
    }

    @Test func aLiteralProbeTakesTheIntegerOverload() {
        let builder = RegistryBuilder(model: DebugModel())

        builder.probe("Five", key: "five") { 5 }

        #expect(builder.probes.first?.read() == .int(5))
    }
}
