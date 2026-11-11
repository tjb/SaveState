import Foundation
import MCP
import SaveStateClientKit

/// The MCP tools: what they advertise, and what each call does.
package struct BridgeTools: Sendable {
    private let discover: @Sendable () async throws -> [DiscoveredApp]
    private let client: SaveStateClient

    /// Creates the tools.
    ///
    /// - Parameters:
    ///   - timeout: How long to wait for an app to answer.
    ///   - discover: Returns the running apps. Defaults to the booted simulators.
    package init(
        timeout: Duration = .seconds(30),
        discover: @escaping @Sendable () async throws -> [DiscoveredApp] = AppDiscovery.runningApps
    ) {
        client = SaveStateClient(timeout: timeout)
        self.discover = discover
    }

    // MARK: - Advertising

    /// The tools the server advertises.
    package static let definitions: [Tool] = [
        Tool(
            name: "savestate_list_apps",
            description: "List running iOS Simulator apps that use SaveState.",
            inputSchema: schema()
        ),
        Tool(
            name: "savestate_describe",
            description: """
            Describe an app's debug state: its controls with their current values, its actions, its \
            named scenarios, and its probes, which are read-only state the app reports and which \
            savestate_wait can wait on. Call this first. Scenarios are the quickest way to reach a state.
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
            Read one control or probe by key. For a control, value is its own setting, realValue the \
            real one if it reports one, and effectiveValue what the app acts on. For the clock, \
            effectiveValue is the app's current time. For a probe, value is what the app reports now.
            """,
            inputSchema: schema(
                properties: [
                    "key": ["type": "string", "description": "The control's or probe's key from savestate_describe."]
                ],
                required: ["key"]
            )
        ),
        Tool(
            name: "savestate_wait",
            description: """
            Wait until a probe meets a condition, then return the probe with the value that met it. \
            Use it after an action or scenario starts work that finishes later. equals and notEquals \
            take true or false, a number, or a string; atLeast and atMost take a number, or a date-time \
            with a time zone, such as 2027-01-15T08:00:00Z, for date probes. Fails if the condition \
            isn't met within timeoutSeconds. Controls can't be waited on; read them with savestate_read.
            """,
            inputSchema: schema(
                properties: [
                    "key": ["type": "string", "description": "The probe's key from savestate_describe."],
                    "condition": [
                        "type": "string",
                        "enum": .array(WaitArguments.conditionNames.map { .string($0) }),
                        "description": "How the probe's value compares with value."
                    ],
                    "value": [
                        "type": ["boolean", "number", "string"],
                        "description": "What to compare with: true or false, a number, a string, or a date-time with a time zone."
                    ],
                    "timeoutSeconds": [
                        "type": "number",
                        "description": """
                        How long to wait, in seconds: more than 0 and at most \(WaitArguments.maximumSeconds). \
                        Defaults to \(WaitArguments.defaultSeconds).
                        """
                    ]
                ],
                required: ["key", "condition", "value"]
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
    package func call(_ name: String, arguments: [String: Value]) async -> CallTool.Result {
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
        case .unknownProbe:
            return "\(error.message) Call savestate_describe to see the probes."
        case .timedOut:
            return """
            \(error.message) Check the probe's current value with savestate_read, or retry with a longer \
            timeoutSeconds, at most \(WaitArguments.maximumSeconds).
            """
        case .invalidCondition:
            return """
            \(error.message) equals and notEquals compare any value of the same type. atLeast and atMost \
            apply only to numbers and dates, and a date compares with a date-time string such as \
            2027-01-15T08:00:00Z.
            """
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
            throw BridgeError(.invalidArgument, """
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
            return try encode(try await client.describe(try await selectApp(arguments)))
        case "savestate_read":
            return try await read(arguments)
        case "savestate_wait":
            return try await wait(arguments)
        case "savestate_set":
            return try await set(arguments)
        case "savestate_run_action":
            let key = try string("key", in: arguments)
            try await client.runAction(key, in: try await selectApp(arguments))
            return "Ran the action \"\(key)\"."
        case "savestate_apply_scenario":
            let key = try string("key", in: arguments)
            try await client.applyScenario(key, in: try await selectApp(arguments))
            return "Applied the scenario \"\(key)\"."
        default:
            throw BridgeError(.invalidArgument, "There's no tool named \(name).")
        }
    }

    private func set(_ arguments: [String: Value]) async throws -> String {
        let key = try string("key", in: arguments)
        guard let json = arguments["value"] else {
            throw BridgeError(.invalidArgument, "savestate_set needs a value.")
        }
        var persist = false
        if let value = arguments["persist"] {
            guard let flag = value.boolValue else {
                throw BridgeError(.invalidArgument, "persist must be true or false.")
            }
            persist = flag
        }
        let app = try await selectApp(arguments)
        let description = try await client.describe(app)
        guard let control = description.controls.first(where: { $0.key == key }) else {
            let keys = description.controls.map(\.key).joined(separator: ", ")
            throw BridgeError(.unknownKey, "No control has the key \"\(key)\". The controls are: \(keys).")
        }
        let value = try ControlValueConversion.value(from: json, kind: control.kind)
        try await client.set(key, to: value, persist: persist, in: app)
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

    /// Reads a control, or a probe when no control has the key, since the two
    /// share one key space.
    private func read(_ arguments: [String: Value]) async throws -> String {
        let key = try string("key", in: arguments)
        let app = try await selectApp(arguments)
        do {
            return try encode(try await client.read(key, in: app))
        } catch let error as WireError where error.code == .unknownControl {
            do {
                return try encode(try await client.readProbe(key, in: app))
            } catch let error as WireError where error.code == .unknownProbe {
                throw BridgeError(.unknownKey, """
                No control or probe has the key "\(key)". Call savestate_describe to see the keys.
                """)
            }
        }
    }

    private func wait(_ arguments: [String: Value]) async throws -> String {
        let key = try string("key", in: arguments)
        let wait = try WaitArguments(arguments)
        let app = try await selectApp(arguments)
        do {
            let probe = try await client.wait(
                forProbe: key,
                until: wait.condition,
                timeout: .milliseconds(wait.milliseconds),
                in: app
            )
            return try encode(probe)
        } catch let error as WireError where error.code == .unknownProbe {
            // Waiting on a control is a likely mistake, so say so rather than that the key is missing.
            guard (try? await client.read(key, in: app)) != nil else { throw error }
            throw BridgeError(.invalidArgument, """
            "\(key)" is a control, not a probe. savestate_wait waits only on probes; read a control with savestate_read.
            """)
        }
    }

    private func runningApps() async throws -> [DiscoveredApp] {
        try await discover()
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
            throw BridgeError(.appNotFound, """
            No SaveState apps are running. Launch a Debug build in a booted simulator, and check that it \
            calls AgentEndpoint.start(registry:).
            """)
        }
        let matches = try matchingApps(arguments, in: running)
        let listing = running
            .map { "\($0.endpoint.bundleIdentifier) on \($0.deviceIdentifier)" }
            .joined(separator: ", ")
        guard let app = matches.first else {
            throw BridgeError(.appNotFound, "No running app matches. Running: \(listing).")
        }
        guard matches.count == 1 else {
            throw BridgeError(.ambiguousApp, "Several apps match, so pass app or device. Running: \(listing).")
        }
        // SaveStateClient checks the app's protocol version on every call.
        return app
    }

    private func string(_ name: String, in arguments: [String: Value]) throws -> String {
        guard let value = try optionalString(name, in: arguments) else {
            throw BridgeError(.invalidArgument, "This tool needs \(name).")
        }
        return value
    }

    private func optionalString(_ name: String, in arguments: [String: Value]) throws -> String? {
        guard let value = arguments[name] else { return nil }
        guard let text = value.stringValue else {
            throw BridgeError(.invalidArgument, "\(name) must be a string.")
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
            throw BridgeError(.invalidArgument, "\(article(for: kind)) \(name(of: kind)) control can't take \(describe(json)). It takes \(accepted(by: kind)).")
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
            return restoredText(json).map(ControlValue.string)
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

    /// Converts the value a `savestate_wait` condition compares with. Unlike a
    /// control's value, it has no kind to check against: the app checks it.
    static func probeValue(from json: Value) throws -> ControlValue {
        switch json {
        case .bool(let flag):
            return .bool(flag)
        case .int(let number):
            return .int(number)
        case .double(let number):
            return .double(number)
        case .string(let text):
            return .string(text)
        case .data:
            if let text = restoredText(json) {
                return .string(text)
            }
        case .null, .array, .object:
            break
        }
        throw BridgeError(.invalidArgument, """
        value can't be \(describe(json)). It takes true or false, a number, a string, or a date-time with \
        a time zone, such as 2027-01-15T08:00:00Z.
        """)
    }

    /// The SDK decodes any string shaped like a data URL as data, so an agent can
    /// send one without meaning binary. Its own encoding restores the text.
    private static func restoredText(_ json: Value) -> String? {
        (try? JSONEncoder().encode(json)).flatMap { try? JSONDecoder().decode(String.self, from: $0) }
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

/// The checked arguments of a `savestate_wait` call, other than the key and app.
struct WaitArguments {
    /// The conditions an agent can name, as the schema lists them.
    static let conditionNames = ["equals", "notEquals", "atLeast", "atMost"]
    /// The timeout when the agent doesn't pass one.
    static let defaultSeconds = 10
    /// The longest timeout the app accepts.
    static let maximumSeconds = Int(SaveStateClient.maximumWaitTimeout.components.seconds)

    /// What to wait for.
    var condition: ProbeCondition
    /// The timeout to send the app.
    var milliseconds: Int

    init(_ arguments: [String: Value]) throws {
        guard let name = arguments["condition"] else {
            throw BridgeError(.invalidArgument, "savestate_wait needs a condition: \(Self.conditionNames.joined(separator: ", ")).")
        }
        guard let json = arguments["value"] else {
            throw BridgeError(.invalidArgument, "savestate_wait needs a value to compare with.")
        }
        let value = try ControlValueConversion.probeValue(from: json)
        switch name.stringValue {
        case "equals": condition = .equals(value: value)
        case "notEquals": condition = .notEquals(value: value)
        case "atLeast": condition = .atLeast(value: value)
        case "atMost": condition = .atMost(value: value)
        default:
            throw BridgeError(.invalidArgument, "condition must be one of: \(Self.conditionNames.joined(separator: ", ")).")
        }
        milliseconds = try Self.milliseconds(arguments["timeoutSeconds"])
    }

    /// Rejects a timeout out of range rather than clamping it, so an agent never
    /// waits a different time than it asked for without knowing.
    private static func milliseconds(_ json: Value?) throws -> Int {
        let seconds: Double
        switch json {
        case nil:
            seconds = Double(defaultSeconds)
        case .int(let number)?:
            seconds = Double(number)
        case .double(let number)?:
            seconds = number
        default:
            seconds = .nan
        }
        guard seconds > 0, seconds <= Double(maximumSeconds) else {
            throw BridgeError(.invalidArgument, "timeoutSeconds must be a number more than 0 and at most \(maximumSeconds).")
        }
        // Rounded to the nearest, since `2.007 * 1000` is a hair over 2007, with a
        // floor of 1 so a tiny timeout still waits rather than becoming zero.
        return max(1, Int((seconds * 1000).rounded()))
    }
}
