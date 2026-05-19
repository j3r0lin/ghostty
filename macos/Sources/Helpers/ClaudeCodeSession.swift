import Foundation

/// Session metadata cached by `~/.claude/hooks/ghostty_*.py`, keyed by Ghostty
/// surface UUID (exposed to child processes as `ITERM_SESSION_ID=ghostty:<UUID>`).
enum ClaudeCodeSession {
    /// The literal title Claude Code emits via OSC 777 for its built-in idle alert.
    static let defaultTitle = "Claude Code"

    struct SessionInfo {
        let sessionID: String
        let cwd: String?
        let title: String?
        let status: String?
    }

    static func latestSession(forTerminalID id: String, requiringStatus: String? = nil) -> SessionInfo? {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/ghostty", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        ) else { return nil }

        var best: (started: String, info: SessionInfo)?
        for url in files where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  obj["terminal_id"] as? String == id
            else { continue }
            if let required = requiringStatus, obj["status"] as? String != required { continue }
            let started = obj["started_at"] as? String ?? ""
            let info = SessionInfo(
                sessionID: url.deletingPathExtension().lastPathComponent,
                cwd: obj["cwd"] as? String,
                title: obj["title"] as? String,
                status: obj["status"] as? String)
            if best == nil || started > best!.started {
                best = (started, info)
            }
        }
        return best?.info
    }

    static func cachedTitle(forTerminalID id: String) -> String? {
        guard let session = latestSession(forTerminalID: id, requiringStatus: "running"),
              let title = session.title, !title.isEmpty
        else { return nil }
        return title
    }
}
