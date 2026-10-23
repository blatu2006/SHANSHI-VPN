import SwiftUI

enum AppColors {
    static let canvas = Color(red: 0.945, green: 0.957, blue: 0.973)
    static let sidebar = Color(red: 0.075, green: 0.105, blue: 0.155)
    static let sidebarMuted = Color(red: 0.55, green: 0.62, blue: 0.71)
    static let blue = Color(red: 0.12, green: 0.39, blue: 0.94)
    static let cyan = Color(red: 0.12, green: 0.72, blue: 0.76)
    static let green = Color(red: 0.12, green: 0.68, blue: 0.46)
    static let amber = Color(red: 0.95, green: 0.61, blue: 0.15)
    static let ink = Color(red: 0.08, green: 0.11, blue: 0.16)
    static let secondaryInk = Color(red: 0.37, green: 0.42, blue: 0.50)
}

struct CardModifier: ViewModifier {
    var padding: CGFloat = 20

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(Color.white.opacity(0.92), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.black.opacity(0.055), lineWidth: 1)
            }
            .shadow(color: Color.black.opacity(0.045), radius: 18, y: 8)
    }
}

extension View {
    func appCard(padding: CGFloat = 20) -> some View {
        modifier(CardModifier(padding: padding))
    }

    func appPage(maxWidth: CGFloat = 1_100) -> some View {
        frame(maxWidth: maxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .top)
            .padding(30)
    }
}

struct StatusPill: View {
    let text: String
    let color: Color
    var icon: String? = nil

    var body: some View {
        HStack(spacing: 6) {
            if let icon {
                Image(systemName: icon)
            }
            Text(text)
        }
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(color)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(color.opacity(0.11), in: Capsule())
    }
}

struct InlineNotice: View {
    let message: String
    var icon = "info.circle.fill"
    var color = AppColors.blue
    var onDismiss: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .padding(.top, 1)
            Text(message)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(AppColors.ink)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(AppColors.secondaryInk)
                        .padding(4)
                }
                .buttonStyle(.plain)
                .help("关闭提示")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(color.opacity(0.09), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
