import Testing
import AppKit
@testable import Ghostty

struct TerminalWindowRestorationTests {
    private let screen = NSRect(x: 0, y: 0, width: 1920, height: 1080)
    private let frame = NSRect(x: 100, y: 480, width: 700, height: 500)

    private func coder(_ encode: (NSCoder) -> Void) throws -> NSCoder {
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        encode(archiver)
        archiver.finishEncoding()
        return try NSKeyedUnarchiver(forReadingFrom: archiver.encodedData)
    }

    @Test func restoresSavedFrameOnSameScreen() throws {
        let coder = try coder { TerminalWindow.encodeRestorableFrame(frame, screenFrame: screen, to: $0) }
        let other = NSRect(x: 1920, y: 0, width: 2560, height: 1440)
        #expect(TerminalWindow.restorableFrame(from: coder, screenFrames: [other, screen]) == frame)
    }

    @Test func leavesPlacementToAppKitWhenScreenIsGone() throws {
        let coder = try coder { TerminalWindow.encodeRestorableFrame(frame, screenFrame: screen, to: $0) }
        let resized = NSRect(x: 0, y: 0, width: 1512, height: 982)
        #expect(TerminalWindow.restorableFrame(from: coder, screenFrames: [resized]) == nil)
    }

    @Test func leavesPlacementToAppKitWithoutSavedFrame() throws {
        let coder = try coder { _ in }
        #expect(TerminalWindow.restorableFrame(from: coder, screenFrames: [screen]) == nil)
    }
}
