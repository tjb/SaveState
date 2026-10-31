import Foundation
import SaveStateProtocol
import Testing
@testable import SaveStateBridgeKit

/// A fake simulator's data folder, removed when the test ends.
private final class FakeSimulator: Sendable {
    let device: SimulatorDevice

    init(identifier: String = "DEVICE") {
        device = SimulatorDevice(
            identifier: identifier,
            dataPath: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: device.dataPath)
    }

    func write(_ contents: Data, toContainer name: String) throws {
        let file = device.dataPath
            .appendingPathComponent("Containers/Data/Application/\(name)")
            .appendingPathComponent(EndpointInfo.relativePath)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: file)
    }

    func write(_ info: EndpointInfo, toContainer name: String = "app") throws {
        try write(try JSONEncoder().encode(info), toContainer: name)
    }
}

/// Discovery against a listening port, so the only thing varying is what the test names.
@Suite("App discovery")
struct AppDiscoveryTests {
    private func info(
        port: UInt16,
        bundleIdentifier: String = "live.app",
        protocolVersion: Int = WireProtocol.version,
        processIdentifier: Int32 = ProcessInfo.processInfo.processIdentifier
    ) -> EndpointInfo {
        EndpointInfo(
            protocolVersion: protocolVersion,
            port: port,
            token: "token",
            bundleIdentifier: bundleIdentifier,
            appName: "Live",
            processIdentifier: processIdentifier
        )
    }

    @Test func findsARunningAppWithItsDevice() async throws {
        let listener = try await FakeEndpoint(.neverUpgrades)
        let simulator = FakeSimulator()
        let written = info(port: listener.port)
        try simulator.write(written)

        let apps = AppDiscovery.apps(on: [simulator.device])

        #expect(apps == [DiscoveredApp(endpoint: written, deviceIdentifier: "DEVICE")])
    }

    @Test func aDeviceWithNoContainersHasNoApps() {
        #expect(AppDiscovery.apps(on: [FakeSimulator().device]).isEmpty)
    }

    @Test func anUnreadableFileIsSkippedWithoutHidingOtherApps() async throws {
        let listener = try await FakeEndpoint(.neverUpgrades)
        let simulator = FakeSimulator()
        try simulator.write(Data("not json".utf8), toContainer: "corrupt")
        try simulator.write(info(port: listener.port), toContainer: "good")

        let apps = AppDiscovery.apps(on: [simulator.device])

        #expect(apps.map(\.endpoint.bundleIdentifier) == ["live.app"])
    }

    /// `kill` treats 0 and negatives as process groups, including the caller's own,
    /// so these would look alive without the guard. The port is open, so nothing else
    /// could be why they're skipped.
    @Test(arguments: [Int32(0), Int32(-1)])
    func aNonPositiveProcessIdentifierIsSkipped(identifier: Int32) async throws {
        let listener = try await FakeEndpoint(.neverUpgrades)
        let simulator = FakeSimulator()
        try simulator.write(info(port: listener.port, processIdentifier: identifier))

        #expect(AppDiscovery.apps(on: [simulator.device]).isEmpty)
    }

    @Test func aProcessThisUserCantSignalStillCountsAsRunning() async throws {
        let listener = try await FakeEndpoint(.neverUpgrades)
        let simulator = FakeSimulator()
        // launchd is always alive. To anyone but root, signalling it is EPERM.
        try simulator.write(info(port: listener.port, processIdentifier: 1))

        #expect(AppDiscovery.apps(on: [simulator.device]).count == 1)
    }

    @Test func anOtherProtocolVersionIsStillReturnedSoTheCallerCanSayToRebuild() async throws {
        let listener = try await FakeEndpoint(.neverUpgrades)
        let simulator = FakeSimulator()
        try simulator.write(info(port: listener.port, protocolVersion: WireProtocol.version + 1))

        let apps = AppDiscovery.apps(on: [simulator.device])

        #expect(apps.map(\.endpoint.protocolVersion) == [WireProtocol.version + 1])
    }

    @Test func appsAreSortedByBundleThenDevice() async throws {
        let listener = try await FakeEndpoint(.neverUpgrades)
        let first = FakeSimulator(identifier: "A")
        let second = FakeSimulator(identifier: "B")
        try first.write(info(port: listener.port, bundleIdentifier: "z.app"), toContainer: "z")
        try second.write(info(port: listener.port, bundleIdentifier: "a.app"), toContainer: "a")
        try second.write(info(port: listener.port, bundleIdentifier: "z.app"), toContainer: "z")

        let apps = AppDiscovery.apps(on: [second.device, first.device])

        #expect(apps.map(\.endpoint.bundleIdentifier) == ["a.app", "z.app", "z.app"])
        #expect(apps.map(\.deviceIdentifier) == ["B", "A", "B"])
    }

    @Test func devicesAreSortedByIdentifierAcrossRuntimes() throws {
        let json = """
        {"devices":{
          "iOS-27":[{"udid":"C","state":"Booted","dataPath":"/c"}],
          "iOS-18":[{"udid":"A","state":"Booted","dataPath":"/a"},{"udid":"B","state":"Booted","dataPath":"/b"}]
        }}
        """

        let devices = try AppDiscovery.parseDevices(Data(json.utf8))

        #expect(devices.map(\.identifier) == ["A", "B", "C"])
    }

    @Test func aMissingExecutableThrowsRatherThanHanging() {
        #expect(throws: (any Error).self) {
            _ = try AppDiscovery.runTool(URL(fileURLWithPath: "/nonexistent/tool"), arguments: [])
        }
    }
}
