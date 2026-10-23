import Foundation
import Testing
@testable import HillstoneProtocol

@Test func controlMessageRoundTrip() throws {
    let message = ControlMessage(
        flags: 0x02,
        type: KnownMessageType.auth.rawValue,
        payloads: [
            ControlTLV(type: 1, value: Data("user".utf8)),
            ControlTLV(type: 9, value: Data([0x00, 0x01]))
        ]
    )

    let data = try message.encoded()
    #expect(data.prefix(8) == Data([0x22, 0x02, 0x00, 0x01, 0x00, 0x00, 0x00, 0x18]))
    #expect(try ControlMessage.decode(data) == message)
}

@Test func controlMessagePadsTLVValuesToFourBytes() throws {
    let message = ControlMessage(type: 3, payloads: [ControlTLV(type: 7, value: Data([1, 2, 3]))])
    let data = try message.encoded()
    #expect(data.count == 16)
    #expect(data.suffix(1) == Data([0]))
    #expect(try ControlMessage.decode(data).payloads[0].value == Data([1, 2, 3]))
}

@Test func rejectsWrongMagic() {
    let data = Data([0x21, 0, 0, 1, 0, 0, 0, 8])
    #expect(throws: ProtocolDecodeError.invalidMagic(0x21)) {
        try ControlMessage.decode(data)
    }
}

@Test func streamDecoderReassemblesFragmentedMessage() throws {
    let expected = ControlMessage(
        type: KnownMessageType.setRoute.rawValue,
        payloads: [ControlTLV(type: 12, value: Data([10, 0, 0, 0, 8]))]
    )
    let encoded = try expected.encoded()
    var decoder = ControlStreamDecoder()

    #expect(try decoder.append(encoded.prefix(3)).isEmpty)
    #expect(try decoder.append(encoded.dropFirst(3).prefix(7)).isEmpty)
    #expect(try decoder.append(encoded.dropFirst(10)) == [expected])
    #expect(decoder.bufferedByteCount == 0)
}

@Test func streamDecoderEmitsCoalescedMessages() throws {
    let first = ControlMessage(type: KnownMessageType.auth.rawValue)
    let second = ControlMessage(
        flags: 1,
        type: KnownMessageType.clientInfo.rawValue,
        payloads: [ControlTLV(type: 2, value: Data("macOS".utf8))]
    )
    var wire = try first.encoded()
    wire.append(try second.encoded())

    var decoder = ControlStreamDecoder()
    #expect(try decoder.append(wire) == [first, second])
}

@Test func streamDecoderRejectsImplausiblyLargeFrame() throws {
    let header = Data([0x22, 0, 0, 1, 0, 0, 0x10, 0])
    var decoder = ControlStreamDecoder(maximumMessageLength: 512)
    #expect(throws: ProtocolDecodeError.invalidTotalLength(4096)) {
        try decoder.append(header)
    }
}

@Test func authenticationMessageMatchesGatewayFieldOrder() throws {
    let message = HillstoneProtocolMessages.authentication(
        username: "alice", password: "secret", hostID: "host-id", hostName: "Mac"
    )
    #expect(message.knownType == .auth)
    #expect(message.payloads.map(\.type) == [81, 1, 2, 84, 96, 97])
    #expect(message.payloads[0].value == Data([0, 1]))
    #expect(message.payloads[1].value == Data("alice".utf8))
    #expect(message.payloads[2].value == Data("secret".utf8))
}

@Test func parsesAddressDNSPortAndFullTunnelRoutes() throws {
    let clientInfo = ControlMessage(type: KnownMessageType.clientInfo.rawValue, payloads: [
        ControlTLV(.status, integer: 0, byteCount: 4),
        ControlTLV(.serverTCPPort, value: Data([0x11, 0x51]))
    ])
    let setIP = ControlMessage(type: KnownMessageType.setIP.rawValue, payloads: [
        ControlTLV(.clientPrivateIPv4, value: Data([192, 168, 88, 64])),
        ControlTLV(.serverPrivateIPv4, value: Data([192, 168, 88, 1])),
        ControlTLV(.netmaskIPv4, value: Data([255, 255, 255, 0])),
        ControlTLV(.serverUDPPort, value: Data([0x11, 0x51])),
        ControlTLV(.dnsIPv4, value: Data([192, 168, 6, 5]))
    ])
    let routes = ControlMessage(type: KnownMessageType.setRoute.rawValue, payloads: [
        ControlTLV(.routeIPv4, value: Data([
            0, 0, 0, 0, 128, 0, 0, 0,
            128, 0, 0, 0, 128, 0, 0, 0
        ]))
    ])
    var negotiated = HillstoneNegotiatedNetwork()
    try HillstoneProtocolMessages.applyNetworkMessage(clientInfo, to: &negotiated)
    try HillstoneProtocolMessages.applyNetworkMessage(setIP, to: &negotiated)
    try HillstoneProtocolMessages.applyNetworkMessage(routes, to: &negotiated)
    let configuration = try negotiated.configuration(mtu: 1_380)
    #expect(configuration == .observedSessionFixture)
    #expect(negotiated.serverUDPPort == 4_433)
    #expect(negotiated.serverTCPPort == 4_433)
}

@Test func streamDecoderIgnoresIdleZeroFrame() throws {
    let message = ControlMessage(type: KnownMessageType.keepAlive.rawValue)
    var bytes = Data(repeating: 0, count: 8)
    bytes.append(try message.encoded())
    var decoder = ControlStreamDecoder()
    #expect(try decoder.append(bytes) == [message])
}

@Test func keepAliveCarriesSessionAndAliveStatus() throws {
    let sessionID = Data([0x12, 0x34, 0x56, 0x78])
    let encoded = try HillstoneProtocolMessages.keepAlive(sessionID: sessionID).encoded()
    #expect(encoded.prefix(8) == Data([0x22, 0x00, 0x00, 0x09, 0x00, 0x00, 0x00, 0x18]))
    let decoded = try ControlMessage.decode(encoded)
    #expect(decoded.payloads.map(\.type) == [51, 64])
    #expect(decoded.payloads[0].value == sessionID)
    #expect(decoded.payloads[1].value == Data([0, 0, 0, 0]))
}

@Test func hostCheckIsRejectedExplicitlyInsteadOfIgnored() {
    let check = ControlMessage(type: KnownMessageType.hostCheck.rawValue)
    #expect(throws: HillstoneNegotiationError.hostCheckRequired(update: false)) {
        try HillstoneProtocolMessages.rejectUnsupportedServerRequirement(check)
    }

    let update = ControlMessage(type: KnownMessageType.hostCheckUpdate.rawValue)
    #expect(throws: HillstoneNegotiationError.hostCheckRequired(update: true)) {
        try HillstoneProtocolMessages.rejectUnsupportedServerRequirement(update)
    }
}

@Test func tcpDataFrameCodecHandlesFragmentedAndCoalescedFrames() throws {
    let first = Data((0..<96).map(UInt8.init))
    let second = Data(repeating: 0xa5, count: 1_380)
    let firstFrame = try HillstoneTCPFrameCodec.encode(first)
    let secondFrame = try HillstoneTCPFrameCodec.encode(second)
    #expect(firstFrame.prefix(4) == Data([0x7c, 0x72, 0x00, 0x60]))

    var decoder = HillstoneTCPFrameCodec()
    #expect(try decoder.append(firstFrame.prefix(3)).isEmpty)
    var remainder = Data(firstFrame.dropFirst(3))
    remainder.append(secondFrame)
    #expect(try decoder.append(remainder) == [first, second])
    #expect(decoder.bufferedByteCount == 0)
}

@Test func tcpDataFrameCodecDrainsLargeCoalescedBatchWithoutLeavingBufferedBytes() throws {
    let payloads = (0..<96).map { index in
        Data(repeating: UInt8(truncatingIfNeeded: index), count: 1_380)
    }
    var coalesced = Data()
    for payload in payloads {
        coalesced.append(try HillstoneTCPFrameCodec.encode(payload))
    }

    var decoder = HillstoneTCPFrameCodec()
    let split = coalesced.count - 317
    let first = try decoder.append(coalesced.prefix(split))
    #expect(first.count == payloads.count - 1)
    #expect(decoder.bufferedByteCount > 0)

    let second = try decoder.append(coalesced.suffix(317))
    #expect(first + second == payloads)
    #expect(decoder.bufferedByteCount == 0)
}

@Test func tcpDataFrameCodecRejectsUnknownPrivateHeader() {
    var decoder = HillstoneTCPFrameCodec()
    #expect(throws: HillstoneTCPFrameError.invalidMagic) {
        try decoder.append(Data([0, 0, 0, 1, 0]))
    }
}
