import Testing
@testable import HillstoneProtocol

@Test func convertsCIDRPrefixesToSubnetMasks() throws {
    #expect(try IPv4Route(destinationAddress: "0.0.0.0", prefixLength: 0).subnetMask == "0.0.0.0")
    #expect(try IPv4Route(destinationAddress: "0.0.0.0", prefixLength: 1).subnetMask == "128.0.0.0")
    #expect(try IPv4Route(destinationAddress: "10.0.0.0", prefixLength: 8).subnetMask == "255.0.0.0")
    #expect(try IPv4Route(destinationAddress: "192.168.88.0", prefixLength: 24).subnetMask == "255.255.255.0")
    #expect(try IPv4Route(destinationAddress: "1.2.3.4", prefixLength: 32).subnetMask == "255.255.255.255")
}

@Test func modelsObservedNetworkPolicy() {
    let configuration = TunnelNetworkConfiguration.observedSessionFixture
    #expect(configuration.clientAddress == "192.168.88.64")
    #expect(configuration.clientSubnetMask == "255.255.255.0")
    #expect(configuration.dnsServers == ["192.168.6.5"])
    #expect(configuration.includedRoutes.map(\.subnetMask) == ["128.0.0.0", "128.0.0.0"])
    #expect(configuration.mtu == 1_380)
}

@Test func rejectsInvalidNetworkPolicy() {
    #expect(throws: NetworkConfigurationError.invalidIPv4Address("999.1.2.3")) {
        try TunnelNetworkConfiguration(
            clientAddress: "999.1.2.3",
            clientPrefixLength: 24,
            dnsServers: [],
            includedRoutes: [try IPv4Route(destinationAddress: "0.0.0.0", prefixLength: 1)],
            mtu: 1_380
        )
    }
}

@Test func fullTunnelModeOverridesServerSplitRoutes() throws {
    var negotiated = HillstoneNegotiatedNetwork()
    negotiated.clientAddress = "192.168.88.64"
    negotiated.prefixLength = 24
    negotiated.gatewayAddress = "192.168.88.1"
    negotiated.dnsServers = ["192.168.6.5"]
    negotiated.routes = [try IPv4Route(destinationAddress: "10.0.0.0", prefixLength: 8)]
    negotiated.serverUDPPort = 4433
    let configuration = try negotiated.configuration(mtu: 1_380, forceFullTunnel: true)

    #expect(configuration.includedRoutes.map(\.destinationAddress) == ["0.0.0.0", "128.0.0.0"])
    #expect(configuration.includedRoutes.map(\.prefixLength) == [1, 1])
}

@Test func parsesInternalHostAndCIDRRoutes() throws {
    let host = try IPv4Route.parseAddressOrCIDR("10.20.30.40")
    #expect(host.cidrString == "10.20.30.40/32")

    let subnet = try IPv4Route.parseAddressOrCIDR("10.20.30.40/8")
    #expect(subnet.cidrString == "10.0.0.0/8")
    #expect(subnet.contains(host))
    #expect(!host.contains(subnet))
}

@Test func addsExplicitInternalRoutesAheadOfServerPolicy() throws {
    var negotiated = HillstoneNegotiatedNetwork()
    negotiated.clientAddress = "192.168.88.64"
    negotiated.prefixLength = 24
    negotiated.routes = [try IPv4Route(destinationAddress: "172.16.0.0", prefixLength: 12)]

    let internalRoute = try IPv4Route.parseAddressOrCIDR("10.40.0.0/16")
    let configuration = try negotiated.configuration(
        mtu: 1_380,
        additionalIncludedRoutes: [internalRoute]
    )

    #expect(configuration.includedRoutes.map(\.cidrString) == ["10.40.0.0/16", "172.16.0.0/12"])
}

@Test func internalRoutesOverrideNarrowerDirectExclusions() throws {
    let internalRoute = try IPv4Route.parseAddressOrCIDR("10.0.0.0/8")
    let exclusions = [
        try IPv4Route.parseAddressOrCIDR("0.0.0.0/1"),
        try IPv4Route.parseAddressOrCIDR("10.0.0.0/8"),
        try IPv4Route.parseAddressOrCIDR("10.40.0.0/16"),
        try IPv4Route.parseAddressOrCIDR("223.64.0.0/11")
    ]

    let filtered = IPv4Route.exclusions(exclusions, overriddenBy: [internalRoute])
    #expect(filtered.map(\.cidrString) == ["0.0.0.0/1", "223.64.0.0/11"])
}
