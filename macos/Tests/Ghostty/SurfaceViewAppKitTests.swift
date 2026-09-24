import AppKit
@testable import Ghostty
import Testing

struct SurfaceViewAppKitTests {
    @Test(arguments: [
        ("\u{0008}", true),
        ("\u{001F}", true),
        ("\u{007F}", false),
        (" ", false),
        ("h", false),
        ("", false),
        ("\u{0009}x", false),
        ("\u{0009}\u{0009}", false),
    ])
    func suppressesOnlySingleC0ControlTextWhileComposing(
        text: String,
        expected: Bool
    ) {
        #expect(
            Ghostty.SurfaceView.shouldSuppressComposingControlInput(
                text,
                composing: true
            ) == expected
        )
    }

    @Test func doesNotSuppressControlTextWhenNotComposing() {
        #expect(
            Ghostty.SurfaceView.shouldSuppressComposingControlInput(
                "\u{0008}",
                composing: false
            ) == false
        )
    }

    @Test func doesNotSuppressMissingText() {
        #expect(
            Ghostty.SurfaceView.shouldSuppressComposingControlInput(
                nil,
                composing: true
            ) == false
        )
    }

    @Test func progressGoesStaleWhenReporterLeavesForeground() {
        var owner = Ghostty.SurfaceView.ProgressOwner()
        owner.record(reporting: true, foreground: 100)
        #expect(!owner.isStale(foreground: 100))
        #expect(owner.isStale(foreground: 42))
    }

    @Test func progressFollowsLatestReporter() {
        var owner = Ghostty.SurfaceView.ProgressOwner()
        owner.record(reporting: true, foreground: 100)
        owner.record(reporting: true, foreground: 42)
        #expect(!owner.isStale(foreground: 42))
        #expect(owner.isStale(foreground: 100))
    }

    @Test func clearedProgressIsNeverStale() {
        var owner = Ghostty.SurfaceView.ProgressOwner()
        owner.record(reporting: true, foreground: 100)
        owner.record(reporting: false, foreground: 100)
        #expect(!owner.isStale(foreground: 42))
    }

    @Test func progressWithUnknownForegroundIsNeverStale() {
        var owner = Ghostty.SurfaceView.ProgressOwner()
        owner.record(reporting: true, foreground: nil)
        #expect(!owner.isStale(foreground: 42))
    }

    @MainActor
    @Test func bringTabToFrontSelectsTheWindowsTab() throws {
        func makeWindow() -> NSWindow {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false)
            window.isReleasedWhenClosed = false
            window.tabbingMode = .preferred
            return window
        }
        let front = makeWindow()
        let back = makeWindow()
        defer {
            back.close()
            front.close()
        }
        front.orderFront(nil)
        front.addTabbedWindow(back, ordered: .above)
        let tabGroup = try #require(front.tabGroup)
        tabGroup.selectedWindow = front
        try #require(tabGroup.selectedWindow === front)

        Ghostty.SurfaceView.bringTabToFront(back)

        #expect(tabGroup.selectedWindow === back)
    }
}
