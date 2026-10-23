import Foundation
import CommonCrypto
import Security

public enum ESPError: Error, Equatable, LocalizedError, Sendable {
    case packetTooShort
    case invalidPadding
    case invalidAuthentication
    case invalidKeyMaterial
    case cryptorFailure(Int32)

    public var errorDescription: String? {
        switch self {
        case .packetTooShort: "ESP 数据包长度不足"
        case .invalidPadding: "ESP 填充格式无效"
        case .invalidAuthentication: "ESP 数据包认证失败"
        case .invalidKeyMaterial: "隧道密钥材料无效"
        case let .cryptorFailure(status): "3DES 加解密失败（\(status)）"
        }
    }
}

public struct HillstoneSecurityAssociation: Equatable, Sendable {
    public let inboundSPI: UInt32
    public let outboundSPI: UInt32
    public let outboundIV: Data
    public let outboundAuthenticationKey: Data
    public let outboundEncryptionKey: Data
    public let inboundAuthenticationKey: Data
    public let inboundEncryptionKey: Data

    /// Hillstone expands the 48-byte negotiated secret into directional keys
    /// by repeatedly hashing the accumulated material with SHA-1.
    public init(inboundSPI: UInt32, outboundSPI: UInt32, keyMaterial: Data) throws {
        guard keyMaterial.count == 48 else { throw ESPError.invalidKeyMaterial }
        self.inboundSPI = inboundSPI
        self.outboundSPI = outboundSPI
        self.outboundIV = keyMaterial.prefix(8)

        var expanded = Data(Self.sha1(keyMaterial))
        for _ in 0..<9 { expanded.append(contentsOf: Self.sha1(expanded)) }
        var offset = 0
        func take(_ count: Int) -> Data {
            defer { offset += count }
            return expanded.subdata(in: offset..<(offset + count))
        }
        outboundAuthenticationKey = take(20)
        outboundEncryptionKey = take(24)
        inboundAuthenticationKey = take(20)
        inboundEncryptionKey = take(24)
    }

    private static func sha1(_ data: Data) -> [UInt8] {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        data.withUnsafeBytes { bytes in
            _ = CC_SHA1(bytes.baseAddress, CC_LONG(data.count), &digest)
        }
        return digest
    }
}

/// Stateful codec for the server's ESP transport (3DES-CBC and
/// HMAC-SHA1-96). Callers serialize access to `seal` so sequence numbers stay
/// monotonic.
public final class HillstoneESPCodec: @unchecked Sendable {
    private var association: HillstoneSecurityAssociation
    private var nextSequence: UInt32 = 1
    private let lock = NSLock()

    public init(association: HillstoneSecurityAssociation) {
        self.association = association
    }

    public func seal(_ IPPacket: Data, nextHeader: UInt8 = 4) throws -> Data {
        try sealBatch([IPPacket], nextHeaders: [nextHeader])[0]
    }

    public func sealBatch(_ packets: [Data], nextHeaders: [UInt8]) throws -> [Data] {
        guard packets.count == nextHeaders.count else { throw ESPError.invalidKeyMaterial }
        lock.lock()
        let association = self.association
        let firstSequence = nextSequence
        nextSequence &+= UInt32(packets.count)
        lock.unlock()

        return try packets.indices.map { index in
            try Self.seal(
                packets[index], nextHeader: nextHeaders[index],
                sequence: firstSequence &+ UInt32(index), association: association
            )
        }
    }

    private static func seal(
        _ IPPacket: Data,
        nextHeader: UInt8,
        sequence: UInt32,
        association: HillstoneSecurityAssociation
    ) throws -> Data {
        var plaintext = IPPacket
        ESPPadding.append(to: &plaintext, blockSize: kCCBlockSize3DES, nextHeader: nextHeader)
        let encrypted = try Self.crypt(
            operation: CCOperation(kCCEncrypt),
            input: plaintext,
            key: association.outboundEncryptionKey,
            iv: association.outboundIV
        )
        var authenticated = ESPHeader(spi: association.outboundSPI, sequence: sequence).encoded()
        authenticated.append(association.outboundIV)
        authenticated.append(encrypted)
        authenticated.append(Self.hmacSHA1(authenticated, key: association.outboundAuthenticationKey).prefix(12))
        return authenticated
    }

    public func open(_ datagram: Data) throws -> (packet: Data, nextHeader: UInt8) {
        lock.lock(); let association = self.association; lock.unlock()
        let minimum = 8 + kCCBlockSize3DES + kCCBlockSize3DES + 12
        guard datagram.count >= minimum else { throw ESPError.packetTooShort }
        let receivedICV = datagram.suffix(12)
        let expectedICV = Self.hmacSHA1(
            datagram, byteCount: datagram.count - 12, key: association.inboundAuthenticationKey
        ).prefix(12)
        guard Self.constantTimeEqual(receivedICV, expectedICV) else {
            throw ESPError.invalidAuthentication
        }

        let header = try ESPHeader.decode(Data(datagram.prefix(8)))
        guard header.spi == association.inboundSPI else { throw ESPError.invalidAuthentication }
        let iv = datagram.subdata(in: 8..<16)
        let ciphertext = datagram.subdata(in: 16..<(datagram.count - 12))
        let plaintext = try Self.crypt(
            operation: CCOperation(kCCDecrypt),
            input: ciphertext,
            key: association.inboundEncryptionKey,
            iv: iv
        )
        let opened = try ESPPadding.remove(from: plaintext)
        return (opened.payload, opened.nextHeader)
    }

    public func replaceAssociation(_ newAssociation: HillstoneSecurityAssociation) {
        lock.lock(); association = newAssociation; nextSequence = 1; lock.unlock()
    }

    private static func crypt(operation: CCOperation, input: Data, key: Data, iv: Data) throws -> Data {
        guard key.count == kCCKeySize3DES, iv.count == kCCBlockSize3DES,
              input.count.isMultiple(of: kCCBlockSize3DES) else {
            throw ESPError.invalidKeyMaterial
        }
        let outputCapacity = input.count
        var output = Data(count: outputCapacity)
        var moved = 0
        let status: CCCryptorStatus = output.withUnsafeMutableBytes { outputBytes in
            input.withUnsafeBytes { inputBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(operation, CCAlgorithm(kCCAlgorithm3DES), CCOptions(0),
                                keyBytes.baseAddress, key.count, ivBytes.baseAddress,
                                inputBytes.baseAddress, input.count,
                                outputBytes.baseAddress, outputCapacity, &moved)
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw ESPError.cryptorFailure(status) }
        output.removeSubrange(moved..<output.count)
        return output
    }

    private static func hmacSHA1(_ data: Data, byteCount: Int? = nil, key: Data) -> Data {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        let count = byteCount ?? data.count
        key.withUnsafeBytes { keyBytes in
            data.withUnsafeBytes { dataBytes in
                CCHmac(CCHmacAlgorithm(kCCHmacAlgSHA1), keyBytes.baseAddress, key.count,
                       dataBytes.baseAddress, count, &digest)
            }
        }
        return Data(digest)
    }

    private static func constantTimeEqual<T: DataProtocol, U: DataProtocol>(_ lhs: T, _ rhs: U) -> Bool {
        let left = Array(lhs), right = Array(rhs)
        guard left.count == right.count else { return false }
        var difference: UInt8 = 0
        for index in left.indices { difference |= left[index] ^ right[index] }
        return difference == 0
    }
}

public struct ESPHeader: Equatable, Sendable {
    public let spi: UInt32
    public let sequence: UInt32

    public init(spi: UInt32, sequence: UInt32) {
        self.spi = spi
        self.sequence = sequence
    }

    public func encoded() -> Data {
        var data = Data(capacity: 8)
        data.appendUInt32BE(spi)
        data.appendUInt32BE(sequence)
        return data
    }

    public static func decode(_ data: Data) throws -> ESPHeader {
        guard data.count >= 8 else { throw ESPError.packetTooShort }
        var cursor = ByteCursor(data)
        return ESPHeader(spi: try cursor.readUInt32BE(), sequence: try cursor.readUInt32BE())
    }
}

public enum ESPPadding {
    public static func append(to plaintext: inout Data, blockSize: Int, nextHeader: UInt8) {
        precondition(blockSize > 0)
        let remainder = (plaintext.count + 2) % blockSize
        let paddingCount = remainder == 0 ? 0 : blockSize - remainder
        if paddingCount > 0 {
            plaintext.append(contentsOf: (1...paddingCount).map(UInt8.init))
        }
        plaintext.append(UInt8(paddingCount))
        plaintext.append(nextHeader)
    }

    public static func remove(from plaintext: Data) throws -> (payload: Data, nextHeader: UInt8) {
        guard plaintext.count >= 2 else { throw ESPError.packetTooShort }
        let paddingCount = Int(plaintext[plaintext.index(plaintext.endIndex, offsetBy: -2)])
        let nextHeader = plaintext.last!
        guard paddingCount <= plaintext.count - 2 else { throw ESPError.invalidPadding }
        if paddingCount > 0 {
            let start = plaintext.count - 2 - paddingCount
            for index in 0..<paddingCount where plaintext[start + index] != UInt8(index + 1) {
                throw ESPError.invalidPadding
            }
        }
        return (plaintext.prefix(plaintext.count - paddingCount - 2), nextHeader)
    }
}

public struct HillstoneTransportPrefix: Equatable, Sendable {
    public static let marker: UInt16 = 0x7c72
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public var hasExpectedMarker: Bool {
        UInt16(rawValue >> 16) == Self.marker
    }
}
