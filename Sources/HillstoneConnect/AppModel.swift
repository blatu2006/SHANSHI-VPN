import AppKit
import Combine
import CryptoKit
import Darwin
import Foundation
import HillstoneProtocol
import Network
import ServiceManagement
import UniformTypeIdentifiers
@preconcurrency import NetworkExtension
@preconcurrency import SystemExtensions
@preconcurrency import UserNotifications

private final class ConnectionEventLogger: @unchecked Sendable {
    static let shared = ConnectionEventLogger()

    let logURL: URL
    private let queue = DispatchQueue(label: "com.linlu.nlvc-vpn.event-log")
    private let maximumBytes: UInt64 = 2 * 1_024 * 1_024
    private let formatter = ISO8601DateFormatter()

    private init() {
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        let directory = library.appendingPathComponent("Logs/NLVC VPN", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        logURL = directory.appendingPathComponent("connection.log")
    }

    func append(_ category: String, _ message: String) {
        queue.async { [self] in
            rotateIfNeeded()
            let safeMessage = message.replacingOccurrences(of: "\n", with: " ")
            let line = "\(formatter.string(from: Date())) [\(category)] \(safeMessage)\n"
            let data = Data(line.utf8)
            if !FileManager.default.fileExists(atPath: logURL.path) {
                FileManager.default.createFile(atPath: logURL.path, contents: data)
                return
            }
            guard let handle = try? FileHandle(forWritingTo: logURL) else { return }
            defer { try? handle.close() }
            do {
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } catch { }
        }
    }

    func tail(maximumLines: Int = 200) -> String {
        queue.sync {
            guard let text = try? String(contentsOf: logURL, encoding: .utf8) else { return "" }
            return text.split(separator: "\n", omittingEmptySubsequences: false)
                .suffix(maximumLines).joined(separator: "\n")
        }
    }

    private func rotateIfNeeded() {
        guard let values = try? logURL.resourceValues(forKeys: [.fileSizeKey]),
              UInt64(values.fileSize ?? 0) >= maximumBytes else { return }
        let archived = logURL.deletingLastPathComponent().appendingPathComponent("connection.previous.log")
        try? FileManager.default.removeItem(at: archived)
        try? FileManager.default.moveItem(at: logURL, to: archived)
    }
}

private enum UpdateError: LocalizedError {
    case invalidManifest
    case checksumMismatch
    case unsupportedPackage

    var errorDescription: String? {
        switch self {
        case .invalidManifest: "更新清单内容无效"
        case .checksumMismatch: "更新包 SHA-256 校验失败，已停止安装"
        case .unsupportedPackage: "更新文件不是受支持的 PKG 或 ZIP 包"
        }
    }
}

private final class UncheckedSendableBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

@MainActor
private final class SystemExtensionActivationController: NSObject, @preconcurrency OSSystemExtensionRequestDelegate {
    typealias Completion = @MainActor (Result<Void, Error>) -> Void

    private let identifier: String
    private var completions: [Completion] = []
    private var requestInFlight = false
    var approvalRequired: (() -> Void)?

    init(identifier: String) {
        self.identifier = identifier
    }

    func activate(completion: @escaping Completion) {
        completions.append(completion)
        guard !requestInFlight else { return }
        requestInFlight = true
        let request = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: identifier,
            queue: .main
        )
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    func request(
        _ request: OSSystemExtensionRequest,
        didFinishWithResult result: OSSystemExtensionRequest.Result
    ) {
        finish(.success(()))
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        finish(.failure(error))
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        approvalRequired?()
    }

    func request(
        _ request: OSSystemExtensionRequest,
        actionForReplacingExtension existing: OSSystemExtensionProperties,
        withExtension ext: OSSystemExtensionProperties
    ) -> OSSystemExtensionRequest.ReplacementAction {
        .replace
    }

    private func finish(_ result: Result<Void, Error>) {
        requestInFlight = false
        let callbacks = completions
        completions.removeAll()
        callbacks.forEach { $0(result) }
    }
}

@MainActor
final class AppModel: ObservableObject {
    private static let eventLogger = ConnectionEventLogger.shared
    private static let profileDefaultsKey = "connection-profile-v1"
    private static let profilesDefaultsKey = "connection-profiles-v4"
    private static let selectedProfileDefaultsKey = "selected-connection-profile-v4"
    private static let directModeMigrationKey = "connection-profile-direct-mode-v2"
    private static let privateCertificateMigrationKey = "connection-profile-private-certificate-v3"
    private static let lastAutomaticUpdateCheckKey = "last-automatic-update-check-v1"

    enum Section: String, CaseIterable, Identifiable {
        case overview
        case connections
        case diagnostics
        case settings

        var id: String { rawValue }

        var title: String {
            switch self {
            case .overview: "概览"
            case .connections: "连接"
            case .diagnostics: "诊断"
            case .settings: "设置"
            }
        }

        var icon: String {
            switch self {
            case .overview: "square.grid.2x2"
            case .connections: "point.3.connected.trianglepath.dotted"
            case .diagnostics: "waveform.path.ecg"
            case .settings: "gearshape"
            }
        }
    }

    @Published var selectedSection: Section = .overview
    @Published var profile: ConnectionProfile
    @Published private(set) var profiles: [ConnectionProfile] = []
    /// Credentials are decrypted from the app's sandbox at runtime. Persisted
    /// ConnectionProfile metadata intentionally contains neither field.
    @Published var sessionPassword = ""
    @Published var credentialError: String?
    @Published var connectionError: String?
    @Published var connectionAlert: String?
    @Published private(set) var systemExtensionApprovalRequired = false
    @Published var settingsError: String?
    @Published var diagnosticsMessage: String?
    @Published var stage: SessionStage = .idle {
        didSet {
            guard stage != oldValue else { return }
            recordStageTransition(from: oldValue)
        }
    }
    @Published var routeCount = 0
    @Published var excludedRouteCount = 0
    @Published var chinaDirectRoutingActive = false
    @Published var elapsedSeconds = 0
    @Published var bytesReceived: UInt64 = 0
    @Published var bytesSent: UInt64 = 0
    @Published var downloadBytesPerSecond: UInt64 = 0
    @Published var uploadBytesPerSecond: UInt64 = 0
    @Published var directBytesReceived: UInt64 = 0
    @Published var directBytesSent: UInt64 = 0
    @Published var directDownloadBytesPerSecond: UInt64 = 0
    @Published var directUploadBytesPerSecond: UInt64 = 0
    @Published var packetsReceived: UInt64 = 0
    @Published var packetsSent: UInt64 = 0
    @Published var droppedPackets: UInt64 = 0
    @Published var heartbeatRTTMilliseconds: Int?
    @Published var heartbeatAgeSeconds: Int?
    @Published var activeRoutes: [String] = []
    @Published var dnsServers: [String] = []
    @Published var certificateFingerprint = ""
    @Published var reconnectCount = 0
    @Published var heartbeatJitterMilliseconds: Double = 0
    @Published var heartbeatLossPercent: Double = 0
    @Published var averageEncryptionMicroseconds: Double = 0
    @Published var activeMTU = 1_380
    @Published var activeDataTransport = ""
    @Published var udpPacingActive = false
    @Published var udpPacingRateMbps = 0
    @Published var udpPacingQueueDelayMilliseconds: Double = 0
    @Published var pathProbeStatus = "未运行"
    @Published var pathProbeRTTMilliseconds: Int?
    @Published var espLossPercent: Double = 0
    @Published var espReorderPercent: Double = 0
    @Published var espDuplicatePackets: UInt64 = 0
    @Published var underlyingNetwork: UnderlyingNetworkKind = .other
    @Published var loginItemError: String?
    @Published var updateStatus = "尚未检查"
    @Published var isCheckingForUpdates = false
    @Published var availableUpdateURL: URL?
    @Published var isDownloadingUpdate = false
    @Published var showingProfileEditor = false
    var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.4.0"
    }
    var appBuild: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    }
    private var tickerTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var tunnelStartStatusTask: Task<Void, Never>?
    private var tunnelManager: NETunnelProviderManager?
    private var statusObserver: NSObjectProtocol?
    private var lifecycleObservers: [NSObjectProtocol] = []
    private var wantsConnection = false
    private var isStartingTunnel = false
    private var connectionOperationID: UInt64 = 0
    private var connectionWasUserInitiated = false
    private var incidentNotificationSent = false
    private var reconnectAttempt = 0
    // Start pessimistically. NWPathMonitor reports the real state shortly
    // after launch; assuming online here can race an automatic VPN attempt and
    // surface a misleading tunnel error while the Mac is offline.
    private var pathIsSatisfied = false
    private var lastProviderResponseAt: Date?
    private var providerRecoveryInProgress = false
    private var requiresFreshPathOptimization = false
    private var shouldReconnectAfterUpdate = CommandLine.arguments.contains("--reconnect-after-update")
    private var availableUpdateSHA256 = ""
    private var availableUpdateVersion = ""
    private var stateSynchronizationTask: Task<Void, Never>?
    private var lastStatsSample: (
        sent: UInt64, received: UInt64,
        wireSent: UInt64, wireReceived: UInt64,
        physicalSent: UInt64, physicalReceived: UInt64,
        date: Date
    )?
    private var physicalInterfaceName: String?
    private let pathMonitor = NWPathMonitor()
    private let pathMonitorQueue = DispatchQueue(label: "com.linlu.nlvc-vpn.path-monitor")
    private var tunnelManagerLoaded = false
    private static let providerBundleIdentifier = "com.linlu.hillstoneconnect.PacketTunnel"
    private lazy var systemExtensionController = SystemExtensionActivationController(
        identifier: Self.providerBundleIdentifier
    )

    init(userDefaults: UserDefaults = .standard) {
        if let data = userDefaults.data(forKey: Self.profilesDefaultsKey),
           let saved = try? JSONDecoder().decode([ConnectionProfile].self, from: data),
           !saved.isEmpty {
            profiles = saved
            let selectedID = userDefaults.string(forKey: Self.selectedProfileDefaultsKey).flatMap(UUID.init(uuidString:))
            profile = saved.first(where: { $0.id == selectedID }) ?? saved[0]
        } else if let data = userDefaults.data(forKey: Self.profileDefaultsKey),
           let saved = try? JSONDecoder().decode(ConnectionProfile.self, from: data) {
            profile = saved
            profiles = [saved]
        } else {
            profile = .preview
            profiles = [.preview]
        }
        if !userDefaults.bool(forKey: Self.directModeMigrationKey) {
            // The observed 5.7.0 profile uses direct TLS and accepts the
            // appliance's private certificate. Apply that compatibility
            // migration once; the user can still change either setting later.
            profile.usesSPA = false
            profile.verifyServerCertificate = false
            userDefaults.set(true, forKey: Self.directModeMigrationKey)
        }
        if !userDefaults.bool(forKey: Self.privateCertificateMigrationKey) {
            // This appliance presents its long-lived private SG-6000
            // certificate. Strict platform validation cannot succeed for it.
            if profile.server == ConnectionProfile.preview.server {
                profile.verifyServerCertificate = false
            }
            userDefaults.set(true, forKey: Self.privateCertificateMigrationKey)
        }
        let legacyUsername = profile.username
        do {
            if let credentials = try LocalCredentialStore.load(profileID: profile.id) {
                profile.username = credentials.username
                sessionPassword = credentials.password
            } else {
                // Move usernames written by older builds out of UserDefaults.
                profile.username = legacyUsername
                sessionPassword = ""
                if !legacyUsername.isEmpty {
                    try LocalCredentialStore.save(
                        LocalCredentials(username: legacyUsername, password: ""),
                        profileID: profile.id
                    )
                }
            }
        } catch {
            profile.username = legacyUsername
            sessionPassword = ""
            credentialError = error.localizedDescription
        }
        persistProfileMetadata(to: userDefaults)
        statusObserver = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange, object: nil, queue: .main
        ) { [weak self] notification in
            guard let connection = notification.object as? NEVPNConnection else { return }
            Task { @MainActor [weak self] in
                guard let self, connection === self.tunnelManager?.connection else { return }
                self.applyVPNStatus(connection.status)
            }
        }
        observeSystemLifecycle()
        pathMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in self?.consumeSystemPath(path) }
        }
        pathMonitor.start(queue: pathMonitorQueue)
        loadTunnelManager()
        systemExtensionController.approvalRequired = { [weak self] in
            guard let self else { return }
            self.systemExtensionApprovalRequired = true
            let message = "请在系统设置 > 通用 > 登录项与扩展 > 网络扩展中允许“NLVC VPN 数据通道”。允许后本次连接会自动继续。"
            self.connectionError = message
            self.connectionAlert = message
            Self.eventLogger.append("system-extension", "activation requires user approval")
        }
        Self.eventLogger.append("lifecycle", "application started, version \(appVersion)")
        Self.eventLogger.append(
            "runtime",
            "bundle=\(Bundle.main.bundlePath), executable=\(Bundle.main.executablePath ?? "missing"), "
                + "packetTunnel=\(Bundle.main.bundlePath)/Contents/Library/SystemExtensions/"
                + "com.linlu.hillstoneconnect.PacketTunnel.systemextension"
        )
        if profile.automaticallyChecksForUpdates {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                guard let self else { return }
                self.checkForUpdates(automatic: true)
            }
        }
    }

    var isConnected: Bool { stage == .connected }
    var isBusy: Bool { ![.idle, .connected, .failed].contains(stage) }
    var hasCredentials: Bool {
        !profile.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !sessionPassword.isEmpty
    }
    var downloadRateText: String { rateText(downloadBytesPerSecond) }
    var uploadRateText: String { rateText(uploadBytesPerSecond) }
    var directDownloadRateText: String { rateText(directDownloadBytesPerSecond) }
    var directUploadRateText: String { rateText(directUploadBytesPerSecond) }

    func toggleConnection() {
        if isConnected || isBusy {
            disconnect()
        } else if !hasCredentials {
            showingProfileEditor = true
        } else {
            connect(userInitiated: true)
        }
    }

    func connect(userInitiated: Bool = true) {
        Self.eventLogger.append("connection", "connect requested")
        connectionWasUserInitiated = userInitiated
        guard pathIsSatisfied else {
            connectionError = nil
            connectionAlert = nil
            wantsConnection = profile.automaticallyReconnects
            stage = .idle
            zeroLiveRates()
            Self.eventLogger.append("network", "connect deferred because no network is available")
            return
        }
        wantsConnection = true
        reconnectTask?.cancel(); reconnectTask = nil
        reconnectAttempt = 0
        reconnectCount = 0
        saveProfile()
        resetSessionMetrics()

        connectionError = nil
        connectionAlert = nil
        systemExtensionApprovalRequired = false
        stage = .discovering
        activateSystemExtensionAndStart(operationID: beginConnectionOperation())
    }

    private func activateSystemExtensionAndStart(operationID: UInt64) {
        // Activation is part of the connection attempt. Mark it busy before
        // submitting the request so a transient .disconnected notification
        // cannot enqueue a second retry while activation is still in flight.
        isStartingTunnel = true
        Self.eventLogger.append("system-extension", "requesting activation, operation=\(operationID)")
        systemExtensionController.activate { [weak self] result in
            guard let self else { return }
            guard self.connectionOperationIsCurrent(operationID) else {
                Self.eventLogger.append(
                    "system-extension",
                    "ignored stale activation callback, operation=\(operationID)"
                )
                return
            }
            switch result {
            case .success:
                self.systemExtensionApprovalRequired = false
                Self.eventLogger.append("system-extension", "activation completed, operation=\(operationID)")
                self.connectionError = nil
                self.configureAndStartVPN(operationID: operationID)
            case .failure(let error):
                let nsError = error as NSError
                let errorDetails = "domain=\(nsError.domain), code=\(nsError.code), "
                    + "description=\(nsError.localizedDescription), userInfo=\(nsError.userInfo)"
                self.wantsConnection = false
                self.isStartingTunnel = false
                self.systemExtensionApprovalRequired = false
                self.connectionError = "VPN 数据通道扩展激活失败（\(nsError.domain) / \(nsError.code)）："
                    + nsError.localizedDescription
                self.connectionAlert = self.connectionError
                self.stage = .failed
                Self.eventLogger.append(
                    "system-extension",
                    "activation failed, operation=\(operationID), \(errorDetails)"
                )
            }
        }
    }

    func openNetworkExtensionSettings() {
        let pane = "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"
            + "?extensionPointIdentifier=com.apple.system_extension.network_extension"
        if let url = URL(string: pane), NSWorkspace.shared.open(url) {
            Self.eventLogger.append("system-extension", "opened Login Items & Extensions settings")
            return
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
        Self.eventLogger.append("system-extension", "opened System Settings fallback")
    }

    func disconnect() {
        Self.eventLogger.append("connection", "manual disconnect requested")
        wantsConnection = false
        invalidateConnectionOperations(reason: "manual disconnect")
        reconnectTask?.cancel(); reconnectTask = nil
        reconnectAttempt = 0
        requiresFreshPathOptimization = false
        tunnelManager?.connection.stopVPNTunnel()
        tickerTask?.cancel()
        tickerTask = nil
        stateSynchronizationTask?.cancel()
        connectionAlert = nil
        connectionError = nil
        resetSessionMetrics()
        stage = .idle
        if !profile.remembersPassword { sessionPassword = "" }
    }

    func saveProfile(to userDefaults: UserDefaults = .standard) {
        profile.authentication = .password
        profile.usesSPA = false
        if profile.server == ConnectionProfile.preview.server {
            profile.verifyServerCertificate = false
        }
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }
        do {
            try LocalCredentialStore.save(
                LocalCredentials(
                    username: profile.username,
                    password: profile.remembersPassword ? sessionPassword : ""
                ),
                profileID: profile.id
            )
            credentialError = nil
        } catch {
            credentialError = error.localizedDescription
        }
        persistProfileMetadata(to: userDefaults)
    }

    func selectProfile(_ id: UUID) {
        guard !isConnected && !isBusy,
              let selected = profiles.first(where: { $0.id == id }) else { return }
        profile = selected
        do {
            let credentials = try LocalCredentialStore.load(profileID: selected.id)
            profile.username = credentials?.username ?? ""
            sessionPassword = credentials?.password ?? ""
            credentialError = nil
        } catch {
            sessionPassword = ""
            credentialError = error.localizedDescription
        }
        UserDefaults.standard.set(id.uuidString, forKey: Self.selectedProfileDefaultsKey)
    }

    func duplicateCurrentProfile() {
        var copy = profile
        copy.id = UUID()
        copy.name = profile.name + " 副本"
        copy.username = ""
        copy.pinnedCertificateSHA256 = ""
        profiles.append(copy)
        profile = copy
        sessionPassword = ""
        saveProfile()
        showingProfileEditor = true
    }

    func deleteCurrentProfile() {
        guard profiles.count > 1, !isConnected && !isBusy else { return }
        let removedID = profile.id
        profiles.removeAll { $0.id == removedID }
        try? LocalCredentialStore.delete(profileID: removedID)
        profile = profiles[0]
        selectProfile(profile.id)
        saveProfile()
    }

    private func persistProfileMetadata(to userDefaults: UserDefaults) {
        var metadata = profile
        metadata.username = ""
        if let data = try? JSONEncoder().encode(metadata) {
            userDefaults.set(data, forKey: Self.profileDefaultsKey)
        }
        let allMetadata = profiles.map { stored -> ConnectionProfile in
            var value = stored
            value.username = ""
            return value
        }
        if let data = try? JSONEncoder().encode(allMetadata) {
            userDefaults.set(data, forKey: Self.profilesDefaultsKey)
            userDefaults.set(profile.id.uuidString, forKey: Self.selectedProfileDefaultsKey)
        }
    }

    private func startTicker() {
        tickerTask?.cancel()
        tickerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                requestRuntimeStats()
                checkProviderLiveness()
            }
        }
    }

    private func loadTunnelManager(adoptSystemIntent: Bool = true) {
        Self.eventLogger.append("configuration", "loading NETunnelProviderManager preferences")
        NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, error in
            let managersBox = UncheckedSendableBox(managers)
            let errorText = error?.localizedDescription
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let errorText {
                    connectionError = errorText
                    Self.eventLogger.append("configuration", errorText)
                    return
                }
                Self.eventLogger.append(
                    "configuration",
                    "loaded \(managersBox.value?.count ?? 0) VPN manager(s)"
                )
                tunnelManager = managersBox.value?.first(where: {
                    ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == Self.providerBundleIdentifier
                })
                tunnelManagerLoaded = true
                if let tunnelManager {
                    Self.eventLogger.append(
                        "configuration",
                        "matched provider manager, status=\(tunnelManager.connection.status.rawValue), enabled=\(tunnelManager.isEnabled)"
                    )
                    if adoptSystemIntent {
                        wantsConnection = tunnelManager.connection.status == .connected
                            || tunnelManager.connection.status == .connecting
                            || tunnelManager.connection.status == .reasserting
                    }
                    applyVPNStatus(tunnelManager.connection.status)
                } else {
                    Self.eventLogger.append("configuration", "no matching provider manager")
                    applyVPNStatus(.invalid)
                }
                restoreConnectionAfterUpdateIfNeeded()
                evaluateAutomaticConnection()
            }
        }
    }

    @discardableResult
    private func beginConnectionOperation() -> UInt64 {
        connectionOperationID &+= 1
        return connectionOperationID
    }

    private func invalidateConnectionOperations(reason: String) {
        connectionOperationID &+= 1
        isStartingTunnel = false
        tunnelStartStatusTask?.cancel(); tunnelStartStatusTask = nil
        Self.eventLogger.append(
            "connection",
            "invalidated pending connection callbacks (\(reason)), operation=\(connectionOperationID)"
        )
    }

    private func connectionOperationIsCurrent(_ operationID: UInt64) -> Bool {
        wantsConnection && operationID == connectionOperationID
    }

    private func configureAndStartVPN(operationID: UInt64) {
        guard connectionOperationIsCurrent(operationID) else {
            Self.eventLogger.append(
                "connection",
                "ignored stale configure request, operation=\(operationID), current=\(connectionOperationID)"
            )
            return
        }
        Self.eventLogger.append(
            "configuration",
            "preparing VPN manager, operation=\(operationID), port \(profile.port), transport=\(profile.dataTransport.rawValue), "
                + "udpPacing=\(profile.udpPacingEnabled), certificateVerification=\(profile.verifyServerCertificate), "
                + "fullTunnel=\(profile.routingMode == .fullTunnel)"
        )
        let manager = tunnelManager ?? NETunnelProviderManager()
        let tunnelProtocol = NETunnelProviderProtocol()
        tunnelProtocol.providerBundleIdentifier = Self.providerBundleIdentifier
        tunnelProtocol.serverAddress = profile.server
        // Keep the client fail-open: only routes installed by a successfully
        // established packet tunnel use the VPN. While disconnected or
        // reconnecting, traffic remains on the Mac's physical interface.
        tunnelProtocol.includeAllNetworks = false
        tunnelProtocol.enforceRoutes = false
        tunnelProtocol.providerConfiguration = [
            "server": profile.server,
            "port": NSNumber(value: profile.port),
            "verifyCertificate": NSNumber(
                value: profile.verifyServerCertificate && profile.server != ConnectionProfile.preview.server
            ),
            "certificatePin": profile.pinnedCertificateSHA256,
            "mtu": NSNumber(value: profile.mtu),
            "automaticMTU": NSNumber(value: profile.automaticMTU),
            "forceFullTunnel": NSNumber(value: profile.routingMode == .fullTunnel),
            "blockIPv6Leaks": NSNumber(value: profile.blockIPv6Leaks),
            "usesTunnelDNS": NSNumber(value: profile.usesTunnelDNS),
            "chinaDirectRouting": NSNumber(value: profile.chinaDirectRouting),
            "udpPacingEnabled": NSNumber(value: profile.udpPacingEnabled),
            "includedIPv4CIDRs": profile.includedIPv4CIDRs,
            "excludedIPv4CIDRs": profile.excludedIPv4CIDRs,
            "dataTransport": (profile.udpPacingEnabled ? ConnectionProfile.DataTransport.udp : profile.dataTransport).rawValue
        ]
        manager.protocolConfiguration = tunnelProtocol
        manager.localizedDescription = profile.name
        manager.isEnabled = true
        stage = .securingControlChannel
        isStartingTunnel = true
        let managerBox = UncheckedSendableBox(manager)
        manager.saveToPreferences { [weak self, managerBox] error in
            let errorText = error?.localizedDescription
            Task { @MainActor [weak self, managerBox] in
                guard let self else { return }
                guard connectionOperationIsCurrent(operationID) else {
                    Self.eventLogger.append(
                        "connection",
                        "ignored stale save callback, operation=\(operationID), current=\(connectionOperationID)"
                    )
                    return
                }
                let manager = managerBox.value
                if let errorText {
                    Self.eventLogger.append("configuration", "saveToPreferences failed: \(errorText)")
                    isStartingTunnel = false
                    failConnectionMessage(errorText, requiresUserAction: connectionWasUserInitiated)
                    return
                }
                Self.eventLogger.append("configuration", "saveToPreferences completed")
                manager.loadFromPreferences { [weak self, managerBox] error in
                    let errorText = error?.localizedDescription
                    Task { @MainActor [weak self, managerBox] in
                        guard let self else { return }
                        guard connectionOperationIsCurrent(operationID) else {
                            Self.eventLogger.append(
                                "connection",
                                "ignored stale load callback, operation=\(operationID), current=\(connectionOperationID)"
                            )
                            return
                        }
                        let manager = managerBox.value
                        if let errorText {
                            Self.eventLogger.append("configuration", "loadFromPreferences failed: \(errorText)")
                            isStartingTunnel = false
                            failConnectionMessage(errorText, requiresUserAction: connectionWasUserInitiated)
                            return
                        }
                        Self.eventLogger.append("configuration", "loadFromPreferences completed; invoking startVPNTunnel")
                        tunnelManager = manager
                        do {
                            guard connectionOperationIsCurrent(operationID) else {
                                Self.eventLogger.append(
                                    "connection",
                                    "cancelled stale tunnel start, operation=\(operationID), current=\(connectionOperationID)"
                                )
                                return
                            }
                            try manager.connection.startVPNTunnel(options: [
                                "username": profile.username as NSString,
                                "password": sessionPassword as NSString,
                                "refreshPathOptimization": NSNumber(value: requiresFreshPathOptimization)
                            ])
                            Self.eventLogger.append(
                                "connection",
                                "startVPNTunnel returned without throwing, operation=\(operationID)"
                            )
                            // startVPNTunnel can be followed by a stale
                            // .disconnected value from a concurrent manager
                            // reload. Keep the start guard until NetworkExtension
                            // reports .connecting/.connected, then expire it if
                            // no status transition arrives.
                            scheduleTunnelStartStatusCheck(operationID: operationID)
                            stage = .securingControlChannel
                        } catch {
                            Self.eventLogger.append("connection", "startVPNTunnel threw: \(error.localizedDescription)")
                            isStartingTunnel = false
                            failConnection(error)
                        }
                    }
                }
            }
        }
    }

    private func applyVPNStatus(_ status: NEVPNStatus) {
        Self.eventLogger.append("provider", "NEVPN status \(status.rawValue)")
        switch status {
        case .invalid, .disconnected:
            tickerTask?.cancel(); tickerTask = nil
            resetSessionMetrics()
            if !pathIsSatisfied {
                reconnectTask?.cancel(); reconnectTask = nil
                connectionError = nil
                stage = .idle
            } else if wantsConnection && isStartingTunnel {
                // save/load/activation can legitimately observe the old
                // manager as disconnected. Keep the current attempt alive.
                stage = .securingControlChannel
            } else if wantsConnection && profile.automaticallyReconnects && !isStartingTunnel {
                captureLastDisconnectError()
                scheduleReconnect(reason: "provider disconnected")
            } else {
                stage = .idle; routeCount = 0
                excludedRouteCount = 0; chinaDirectRoutingActive = false
            }
        case .connecting:
            tunnelStartStatusTask?.cancel(); tunnelStartStatusTask = nil
            isStartingTunnel = false
            guard wantsConnection else {
                Self.eventLogger.append("connection", "stopping unexpected connecting tunnel after cancellation")
                tunnelManager?.connection.stopVPNTunnel()
                stage = .idle
                return
            }
            stage = .securingControlChannel
        case .connected:
            tunnelStartStatusTask?.cancel(); tunnelStartStatusTask = nil
            isStartingTunnel = false
            guard wantsConnection else {
                Self.eventLogger.append("connection", "stopping unexpected connected tunnel after cancellation")
                tunnelManager?.connection.stopVPNTunnel()
                stage = .idle
                return
            }
            reconnectTask?.cancel(); reconnectTask = nil
            // NEVPNStatus.connected can arrive before the provider's
            // startTunnel completion and can therefore be followed by an
            // immediate establishment error. Keep showing the handshake state
            // until the provider confirms that routes and the data channel are
            // actually active through its runtime snapshot.
            if stage != .connected { stage = .securingControlChannel }
            lastProviderResponseAt = Date()
            if tickerTask == nil { startTicker() }
            requestRuntimeStats()
        case .reasserting:
            tunnelStartStatusTask?.cancel(); tunnelStartStatusTask = nil
            isStartingTunnel = false
            zeroLiveRates()
            stage = .reconnecting
        case .disconnecting:
            tunnelStartStatusTask?.cancel(); tunnelStartStatusTask = nil
            isStartingTunnel = false
            zeroLiveRates()
            stage = wantsConnection ? .reconnecting : .idle
        @unknown default: stage = .failed
        }
    }

    private func requestRuntimeStats() {
        guard let session = tunnelManager?.connection as? NETunnelProviderSession,
              session.status == .connected else { return }
        do {
            try session.sendProviderMessage(Data("stats".utf8)) { [weak self] data in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    guard let data,
                          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                        return
                    }
                    let sent = (object["sent"] as? NSNumber)?.uint64Value ?? 0
                    let received = (object["received"] as? NSNumber)?.uint64Value ?? 0
                    let wireSent = (object["wireSent"] as? NSNumber)?.uint64Value ?? 0
                    let wireReceived = (object["wireReceived"] as? NSNumber)?.uint64Value ?? 0
                    let now = Date()
                    lastProviderResponseAt = now
                    providerRecoveryInProgress = false
                    let physical = Self.interfaceCounters(named: physicalInterfaceName)
                    if let sample = lastStatsSample, let physical {
                        let interval = max(now.timeIntervalSince(sample.date), 0.1)
                        uploadBytesPerSecond = UInt64(Double(sent >= sample.sent ? sent - sample.sent : 0) / interval)
                        downloadBytesPerSecond = UInt64(Double(received >= sample.received ? received - sample.received : 0) / interval)
                        if chinaDirectRoutingActive {
                            let physicalSentDelta = physical.sent >= sample.physicalSent
                                ? physical.sent - sample.physicalSent : 0
                            let physicalReceivedDelta = physical.received >= sample.physicalReceived
                                ? physical.received - sample.physicalReceived : 0
                            let wireSentDelta = wireSent >= sample.wireSent ? wireSent - sample.wireSent : 0
                            let wireReceivedDelta = wireReceived >= sample.wireReceived
                                ? wireReceived - sample.wireReceived : 0
                            let directSentDelta = physicalSentDelta > wireSentDelta
                                ? physicalSentDelta - wireSentDelta : 0
                            let directReceivedDelta = physicalReceivedDelta > wireReceivedDelta
                                ? physicalReceivedDelta - wireReceivedDelta : 0
                            directBytesSent += directSentDelta
                            directBytesReceived += directReceivedDelta
                            directUploadBytesPerSecond = UInt64(Double(directSentDelta) / interval)
                            directDownloadBytesPerSecond = UInt64(Double(directReceivedDelta) / interval)
                        } else {
                            directUploadBytesPerSecond = 0
                            directDownloadBytesPerSecond = 0
                        }
                    }
                    if let physical {
                        lastStatsSample = (
                            sent, received, wireSent, wireReceived,
                            physical.sent, physical.received, now
                        )
                    } else {
                        lastStatsSample = nil
                    }
                    bytesSent = sent
                    bytesReceived = received
                    packetsSent = (object["sentPackets"] as? NSNumber)?.uint64Value ?? 0
                    packetsReceived = (object["receivedPackets"] as? NSNumber)?.uint64Value ?? 0
                    droppedPackets = (object["droppedPackets"] as? NSNumber)?.uint64Value ?? 0
                    elapsedSeconds = (object["duration"] as? NSNumber)?.intValue ?? 0
                    routeCount = (object["routeCount"] as? NSNumber)?.intValue ?? 0
                    excludedRouteCount = (object["excludedRouteCount"] as? NSNumber)?.intValue ?? 0
                    chinaDirectRoutingActive = (object["chinaDirectRouting"] as? NSNumber)?.boolValue ?? false
                    heartbeatRTTMilliseconds = (object["heartbeatRTTMs"] as? NSNumber)?.intValue
                    heartbeatAgeSeconds = (object["heartbeatAgeSeconds"] as? NSNumber)?.intValue
                    heartbeatJitterMilliseconds = (object["heartbeatJitterMs"] as? NSNumber)?.doubleValue ?? 0
                    heartbeatLossPercent = (object["heartbeatLossPercent"] as? NSNumber)?.doubleValue ?? 0
                    averageEncryptionMicroseconds = (object["averageEncryptionMicroseconds"] as? NSNumber)?.doubleValue ?? 0
                    activeMTU = (object["mtu"] as? NSNumber)?.intValue ?? activeMTU
                    activeDataTransport = object["dataTransport"] as? String ?? activeDataTransport
                    udpPacingActive = (object["udpPacingActive"] as? NSNumber)?.boolValue ?? false
                    udpPacingRateMbps = (object["udpPacingRateMbps"] as? NSNumber)?.intValue ?? 0
                    udpPacingQueueDelayMilliseconds = (object["udpPacingQueueDelayMs"] as? NSNumber)?.doubleValue ?? 0
                    pathProbeStatus = object["pathProbeStatus"] as? String ?? "未运行"
                    pathProbeRTTMilliseconds = (object["pathProbeRTTMs"] as? NSNumber)?.intValue
                    espLossPercent = (object["espLossPercent"] as? NSNumber)?.doubleValue ?? 0
                    espReorderPercent = (object["espReorderPercent"] as? NSNumber)?.doubleValue ?? 0
                    espDuplicatePackets = (object["espDuplicatePackets"] as? NSNumber)?.uint64Value ?? 0
                    if let rawNetwork = object["networkKind"] as? String,
                       let kind = UnderlyingNetworkKind(rawValue: rawNetwork) {
                        underlyingNetwork = kind
                    }
                    activeRoutes = object["routes"] as? [String] ?? []
                    dnsServers = object["dnsServers"] as? [String] ?? []
                    let providerReady = (object["ready"] as? NSNumber)?.boolValue ?? false
                    if providerReady, routeCount > 0, !activeDataTransport.isEmpty {
                        markProviderReady()
                    }
                    if let fingerprint = object["certificateFingerprint"] as? String,
                       !fingerprint.isEmpty {
                        certificateFingerprint = fingerprint
                        if profile.pinnedCertificateSHA256.isEmpty {
                            profile.pinnedCertificateSHA256 = fingerprint
                            saveProfile()
                        }
                    }
                }
            }
        } catch {
            Self.eventLogger.append("statistics", "provider message failed: \(error.localizedDescription)")
            checkProviderLiveness()
        }
    }

    private func failConnection(_ error: Error) {
        guard pathIsSatisfied, !Self.isRoutineNetworkDisconnect(error) else {
            connectionError = nil
            stage = .idle
            Self.eventLogger.append("network", "connection stopped because the network is unavailable")
            if pathIsSatisfied && wantsConnection && profile.automaticallyReconnects {
                scheduleReconnect(reason: "transient network error")
            }
            return
        }
        let message = Self.friendlyDisconnectMessage(
            error,
            udpPacingEnabled: profile.udpPacingEnabled
        )
        let needsAttention = Self.requiresImmediateAttention(error)
        connectionError = message
        Self.eventLogger.append("error", message)
        stage = .failed
        if connectionWasUserInitiated && needsAttention {
            connectionAlert = message
        }
        connectionWasUserInitiated = false
        if needsAttention {
            wantsConnection = false
            reconnectTask?.cancel(); reconnectTask = nil
        } else if wantsConnection && profile.automaticallyReconnects {
            scheduleReconnect(reason: "connection failure")
        }
    }

    private func failConnectionMessage(_ message: String, requiresUserAction: Bool = false) {
        guard pathIsSatisfied else {
            connectionError = nil
            stage = .idle
            Self.eventLogger.append("network", "connection stopped because the network is unavailable")
            return
        }
        connectionError = message
        Self.eventLogger.append("error", message)
        stage = .failed
        if requiresUserAction && connectionWasUserInitiated {
            connectionAlert = message
        }
        connectionWasUserInitiated = false
        if requiresUserAction {
            wantsConnection = false
            reconnectTask?.cancel(); reconnectTask = nil
        } else if wantsConnection && profile.automaticallyReconnects {
            scheduleReconnect(reason: "configuration failure")
        }
    }

    static func reconnectDelayMilliseconds(forAttempt attempt: Int, fastFirstAttempt: Bool = false) -> Int {
        if fastFirstAttempt && attempt <= 1 { return 1_500 }
        // Give transient failures three quick retries. A persistent gateway or
        // UDP-path failure then backs off aggressively instead of cycling the
        // System Extension several times per second.
        let delays = [500, 1_000, 2_000, 30_000, 60_000]
        return delays[min(max(attempt - 1, 0), delays.count - 1)]
    }

    static func dataTransportAfterTogglingUDPPacing(
        enabled: Bool,
        current: ConnectionProfile.DataTransport
    ) -> ConnectionProfile.DataTransport {
        if enabled { return .udp }
        return current == .udp ? .automatic : current
    }

    private func scheduleReconnect(reason: String, fastFirstAttempt: Bool = false) {
        guard reconnectTask == nil, wantsConnection, profile.automaticallyReconnects,
              pathIsSatisfied, !isStartingTunnel else { return }
        reconnectAttempt += 1
        reconnectCount += 1
        stage = .reconnecting
        let delayMilliseconds = Self.reconnectDelayMilliseconds(
            forAttempt: reconnectAttempt,
            fastFirstAttempt: fastFirstAttempt
        )
        let delaySeconds = String(format: "%.2f", Double(delayMilliseconds) / 1_000)
        Self.eventLogger.append(
            "reconnect",
            "attempt \(reconnectAttempt), delay \(delaySeconds)s, reason=\(reason)"
        )
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(delayMilliseconds))
            guard let self, !Task.isCancelled, self.wantsConnection,
                  self.pathIsSatisfied, !self.isStartingTunnel else { return }
            self.reconnectTask = nil
            let currentStatus = self.tunnelManager?.connection.status ?? .invalid
            guard currentStatus == .invalid || currentStatus == .disconnected else {
                Self.eventLogger.append(
                    "reconnect",
                    "waiting for previous tunnel cleanup, status=\(currentStatus.rawValue)"
                )
                self.tunnelManager?.connection.stopVPNTunnel()
                self.scheduleReconnect(reason: "waiting for previous tunnel cleanup")
                return
            }
            self.connectionError = nil
            self.stage = .discovering
            // Re-run System Extension activation before every retry. This is
            // normally a fast no-op, but after an in-place app upgrade it is
            // what replaces the previously registered provider before the
            // VPN session starts again.
            self.activateSystemExtensionAndStart(operationID: self.beginConnectionOperation())
        }
    }

    private func consumeSystemPath(_ path: NWPath) {
        let wasSatisfied = pathIsSatisfied
        pathIsSatisfied = path.status == .satisfied
        let interfaceType: NWInterface.InterfaceType?
        if path.usesInterfaceType(.wiredEthernet) {
            underlyingNetwork = .wiredEthernet; interfaceType = .wiredEthernet
        } else if path.usesInterfaceType(.wifi) {
            underlyingNetwork = .wiFi; interfaceType = .wifi
        } else if path.usesInterfaceType(.cellular) {
            underlyingNetwork = .cellular; interfaceType = .cellular
        } else {
            underlyingNetwork = .other; interfaceType = nil
        }
        physicalInterfaceName = interfaceType.flatMap { type in
            path.availableInterfaces.first(where: { $0.type == type })?.name
        }
        Self.eventLogger.append(
            "network",
            "path \(pathIsSatisfied ? "satisfied" : "unavailable"), interface \(underlyingNetwork.title)"
        )
        lastStatsSample = nil
        guard pathIsSatisfied else {
            if wasSatisfied {
                invalidateConnectionOperations(reason: "network unavailable")
                reconnectTask?.cancel(); reconnectTask = nil
                reconnectAttempt = 0
                requiresFreshPathOptimization = true
                tickerTask?.cancel(); tickerTask = nil
                connectionError = nil
                zeroLiveRates()
                stage = .idle
                let currentStatus = tunnelManager?.connection.status ?? .invalid
                if currentStatus != .invalid && currentStatus != .disconnected {
                    Self.eventLogger.append(
                        "network",
                        "stopping tunnel to release routes and DNS, status=\(currentStatus.rawValue)"
                    )
                    tunnelManager?.connection.stopVPNTunnel()
                }
                if !profile.automaticallyReconnects { wantsConnection = false }
            }
            return
        }
        if !wasSatisfied {
            lastProviderResponseAt = Date()
            scheduleStateSynchronization(delays: [.zero, .seconds(1), .seconds(3)])
            if wantsConnection && profile.automaticallyReconnects {
                scheduleReconnect(reason: "network restored", fastFirstAttempt: true)
            }
        }
        restoreConnectionAfterUpdateIfNeeded()
        evaluateAutomaticConnection()
    }

    private func restoreConnectionAfterUpdateIfNeeded() {
        guard shouldReconnectAfterUpdate, pathIsSatisfied, tunnelManagerLoaded,
              !isConnected, !isBusy, hasCredentials else { return }
        shouldReconnectAfterUpdate = false
        Self.eventLogger.append("update", "restoring connection that was active before installation")
        connect(userInitiated: false)
    }

    private func observeSystemLifecycle() {
        let workspaceNotifications = NSWorkspace.shared.notificationCenter
        lifecycleObservers.append(workspaceNotifications.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.prepareForSystemSleep() }
        })
        lifecycleObservers.append(workspaceNotifications.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.resumeAfterSystemWake() }
        })
        lifecycleObservers.append(workspaceNotifications.addObserver(
            forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.prepareForPowerOff() }
        })
        lifecycleObservers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scheduleStateSynchronization(delays: [.zero, .seconds(1)])
            }
        })
    }

    private func prepareForSystemSleep() {
        reconnectTask?.cancel(); reconnectTask = nil
        reconnectAttempt = 0
        tickerTask?.cancel(); tickerTask = nil
        stateSynchronizationTask?.cancel(); stateSynchronizationTask = nil
        zeroLiveRates()
        lastStatsSample = nil
        lastProviderResponseAt = nil
        if wantsConnection { stage = .reconnecting }
    }

    private func resumeAfterSystemWake() {
        zeroLiveRates()
        lastStatsSample = nil
        lastProviderResponseAt = Date()
        scheduleStateSynchronization(delays: [.zero, .seconds(1), .seconds(3)])
    }

    private func prepareForPowerOff() {
        wantsConnection = false
        invalidateConnectionOperations(reason: "system power off")
        reconnectTask?.cancel(); reconnectTask = nil
        tickerTask?.cancel(); tickerTask = nil
        stateSynchronizationTask?.cancel(); stateSynchronizationTask = nil
        resetSessionMetrics()
        stage = .idle
    }

    private func scheduleStateSynchronization(delays: [Duration]) {
        stateSynchronizationTask?.cancel()
        stateSynchronizationTask = Task { [weak self] in
            for delay in delays {
                if delay != .zero { try? await Task.sleep(for: delay) }
                guard let self, !Task.isCancelled else { return }
                self.loadTunnelManager(adoptSystemIntent: false)
            }
            self?.stateSynchronizationTask = nil
        }
    }

    private func scheduleTunnelStartStatusCheck(operationID: UInt64) {
        tunnelStartStatusTask?.cancel()
        tunnelStartStatusTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, !Task.isCancelled,
                  self.connectionOperationIsCurrent(operationID),
                  self.isStartingTunnel else { return }
            self.isStartingTunnel = false
            self.tunnelStartStatusTask = nil
            Self.eventLogger.append(
                "connection",
                "start status grace expired; reloading manager, operation=\(operationID)"
            )
            self.loadTunnelManager(adoptSystemIntent: false)
        }
    }

    private func checkProviderLiveness() {
        guard pathIsSatisfied, wantsConnection,
              tunnelManager?.connection.status == .connected,
              !providerRecoveryInProgress,
              let lastProviderResponseAt,
              Date().timeIntervalSince(lastProviderResponseAt) >= 10 else { return }
        providerRecoveryInProgress = true
        invalidateConnectionOperations(reason: "provider liveness recovery")
        connectionError = "VPN 隧道长时间未响应，正在重新同步连接状态。"
        Self.eventLogger.append("recovery", connectionError ?? "provider liveness timeout")
        zeroLiveRates()
        stage = .reconnecting
        tunnelManager?.connection.stopVPNTunnel()
        scheduleStateSynchronization(delays: [.seconds(1), .seconds(3)])
    }

    private func zeroLiveRates() {
        downloadBytesPerSecond = 0
        uploadBytesPerSecond = 0
        directDownloadBytesPerSecond = 0
        directUploadBytesPerSecond = 0
    }

    private func resetSessionMetrics() {
        elapsedSeconds = 0
        routeCount = 0
        excludedRouteCount = 0
        chinaDirectRoutingActive = false
        bytesReceived = 0
        bytesSent = 0
        zeroLiveRates()
        directBytesReceived = 0
        directBytesSent = 0
        packetsReceived = 0
        packetsSent = 0
        droppedPackets = 0
        heartbeatRTTMilliseconds = nil
        heartbeatAgeSeconds = nil
        heartbeatJitterMilliseconds = 0
        heartbeatLossPercent = 0
        averageEncryptionMicroseconds = 0
        activeDataTransport = ""
        udpPacingActive = false
        udpPacingRateMbps = 0
        udpPacingQueueDelayMilliseconds = 0
        pathProbeStatus = "未运行"
        pathProbeRTTMilliseconds = nil
        espLossPercent = 0
        espReorderPercent = 0
        espDuplicatePackets = 0
        activeRoutes = []
        dnsServers = []
        certificateFingerprint = ""
        lastStatsSample = nil
        lastProviderResponseAt = nil
        providerRecoveryInProgress = false
    }

    private static func interfaceCounters(named interfaceName: String?) -> (sent: UInt64, received: UInt64)? {
        guard let interfaceName else { return nil }
        var firstAddress: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&firstAddress) == 0, let firstAddress else { return nil }
        defer { freeifaddrs(firstAddress) }
        var current: UnsafeMutablePointer<ifaddrs>? = firstAddress
        while let address = current {
            let item = address.pointee
            if String(cString: item.ifa_name) == interfaceName,
               item.ifa_addr?.pointee.sa_family == UInt8(AF_LINK),
               let rawData = item.ifa_data {
                let data = rawData.assumingMemoryBound(to: if_data.self).pointee
                return (UInt64(data.ifi_obytes), UInt64(data.ifi_ibytes))
            }
            current = item.ifa_next
        }
        return nil
    }

    private func evaluateAutomaticConnection() {
        guard pathIsSatisfied, tunnelManagerLoaded, !wantsConnection,
              !isConnected, !isBusy, hasCredentials else { return }
        let shouldConnect = (underlyingNetwork == .wiFi && profile.connectsOnWiFi)
            || (underlyingNetwork == .wiredEthernet && profile.connectsOnEthernet)
        if shouldConnect { connect(userInitiated: false) }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            profile.launchesAtLogin = enabled
            loginItemError = nil
            saveProfile()
        } catch {
            profile.launchesAtLogin = SMAppService.mainApp.status == .enabled
            loginItemError = error.localizedDescription
        }
    }

    private func captureLastDisconnectError() {
        tunnelManager?.connection.fetchLastDisconnectError { [weak self] error in
            guard let error else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.pathIsSatisfied, !Self.isRoutineNetworkDisconnect(error) else {
                    Self.eventLogger.append("network", "routine offline disconnect suppressed")
                    self.connectionError = nil
                    if !self.pathIsSatisfied { self.stage = .idle }
                    return
                }
                let message = Self.friendlyDisconnectMessage(error)
                Self.eventLogger.append("error", message)
                self.connectionError = message
                if Self.requiresImmediateAttention(error) {
                    self.wantsConnection = false
                    self.reconnectTask?.cancel(); self.reconnectTask = nil
                    self.stage = .failed
                    if self.connectionWasUserInitiated {
                        self.connectionAlert = message
                    }
                    self.connectionWasUserInitiated = false
                }
            }
        }
    }

    static func isRoutineNetworkDisconnect(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NEVPNConnectionErrorDomain, nsError.code == 2 || nsError.code == 3 {
            return true
        }
        let message = nsError.localizedDescription.lowercased()
        return [
            "network is unreachable", "network is down", "network connection was lost",
            "not connected to the internet", "internet connection appears to be offline",
            "no network", "没有可用网络", "网络连接已中断", "未连接到互联网"
        ].contains { message.contains($0) }
    }

    static func friendlyDisconnectMessage(
        _ error: Error,
        udpPacingEnabled: Bool = false
    ) -> String {
        let nsError = error as NSError
        if nsError.domain == NEVPNConnectionErrorDomain {
            switch nsError.code {
            case 2: return "当前没有可用网络，恢复联网后将自动重连。"
            case 3: return "Wi-Fi 或有线网络发生变化，正在重新建立隧道。"
            case 5: return "无法解析 VPN 网关地址。"
            case 6, 7: return "VPN 网关没有响应，请检查网络或服务器状态。"
            case 8: return "用户名或密码被网关拒绝。"
            case 12, 14: return "VPN 数据通道扩展无法运行，请重新安装最新版。"
            case 15: return "VPN 协议协商失败，请查看诊断信息。"
            case 16: return "VPN 网关主动断开了连接。"
            case 17, 18, 19: return "VPN 网关证书验证失败。"
            default: break
            }
        }
        if nsError.domain.contains("HillstonePacketTunnel") {
            if udpPacingEnabled {
                return "UDP 数据通道连续探测未收到响应；手机热点可能限制 UDP。请关闭“UDP Pacing 加速”切换到自动/TCP；正在低频重试，本机网络未被接管。"
            }
            return "VPN 数据通道未通过可达性检查，正在重试；本机网络未被接管。"
        }
        let message = nsError.localizedDescription
        let lower = message.lowercased()
        if lower.contains("certificate") || message.contains("证书") { return "VPN 网关证书或证书指纹不匹配。" }
        if lower.contains("authentication") || message.contains("密码") || message.contains("认证") { return "用户名或密码验证失败。" }
        if lower.contains("udp") || lower.contains("tcp") || message.contains("数据通道") {
            return "TLS 登录成功，但 VPN 数据通道不可达。"
        }
        if lower.contains("timed out") || message.contains("超时") { return "VPN 网关响应超时。" }
        return message
    }

    private func markProviderReady() {
        guard wantsConnection,
              tunnelManager?.connection.status == .connected else { return }
        let wasReady = stage == .connected
        reconnectTask?.cancel(); reconnectTask = nil
        reconnectAttempt = 0
        requiresFreshPathOptimization = false
        stage = .connected
        providerRecoveryInProgress = false
        connectionError = nil
        connectionAlert = nil
        connectionWasUserInitiated = false
        if !wasReady {
            Self.eventLogger.append(
                "provider",
                "runtime readiness confirmed; transport=\(activeDataTransport), routes=\(routeCount)"
            )
        }
    }

    private static func requiresImmediateAttention(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NEVPNConnectionErrorDomain {
            return [8, 12, 14, 15, 17, 18, 19].contains(nsError.code)
        }
        let message = nsError.localizedDescription.lowercased()
        return message.contains("authentication")
            || message.contains("certificate")
            || message.contains("extension")
            || message.contains("密码")
            || message.contains("认证")
            || message.contains("证书")
            || message.contains("扩展")
    }

    func setConnectionNotifications(_ enabled: Bool) {
        profile.connectionNotifications = enabled
        saveProfile()
        guard enabled else {
            settingsError = nil
            return
        }
        Task {
            do {
                let granted = try await UNUserNotificationCenter.current()
                    .requestAuthorization(options: [.alert, .sound])
                if !granted {
                    settingsError = "系统通知未获授权，可在“系统设置 → 通知”中开启。"
                } else {
                    settingsError = nil
                }
            } catch {
                settingsError = "无法申请通知权限：\(error.localizedDescription)"
            }
        }
    }

    private func recordStageTransition(from previous: SessionStage) {
        Self.eventLogger.append("state", "\(previous.title) -> \(stage.title)")
        guard profile.connectionNotifications else { return }
        let body: String?
        switch stage {
        case .connected:
            incidentNotificationSent = false
            body = "公司网络已连接。"
        case .failed where !incidentNotificationSent:
            incidentNotificationSent = true
            body = connectionError ?? "连接失败，请打开诊断页面查看详情。"
        case .reconnecting where previous == .connected && !incidentNotificationSent:
            incidentNotificationSent = true
            body = "连接已中断，正在自动重连。"
        default:
            body = nil
        }
        guard let body else { return }
        Task {
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            if settings.authorizationStatus == .notDetermined {
                guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
            } else if settings.authorizationStatus != .authorized
                        && settings.authorizationStatus != .provisional {
                return
            }
            let content = UNMutableNotificationContent()
            content.title = "NLVC VPN"
            content.body = body
            content.sound = .default
            let request = UNNotificationRequest(
                identifier: "nlvc-\(UUID().uuidString)", content: content, trigger: nil
            )
            try? await center.add(request)
        }
    }

    func checkForUpdates(automatic: Bool = false) {
        guard !isCheckingForUpdates else { return }
        if automatic,
           let lastCheck = UserDefaults.standard.object(forKey: Self.lastAutomaticUpdateCheckKey) as? Date,
           Date().timeIntervalSince(lastCheck) < 24 * 60 * 60 {
            return
        }
        guard let value = Bundle.main.object(forInfoDictionaryKey: "NLVCUpdateManifestURL") as? String,
              let url = URL(string: value),
              url.scheme?.lowercased() == "https",
              !value.isEmpty else {
            if !automatic { updateStatus = "尚未配置更新清单地址" }
            return
        }
        isCheckingForUpdates = true
        if automatic { UserDefaults.standard.set(Date(), forKey: Self.lastAutomaticUpdateCheckKey) }
        updateStatus = "正在检查…"
        Task { [weak self] in
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                    throw URLError(.badServerResponse)
                }
                let manifest = try JSONDecoder().decode(UpdateManifest.self, from: data)
                guard manifest.sha256.count == 64,
                      manifest.sha256.allSatisfy(\.isHexDigit),
                      let downloadURL = URL(string: manifest.downloadURL),
                      downloadURL.scheme?.lowercased() == "https" else {
                    throw UpdateError.invalidManifest
                }
                let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
                await MainActor.run {
                    guard let self else { return }
                    if manifest.version.compare(current, options: .numeric) == .orderedDescending {
                        self.availableUpdateURL = downloadURL
                        self.availableUpdateSHA256 = manifest.sha256.lowercased()
                        self.availableUpdateVersion = manifest.version
                        self.updateStatus = "发现新版本 \(manifest.version)"
                    } else {
                        self.availableUpdateURL = nil
                        self.availableUpdateSHA256 = ""
                        self.availableUpdateVersion = ""
                        self.updateStatus = "已是最新版本 \(current)"
                    }
                    self.isCheckingForUpdates = false
                }
            } catch {
                await MainActor.run {
                    self?.updateStatus = "检查失败：\(error.localizedDescription)"
                    self?.isCheckingForUpdates = false
                }
            }
        }
    }

    func downloadAndInstallAvailableUpdate() {
        guard !isDownloadingUpdate, let availableUpdateURL,
              !availableUpdateSHA256.isEmpty else { return }
        isDownloadingUpdate = true
        updateStatus = "正在下载 \(availableUpdateVersion)…"
        Task { [weak self] in
            guard let self else { return }
            do {
                let (temporaryURL, response) = try await URLSession.shared.download(from: availableUpdateURL)
                guard let response = response as? HTTPURLResponse,
                      response.statusCode == 200 else { throw URLError(.badServerResponse) }
                let extensionName = availableUpdateURL.pathExtension.lowercased()
                guard extensionName == "pkg" || extensionName == "zip" else {
                    throw UpdateError.unsupportedPackage
                }
                let digest = try Self.sha256(of: temporaryURL)
                guard digest == self.availableUpdateSHA256 else { throw UpdateError.checksumMismatch }

                let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("NLVC VPN/Updates", isDirectory: true)
                try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
                let filename = "NLVC-VPN-\(self.availableUpdateVersion).\(extensionName)"
                let destination = support.appendingPathComponent(filename)
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: temporaryURL, to: destination)
                Self.eventLogger.append("update", "downloaded and verified version \(self.availableUpdateVersion)")
                await MainActor.run {
                    self.isDownloadingUpdate = false
                    self.updateStatus = "校验完成，正在打开安装包"
                    NSWorkspace.shared.open(destination)
                }
            } catch {
                Self.eventLogger.append("update-error", error.localizedDescription)
                await MainActor.run {
                    self.isDownloadingUpdate = false
                    self.updateStatus = "更新失败：\(error.localizedDescription)"
                }
            }
        }
    }

    private nonisolated static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1_048_576) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func rateText(_ bytesPerSecond: UInt64) -> String {
        let bytes = Double(bytesPerSecond)
        if bytes < 1_000_000 {
            let kilobytes = bytes / 1_000
            let precision = kilobytes < 10 ? 1 : 0
            return String(format: "%.*f KB/s", precision, kilobytes)
        }
        if bytes < 1_000_000_000 {
            let megabytes = bytes / 1_000_000
            let precision = megabytes < 10 ? 1 : 0
            return String(format: "%.*f MB/s", precision, megabytes)
        }
        let gigabytes = bytes / 1_000_000_000
        return String(format: gigabytes < 10 ? "%.1f GB/s" : "%.0f GB/s", gigabytes)
    }

    private struct UpdateManifest: Decodable {
        let version: String
        let downloadURL: String
        let sha256: String
    }

    private var diagnosticReport: String {
        let heartbeat = heartbeatRTTMilliseconds.map { "\($0) ms" } ?? "尚未收到"
        return """
        NLVC VPN 诊断
        状态：\(stage.title)
        持续：\(elapsedSeconds) 秒
        路由：\(routeCount) 条
        DNS：\(dnsServers.count) 个
        VPN 上传：\(bytesSent) 字节（\(packetsSent) 包）
        VPN 下载：\(bytesReceived) 字节（\(packetsReceived) 包）
        直连上传（估算）：\(directBytesSent) 字节
        直连下载（估算）：\(directBytesReceived) 字节
        丢弃：\(droppedPackets) 包
        心跳延迟：\(heartbeat)
        自动重连：\(reconnectCount) 次
        UDP Pacing：\(udpPacingActive ? "已启用（\(udpPacingRateMbps) Mbps）" : "未启用")
        Pacing 队列延迟：\(String(format: "%.2f ms", udpPacingQueueDelayMilliseconds))
        路径 MTU 探测：\(pathProbeStatus)\(pathProbeRTTMilliseconds.map { "（\($0) ms）" } ?? "")
        ESP 估算丢包：\(String(format: "%.2f%%", espLossPercent))
        ESP 乱序：\(String(format: "%.2f%%", espReorderPercent))
        ESP 重复包：\(espDuplicatePackets)
        证书指纹：\(certificateFingerprint.isEmpty ? "尚未固定" : certificateFingerprint)

        最近连接事件：
        \(Self.eventLogger.tail())
        """
    }

    func copyDiagnostics() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(diagnosticReport, forType: .string)
    }

    func exportDiagnostics() {
        let panel = NSSavePanel()
        panel.title = "导出诊断报告"
        panel.nameFieldStringValue = "NLVC-VPN-诊断.txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try diagnosticReport.write(to: url, atomically: true, encoding: .utf8)
            diagnosticsMessage = "诊断报告已导出。"
        } catch {
            diagnosticsMessage = "无法导出诊断报告：\(error.localizedDescription)"
        }
    }

    func revealConnectionLog() {
        let url = Self.eventLogger.logURL
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            diagnosticsMessage = "连接日志尚未生成。"
        }
    }
}
