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
}
