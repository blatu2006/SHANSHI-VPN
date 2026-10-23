import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 0) {
            SidebarView()
                .frame(width: 224)

            Group {
                switch model.selectedSection {
                case .overview:
                    DashboardView()
                case .connections:
                    ConnectionsView()
                case .diagnostics:
                    DiagnosticsView()
                case .settings:
                    SettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(AppColors.canvas)
        }
        .ignoresSafeArea(.container, edges: .top)
        .sheet(isPresented: $model.showingProfileEditor) {
            ProfileEditorView(profile: $model.profile, password: $model.sessionPassword) {
                model.saveProfile()
            }
        }
        .alert(
            model.systemExtensionApprovalRequired ? "需要允许数据通道" : "连接失败",
            isPresented: Binding(
                get: { model.connectionAlert != nil },
                set: { if !$0 { model.connectionAlert = nil } }
            )
        ) {
            if model.systemExtensionApprovalRequired {
                Button("打开系统设置") {
                    model.openNetworkExtensionSettings()
                    model.connectionAlert = nil
                }
            }
            Button("知道了", role: .cancel) { model.connectionAlert = nil }
        } message: {
            Text(model.connectionAlert ?? "未知连接错误")
        }
    }
}

private struct SidebarView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                ZStack {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [AppColors.blue, AppColors.cyan],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .font(.system(size: 19, weight: .bold))
                        .foregroundStyle(.white)
                }
                .frame(width: 38, height: 38)

                VStack(alignment: .leading, spacing: 1) {
                    Text("NLVC")
                        .font(.system(size: 15, weight: .bold))
                    Text("VPN")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(AppColors.sidebarMuted)
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 22)
            .padding(.top, 30)
            .padding(.bottom, 30)

            VStack(spacing: 6) {
                ForEach(AppModel.Section.allCases) { section in
                    Button {
                        model.selectedSection = section
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: section.icon)
                                .frame(width: 20)
                            Text(section.title)
                            Spacer()
                        }
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(model.selectedSection == section ? .white : AppColors.sidebarMuted)
                        .padding(.horizontal, 14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(height: 42)
                        .background(
                            model.selectedSection == section ? Color.white.opacity(0.11) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 12)

            Spacer()

            Text(versionLabel)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(AppColors.sidebarMuted.opacity(0.72))
                .padding(.horizontal, 22)
                .padding(.bottom, 18)
        }
        .background(AppColors.sidebar)
    }

    private var versionLabel: String {
        if let build = model.appBuild, !build.isEmpty {
            return "v\(model.appVersion) (\(build))"
        }
        return "v\(model.appVersion)"
    }
}
