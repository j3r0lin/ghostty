import AppKit
import SwiftUI
import OSLog

/// Manages the stack of in-app notification toasts.
///
/// Each visible toast lives in its own borderless, non-activating `NSPanel`
/// that floats above all windows and follows the user across Spaces. The
/// manager handles positioning, auto-dismissal (paused while the user is
/// hovering the toast), and click-through to focus the source surface.
///
/// Toasts are bounded to `maxVisible` to avoid covering the screen; the
/// oldest is evicted when a new one arrives over the limit.
@MainActor
final class NotificationToastManager {
    static let shared = NotificationToastManager()

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier!,
        category: String(describing: NotificationToastManager.self)
    )

    /// How long a toast stays on screen before auto-dismissal.
    private let displayDuration: TimeInterval = 8.0
    /// Maximum number of toasts visible simultaneously.
    private let maxVisible: Int = 3
    /// Vertical gap between stacked toasts, in points.
    private let stackGap: CGFloat = 4
    /// Inset from the screen edges, in points.
    private let edgeInset: CGFloat = 8

    /// Look up a surface by its UUID (set by the integration layer).
    var surfaceLookup: ((UUID) -> Ghostty.SurfaceView?)?

    private struct Entry {
        let toast: NotificationToast
        let panel: NSPanel
        var dismissTask: Task<Void, Never>?
    }

    private var entries: [Entry] = []

    // MARK: - Public API

    /// Show a toast. Returns immediately; auto-dismissal is scheduled.
    func show(_ toast: NotificationToast) {
        // Evict oldest if at the cap.
        while entries.count >= maxVisible {
            removeEntry(at: 0, animated: false)
        }

        let panel = makePanel(for: toast)
        var entry = Entry(toast: toast, panel: panel, dismissTask: nil)
        entries.append(entry)

        panel.alphaValue = 0
        positionPanels()
        panel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            panel.animator().alphaValue = 1
        }

        let id = toast.id
        let task = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(self?.displayDuration ?? 8))
            guard !Task.isCancelled else { return }
            self?.dismiss(id: id)
        }

        if let idx = entries.firstIndex(where: { $0.toast.id == toast.id }) {
            entry.dismissTask = task
            entries[idx] = entry
        }
    }

    /// Dismiss a specific toast by ID. No-op if not currently shown.
    func dismiss(id: UUID) {
        guard let idx = entries.firstIndex(where: { $0.toast.id == id }) else { return }
        removeEntry(at: idx, animated: true)
    }

    /// Pause auto-dismissal for the given toast (used while the cursor is over it).
    func pauseTimer(for id: UUID) {
        guard let idx = entries.firstIndex(where: { $0.toast.id == id }) else { return }
        entries[idx].dismissTask?.cancel()
        entries[idx].dismissTask = nil
    }

    /// Restart auto-dismissal for the given toast.
    func resumeTimer(for id: UUID) {
        guard let idx = entries.firstIndex(where: { $0.toast.id == id }) else { return }
        let toastID = entries[idx].toast.id
        let task = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(self?.displayDuration ?? 8))
            guard !Task.isCancelled else { return }
            self?.dismiss(id: toastID)
        }
        entries[idx].dismissTask = task
    }

    // MARK: - Internals

    private func makePanel(for toast: NotificationToast) -> NSPanel {
        let view = NotificationToastView(
            toast: toast,
            onClick: { [weak self] in self?.handleClick(id: toast.id) },
            onClose: { [weak self] in self?.dismiss(id: toast.id) }
        )
        let host = NSHostingView(rootView: view)
        host.frame.size = host.fittingSize

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: host.fittingSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .stationary,
            .fullScreenAuxiliary,
            .ignoresCycle,
        ]
        panel.contentView = host
        return panel
    }

    /// Shadow padding around each toast inside its panel.
    /// Must match the `.padding(12)` at the end of `NotificationToastView.body`.
    private let shadowPad: CGFloat = 12

    private func positionPanels() {
        guard let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        var topY = frame.maxY - 38

        for entry in entries {
            let panelW = entry.panel.frame.width
            let panelH = entry.panel.frame.height
            let visibleH = panelH - 2 * shadowPad
            // Right edge of visible toast hugs screen.maxX - edgeInset, so:
            let panelX = frame.maxX - edgeInset - panelW + shadowPad
            // Panel origin (bottom-left). topY is the top of the visible toast.
            let panelY = topY - visibleH - shadowPad
            entry.panel.setFrameOrigin(NSPoint(x: panelX, y: panelY))
            topY -= visibleH + stackGap
        }
    }

    private func removeEntry(at index: Int, animated: Bool) {
        guard index >= 0, index < entries.count else { return }
        let entry = entries.remove(at: index)
        entry.dismissTask?.cancel()

        if animated {
            let panel = entry.panel
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                panel.animator().alphaValue = 0
            } completionHandler: {
                panel.orderOut(nil)
            }
        } else {
            entry.panel.orderOut(nil)
        }

        positionPanels()
    }

    private func handleClick(id: UUID) {
        guard let entry = entries.first(where: { $0.toast.id == id }) else { return }
        let surfaceID = entry.toast.surfaceID

        if let lookup = surfaceLookup, let surface = lookup(surfaceID) {
            surface.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            Ghostty.moveFocus(to: surface)
        } else {
            Self.logger.warning("toast click: could not find surface for \(surfaceID)")
        }

        if let appDelegate = NSApplication.shared.delegate as? AppDelegate {
            appDelegate.ghostty.removeUnreadNotification(surfaceID: surfaceID)
        }

        dismiss(id: id)
    }
}
