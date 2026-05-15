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
    @State private var isHovered: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            iconView

            VStack(alignment: .leading, spacing: 1) {
                Text(toast.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if !toast.subtitle.isEmpty {
                    Text(toast.subtitle)
                        .font(.system(size: 13))
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
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .frame(width: 370, alignment: .leading)
        .background(
            NotificationVisualEffectBlur(material: .menu, blendingMode: .behindWindow)
                .clipShape(RoundedRectangle(cornerRadius: 14))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.primary.opacity(0.12), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.18), radius: 8, x: 0, y: 3)
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
                .offset(x: -7, y: -7)
            }
        }
        .padding(12) // reserve space so shadow isn't clipped by panel bounds
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .onTapGesture(perform: onClick)
        .onHover { isHovered = $0 }
    }

    @ViewBuilder
    private var iconView: some View {
        if let agent = toast.agent, let img = agent.iconImage() {
            Image(nsImage: img)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: 44, height: 44)
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
            .frame(width: 44, height: 44)
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
