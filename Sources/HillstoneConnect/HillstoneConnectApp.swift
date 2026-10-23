import SwiftUI

@main
struct HillstoneConnectApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("NLVC VPN") {
            RootView()
                .environmentObject(model)
                .frame(minWidth: 980, minHeight: 680)
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact)
        .defaultSize(width: 1120, height: 760)

        MenuBarExtra(
            "NLVC VPN",
            systemImage: model.isConnected ? "point.3.filled.connected.trianglepath.dotted" : "point.3.connected.trianglepath.dotted"
        ) {
            VStack(alignment: .leading, spacing: 12) {
                Text(model.profile.name)
                    .font(.headline)
                Text(model.stage.title)
                    .foregroundStyle(.secondary)
                if model.isConnected {
                    Text("↓ \(model.downloadRateText)   ↑ \(model.uploadRateText)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Divider()
                Button(model.isConnected ? "断开连接" : "连接") {
                    model.toggleConnection()
                }
                Button("退出") { NSApplication.shared.terminate(nil) }
            }
            .padding(8)
        }
    }
}
