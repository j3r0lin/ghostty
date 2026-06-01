import SwiftUI

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

/// Gradient sweep progress bar — Canvas + TimelineView for guaranteed continuous animation
private struct GradientSweepProgressBar: View {
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
