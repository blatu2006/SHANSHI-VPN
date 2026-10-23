import Foundation

public enum NetworkConfigurationError: Error, Equatable, LocalizedError, Sendable {
    case invalidIPv4Address(String)
    case invalidPrefixLength(Int)
    case invalidMTU(Int)
    case missingRoute

    public var errorDescription: String? {
        switch self {
        case let .invalidIPv4Address(address): "无效的 IPv4 地址：\(address)"
        case let .invalidPrefixLength(length): "无效的 IPv4 前缀长度：\(length)"
        case let .invalidMTU(mtu): "无效的 MTU：\(mtu)"
        case .missingRoute: "服务器没有下发任何路由"
        }
    }
}

public struct IPv4Route: Codable, Equatable, Sendable {
    public let destinationAddress: String
    public let prefixLength: Int

    public init(destinationAddress: String, prefixLength: Int) throws {
        guard Self.isValidAddress(destinationAddress) else {
            throw NetworkConfigurationError.invalidIPv4Address(destinationAddress)
        }
        guard (0...32).contains(prefixLength) else {
            throw NetworkConfigurationError.invalidPrefixLength(prefixLength)
        }
        self.destinationAddress = destinationAddress
        self.prefixLength = prefixLength
    }

    public var subnetMask: String {
        guard prefixLength > 0 else { return "0.0.0.0" }
        let value = UInt32.max << UInt32(32 - prefixLength)
        return [24, 16, 8, 0]
            .map { String((value >> UInt32($0)) & 0xff) }
            .joined(separator: ".")
    }

    public static func isValidAddress(_ value: String) -> Bool {
        let components = value.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 4 else { return false }
        return components.allSatisfy { component in
            guard !component.isEmpty,
                  component.allSatisfy(\.isNumber),
                  let number = UInt8(component) else { return false }
            return String(number) == component || component == "0"
        }
    }

    public static func parseCIDR(_ value: String) throws -> IPv4Route {
        let parts = value.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "/")
        guard parts.count == 2, let prefix = Int(parts[1]) else {
            throw NetworkConfigurationError.invalidIPv4Address(value)
        }
        return try IPv4Route(destinationAddress: String(parts[0]), prefixLength: prefix)
    }

    /// Parses either an IPv4 host address or a CIDR. A bare address represents
    /// one host so the UI can accept both `10.0.0.5` and `10.0.0.0/8`.
    public static func parseAddressOrCIDR(_ value: String) throws -> IPv4Route {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let route = if trimmed.contains("/") {
            try parseCIDR(trimmed)
        } else {
            try IPv4Route(destinationAddress: trimmed, prefixLength: 32)
        }
        return try IPv4Route(destinationAddress: route.networkAddress, prefixLength: route.prefixLength)
    }

    public var cidrString: String {
        "\(networkAddress)/\(prefixLength)"
    }

    public var networkAddress: String {
        guard let value = Self.addressValue(destinationAddress) else { return destinationAddress }
        let mask = prefixLength == 0 ? UInt32(0) : UInt32.max << UInt32(32 - prefixLength)
        let network = value & mask
        return [24, 16, 8, 0]
            .map { String((network >> UInt32($0)) & 0xff) }
            .joined(separator: ".")
    }

    /// Returns true when every address in `route` is contained by this route.
    public func contains(_ route: IPv4Route) -> Bool {
        guard prefixLength <= route.prefixLength,
              let lhs = Self.addressValue(destinationAddress),
              let rhs = Self.addressValue(route.destinationAddress) else { return false }
        let mask = prefixLength == 0 ? UInt32(0) : UInt32.max << UInt32(32 - prefixLength)
        return lhs & mask == rhs & mask
    }

    /// Removes exclusions that are equal to or narrower than an explicitly
    /// included route. Broader exclusions remain safe because route selection
    /// prefers the more-specific included prefix.
    public static func exclusions(
        _ exclusions: [IPv4Route],
        overriddenBy includedRoutes: [IPv4Route]
    ) -> [IPv4Route] {
        exclusions.filter { excluded in
            !includedRoutes.contains { included in included.contains(excluded) }
        }
    }

    private static func addressValue(_ address: String) -> UInt32? {
        let octets = address.split(separator: ".").compactMap { UInt32($0) }
        guard octets.count == 4 else { return nil }
        return octets.reduce(0) { ($0 << 8) | $1 }
    }
}

public enum UnderlyingNetworkKind: String, Codable, Equatable, Sendable {
    case wiredEthernet, wiFi, cellular, other

    public var title: String {
        switch self {
        case .wiredEthernet: "有线网络"
        case .wiFi: "Wi-Fi"
        case .cellular: "蜂窝网络"
        case .other: "其他网络"
        }
    }
}

public enum AdaptiveMTU {
    public static func recommended(for network: UnderlyingNetworkKind) -> Int {
        switch network {
        case .wiredEthernet: 1_420
        case .wiFi: 1_380
        case .cellular: 1_280
        case .other: 1_360
        }
    }
}

public struct TunnelNetworkConfiguration: Codable, Equatable, Sendable {
    public let clientAddress: String
    public let clientPrefixLength: Int
    public let dnsServers: [String]
    public let includedRoutes: [IPv4Route]
    public let excludedRoutes: [IPv4Route]
    public let blockIPv6Leaks: Bool
    public let mtu: Int

    public init(
        clientAddress: String,
        clientPrefixLength: Int,
        dnsServers: [String],
        includedRoutes: [IPv4Route],
        excludedRoutes: [IPv4Route] = [],
        blockIPv6Leaks: Bool = true,
        mtu: Int
    ) throws {
        guard IPv4Route.isValidAddress(clientAddress) else {
            throw NetworkConfigurationError.invalidIPv4Address(clientAddress)
        }
        guard (0...32).contains(clientPrefixLength) else {
            throw NetworkConfigurationError.invalidPrefixLength(clientPrefixLength)
        }
        if let invalidDNS = dnsServers.first(where: { !IPv4Route.isValidAddress($0) }) {
            throw NetworkConfigurationError.invalidIPv4Address(invalidDNS)
        }
        guard !includedRoutes.isEmpty else { throw NetworkConfigurationError.missingRoute }
        guard (576...9_000).contains(mtu) else { throw NetworkConfigurationError.invalidMTU(mtu) }

        self.clientAddress = clientAddress
        self.clientPrefixLength = clientPrefixLength
        self.dnsServers = dnsServers
        self.includedRoutes = includedRoutes
        self.excludedRoutes = excludedRoutes
        self.blockIPv6Leaks = blockIPv6Leaks
        self.mtu = mtu
    }

    public var clientSubnetMask: String {
        // Construction already validated the prefix.
        try! IPv4Route(destinationAddress: "0.0.0.0", prefixLength: clientPrefixLength).subnetMask
    }

    /// A fixture matching the connected session supplied during protocol
    /// analysis. Production code must replace it with SET_IP/SET_ROUTE values.
    public static var observedSessionFixture: TunnelNetworkConfiguration {
        try! TunnelNetworkConfiguration(
            clientAddress: "192.168.88.64",
            clientPrefixLength: 24,
            dnsServers: ["192.168.6.5"],
            includedRoutes: [
                try IPv4Route(destinationAddress: "0.0.0.0", prefixLength: 1),
                try IPv4Route(destinationAddress: "128.0.0.0", prefixLength: 1)
            ],
            mtu: 1_380
        )
    }
}
