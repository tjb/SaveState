import Foundation
import MCP
import SaveStateProtocol

/// The MCP tools: what they advertise, and what each call does.
public struct BridgeTools: Sendable {
    private let discover: @Sendable () throws -> [DiscoveredApp]
    private let timeout: Duration

    /// Creates the tools.
    ///
    /// - Parameters:
    ///   - timeout: How long to wait for an app to answer.
    ///   - discover: Returns the running apps. Defaults to the booted simulators.
    public init(
        timeout: Duration = .seconds(30),
        discover: @escaping @Sendable () throws -> [DiscoveredApp] = {
            AppDiscovery.apps(on: try AppDiscovery.bootedDevices())
        }
    ) {
        self.timeout = timeout
        self.discover = discover
    }

    // MARK: - Advertising

    /// The tools the server advertises.
    public static let definitions: [Tool] = [
        Tool(
            name: "savestate_list_apps",
            description: "List running iOS Simulator apps that use SaveState.",
            inputSchema: schema()
        ),
        Tool(
            name: "savestate_describe",
            description: """
            Describe an app's debug state: its controls with their current values, its actions, and \
            its named scenarios. Call this first. Scenarios are the quickest way to reach a state.
            """,
            inputSchema: schema()
        ),
        Tool(
            name: "savestate_set",
            description: """
            Set one control. Values: true or false for toggles; true, false, or null (use the real \
            value) for tri-states; a listed option for choices; a string for text; a number for \
            integers and decimals; a date-time with a time zone, such as 2027-01-15T08:00:00Z, or null \
            for dates and the clock. The change lasts \
            for this launch unless persist is true. A control that requires a relaunch keeps the value \
            through the next launch, so relaunching applies it once.
            """,
            inputSchema: schema(
                properties: [
                    "key": ["type": "string", "description": "The control's key from savestate_describe."],
                    "value": ["description": "The new value. Its type depends on the control's kind."],
                    "persist": ["type": "boolean", "description": "Keep the value across relaunches until reset."]
                ],
                required: ["key", "value"]
            )
        ),
        Tool(
            name: "savestate_run_action",
            description: "Run an action by key. Actions marked destructive are refused: a person has to run those.",
            inputSchema: schema(
                properties: ["key": ["type": "string", "description": "The action's key from savestate_describe."]],
                required: ["key"]
            )
        ),
        Tool(
            name: "savestate_apply_scenario",
            description: "Apply a named scenario, such as expired-trial, which puts the app in that state.",
            inputSchema: schema(
                properties: ["key": ["type": "string", "description": "The scenario's key from savestate_describe."]],
                required: ["key"]
            )
        ),
        Tool(
            name: "savestate_read",
            description: """
            Read one control's values: value is its own setting, realValue the real one if it reports \
            one, and effectiveValue what the app acts on. For the clock, effectiveValue is the app's \
            current time.
            """,
            inputSchema: schema(
                properties: ["key": ["type": "string", "description": "The control's key from savestate_describe."]],
                required: ["key"]
            )
        )
    ]

    private static func schema(
        properties: [String: Value] = [:],
        required: [String] = []
    ) -> Value {
        var all = properties
        all["app"] = [
            "type": "string",
            "description": "The app's bundle identifier. Needed only when several apps are running."
        ]
        all["device"] = [
            "type": "string",
            "description": "The simulator's UDID. Needed only when the app runs on several simulators."
        ]
        return [
            "type": "object",
            "properties": .object(all),
            "required": .array(required.map { .string($0) }),
            "additionalProperties": false
        ]
    }

    // MARK: - Calling

    /// Runs a tool. Failures come back as an error result the agent can read.
    public func call(_ name: String, arguments: [String: Value]) async -> CallTool.Result {
        do {
            return CallTool.Result(content: [.text(text: try await perform(name, arguments), annotations: nil, _meta: nil)])
        } catch let error as BridgeError {
            return failure(error.message)
        } catch let error as WireError {
            return failure(message(for: error))
        } catch {
            return failure(String(describing: error))
        }
    }

    private func failure(_ message: String) -> CallTool.Result {
        CallTool.Result(content: [.text(text: message, annotations: nil, _meta: nil)], isError: true)
    }

    private func message(for error: WireError) -> String {
        switch error.code {
        case .protocolMismatch:
            return "\(error.message) Rebuild the app and the bridge from the same SaveState version."
        case .unauthorized:
            return "\(error.message) The app may have relaunched. Try again."
        default:
            return error.message
        }
    }

    /// Rejects misspelled arguments. A client may not validate the schema, and a
    /// quietly ignored `persisted` or `device_id` would do the wrong thing.
    private func checkArguments(of name: String, _ arguments: [String: Value]) throws {
        guard let tool = Self.definitions.first(where: { $0.name == name }),
              let allowed = tool.inputSchema.objectValue?["properties"]?.objectValue?.keys
        else { return }
        let unknown = arguments.keys.filter { !allowed.contains($0) }.sorted()
        guard unknown.isEmpty else {
            throw BridgeError("""
            \(name) doesn't take \(unknown.joined(separator: ", ")). It takes: \(allowed.sorted().joined(separator: ", ")).
            """)
        }
    }

    private func perform(_ name: String, _ arguments: [String: Value]) async throws -> String {
        try checkArguments(of: name, arguments)
        switch name {
        case "savestate_list_apps":
            return try encode(try matchingApps(arguments, in: try await runningApps()).map(AppListing.init))
        case "savestate_describe":
            return try encode(try await registry(of: try await selectApp(arguments)))
        case "savestate_read":
            let result = try await send(.read(key: try string("key", in: arguments)), to: try await selectApp(arguments))
            guard case .control(let control) = result else { throw unexpected(result) }
            return try encode(control)
        case "savestate_set":
            return try await set(arguments)
        case "savestate_run_action":
            let key = try string("key", in: arguments)
            try expectDone(try await send(.runAction(key: key), to: try await selectApp(arguments)))
            return "Ran the action \"\(key)\"."
        case "savestate_apply_scenario":
            let key = try string("key", in: arguments)
            try expectDone(try await send(.applyScenario(key: key), to: try await selectApp(arguments)))
            return "Applied the scenario \"\(key)\"."
        default:
            throw BridgeError("There's no tool named \(name).")
        }
    }

    private func set(_ arguments: [String: Value]) async throws -> String {
        let key = try string("key", in: arguments)
        guard let json = arguments["value"] else {
            throw BridgeError("savestate_set needs a value.")
        }
        var persist = false
        if let value = arguments["persist"] {
            guard let flag = value.boolValue else {
                throw BridgeError("persist must be true or false.")
            }
            persist = flag
        }
        let app = try await selectApp(arguments)
        let description = try await registry(of: app)
        guard let control = description.controls.first(where: { $0.key == key }) else {
            let keys = description.controls.map(\.key).joined(separator: ", ")
            throw BridgeError("No control has the key \"\(key)\". The controls are: \(keys).")
        }
        let value = try ControlValueConversion.value(from: json, kind: control.kind)
        try expectDone(try await send(.set(key: key, value: value, persist: persist), to: app))
        switch (persist, control.requiresRelaunch) {
        case (true, true):
            return "Set \"\(key)\". Relaunch the app to apply it. It persists across relaunches until reset."
        case (true, false):
            return "Set \"\(key)\". It persists across relaunches until reset."
        case (false, true):
            return "Set \"\(key)\". Relaunch the app to apply it. It lasts through the next launch."
        case (false, false):
            return "Set \"\(key)\". It lasts for this launch."
        }
    }

    private func registry(of app: DiscoveredApp) async throws -> RegistryDescription {
        let result = try await send(.describe, to: app)
        guard case .description(let description) = result else { throw unexpected(result) }
        return description
    }

    private func send(_ request: WireRequest, to app: DiscoveredApp) async throws -> WireResult {
        let result = try await AppClient.send(request, to: app, timeout: timeout)
        if case .failure(let error) = result { throw error }
        return result
    }

    private func expectDone(_ result: WireResult) throws {
        guard case .done = result else { throw unexpected(result) }
    }

    private func unexpected(_ result: WireResult) -> BridgeError {
        BridgeError("The app sent an unexpected response: \(result)")
    }

    /// Runs discovery away from Swift's shared thread pool, because it blocks on
    /// `simctl`.
    private func runningApps() async throws -> [DiscoveredApp] {
        let discover = discover
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(with: Result { try discover() })
            }
        }
    }

    private func matchingApps(_ arguments: [String: Value], in running: [DiscoveredApp]) throws -> [DiscoveredApp] {
        let requestedApp = try optionalString("app", in: arguments)
        let requestedDevice = try optionalString("device", in: arguments)
        return running.filter { app in
            (requestedApp == nil || app.endpoint.bundleIdentifier == requestedApp)
                && (requestedDevice == nil || app.deviceIdentifier == requestedDevice)
        }
    }

    private func selectApp(_ arguments: [String: Value]) async throws -> DiscoveredApp {
        let running = try await runningApps()
        guard !running.isEmpty else {
            throw BridgeError("""
            No SaveState apps are running. Launch a Debug build in a booted simulator, and check that it \
            calls AgentEndpoint.start(registry:).
            """)
        }
        let matches = try matchingApps(arguments, in: running)
        let listing = running
            .map { "\($0.endpoint.bundleIdentifier) on \($0.deviceIdentifier)" }
            .joined(separator: ", ")
        guard let app = matches.first else {
            throw BridgeError("No running app matches. Running: \(listing).")
        }
        guard matches.count == 1 else {
            throw BridgeError("Several apps match, so pass app or device. Running: \(listing).")
        }
        guard app.endpoint.protocolVersion == WireProtocol.version else {
            throw BridgeError("""
            \(app.endpoint.appName) speaks protocol \(app.endpoint.protocolVersion), and this bridge speaks \
            \(WireProtocol.version). Rebuild the app and the bridge from the same SaveState version.
            """)
        }
        return app
    }

    private func string(_ name: String, in arguments: [String: Value]) throws -> String {
        guard let value = try optionalString(name, in: arguments) else {
            throw BridgeError("This tool needs \(name).")
        }
        return value
    }

    private func optionalString(_ name: String, in arguments: [String: Value]) throws -> String? {
        guard let value = arguments[name] else { return nil }
        guard let text = value.stringValue else {
            throw BridgeError("\(name) must be a string.")
        }
        return text
    }

    private func encode(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(bytes: try encoder.encode(value), encoding: .utf8) ?? ""
    }
}

/// One entry in `savestate_list_apps`. The token stays out of it: agents never need it.
private struct AppListing: Encodable {
    var bundleIdentifier: String
    var appName: String
    var device: String
    var protocolVersion: Int

    init(_ app: DiscoveredApp) {
        bundleIdentifier = app.endpoint.bundleIdentifier
        appName = app.endpoint.appName
        device = app.deviceIdentifier
        protocolVersion = app.endpoint.protocolVersion
    }
}

/// Converts the plain JSON agents send into the value a control's kind expects.
enum ControlValueConversion {
    static func value(from json: Value, kind: ControlKind) throws -> ControlValue {
        guard let value = convert(json, kind: kind), let normalized = kind.normalize(value) else {
            throw BridgeError("\(article(for: kind)) \(name(of: kind)) control can't take \(describe(json)). It takes \(accepted(by: kind)).")
        }
        return normalized
    }

    private static func convert(_ json: Value, kind: ControlKind) -> ControlValue? {
        switch (json, kind) {
        case (.null, _):
            return .null
        case (.bool(let flag), _):
            return .bool(flag)
        case (.string(let text), .date), (.string(let text), .clock):
            return ControlValue(iso8601Date: text)
        case (.data, .text), (.data, .choice):
            // The SDK decodes any string shaped like a data URL as data, so an agent
            // can send one without meaning binary. Its own encoding restores the text.
            return (try? JSONEncoder().encode(json))
                .flatMap { try? JSONDecoder().decode(String.self, from: $0) }
                .map(ControlValue.string)
        case (.string(let text), _):
            return .string(text)
        case (.int(let number), .decimal):
            return .double(Double(number))
        case (.int(let number), _):
            return .int(number)
        case (.double(let number), .integer):
            // JSON has one number type, so a client may send 3 as 3.0.
            return Int(exactly: number).map(ControlValue.int)
        case (.double(let number), _):
            return .double(number)
        default:
            return nil
        }
    }

    private static func article(for kind: ControlKind) -> String {
        kind == .integer ? "An" : "A"
    }

    private static func name(of kind: ControlKind) -> String {
        switch kind {
        case .toggle: return "toggle"
        case .triState: return "tri-state"
        case .choice: return "choice"
        case .text: return "text"
        case .integer: return "integer"
        case .decimal: return "decimal"
        case .date: return "date"
        case .clock: return "clock"
        }
    }

    private static func accepted(by kind: ControlKind) -> String {
        switch kind {
        case .toggle: return "true or false"
        case .triState: return "true, false, or null for the real value"
        case .choice(let options): return "one of: \(options.joined(separator: ", "))"
        case .text: return "a string"
        case .integer: return "a whole number"
        case .decimal: return "a number"
        case .date: return "a date-time with a time zone, such as 2027-01-15T08:00:00Z, or null for the real value"
        case .clock: return "a date-time with a time zone, such as 2027-01-15T08:00:00Z, or null for real time"
        }
    }

    private static func describe(_ json: Value) -> String {
        switch json {
        case .null: return "null"
        case .bool(let flag): return String(flag)
        case .int(let number): return String(number)
        case .double(let number): return String(number)
        case .string(let text): return "\"\(text)\""
        case .data: return "binary data"
        case .array: return "an array"
        case .object: return "an object"
        }
    }
}
