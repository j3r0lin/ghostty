import SwiftUI
#if os(macOS)
import AppKit
import QuartzCore
#endif

/// The progress bar to show a surface progress report. We implement this from scratch because the
/// standard ProgressView is broken on macOS 26 and this is simple anyways and gives us a ton of
/// control.
struct SurfaceProgressBar: View {
    let report: Ghostty.Action.ProgressReport

    private var color: Color {
        switch report.state {
        case .error: return .red
        case .pause: return .orange
        default: return .accentColor
        }
    }

    private var progress: UInt8? {
        // If we have an explicit progress use that.
        if let v = report.progress { return v }

        // Otherwise, if we're in the pause state, we act as if we're at 100%.
        if report.state == .pause { return 100 }

        return nil
    }

    private var accessibilityLabel: String {
        switch report.state {
        case .error: return "Terminal progress - Error"
        case .pause: return "Terminal progress - Paused"
        case .indeterminate: return "Terminal progress - In progress"
        default: return "Terminal progress"
        }
    }

    private var accessibilityValue: String {
        if let progress {
            return "\(progress) percent complete"
        } else {
            switch report.state {
            case .error: return "Operation failed"
            case .pause: return "Operation paused at completion"
            case .indeterminate: return "Operation in progress"
            default: return "Indeterminate progress"
            }
        }
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                if let progress {
                    Rectangle()
                        .fill(color)
                        .frame(
                            width: geometry.size.width * CGFloat(progress) / 100,
                            height: geometry.size.height
                        )
                        .animation(.easeInOut(duration: 0.2), value: progress)
                } else {
                    GradientSweepProgressBar(colors: [.red, .yellow, .green, .cyan])
                }
            }
        }
        .frame(height: 2)
        .clipped()
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.updatesFrequently)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(accessibilityValue)
    }
}

/// Gradient sweep progress bar.
///
/// On macOS this is a Core Animation layer whose translation is animated by the
/// render server, so the sweep costs nothing on the main thread. The previous
/// SwiftUI `TimelineView(.animation)` implementation re-ran a Canvas draw and the
/// whole SwiftUI/AttributeGraph update every display frame on the main thread —
/// ~20% of a core per visible indeterminate bar. iOS keeps that version.
private struct GradientSweepProgressBar: View {
    let colors: [Color]

    var body: some View {
        #if os(macOS)
        GradientSweepLayerView(colors: colors)
        #else
        LegacyGradientSweep(colors: colors)
        #endif
    }
}

#if os(macOS)
/// Wraps a CAGradientLayer whose horizontal translation is animated by Core
/// Animation. Because it's a plain layer animation, macOS suspends it for free
/// when the window is occluded — no main-thread work while it sweeps.
private struct GradientSweepLayerView: NSViewRepresentable {
    let colors: [Color]

    func makeNSView(context: Context) -> GradientSweepNSView {
        GradientSweepNSView(colors: colors.map { NSColor($0) })
    }

    func updateNSView(_ nsView: GradientSweepNSView, context: Context) {
        nsView.setColors(colors.map { NSColor($0) })
    }
}

private final class GradientSweepNSView: NSView {
    private let gradient = CAGradientLayer()
    private var cgColors: [CGColor]
    private let period: CFTimeInterval = 1.5
    private static let animationKey = "sweep"

    init(colors: [NSColor]) {
        self.cgColors = Self.expand(colors)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        gradient.startPoint = CGPoint(x: 0, y: 0.5)
        gradient.endPoint = CGPoint(x: 1, y: 0.5)
        gradient.anchorPoint = CGPoint(x: 0, y: 0)
        applyColors()
        layer?.addSublayer(gradient)
    }

    required init?(coder: NSCoder) { fatalError() }

    func setColors(_ colors: [NSColor]) {
        let expanded = Self.expand(colors)
        guard expanded != cgColors else { return }
        cgColors = expanded
        applyColors()
    }

    /// Two full cycles plus a wrap stop, so translating by one period is seamless.
    private static func expand(_ colors: [NSColor]) -> [CGColor] {
        guard let first = colors.first else { return [] }
        return (colors + colors + [first]).map { $0.cgColor }
    }

    private func applyColors() {
        gradient.colors = cgColors
        let n = cgColors.count
        gradient.locations = (0..<n).map { NSNumber(value: Double($0) / Double(max(n - 1, 1))) }
    }

    override func layout() {
        super.layout()
        let w = bounds.width
        guard w > 0 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Twice the width so one full period is off-screen to the left; sliding
        // right by one period wraps seamlessly given the doubled color stops.
        gradient.frame = CGRect(x: 0, y: 0, width: w * 2, height: bounds.height)
        CATransaction.commit()
        installAnimation(width: w)
    }

    private func installAnimation(width w: CGFloat) {
        gradient.removeAnimation(forKey: Self.animationKey)
        let anim = CABasicAnimation(keyPath: "transform.translation.x")
        anim.fromValue = -w
        anim.toValue = 0
        anim.duration = period
        anim.repeatCount = .infinity
        anim.isRemovedOnCompletion = false
        gradient.add(anim, forKey: Self.animationKey)
    }
}
#else
/// Original SwiftUI implementation, retained for iOS.
private struct LegacyGradientSweep: View {
    let colors: [Color]
    private let duration: Double = 1.5

    var body: some View {
        TimelineView(.animation) { timeline in
            let phase = timeline.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: duration) / duration

            Canvas { context, size in
                let periodWidth = size.width
                let totalWidth = periodWidth * 2
                let offsetX = -periodWidth + CGFloat(phase) * periodWidth

                let allColors = colors + colors + [colors[0]]
                let stops = allColors.enumerated().map { i, color in
                    Gradient.Stop(color: color, location: CGFloat(i) / CGFloat(allColors.count - 1))
                }
                let gradient = Gradient(stops: stops)

                context.fill(
                    Path(CGRect(x: offsetX, y: 0, width: totalWidth, height: size.height)),
                    with: .linearGradient(
                        gradient,
                        startPoint: CGPoint(x: offsetX, y: 0),
                        endPoint: CGPoint(x: offsetX + totalWidth, y: 0)
                    )
                )
            }
        }
    }
}
#endif
