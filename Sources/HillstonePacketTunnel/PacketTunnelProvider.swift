import CryptoKit
import Foundation
import Network
import NetworkExtension
import OSLog
import Security
import HillstoneProtocol

private let tunnelDebugLog = Logger(
    subsystem: "com.linlu.hillstoneconnect.PacketTunnel",
    category: "connection"
)

private enum TunnelError: Error, LocalizedError {
    case invalidConfiguration, missingCredentials, connectionClosed, serverDisconnected
    case connectionTimedOut, responseTimedOut
    case certificatePinMismatch
    case dataChannelUnavailable
    case tcpDataPortUnavailable
    case chinaRouteCatalogUnavailable(String)
    case networkChanged(UnderlyingNetworkKind)
    case networkSettingsFailed(String)
    var errorDescription: String? {
        switch self {
        case .invalidConfiguration: "VPN 配置不完整"
        case .missingCredentials: "用户名或密码为空"
        case .connectionClosed: "与 VPN 网关的连接已关闭"
        case .serverDisconnected: "VPN 网关主动断开了连接"
        case .connectionTimedOut: "连接 VPN 网关超时"
        case .responseTimedOut: "等待 VPN 网关响应超时"
        case .certificatePinMismatch: "VPN 网关证书与首次连接时保存的指纹不一致"
        case .dataChannelUnavailable: "TLS 登录成功，但数据通道不可达"
        case .tcpDataPortUnavailable: "网关未下发 TCP 数据端口，无法使用 TCP 稳定模式"
        case let .chinaRouteCatalogUnavailable(message): "无法加载国内直连地址库：\(message)"
        case let .networkChanged(kind): "底层网络已切换为\(kind.title)，正在重新连接"
        case let .networkSettingsFailed(message): "无法应用 VPN 路由或 DNS：\(message)"
        }
    }
}

private struct RuntimeConfiguration {
    let server: String, username: String, password: String
    let port: UInt16
    let verifyCertificate: Bool, forceFullTunnel: Bool, automaticMTU: Bool, blockIPv6Leaks: Bool
    let usesTunnelDNS: Bool, chinaDirectRouting: Bool, udpPacingEnabled: Bool
    let refreshPathOptimization: Bool
    let dataTransport: ConnectionProfile.DataTransport
    let certificatePin: String
    let includedIPv4CIDRs: [String], excludedIPv4CIDRs: [String]
    let mtu: Int

    init(provider: NEPacketTunnelProvider, options: [String: NSObject]?) throws {
        guard let proto = provider.protocolConfiguration as? NETunnelProviderProtocol,
              let stored = proto.providerConfiguration,
              let server = stored["server"] as? String,
              let portNumber = stored["port"] as? NSNumber,
              let username = options?["username"] as? NSString,
              let password = options?["password"] as? NSString,
              !server.isEmpty, username.length > 0, password.length > 0 else {
            throw TunnelError.missingCredentials
        }
        self.server = server; port = portNumber.uint16Value
        self.username = username as String; self.password = password as String
        verifyCertificate = (stored["verifyCertificate"] as? NSNumber)?.boolValue ?? false
        forceFullTunnel = (stored["forceFullTunnel"] as? NSNumber)?.boolValue ?? false
        automaticMTU = (stored["automaticMTU"] as? NSNumber)?.boolValue ?? true
        blockIPv6Leaks = (stored["blockIPv6Leaks"] as? NSNumber)?.boolValue ?? true
        usesTunnelDNS = (stored["usesTunnelDNS"] as? NSNumber)?.boolValue ?? true
        chinaDirectRouting = (stored["chinaDirectRouting"] as? NSNumber)?.boolValue ?? false
        udpPacingEnabled = (stored["udpPacingEnabled"] as? NSNumber)?.boolValue ?? false
        refreshPathOptimization = (options?["refreshPathOptimization"] as? NSNumber)?.boolValue ?? false
        dataTransport = (stored["dataTransport"] as? String)
            .flatMap(ConnectionProfile.DataTransport.init(rawValue:)) ?? .automatic
        includedIPv4CIDRs = stored["includedIPv4CIDRs"] as? [String] ?? []
        excludedIPv4CIDRs = stored["excludedIPv4CIDRs"] as? [String] ?? []
        certificatePin = (stored["certificatePin"] as? String ?? "")
            .lowercased().filter(\.isHexDigit)
        mtu = (stored["mtu"] as? NSNumber)?.intValue ?? 1_380
        guard port > 0, (576...9_000).contains(mtu) else { throw TunnelError.invalidConfiguration }
    }
}

private protocol TunnelDataChannel: AnyObject, Sendable {
    var kind: DataChannelKind { get }
    var networkKind: UnderlyingNetworkKind { get }
    var transportName: String { get }
    var udpPacingRateMbps: Int? { get }
    var udpPacingQueueDelayMilliseconds: Double? { get }
    func start() async throws
    func sendBatch(_ datagrams: [Data]) async throws
    func receiveBatch(timeout: TimeInterval?) async throws -> [Data]
    func updatePathFeedback(_ feedback: PathFeedback)
    func cancel()
}

private struct OpenedDataChannel {
    let channel: any TunnelDataChannel
    let discoveredMTU: Int?
    let probeRTTMilliseconds: Int?
    let probeStatus: String
}

private struct DataPathProbeResult {
    let supported: Bool
    let bestMTU: Int?
    let rttMilliseconds: Int?
    let requiresFreshChannel: Bool
}

private final class ContinuationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    init(_ continuation: CheckedContinuation<Void, Error>) { self.continuation = continuation }
    @discardableResult func succeed() -> Bool { finish(nil) }
    @discardableResult func fail(_ error: Error) -> Bool { finish(error) }
    private func finish(_ error: Error?) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let continuation else { return false }
        self.continuation = nil
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
        return true
    }
}

private final class ValueContinuationGate<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    init(_ continuation: CheckedContinuation<Value, Error>) { self.continuation = continuation }
    @discardableResult func succeed(_ value: sending Value) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let continuation else { return false }
        self.continuation = nil
        continuation.resume(returning: value)
        return true
    }
    @discardableResult func fail(_ error: Error) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let continuation else { return false }
        self.continuation = nil
        continuation.resume(throwing: error)
        return true
    }
}

private final class TunnelCompletion: @unchecked Sendable {
    let callback: (Error?) -> Void
    init(_ callback: @escaping (Error?) -> Void) { self.callback = callback }
}

private final class TunnelStopCompletion: @unchecked Sendable {
    let callback: () -> Void
    init(_ callback: @escaping () -> Void) { self.callback = callback }
}

private final class ControlChannel: @unchecked Sendable {
    private var connection: NWConnection!
    private let queue = DispatchQueue(label: "com.linlu.hillstone.control")
    private var decoder = ControlStreamDecoder()
    private var pending: [ControlMessage] = []
    private let metadataLock = NSLock()
    private var observedCertificateFingerprint = ""
    private var observedPinMismatch = false

    var certificateFingerprint: String {
        metadataLock.lock(); defer { metadataLock.unlock() }
        return observedCertificateFingerprint
    }

    init(server: String, port: UInt16, verifyCertificate: Bool, certificatePin: String) {
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        let normalizedPin = certificatePin.lowercased().filter(\.isHexDigit)
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { [weak self] _, protocolTrust, complete in
            let trust = sec_trust_copy_ref(protocolTrust).takeRetainedValue()
            guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
                  let certificate = chain.first else {
                complete(false); return
            }
            let data = SecCertificateCopyData(certificate) as Data
            let fingerprint = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            self?.metadataLock.lock()
            self?.observedCertificateFingerprint = fingerprint
            self?.observedPinMismatch = !normalizedPin.isEmpty && normalizedPin != fingerprint
            self?.metadataLock.unlock()
            if verifyCertificate {
                complete(SecTrustEvaluateWithError(trust, nil))
            } else {
                complete(normalizedPin.isEmpty || normalizedPin == fingerprint)
            }
        }, queue)
        connection = NWConnection(
            host: NWEndpoint.Host(server), port: NWEndpoint.Port(rawValue: port)!,
            using: NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        )
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let gate = ContinuationGate(continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: gate.succeed()
                case let .failed(error): gate.fail(self.pinAware(error))
                case let .waiting(error): gate.fail(self.pinAware(error))
                case .cancelled: gate.fail(TunnelError.connectionClosed)
                default: break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 15) { [connection] in
                if gate.fail(TunnelError.connectionTimedOut) { connection?.cancel() }
            }
        }
    }

    private func pinAware(_ error: Error) -> Error {
        metadataLock.lock(); defer { metadataLock.unlock() }
        return observedPinMismatch ? TunnelError.certificatePinMismatch : error
    }

    func send(_ message: ControlMessage) async throws {
        let data = try message.encoded()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }

    func nextMessage(timeout: TimeInterval? = 15) async throws -> ControlMessage {
        if !pending.isEmpty { return pending.removeFirst() }
        while true {
            let data: Data = try await withCheckedThrowingContinuation { continuation in
                let gate = ValueContinuationGate<Data>(continuation)
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, _, error in
                    if let error { gate.fail(error) }
                    else if let data, !data.isEmpty { gate.succeed(data) }
                    else { gate.fail(TunnelError.connectionClosed) }
                }
                if let timeout {
                    queue.asyncAfter(deadline: .now() + timeout) { [connection] in
                        if gate.fail(TunnelError.responseTimedOut) { connection?.cancel() }
                    }
                }
            }
            let decoded = try decoder.append(data)
            if let first = decoded.first {
                pending.append(contentsOf: decoded.dropFirst()); return first
            }
        }
    }

    func cancel() { connection.cancel() }
}

struct UDPPacingController: Sendable {
    let enabled: Bool
    private(set) var scheduledThroughNanoseconds: UInt64 = 0
    private(set) var currentBitsPerSecond: UInt64 = 0
    private var currentNetworkKind: UnderlyingNetworkKind?
    private var lastScheduleNanoseconds: UInt64?
    private var previousBatchWasBulk = false
    private var feedbackCeilingBitsPerSecond: UInt64 = .max
    private var minimumObservedRTTMilliseconds: Int?
    private let burstBytes: Int = 24_000

    init(enabled: Bool) {
        self.enabled = enabled
    }

    static func initialBitsPerSecond(for networkKind: UnderlyingNetworkKind) -> UInt64 {
        switch networkKind {
        case .wiredEthernet: 800_000_000
        case .wiFi: 400_000_000
        case .cellular: 80_000_000
        case .other: 200_000_000
        }
    }

    static func maximumBitsPerSecond(for networkKind: UnderlyingNetworkKind) -> UInt64 {
        switch networkKind {
        case .wiredEthernet: 2_500_000_000
        case .wiFi: 1_200_000_000
        case .cellular: 300_000_000
        case .other: 600_000_000
        }
    }

    mutating func schedule(
        datagramSizes: [Int],
        nowNanoseconds: UInt64,
        networkKind: UnderlyingNetworkKind
    ) -> [UInt64] {
        guard enabled else { return Array(repeating: 0, count: datagramSizes.count) }
        if currentNetworkKind != networkKind || currentBitsPerSecond == 0 {
            currentNetworkKind = networkKind
            currentBitsPerSecond = Self.initialBitsPerSecond(for: networkKind)
            feedbackCeilingBitsPerSecond = Self.maximumBitsPerSecond(for: networkKind)
            minimumObservedRTTMilliseconds = nil
            scheduledThroughNanoseconds = nowNanoseconds
            lastScheduleNanoseconds = nil
            previousBatchWasBulk = false
        } else if let lastScheduleNanoseconds,
                  nowNanoseconds > lastScheduleNanoseconds + 50_000_000 {
            // Restart conservatively after an idle period so a fresh burst is
            // still smoothed on a potentially changed path.
            currentBitsPerSecond = Self.initialBitsPerSecond(for: networkKind)
            previousBatchWasBulk = false
        }

        let batchBytes = datagramSizes.reduce(0) { $0 + max($1, 1) }
        let isBulkBatch = batchBytes >= burstBytes
        if isBulkBatch, previousBatchWasBulk {
            // Consecutive large batches identify a sustained transfer. Ramp
            // up rather than turning the starting rate into a hard ceiling.
            let increased = currentBitsPerSecond + max(currentBitsPerSecond / 4, 1)
            currentBitsPerSecond = min(
                increased,
                min(Self.maximumBitsPerSecond(for: networkKind), feedbackCeilingBitsPerSecond)
            )
        }
        previousBatchWasBulk = isBulkBatch
        lastScheduleNanoseconds = nowNanoseconds
        let rate = currentBitsPerSecond
        var deadline = max(nowNanoseconds, scheduledThroughNanoseconds)
        var remainingBurst = deadline <= nowNanoseconds ? burstBytes : 0
        var offsets: [UInt64] = []
        offsets.reserveCapacity(datagramSizes.count)

        for rawSize in datagramSizes {
            let size = max(rawSize, 1)
            if remainingBurst >= size {
                remainingBurst -= size
            } else {
                let pacedBytes = size - remainingBurst
                remainingBurst = 0
                let spacing = UInt64(
                    ceil(Double(pacedBytes) * 8_000_000_000 / Double(rate))
                )
                deadline &+= max(spacing, 1)
            }
            offsets.append(deadline > nowNanoseconds ? deadline - nowNanoseconds : 0)
        }
        scheduledThroughNanoseconds = deadline
        return offsets
    }

    mutating func applyFeedback(_ feedback: PathFeedback, networkKind: UnderlyingNetworkKind) {
        guard enabled else { return }
        if currentNetworkKind != networkKind || currentBitsPerSecond == 0 {
            currentNetworkKind = networkKind
            currentBitsPerSecond = Self.initialBitsPerSecond(for: networkKind)
            feedbackCeilingBitsPerSecond = Self.maximumBitsPerSecond(for: networkKind)
        }
        if let rtt = feedback.rttMilliseconds, rtt > 0 {
            minimumObservedRTTMilliseconds = min(minimumObservedRTTMilliseconds ?? rtt, rtt)
        }
        let baseline = minimumObservedRTTMilliseconds ?? feedback.rttMilliseconds ?? 0
        let queueInflation = baseline > 0
            ? Double(feedback.rttMilliseconds ?? baseline) / Double(baseline)
            : 1
        let congested = feedback.heartbeatLossPercent >= 10
            || feedback.espLossPercent >= 2
            || queueInflation >= 1.5
            || feedback.jitterMilliseconds >= 40

        let initial = Self.initialBitsPerSecond(for: networkKind)
        let minimum = max(initial / 8, 10_000_000)
        if congested {
            let reduced = max(minimum, currentBitsPerSecond * 3 / 4)
            currentBitsPerSecond = reduced
            feedbackCeilingBitsPerSecond = max(minimum, reduced)
            scheduledThroughNanoseconds = min(scheduledThroughNanoseconds, DispatchTime.now().uptimeNanoseconds + 50_000_000)
        } else {
            let maximum = Self.maximumBitsPerSecond(for: networkKind)
            let raisedCeiling = feedbackCeilingBitsPerSecond + max(feedbackCeilingBitsPerSecond / 10, 1)
            feedbackCeilingBitsPerSecond = min(maximum, raisedCeiling)
            let increased = currentBitsPerSecond + max(currentBitsPerSecond / 10, 1)
            currentBitsPerSecond = min(increased, feedbackCeilingBitsPerSecond)
        }
    }

    func queueDelayMilliseconds(nowNanoseconds: UInt64) -> Double {
        guard enabled, scheduledThroughNanoseconds > nowNanoseconds else { return 0 }
        return Double(scheduledThroughNanoseconds - nowNanoseconds) / 1_000_000
    }
}

private final class UDPDataChannel: TunnelDataChannel, @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "com.linlu.hillstone.data")
    private let pathLock = NSLock()
    private let pacingLock = NSLock()
    private var lastNetworkKind: UnderlyingNetworkKind?
    private var pacingController: UDPPacingController
    private let pathChangeHandler: @Sendable (UnderlyingNetworkKind) -> Void

    init(
        server: String,
        port: UInt16,
        pacingEnabled: Bool,
        disableFragmentation: Bool = false,
        pathChangeHandler: @escaping @Sendable (UnderlyingNetworkKind) -> Void
    ) {
        self.pathChangeHandler = pathChangeHandler
        pacingController = UDPPacingController(enabled: pacingEnabled)
        let parameters = NWParameters.udp
        if disableFragmentation {
            (parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options)?
                .disableFragmentation = true
        }
        connection = NWConnection(
            host: NWEndpoint.Host(server),
            port: NWEndpoint.Port(rawValue: port)!,
            using: parameters
        )
        connection.pathUpdateHandler = { [weak self] path in self?.consume(path: path) }
    }

    let kind = DataChannelKind.udp
    var networkKind: UnderlyingNetworkKind {
        guard let path = connection.currentPath else { return .other }
        return Self.kind(for: path)
    }

    var transportName: String { pacingController.enabled ? "UDP ESP · Pacing" : "UDP ESP" }
    var udpPacingRateMbps: Int? {
        guard pacingController.enabled else { return nil }
        pacingLock.lock(); defer { pacingLock.unlock() }
        let rate = pacingController.currentBitsPerSecond > 0
            ? pacingController.currentBitsPerSecond
            : UDPPacingController.initialBitsPerSecond(for: networkKind)
        return Int(rate / 1_000_000)
    }
    var udpPacingQueueDelayMilliseconds: Double? {
        guard pacingController.enabled else { return nil }
        pacingLock.lock(); defer { pacingLock.unlock() }
        return pacingController.queueDelayMilliseconds(nowNanoseconds: DispatchTime.now().uptimeNanoseconds)
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { continuation in
            let gate = ContinuationGate(continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: gate.succeed()
                case let .failed(error): gate.fail(error)
                case let .waiting(error): gate.fail(error)
                case .cancelled: gate.fail(TunnelError.connectionClosed)
                default: break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 10) { [connection] in
                if gate.fail(TunnelError.connectionTimedOut) { connection.cancel() }
            }
        }
    }
    func send(_ datagram: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: datagram, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }
    func sendBatch(_ datagrams: [Data]) async throws {
        guard !datagrams.isEmpty else { return }
        try await withCheckedThrowingContinuation { continuation in
            let gate = BatchSendGate(count: datagrams.count, continuation: continuation)
            queue.async { [self] in
                pacingLock.lock()
                let offsets = pacingController.schedule(
                    datagramSizes: datagrams.map(\.count),
                    nowNanoseconds: DispatchTime.now().uptimeNanoseconds,
                    networkKind: networkKind
                )
                pacingLock.unlock()
                for (datagram, offset) in zip(datagrams, offsets) {
                    let send: @Sendable () -> Void = { [connection] in
                        connection.send(content: datagram, completion: .contentProcessed { error in
                            gate.complete(error)
                        })
                    }
                    if offset == 0 {
                        send()
                    } else {
                        queue.asyncAfter(
                            deadline: .now() + .nanoseconds(Int(min(offset, UInt64(Int.max)))),
                            execute: send
                        )
                    }
                }
            }
        }
    }
    func receiveBatch(timeout: TimeInterval? = nil) async throws -> [Data] {
        try await withCheckedThrowingContinuation { continuation in
            let gate = ValueContinuationGate<[Data]>(continuation)
            connection.receiveMessage { data, _, _, error in
                if let error { gate.fail(error) }
                else if let data, !data.isEmpty { gate.succeed([data]) }
                else { gate.fail(TunnelError.connectionClosed) }
            }
            if let timeout {
                queue.asyncAfter(deadline: .now() + timeout) {
                    gate.fail(TunnelError.responseTimedOut)
                }
            }
        }
    }
    func updatePathFeedback(_ feedback: PathFeedback) {
        pacingLock.lock()
        pacingController.applyFeedback(feedback, networkKind: networkKind)
        pacingLock.unlock()
    }
    func cancel() { connection.cancel() }

    private func consume(path: NWPath) {
        let kind = Self.kind(for: path)
        pathLock.lock()
        let previous = lastNetworkKind
        lastNetworkKind = kind
        pathLock.unlock()
        if let previous, previous != kind { pathChangeHandler(kind) }
    }

    private static func kind(for path: NWPath) -> UnderlyingNetworkKind {
        if path.usesInterfaceType(.wiredEthernet) { return .wiredEthernet }
        if path.usesInterfaceType(.wifi) { return .wiFi }
        if path.usesInterfaceType(.cellular) { return .cellular }
        return .other
    }
}

private final class TCPDataChannel: TunnelDataChannel, @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "com.linlu.hillstone.data.tcp")
    private let pathLock = NSLock()
    private var lastNetworkKind: UnderlyingNetworkKind?
    private var decoder = HillstoneTCPFrameCodec()
    private let pathChangeHandler: @Sendable (UnderlyingNetworkKind) -> Void

    init(
        server: String,
        port: UInt16,
        pathChangeHandler: @escaping @Sendable (UnderlyingNetworkKind) -> Void
    ) {
        self.pathChangeHandler = pathChangeHandler
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        connection = NWConnection(
            host: NWEndpoint.Host(server),
            port: NWEndpoint.Port(rawValue: port)!,
            using: NWParameters(tls: nil, tcp: tcp)
        )
        connection.pathUpdateHandler = { [weak self] path in self?.consume(path: path) }
    }

    let kind = DataChannelKind.tcp
    var networkKind: UnderlyingNetworkKind {
        guard let path = connection.currentPath else { return .other }
        return Self.kind(for: path)
    }

    let transportName = "TCP ESP"
    let udpPacingRateMbps: Int? = nil
    let udpPacingQueueDelayMilliseconds: Double? = nil

    func start() async throws {
        try await withCheckedThrowingContinuation { continuation in
            let gate = ContinuationGate(continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: gate.succeed()
                case let .failed(error): gate.fail(error)
                case let .waiting(error): gate.fail(error)
                case .cancelled: gate.fail(TunnelError.connectionClosed)
                default: break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 10) { [connection] in
                if gate.fail(TunnelError.connectionTimedOut) { connection.cancel() }
            }
        }
    }

    func sendBatch(_ datagrams: [Data]) async throws {
        guard !datagrams.isEmpty else { return }
        var frames = Data()
        frames.reserveCapacity(datagrams.reduce(0) { $0 + $1.count + 4 })
        for datagram in datagrams { frames.append(try HillstoneTCPFrameCodec.encode(datagram)) }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: frames, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            })
        }
    }

    func receiveBatch(timeout: TimeInterval? = nil) async throws -> [Data] {
        let deadline = timeout.map { Date().addingTimeInterval($0) }
        while true {
            let bytes: Data = try await withCheckedThrowingContinuation { continuation in
                let gate = ValueContinuationGate<Data>(continuation)
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, _, error in
                    if let error { gate.fail(error) }
                    else if let data, !data.isEmpty { gate.succeed(data) }
                    else { gate.fail(TunnelError.connectionClosed) }
                }
                if let deadline {
                    let remaining = max(0, deadline.timeIntervalSinceNow)
                    queue.asyncAfter(deadline: .now() + remaining) {
                        gate.fail(TunnelError.responseTimedOut)
                    }
                }
            }
            let decoded = try decoder.append(bytes)
            if !decoded.isEmpty { return decoded }
            if let deadline, deadline <= Date() { throw TunnelError.responseTimedOut }
        }
    }

    func updatePathFeedback(_ feedback: PathFeedback) {}

    func cancel() { connection.cancel() }

    private func consume(path: NWPath) {
        let kind = Self.kind(for: path)
        pathLock.lock()
        let previous = lastNetworkKind
        lastNetworkKind = kind
        pathLock.unlock()
        if let previous, previous != kind { pathChangeHandler(kind) }
    }

    private static func kind(for path: NWPath) -> UnderlyingNetworkKind {
        if path.usesInterfaceType(.wiredEthernet) { return .wiredEthernet }
        if path.usesInterfaceType(.wifi) { return .wiFi }
        if path.usesInterfaceType(.cellular) { return .cellular }
        return .other
    }
}

private final class BatchSendGate: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: Int
    private var firstError: Error?
    private var continuation: CheckedContinuation<Void, Error>?

    init(count: Int, continuation: CheckedContinuation<Void, Error>) {
        remaining = count
        self.continuation = continuation
    }

    func complete(_ error: Error?) {
        lock.lock(); defer { lock.unlock() }
        if firstError == nil { firstError = error }
        remaining -= 1
        guard remaining == 0, let continuation else { return }
        self.continuation = nil
        if let firstError { continuation.resume(throwing: firstError) }
        else { continuation.resume() }
    }
}

private final class InboundPacketBatcher: @unchecked Sendable {
    private let flow: NEPacketTunnelFlow
    private let queue = DispatchQueue(label: "com.linlu.hillstone.inbound-batcher")
    private var packets: [Data] = []
    private var protocols: [NSNumber] = []
    private var scheduledFlush: DispatchWorkItem?
    private var maximumBatchSize = 8
    private let maximumDelay: DispatchTimeInterval = .milliseconds(1)
    private var arrivalsInWindow = 0
    private var windowStartedAt = DispatchTime.now().uptimeNanoseconds

    init(flow: NEPacketTunnelFlow) { self.flow = flow }

    func append(_ packet: Data, protocolNumber: NSNumber) {
        append([packet], protocolNumbers: [protocolNumber])
    }

    func append(_ newPackets: [Data], protocolNumbers newProtocols: [NSNumber]) {
        guard !newPackets.isEmpty, newPackets.count == newProtocols.count else { return }
        queue.async { [self] in
            tuneBatchSize(arrivals: newPackets.count)
            packets.append(contentsOf: newPackets)
            protocols.append(contentsOf: newProtocols)
            if packets.count >= maximumBatchSize {
                flush()
            } else if scheduledFlush == nil {
                let work = DispatchWorkItem { [weak self] in self?.flush() }
                scheduledFlush = work
                queue.asyncAfter(deadline: .now() + maximumDelay, execute: work)
            }
        }
    }

    func flushNow() { queue.async { [weak self] in self?.flush() } }

    private func flush() {
        guard !packets.isEmpty else { scheduledFlush = nil; return }
        scheduledFlush?.cancel(); scheduledFlush = nil
        let readyPackets = packets, readyProtocols = protocols
        packets.removeAll(keepingCapacity: true)
        protocols.removeAll(keepingCapacity: true)
        flow.writePackets(readyPackets, withProtocols: readyProtocols)
    }

    private func tuneBatchSize(arrivals: Int) {
        arrivalsInWindow += arrivals
        let now = DispatchTime.now().uptimeNanoseconds
        let elapsed = now - windowStartedAt
        guard elapsed >= 1_000_000_000 else { return }
        let packetsPerSecond = Double(arrivalsInWindow) * 1_000_000_000 / Double(elapsed)
        maximumBatchSize = packetsPerSecond > 5_000 ? 48 : (packetsPerSecond > 1_000 ? 24 : 8)
        arrivalsInWindow = 0
        windowStartedAt = now
    }
}

public final class PacketTunnelProvider: NEPacketTunnelProvider, @unchecked Sendable {
    private var sessionTask: Task<Void, Never>?, inboundTask: Task<Void, Never>?
    private var keepAliveTask: Task<Void, Never>?, controlTask: Task<Void, Never>?
    private var control: ControlChannel?
    private var dataChannel: (any TunnelDataChannel)?
    private var inboundBatcher: InboundPacketBatcher?
    private let statsLock = NSLock()
    private var sentBytes: UInt64 = 0, receivedBytes: UInt64 = 0
    private var wireSentBytes: UInt64 = 0, wireReceivedBytes: UInt64 = 0
    private var sentPackets: UInt64 = 0, receivedPackets: UInt64 = 0, droppedPackets: UInt64 = 0
    private var startedAt: Date?
    private var installedRouteCount = 0
    private var installedExcludedRouteCount = 0
    private var chinaDirectRoutingActive = false
    private var installedRoutes: [String] = []
    private var installedDNSServers: [String] = []
    private var lastHeartbeatSent: Date?
    private var lastHeartbeatReceived: Date?
    private var heartbeatRTTMilliseconds: Int?
    private var heartbeatSamples: [Int] = []
    private var keepAlivesSent: UInt64 = 0, keepAlivesReceived: UInt64 = 0
    private var encryptionNanoseconds: UInt64 = 0, encryptionBatches: UInt64 = 0
    private var activeMTU = 1_380
    private var activeNetworkKind: UnderlyingNetworkKind = .other
    private var activeDataTransport = ""
    private var udpPacingActive = false
    private var udpPacingRateMbps = 0
    private var pathProbeStatus = "未运行"
    private var pathProbeRTTMilliseconds: Int?
    private var sequenceTracker = ESPSequenceTracker()
    private var activeSessionID = Data()
    private var isRekeying = false
    private var shouldReconnectAfterWake = false
    private let runtimeFailureLock = NSLock()
    private var runtimeFailureInProgress = false

    public override func startTunnel(options: [String: NSObject]? = nil, completionHandler: @escaping (Error?) -> Void) {
        runtimeFailureLock.lock(); runtimeFailureInProgress = false; runtimeFailureLock.unlock()
        reasserting = false
        tunnelDebugLog.notice(
            "startTunnel invoked; usernamePresent=\(options?["username"] != nil, privacy: .public), passwordPresent=\(options?["password"] != nil, privacy: .public)"
        )
        sessionTask?.cancel()
        let runtime: RuntimeConfiguration
        do {
            runtime = try RuntimeConfiguration(provider: self, options: options)
            tunnelDebugLog.info(
                "runtime configuration accepted; port=\(runtime.port, privacy: .public), transport=\(runtime.dataTransport.rawValue, privacy: .public), udpPacing=\(runtime.udpPacingEnabled, privacy: .public), verifyCertificate=\(runtime.verifyCertificate, privacy: .public), chinaDirect=\(runtime.chinaDirectRouting, privacy: .public), refreshPath=\(runtime.refreshPathOptimization, privacy: .public)"
            )
        } catch {
            tunnelDebugLog.error("runtime configuration rejected: \(error.localizedDescription, privacy: .public)")
            completionHandler(error)
            return
        }
        let completion = TunnelCompletion(completionHandler)
        sessionTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await establish(runtime)
                tunnelDebugLog.notice("tunnel establishment completed successfully")
                completion.callback(nil)
            } catch {
                tunnelDebugLog.error("tunnel establishment failed: \(error.localizedDescription, privacy: .public)")
                cancelResources()
                completion.callback(error)
            }
        }
    }

    public override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        tunnelDebugLog.notice("stopTunnel invoked; reason=\(reason.rawValue, privacy: .public)")
        reasserting = false
        if let control { Task { try? await control.send(HillstoneProtocolMessages.logout) } }
        cancelResources()
        let completion = TunnelStopCompletion(completionHandler)
        removeTunnelNetworkSettings { completion.callback() }
    }

    public override func sleep(completionHandler: @escaping () -> Void) {
        shouldReconnectAfterWake = startedAt != nil
        completionHandler()
    }

    public override func wake() {
        guard shouldReconnectAfterWake else { return }
        shouldReconnectAfterWake = false
        failOpenAndCancelTunnel(with: TunnelError.networkChanged(activeNetworkKind))
    }

    public override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)? = nil) {
        let livePacingRate = dataChannel?.udpPacingRateMbps
        let livePacingQueueDelay = dataChannel?.udpPacingQueueDelayMilliseconds
        statsLock.lock()
        let sequenceSnapshot = sequenceTracker.snapshot
        var snapshot: [String: Any] = [
            "sent": sentBytes, "received": receivedBytes,
            "wireSent": wireSentBytes, "wireReceived": wireReceivedBytes,
            "sentPackets": sentPackets, "receivedPackets": receivedPackets,
            "droppedPackets": droppedPackets,
            "duration": startedAt.map { Int(Date().timeIntervalSince($0)) } ?? 0,
            "routeCount": installedRouteCount, "routes": installedRoutes,
            "excludedRouteCount": installedExcludedRouteCount,
            "chinaDirectRouting": chinaDirectRoutingActive,
            "dnsServers": installedDNSServers,
            "mtu": activeMTU, "networkKind": activeNetworkKind.rawValue,
            "dataTransport": activeDataTransport,
            "udpPacingActive": udpPacingActive,
            "udpPacingRateMbps": livePacingRate ?? udpPacingRateMbps,
            "udpPacingQueueDelayMs": livePacingQueueDelay ?? 0,
            "pathProbeStatus": pathProbeStatus,
            "espEstimatedLostPackets": sequenceSnapshot.estimatedLostPackets,
            "espLossPercent": sequenceSnapshot.lossPercent,
            "espReorderedPackets": sequenceSnapshot.reorderedPackets,
            "espReorderPercent": sequenceSnapshot.reorderPercent,
            "espDuplicatePackets": sequenceSnapshot.duplicatePackets,
            "keepAlivesSent": keepAlivesSent, "keepAlivesReceived": keepAlivesReceived,
            "heartbeatLossPercent": keepAlivesSent > 0
                ? Double(keepAlivesSent - min(keepAlivesSent, keepAlivesReceived)) / Double(keepAlivesSent) * 100
                : 0,
            "heartbeatJitterMs": heartbeatJitter(),
            "averageEncryptionMicroseconds": encryptionBatches > 0
                ? Double(encryptionNanoseconds) / Double(encryptionBatches) / 1_000
                : 0
        ]
        if let heartbeatRTTMilliseconds { snapshot["heartbeatRTTMs"] = heartbeatRTTMilliseconds }
        if let pathProbeRTTMilliseconds { snapshot["pathProbeRTTMs"] = pathProbeRTTMilliseconds }
        if let lastHeartbeatReceived {
            snapshot["heartbeatAgeSeconds"] = max(0, Int(Date().timeIntervalSince(lastHeartbeatReceived)))
        }
        statsLock.unlock()
        if let fingerprint = control?.certificateFingerprint, !fingerprint.isEmpty {
            snapshot["certificateFingerprint"] = fingerprint
        }
        completionHandler?(try? JSONSerialization.data(withJSONObject: snapshot))
    }

    private func establish(_ runtime: RuntimeConfiguration) async throws {
        tunnelDebugLog.info("stage 1/8: opening TLS control channel")
        let control = ControlChannel(
            server: runtime.server, port: runtime.port,
            verifyCertificate: runtime.verifyCertificate, certificatePin: runtime.certificatePin
        )
        self.control = control
        try await control.start()
        tunnelDebugLog.info("stage 1/8 complete: TLS control channel ready")
        tunnelDebugLog.info("stage 2/8: sending authentication request")
        try await control.send(HillstoneProtocolMessages.authentication(username: runtime.username, password: runtime.password))
        let auth = try await control.nextMessage()
        tunnelDebugLog.info("stage 2/8: received \(auth.displayName, privacy: .public)")
        guard auth.knownType == .auth else { throw HillstoneNegotiationError.unexpectedMessage(auth.displayName) }
        try HillstoneProtocolMessages.requireSuccess(auth)

        tunnelDebugLog.info("stage 3/8: requesting client policy")
        try await control.send(HillstoneProtocolMessages.clientInfo(serverIPv4: runtime.server))
        let info = try await control.nextMessage()
        tunnelDebugLog.info("stage 3/8: received \(info.displayName, privacy: .public)")
        guard info.knownType == .clientInfo else { throw HillstoneNegotiationError.unexpectedMessage(info.displayName) }
        try HillstoneProtocolMessages.requireSuccess(info)

        var network = HillstoneNegotiatedNetwork()
        try HillstoneProtocolMessages.applyNetworkMessage(info, to: &network)
        tunnelDebugLog.info("stage 4/8: receiving network policy")
        while true {
            let message = try await control.nextMessage()
            tunnelDebugLog.debug("policy message: \(message.displayName, privacy: .public)")
            if message.knownType == .serverDisconnect { throw TunnelError.serverDisconnected }
            try HillstoneProtocolMessages.rejectUnsupportedServerRequirement(message)
            if message.knownType == .keyDone { break }
            try HillstoneProtocolMessages.applyNetworkMessage(message, to: &network)
        }

        tunnelDebugLog.info("stage 5/8: exchanging tunnel keys")
        let keyResult = try await exchangeKeys(control: control)
        let association = keyResult.association
        let sessionID = keyResult.sessionID
        let codec = HillstoneESPCodec(association: association)
        tunnelDebugLog.info("stage 6/8: opening data channel")
        let openedDataChannel = try await openDataChannel(runtime: runtime, network: network, codec: codec)
        let dataChannel = openedDataChannel.channel
        self.dataChannel = dataChannel
        tunnelDebugLog.info("stage 6/8 complete: \(dataChannel.transportName, privacy: .public) data channel ready")

        let networkKind = dataChannel.networkKind
        let effectiveMTU = runtime.automaticMTU
            ? (openedDataChannel.discoveredMTU ?? AdaptiveMTU.recommended(for: networkKind))
            : runtime.mtu
        let includedRoutes = try runtime.includedIPv4CIDRs.map(IPv4Route.parseAddressOrCIDR)
        var excludedRoutes = try runtime.excludedIPv4CIDRs.map(IPv4Route.parseCIDR)
        if runtime.chinaDirectRouting {
            do { excludedRoutes.append(contentsOf: try ChinaDirectRouteCatalog.load()) }
            catch { throw TunnelError.chinaRouteCatalogUnavailable(error.localizedDescription) }
        }
        // Explicit internal routes take precedence over direct-routing
        // exclusions. Keep a broader exclusion because the more-specific
        // included route wins, but remove equal or narrower exclusions that
        // would otherwise carve addresses out of the requested VPN subnet.
        excludedRoutes = IPv4Route.exclusions(excludedRoutes, overriddenBy: includedRoutes)
        excludedRoutes = Self.deduplicatedRoutes(excludedRoutes)
        var effectiveNetwork = network
        if !runtime.usesTunnelDNS { effectiveNetwork.dnsServers = [] }
        let config = try effectiveNetwork.configuration(
            mtu: effectiveMTU,
            forceFullTunnel: runtime.forceFullTunnel,
            additionalIncludedRoutes: includedRoutes,
            excludedRoutes: excludedRoutes,
            blockIPv6Leaks: runtime.blockIPv6Leaks
        )
        tunnelDebugLog.info(
            "stage 7/8: applying network settings; mtu=\(config.mtu, privacy: .public), routes=\(config.includedRoutes.count, privacy: .public), customRoutes=\(includedRoutes.count, privacy: .public), excludedRoutes=\(config.excludedRoutes.count, privacy: .public), dns=\(config.dnsServers.count, privacy: .public)"
        )
        do { try await applyNetworkConfiguration(config, remoteAddress: runtime.server) }
        catch { throw TunnelError.networkSettingsFailed(error.localizedDescription) }
        resetStats(
            configuration: config,
            sessionID: sessionID,
            networkKind: networkKind,
            dataTransport: dataChannel.transportName,
            chinaDirectRouting: runtime.chinaDirectRouting,
            udpPacingActive: runtime.udpPacingEnabled && dataChannel.transportName.contains("Pacing"),
            pathProbeStatus: openedDataChannel.probeStatus,
            pathProbeRTTMilliseconds: openedDataChannel.probeRTTMilliseconds
        )
        let batcher = InboundPacketBatcher(flow: packetFlow)
        inboundBatcher = batcher
        startPacketFlow(dataChannel: dataChannel, codec: codec)
        inboundTask = Task { [weak self] in await self?.runInbound(dataChannel: dataChannel, codec: codec, batcher: batcher) }
        controlTask = Task { [weak self] in await self?.runOnlineControl(control: control, codec: codec) }
        keepAliveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard let self, !Task.isCancelled else { return }
                let sessionID = currentSessionIDUnlessRekeying()
                guard !sessionID.isEmpty else { continue }
                do {
                    recordHeartbeatSent()
                    try await control.send(HillstoneProtocolMessages.keepAlive(sessionID: sessionID))
                } catch {
                    if !Task.isCancelled { failOpenAndCancelTunnel(with: error) }
                    return
                }
            }
        }
        tunnelDebugLog.notice("stage 8/8: packet flow and keepalive tasks started")
    }

    private static func deduplicatedRoutes(_ routes: [IPv4Route]) -> [IPv4Route] {
        var seen = Set<String>()
        return routes.filter { seen.insert("\($0.destinationAddress)/\($0.prefixLength)").inserted }
    }

    private func exchangeKeys(control: ControlChannel) async throws -> (association: HillstoneSecurityAssociation, sessionID: Data) {
        let keyMaterialCount = 48
        var keyMaterial = Data(count: keyMaterialCount), inboundSPI: UInt32 = 0, inboundCPI: UInt16 = 0
        let randomOK = keyMaterial.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, keyMaterialCount, $0.baseAddress!) == errSecSuccess
        }
        guard randomOK,
              withUnsafeMutableBytes(of: &inboundSPI, { SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!) }) == errSecSuccess,
              withUnsafeMutableBytes(of: &inboundCPI, { SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!) }) == errSecSuccess else {
            throw TunnelError.invalidConfiguration
        }
        if inboundSPI == 0 { inboundSPI = 1 }
        try await control.send(HillstoneProtocolMessages.newKey(
            keyMaterial: keyMaterial, inboundSPI: inboundSPI, inboundCPI: inboundCPI
        ))
        let response = try await control.nextMessage()
        let association = try HillstoneProtocolMessages.securityAssociation(
            response: response, inboundSPI: inboundSPI, keyMaterial: keyMaterial
        )
        guard let sessionID = response.value(for: .sessionID), sessionID.count == 4 else {
            throw HillstoneNegotiationError.missingPayload(.sessionID)
        }
        return (association, sessionID)
    }

    private func runOnlineControl(control: ControlChannel, codec: HillstoneESPCodec) async {
        while !Task.isCancelled {
            do {
                let message = try await control.nextMessage(timeout: nil)
                switch message.knownType {
                case .keepAlive:
                    recordHeartbeatReceived()
                    continue
                case .rekey:
                    setRekeying(true)
                    defer { setRekeying(false) }
                    let replacement = try await exchangeKeys(control: control)
                    codec.replaceAssociation(replacement.association)
                    updateSessionID(replacement.sessionID)
                case .serverDisconnect:
                    throw TunnelError.serverDisconnected
                case .hostCheck, .hostCheckUpdate:
                    try HillstoneProtocolMessages.rejectUnsupportedServerRequirement(message)
                default:
                    continue
                }
            } catch {
                if !Task.isCancelled { failOpenAndCancelTunnel(with: error) }
                return
            }
        }
    }

    private func openDataChannel(
        runtime: RuntimeConfiguration,
        network: HillstoneNegotiatedNetwork,
        codec: HillstoneESPCodec
    ) async throws -> OpenedDataChannel {
        let pathChanged: @Sendable (UnderlyingNetworkKind) -> Void = { [weak self] kind in
            self?.handleNetworkChange(kind)
        }
        func udp(disableFragmentation: Bool = false) throws -> UDPDataChannel {
            guard let port = network.serverUDPPort else {
                throw HillstoneNegotiationError.missingPayload(.serverUDPPort)
            }
            return UDPDataChannel(
                server: runtime.server,
                port: port,
                pacingEnabled: runtime.udpPacingEnabled,
                disableFragmentation: disableFragmentation,
                pathChangeHandler: pathChanged
            )
        }
        func tcp() throws -> TCPDataChannel {
            guard let port = network.serverTCPPort else { throw TunnelError.tcpDataPortUnavailable }
            return TCPDataChannel(server: runtime.server, port: port, pathChangeHandler: pathChanged)
        }

        func started(_ channel: any TunnelDataChannel) async throws -> any TunnelDataChannel {
            try await channel.start()
            return channel
        }

        let initialChannel: any TunnelDataChannel
        switch runtime.dataTransport {
        case .udp:
            tunnelDebugLog.info("data transport forced to UDP")
            let channel = try udp(disableFragmentation: runtime.automaticMTU)
            do { initialChannel = try await started(channel) }
            catch { throw TunnelError.dataChannelUnavailable }
        case .tcp:
            tunnelDebugLog.info("data transport forced to TCP")
            let channel = try tcp()
            do { initialChannel = try await started(channel) }
            catch { throw TunnelError.dataChannelUnavailable }
        case .automatic:
            // UDP avoids nesting inner TCP congestion control inside another
            // reliable byte stream. Keep TCP as the compatibility fallback
            // for paths where creating the UDP endpoint fails.
            if network.serverUDPPort != nil {
                tunnelDebugLog.info("automatic transport: trying UDP first")
                let channel = try udp(disableFragmentation: runtime.automaticMTU)
                do { initialChannel = try await started(channel) }
                catch {
                    tunnelDebugLog.warning("automatic transport: UDP failed, falling back to TCP: \(error.localizedDescription, privacy: .public)")
                    channel.cancel()
                    let fallback = try tcp()
                    do { initialChannel = try await started(fallback) }
                    catch { throw TunnelError.dataChannelUnavailable }
                }
            } else {
                tunnelDebugLog.info("automatic transport: trying TCP")
                let channel = try tcp()
                do { initialChannel = try await started(channel) }
                catch { throw TunnelError.dataChannelUnavailable }
            }
        }

        var selectedChannel = initialChannel
        var networkKind = selectedChannel.networkKind
        if !runtime.refreshPathOptimization,
           runtime.dataTransport == .automatic,
           let cached = PathOptimizationStore.shared.load(server: runtime.server, networkKind: networkKind),
           cached.transport != selectedChannel.kind {
            do {
                let replacement: any TunnelDataChannel
                switch cached.transport {
                case .udp:
                    replacement = try await started(udp(disableFragmentation: runtime.automaticMTU))
                case .tcp:
                    replacement = try await started(tcp())
                }
                selectedChannel.cancel()
                selectedChannel = replacement
                networkKind = replacement.networkKind
                tunnelDebugLog.info("automatic transport: restored cached \(replacement.kind.rawValue, privacy: .public) path")
            } catch {
                tunnelDebugLog.warning("cached transport unavailable; keeping current channel: \(error.localizedDescription, privacy: .public)")
            }
        }

        guard runtime.automaticMTU else {
            return OpenedDataChannel(
                channel: selectedChannel, discoveredMTU: nil, probeRTTMilliseconds: nil,
                probeStatus: "已使用手动 MTU"
            )
        }

        let previousOptimization = PathOptimizationStore.shared.load(
            server: runtime.server,
            networkKind: networkKind
        )
        if !runtime.refreshPathOptimization,
           let cached = previousOptimization,
           cached.transport == selectedChannel.kind,
           cached.mtu != nil || !cached.probeSupported {
            return OpenedDataChannel(
                channel: selectedChannel,
                discoveredMTU: cached.mtu,
                probeRTTMilliseconds: nil,
                probeStatus: selectedChannel.kind == .tcp
                    ? "TCP 数据通道使用系统分段"
                    : (cached.probeSupported ? "使用 24 小时路径缓存" : "网关不响应 MTU 探测")
            )
        }

        guard selectedChannel.kind == .udp,
              let sourceAddress = network.clientAddress,
              let destinationAddress = network.gatewayAddress else {
            PathOptimizationStore.shared.save(
                server: runtime.server, networkKind: networkKind,
                transport: selectedChannel.kind, mtu: nil, probeSupported: false
            )
            return OpenedDataChannel(
                channel: selectedChannel, discoveredMTU: nil, probeRTTMilliseconds: nil,
                probeStatus: selectedChannel.kind == .tcp
                    ? "TCP 数据通道使用系统分段"
                    : "网关未提供 MTU 探测地址"
            )
        }

        let probe = await probeDataPath(
            channel: selectedChannel,
            codec: codec,
            sourceAddress: sourceAddress,
            destinationAddress: destinationAddress,
            recommendedMTU: AdaptiveMTU.recommended(for: networkKind),
            networkKind: networkKind
        )
        if PathOptimizationPolicy.shouldRejectRefreshedPath(
            refreshRequested: runtime.refreshPathOptimization,
            previousProbeWasSupported: previousOptimization?.probeSupported == true,
            currentProbeSucceeded: probe.supported
        ) {
            selectedChannel.cancel()
            tunnelDebugLog.warning("fresh path failed a previously supported data probe")
            throw TunnelError.dataChannelUnavailable
        }
        var finalChannel = selectedChannel
        if probe.requiresFreshChannel {
            selectedChannel.cancel()
            let replacement = try udp(disableFragmentation: true)
            do { finalChannel = try await started(replacement) }
            catch { throw TunnelError.dataChannelUnavailable }
        }
        PathOptimizationStore.shared.save(
            server: runtime.server, networkKind: networkKind,
            transport: finalChannel.kind, mtu: probe.bestMTU, probeSupported: probe.supported
        )
        return OpenedDataChannel(
            channel: finalChannel,
            discoveredMTU: probe.bestMTU,
            probeRTTMilliseconds: probe.rttMilliseconds,
            probeStatus: probe.supported
                ? "已探测到安全 MTU \(probe.bestMTU ?? DPLPMTUDPlan.baseMTU)"
                : "网关不响应 MTU 探测"
        )
    }

    private func probeDataPath(
        channel: any TunnelDataChannel,
        codec: HillstoneESPCodec,
        sourceAddress: String,
        destinationAddress: String,
        recommendedMTU: Int,
        networkKind: UnderlyingNetworkKind
    ) async -> DataPathProbeResult {
        let identifier = UInt16.random(in: 1...UInt16.max)
        var bestMTU: Int?
        var measuredRTT: Int?
        var timedOut = false

        for (index, candidate) in DPLPMTUDPlan.candidates(
            recommendedMTU: recommendedMTU,
            networkKind: networkKind
        ).enumerated() {
            let sequence = UInt16(truncatingIfNeeded: index + 1)
            guard let request = IPv4ICMPEchoProbe.request(
                sourceAddress: sourceAddress,
                destinationAddress: destinationAddress,
                totalSize: candidate,
                identifier: identifier,
                sequence: sequence
            ) else { break }
            do {
                let started = DispatchTime.now().uptimeNanoseconds
                try await channel.sendBatch([try codec.seal(request, nextHeader: 4)])
                let replies = try await channel.receiveBatch(timeout: 0.5)
                let matched = try replies.contains { datagram in
                    let opened = try codec.open(datagram)
                    return opened.nextHeader == 4
                        && IPv4ICMPEchoProbe.matchesReply(
                            opened.packet, identifier: identifier, sequence: sequence
                        )
                }
                guard matched else { break }
                bestMTU = candidate
                measuredRTT = Int((DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
            } catch {
                timedOut = true
                break
            }
        }
        return DataPathProbeResult(
            supported: bestMTU != nil,
            bestMTU: bestMTU,
            rttMilliseconds: measuredRTT,
            requiresFreshChannel: timedOut
        )
    }

    private func startPacketFlow(dataChannel: any TunnelDataChannel, codec: HillstoneESPCodec) {
        packetFlow.readPackets { [weak self] packets, protocols in
            guard let self, !packets.isEmpty else { return }
            Task {
                do {
                    let started = DispatchTime.now().uptimeNanoseconds
                    let headers = packets.indices.map { index -> UInt8 in
                        let family = index < protocols.count ? protocols[index].int32Value : AF_INET
                        return family == AF_INET6 ? 41 : 4
                    }
                    let datagrams = try codec.sealBatch(packets, nextHeaders: headers)
                    try await dataChannel.sendBatch(datagrams)
                    let processingTime = DispatchTime.now().uptimeNanoseconds - started
                    self.addSent(
                        bytes: UInt64(packets.reduce(0) { $0 + $1.count }),
                        wireBytes: UInt64(datagrams.reduce(0) { $0 + $1.count }),
                        packets: UInt64(packets.count),
                        processingNanoseconds: processingTime
                    )
                } catch {
                    self.recordDrop(UInt64(packets.count))
                    self.failOpenAndCancelTunnel(with: error)
                    return
                }
                self.startPacketFlow(dataChannel: dataChannel, codec: codec)
            }
        }
    }

    private func runInbound(dataChannel: any TunnelDataChannel, codec: HillstoneESPCodec, batcher: InboundPacketBatcher) async {
        while !Task.isCancelled {
            do {
                let datagrams = try await dataChannel.receiveBatch(timeout: nil)
                var packets: [Data] = []
                var protocols: [NSNumber] = []
                packets.reserveCapacity(datagrams.count)
                protocols.reserveCapacity(datagrams.count)
                var receivedByteCount: UInt64 = 0
                var wireByteCount: UInt64 = 0
                for datagram in datagrams {
                    if let header = try? ESPHeader.decode(Data(datagram.prefix(8))) {
                        recordInboundESPSequence(header.sequence)
                    }
                    let opened = try codec.open(datagram)
                    packets.append(opened.packet)
                    protocols.append(NSNumber(value: opened.nextHeader == 41 ? AF_INET6 : AF_INET))
                    receivedByteCount += UInt64(opened.packet.count)
                    wireByteCount += UInt64(datagram.count)
                }
                batcher.append(packets, protocolNumbers: protocols)
                addReceived(
                    bytes: receivedByteCount,
                    wireBytes: wireByteCount,
                    packets: UInt64(datagrams.count)
                )
            } catch {
                if !Task.isCancelled {
                    recordDrop(1)
                    failOpenAndCancelTunnel(with: error)
                }
                return
            }
        }
    }

    private func applyNetworkConfiguration(_ config: TunnelNetworkConfiguration, remoteAddress: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            setTunnelNetworkSettings(NetworkSettingsFactory.make(configuration: config, remoteAddress: remoteAddress)) { error in
                if let error {
                    tunnelDebugLog.error("setTunnelNetworkSettings failed: \(error.localizedDescription, privacy: .public)")
                    continuation.resume(throwing: error)
                } else {
                    tunnelDebugLog.info("setTunnelNetworkSettings completed")
                    continuation.resume()
                }
            }
        }
    }
    private func addSent(bytes: UInt64, wireBytes: UInt64, packets: UInt64, processingNanoseconds: UInt64) {
        statsLock.lock()
        sentBytes += bytes; wireSentBytes += wireBytes; sentPackets += packets
        encryptionNanoseconds += processingNanoseconds; encryptionBatches += 1
        statsLock.unlock()
    }
    private func addReceived(bytes: UInt64, wireBytes: UInt64, packets: UInt64) {
        statsLock.lock()
        receivedBytes += bytes; wireReceivedBytes += wireBytes; receivedPackets += packets
        statsLock.unlock()
    }
    private func recordDrop(_ packets: UInt64) {
        statsLock.lock(); droppedPackets += packets; statsLock.unlock()
    }
    private func resetStats(
        configuration: TunnelNetworkConfiguration,
        sessionID: Data,
        networkKind: UnderlyingNetworkKind,
        dataTransport: String,
        chinaDirectRouting: Bool,
        udpPacingActive: Bool,
        pathProbeStatus: String,
        pathProbeRTTMilliseconds: Int?
    ) {
        statsLock.lock()
        sentBytes = 0; receivedBytes = 0; wireSentBytes = 0; wireReceivedBytes = 0
        sentPackets = 0; receivedPackets = 0; droppedPackets = 0
        startedAt = Date(); installedRouteCount = configuration.includedRoutes.count
        installedExcludedRouteCount = configuration.excludedRoutes.count
        chinaDirectRoutingActive = chinaDirectRouting
        installedRoutes = configuration.includedRoutes.map { "\($0.destinationAddress)/\($0.prefixLength)" }
        installedDNSServers = configuration.dnsServers
        activeMTU = configuration.mtu; activeNetworkKind = networkKind
        activeDataTransport = dataTransport
        self.udpPacingActive = udpPacingActive
        self.pathProbeStatus = pathProbeStatus
        self.pathProbeRTTMilliseconds = pathProbeRTTMilliseconds
        udpPacingRateMbps = udpPacingActive
            ? Int(UDPPacingController.initialBitsPerSecond(for: networkKind) / 1_000_000)
            : 0
        lastHeartbeatSent = nil; lastHeartbeatReceived = nil; heartbeatRTTMilliseconds = nil
        heartbeatSamples = []; keepAlivesSent = 0; keepAlivesReceived = 0
        encryptionNanoseconds = 0; encryptionBatches = 0
        sequenceTracker = ESPSequenceTracker()
        activeSessionID = sessionID; isRekeying = false
        statsLock.unlock()
    }
    private func currentSessionIDUnlessRekeying() -> Data {
        statsLock.lock(); defer { statsLock.unlock() }
        return isRekeying ? Data() : activeSessionID
    }
    private func updateSessionID(_ value: Data) {
        statsLock.lock(); activeSessionID = value; statsLock.unlock()
    }
    private func setRekeying(_ value: Bool) {
        statsLock.lock(); isRekeying = value; statsLock.unlock()
    }
    private func recordHeartbeatSent() {
        statsLock.lock(); lastHeartbeatSent = Date(); keepAlivesSent += 1; statsLock.unlock()
    }
    private func recordHeartbeatReceived() {
        statsLock.lock()
        let now = Date(); lastHeartbeatReceived = now
        keepAlivesReceived += 1
        if let lastHeartbeatSent {
            let rtt = max(0, Int(now.timeIntervalSince(lastHeartbeatSent) * 1_000))
            heartbeatRTTMilliseconds = rtt
            heartbeatSamples.append(rtt)
            if heartbeatSamples.count > 20 { heartbeatSamples.removeFirst() }
        }
        statsLock.unlock()
        updatePathFeedback()
    }

    private func recordInboundESPSequence(_ sequence: UInt32) {
        statsLock.lock(); sequenceTracker.record(sequence: sequence); statsLock.unlock()
    }

    private func updatePathFeedback() {
        statsLock.lock()
        let sequence = sequenceTracker.snapshot
        let feedback = PathFeedback(
            rttMilliseconds: heartbeatRTTMilliseconds,
            jitterMilliseconds: heartbeatJitter(),
            heartbeatLossPercent: keepAlivesSent > 0
                ? Double(keepAlivesSent - min(keepAlivesSent, keepAlivesReceived)) / Double(keepAlivesSent) * 100
                : 0,
            espLossPercent: sequence.lossPercent,
            espReorderPercent: sequence.reorderPercent
        )
        statsLock.unlock()
        dataChannel?.updatePathFeedback(feedback)
    }

    private func heartbeatJitter() -> Double {
        guard heartbeatSamples.count > 1 else { return 0 }
        let differences = zip(heartbeatSamples, heartbeatSamples.dropFirst()).map { abs($1 - $0) }
        return Double(differences.reduce(0, +)) / Double(differences.count)
    }

    private func handleNetworkChange(_ kind: UnderlyingNetworkKind) {
        statsLock.lock(); activeNetworkKind = kind; let isActive = startedAt != nil; statsLock.unlock()
        guard isActive else { return }
        tunnelDebugLog.notice("underlying network changed to \(kind.rawValue, privacy: .public); requesting reconnect")
        failOpenAndCancelTunnel(with: TunnelError.networkChanged(kind))
    }
    private func failOpenAndCancelTunnel(with error: Error) {
        runtimeFailureLock.lock()
        guard !runtimeFailureInProgress else {
            runtimeFailureLock.unlock()
            return
        }
        runtimeFailureInProgress = true
        runtimeFailureLock.unlock()

        // Do not leave the session in reasserting state with stale full-tunnel
        // routes. Remove the settings first, stop packet I/O, and let the host
        // app perform a fresh connection attempt over the physical interface.
        reasserting = false
        tunnelDebugLog.notice("failing open and removing tunnel routes before reconnect")
        cancelResources()
        removeTunnelNetworkSettings { [weak self] in
            self?.cancelTunnelWithError(error)
        }
    }

    private func removeTunnelNetworkSettings(completion: @escaping @Sendable () -> Void) {
        setTunnelNetworkSettings(nil) { settingsError in
            if let settingsError {
                tunnelDebugLog.error(
                    "failed to explicitly remove tunnel settings: \(settingsError.localizedDescription, privacy: .public)"
                )
            } else {
                tunnelDebugLog.info("tunnel settings removed; physical network and DNS are active")
            }
            completion()
        }
    }
    private func cancelResources() {
        tunnelDebugLog.debug("cancelling provider resources")
        sessionTask?.cancel(); inboundTask?.cancel(); keepAliveTask?.cancel(); controlTask?.cancel()
        control?.cancel(); dataChannel?.cancel()
        inboundBatcher?.flushNow()
        sessionTask = nil; inboundTask = nil; keepAliveTask = nil; controlTask = nil
        control = nil; dataChannel = nil; inboundBatcher = nil
        statsLock.lock(); startedAt = nil; statsLock.unlock()
    }
}
