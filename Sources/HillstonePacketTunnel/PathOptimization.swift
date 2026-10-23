import Foundation
import HillstoneProtocol

enum DataChannelKind: String, Codable, Sendable {
    case udp
    case tcp

    var displayName: String {
        switch self {
        case .udp: "UDP"
        case .tcp: "TCP"
        }
    }
}

struct PathOptimizationMemory: Codable, Equatable, Sendable {
    var transport: DataChannelKind
    var mtu: Int?
    var probeSupported: Bool
    var updatedAt: Date

    func isFresh(at date: Date = Date(), maximumAge: TimeInterval = 24 * 60 * 60) -> Bool {
        date.timeIntervalSince(updatedAt) >= 0 && date.timeIntervalSince(updatedAt) <= maximumAge
    }
}

enum PathOptimizationPolicy {
    /// A data probe that worked on the previous physical network but fails
    /// immediately after a network change indicates that the new path cannot
    /// carry the selected data transport. Reject it before tunnel routes are
    /// installed so the Mac remains fail-open.
    static func shouldRejectRefreshedPath(
        refreshRequested: Bool,
        previousProbeWasSupported: Bool,
        currentProbeSucceeded: Bool
    ) -> Bool {
        refreshRequested && previousProbeWasSupported && !currentProbeSucceeded
    }
}

final class PathOptimizationStore: @unchecked Sendable {
    static let shared = PathOptimizationStore()

    private let defaults: UserDefaults
    private let lock = NSLock()
    private let keyPrefix = "path-optimization.v1."

    init(defaults: UserDefaults = UserDefaults(suiteName: "T84BKD53ZD.com.linlu.hillstoneconnect") ?? .standard) {
        self.defaults = defaults
    }

    func load(server: String, networkKind: UnderlyingNetworkKind) -> PathOptimizationMemory? {
        lock.lock(); defer { lock.unlock() }
        guard let data = defaults.data(forKey: key(server: server, networkKind: networkKind)),
              let memory = try? JSONDecoder().decode(PathOptimizationMemory.self, from: data),
              memory.isFresh() else { return nil }
        return memory
    }

    func save(
        server: String,
        networkKind: UnderlyingNetworkKind,
        transport: DataChannelKind,
        mtu: Int?,
        probeSupported: Bool,
        date: Date = Date()
    ) {
        let memory = PathOptimizationMemory(
            transport: transport,
            mtu: mtu,
            probeSupported: probeSupported,
            updatedAt: date
        )
        guard let data = try? JSONEncoder().encode(memory) else { return }
        lock.lock(); defer { lock.unlock() }
        defaults.set(data, forKey: key(server: server, networkKind: networkKind))
    }

    private func key(server: String, networkKind: UnderlyingNetworkKind) -> String {
        let normalized = server.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }
        return keyPrefix + normalized + "." + networkKind.rawValue
    }
}

struct ESPSequenceSnapshot: Equatable, Sendable {
    let receivedPackets: UInt64
    let estimatedLostPackets: UInt64
    let reorderedPackets: UInt64
    let duplicatePackets: UInt64

    var lossPercent: Double {
        let expected = receivedPackets + estimatedLostPackets
        guard expected > 0 else { return 0 }
        return Double(estimatedLostPackets) / Double(expected) * 100
    }

    var reorderPercent: Double {
        guard receivedPackets > 0 else { return 0 }
        return Double(reorderedPackets) / Double(receivedPackets) * 100
    }
}

struct ESPSequenceTracker: Sendable {
    private var highestSequence: UInt32?
    private var missingSequences = Set<UInt32>()
    private var lossBeyondWindow: UInt64 = 0
    private(set) var receivedPackets: UInt64 = 0
    private(set) var reorderedPackets: UInt64 = 0
    private(set) var duplicatePackets: UInt64 = 0
    private let maximumTrackedGap: UInt32 = 4_096

    mutating func record(sequence: UInt32) {
        receivedPackets += 1
        guard let highestSequence else {
            self.highestSequence = sequence
            return
        }

        if sequence > highestSequence {
            let gap = sequence - highestSequence - 1
            if gap > 0 {
                if gap <= maximumTrackedGap {
                    for missing in (highestSequence + 1)..<sequence {
                        missingSequences.insert(missing)
                    }
                } else {
                    lossBeyondWindow += UInt64(gap)
                    missingSequences.removeAll(keepingCapacity: true)
                }
            }
            self.highestSequence = sequence
        } else if missingSequences.remove(sequence) != nil {
            reorderedPackets += 1
        } else {
            duplicatePackets += 1
        }
    }

    var snapshot: ESPSequenceSnapshot {
        ESPSequenceSnapshot(
            receivedPackets: receivedPackets,
            estimatedLostPackets: lossBeyondWindow + UInt64(missingSequences.count),
            reorderedPackets: reorderedPackets,
            duplicatePackets: duplicatePackets
        )
    }
}

struct PathFeedback: Equatable, Sendable {
    let rttMilliseconds: Int?
    let jitterMilliseconds: Double
    let heartbeatLossPercent: Double
    let espLossPercent: Double
    let espReorderPercent: Double
}

enum DPLPMTUDPlan {
    static let baseMTU = 1_200

    static func candidates(
        recommendedMTU: Int,
        networkKind: UnderlyingNetworkKind
    ) -> [Int] {
        let ceiling: Int
        switch networkKind {
        case .wiredEthernet, .wiFi: ceiling = 1_420
        case .cellular, .other: ceiling = 1_380
        }
        let recommended = min(max(recommendedMTU, 1_280), ceiling)
        var values = [baseMTU, recommended]
        if recommended < ceiling {
            var value = ((recommended + 19) / 20) * 20
            if value == recommended { value += 20 }
            while value <= ceiling {
                values.append(value)
                value += 20
            }
        }
        return Array(Set(values)).sorted()
    }
}

enum IPv4ICMPEchoProbe {
    static func request(
        sourceAddress: String,
        destinationAddress: String,
        totalSize: Int,
        identifier: UInt16,
        sequence: UInt16
    ) -> Data? {
        guard totalSize >= 28, totalSize <= Int(UInt16.max),
              let source = ipv4Bytes(sourceAddress),
              let destination = ipv4Bytes(destinationAddress) else { return nil }

        var packet = Data(repeating: 0, count: totalSize)
        packet[0] = 0x45
        packet[1] = 0
        writeUInt16(UInt16(totalSize), to: &packet, at: 2)
        writeUInt16(identifier, to: &packet, at: 4)
        writeUInt16(0x4000, to: &packet, at: 6)
        packet[8] = 64
        packet[9] = 1
        packet.replaceSubrange(12..<16, with: source)
        packet.replaceSubrange(16..<20, with: destination)
        writeUInt16(checksum(packet.prefix(20)), to: &packet, at: 10)

        packet[20] = 8
        packet[21] = 0
        writeUInt16(identifier, to: &packet, at: 24)
        writeUInt16(sequence, to: &packet, at: 26)
        if totalSize > 28 {
            for index in 28..<totalSize {
                packet[index] = UInt8(truncatingIfNeeded: index &+ Int(sequence))
            }
        }
        writeUInt16(checksum(packet.dropFirst(20)), to: &packet, at: 22)
        return packet
    }

    static func matchesReply(_ packet: Data, identifier: UInt16, sequence: UInt16) -> Bool {
        guard packet.count >= 28,
              packet[0] >> 4 == 4 else { return false }
        let headerLength = Int(packet[0] & 0x0f) * 4
        guard headerLength >= 20, packet.count >= headerLength + 8,
              packet[9] == 1,
              packet[headerLength] == 0,
              packet[headerLength + 1] == 0 else { return false }
        return readUInt16(packet, at: headerLength + 4) == identifier
            && readUInt16(packet, at: headerLength + 6) == sequence
    }

    private static func ipv4Bytes(_ value: String) -> [UInt8]? {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var result: [UInt8] = []
        for part in parts {
            guard let byte = UInt8(part) else { return nil }
            result.append(byte)
        }
        return result
    }

    private static func checksum<S: DataProtocol>(_ bytes: S) -> UInt16 {
        let values = Array(bytes)
        var sum: UInt32 = 0
        var index = 0
        while index + 1 < values.count {
            sum += UInt32(values[index]) << 8 | UInt32(values[index + 1])
            index += 2
        }
        if index < values.count { sum += UInt32(values[index]) << 8 }
        while sum > 0xffff { sum = (sum & 0xffff) + (sum >> 16) }
        return ~UInt16(sum)
    }

    private static func writeUInt16(_ value: UInt16, to data: inout Data, at offset: Int) {
        data[offset] = UInt8(value >> 8)
        data[offset + 1] = UInt8(value & 0xff)
    }

    private static func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
        UInt16(data[offset]) << 8 | UInt16(data[offset + 1])
    }
}
