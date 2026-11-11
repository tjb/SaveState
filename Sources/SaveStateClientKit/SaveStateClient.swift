// SaveStateClientKit runs on a Mac and compiles to nothing on iOS: it reaches
// apps from outside them, so no app links it.
#if os(macOS)
// A library user needs only `import SaveStateClientKit`: this re-exports
// SaveStateProtocol for the types the client takes and returns. Those are
// `ControlValue`, `ProbeCondition`, `RegistryDescription`, `ControlDescription`,
// `ActionDescription`, `ScenarioDescription`, `ProbeDescription`, `ControlKind`,
// `WireError`, `EndpointInfo`, and `WireProtocol.version`, and they're the
// client's contract. The rest of SaveStateProtocol (`ClientHello`, `ServerHello`,
// `WireRequest`, `WireResult`, `RequestEnvelope`, `ResponseEnvelope`) is how the
// client talks to apps. It changes whenever `WireProtocol.version` does and isn't
// part of the client's API, so don't build on it.
@_exported import SaveStateProtocol

/// Talks to a running app's SaveState endpoint from a Mac: reads its debug
/// state, changes it, and waits on its probes.
///
/// Find apps with ``AppDiscovery``, then pass one to each call. Each call opens
/// its own connection, so a relaunched app is reached at its new port as soon
/// as it's discovered again.
///
/// ```swift
/// import SaveStateClientKit
///
/// let client = SaveStateClient()
/// guard let app = try await AppDiscovery.runningApps().first else { return }
/// try await client.applyScenario("expired-trial", in: app)
/// let pending = try await client.wait(forProbe: "pending", until: .atMost(value: .int(0)), in: app)
/// ```
///
/// Every call can throw three kinds of error. Match on their codes, never on
/// their messages, which are for people to read and can be reworded.
///
/// - ``BridgeError``, a failure on the Mac side. Its ``BridgeError/code`` is
///   `protocolMismatch` when the app speaks a different `WireProtocol.version`
///   (checked before anything is sent), `unreachable` when the app can't be
///   reached, `noResponse` when it doesn't answer within the timeout,
///   `unreadableReply` when its reply can't be decoded, `unexpectedResponse`
///   when it answers with a result of the wrong kind, and `invalidArgument`
///   when an argument is out of range, before anything is sent.
/// - `WireError`, the app's own answer, when it refuses the connection, such as
///   for a stale token (`unauthorized`), or fails the request, such as for a
///   key it doesn't have (`unknownControl`). Match on its `code`.
/// - `CancellationError` when the calling task is cancelled.
public struct SaveStateClient: Sendable {
    /// The longest timeout ``wait(forProbe:until:timeout:in:)`` accepts, which is
    /// the most an app will wait.
    public static let maximumWaitTimeout: Duration = .seconds(30)

    /// The longest ``timeout`` a client keeps: one day. A longer one is
    /// shortened to this, since the timer can't count much further.
    public static let maximumTimeout: Duration = .seconds(86_400)

    /// How much longer than a wait the client waits for the app's answer, since
    /// the app answers only when the wait ends.
    static let waitSlack: Duration = .seconds(5)

    /// How long to wait for an app to answer a request.
    ///
    /// A wait gets at least its own timeout plus a few seconds, even when this is
    /// shorter.
    public let timeout: Duration

    /// Creates a client.
    ///
    /// - Parameter timeout: How long to wait for an app to answer a request, at
    ///   most ``maximumTimeout``. A longer one is shortened to that. With zero
    ///   or less, every call except a wait throws ``BridgeError/Code/noResponse``
    ///   at once.
    public init(timeout: Duration = .seconds(30)) {
        self.timeout = min(timeout, Self.maximumTimeout)
    }

    // MARK: - Reading

    /// Returns everything the app declares: its controls with their current
    /// values, its actions, its scenarios, and its probes.
    ///
    /// - Parameter app: The app to ask.
    /// - Returns: The app's registry as it is now.
    /// - Throws: ``BridgeError`` if the app speaks another protocol version,
    ///   can't be reached, or answers oddly; `WireError` if the app refuses
    ///   the request, such as with `disabled`; `CancellationError` if cancelled.
    public func describe(_ app: DiscoveredApp) async throws -> RegistryDescription {
        let result = try await send(.describe, to: app)
        guard case .description(let description) = result else { throw Self.unexpected(result) }
        return description
    }

    /// Returns one control's current values.
    ///
    /// - Parameters:
    ///   - key: The control's key.
    ///   - app: The app to ask.
    /// - Returns: The control, with its own value, its real value if it reports
    ///   one, and the effective value the app acts on.
    /// - Throws: `WireError` with `unknownControl` if no control has the key,
    ///   including when the key is a probe's; ``BridgeError`` if the app speaks
    ///   another protocol version, can't be reached, or answers oddly;
    ///   `CancellationError` if cancelled.
    public func read(_ key: String, in app: DiscoveredApp) async throws -> ControlDescription {
        let result = try await send(.read(key: key), to: app)
        guard case .control(let control) = result else { throw Self.unexpected(result) }
        return control
    }

    /// Returns one probe's current value.
    ///
    /// - Parameters:
    ///   - key: The probe's key.
    ///   - app: The app to ask.
    /// - Returns: The probe, with the value the app reports now.
    /// - Throws: `WireError` with `unknownProbe` if no probe has the key,
    ///   including when the key is a control's; ``BridgeError`` if the app
    ///   speaks another protocol version, can't be reached, or answers oddly;
    ///   `CancellationError` if cancelled.
    public func readProbe(_ key: String, in app: DiscoveredApp) async throws -> ProbeDescription {
        let result = try await send(.readProbe(key: key), to: app)
        guard case .probe(let probe) = result else { throw Self.unexpected(result) }
        return probe
    }

    // MARK: - Changing

    /// Sets one control.
    ///
    /// The value must already suit the control's kind: the client doesn't
    /// convert it, and the app normalizes or rejects it. Read the kind from
    /// ``describe(_:)`` first if you don't know it.
    ///
    /// - Parameters:
    ///   - key: The control's key.
    ///   - value: The new value. `.null` returns a tri-state, date, or the clock
    ///     to its real value.
    ///   - persist: Whether the value survives relaunches until it's reset.
    ///     Without it, the value lasts for this launch, except on a control
    ///     that requires a relaunch, where it lasts through the next launch.
    ///   - app: The app to change.
    /// - Throws: `WireError` with `unknownControl` or `invalidValue` if the app
    ///   refuses the change; ``BridgeError`` if the app speaks another protocol
    ///   version, can't be reached, or answers oddly; `CancellationError` if
    ///   cancelled.
    public func set(
        _ key: String,
        to value: ControlValue,
        persist: Bool = false,
        in app: DiscoveredApp
    ) async throws {
        try Self.expectDone(try await send(.set(key: key, value: value, persist: persist), to: app))
    }

    /// Runs an action and returns once it finishes.
    ///
    /// - Parameters:
    ///   - key: The action's key.
    ///   - app: The app to run it in.
    /// - Throws: `WireError` with `unknownAction`, with
    ///   `destructiveActionNotAllowed` for an action marked destructive, which
    ///   only a person can run, or with `operationFailed` if the action threw;
    ///   ``BridgeError`` if the app speaks another protocol version, can't be
    ///   reached, or answers oddly; `CancellationError` if cancelled.
    public func runAction(_ key: String, in app: DiscoveredApp) async throws {
        try Self.expectDone(try await send(.runAction(key: key), to: app))
    }

    /// Applies a scenario and returns once it's applied.
    ///
    /// - Parameters:
    ///   - key: The scenario's key, such as `expired-trial`.
    ///   - app: The app to apply it in.
    /// - Throws: `WireError` with `unknownScenario`, or with `operationFailed`
    ///   if the scenario threw; ``BridgeError`` if the app speaks another
    ///   protocol version, can't be reached, or answers oddly;
    ///   `CancellationError` if cancelled.
    public func applyScenario(_ key: String, in app: DiscoveredApp) async throws {
        try Self.expectDone(try await send(.applyScenario(key: key), to: app))
    }

    // MARK: - Waiting

    /// Waits until a probe meets a condition, then returns the probe with the
    /// value that met it.
    ///
    /// The app checks the condition, so this returns as soon as the probe
    /// changes, without polling. The client waits for the app's answer for the
    /// longer of ``timeout`` and this wait's `timeout` plus five seconds.
    ///
    /// - Parameters:
    ///   - key: The probe's key.
    ///   - condition: What the probe's value has to meet.
    ///   - timeout: How long the app waits, more than zero and at most
    ///     ``maximumWaitTimeout``. It's sent in whole milliseconds, rounded to
    ///     the nearest with halves rounded up, and at least one.
    ///   - app: The app to ask.
    /// - Returns: The probe, with the value that met the condition.
    /// - Throws: ``BridgeError`` with ``BridgeError/Code/invalidArgument`` if
    ///   `timeout` is out of range, before anything is sent; `WireError` with `timedOut` if the condition isn't met in time,
    ///   `unknownProbe` if no probe has the key, or `invalidCondition` if the
    ///   condition can't apply to the probe's value, such as `atLeast` on a
    ///   Boolean; ``BridgeError`` if the app speaks another protocol version,
    ///   can't be reached, or answers oddly; `CancellationError` if cancelled.
    public func wait(
        forProbe key: String,
        until condition: ProbeCondition,
        timeout: Duration = .seconds(10),
        in app: DiscoveredApp
    ) async throws -> ProbeDescription {
        guard timeout > .zero, timeout <= Self.maximumWaitTimeout else {
            throw BridgeError(.invalidArgument, """
            A wait's timeout must be more than 0 and at most \(Self.maximumWaitTimeout.components.seconds) seconds. \
            It was \(timeout).
            """)
        }
        let milliseconds = Self.milliseconds(timeout)
        let result = try await send(
            .wait(key: key, condition: condition, timeoutMilliseconds: milliseconds),
            to: app,
            // The app answers when the wait ends, so the client has to outlast it.
            timeout: max(self.timeout, .milliseconds(milliseconds) + Self.waitSlack)
        )
        guard case .probe(let probe) = result else { throw Self.unexpected(result) }
        return probe
    }

    /// Converts a wait's timeout to the milliseconds the app takes: rounded to
    /// the nearest with halves rounded up, with a floor of 1 so a tiny timeout
    /// still waits rather than becoming zero.
    static func milliseconds(_ duration: Duration) -> Int {
        let components = duration.components
        let milliseconds = Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15
        return max(1, Int(milliseconds.rounded()))
    }

    // MARK: - Sending

    /// Checks the app's protocol version, sends one request, and throws the app's
    /// failure as the `WireError` itself.
    private func send(_ request: WireRequest, to app: DiscoveredApp, timeout: Duration? = nil) async throws -> WireResult {
        try Self.checkProtocol(of: app)
        let result = try await AppClient.send(request, to: app, timeout: timeout ?? self.timeout)
        if case .failure(let error) = result { throw error }
        return result
    }

    private static func checkProtocol(of app: DiscoveredApp) throws {
        guard app.endpoint.protocolVersion == WireProtocol.version else {
            throw BridgeError(.protocolMismatch, """
            \(app.endpoint.appName) speaks protocol \(app.endpoint.protocolVersion), and this tool speaks \
            \(WireProtocol.version). Rebuild the app and this tool from the same SaveState version.
            """)
        }
    }

    private static func expectDone(_ result: WireResult) throws {
        guard case .done = result else { throw unexpected(result) }
    }

    private static func unexpected(_ result: WireResult) -> BridgeError {
        BridgeError(.unexpectedResponse, "The app sent an unexpected response: \(result)")
    }
}
#endif
