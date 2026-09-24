import Foundation
import Testing
@testable import Ghostty

@MainActor
struct NotificationToastManagerTests {
    private func makeToast() -> NotificationToast {
        NotificationToast(title: "t", subtitle: "", body: "b", agent: nil, surfaceID: UUID())
    }

    /// Polls until the toast is gone; the dismiss task shares the main actor
    /// with the test, so a busy host app can delay it.
    private func waitUntilDismissed(_ manager: NotificationToastManager, _ id: UUID) async throws -> Bool {
        for _ in 0..<100 where manager.isShowing(id: id) {
            try await Task.sleep(for: .milliseconds(20))
        }
        return !manager.isShowing(id: id)
    }

    @Test func dismissesAfterDisplayDuration() async throws {
        let manager = NotificationToastManager(displayDuration: 0.1)
        let toast = makeToast()
        manager.show(toast)
        #expect(manager.isShowing(id: toast.id))
        #expect(try await waitUntilDismissed(manager, toast.id))
    }

    @Test func hoveredToastStaysUntilCursorLeaves() async throws {
        let manager = NotificationToastManager(displayDuration: 0.1)
        let toast = makeToast()
        manager.show(toast)
        manager.hoverChanged(id: toast.id, hovering: true)
        try await Task.sleep(for: .milliseconds(400))
        #expect(manager.isShowing(id: toast.id))

        manager.hoverChanged(id: toast.id, hovering: false)
        #expect(try await waitUntilDismissed(manager, toast.id))
    }

    @Test func repeatedHoverExitDoesNotOutliveNextHover() async throws {
        let manager = NotificationToastManager(displayDuration: 0.1)
        let toast = makeToast()
        manager.show(toast)
        manager.hoverChanged(id: toast.id, hovering: false)
        manager.hoverChanged(id: toast.id, hovering: false)
        manager.hoverChanged(id: toast.id, hovering: true)
        try await Task.sleep(for: .milliseconds(400))
        #expect(manager.isShowing(id: toast.id))
        manager.dismiss(id: toast.id)
    }
}
