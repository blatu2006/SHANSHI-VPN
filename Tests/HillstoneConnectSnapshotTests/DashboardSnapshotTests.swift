import AppKit
import CryptoKit
import NetworkExtension
import SwiftUI
import Testing
@testable import HillstoneConnect

@Test
func localCredentialsAreEncryptedAndRoundTrip() throws {
    let credentials = LocalCredentials(username: "vpn-user", password: "vpn-password")
    let key = SymmetricKey(size: .bits256)
    let encrypted = try LocalCredentialStore.encrypt(credentials, using: key)

    #expect(encrypted.range(of: Data(credentials.username.utf8)) == nil)
    #expect(encrypted.range(of: Data(credentials.password.utf8)) == nil)
    #expect(try LocalCredentialStore.decrypt(encrypted, using: key) == credentials)
}

@Test
func localCredentialKeyCanBeCreatedOnDisk() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("nlvc-credential-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let keyURL = directory.appendingPathComponent("credentials.key")
    _ = try LocalCredentialStore.createKey(at: keyURL)

    let data = try Data(contentsOf: keyURL)
    #expect(data.count == 32)
    let permissions = try FileManager.default.attributesOfItem(atPath: keyURL.path)[.posixPermissions] as? NSNumber
    #expect(permissions?.intValue == 0o600)
}

@Test @MainActor
func routineOfflineDisconnectsDoNotRequireAnAlert() {
    let noNetwork = NSError(domain: NEVPNConnectionErrorDomain, code: 2)
    let networkChanged = NSError(domain: NEVPNConnectionErrorDomain, code: 3)
    let authenticationFailure = NSError(domain: NEVPNConnectionErrorDomain, code: 8)

    #expect(AppModel.isRoutineNetworkDisconnect(noNetwork))
    #expect(AppModel.isRoutineNetworkDisconnect(networkChanged))
    #expect(!AppModel.isRoutineNetworkDisconnect(authenticationFailure))
}

@Test @MainActor
func reconnectBackoffStartsFastAndRemainsBounded() {
    #expect(AppModel.reconnectDelayMilliseconds(forAttempt: 1) == 500)
    #expect(AppModel.reconnectDelayMilliseconds(forAttempt: 2) == 1_000)
    #expect(AppModel.reconnectDelayMilliseconds(forAttempt: 3) == 2_000)
    #expect(AppModel.reconnectDelayMilliseconds(forAttempt: 20) == 30_000)
    #expect(AppModel.reconnectDelayMilliseconds(forAttempt: 1, fastFirstAttempt: true) == 1_500)
}

@Test @MainActor
func connectionDurationUsesHoursInsteadOfGrowingMinuteField() {
    #expect(DashboardView.durationText(seconds: 59) == "00:59")
    #expect(DashboardView.durationText(seconds: 3_661) == "01:01:01")
    #expect(DashboardView.durationText(seconds: 900_061) == "250:01:01")
}

@Test @MainActor
func rendersDashboardAtDefaultWindowSize() throws {
    let model = AppModel()
    model.elapsedSeconds = 900_061
    let view = RootView()
        .environmentObject(model)
        .frame(width: 1120, height: 760)

    try snapshot(view, size: NSSize(width: 1120, height: 760), to: "/private/tmp/hillstone-connect-preview.png")

    try snapshot(
        DashboardView()
            .environmentObject(model)
            .frame(width: 896, height: 760)
            .background(AppColors.canvas),
        size: NSSize(width: 896, height: 760),
        to: "/private/tmp/hillstone-dashboard-preview.png"
    )
}

@Test @MainActor
func rendersAllSecondarySectionsAtDefaultWindowSize() throws {
    let model = AppModel()
    for section in [AppModel.Section.connections, .diagnostics, .settings] {
        model.selectedSection = section
        let view = RootView()
            .environmentObject(model)
            .frame(width: 1120, height: 760)
        try snapshot(
            view,
            size: NSSize(width: 1120, height: 760),
            to: "/private/tmp/nlvc-\(section.rawValue)-preview.png"
        )
    }

    model.selectedSection = .connections
    model.stage = .connected
    model.activeRoutes = ["0.0.0.0/1", "128.0.0.0/1"]
    model.dnsServers = ["192.168.6.5"]
    try snapshot(
        RootView().environmentObject(model).frame(width: 1120, height: 760),
        size: NSSize(width: 1120, height: 760),
        to: "/private/tmp/nlvc-connections-connected-preview.png"
    )
}

@MainActor
private func snapshot<Content: View>(_ content: Content, size: NSSize, to path: String) throws {
    // NSHostingView drives AppKit's normal layout pass, which is required for
    // ScrollView content and environment objects in a headless test run.
    let host = NSHostingView(rootView: content)
    host.frame = NSRect(origin: .zero, size: size)
    let window = NSWindow(
        contentRect: host.frame,
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
    )
    window.contentView = host
    window.layoutIfNeeded()
    host.layoutSubtreeIfNeeded()

    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: bitmap)
    let png = try #require(bitmap.representation(using: .png, properties: [:]))
    try png.write(to: URL(fileURLWithPath: path))
}
