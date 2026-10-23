import Foundation

public enum ProtocolDecodeError: Error, Equatable, LocalizedError, Sendable {
    case truncated(expected: Int, remaining: Int)
    case invalidMagic(UInt8)
    case invalidTotalLength(Int)
    case invalidPayloadLength(type: UInt16, length: Int)
    case trailingBytes(Int)

    public var errorDescription: String? {
        switch self {
        case let .truncated(expected, remaining):
            "消息不完整：需要 \(expected) 字节，只剩 \(remaining) 字节"
        case let .invalidMagic(value):
            "控制消息标识无效：0x\(String(value, radix: 16))"
        case let .invalidTotalLength(length):
            "控制消息长度无效：\(length)"
        case let .invalidPayloadLength(type, length):
            "参数 \(type) 的长度无效：\(length)"
        case let .trailingBytes(count):
            "消息末尾存在 \(count) 个未解析字节"
        }
    }
}

struct ByteCursor {
    private let data: Data
    private(set) var offset: Int = 0

    init(_ data: Data) {
        self.data = data
    }

    var remaining: Int { data.count - offset }

    mutating func readUInt8() throws -> UInt8 {
        guard remaining >= 1 else {
            throw ProtocolDecodeError.truncated(expected: 1, remaining: remaining)
        }
        defer { offset += 1 }
        return data[data.startIndex + offset]
    }

    mutating func readUInt16BE() throws -> UInt16 {
        guard remaining >= 2 else {
            throw ProtocolDecodeError.truncated(expected: 2, remaining: remaining)
        }
        let base = data.startIndex + offset
        offset += 2
        return UInt16(data[base]) << 8 | UInt16(data[base + 1])
    }

    mutating func readUInt32BE() throws -> UInt32 {
        guard remaining >= 4 else {
            throw ProtocolDecodeError.truncated(expected: 4, remaining: remaining)
        }
        let base = data.startIndex + offset
        offset += 4
        return UInt32(data[base]) << 24
            | UInt32(data[base + 1]) << 16
            | UInt32(data[base + 2]) << 8
            | UInt32(data[base + 3])
    }

    mutating func readData(count: Int) throws -> Data {
        guard count >= 0, remaining >= count else {
            throw ProtocolDecodeError.truncated(expected: count, remaining: remaining)
        }
        let start = data.startIndex + offset
        offset += count
        return data.subdata(in: start..<(start + count))
    }

    mutating func skip(_ count: Int) throws {
        _ = try readData(count: count)
    }
}

extension Data {
    mutating func appendUInt16BE(_ value: UInt16) {
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value))
    }

    mutating func appendUInt32BE(_ value: UInt32) {
        append(UInt8(truncatingIfNeeded: value >> 24))
        append(UInt8(truncatingIfNeeded: value >> 16))
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value))
    }
}

func alignedToFour(_ length: Int) -> Int {
    (length + 3) & ~3
}
