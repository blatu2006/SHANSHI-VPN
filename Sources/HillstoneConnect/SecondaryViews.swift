import HillstoneProtocol
import SwiftUI

struct ConnectionsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                pageHeader("连接", subtitle: "管理网关、认证方式与网络策略") {
                    HStack(spacing: 10) {
                        Menu {
                            ForEach(model.profiles) { profile in
                                Button {
                                    model.selectProfile(profile.id)
                                } label: {
                                    if profile.id == model.profile.id {
                                        Label(profile.name, systemImage: "checkmark")
                                    } else {
                                        Text(profile.name)
                                    }
                                }
                            }
                            Divider()
                            Button("复制当前连接", systemImage: "plus.square.on.square") {
                                model.duplicateCurrentProfile()
                            }
                            Button("删除当前连接", systemImage: "trash", role: .destructive) {
                                model.deleteCurrentProfile()
                            }
                            .disabled(model.profiles.count <= 1)
                        } label: {
                            Label("\(model.profiles.count) 个连接", systemImage: "rectangle.stack")
                        }
                        .disabled(model.isConnected || model.isBusy)
                        .help(model.isConnected || model.isBusy ? "断开连接后可切换配置" : "选择和管理连接")

                        Button {
                            model.showingProfileEditor = true
                        } label: {
                            Label("编辑", systemImage: "pencil")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }

                if let message = model.connectionError {
                    InlineNotice(message: message, icon: "exclamationmark.triangle.fill", color: AppColors.amber) {
                        model.connectionError = nil
                    }
                }

                VStack(alignment: .leading, spacing: 20) {
                    HStack(spacing: 15) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(AppColors.blue.opacity(0.10))
                            Image(systemName: "building.2.fill")
                                .foregroundStyle(AppColors.blue)
                                .font(.system(size: 22, weight: .semibold))
                        }
                        .frame(width: 54, height: 54)

                        VStack(alignment: .leading, spacing: 5) {
                            Text(model.profile.name)
                                .font(.system(size: 18, weight: .semibold))
                            Text("\(model.profile.server):\(model.profile.port)")
                                .font(.system(size: 13, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        StatusPill(
                            text: model.isConnected ? "已连接" : model.stage.title,
                            color: model.isConnected ? AppColors.green : AppColors.blue,
                            icon: model.isConnected ? "checkmark.circle.fill" : "circle.dotted"
                        )
                    }

                    Divider()

                    LazyVGrid(
                        columns: Array(repeating: GridItem(.flexible(), spacing: 18), count: 4),
                        alignment: .leading,
                        spacing: 18
                    ) {
                        connectionAttribute("认证方式", model.profile.authentication.title, icon: "person.badge.key")
                        connectionAttribute(
                            "数据通道",
                            "TLS 控制 + " + (model.isConnected && !model.activeDataTransport.isEmpty
                                ? model.activeDataTransport
                                : model.profile.dataTransport.title),
                            icon: "arrow.left.arrow.right"
                        )
                        connectionAttribute("路由模式", model.profile.routingMode.title, icon: "arrow.triangle.branch")
                        connectionAttribute(
                            "国内互联网",
                            model.profile.chinaDirectRouting ? "本机网络直连" : "跟随 VPN 路由",
                            icon: "location.fill"
                        )
                        connectionAttribute(
                            "MTU",
                            model.isConnected
                                ? "\(model.activeMTU) · \(model.underlyingNetwork.title)"
                                : (model.profile.automaticMTU ? "按网络自动选择" : String(model.profile.mtu)),
                            icon: "gauge.with.dots.needle.33percent"
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .appCard()

                VStack(alignment: .leading, spacing: 13) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("网络策略")
                            .font(.system(size: 18, weight: .semibold))
                        Text(model.isConnected ? "当前由隧道实际应用的网络设置" : "连接后显示服务器下发的路由与 DNS")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }

                    HStack(alignment: .top, spacing: 18) {
                        VStack(alignment: .leading, spacing: 14) {
                            HStack {
                                Label("活动路由", systemImage: "arrow.triangle.branch")
                                    .font(.headline)
                                Spacer()
                                Text(model.isConnected ? "\(model.activeRoutes.count) 条" : "等待连接")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(model.isConnected ? AppColors.blue : .secondary)
                            }

                            Divider()

                            if model.isConnected && model.chinaDirectRoutingActive {
                                Label("国内公网直连已应用 · \(model.excludedRouteCount) 条排除路由", systemImage: "location.fill")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(AppColors.green)
                            }

                            if model.activeRoutes.isEmpty {
                                emptyNetworkValue("连接后将在这里显示服务器下发的目标网段", icon: "point.3.filled.connected.trianglepath.dotted")
                            } else {
                                LazyVGrid(
                                    columns: [GridItem(.adaptive(minimum: 170), spacing: 10)],
                                    alignment: .leading,
                                    spacing: 10
                                ) {
                                    ForEach(model.activeRoutes, id: \.self) { route in
                                        Label(route, systemImage: "arrow.right")
                                            .font(.system(size: 13, weight: .medium, design: .monospaced))
                                            .foregroundStyle(AppColors.ink)
                                    }
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: 122, alignment: .topLeading)
                        .appCard()

                        VStack(alignment: .leading, spacing: 14) {
                            HStack {
                                Label("DNS", systemImage: "network")
                                    .font(.headline)
                                Spacer()
                                if model.isConnected && !model.dnsServers.isEmpty {
                                    StatusPill(text: "隧道内", color: AppColors.green)
                                }
                            }

                            Divider()

                            if model.isConnected && model.dnsServers.isEmpty {
                                emptyNetworkValue("沿用本机网络 DNS", icon: "globe")
                            } else if model.dnsServers.isEmpty {
                                emptyNetworkValue("连接后显示 DNS 策略", icon: "globe")
                            } else {
                                ForEach(model.dnsServers, id: \.self) { server in
                                    Text(server)
                                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                                }
                                Text("所有域名查询均使用隧道 DNS")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(width: 330, alignment: .leading)
                        .frame(minHeight: 122, alignment: .topLeading)
                        .appCard()
                    }
                }

                if model.isConnected {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.shield.fill")
                            .foregroundStyle(AppColors.green)
                        Text("网络设置已由 macOS Network Extension 应用")
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)
            }
            .appPage()
        }
    }
}

@MainActor
private func connectionAttribute(_ title: String, _ value: String, icon: String) -> some View {
    HStack(alignment: .top, spacing: 10) {
        Image(systemName: icon)
            .frame(width: 18)
            .foregroundStyle(AppColors.blue)
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(2)
        }
    }
}

@MainActor
private func emptyNetworkValue(_ text: String, icon: String) -> some View {
    HStack(spacing: 10) {
        Image(systemName: icon)
            .foregroundStyle(AppColors.secondaryInk)
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, minHeight: 45, alignment: .leading)
}

struct DiagnosticsView: View {
    @EnvironmentObject private var model: AppModel
    private let stages: [(String, String)] = [
        ("直连模式", "当前网关未启用 SPA"),
        ("TLS 控制通道", "TCP 4433 · TLS 1.2"),
        ("控制消息编解码", "Header + TLV"),
        ("NEW_KEY 字段", "48 字节密钥与双向 SPI"),
        ("虚拟接口与路由", "utun · IPv4 · DNS · MTU"),
        ("ESP 数据通道", "UDP / TCP 自动选择 · 3DES-CBC · HMAC-SHA1-96"),
        ("Packet Tunnel 数据收发", "Network Extension packetFlow")
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                pageHeader("协议诊断", subtitle: "把技术状态翻译成可行动的信息") {
                    HStack {
                        Button {
                            model.copyDiagnostics()
                        } label: {
                            Label("复制报告", systemImage: "doc.on.doc")
                        }
                        Button {
                            model.exportDiagnostics()
                        } label: {
                            Label("导出报告", systemImage: "square.and.arrow.up")
                        }
                        Button {
                            model.revealConnectionLog()
                        } label: {
                            Label("连接日志", systemImage: "doc.text.magnifyingglass")
                        }
                    }
                    .buttonStyle(.bordered)
                }

                if let message = model.diagnosticsMessage {
                    InlineNotice(message: message) {
                        model.diagnosticsMessage = nil
                    }
                }

                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 4),
                    spacing: 14
                ) {
                    diagnosticMetric("VPN 实时下载", model.downloadRateText)
                    diagnosticMetric("VPN 实时上传", model.uploadRateText)
                    diagnosticMetric(
                        "直连实时下载 · 估算",
                        model.chinaDirectRoutingActive ? model.directDownloadRateText : "未开启"
                    )
                    diagnosticMetric(
                        "直连实时上传 · 估算",
                        model.chinaDirectRoutingActive ? model.directUploadRateText : "未开启"
                    )
                    diagnosticMetric("心跳", model.heartbeatRTTMilliseconds.map { "\($0) ms" } ?? "等待中")
                    diagnosticMetric("心跳抖动", String(format: "%.1f ms", model.heartbeatJitterMilliseconds))
                    diagnosticMetric("心跳丢包", String(format: "%.1f%%", model.heartbeatLossPercent))
                    diagnosticMetric("数据包丢弃", "\(model.droppedPackets)")
                    diagnosticMetric("ESP 估算丢包", String(format: "%.2f%%", model.espLossPercent))
                    diagnosticMetric("ESP 乱序", String(format: "%.2f%%", model.espReorderPercent))
                    diagnosticMetric("ESP 重复包", "\(model.espDuplicatePackets)")
                    diagnosticMetric("当前 MTU", "\(model.activeMTU)")
                    diagnosticMetric(
                        "路径 MTU 探测",
                        model.pathProbeRTTMilliseconds.map { "\(model.pathProbeStatus) · \($0) ms" }
                            ?? model.pathProbeStatus
                    )
                    diagnosticMetric("底层网络", model.underlyingNetwork.title)
                    diagnosticMetric(
                        "UDP Pacing",
                        model.udpPacingActive ? "启用 · \(model.udpPacingRateMbps) Mbps" : "未启用"
                    )
                    diagnosticMetric(
                        "Pacing 队列",
                        model.udpPacingActive
                            ? String(format: "%.2f ms", model.udpPacingQueueDelayMilliseconds)
                            : "未启用"
                    )
                }

                VStack(spacing: 0) {
                    ForEach(Array(stages.enumerated()), id: \.offset) { index, item in
                        HStack(spacing: 15) {
                            ZStack {
                                Circle().fill(AppColors.green.opacity(0.12))
                                Image(systemName: "checkmark")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(AppColors.green)
                            }
                            .frame(width: 30, height: 30)

                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.0).font(.system(size: 14, weight: .semibold))
                                Text(item.1).font(.system(size: 12)).foregroundStyle(.secondary)
                            }
                            Spacer()
                            StatusPill(text: "已实现", color: AppColors.green)
                        }
                        .padding(.vertical, 14)
                        if index < stages.count - 1 { Divider().padding(.leading, 45) }
                    }
                }
                .appCard()

                VStack(alignment: .leading, spacing: 10) {
                    Label("隐私保护", systemImage: "hand.raised.fill")
                        .font(.headline)
                    Text("诊断视图默认隐藏用户名、网关地址、Cookie、Token、SPI 和密钥材料。导出日志前会再次执行脱敏。")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .appCard()
            }
            .appPage()
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var newInternalAddress = ""
    @State private var internalAddressError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                pageHeader("设置", subtitle: "默认安全，保持克制") { EmptyView() }

                if let message = model.credentialError {
                    InlineNotice(message: "本地凭据：\(message)", icon: "key.fill", color: AppColors.amber) {
                        model.credentialError = nil
                    }
                }

                if let message = model.loginItemError {
                    InlineNotice(message: "登录启动：\(message)", icon: "exclamationmark.triangle.fill", color: AppColors.amber) {
                        model.loginItemError = nil
                    }
                }

                if let message = model.settingsError {
                    InlineNotice(message: message, icon: "bell.slash.fill", color: AppColors.amber) {
                        model.settingsError = nil
                    }
                }

                settingsSection("系统集成", icon: "macwindow") {
                    settingValueRow("VPN 配置", "由 macOS Network Extension 管理")
                    Divider()
                    settingValueRow("菜单栏状态", "已启用")
                    Divider()
                    HStack {
                        Text("断线后自动重连")
                        Spacer()
                        Toggle("", isOn: $model.profile.automaticallyReconnects)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }
                    .padding(.vertical, 12)
                    Divider()
                    HStack(alignment: .center, spacing: 20) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("UDP Pacing 加速")
                            Text("开启后固定使用 UDP；平滑突发并在持续传输时自动提高发送速率。修改会在下次连接生效。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("", isOn: $model.profile.udpPacingEnabled)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }
                    .font(.system(size: 13))
                    .padding(.vertical, 12)
                    Divider()
                    HStack {
                        Text("登录后启动 NLVC VPN")
                        Spacer()
                        Toggle(
                            "",
                            isOn: Binding(
                                get: { model.profile.launchesAtLogin },
                                set: { model.setLaunchAtLogin($0) }
                            )
                        )
                        .labelsHidden()
                        .toggleStyle(.switch)
                    }
                    .padding(.vertical, 12)
                    Divider()
                    settingsToggle("Wi-Fi 可用时自动连接", isOn: $model.profile.connectsOnWiFi)
                    Divider()
                    settingsToggle("有线网络可用时自动连接", isOn: $model.profile.connectsOnEthernet)
                    Divider()
                    settingsToggle("连接状态系统通知", isOn: $model.profile.connectionNotifications)
                }

                settingsSection("安全", icon: "checkmark.shield") {
                    settingValueRow("凭据存储", "本机 AES-GCM 加密文件")
                    Divider()
                    settingValueRow("证书策略", "按连接配置")
                    Divider()
                    settingValueRow("隧道算法", "3DES-CBC · HMAC-SHA1-96")
                    Divider()
                    settingValueRow(
                        "证书指纹",
                        model.profile.pinnedCertificateSHA256.isEmpty ? "首次连接后固定" : "已固定"
                    )
                    Divider()
                    settingsToggle("在本机加密保存密码", isOn: $model.profile.remembersPassword)
                    Divider()
                    settingsToggle("阻止 IPv6 绕过隧道", isOn: $model.profile.blockIPv6Leaks)
                }

                settingsSection("路由", icon: "arrow.triangle.branch") {
                    settingsToggle("使用 VPN 下发的 DNS", isOn: $model.profile.usesTunnelDNS)
                    Text("开启时只在 VPN 连接期间临时使用隧道 DNS，不会修改 Wi-Fi 或网线的 DNS 配置；关闭后沿用本机 DNS。修改会在下次连接生效。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                    Divider()
                    VStack(alignment: .leading, spacing: 10) {
                        Text("始终走 VPN 的内网地址")
                            .font(.system(size: 13))
                        HStack(spacing: 10) {
                            TextField("IPv4 或网段，例如 10.0.0.0/8", text: $newInternalAddress)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit(addInternalAddress)
                            Button("添加", action: addInternalAddress)
                                .buttonStyle(.bordered)
                                .disabled(newInternalAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                        if let internalAddressError {
                            Text(internalAddressError)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                        ForEach(model.profile.includedIPv4CIDRs, id: \.self) { cidr in
                            HStack {
                                Text(cidr)
                                    .font(.system(size: 12, design: .monospaced))
                                Spacer()
                                Button {
                                    removeInternalAddress(cidr)
                                } label: {
                                    Image(systemName: "minus.circle")
                                }
                                .buttonStyle(.plain)
                                .help("删除 \(cidr)")
                            }
                        }
                        Text("单个地址按 /32 处理；这些地址优先走 VPN，包括开启国内公网直连时。修改会在下次连接生效。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 12)
                    Divider()
                    settingsToggle("中国大陆公网 IPv4 直连", isOn: $model.profile.chinaDirectRouting)
                    Text("开启后，国内公网 IPv4 走 Mac 自己的 Wi-Fi 或网线；公司内网、隧道 DNS 与未命中国地址库的流量仍按 VPN 策略处理。修改会在下次连接生效。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                }

                settingsSection("软件更新", icon: "arrow.triangle.2.circlepath") {
                    settingsToggle("自动检查更新", isOn: $model.profile.automaticallyChecksForUpdates)
                    Divider()
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("版本 \(model.appVersion)")
                                .font(.system(size: 13, weight: .medium))
                            Text(model.updateStatus)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if model.availableUpdateURL != nil {
                            Button(model.isDownloadingUpdate ? "正在下载…" : "下载并安装") {
                                model.downloadAndInstallAvailableUpdate()
                            }
                                .buttonStyle(.borderedProminent)
                                .disabled(model.isDownloadingUpdate)
                        } else {
                            Button("检查更新") { model.checkForUpdates() }
                                .buttonStyle(.bordered)
                                .disabled(model.isCheckingForUpdates)
                        }
                    }
                    .padding(.vertical, 6)
                }

                Spacer(minLength: 8)
            }
            .appPage()
            .onChange(of: model.profile.automaticallyReconnects) { _, _ in model.saveProfile() }
            .onChange(of: model.profile.udpPacingEnabled) { _, enabled in
                if enabled {
                    model.profile.dataTransport = .udp
                }
                model.saveProfile()
            }
            .onChange(of: model.profile.usesTunnelDNS) { _, _ in model.saveProfile() }
            .onChange(of: model.profile.connectsOnWiFi) { _, _ in model.saveProfile() }
            .onChange(of: model.profile.connectsOnEthernet) { _, _ in model.saveProfile() }
            .onChange(of: model.profile.connectionNotifications) { _, enabled in
                model.setConnectionNotifications(enabled)
            }
            .onChange(of: model.profile.automaticallyChecksForUpdates) { _, _ in model.saveProfile() }
            .onChange(of: model.profile.remembersPassword) { _, _ in model.saveProfile() }
            .onChange(of: model.profile.blockIPv6Leaks) { _, _ in
                model.saveProfile()
            }
            .onChange(of: model.profile.chinaDirectRouting) { _, _ in model.saveProfile() }
        }
    }

    private func addInternalAddress() {
        do {
            let route = try IPv4Route.parseAddressOrCIDR(newInternalAddress)
            let cidr = route.cidrString
            if !model.profile.includedIPv4CIDRs.contains(cidr) {
                model.profile.includedIPv4CIDRs.append(cidr)
                model.saveProfile()
            }
            newInternalAddress = ""
            internalAddressError = nil
        } catch {
            internalAddressError = "地址格式无效，请输入 IPv4 或 CIDR 网段。"
        }
    }

    private func removeInternalAddress(_ cidr: String) {
        model.profile.includedIPv4CIDRs.removeAll { $0 == cidr }
        model.saveProfile()
        internalAddressError = nil
    }
}

@MainActor
private func settingsSection<Content: View>(
    _ title: String,
    icon: String,
    @ViewBuilder content: () -> Content
) -> some View {
    VStack(alignment: .leading, spacing: 16) {
        Label(title, systemImage: icon)
            .font(.system(size: 16, weight: .bold))
            .foregroundStyle(AppColors.ink)
        VStack(spacing: 0) {
            content()
        }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .appCard()
}

@MainActor
private func settingValueRow(_ title: String, _ value: String) -> some View {
    HStack(spacing: 20) {
        Text(title)
            .foregroundStyle(AppColors.ink)
        Spacer()
        Text(value)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.trailing)
    }
    .font(.system(size: 13))
    .padding(.vertical, 12)
}

@MainActor
private func settingsToggle(_ title: String, isOn: Binding<Bool>) -> some View {
    HStack {
        Text(title)
        Spacer()
        Toggle("", isOn: isOn)
            .labelsHidden()
            .toggleStyle(.switch)
    }
    .font(.system(size: 13))
    .padding(.vertical, 12)
}

struct ProfileEditorView: View {
    @Binding var profile: ConnectionProfile
    @Binding var password: String
    @Environment(\.dismiss) private var dismiss
    @State private var advanced = false
    @State private var draftProfile: ConnectionProfile
    @State private var draftPassword: String
    let onSave: () -> Void

    init(
        profile: Binding<ConnectionProfile>,
        password: Binding<String>,
        onSave: @escaping () -> Void = {}
    ) {
        _profile = profile
        _password = password
        _draftProfile = State(initialValue: profile.wrappedValue)
        _draftPassword = State(initialValue: password.wrappedValue)
        self.onSave = onSave
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("编辑连接").font(.title2.bold())
                    Text("账号与密码保存在应用沙箱内的本地加密文件中。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(24)

            Divider()

            Form {
                Section("基本信息") {
                    TextField("名称", text: $draftProfile.name)
                    TextField("服务器", text: $draftProfile.server)
                    TextField("用户名", text: $draftProfile.username)
                    SecureField("密码", text: $draftPassword)
                    Toggle("在本机加密保存密码", isOn: $draftProfile.remembersPassword)
                    Text(draftProfile.remembersPassword
                         ? "账号与密码不会写入连接配置；保存后使用 AES-GCM 加密并限制为当前用户访问。"
                         : "密码仅用于本次连接；断开后需要重新输入。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("连接") {
                    LabeledContent("认证方式", value: "用户名和密码")
                    Picker("数据通道", selection: $draftProfile.dataTransport) {
                        ForEach(ConnectionProfile.DataTransport.allCases, id: \.self) { transport in
                            Text(transport.title).tag(transport)
                        }
                    }
                    Text("自动模式优先使用高速 UDP；UDP 端点不可用时回退到 TCP 稳定模式。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if draftProfile.server == ConnectionProfile.preview.server {
                        LabeledContent("服务器证书", value: "兼容 SG-6000 私有证书")
                        Text("此网关证书无法通过 macOS 严格校验，应用将只对该地址使用兼容模式。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Toggle("验证服务器证书", isOn: $draftProfile.verifyServerCertificate)
                    }
                    Picker("路由模式", selection: $draftProfile.routingMode) {
                        ForEach(ConnectionProfile.RoutingMode.allCases, id: \.self) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    Toggle("使用 VPN 下发的 DNS", isOn: $draftProfile.usesTunnelDNS)
                    Text("开启时仅在 VPN 会话内临时接管 DNS，不会修改 Wi-Fi 或网线的 DNS 配置；关闭后沿用本机 DNS。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField(
                        "始终走 VPN 的内网地址（逗号分隔）",
                        text: Binding(
                            get: { draftProfile.includedIPv4CIDRs.joined(separator: ", ") },
                            set: { value in
                                draftProfile.includedIPv4CIDRs = value
                                    .split(separator: ",")
                                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                                    .filter { !$0.isEmpty }
                            }
                        )
                    )
                    Text("支持单个 IPv4 或 CIDR 网段；保存后在下次连接生效。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if normalizedInternalAddresses == nil {
                        Text("内网地址格式无效，请使用 IPv4 或 CIDR，并以逗号分隔。")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    Toggle("中国大陆公网 IPv4 直连", isOn: $draftProfile.chinaDirectRouting)
                    Text(draftProfile.usesTunnelDNS
                         ? "国内互联网走本机网络；公司内网和隧道 DNS 仍按 VPN 策略处理。"
                         : "国内互联网走本机网络；DNS 保持当前本机设置。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Toggle("断线自动重连", isOn: $draftProfile.automaticallyReconnects)
                }

                DisclosureGroup("高级设置", isExpanded: $advanced) {
                    TextField("端口", value: $draftProfile.port, format: .number)
                    Toggle("自动选择安全 MTU", isOn: $draftProfile.automaticMTU)
                    if !draftProfile.automaticMTU {
                        TextField("MTU", value: $draftProfile.mtu, format: .number)
                    }
                    Toggle("阻止 IPv6 绕过隧道", isOn: $draftProfile.blockIPv6Leaks)
                    TextField(
                        "排除网段（例如 192.168.1.0/24）",
                        text: Binding(
                            get: { draftProfile.excludedIPv4CIDRs.joined(separator: ", ") },
                            set: { value in
                                draftProfile.excludedIPv4CIDRs = value
                                    .split(separator: ",")
                                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                                    .filter { !$0.isEmpty }
                            }
                        )
                    )
                    LabeledContent("网关模式", value: "直连（SPA 关闭）")
                    if !draftProfile.pinnedCertificateSHA256.isEmpty {
                        Button("清除已保存的证书指纹", role: .destructive) {
                            draftProfile.pinnedCertificateSHA256 = ""
                        }
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("保存") {
                    draftProfile.includedIPv4CIDRs = normalizedInternalAddresses ?? []
                    profile = draftProfile
                    password = draftPassword
                    onSave()
                    dismiss()
                }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(
                        draftProfile.server.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || draftProfile.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || draftPassword.isEmpty
                            || normalizedInternalAddresses == nil
                    )
            }
            .padding(18)
        }
        .frame(width: 540, height: 680)
    }

    private var normalizedInternalAddresses: [String]? {
        var seen = Set<String>()
        do {
            return try draftProfile.includedIPv4CIDRs.compactMap { value in
                let cidr = try IPv4Route.parseAddressOrCIDR(value).cidrString
                return seen.insert(cidr).inserted ? cidr : nil
            }
        } catch {
            return nil
        }
    }
}

@MainActor
private func diagnosticMetric(_ title: String, _ value: String) -> some View {
    VStack(alignment: .leading, spacing: 5) {
        Text(title).font(.caption).foregroundStyle(.secondary)
        Text(value).font(.system(size: 15, weight: .semibold, design: .rounded))
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .appCard(padding: 14)
}

@ViewBuilder
private func pageHeader<Trailing: View>(
    _ title: String,
    subtitle: String,
    @ViewBuilder trailing: () -> Trailing
) -> some View {
    HStack {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 28, weight: .bold)).foregroundStyle(AppColors.ink)
            Text(subtitle).font(.system(size: 14)).foregroundStyle(AppColors.secondaryInk)
        }
        Spacer()
        trailing()
    }
}

@ViewBuilder
private func property(_ label: String, _ value: String) -> some View {
    HStack {
        Text(label).foregroundStyle(.secondary)
        Spacer()
        Text(value).fontWeight(.medium)
    }
    .font(.system(size: 13))
}
