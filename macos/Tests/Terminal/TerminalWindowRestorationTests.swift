import Testing
import AppKit
@testable import Ghostty

struct TerminalWindowRestorationTests {
    @Test func copiesSavedStateDirectory() throws {
        let fm = FileManager.default
        let temporary = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: temporary) }
        let source = temporary.appendingPathComponent("source/nested")
        let evidence = temporary.appendingPathComponent("evidence")
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("saved window".utf8).write(to: source.appendingPathComponent("windows.plist"))

        TerminalWindowRestoration.backupSavedState(
            from: temporary.appendingPathComponent("source"), to: evidence, keeping: 5)

        let backups = try fm.contentsOfDirectory(at: evidence, includingPropertiesForKeys: nil)
        #expect(backups.count == 1)
        let backup = try #require(backups.first)
        #expect(try Data(contentsOf: backup.appendingPathComponent("nested/windows.plist")) == Data("saved window".utf8))
        #expect(fm.fileExists(atPath: source.appendingPathComponent("windows.plist").path))
    }

    @Test func keepsNewestSavedStateBackups() throws {
        let fm = FileManager.default
        let temporary = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: temporary) }
        let source = temporary.appendingPathComponent("source")
        let evidence = temporary.appendingPathComponent("evidence")
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        let olderNames = (1...5).map { "2000010\($0)-000000" }
        for name in olderNames {
            try fm.createDirectory(at: evidence.appendingPathComponent(name), withIntermediateDirectories: true)
        }

        TerminalWindowRestoration.backupSavedState(from: source, to: evidence, keeping: 5)

        let names = try fm.contentsOfDirectory(atPath: evidence.path)
        #expect(names.count == 5)
        #expect(!names.contains(olderNames[0]))
        #expect(olderNames.dropFirst().allSatisfy { names.contains($0) })
        #expect(names.contains { !olderNames.contains($0) })
    }

    @Test func missingSavedStateDoesNotCreateEvidenceDirectory() {
        let fm = FileManager.default
        let temporary = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let evidence = temporary.appendingPathComponent("evidence")
        TerminalWindowRestoration.backupSavedState(
            from: temporary.appendingPathComponent("missing"), to: evidence, keeping: 5)
        #expect(!fm.fileExists(atPath: temporary.path))
    }

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
