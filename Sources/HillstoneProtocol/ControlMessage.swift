import Foundation

public enum KnownMessageType: UInt16, CaseIterable, Sendable {
    case none = 0
    case auth = 1
    case clientInfo = 2
    case setIP = 3
    case setRoute = 4
    case newKey = 5
    case keyDone = 6
    case clientLogout = 7
    case serverDisconnect = 8
    case keepAlive = 9
    case rekey = 10
    case hostCheck = 11
    case hostCheckUpdate = 12

    public var displayName: String {
        switch self {
        case .none: "NONE"
        case .auth: "AUTH"
        case .clientInfo: "CLNT_INFO"
        case .setIP: "SET_IP"
        case .setRoute: "SET_ROUTE"
        case .newKey: "NEW_KEY"
        case .keyDone: "KEY_DONE"
        case .clientLogout: "CLNT_LOGOUT"
        case .serverDisconnect: "SERV_DISCONN"
        case .keepAlive: "KEEP_ALIVE"
        case .rekey: "REKEY"
        case .hostCheck: "HOST_CHECK"
        case .hostCheckUpdate: "HOST_CHECK_UPD"
        }
    }
}

/// Parameter identifiers used by Hillstone Secure Connect's control channel.
public enum HillstonePayload: UInt16, Sendable {
    case username = 1, password = 2, challengePassword = 3, status = 4
    case clientPublicIPv4 = 5, serverPublicIPv4 = 6
    case clientPrivateIPv4 = 7, serverPrivateIPv4 = 8, serverUDPPort = 9
    case ipSubnet = 10, netmaskIPv4 = 11, gatewayIPv4 = 12, routeMetrics = 13
    case ipsecSetting = 14, modpGroup = 15, keyMaterial = 16
    case dnsIPv4 = 17, winsIPv4 = 18, routeIPv4 = 19
    /// TCP data-channel port advertised in the CLNT_INFO response.
    /// Secure Connect 5.7 treats this field as optional and falls back to UDP
    /// when it is absent in automatic mode.
    case serverTCPPort = 22
    case keyExchangeMode = 32
    case spi = 48, encryptionAlgorithm = 49, authenticationAlgorithm = 50, sessionID = 51
    case englishErrorMessage = 53, chineseErrorMessage = 54
    case aliveStatus = 64
    case authenticationType = 81, cookie = 82, disconnect = 83, clientVersion = 84
    case hostID = 96, hostName = 97
    case hostCheckMD5 = 112, hostCheckResult = 115, hostCheckResultSize = 116
    case ipcompCPI = 128, ipcompAlgorithm = 129
    case allowPassword = 132, needsSMSAuthentication = 133, smsAuthenticationCode = 134
    case clientAutoConnect = 136
}

public struct ControlTLV: Equatable, Sendable {
    public let type: UInt16
    public let value: Data

    public init(type: UInt16, value: Data) {
        self.type = type
        self.value = value
    }

    public init(_ type: HillstonePayload, value: Data) {
        self.init(type: type.rawValue, value: value)
    }

    public init(_ type: HillstonePayload, string: String) {
        self.init(type, value: Data(string.utf8))
    }

    public init(_ type: HillstonePayload, integer: UInt64, byteCount: Int) {
        precondition((1...8).contains(byteCount))
        var bytes = Data(capacity: byteCount)
        for shift in stride(from: (byteCount - 1) * 8, through: 0, by: -8) {
            bytes.append(UInt8(truncatingIfNeeded: integer >> UInt64(shift)))
        }
        self.init(type, value: bytes)
    }

    public var payloadType: HillstonePayload? { HillstonePayload(rawValue: type) }

    public func unsignedInteger() -> UInt64? {
        guard !value.isEmpty, value.count <= 8 else { return nil }
        return value.reduce(0) { ($0 << 8) | UInt64($1) }
    }

    public var encodedLength: Int {
        4 + alignedToFour(value.count)
    }

    fileprivate func encode(into data: inout Data) {
        data.appendUInt16BE(type)
        data.appendUInt16BE(UInt16(value.count))
        data.append(value)
        let paddingCount = alignedToFour(value.count) - value.count
        if paddingCount > 0 {
            data.append(contentsOf: repeatElement(UInt8.zero, count: paddingCount))
        }
    }
}

public struct ControlMessage: Equatable, Sendable {
    public static let magic: UInt8 = 0x22
    public static let headerLength = 8

    public let flags: UInt8
    public let type: UInt16
    public let payloads: [ControlTLV]

    public init(flags: UInt8 = 0, type: UInt16, payloads: [ControlTLV] = []) {
        self.flags = flags
        self.type = type
        self.payloads = payloads
    }

    public var knownType: KnownMessageType? {
        KnownMessageType(rawValue: type)
    }

    public var displayName: String {
        knownType?.displayName ?? "TYPE_\(type)"
    }

    public func encoded() throws -> Data {
        let length = Self.headerLength + payloads.reduce(0) { $0 + $1.encodedLength }
        guard length <= Int(UInt32.max) else {
            throw ProtocolDecodeError.invalidTotalLength(length)
        }
        guard payloads.allSatisfy({ $0.value.count <= Int(UInt16.max) }) else {
            let invalid = payloads.first { $0.value.count > Int(UInt16.max) }!
            throw ProtocolDecodeError.invalidPayloadLength(type: invalid.type, length: invalid.value.count)
        }

        var data = Data(capacity: length)
        data.append(Self.magic)
        data.append(flags)
        data.appendUInt16BE(type)
        data.appendUInt32BE(UInt32(length))
        payloads.forEach { $0.encode(into: &data) }
        return data
    }

    public static func decode(_ data: Data, requireExactLength: Bool = true) throws -> ControlMessage {
        var cursor = ByteCursor(data)
        let magic = try cursor.readUInt8()
        guard magic == Self.magic else {
            throw ProtocolDecodeError.invalidMagic(magic)
        }

        let flags = try cursor.readUInt8()
        let type = try cursor.readUInt16BE()
        let totalLength = Int(try cursor.readUInt32BE())
        guard totalLength >= headerLength, totalLength <= data.count else {
            throw ProtocolDecodeError.invalidTotalLength(totalLength)
        }
        if requireExactLength, totalLength != data.count {
            throw ProtocolDecodeError.trailingBytes(data.count - totalLength)
        }

        let messageData = data.prefix(totalLength)
        cursor = ByteCursor(Data(messageData))
        try cursor.skip(headerLength)
        var payloads: [ControlTLV] = []

        while cursor.offset < totalLength {
            guard cursor.remaining >= 4 else {
                throw ProtocolDecodeError.truncated(expected: 4, remaining: cursor.remaining)
            }
            let parameterType = try cursor.readUInt16BE()
            let valueLength = Int(try cursor.readUInt16BE())
            guard cursor.remaining >= alignedToFour(valueLength) else {
                throw ProtocolDecodeError.invalidPayloadLength(type: parameterType, length: valueLength)
            }
            let value = try cursor.readData(count: valueLength)
            try cursor.skip(alignedToFour(valueLength) - valueLength)
            payloads.append(ControlTLV(type: parameterType, value: value))
        }

        return ControlMessage(flags: flags, type: type, payloads: payloads)
    }
}

/// Reassembles the control protocol carried by TCP/TLS. A single read may
/// contain half a message or several messages, so callers must not decode
/// socket reads as packet boundaries.
public struct ControlStreamDecoder: Sendable {
    public let maximumMessageLength: Int
    private var buffer = Data()

    public init(maximumMessageLength: Int = 1_048_576) {
        precondition(maximumMessageLength >= ControlMessage.headerLength)
        self.maximumMessageLength = maximumMessageLength
    }

    public var bufferedByteCount: Int { buffer.count }

    public mutating func append(_ bytes: Data) throws -> [ControlMessage] {
        buffer.append(bytes)
        var messages: [ControlMessage] = []

        while !buffer.isEmpty {
            // The official client and compatible implementations accept an
            // all-zero 8-byte idle frame between messages.
            if buffer.count >= ControlMessage.headerLength,
               buffer.prefix(ControlMessage.headerLength).allSatisfy({ $0 == 0 }) {
                buffer.removeFirst(ControlMessage.headerLength)
                continue
            }
            guard buffer[buffer.startIndex] == ControlMessage.magic else {
                throw ProtocolDecodeError.invalidMagic(buffer[buffer.startIndex])
            }
            guard buffer.count >= ControlMessage.headerLength else { break }

            let lengthOffset = buffer.startIndex + 4
            let totalLength = Int(
                UInt32(buffer[lengthOffset]) << 24
                    | UInt32(buffer[lengthOffset + 1]) << 16
                    | UInt32(buffer[lengthOffset + 2]) << 8
                    | UInt32(buffer[lengthOffset + 3])
            )
            guard totalLength >= ControlMessage.headerLength,
                  totalLength <= maximumMessageLength else {
                throw ProtocolDecodeError.invalidTotalLength(totalLength)
            }
            guard buffer.count >= totalLength else { break }

            let frame = Data(buffer.prefix(totalLength))
            messages.append(try ControlMessage.decode(frame))
            buffer.removeFirst(totalLength)
        }

        return messages
    }
}

public enum HillstoneNegotiationError: Error, Equatable, LocalizedError, Sendable {
    case unexpectedMessage(String)
    case missingPayload(HillstonePayload)
    case serverStatus(UInt32, String?)
    case unsupportedAlgorithms(encryption: UInt16, authentication: UInt16, compression: UInt16)
    case invalidIPv4Payload
    case hostCheckRequired(update: Bool)

    public var errorDescription: String? {
        switch self {
        case let .unexpectedMessage(message): "网关返回了意外消息：\(message)"
        case let .missingPayload(type): "网关响应缺少参数 \(type.rawValue)"
        case let .serverStatus(code, message): message ?? "网关拒绝请求（错误码 \(code)）"
        case let .unsupportedAlgorithms(enc, auth, compression):
            "网关下发了不支持的算法（加密 \(enc)，认证 \(auth)，压缩 \(compression)）"
        case .invalidIPv4Payload: "网关下发的 IPv4 配置格式无效"
        case let .hostCheckRequired(update):
            update
                ? "网关要求更新终端合规检查组件；当前版本不会伪造合规结果，请使用管理员认可的检查组件。"
                : "网关要求终端合规检查；当前版本不会伪造合规结果，请联系管理员确认检查策略。"
        }
    }
}

public struct HillstoneNegotiatedNetwork: Equatable, Sendable {
    public var clientAddress: String?
    public var prefixLength: Int?
    public var gatewayAddress: String?
    public var dnsServers: [String] = []
    public var routes: [IPv4Route] = []
    public var serverUDPPort: UInt16?
    public var serverTCPPort: UInt16?

    public init() {}

    public func configuration(
        mtu: Int,
        forceFullTunnel: Bool = false,
        additionalIncludedRoutes: [IPv4Route] = [],
        excludedRoutes: [IPv4Route] = [],
        blockIPv6Leaks: Bool = true
    ) throws -> TunnelNetworkConfiguration {
        guard let clientAddress, let prefixLength else {
            throw HillstoneNegotiationError.invalidIPv4Payload
        }
        let fullTunnelRoutes = [
            try IPv4Route(destinationAddress: "0.0.0.0", prefixLength: 1),
            try IPv4Route(destinationAddress: "128.0.0.0", prefixLength: 1)
        ]
        let policyRoutes = forceFullTunnel || routes.isEmpty ? fullTunnelRoutes : routes
        var seenRoutes = Set<String>()
        let effectiveRoutes = (additionalIncludedRoutes + policyRoutes).filter {
            seenRoutes.insert($0.cidrString).inserted
        }
        return try TunnelNetworkConfiguration(
            clientAddress: clientAddress,
            clientPrefixLength: prefixLength,
            dnsServers: dnsServers,
            includedRoutes: effectiveRoutes,
            excludedRoutes: excludedRoutes,
            blockIPv6Leaks: blockIPv6Leaks,
            mtu: mtu
        )
    }
}

public enum HillstoneProtocolMessages {
    public static func rejectUnsupportedServerRequirement(_ message: ControlMessage) throws {
        switch message.knownType {
        case .hostCheck:
            throw HillstoneNegotiationError.hostCheckRequired(update: false)
        case .hostCheckUpdate:
            throw HillstoneNegotiationError.hostCheckRequired(update: true)
        default:
            break
        }
    }

    public static func authentication(
        username: String,
        password: String,
        clientVersion: String = "5.7.0",
        hostID: String = "",
        hostName: String = Host.current().localizedName ?? "Mac"
    ) -> ControlMessage {
        ControlMessage(type: KnownMessageType.auth.rawValue, payloads: [
            ControlTLV(.authenticationType, integer: 1, byteCount: 2),
            ControlTLV(.username, string: username), ControlTLV(.password, string: password),
            ControlTLV(.clientVersion, string: clientVersion), ControlTLV(.hostID, string: hostID),
            ControlTLV(.hostName, string: hostName)
        ])
    }

    public static func clientInfo(serverIPv4: String, clientIPv4: String = "127.0.0.1") throws -> ControlMessage {
        ControlMessage(type: KnownMessageType.clientInfo.rawValue, payloads: [
            ControlTLV(.clientPublicIPv4, value: try ipv4Data(clientIPv4)),
            ControlTLV(.serverPublicIPv4, value: try ipv4Data(serverIPv4))
        ])
    }

    public static func newKey(keyMaterial: Data, inboundSPI: UInt32, inboundCPI: UInt16) throws -> ControlMessage {
        guard keyMaterial.count == 48 else { throw ESPError.invalidKeyMaterial }
        return ControlMessage(type: KnownMessageType.newKey.rawValue, payloads: [
            ControlTLV(.keyExchangeMode, integer: 3, byteCount: 2),
            ControlTLV(.keyMaterial, value: keyMaterial),
            ControlTLV(.spi, integer: UInt64(inboundSPI), byteCount: 4),
            ControlTLV(.ipcompCPI, integer: UInt64(inboundCPI), byteCount: 2)
        ])
    }

    public static func keepAlive(sessionID: Data, aliveStatus: UInt32 = 0) -> ControlMessage {
        ControlMessage(type: KnownMessageType.keepAlive.rawValue, payloads: [
            ControlTLV(.sessionID, value: sessionID),
            ControlTLV(.aliveStatus, integer: UInt64(aliveStatus), byteCount: 4)
        ])
    }
    public static let logout = ControlMessage(type: KnownMessageType.clientLogout.rawValue, payloads: [
        ControlTLV(.disconnect, integer: 0, byteCount: 2)
    ])

    public static func requireSuccess(_ message: ControlMessage) throws {
        guard let status = message.value(for: .status)?.uint32 else {
            throw HillstoneNegotiationError.missingPayload(.status)
        }
        guard status == 0 else {
            let text = message.stringValue(for: .chineseErrorMessage) ?? message.stringValue(for: .englishErrorMessage)
            throw HillstoneNegotiationError.serverStatus(status, text)
        }
    }

    public static func applyNetworkMessage(_ message: ControlMessage, to network: inout HillstoneNegotiatedNetwork) throws {
        if let status = message.value(for: .status)?.uint32, status != 0 { try requireSuccess(message) }
        switch message.knownType {
        case .clientInfo:
            if let value = message.value(for: .serverTCPPort) {
                guard let port = value.uint16, port > 0 else {
                    throw HillstoneNegotiationError.invalidIPv4Payload
                }
                network.serverTCPPort = port
            }
        case .setIP:
            guard let client = message.value(for: .clientPrivateIPv4)?.ipv4String,
                  let mask = message.value(for: .netmaskIPv4)?.ipv4String,
                  let prefix = prefixLength(fromMask: mask),
                  let port = message.value(for: .serverUDPPort)?.uint16 else {
                throw HillstoneNegotiationError.invalidIPv4Payload
            }
            network.clientAddress = client
            network.prefixLength = prefix
            network.gatewayAddress = message.value(for: .serverPrivateIPv4)?.ipv4String
            network.serverUDPPort = port
            if let dns = message.value(for: .dnsIPv4) {
                network.dnsServers = stride(from: 0, to: dns.count, by: 4).compactMap { offset in
                    guard offset + 4 <= dns.count else { return nil }
                    return Data(dns[offset..<(offset + 4)]).ipv4String
                }
            }
        case .setRoute:
            guard let raw = message.value(for: .routeIPv4) else { return }
            network.routes = stride(from: 0, to: raw.count, by: 8).compactMap { offset in
                guard offset + 8 <= raw.count,
                      let address = Data(raw[offset..<(offset + 4)]).ipv4String,
                      let mask = Data(raw[(offset + 4)..<(offset + 8)]).ipv4String,
                      let prefix = prefixLength(fromMask: mask) else { return nil }
                return try? IPv4Route(destinationAddress: address, prefixLength: prefix)
            }
        default: break
        }
    }

    public static func securityAssociation(response: ControlMessage, inboundSPI: UInt32, keyMaterial: Data) throws -> HillstoneSecurityAssociation {
        try requireSuccess(response)
        guard let outboundSPI = response.value(for: .spi)?.uint32 else {
            throw HillstoneNegotiationError.unexpectedMessage(response.displayName)
        }
        let encryption = response.value(for: .encryptionAlgorithm)?.uint16 ?? 0
        let authentication = response.value(for: .authenticationAlgorithm)?.uint16 ?? 0
        let compression = response.value(for: .ipcompAlgorithm)?.uint16 ?? 0
        guard encryption == 3, authentication == 2, compression == 0 else {
            throw HillstoneNegotiationError.unsupportedAlgorithms(encryption: encryption, authentication: authentication, compression: compression)
        }
        return try HillstoneSecurityAssociation(inboundSPI: inboundSPI, outboundSPI: outboundSPI, keyMaterial: keyMaterial)
    }

    private static func ipv4Data(_ value: String) throws -> Data {
        guard let data = value.ipv4Data else { throw HillstoneNegotiationError.invalidIPv4Payload }
        return data
    }

    private static func prefixLength(fromMask value: String) -> Int? {
        guard let bytes = value.ipv4Data else { return nil }
        let number = bytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        var seenZero = false, count = 0
        for bit in (0..<32).reversed() {
            if number & (UInt32(1) << UInt32(bit)) != 0 {
                guard !seenZero else { return nil }; count += 1
            } else { seenZero = true }
        }
        return count
    }
}

public extension ControlMessage {
    func value(for type: HillstonePayload) -> Data? { payloads.first { $0.type == type.rawValue }?.value }
    func stringValue(for type: HillstonePayload) -> String? { value(for: type).flatMap { String(data: $0, encoding: .utf8) } }
}

private extension Data {
    var uint16: UInt16? {
        guard count == 2 else { return nil }
        return UInt16(self[startIndex]) << 8 | UInt16(self[startIndex + 1])
    }
    var uint32: UInt32? {
        guard count == 4 else { return nil }
        return UInt32(self[startIndex]) << 24 | UInt32(self[startIndex + 1]) << 16
            | UInt32(self[startIndex + 2]) << 8 | UInt32(self[startIndex + 3])
    }
    var ipv4String: String? {
        guard count == 4 else { return nil }
        return map(String.init).joined(separator: ".")
    }
}

private extension String {
    var ipv4Data: Data? {
        let parts = split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        let bytes = parts.compactMap { UInt8($0) }
        return bytes.count == 4 ? Data(bytes) : nil
    }
}
