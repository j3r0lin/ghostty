import AppKit
import SwiftUI

/// Card view for a single in-app notification toast.
///
/// Visual style mirrors macOS system notifications: agent app icon on the
/// left, three lines of text on the right, popover-material rounded
/// background, hover-revealed close button in the top-left corner.
struct NotificationToastView: View {
    let toast: NotificationToast
    var onClick: () -> Void = {}
    var onClose: () -> Void = {}
    var onHoverChange: (Bool) -> Void = { _ in }
    @State private var isHovered: Bool = false
    @Environment(\.colorScheme) private var colorScheme
    private let cornerRadius: CGFloat = 20
    private var chrome: ToastChrome { ToastChrome(isDark: colorScheme == .dark) }

    private var cardBackground: some View {
        ZStack {
            NotificationVisualEffectBlur(material: chrome.material, blendingMode: .behindWindow)
            if let tint = chrome.tint {
                tint
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }

    // 按 Claude 图标透明边标定：48/40 pt 绘制与布局框、下移 1 pt、间隔 9.5 pt，
    // 使可见图标为 38 pt、距卡片左侧 13 pt，文字起点为 61.5 pt。
    var body: some View {
        HStack(alignment: .center, spacing: 9.5) {
            iconView

            VStack(alignment: .leading, spacing: 0) {
                Text(toast.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if !toast.subtitle.isEmpty {
                    Text(toast.subtitle)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                if !toast.body.isEmpty {
                    Text(toast.body)
                        .font(.system(size: 13))
                        .lineLimit(4)
                        .foregroundStyle(.primary.opacity(0.92))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, 12)
        .padding(.trailing, 10)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .frame(width: 344, alignment: .leading)
        .background(cardBackground)
        .overlay(border)
        .overlay(outerLine)
        .shadow(color: chrome.shadowColor, radius: chrome.shadowRadius, x: 0, y: chrome.shadowY)
        .overlay(alignment: .topLeading) {
            if isHovered {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.primary.opacity(0.85))
                }
                .buttonStyle(.plain)
                .frame(width: 18, height: 18)
                .background(
                    NotificationVisualEffectBlur(material: .menu, blendingMode: .behindWindow)
                        .clipShape(Circle())
                )
                .overlay(Circle().stroke(.primary.opacity(0.12), lineWidth: 0.5))
                .offset(x: 4, y: 4)
            }
        }
        .padding(12) // reserve space so shadow isn't clipped by panel bounds
        .contentShape(RoundedRectangle(cornerRadius: cornerRadius))
        .onTapGesture(perform: onClick)
        .onHover { hovering in
            isHovered = hovering
            onHoverChange(hovering)
        }
    }

    @ViewBuilder
    private var border: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius)
        if chrome.borderInside {
            shape.strokeBorder(chrome.borderColor, lineWidth: chrome.borderWidth)
        } else {
            shape.stroke(chrome.borderColor, lineWidth: chrome.borderWidth)
        }
    }

    // 画在卡片边界之外，对应系统横幅外侧那 1 px 暗线。
    @ViewBuilder
    private var outerLine: some View {
        if let color = chrome.outerLineColor {
            RoundedRectangle(cornerRadius: cornerRadius)
                .inset(by: -0.25)
                .stroke(color, lineWidth: 0.5)
        }
    }

    @ViewBuilder
    private var iconView: some View {
        if let agent = toast.agent, let img = agent.iconImage() {
            Image(nsImage: img)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: 48, height: 48)
                .frame(width: 40, height: 40)
                .offset(y: 1)
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.gray.opacity(0.5))
                Image(systemName: "terminal")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .foregroundStyle(.white)
                    .padding(9)
            }
            .frame(width: 38, height: 38)
            .frame(width: 40, height: 40)
            .offset(y: 1)
        }
    }
}

/// Material, border and shadow of the toast card for one color scheme.
private struct ToastChrome {
    let material: NSVisualEffectView.Material
    /// 叠在材质上，用来压低材质对背景亮度的敏感度。
    let tint: Color?
    let borderColor: Color
    let borderWidth: CGFloat
    let borderInside: Bool
    let outerLineColor: Color?
    let shadowColor: Color
    let shadowRadius: CGFloat
    let shadowY: CGFloat

    init(isDark: Bool) {
        if isDark {
            material = .headerView
            tint = Color(white: 0.16).opacity(0.28)
            borderColor = Color.white.opacity(0.15)
            borderWidth = 1
            borderInside = true
            outerLineColor = Color.black.opacity(0.27)
            shadowColor = .black.opacity(0.4)
            shadowRadius = 5
            shadowY = 1
        } else {
            material = .menu
            tint = nil
            borderColor = Color.primary.opacity(0.12)
            borderWidth = 0.5
            borderInside = false
            outerLineColor = nil
            shadowColor = .black.opacity(0.18)
            shadowRadius = 8
            shadowY = 3
        }
    }
}

/// SwiftUI wrapper around NSVisualEffectView so toast cards can use the
/// system's notification-style translucent material with proper window blur.
struct NotificationVisualEffectBlur: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blendingMode
        v.state = .active
        return v
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}
