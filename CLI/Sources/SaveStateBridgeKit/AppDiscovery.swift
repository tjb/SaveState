import Darwin
import Foundation
import SaveStateProtocol

/// A running app with an agent endpoint, found on a booted simulator.
public struct DiscoveredApp: Hashable, Sendable {
    /// What the app wrote to its endpoint file.
    public var endpoint: EndpointInfo
    /// The simulator the app runs on.
    public var deviceIdentifier: String

    /// Creates a discovered app.
    public init(endpoint: EndpointInfo, deviceIdentifier: String) {
        self.endpoint = endpoint
        self.deviceIdentifier = deviceIdentifier
    }
}

/// A booted simulator's identity and the folder holding its data.
public struct SimulatorDevice: Hashable, Sendable {
    /// The simulator's UDID.
    public var identifier: String
    /// The folder apps' data containers live under.
    public var dataPath: URL

    /// Creates a device.
    public init(identifier: String, dataPath: URL) {
        self.identifier = identifier
        self.dataPath = dataPath
    }
}

/// Finds running apps through the endpoint files in their data containers.
public enum AppDiscovery {
    /// Returns the booted simulators, using `xcrun simctl`.
    public static func bootedDevices() throws -> [SimulatorDevice] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl", "list", "devices", "booted", "--json"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw BridgeError("`xcrun simctl` failed. Check that Xcode is installed and selected.")
        }
        return try parseDevices(data)
    }

    /// Parses the JSON from `simctl list devices`, keeping only booted devices.
    static func parseDevices(_ data: Data) throws -> [SimulatorDevice] {
        try JSONDecoder().decode(SimulatorListing.self, from: data).devices.values
            .flatMap { $0 }
            .filter { $0.state == "Booted" }
            .map { SimulatorDevice(identifier: $0.udid, dataPath: URL(fileURLWithPath: $0.dataPath)) }
            .sorted { $0.identifier < $1.identifier }
    }

    /// Returns the apps on these devices whose endpoint file names a live process.
    ///
    /// Unreadable files are skipped: an app that crashed leaves its file behind.
    /// A file from a different protocol version is still returned, so the caller
    /// can say to rebuild rather than reporting no apps at all.
    public static func apps(on devices: [SimulatorDevice]) -> [DiscoveredApp] {
        devices.flatMap { device -> [DiscoveredApp] in
            let containers = device.dataPath.appendingPathComponent("Containers/Data/Application")
            let names = (try? FileManager.default.contentsOfDirectory(atPath: containers.path)) ?? []
            return names.compactMap { name -> DiscoveredApp? in
                let file = containers.appendingPathComponent(name).appendingPathComponent(EndpointInfo.relativePath)
                guard let data = try? Data(contentsOf: file),
                      let endpoint = try? JSONDecoder().decode(EndpointInfo.self, from: data),
                      isRunning(endpoint.processIdentifier)
                else { return nil }
                return DiscoveredApp(endpoint: endpoint, deviceIdentifier: device.identifier)
            }
        }
        .sorted { ($0.endpoint.bundleIdentifier, $0.deviceIdentifier) < ($1.endpoint.bundleIdentifier, $1.deviceIdentifier) }
    }

    /// Simulator apps are ordinary Mac processes, so this sees them.
    private static func isRunning(_ identifier: Int32) -> Bool {
        guard identifier > 0 else { return false }
        return kill(identifier, 0) == 0 || errno == EPERM
    }
}

/// The parts of `simctl list devices --json` the bridge reads.
private struct SimulatorListing: Decodable {
    struct Device: Decodable {
        var udid: String
        var state: String
        var dataPath: String
    }

    var devices: [String: [Device]]
}

/// A failure the bridge reports to the agent. The message says what to do next.
public struct BridgeError: Error, Equatable, Sendable {
    /// A description for the agent.
    public var message: String

    /// Creates an error.
    public init(_ message: String) {
        self.message = message
    }
}
