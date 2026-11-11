#if DEBUG && os(macOS)
import Foundation
import SaveState
import SaveStateClientKit
import Testing
@testable import SaveStateAgent

private enum ClientFlavor: String, CaseIterable {
    case sweet
    case sour
}

@MainActor
private final class ClientModel {
    var isOn = false
    var flavor = ClientFlavor.sweet
    var count = 0
    var runs = 0
    var premium: Bool?
    var items = 0
}

/// A suite name and a container folder for one test, removed when it ends.
private final class ClientScratch: Sendable {
    let suiteName = "SaveStateClientTests.\(UUID().uuidString)"
    let container = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)

    deinit {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: container)
    }
}

// A process runs one AgentEndpoint at a time, and starting one stops the last.
// Every test target shares one process, so these run inside the endpoint's
// serialized suite rather than in SaveStateClientKitTests beside it.
extension AgentEndpointTests {
    /// `SaveStateClient` against a real endpoint and registry.
    @Suite("SaveStateClient")
    @MainActor
    struct SaveStateClientTests {
        private let scratch = ClientScratch()
        private let model = ClientModel()
        private let client = SaveStateClient(timeout: .seconds(5))

        private func register(_ r: RegistryBuilder<ClientModel>) {
            let model = model
            r.toggle("On", key: "on", \.isOn)
            r.choice("Flavor", key: "flavor", \.flavor)
            r.integer("Count", key: "count", \.count)
            r.action("Run", key: "run") { model.runs += 1 }
            r.scenario("Expired", key: "expired-trial") { state in state.premium = false }
            r.triState("Premium", key: "premium", \.premium)
            r.probe("Items", key: "item-count") { model.items }
        }

        private func start() async throws -> (AgentEndpoint, DiscoveredApp) {
            let registry = SaveStateRegistry(
                model: model,
                store: OverrideStore(suiteName: scratch.suiteName),
                isEnabled: true
            ) { r in register(r) }
            let endpoint = try #require(try await AgentEndpoint.start(registry: registry, container: scratch.container))
            return (endpoint, DiscoveredApp(endpoint: endpoint.info, deviceIdentifier: "DEVICE"))
        }

        // MARK: - Each call

        @Test func describesTheRegistry() async throws {
            let (endpoint, app) = try await start()
            defer { endpoint.stop() }

            let description = try await client.describe(app)

            #expect(description.controls.map(\.key) == ["on", "flavor", "count", "premium"])
            #expect(description.actions.map(\.key) == ["run"])
            #expect(description.scenarios.map(\.key) == ["expired-trial"])
            #expect(description.probes.map(\.key) == ["item-count"])
        }

        @Test func setsAndReadsBackEachValue() async throws {
            let (endpoint, app) = try await start()
            defer { endpoint.stop() }

            try await client.set("on", to: .bool(true), in: app)
            try await client.set("flavor", to: .string("sour"), in: app)
            try await client.set("count", to: .int(7), in: app)

            #expect(model.isOn)
            #expect(model.flavor == .sour)
            #expect(try await client.read("on", in: app).effectiveValue == .bool(true))
            #expect(try await client.read("flavor", in: app).value == .string("sour"))
            #expect(try await client.read("count", in: app).value == .int(7))
        }

        @Test func aSetIsSessionScopedUnlessPersisted() async throws {
            let (endpoint, app) = try await start()
            defer { endpoint.stop() }
            let store = OverrideStore(suiteName: scratch.suiteName)
            func relaunched() -> Bool {
                let model = ClientModel()
                _ = SaveStateRegistry(model: model, store: store, isEnabled: true) { r in r.toggle("On", key: "on", \.isOn) }
                return model.isOn
            }

            try await client.set("on", to: .bool(true), in: app)
            #expect(model.isOn)
            #expect(!relaunched())

            try await client.set("on", to: .bool(true), persist: true, in: app)
            #expect(relaunched())
        }

        @Test func runsAnAction() async throws {
            let (endpoint, app) = try await start()
            defer { endpoint.stop() }

            try await client.runAction("run", in: app)
            try await client.runAction("run", in: app)

            #expect(model.runs == 2)
        }

        @Test func appliesAScenario() async throws {
            let (endpoint, app) = try await start()
            defer { endpoint.stop() }

            try await client.applyScenario("expired-trial", in: app)

            #expect(model.premium == false)
        }

        @Test func readsAProbe() async throws {
            let (endpoint, app) = try await start()
            defer { endpoint.stop() }
            model.items = 4

            let probe = try await client.readProbe("item-count", in: app)

            #expect(probe.label == "Items")
            #expect(probe.value == .int(4))
        }

        @Test func waitsUntilAProbeMeetsTheCondition() async throws {
            let (endpoint, app) = try await start()
            defer { endpoint.stop() }
            let model = model
            let change = Task { @MainActor in
                try await Task.sleep(for: .milliseconds(200))
                model.items = 3
            }
            defer { change.cancel() }

            let probe = try await client.wait(forProbe: "item-count", until: .atLeast(value: .int(3)), timeout: .seconds(5), in: app)

            #expect(probe.value == .int(3))
        }

        @Test func aWaitThatIsntMetThrowsTimedOut() async throws {
            let (endpoint, app) = try await start()
            defer { endpoint.stop() }

            let error = await #expect(throws: WireError.self) {
                try await client.wait(forProbe: "item-count", until: .atLeast(value: .int(99)), timeout: .milliseconds(100), in: app)
            }

            #expect(error?.code == .timedOut)
        }

        // MARK: - The app's failures

        @Test func anAppsFailureIsThrownAsTheWireErrorItself() async throws {
            let (endpoint, app) = try await start()
            defer { endpoint.stop() }

            await #expect(throws: WireError.self) { try await client.read("nope", in: app) }
            let codes: [WireError.Code?] = [
                await code { try await client.read("item-count", in: app) },
                await code { try await client.readProbe("on", in: app) },
                await code { try await client.set("nope", to: .bool(true), in: app) },
                await code { try await client.set("count", to: .string("three"), in: app) },
                await code { try await client.runAction("nope", in: app) },
                await code { try await client.applyScenario("nope", in: app) },
                await code { try await client.wait(forProbe: "nope", until: .equals(value: .int(1)), in: app) }
            ]

            #expect(codes == [.unknownControl, .unknownProbe, .unknownControl, .invalidValue, .unknownAction, .unknownScenario, .unknownProbe])
        }

        private func code(_ body: () async throws -> some Any) async -> WireError.Code? {
            do {
                _ = try await body()
                return nil
            } catch let error as WireError {
                return error.code
            } catch {
                return nil
            }
        }
    }
}
#endif
