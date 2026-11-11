// The client runs on a Mac and compiles to nothing on iOS.
#if os(macOS)
import Darwin
import Foundation
import SaveStateProtocol
import Synchronization

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
    /// Returns the SaveState apps running on every booted simulator.
    ///
    /// This is ``bootedDevices()`` followed by ``apps(on:)``.
    ///
    /// - Returns: The running apps, sorted by bundle identifier and then device.
    /// - Throws: ``BridgeError`` with ``BridgeError/Code/discoveryFailed`` if
    ///   `xcrun simctl` fails or doesn't answer; `CancellationError` if the
    ///   calling task is cancelled.
    public static func runningApps() async throws -> [DiscoveredApp] {
        try await runningApps(listing: simctl)
    }

    /// Returns the booted simulators, using `xcrun simctl`.
    ///
    /// `simctl` can take well over 15 seconds right after a simulator boots. It
    /// runs off Swift's shared thread pool, is stopped after 40 seconds, and is
    /// stopped as soon as the calling task is cancelled.
    ///
    /// - Returns: The booted simulators, sorted by identifier.
    /// - Throws: ``BridgeError`` with ``BridgeError/Code/discoveryFailed`` if
    ///   `simctl` fails, doesn't answer, or prints something it can't parse;
    ///   `CancellationError` if the calling task is cancelled.
    public static func bootedDevices() async throws -> [SimulatorDevice] {
        try await bootedDevices(listing: simctl)
    }

    /// The command that lists the booted simulators as JSON.
    static let simctl = Tool(
        executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
        arguments: ["simctl", "list", "devices", "booted", "--json"]
    )

    /// A command line: what to run, and its arguments.
    struct Tool {
        var executable: URL
        var arguments: [String]
    }

    /// ``runningApps()`` with the listing from `tool`, so tests can stand in for `simctl`.
    static func runningApps(listing tool: Tool) async throws -> [DiscoveredApp] {
        apps(on: try await bootedDevices(listing: tool))
    }

    /// ``bootedDevices()`` with the listing from `tool`, so tests can stand in for `simctl`.
    static func bootedDevices(listing tool: Tool) async throws -> [SimulatorDevice] {
        let data = try await runTool(tool.executable, arguments: tool.arguments)
        do {
            return try parseDevices(data)
        } catch {
            throw BridgeError(.discoveryFailed, "`xcrun simctl` printed a device list this tool can't read.")
        }
    }

    /// Runs a tool and returns its output, stopping it at the deadline so a wedged
    /// CoreSimulatorService can't hang every tool call. `simctl` can take well over 15
    /// seconds right after a simulator boots, and MCP clients commonly give up at 60,
    /// so the default leaves room for the first and answers inside the second.
    ///
    /// The tool blocks a thread while it runs, so it runs on a dispatch queue rather
    /// than Swift's shared pool, and cancelling the calling task stops it.
    static func runTool(
        _ executable: URL,
        arguments: [String],
        deadline: TimeInterval = 40,
        launch: ToolLaunch = ToolLaunch()
    ) async throws -> Data {
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global().async {
                    continuation.resume(with: Result {
                        try runToolBlocking(executable, arguments: arguments, deadline: deadline, launch: launch)
                    })
                }
            }
        } onCancel: {
            launch.cancel()
        }
    }

    private static func runToolBlocking(
        _ executable: URL,
        arguments: [String],
        deadline: TimeInterval,
        launch: ToolLaunch
    ) throws -> Data {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try launch.run(process)
        let timer = DispatchWorkItem { [process] in
            process.terminate()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + deadline, execute: timer)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timer.cancel()
        if launch.isCancelled {
            throw CancellationError()
        }
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw BridgeError(
                .discoveryFailed,
                "`xcrun simctl` failed or didn't answer. Check that Xcode is installed and selected, and that the simulator service is working."
            )
        }
        return data
    }

    /// Parses the JSON from `simctl list devices`, keeping only booted devices.
    static func parseDevices(_ data: Data) throws -> [SimulatorDevice] {
        try JSONDecoder().decode(SimulatorListing.self, from: data).devices.values
            .flatMap { $0 }
            .filter { $0.state == "Booted" }
            .map { SimulatorDevice(identifier: $0.udid, dataPath: URL(fileURLWithPath: $0.dataPath)) }
            .sorted { $0.identifier < $1.identifier }
    }

    /// Returns the apps on these devices whose endpoint file names a live process
    /// with its port open.
    ///
    /// Unreadable files are skipped: an app that crashed leaves its file behind, and
    /// its process identifier may since have been reused, so a live process alone
    /// doesn't show the app is running.
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
                      isRunning(endpoint.processIdentifier),
                      isListening(on: endpoint.port)
                else { return nil }
                return DiscoveredApp(endpoint: endpoint, deviceIdentifier: device.identifier)
            }
        }
        .sorted { ($0.endpoint.bundleIdentifier, $0.deviceIdentifier) < ($1.endpoint.bundleIdentifier, $1.deviceIdentifier) }
    }

    private static func isListening(on port: UInt16) -> Bool {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = UInt32(INADDR_LOOPBACK).bigEndian
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }

    /// Simulator apps are ordinary Mac processes, so this sees them.
    private static func isRunning(_ identifier: Int32) -> Bool {
        guard identifier > 0 else { return false }
        return kill(identifier, 0) == 0 || errno == EPERM
    }
}

/// The parts of `simctl list devices --json` that discovery reads.
private struct SimulatorListing: Decodable {
    struct Device: Decodable {
        var udid: String
        var state: String
        var dataPath: String
    }

    var devices: [String: [Device]]
}

/// Starts a tool unless its task was already cancelled, and stops it if the
/// task is cancelled later. A process can't be stopped before it starts, so
/// both happen under one lock.
final class ToolLaunch: Sendable {
    private enum State {
        case waiting
        case running(Process)
        case cancelled
    }

    private let state = Mutex(State.waiting)

    /// Whether the tool has started and hasn't been cancelled. Tests wait for it
    /// before cancelling, so they cancel a tool that's really running.
    var isRunning: Bool {
        state.withLock { state in
            if case .running = state { return true }
            return false
        }
    }

    var isCancelled: Bool {
        state.withLock { state in
            if case .cancelled = state { return true }
            return false
        }
    }

    func run(_ process: Process) throws {
        try state.withLock { state in
            guard case .waiting = state else { throw CancellationError() }
            try process.run()
            state = .running(process)
        }
    }

    func cancel() {
        state.withLock { state in
            if case .running(let process) = state {
                process.terminate()
            }
            state = .cancelled
        }
    }
}

/// A failure on the Mac side: the app couldn't be found, reached, or
/// understood, or a call's arguments were wrong.
///
/// Match on ``code``, which is stable. The ``message`` says what to do next and
/// is written for a person or an agent to read, so its wording can change in
/// any release.
///
/// When the app itself fails a request, such as for a key it doesn't have, the
/// error is the app's `WireError` instead.
public struct BridgeError: Error, Equatable, Sendable, CustomStringConvertible {
    /// What kind of failure this is.
    public enum Code: String, Sendable, Hashable, CaseIterable {
        /// The app speaks a different `WireProtocol.version`, so nothing was
        /// sent. Rebuild the app and the client from the same SaveState version.
        case protocolMismatch
        /// The app couldn't be reached: it quit, or its endpoint file is stale
        /// or has a bad port.
        case unreachable
        /// The app didn't answer within the timeout. It may be suspended in the
        /// background or stopped in a debugger.
        case noResponse
        /// The app sent a reply that couldn't be decoded.
        case unreadableReply
        /// The app answered with a result of the wrong kind, or answered a
        /// different request.
        case unexpectedResponse
        /// An argument was out of range or malformed, so nothing was sent.
        case invalidArgument
        /// Finding the booted simulators failed: `xcrun simctl` failed or
        /// didn't answer.
        case discoveryFailed
        /// No running app matches the one asked for.
        case appNotFound
        /// Several running apps match, so the request doesn't say which.
        case ambiguousApp
        /// The app has no control or probe with the key asked for.
        case unknownKey
    }

    /// What kind of failure this is. Match on this rather than ``message``.
    public var code: Code
    /// What went wrong and what to do next, for a person or an agent to read.
    public var message: String

    /// Creates an error.
    ///
    /// - Parameters:
    ///   - code: What kind of failure this is.
    ///   - message: What went wrong and what to do next.
    public init(_ code: Code, _ message: String) {
        self.code = code
        self.message = message
    }

    /// The message.
    public var description: String {
        message
    }
}
#endif
