import Foundation
import HillstoneProtocol
import NetworkExtension

public enum NetworkSettingsFactory {
    public static func make(
        configuration: TunnelNetworkConfiguration,
        remoteAddress: String
    ) -> NEPacketTunnelNetworkSettings {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: remoteAddress)
        settings.mtu = NSNumber(value: configuration.mtu)

        let ipv4 = NEIPv4Settings(
            addresses: [configuration.clientAddress],
            subnetMasks: [configuration.clientSubnetMask]
        )
        ipv4.includedRoutes = configuration.includedRoutes.map {
            NEIPv4Route(destinationAddress: $0.destinationAddress, subnetMask: $0.subnetMask)
        }

        var excludedRoutes = configuration.excludedRoutes.map {
            NEIPv4Route(destinationAddress: $0.destinationAddress, subnetMask: $0.subnetMask)
        }
        // The gateway itself must stay on the physical interface, otherwise a
        // full-tunnel route recursively sends tunnel traffic back into utun.
        if IPv4Route.isValidAddress(remoteAddress) {
            excludedRoutes.append(
                NEIPv4Route(destinationAddress: remoteAddress, subnetMask: "255.255.255.255")
            )
        }
        ipv4.excludedRoutes = excludedRoutes
        settings.ipv4Settings = ipv4

        if configuration.blockIPv6Leaks {
            // The observed appliance does not assign an IPv6 address. Routing
            // IPv6 into the packet tunnel prevents it from bypassing the VPN;
            // unsupported IPv6 packets are safely dropped by the gateway.
            let ipv6 = NEIPv6Settings(addresses: ["fd00::1"], networkPrefixLengths: [128])
            ipv6.includedRoutes = [NEIPv6Route.default()]
            settings.ipv6Settings = ipv6
        }

        if !configuration.dnsServers.isEmpty {
            let dns = NEDNSSettings(servers: configuration.dnsServers)
            dns.matchDomains = [""]
            settings.dnsSettings = dns
        }

        return settings
    }
}
