import Foundation
import Testing
@testable import Ghostty

struct ClaudeCodeSessionTests {
    private let dir: URL
    private let terminal = UUID().uuidString

    init() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    private func write(_ session: String, terminal: String, started: String, status: String,
                       title: String = "t", modified: Date = Date()) throws {
        let url = dir.appendingPathComponent("\(session).json")
        let obj: [String: Any] = [
            "terminal_id": terminal, "started_at": started, "status": status, "title": title,
        ]
        try JSONSerialization.data(withJSONObject: obj).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
    }

    private func latest(requiring status: String? = nil) -> ClaudeCodeSession.SessionInfo? {
        ClaudeCodeSession.latestSession(forTerminalID: terminal, requiringStatus: status, in: dir)
    }

    @Test func returnsMostRecentlyStartedSessionForTerminal() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("old", terminal: terminal, started: "2026-09-01T10:00:00", status: "running")
        try write("new", terminal: terminal, started: "2026-09-02T10:00:00", status: "running")
        try write("other", terminal: UUID().uuidString, started: "2026-09-03T10:00:00", status: "running")
        #expect(latest()?.sessionID == "new")
    }

    @Test func filtersByStatus() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("ended", terminal: terminal, started: "2026-09-02T10:00:00", status: "ended")
        try write("running", terminal: terminal, started: "2026-09-01T10:00:00", status: "running")
        #expect(latest(requiring: "running")?.sessionID == "running")
    }

    @Test func picksUpRewrittenFile() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let t0 = Date(timeIntervalSinceNow: -60)
        try write("s", terminal: terminal, started: "2026-09-01T10:00:00", status: "running", title: "a", modified: t0)
        #expect(latest(requiring: "running")?.title == "a")

        try write("s", terminal: terminal, started: "2026-09-01T10:00:00", status: "ended", title: "b",
                  modified: t0.addingTimeInterval(1))
        #expect(latest(requiring: "running") == nil)
        #expect(latest()?.title == "b")
    }

    @Test func forgetsDeletedFile() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("s", terminal: terminal, started: "2026-09-01T10:00:00", status: "running")
        #expect(latest()?.sessionID == "s")
        try FileManager.default.removeItem(at: dir.appendingPathComponent("s.json"))
        #expect(latest() == nil)
    }
}
