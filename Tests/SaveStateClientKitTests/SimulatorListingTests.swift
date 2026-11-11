#if os(macOS)
import Foundation
import Testing
@testable import SaveStateClientKit

@Suite("Simulator listing")
struct SimulatorListingTests {
    @Test func aToolPastItsDeadlineIsStoppedAndReported() async {
        let start = ContinuousClock.now

        let error = await #expect(throws: BridgeError.self) {
            _ = try await AppDiscovery.runTool(URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"], deadline: 0.2)
        }

        #expect(error?.code == .discoveryFailed)
        #expect(ContinuousClock.now - start < .seconds(15))
    }

    @Test func aFailingToolIsReported() async {
        let error = await #expect(throws: BridgeError.self) {
            _ = try await AppDiscovery.runTool(URL(fileURLWithPath: "/usr/bin/false"), arguments: [])
        }

        #expect(error?.code == .discoveryFailed)
    }

    @Test func cancellingTheTaskStopsARunningTool() async {
        let start = ContinuousClock.now
        let launch = ToolLaunch()
        let run = Task {
            try await AppDiscovery.runTool(URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"], launch: launch)
        }
        // Cancel only once the tool runs, or this would test a tool that never started.
        while !launch.isRunning, ContinuousClock.now - start < .seconds(5) {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(launch.isRunning)

        run.cancel()

        await #expect(throws: CancellationError.self) { try await run.value }
        #expect(ContinuousClock.now - start < .seconds(10))
    }

    @Test func aToolIsNeverStartedForACancelledTask() async {
        let start = ContinuousClock.now
        let run = Task {
            // Cancelled before the tool is launched.
            withUnsafeCurrentTask { $0?.cancel() }
            return try await AppDiscovery.runTool(URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"])
        }

        await #expect(throws: CancellationError.self) { try await run.value }
        #expect(ContinuousClock.now - start < .seconds(10))
    }

    @Test func theBootedDevicesComeFromTheListing() async throws {
        let listing = #"{"devices":{"iOS":[{"udid":"B","state":"Booted","dataPath":"/b"},{"udid":"S","state":"Shutdown","dataPath":"/s"}]}}"#
        let echo = AppDiscovery.Tool(executable: URL(fileURLWithPath: "/bin/echo"), arguments: [listing])

        let devices = try await AppDiscovery.bootedDevices(listing: echo)
        let apps = try await AppDiscovery.runningApps(listing: echo)

        #expect(devices == [SimulatorDevice(identifier: "B", dataPath: URL(fileURLWithPath: "/b"))])
        #expect(apps.isEmpty)
    }

    @Test func aListingThatIsntJSONIsADiscoveryFailure() async {
        let echo = AppDiscovery.Tool(executable: URL(fileURLWithPath: "/bin/echo"), arguments: ["not json"])

        let error = await #expect(throws: BridgeError.self) { try await AppDiscovery.bootedDevices(listing: echo) }

        #expect(error?.code == .discoveryFailed)
    }

    @Test func discoveryUsesSimctl() {
        #expect(AppDiscovery.simctl.executable.path == "/usr/bin/xcrun")
        #expect(AppDiscovery.simctl.arguments == ["simctl", "list", "devices", "booted", "--json"])
    }

    @Test func aToolsOutputIsReturned() async throws {
        let data = try await AppDiscovery.runTool(URL(fileURLWithPath: "/bin/echo"), arguments: ["hi"])

        #expect(String(bytes: data, encoding: .utf8) == "hi\n")
    }

    @Test func malformedListingsThrow() {
        #expect(throws: (any Error).self) {
            _ = try AppDiscovery.parseDevices(Data("not json".utf8))
        }
    }

    @Test func devicesAreSortedSoSelectionIsStable() throws {
        let json = """
        {"devices":{"iOS-27":[
          {"udid":"B","state":"Booted","dataPath":"/b"},
          {"udid":"A","state":"Booted","dataPath":"/a"},
          {"udid":"C","state":"Booted","dataPath":"/c"}
        ]}}
        """

        #expect(try AppDiscovery.parseDevices(Data(json.utf8)).map(\.identifier) == ["A", "B", "C"])
    }

    @Test func keepsOnlyBootedDevices() throws {
        let json = """
        {"devices":{"iOS-27":[
          {"udid":"A","state":"Booted","dataPath":"/a","name":"One"},
          {"udid":"B","state":"Shutdown","dataPath":"/b","name":"Two"}
        ],"iOS-18":[]}}
        """
        let devices = try AppDiscovery.parseDevices(Data(json.utf8))

        #expect(devices == [SimulatorDevice(identifier: "A", dataPath: URL(fileURLWithPath: "/a"))])
    }
}
#endif
