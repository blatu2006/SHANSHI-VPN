import Foundation
import Testing
@testable import HillstoneProtocol

@Test func oldConnectionProfileGetsSafeDefaultsForNewOptions() throws {
    let id = UUID()
    let json = """
    {
      "id": "\(id.uuidString)",
      "name": "旧连接",
      "server": "vpn.example.com",
      "port": 4433,
      "username": "",
      "authentication": "password",
      "dataTransport": "udp",
      "verifyServerCertificate": true,
      "mtu": 1380,
      "usesSPA": false
    }
    """
    let profile = try JSONDecoder().decode(ConnectionProfile.self, from: Data(json.utf8))

    #expect(profile.id == id)
    #expect(profile.automaticMTU)
    #expect(profile.routingMode == .serverPolicy)
    #expect(profile.automaticallyReconnects)
    #expect(profile.pinnedCertificateSHA256.isEmpty)
    #expect(profile.usesTunnelDNS)
    #expect(profile.chinaDirectRouting == false)
    #expect(profile.udpPacingEnabled == false)
    #expect(profile.includedIPv4CIDRs.isEmpty)
}
