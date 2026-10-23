import HillstoneProtocol
import NetworkExtension
import Testing
@testable import HillstonePacketTunnel

@Test func parsesBundledChinaDirectRouteCatalog() throws {
    let routes = try ChinaDirectRouteCatalog.load()
    #expect(routes.count > 4_000)
    #expect(routes.contains { $0.destinationAddress == "223.71.0.0" || $0.destinationAddress == "223.64.0.0" })
}

@Test func ignoresCatalogCommentsAndBlankLines() throws {
    let routes = try ChinaDirectRouteCatalog.parse("""
    # generated file

    1.2.4.0/24
    223.255.252.0/23
    """)
    #expect(routes.count == 2)
    #expect(routes[0].subnetMask == "255.255.255.0")
}

@Test func createsSystemSettingsForObservedPolicy() throws {
    let settings = NetworkSettingsFactory.make(
        configuration: .observedSessionFixture,
        remoteAddress: "223.71.10.170"
    )

    #expect(settings.tunnelRemoteAddress == "223.71.10.170")
    #expect(settings.mtu?.intValue == 1_380)

    let ipv4 = try #require(settings.ipv4Settings)
    #expect(ipv4.addresses == ["192.168.88.64"])
    #expect(ipv4.subnetMasks == ["255.255.255.0"])
    #expect(ipv4.includedRoutes?.map(\.destinationAddress) == ["0.0.0.0", "128.0.0.0"])
    #expect(ipv4.includedRoutes?.map(\.destinationSubnetMask) == ["128.0.0.0", "128.0.0.0"])
    #expect(ipv4.excludedRoutes?.map(\.destinationAddress) == ["223.71.10.170"])

    let dns = try #require(settings.dnsSettings)
    #expect(dns.servers == ["192.168.6.5"])
    #expect(dns.matchDomains == [""])
}

@Test func leavesSystemResolverUntouchedWhenTunnelDNSIsDisabled() throws {
    let configuration = try TunnelNetworkConfiguration(
        clientAddress: "192.168.88.64",
        clientPrefixLength: 24,
        dnsServers: [],
        includedRoutes: [try IPv4Route(destinationAddress: "10.0.0.0", prefixLength: 8)],
        mtu: 1_380
    )

    let settings = NetworkSettingsFactory.make(
        configuration: configuration,
        remoteAddress: "223.71.10.170"
    )
    #expect(settings.dnsSettings == nil)
}

@Test func installsExplicitInternalRouteInTunnelSettings() throws {
    let configuration = try TunnelNetworkConfiguration(
        clientAddress: "192.168.88.64",
        clientPrefixLength: 24,
        dnsServers: [],
        includedRoutes: [
            try IPv4Route.parseAddressOrCIDR("10.40.0.0/16"),
            try IPv4Route(destinationAddress: "0.0.0.0", prefixLength: 1)
        ],
        mtu: 1_380
    )

    let settings = NetworkSettingsFactory.make(
        configuration: configuration,
        remoteAddress: "223.71.10.170"
    )
    let routes = try #require(settings.ipv4Settings?.includedRoutes)
    #expect(routes.first?.destinationAddress == "10.40.0.0")
    #expect(routes.first?.destinationSubnetMask == "255.255.0.0")
}

@Test func disabledUDPPacingAddsNoDelay() {
    var controller = UDPPacingController(enabled: false)
    let offsets = controller.schedule(
        datagramSizes: [1_400, 1_400, 1_400],
        nowNanoseconds: 1_000_000,
        networkKind: .wiFi
    )

    #expect(offsets == [0, 0, 0])
}

@Test func udpPacingAllowsSmallBurstThenSpacesDatagrams() {
    var controller = UDPPacingController(enabled: true)
    let offsets = controller.schedule(
        datagramSizes: Array(repeating: 1_400, count: 20),
        nowNanoseconds: 1_000_000,
        networkKind: .wiFi
    )

    #expect(offsets.prefix(17).allSatisfy { $0 == 0 })
    #expect(Array(offsets.suffix(3)) == [24_000, 52_000, 80_000])
    #expect(controller.currentBitsPerSecond == 400_000_000)
}

@Test func udpPacingRampsUpForSustainedBulkTrafficAndResetsAfterIdle() {
    var controller = UDPPacingController(enabled: true)
    let now: UInt64 = 1_000_000
    _ = controller.schedule(
        datagramSizes: Array(repeating: 1_400, count: 100),
        nowNanoseconds: now,
        networkKind: .wiFi
    )
    #expect(controller.currentBitsPerSecond == 400_000_000)

    let next = controller.schedule(
        datagramSizes: Array(repeating: 1_400, count: 100),
        nowNanoseconds: now + 3_000_000,
        networkKind: .wiFi
    )
    #expect(controller.currentBitsPerSecond == 500_000_000)
    #expect(next.last! > 1_000_000)

    let afterIdle = controller.schedule(
        datagramSizes: [1_400],
        nowNanoseconds: now + 100_000_000,
        networkKind: .wiFi
    )
    #expect(controller.currentBitsPerSecond == 400_000_000)
    #expect(afterIdle == [0])
}

@Test func udpPacingUsesPathFeedbackToAdjustItsTargetRate() {
    var controller = UDPPacingController(enabled: true)
    _ = controller.schedule(
        datagramSizes: [1_400],
        nowNanoseconds: 1_000_000,
        networkKind: .wiFi
    )

    controller.applyFeedback(
        PathFeedback(
            rttMilliseconds: 20,
            jitterMilliseconds: 1,
            heartbeatLossPercent: 0,
            espLossPercent: 0,
            espReorderPercent: 0
        ),
        networkKind: .wiFi
    )
    #expect(controller.currentBitsPerSecond == 440_000_000)

    controller.applyFeedback(
        PathFeedback(
            rttMilliseconds: 40,
            jitterMilliseconds: 1,
            heartbeatLossPercent: 0,
            espLossPercent: 0,
            espReorderPercent: 0
        ),
        networkKind: .wiFi
    )
    #expect(controller.currentBitsPerSecond == 330_000_000)
}

@Test func dplpmtudCandidatesStayWithinNetworkCeilings() {
    #expect(DPLPMTUDPlan.candidates(recommendedMTU: 1_380, networkKind: .wiFi) == [
        1_200, 1_380, 1_400, 1_420
    ])
    #expect(DPLPMTUDPlan.candidates(recommendedMTU: 1_280, networkKind: .cellular) == [
        1_200, 1_280, 1_300, 1_320, 1_340, 1_360, 1_380
    ])
}

@Test func icmpPathProbeBuildsAndMatchesAnEchoExchange() throws {
    let identifier: UInt16 = 0x1234
    let sequence: UInt16 = 7
    var reply = try #require(IPv4ICMPEchoProbe.request(
        sourceAddress: "192.168.88.64",
        destinationAddress: "192.168.88.1",
        totalSize: 1_380,
        identifier: identifier,
        sequence: sequence
    ))
    #expect(reply.count == 1_380)
    #expect(reply[6] == 0x40)
    #expect(reply[7] == 0)

    reply[20] = 0
    reply[21] = 0
    #expect(IPv4ICMPEchoProbe.matchesReply(reply, identifier: identifier, sequence: sequence))
    #expect(!IPv4ICMPEchoProbe.matchesReply(reply, identifier: identifier, sequence: sequence + 1))
}

@Test func espSequenceTrackerSeparatesReorderingFromDuplicates() {
    var tracker = ESPSequenceTracker()
    for sequence: UInt32 in [10, 13, 12, 11, 12] {
        tracker.record(sequence: sequence)
    }

    let snapshot = tracker.snapshot
    #expect(snapshot.receivedPackets == 5)
    #expect(snapshot.estimatedLostPackets == 0)
    #expect(snapshot.reorderedPackets == 2)
    #expect(snapshot.duplicatePackets == 1)
    #expect(snapshot.reorderPercent == 40)
}

@Test func pathOptimizationMemoryExpiresAfterItsMaximumAge() {
    let fresh = PathOptimizationMemory(
        transport: .udp,
        mtu: 1_380,
        probeSupported: true,
        updatedAt: Date(timeIntervalSince1970: 1_000)
    )
    #expect(fresh.isFresh(at: Date(timeIntervalSince1970: 1_100), maximumAge: 200))
    #expect(!fresh.isFresh(at: Date(timeIntervalSince1970: 1_201), maximumAge: 200))
    #expect(!fresh.isFresh(at: Date(timeIntervalSince1970: 999), maximumAge: 200))
}

@Test func refreshedPhysicalPathRejectsARegressedDataProbe() {
    #expect(PathOptimizationPolicy.shouldRejectRefreshedPath(
        refreshRequested: true,
        previousProbeWasSupported: true,
        currentProbeSucceeded: false
    ))
    #expect(!PathOptimizationPolicy.shouldRejectRefreshedPath(
        refreshRequested: false,
        previousProbeWasSupported: true,
        currentProbeSucceeded: false
    ))
    #expect(!PathOptimizationPolicy.shouldRejectRefreshedPath(
        refreshRequested: true,
        previousProbeWasSupported: false,
        currentProbeSucceeded: false
    ))
}
