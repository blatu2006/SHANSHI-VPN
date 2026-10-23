import Foundation

public struct ConnectionProfile: Identifiable, Codable, Equatable, Sendable {
    public enum RoutingMode: String, Codable, CaseIterable, Sendable {
        case serverPolicy
        case fullTunnel

        public var title: String {
            switch self {
            case .serverPolicy: "按服务器策略"
            case .fullTunnel: "全部流量"
            }
        }
    }

    public enum Authentication: String, Codable, CaseIterable, Sendable {
        case password
        case passwordAndCode
        case certificate

        public var title: String {
            switch self {
            case .password: "用户名和密码"
            case .passwordAndCode: "密码和验证码"
            case .certificate: "客户端证书"
            }
        }
    }

    public enum DataTransport: String, Codable, CaseIterable, Sendable {
        case automatic
        case udp
        case tcp

        public var title: String {
            switch self {
            case .automatic: "自动"
            case .udp: "UDP 优先"
            case .tcp: "TCP 稳定模式"
            }
        }
    }

    public var id: UUID
    public var name: String
    public var server: String
    public var port: UInt16
    public var username: String
    public var authentication: Authentication
    public var dataTransport: DataTransport
    public var verifyServerCertificate: Bool
    public var mtu: Int
    public var automaticMTU: Bool
    public var routingMode: RoutingMode
    public var automaticallyReconnects: Bool
    public var pinnedCertificateSHA256: String
    public var remembersPassword: Bool
    public var launchesAtLogin: Bool
    public var connectsOnWiFi: Bool
    public var connectsOnEthernet: Bool
    public var blockIPv6Leaks: Bool
    public var usesTunnelDNS: Bool
    public var chinaDirectRouting: Bool
    public var udpPacingEnabled: Bool
    public var includedIPv4CIDRs: [String]
    public var excludedIPv4CIDRs: [String]
    public var usesSPA: Bool
    public var connectionNotifications: Bool
    public var automaticallyChecksForUpdates: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        server: String,
        port: UInt16 = 4433,
        username: String = "",
        authentication: Authentication = .password,
        dataTransport: DataTransport = .automatic,
        verifyServerCertificate: Bool = false,
        mtu: Int = 1380,
        automaticMTU: Bool = true,
        routingMode: RoutingMode = .serverPolicy,
        automaticallyReconnects: Bool = true,
        pinnedCertificateSHA256: String = "",
        remembersPassword: Bool = true,
        launchesAtLogin: Bool = false,
        connectsOnWiFi: Bool = false,
        connectsOnEthernet: Bool = false,
        blockIPv6Leaks: Bool = true,
        usesTunnelDNS: Bool = true,
        chinaDirectRouting: Bool = false,
        udpPacingEnabled: Bool = false,
        includedIPv4CIDRs: [String] = [],
        excludedIPv4CIDRs: [String] = [],
        usesSPA: Bool = false,
        connectionNotifications: Bool = true,
        automaticallyChecksForUpdates: Bool = true
    ) {
        self.id = id
        self.name = name
        self.server = server
        self.port = port
        self.username = username
        self.authentication = authentication
        self.dataTransport = dataTransport
        self.verifyServerCertificate = verifyServerCertificate
        self.mtu = mtu
        self.automaticMTU = automaticMTU
        self.routingMode = routingMode
        self.automaticallyReconnects = automaticallyReconnects
        self.pinnedCertificateSHA256 = pinnedCertificateSHA256
        self.remembersPassword = remembersPassword
        self.launchesAtLogin = launchesAtLogin
        self.connectsOnWiFi = connectsOnWiFi
        self.connectsOnEthernet = connectsOnEthernet
        self.blockIPv6Leaks = blockIPv6Leaks
        self.usesTunnelDNS = usesTunnelDNS
        self.chinaDirectRouting = chinaDirectRouting
        self.udpPacingEnabled = udpPacingEnabled
        self.includedIPv4CIDRs = includedIPv4CIDRs
        self.excludedIPv4CIDRs = excludedIPv4CIDRs
        self.usesSPA = usesSPA
        self.connectionNotifications = connectionNotifications
        self.automaticallyChecksForUpdates = automaticallyChecksForUpdates
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, server, port, username, authentication, dataTransport
        case verifyServerCertificate, mtu, automaticMTU, routingMode
        case automaticallyReconnects, pinnedCertificateSHA256, remembersPassword
        case launchesAtLogin, connectsOnWiFi, connectsOnEthernet
        case blockIPv6Leaks, usesTunnelDNS, chinaDirectRouting, udpPacingEnabled
        case includedIPv4CIDRs, excludedIPv4CIDRs, usesSPA
        case connectionNotifications, automaticallyChecksForUpdates
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try values.decodeIfPresent(String.self, forKey: .name) ?? "公司网络"
        server = try values.decodeIfPresent(String.self, forKey: .server) ?? Self.preview.server
        port = try values.decodeIfPresent(UInt16.self, forKey: .port) ?? 4433
        username = try values.decodeIfPresent(String.self, forKey: .username) ?? ""
        authentication = try values.decodeIfPresent(Authentication.self, forKey: .authentication) ?? .password
        dataTransport = try values.decodeIfPresent(DataTransport.self, forKey: .dataTransport) ?? .udp
        verifyServerCertificate = try values.decodeIfPresent(Bool.self, forKey: .verifyServerCertificate) ?? false
        mtu = try values.decodeIfPresent(Int.self, forKey: .mtu) ?? 1_380
        automaticMTU = try values.decodeIfPresent(Bool.self, forKey: .automaticMTU) ?? true
        routingMode = try values.decodeIfPresent(RoutingMode.self, forKey: .routingMode) ?? .serverPolicy
        automaticallyReconnects = try values.decodeIfPresent(Bool.self, forKey: .automaticallyReconnects) ?? true
        pinnedCertificateSHA256 = try values.decodeIfPresent(String.self, forKey: .pinnedCertificateSHA256) ?? ""
        remembersPassword = try values.decodeIfPresent(Bool.self, forKey: .remembersPassword) ?? true
        launchesAtLogin = try values.decodeIfPresent(Bool.self, forKey: .launchesAtLogin) ?? false
        connectsOnWiFi = try values.decodeIfPresent(Bool.self, forKey: .connectsOnWiFi) ?? false
        connectsOnEthernet = try values.decodeIfPresent(Bool.self, forKey: .connectsOnEthernet) ?? false
        blockIPv6Leaks = try values.decodeIfPresent(Bool.self, forKey: .blockIPv6Leaks) ?? true
        usesTunnelDNS = try values.decodeIfPresent(Bool.self, forKey: .usesTunnelDNS) ?? true
        chinaDirectRouting = try values.decodeIfPresent(Bool.self, forKey: .chinaDirectRouting) ?? false
        udpPacingEnabled = try values.decodeIfPresent(Bool.self, forKey: .udpPacingEnabled) ?? false
        includedIPv4CIDRs = try values.decodeIfPresent([String].self, forKey: .includedIPv4CIDRs) ?? []
        excludedIPv4CIDRs = try values.decodeIfPresent([String].self, forKey: .excludedIPv4CIDRs) ?? []
        usesSPA = try values.decodeIfPresent(Bool.self, forKey: .usesSPA) ?? false
        connectionNotifications = try values.decodeIfPresent(Bool.self, forKey: .connectionNotifications) ?? true
        automaticallyChecksForUpdates = try values.decodeIfPresent(Bool.self, forKey: .automaticallyChecksForUpdates) ?? true
    }

    public static let preview = ConnectionProfile(
        name: "公司网络",
        server: "223.71.10.170",
        port: 4433,
        username: "",
        dataTransport: .udp,
        verifyServerCertificate: false,
        usesSPA: false
    )
}
