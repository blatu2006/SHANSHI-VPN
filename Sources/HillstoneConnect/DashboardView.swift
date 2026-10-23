import HillstoneProtocol
import SwiftUI

struct DashboardView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                connectionHero
                HStack(alignment: .top, spacing: 18) {
                    connectionQuality
                    securityCard
                }
                realtimeDataCard
            }
            .appPage()
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 5) {
                Text("安全访问")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(AppColors.ink)
                Text("连接公司网络时，关键状态始终清晰可见。")
                    .font(.system(size: 14))
                    .foregroundStyle(AppColors.secondaryInk)
            }
            Spacer()
            Button {
                model.showingProfileEditor = true
            } label: {
                Label("编辑连接", systemImage: "slider.horizontal.3")
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
    }

    private var connectionHero: some View {
        HStack(spacing: 28) {
            VStack(alignment: .leading, spacing: 15) {
                HStack(spacing: 10) {
                    StatusPill(
                        text: model.isConnected ? "受保护" : (model.isBusy ? "正在建立连接" : "未连接"),
                        color: model.isConnected ? AppColors.green : (model.isBusy ? AppColors.blue : AppColors.secondaryInk),
                        icon: model.isConnected ? "checkmark.shield.fill" : "shield"
                    )
                    StatusPill(text: "原生 VPN", color: AppColors.cyan, icon: "network.badge.shield.half.filled")
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text(model.stage.title)
                        .font(.system(size: 31, weight: .bold))
                        .foregroundStyle(.white)
                        .contentTransition(.numericText())
                    Text(model.isConnected ? "流量正在通过加密隧道传输" : (model.connectionError ?? stageDescription))
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white.opacity(0.72))
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 28) {
                    heroMetric(title: "网关", value: model.profile.server)
                    heroMetric(
                        title: "数据通道",
                        value: model.isConnected && !model.activeDataTransport.isEmpty
                            ? model.activeDataTransport
                            : model.profile.dataTransport.title
                    )
                    heroMetric(title: "路由", value: model.isConnected ? "\(model.routeCount) 条" : "—")
                }

                Button {
                    model.toggleConnection()
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: model.isConnected || model.isBusy ? "stop.fill" : "power")
                        Text(model.isConnected || model.isBusy ? "断开连接" : "连接")
                    }
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(model.isConnected || model.isBusy ? .white : AppColors.blue)
                    .frame(width: 156, height: 46)
                    .background(
                        model.isConnected || model.isBusy ? Color.white.opacity(0.14) : Color.white,
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                    )
                }
                .buttonStyle(.plain)
            }

            Spacer(minLength: 12)

            ConnectionOrb(stage: model.stage)
                .frame(width: 205, height: 205)
        }
        .padding(28)
        .background(
            LinearGradient(
                colors: [Color(red: 0.075, green: 0.16, blue: 0.36), Color(red: 0.08, green: 0.36, blue: 0.53)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 24, style: .continuous)
        )
        .overlay(alignment: .topTrailing) {
            Circle()
                .fill(.white.opacity(0.06))
                .frame(width: 260, height: 260)
                .offset(x: 70, y: -105)
        }
        .shadow(color: AppColors.blue.opacity(0.16), radius: 24, y: 12)
        .clipped()
    }

    private var connectionQuality: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("连接质量", systemImage: "chart.line.uptrend.xyaxis")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(AppColors.ink)

            HStack(spacing: 0) {
                metric(
                    title: "连接时间",
                    value: durationText,
                    icon: "clock",
                    alignsUnitlessValueWithNumbers: true
                )
                Divider().frame(height: 45)
                metric(title: "VPN 下载", value: byteText(model.bytesReceived), icon: "lock.arrow.down")
                Divider().frame(height: 45)
                metric(title: "VPN 上传", value: byteText(model.bytesSent), icon: "lock.arrow.up")
            }

            HStack(spacing: 0) {
                metric(
                    title: "直连下载 · 估算",
                    value: model.chinaDirectRoutingActive ? byteText(model.directBytesReceived) : "未开启",
                    icon: "arrow.down.circle"
                )
                Divider().frame(height: 45)
                metric(
                    title: "直连上传 · 估算",
                    value: model.chinaDirectRoutingActive ? byteText(model.directBytesSent) : "未开启",
                    icon: "arrow.up.circle"
                )
                Divider().frame(height: 45)
                metric(title: "心跳延迟", value: heartbeatRTTText, icon: "waveform.path.ecg")
            }

        }
        .frame(maxWidth: .infinity, minHeight: 160, maxHeight: 160, alignment: .topLeading)
        .appCard()
    }

    private var securityCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("安全设置", systemImage: "checkmark.shield")
                    .font(.system(size: 16, weight: .bold))
                Spacer()
                Text(model.profile.verifyServerCertificate ? "严格模式" : "兼容模式")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(model.profile.verifyServerCertificate ? AppColors.green : AppColors.blue)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(
                        (model.profile.verifyServerCertificate ? AppColors.green : AppColors.blue).opacity(0.10),
                        in: Capsule()
                    )
            }
            .foregroundStyle(AppColors.ink)

            securityRow(
                model.profile.verifyServerCertificate ? "服务器证书：严格验证" : "服务器证书：兼容私有证书",
                icon: model.profile.verifyServerCertificate ? "checkmark.circle.fill" : "building.2.crop.circle.fill",
                color: model.profile.verifyServerCertificate ? AppColors.green : AppColors.blue
            )
            if !model.certificateFingerprint.isEmpty || !model.profile.pinnedCertificateSHA256.isEmpty {
                securityRow("网关证书指纹已固定", icon: "pin.circle.fill", color: AppColors.green)
            }
            securityRow(
                "账号与密码在本机加密保存",
                icon: "checkmark.circle.fill",
                color: AppColors.green
            )
        }
        .frame(width: 270, alignment: .leading)
        .frame(minHeight: 160, maxHeight: 160, alignment: .topLeading)
        .appCard()
    }

    private var realtimeDataCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 9) {
                Label("实时数据", systemImage: "waveform.path.ecg")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(AppColors.ink)
                Spacer()
                Circle()
                    .fill(qualityColor)
                    .frame(width: 7, height: 7)
                Text(model.isConnected ? "实时更新" : "等待连接")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(AppColors.secondaryInk)
            }

            HStack(spacing: 0) {
                realtimeMetric(title: "VPN 下载", value: model.downloadRateText, icon: "lock.arrow.down")
                realtimeDivider
                realtimeMetric(title: "VPN 上传", value: model.uploadRateText, icon: "lock.arrow.up")
                realtimeDivider
                realtimeMetric(
                    title: "直连下载",
                    value: model.chinaDirectRoutingActive ? model.directDownloadRateText : "未开启",
                    icon: "arrow.down.circle"
                )
                realtimeDivider
                realtimeMetric(
                    title: "直连上传",
                    value: model.chinaDirectRoutingActive ? model.directUploadRateText : "未开启",
                    icon: "arrow.up.circle"
                )
                realtimeDivider
                realtimeMetric(
                    title: "心跳更新",
                    value: model.heartbeatAgeSeconds.map { "\($0) 秒前" } ?? "等待中",
                    icon: "heart.circle"
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .appCard()
    }

    private var stageDescription: String {
        switch model.stage {
        case .idle: "选择连接后即可安全访问内部资源"
        case .failed: "查看诊断信息，问题会明确说明"
        default: "正在完成 \(model.stage.title)…"
        }
    }

    private var durationText: String {
        Self.durationText(seconds: model.elapsedSeconds)
    }

    static func durationText(seconds totalSeconds: Int) -> String {
        let safeSeconds = max(totalSeconds, 0)
        let hours = safeSeconds / 3_600
        let minutes = (safeSeconds % 3_600) / 60
        let seconds = safeSeconds % 60
        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private var heartbeatRTTText: String {
        model.heartbeatRTTMilliseconds.map { "\($0) ms" } ?? "等待中"
    }

    private var qualityColor: Color {
        guard model.isConnected else { return Color.gray.opacity(0.5) }
        if let age = model.heartbeatAgeSeconds, age > 30 { return AppColors.amber }
        return AppColors.green
    }

    private func byteText(_ bytes: UInt64) -> String {
        guard bytes > 0 else { return "0 KB" }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private func heroMetric(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white.opacity(0.47))
            Text(value)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
        }
    }

    private func metric(
        title: String,
        value: String,
        icon: String,
        alignsUnitlessValueWithNumbers: Bool = false
    ) -> some View {
        let parts = metricValueParts(value)

        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .frame(width: 16, alignment: .center)
                Text(title)
                    .lineLimit(1)
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(AppColors.secondaryInk)

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                if let unit = parts.unit {
                    Text(parts.number)
                        .fixedSize(horizontal: true, vertical: false)
                        .frame(minWidth: 52, alignment: .trailing)
                    Text(unit)
                        .fixedSize(horizontal: true, vertical: false)
                } else if alignsUnitlessValueWithNumbers {
                    Text(parts.number)
                        .fixedSize(horizontal: true, vertical: false)
                        .frame(minWidth: 52, alignment: .trailing)
                } else {
                    Text(parts.number)
                        .fixedSize(horizontal: true, vertical: false)
                }
                Spacer(minLength: 0)
            }
            .font(.system(size: 16, weight: .bold, design: .rounded))
            .monospacedDigit()
            .layoutPriority(1)
            .foregroundStyle(AppColors.ink)
            .frame(height: 21, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
    }

    private func metricValueParts(_ value: String) -> (number: String, unit: String?) {
        let parts = value.split(whereSeparator: { $0.isWhitespace })
        guard parts.count == 2 else { return (value, nil) }

        let unit = String(parts[1])
        let fixedUnits: Set<String> = [
            "bytes", "KB", "MB", "GB", "TB", "ms",
            "KB/s", "MB/s", "GB/s", "秒前"
        ]
        guard fixedUnits.contains(unit) else { return (value, nil) }
        return (String(parts[0]), unit)
    }

    private var realtimeDivider: some View {
        Divider()
            .frame(height: 38)
    }

    private func realtimeMetric(title: String, value: String, icon: String) -> some View {
        let parts = metricValueParts(value)

        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .frame(width: 16, alignment: .center)
                Text(title)
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(AppColors.secondaryInk)

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                if let unit = parts.unit {
                    Text(parts.number)
                        .frame(width: 52, alignment: .trailing)
                    Text(unit)
                        .fixedSize(horizontal: true, vertical: false)
                } else {
                    Text(parts.number)
                        .fixedSize(horizontal: true, vertical: false)
                }
                Spacer(minLength: 0)
            }
            .font(.system(size: 15, weight: .bold, design: .rounded))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .foregroundStyle(AppColors.ink)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
    }

    private func securityRow(_ title: String, icon: String, color: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(color)
            Text(title)
                .font(.system(size: 13, weight: .medium))
            Spacer()
        }
    }
}

private struct ConnectionOrb: View {
    let stage: SessionStage

    private var active: Bool { stage != .idle && stage != .failed }
    private var connected: Bool { stage == .connected }

    var body: some View {
        ZStack {
            Circle()
                .stroke(.white.opacity(0.08), lineWidth: 16)
            Circle()
                .trim(from: 0.06, to: active ? 0.92 : 0.62)
                .stroke(
                    AngularGradient(colors: [AppColors.cyan, .white.opacity(0.92), AppColors.cyan], center: .center),
                    style: StrokeStyle(lineWidth: 6, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .shadow(color: AppColors.cyan.opacity(0.55), radius: 15)

            Circle()
                .fill(.white.opacity(0.08))
                .padding(28)

            Image(systemName: connected ? "checkmark.shield.fill" : (active ? "lock.shield.fill" : "shield"))
                .font(.system(size: 55, weight: .medium))
                .foregroundStyle(.white)
                .symbolEffect(.pulse, isActive: active && !connected)
        }
        .padding(8)
    }
}
