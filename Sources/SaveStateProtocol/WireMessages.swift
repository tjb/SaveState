/// Where a running app's agent endpoint listens. The app writes this as JSON to
/// `relativePath` inside its data container, and the bridge reads it there.
public struct EndpointInfo: Codable, Hashable, Sendable {
    /// The endpoint file's path relative to an app's data container.
    public static let relativePath = "Library/Application Support/SaveState/endpoint.json"

    /// The wire protocol version the app speaks.
    public var protocolVersion: Int
    /// The loopback port the endpoint listens on.
    public var port: UInt16
    /// The secret a client must present, new at each launch.
    public var token: String
    /// The app's bundle identifier.
    public var bundleIdentifier: String
    /// The app's name.
    public var appName: String
    /// The app's process, so the bridge can skip files a dead process left behind.
    public var processIdentifier: Int32

    /// Creates an endpoint description.
    public init(
        protocolVersion: Int,
        port: UInt16,
        token: String,
        bundleIdentifier: String,
        appName: String,
        processIdentifier: Int32
    ) {
        self.protocolVersion = protocolVersion
        self.port = port
        self.token = token
        self.bundleIdentifier = bundleIdentifier
        self.appName = appName
        self.processIdentifier = processIdentifier
    }
}

/// The first message a client sends on a connection. The endpoint accepts
/// nothing else until this succeeds.
public struct ClientHello: Codable, Hashable, Sendable {
    /// The wire protocol version the client speaks.
    public var protocolVersion: Int
    /// The token from the app's endpoint file.
    public var token: String

    /// Creates a hello.
    public init(protocolVersion: Int, token: String) {
        self.protocolVersion = protocolVersion
        self.token = token
    }
}

/// The endpoint's answer to a `ClientHello`.
public enum ServerHello: Codable, Hashable, Sendable {
    /// The connection may send requests.
    case accepted
    /// The endpoint closes the connection after sending this.
    case rejected(error: WireError)
}

/// One operation a client asks of an app.
public enum WireRequest: Codable, Hashable, Sendable {
    /// Returns a `.description` of every control, action, and scenario.
    case describe
    /// Returns a `.control` with one control's current values.
    case read(key: String)
    /// Sets one control. Without `persist`, the value lasts for this launch,
    /// except on a control that requires a relaunch: there it lasts through the
    /// next launch, so relaunching applies it once.
    case set(key: String, value: ControlValue, persist: Bool)
    /// Runs an action. Destructive actions are refused.
    case runAction(key: String)
    /// Applies a scenario.
    case applyScenario(key: String)
}

/// How a request ended.
public enum WireResult: Codable, Hashable, Sendable {
    /// The request succeeded and has nothing to return.
    case done
    /// The registry's current description.
    case description(registry: RegistryDescription)
    /// One control's current values.
    case control(control: ControlDescription)
    /// The request failed.
    case failure(error: WireError)
}

/// A request and the identifier its response will carry.
public struct RequestEnvelope: Codable, Hashable, Sendable {
    /// Chosen by the client and echoed in the response.
    public var id: Int
    /// The operation.
    public var request: WireRequest

    /// Creates an envelope.
    public init(id: Int, request: WireRequest) {
        self.id = id
        self.request = request
    }
}

/// A response to a `RequestEnvelope`.
public struct ResponseEnvelope: Codable, Hashable, Sendable {
    /// The request's identifier, or `nil` when the message couldn't be decoded.
    public var id: Int?
    /// How the request ended.
    public var result: WireResult

    /// Creates an envelope.
    public init(id: Int?, result: WireResult) {
        self.id = id
        self.result = result
    }
}

/// A failure reported over the wire.
public struct WireError: Codable, Hashable, Sendable, Error {
    /// What kind of failure this is. Clients match on this.
    public enum Code: String, Codable, Sendable {
        /// The token was wrong, or a request came before a hello.
        case unauthorized
        /// The client and app speak different protocol versions.
        case protocolMismatch
        /// The message couldn't be decoded.
        case badRequest
        /// The registry is disabled.
        case disabled
        /// No control has this key.
        case unknownControl
        /// No action has this key.
        case unknownAction
        /// No scenario has this key.
        case unknownScenario
        /// The action is destructive, which this request can't run.
        case destructiveActionNotAllowed
        /// The control's kind doesn't accept this value.
        case invalidValue
        /// The app's action or scenario threw.
        case operationFailed
    }

    /// What kind of failure this is.
    public var code: Code
    /// A description for people.
    public var message: String

    /// Creates an error.
    public init(code: Code, message: String) {
        self.code = code
        self.message = message
    }
}
