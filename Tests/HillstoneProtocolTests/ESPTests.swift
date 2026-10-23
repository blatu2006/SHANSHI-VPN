import Foundation
import Testing
@testable import HillstoneProtocol

@Test func espHeaderRoundTrip() throws {
    let header = ESPHeader(spi: 0x11223344, sequence: 0x55667788)
    #expect(header.encoded() == Data([0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88]))
    #expect(try ESPHeader.decode(header.encoded()) == header)
}

@Test func espPaddingRoundTrip() throws {
    let original = Data((0..<31).map(UInt8.init))
    var padded = original
    ESPPadding.append(to: &padded, blockSize: 16, nextHeader: 4)
    #expect(padded.count.isMultiple(of: 16))

    let result = try ESPPadding.remove(from: padded)
    #expect(result.payload == original)
    #expect(result.nextHeader == 4)
}

@Test func derivesHillstoneDirectionalKeysFromNegotiatedSecret() throws {
    let material = Data((0..<48).map(UInt8.init))
    let association = try HillstoneSecurityAssociation(
        inboundSPI: 0x01020304, outboundSPI: 0x05060708, keyMaterial: material
    )
    #expect(association.outboundIV == Data(0..<8))
    #expect(association.outboundAuthenticationKey.hex == "df7f23b160e75b9bae5ea1e62b43a5a34a260127")
    #expect(association.outboundEncryptionKey.hex == "e9ec19f739854e70a63335f43b64f828a1baa6b582087d43")
    #expect(association.inboundAuthenticationKey.hex == "1d325a43cc44bb29fd7d541dcee8a3ff4a10f0bc")
    #expect(association.inboundEncryptionKey.hex == "3429ddc8a3976eb2e8f31fd3f452b379811bf9cc7a4735cc")
}

@Test func sealedESPUsesNegotiatedSPISequenceAndBlockLayout() throws {
    let association = try HillstoneSecurityAssociation(
        inboundSPI: 1, outboundSPI: 0x11223344, keyMaterial: Data((0..<48).map(UInt8.init))
    )
    let codec = HillstoneESPCodec(association: association)
    let first = try codec.seal(Data(repeating: 0x45, count: 31))
    let second = try codec.seal(Data(repeating: 0x45, count: 31))
    #expect(first.prefix(8) == Data([0x11, 0x22, 0x33, 0x44, 0, 0, 0, 1]))
    #expect(second.prefix(8) == Data([0x11, 0x22, 0x33, 0x44, 0, 0, 0, 2]))
    #expect((first.count - 8 - 8 - 12).isMultiple(of: 8))
}

@Test func sealedESPBatchUsesContiguousSequenceNumbers() throws {
    let association = try HillstoneSecurityAssociation(
        inboundSPI: 1, outboundSPI: 0x11223344, keyMaterial: Data((0..<48).map(UInt8.init))
    )
    let codec = HillstoneESPCodec(association: association)
    let sealed = try codec.sealBatch(
        [Data(repeating: 0x45, count: 64), Data(repeating: 0x60, count: 80), Data(repeating: 0x45, count: 96)],
        nextHeaders: [4, 41, 4]
    )

    #expect(sealed.count == 3)
    #expect(sealed[0].prefix(8) == Data([0x11, 0x22, 0x33, 0x44, 0, 0, 0, 1]))
    #expect(sealed[1].prefix(8) == Data([0x11, 0x22, 0x33, 0x44, 0, 0, 0, 2]))
    #expect(sealed[2].prefix(8) == Data([0x11, 0x22, 0x33, 0x44, 0, 0, 0, 3]))
}

private extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}

@Test func stateMachineFollowsObservedHandshake() {
    var machine = SessionStateMachine()
    machine.begin()
    machine.didSendSPA()
    machine.didSecureControlChannel()
    machine.consume(ControlMessage(type: 1))
    #expect(machine.stage == .checkingDevice)
    machine.consume(ControlMessage(type: 2))
    machine.consume(ControlMessage(type: 3))
    machine.consume(ControlMessage(type: 4))
    machine.consume(ControlMessage(type: 6))
    #expect(machine.stage == .exchangingKeys)
    machine.consume(ControlMessage(type: 5))
    #expect(machine.stage == .startingDataChannel)
}

/// A deterministic 24-hour session simulation: every logical hour replaces
/// the SA, then sends a burst. This exercises the hourly REKEY path without a
/// wall-clock, credentials, or a live gateway.
@Test func twentyFourHourlyRekeysResetSPIAndSequenceWithoutCorruptingPackets() throws {
    let firstAssociation = try HillstoneSecurityAssociation(
        inboundSPI: 1,
        outboundSPI: 0x7000_0000,
        keyMaterial: Data((0..<48).map(UInt8.init))
    )
    let codec = HillstoneESPCodec(association: firstAssociation)

    for hour in 0..<24 {
        let spi = UInt32(0x7000_0000 + hour)
        let material = Data((0..<48).map { UInt8(($0 + hour) & 0xff) })
        codec.replaceAssociation(try HillstoneSecurityAssociation(
            inboundSPI: UInt32(hour + 1), outboundSPI: spi, keyMaterial: material
        ))

        let packets = (0..<128).map { index in
            Data(repeating: UInt8((index + hour) & 0xff), count: 64 + index % 257)
        }
        let sealed = try codec.sealBatch(packets, nextHeaders: Array(repeating: 4, count: packets.count))
        #expect(sealed.count == packets.count)
        for (index, datagram) in sealed.enumerated() {
            let header = try ESPHeader.decode(Data(datagram.prefix(8)))
            #expect(header.spi == spi)
            #expect(header.sequence == UInt32(index + 1))
        }
    }
}
