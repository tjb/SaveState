import Foundation
import MCP
import SaveStateProtocol
import Testing
@testable import SaveStateBridgeKit

private func text(_ result: CallTool.Result) -> String {
    result.content.compactMap { content -> String? in
        if case .text(let text, _, _) = content { return text }
        return nil
    }
    .joined()
}

private let sampleProbe = ProbeDescription(key: "pending", label: "Pending uploads", section: nil, value: .int(5))

/// `savestate_wait` and `savestate_read` against a fake app, to see exactly what
/// the bridge sends and how long it waits for the answer.
@Suite("The wait tool")
struct WaitToolTests {
    private func wait(
        _ arguments: [String: Value],
        timeout: Duration = .seconds(5),
        behavior: FakeEndpoint.Behavior = .replies { _ in .probe(probe: sampleProbe) }
    ) async throws -> (CallTool.Result, [WireRequest]) {
        let endpoint = try await FakeEndpoint(behavior)
        let app = endpoint.app()
        let tools = BridgeTools(timeout: timeout) { [app] }
        let result = await tools.call("savestate_wait", arguments: arguments)
        return (result, endpoint.log.all)
    }

    private let atLeastFive: [String: Value] = ["key": "pending", "condition": "atLeast", "value": 5]

    // MARK: - What it sends

    @Test(arguments: [
        ("equals", Value.bool(true), ProbeCondition.equals(value: .bool(true))),
        ("notEquals", .string("home"), .notEquals(value: .string("home"))),
        ("atLeast", .int(5), .atLeast(value: .int(5))),
        ("atMost", .double(0.5), .atMost(value: .double(0.5)))
    ])
    func sendsEachCondition(name: String, value: Value, condition: ProbeCondition) async throws {
        let (result, requests) = try await wait(["key": "pending", "condition": .string(name), "value": value])

        #expect(result.isError != true, "\(text(result))")
        #expect(requests == [.wait(key: "pending", condition: condition, timeoutMilliseconds: 10_000)])
    }

    @Test func returnsTheProbeThatMetTheCondition() async throws {
        let (result, _) = try await wait(atLeastFive)

        #expect(text(result).contains("Pending uploads"))
        #expect(text(result).contains("\"value\" : 5"), "\(text(result))")
    }

    @Test(arguments: [
        (Value.int(30), 30_000),
        (.double(2.5), 2500),
        (.double(2.007), 2007),
        (.double(0.0001), 1),
        (.double(0.0015), 2)
    ])
    func forwardsTheTimeoutInMilliseconds(seconds: Value, milliseconds: Int) async throws {
        var arguments = atLeastFive
        arguments["timeoutSeconds"] = seconds

        let (result, requests) = try await wait(arguments)

        #expect(result.isError != true, "\(text(result))")
        #expect(requests == [.wait(key: "pending", condition: .atLeast(value: .int(5)), timeoutMilliseconds: milliseconds)])
    }

    @Test func aDataURLStringIsSentAsText() async throws {
        let url = "data:text/plain;base64,aGk="
        let value = try JSONDecoder().decode(Value.self, from: JSONEncoder().encode(url))
        guard case .data = value else {
            Issue.record("The SDK no longer decodes a data URL as data, so this test checks nothing.")
            return
        }

        let (_, requests) = try await wait(["key": "screen", "condition": "equals", "value": value])

        #expect(requests == [.wait(key: "screen", condition: .equals(value: .string(url)), timeoutMilliseconds: 10_000)])
    }

    // MARK: - How long it waits for the app

    @Test func theBridgeOutlastsTheWait() async throws {
        var arguments = atLeastFive
        arguments["timeoutSeconds"] = 2
        // Longer than the bridge's own timeout, within the wait's plus its slack.
        let slow = FakeEndpoint.Behavior.replies(after: .milliseconds(1500)) { _ in .probe(probe: sampleProbe) }

        let (result, _) = try await wait(arguments, timeout: .milliseconds(500), behavior: slow)

        #expect(result.isError != true, "\(text(result))")
        #expect(text(result).contains("Pending uploads"))
    }

    @Test func theBridgeOutlastsTheWaitByTheSlack() async throws {
        var arguments = atLeastFive
        arguments["timeoutSeconds"] = 1
        // After the wait's own timeout, within its slack.
        let slow = FakeEndpoint.Behavior.replies(after: .seconds(2)) { _ in .probe(probe: sampleProbe) }

        let (result, _) = try await wait(arguments, timeout: .milliseconds(500), behavior: slow)

        #expect(result.isError != true, "\(text(result))")
        #expect(text(result).contains("Pending uploads"))
    }

    @Test func otherToolsStillTimeOutOnTheBridgesTimeout() async throws {
        // The same slow app, so the test above proves the wait's own timeout.
        let slow = FakeEndpoint.Behavior.replies(after: .milliseconds(1500)) { _ in .probe(probe: sampleProbe) }
        let endpoint = try await FakeEndpoint(slow)
        let app = endpoint.app()
        let tools = BridgeTools(timeout: .milliseconds(500)) { [app] }

        let result = await tools.call("savestate_read", arguments: ["key": "pending"])

        #expect(result.isError == true)
        #expect(text(result).contains("didn't answer in time"))
    }

    @Test func aShortWaitStillGetsTheBridgesTimeout() async throws {
        var arguments = atLeastFive
        arguments["timeoutSeconds"] = 0.1
        // Slower than the wait plus its slack, within the bridge's own timeout.
        let slow = FakeEndpoint.Behavior.replies(after: .milliseconds(5500)) { _ in .probe(probe: sampleProbe) }

        let (result, _) = try await wait(arguments, timeout: .seconds(10), behavior: slow)

        #expect(result.isError != true, "\(text(result))")
    }

    // MARK: - Arguments

    @Test(arguments: [
        ([:], "This tool needs key."),
        (["key": "pending", "value": 5], "savestate_wait needs a condition: equals, notEquals, atLeast, atMost."),
        (["key": "pending", "condition": "atLeast"], "savestate_wait needs a value to compare with."),
        (["key": "pending", "condition": "greaterThan", "value": 5], "condition must be one of: equals, notEquals, atLeast, atMost."),
        (["key": "pending", "condition": 3, "value": 5], "condition must be one of: equals, notEquals, atLeast, atMost.")
    ] as [([String: Value], String)])
    func rejectsMissingOrBadArguments(arguments: [String: Value], message: String) async throws {
        let (result, requests) = try await wait(arguments)

        #expect(result.isError == true)
        #expect(text(result) == message)
        #expect(requests.isEmpty)
    }

    @Test(arguments: [Value.null, .array([.int(1)]), .object(["a": .int(1)])])
    func rejectsAValueThatIsntAScalar(value: Value) async throws {
        let (result, requests) = try await wait(["key": "pending", "condition": "equals", "value": value])

        #expect(result.isError == true)
        #expect(text(result).hasPrefix("value can't be "), "\(text(result))")
        #expect(text(result).contains("true or false, a number, a string, or a date-time"))
        #expect(requests.isEmpty)
    }

    @Test(arguments: [Value.int(0), .double(-1), .double(30.001), .int(31), .string("5"), .bool(true), .null, .double(.nan)])
    func rejectsATimeoutOutOfRange(seconds: Value) async throws {
        var arguments = atLeastFive
        arguments["timeoutSeconds"] = seconds

        let (result, requests) = try await wait(arguments)

        #expect(result.isError == true)
        #expect(text(result) == "timeoutSeconds must be a number more than 0 and at most 30.")
        #expect(requests.isEmpty)
    }

    @Test func theSchemaListsTheConditionsAndRequiresTheirArguments() throws {
        let tool = try #require(BridgeTools.definitions.first { $0.name == "savestate_wait" })
        let schema = try #require(tool.inputSchema.objectValue)
        let condition = schema["properties"]?.objectValue?["condition"]?.objectValue

        #expect(condition?["enum"] == ["equals", "notEquals", "atLeast", "atMost"])
        #expect(schema["properties"]?.objectValue?["value"]?.objectValue?["type"] == ["boolean", "number", "string"])
        #expect(tool.description?.contains("Controls can't be waited on") == true)
        #expect(schema["required"] == ["key", "condition", "value"])
        #expect(schema["properties"]?.objectValue?["timeoutSeconds"] != nil)
    }

    @Test func readAndDescribeMentionProbes() throws {
        let read = try #require(BridgeTools.definitions.first { $0.name == "savestate_read" })
        let describe = try #require(BridgeTools.definitions.first { $0.name == "savestate_describe" })
        let key = read.inputSchema.objectValue?["properties"]?.objectValue?["key"]?.objectValue?["description"]

        #expect(key == "The control's or probe's key from savestate_describe.")
        #expect(describe.description?.contains("probes") == true)
        #expect(describe.description?.contains("savestate_wait") == true)
    }

    // MARK: - Odd answers

    @Test func aWaitAnsweredWithTheWrongResultIsReported() async throws {
        let (result, _) = try await wait(atLeastFive, behavior: .replies { _ in .done })

        #expect(result.isError == true)
        #expect(text(result).contains("unexpected response"))
    }

    @Test func aReadFallsBackOnlyOnUnknownControl() async throws {
        let failure = WireError(code: .badRequest, message: "Bad message.")
        let endpoint = try await FakeEndpoint(.replies { _ in .failure(error: failure) })
        let app = endpoint.app()
        let tools = BridgeTools(timeout: .seconds(5)) { [app] }

        let result = await tools.call("savestate_read", arguments: ["key": "pending"])

        #expect(text(result) == "Bad message.")
        #expect(endpoint.log.all == [.read(key: "pending")])
    }

    @Test func aProbeReadFailingOtherwiseKeepsTheAppsMessage() async throws {
        let endpoint = try await FakeEndpoint(.replies { request in
            if case .read = request {
                return .failure(error: WireError(code: .unknownControl, message: "No control."))
            }
            return .failure(error: WireError(code: .badRequest, message: "Bad message."))
        })
        let app = endpoint.app()
        let tools = BridgeTools(timeout: .seconds(5)) { [app] }

        let result = await tools.call("savestate_read", arguments: ["key": "pending"])

        #expect(text(result) == "Bad message.")
        #expect(endpoint.log.all == [.read(key: "pending"), .readProbe(key: "pending")])
    }

    @Test func aProbeReadAnsweredWithTheWrongResultIsReported() async throws {
        let endpoint = try await FakeEndpoint(.replies { request in
            if case .read = request {
                return .failure(error: WireError(code: .unknownControl, message: "No control."))
            }
            return .done
        })
        let app = endpoint.app()
        let tools = BridgeTools(timeout: .seconds(5)) { [app] }

        let result = await tools.call("savestate_read", arguments: ["key": "pending"])

        #expect(result.isError == true)
        #expect(text(result).contains("unexpected response"))
    }
}
