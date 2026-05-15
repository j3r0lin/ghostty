import Foundation

/// Session metadata cached by `~/.claude/hooks/ghostty_*.py`, keyed by Ghostty
/// surface UUID (exposed to child processes as `ITERM_SESSION_ID=ghostty:<UUID>`).
enum ClaudeCodeSession {
    /// The literal title Claude Code emits via OSC 777 for its built-in idle alert.
    static let defaultTitle = "Claude Code"

    static func cachedTitle(forTerminalID id: String) -> String? {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/ghostty", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        ) else { return nil }

        var best: (started: String, title: String)?
        for url in files where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  obj["terminal_id"] as? String == id,
                  obj["status"] as? String == "running",
                  let title = obj["title"] as? String,
                  !title.isEmpty
            else { continue }
            let started = obj["started_at"] as? String ?? ""
            if best == nil || started > best!.started {
                best = (started, title)
            }
        }
        return best?.title
    }
}
