import SaveStateBridgeKit
import SaveStateProtocol
import Testing

@Test func bridgeSpeaksTheCurrentWireProtocol() {
    #expect(Bridge.protocolVersion == WireProtocol.version)
}
