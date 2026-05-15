import Foundation

/// A single in-app notification toast.
///
/// Toasts are shown by `NotificationToastManager` as floating panels at the
/// top-right of the screen when the originating Ghostty window is focused.
/// When the window is not focused, the system notification path is used
/// instead so the user is alerted while in another app.
struct NotificationToast: Identifiable, Equatable {
    let id: UUID
    let title: String
    let subtitle: String
    let body: String
    let agent: CLIAgent?
    let surfaceID: UUID
    let createdAt: Date

    init(
        title: String,
        subtitle: String,
        body: String,
        agent: CLIAgent?,
        surfaceID: UUID
    ) {
        self.id = UUID()
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.agent = agent
        self.surfaceID = surfaceID
        self.createdAt = Date()
    }
}
