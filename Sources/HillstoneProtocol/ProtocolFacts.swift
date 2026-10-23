import Foundation

public struct ProtocolFact: Identifiable, Equatable, Sendable {
    public enum Confidence: String, Sendable {
        case verified = "已确认"
    }

    public let id: String
    public let title: String
    public let detail: String
    public let confidence: Confidence

    public init(id: String, title: String, detail: String, confidence: Confidence) {
        self.id = id
        self.title = title
        self.detail = detail
        self.confidence = confidence
    }
}

public enum ProtocolFacts {
    public static let all: [ProtocolFact] = [
        .init(id: "spa", title: "网关开启方式", detail: "当前配置 SPA 模式为 0，直接建立 TLS 控制连接", confidence: .verified),
        .init(id: "control", title: "TLS 控制通道", detail: "TCP 4433，当前网关协商 TLS 1.2", confidence: .verified),
        .init(id: "framing", title: "控制消息", detail: "8 字节头 + 四字节对齐 TLV", confidence: .verified),
        .init(id: "data", title: "数据通道", detail: "UDP ESP 或网关下发端口的 TCP 私有帧", confidence: .verified),
        .init(id: "vnic", title: "虚拟网卡", detail: "Apple utun，MTU 1380", confidence: .verified),
        .init(id: "keymap", title: "密钥字段映射", detail: "PLAIN 交换、48 字节 KEYMAT、双向 SPI", confidence: .verified),
        .init(id: "network", title: "接口与路由", detail: "动态配置 utun、IPv4、DNS、MTU 与包含路由", confidence: .verified),
        .init(id: "cipher", title: "当前会话密码套件", detail: "3DES-CBC 与 HMAC-SHA1-96", confidence: .verified)
    ]
}

public enum HillstoneTCPFrameError: Error, Equatable, LocalizedError, Sendable {
    case payloadTooLarge(Int)
    case invalidMagic
    case unsupportedVersion
    case unsupportedType

    public var errorDescription: String? {
        switch self {
        case let .payloadTooLarge(length): "TCP 数据帧过大（\(length) 字节，最大 4095 字节）"
        case .invalidMagic: "TCP 数据帧魔数无效"
        case .unsupportedVersion: "TCP 数据帧版本不受支持"
        case .unsupportedType: "TCP 数据帧类型不受支持"
        }
    }
}

/// Framing used by Secure Connect 5.7's `IPSecTunnelOverTCP` data channel.
/// The format was recovered from the installed Intel client's unstripped
/// `CheckTcpPacketPrivateHeader`: one big-endian 32-bit word followed by an ESP
/// datagram. The low 12 bits carry payload length.
public struct HillstoneTCPFrameCodec: Sendable {
    public static let maximumPayloadLength = 0x0fff
    private static let magic: UInt32 = 0x7c72_0000
    private var buffer = Data()
    private var readOffset = 0

    public init() {}

    public var bufferedByteCount: Int { buffer.count - readOffset }

    public static func encode(_ payload: Data) throws -> Data {
        guard !payload.isEmpty, payload.count <= maximumPayloadLength else {
            throw HillstoneTCPFrameError.payloadTooLarge(payload.count)
        }
        let word = magic | UInt32(payload.count)
        var frame = Data(capacity: 4 + payload.count)
        frame.append(UInt8(truncatingIfNeeded: word >> 24))
        frame.append(UInt8(truncatingIfNeeded: word >> 16))
        frame.append(UInt8(truncatingIfNeeded: word >> 8))
        frame.append(UInt8(truncatingIfNeeded: word))
        frame.append(payload)
        return frame
    }

    public mutating func append(_ bytes: Data) throws -> [Data] {
        compactConsumedBytesIfNeeded()
        buffer.append(bytes)
        var payloads: [Data] = []
        while buffer.count - readOffset >= 4 {
            let header = buffer.startIndex + readOffset
            let word = UInt32(buffer[header]) << 24
                | UInt32(buffer[header + 1]) << 16
                | UInt32(buffer[header + 2]) << 8
                | UInt32(buffer[header + 3])
            guard word & 0xfffe_0000 == Self.magic else { throw HillstoneTCPFrameError.invalidMagic }
            guard word & 0x0001_8000 == 0 else { throw HillstoneTCPFrameError.unsupportedVersion }
            guard word & 0x0000_7000 == 0 else { throw HillstoneTCPFrameError.unsupportedType }
            let length = Int(word & 0x0fff)
            guard length > 0 else { throw HillstoneTCPFrameError.payloadTooLarge(length) }
            guard buffer.count - readOffset >= 4 + length else { break }
            let payloadStart = header + 4
            payloads.append(Data(buffer[payloadStart..<(payloadStart + length)]))
            readOffset += 4 + length
        }
        compactConsumedBytesIfNeeded()
        return payloads
    }

    private mutating func compactConsumedBytesIfNeeded() {
        guard readOffset > 0 else { return }
        if readOffset == buffer.count {
            buffer.removeAll(keepingCapacity: true)
            readOffset = 0
        } else if readOffset >= 65_536 || readOffset * 2 >= buffer.count {
            buffer.removeFirst(readOffset)
            readOffset = 0
        }
    }
}
