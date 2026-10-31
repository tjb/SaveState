import Foundation
import SaveStateProtocol
import Testing

private let premium = ControlDescription(
    key: "premium",
    label: "Premium",
    section: nil,
    kind: .triState,
    value: .null,
    realValue: nil,
    effectiveValue: .bool(true),
    defaultValue: .null,
    requiresRelaunch: false,
    nextLaunchValue: nil,
    isChanged: false
)

private let premiumJSON = #"{"defaultValue":{"type":"null"},"effectiveValue":{"type":"bool","value":true},"#
    + #""isChanged":false,"key":"premium","kind":{"type":"triState"},"label":"Premium","#
    + #""requiresRelaunch":false,"value":{"type":"null"}}"#

/// Sets every optional field, so each one's key is pinned.
private let environment = ControlDescription(
    key: "env",
    label: "Environment",
    section: "Network",
    kind: .choice(options: ["staging", "production"]),
    value: .string("staging"),
    realValue: .string("production"),
    effectiveValue: .string("staging"),
    defaultValue: .string("production"),
    requiresRelaunch: true,
    nextLaunchValue: .string("staging"),
    isChanged: true
)

private let environmentJSON = #"{"defaultValue":{"type":"string","value":"production"},"#
    + #""effectiveValue":{"type":"string","value":"staging"},"isChanged":true,"key":"env","#
    + #""kind":{"options":["staging","production"],"type":"choice"},"label":"Environment","#
    + #""nextLaunchValue":{"type":"string","value":"staging"},"#
    + #""realValue":{"type":"string","value":"production"},"requiresRelaunch":true,"#
    + #""section":"Network","value":{"type":"string","value":"staging"}}"#

private let expiredTrial = ScenarioDescription(
    key: "expired-trial",
    label: "Expired trial",
    section: "Purchases",
    summary: "The trial ended."
)

private let expiredTrialJSON = #"{"key":"expired-trial","label":"Expired trial","#
    + #""section":"Purchases","summary":"The trial ended."}"#

/// These pin the JSON itself. The app and the bridge ship separately, so a
/// change here is a breaking wire change that needs a `WireProtocol.version` bump.
@Suite("Wire format")
struct WireFormatTests {
    @Test(arguments: [
        (WireRequest.describe, #"{"describe":{}}"#),
        (.read(key: "on"), #"{"read":{"key":"on"}}"#),
        (
            .set(key: "on", value: .bool(true), persist: true),
            #"{"set":{"key":"on","persist":true,"value":{"type":"bool","value":true}}}"#
        ),
        (.runAction(key: "seed"), #"{"runAction":{"key":"seed"}}"#),
        (.applyScenario(key: "expired-trial"), #"{"applyScenario":{"key":"expired-trial"}}"#)
    ])
    func requestsEncodeStably(_ request: WireRequest, expected: String) throws {
        let text = try json(request)
        let decoded = try roundTrip(request)

        #expect(text == expected)
        #expect(decoded == request)
    }

    @Test func doneEncodesStably() throws {
        let text = try json(WireResult.done)

        #expect(text == #"{"done":{}}"#)
    }

    @Test func controlResultEncodesStably() throws {
        let text = try json(WireResult.control(control: premium))

        #expect(text == #"{"control":{"control":\#(premiumJSON)}}"#)
    }

    @Test func aControlWithEveryOptionalFieldEncodesStably() throws {
        #expect(try json(environment) == environmentJSON)
    }

    /// Decodes literal JSON, because a round trip would use one set of keys on
    /// both sides and pass under any rename.
    @Test func aControlWithEveryOptionalFieldDecodesFromItsPinnedJSON() throws {
        let decoded = try JSONDecoder().decode(ControlDescription.self, from: Data(environmentJSON.utf8))

        #expect(decoded == environment)
    }

    @Test func aScenarioWithEveryOptionalFieldEncodesStably() throws {
        #expect(try json(expiredTrial) == expiredTrialJSON)
    }

    @Test func aScenarioWithEveryOptionalFieldDecodesFromItsPinnedJSON() throws {
        let decoded = try JSONDecoder().decode(ScenarioDescription.self, from: Data(expiredTrialJSON.utf8))

        #expect(decoded == expiredTrial)
    }

    @Test func descriptionResultEncodesStably() throws {
        let registry = RegistryDescription(
            controls: [premium],
            actions: [ActionDescription(key: "erase", label: "Erase", section: "Data", isDestructive: true)],
            scenarios: [ScenarioDescription(key: "fresh", label: "Fresh", section: nil, summary: "New user")]
        )

        let text = try json(WireResult.description(registry: registry))

        #expect(text == #"{"description":{"registry":{"actions":[{"isDestructive":true,"key":"erase","label":"Erase","section":"Data"}],"#
            + #""controls":[\#(premiumJSON)],"#
            + #""scenarios":[{"key":"fresh","label":"Fresh","summary":"New user"}]}}}"#)
    }

    @Test func requestEnvelopesEncodeStably() throws {
        let text = try json(RequestEnvelope(id: 3, request: .describe))

        #expect(text == #"{"id":3,"request":{"describe":{}}}"#)
    }

    @Test func aResponseWithAnIDEncodesIt() throws {
        let text = try json(ResponseEnvelope(id: 3, result: .done))

        #expect(text == #"{"id":3,"result":{"done":{}}}"#)
    }

    @Test func aResponseWithoutAnIDOmitsIt() throws {
        let text = try json(ResponseEnvelope(id: nil, result: .done))

        #expect(text == #"{"result":{"done":{}}}"#)
    }

    @Test func aNullResponseIDDecodesAsNil() throws {
        let data = Data(#"{"id":null,"result":{"done":{}}}"#.utf8)

        let envelope = try JSONDecoder().decode(ResponseEnvelope.self, from: data)

        #expect(envelope.id == nil)
    }

    @Test func clientHellosEncodeStably() throws {
        let text = try json(ClientHello(protocolVersion: 2, token: "secret"))

        #expect(text == #"{"protocolVersion":2,"token":"secret"}"#)
    }

    @Test func rejectedServerHellosEncodeStably() throws {
        let hello = ServerHello.rejected(error: WireError(code: .protocolMismatch, message: "No."))

        let text = try json(hello)

        #expect(text == #"{"rejected":{"error":{"code":"protocolMismatch","message":"No."}}}"#)
    }

    @Test func endpointFilesEncodeStably() throws {
        let info = EndpointInfo(
            protocolVersion: 2,
            port: 65_535,
            token: "secret",
            bundleIdentifier: "com.example.app",
            appName: "Example",
            processIdentifier: 42
        )

        let text = try json(info)
        let decoded = try roundTrip(info)

        #expect(text == #"{"appName":"Example","bundleIdentifier":"com.example.app","port":65535,"#
            + #""processIdentifier":42,"protocolVersion":2,"token":"secret"}"#)
        #expect(decoded == info)
    }

    @Test func theEndpointFileStaysAtItsAgreedPath() {
        #expect(EndpointInfo.relativePath == "Library/Application Support/SaveState/endpoint.json")
    }

    @Test(arguments: [
        (WireError.Code.unauthorized, "unauthorized"),
        (.protocolMismatch, "protocolMismatch"),
        (.badRequest, "badRequest"),
        (.disabled, "disabled"),
        (.unknownControl, "unknownControl"),
        (.unknownAction, "unknownAction"),
        (.unknownScenario, "unknownScenario"),
        (.destructiveActionNotAllowed, "destructiveActionNotAllowed"),
        (.invalidValue, "invalidValue"),
        (.operationFailed, "operationFailed")
    ])
    func errorCodesKeepTheirNames(_ code: WireError.Code, name: String) throws {
        let text = try json(WireError(code: code, message: "m"))

        #expect(text == #"{"code":"\#(name)","message":"m"}"#)
    }
}

@Suite("Malformed wire messages")
struct MalformedWireMessageTests {
    @Test(arguments: [
        "{}",
        #"{"bogus":{}}"#,
        #"{"read":{}}"#,
        #"{"read":{"key":1}}"#,
        #"{"set":{"key":"on","value":{"type":"bool","value":true}}}"#,
        #"{"set":{"key":"on","persist":true}}"#,
        #"{"set":{"key":"on","persist":true,"value":{"type":"bool"}}}"#,
        #"{"read":{"key":"on"},"describe":{}}"#
    ])
    func badRequestsFailToDecode(_ text: String) {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(WireRequest.self, from: Data(text.utf8))
        }
    }

    @Test(arguments: [
        #"{"request":{"describe":{}}}"#,
        #"{"id":"3","request":{"describe":{}}}"#,
        #"{"id":3}"#
    ])
    func badRequestEnvelopesFailToDecode(_ text: String) {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(RequestEnvelope.self, from: Data(text.utf8))
        }
    }

    @Test func anUnknownErrorCodeFailsToDecode() {
        let data = Data(#"{"code":"teapot","message":"m"}"#.utf8)

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(WireError.self, from: data)
        }
    }

    @Test(arguments: [65_536, -1])
    func anOutOfRangePortFailsToDecode(_ port: Int) {
        let data = Data(
            #"{"appName":"A","bundleIdentifier":"b","port":\#(port),"processIdentifier":1,"protocolVersion":2,"token":"t"}"#.utf8
        )

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(EndpointInfo.self, from: data)
        }
    }

    @Test func aControlMissingARequiredFieldFailsToDecode() {
        let data = Data(#"{"key":"k","label":"L"}"#.utf8)

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(ControlDescription.self, from: data)
        }
    }
}
