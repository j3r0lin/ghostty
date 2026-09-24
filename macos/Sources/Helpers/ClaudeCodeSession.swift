import Foundation

/// Session metadata written by the Claude Code Ghostty hook (`ghostty_hooks.lua`),
/// keyed by Ghostty surface UUID (exposed to child processes as
/// `ITERM_SESSION_ID=ghostty:<UUID>`).
enum ClaudeCodeSession {
    /// The literal title Claude Code emits via OSC 777 for its built-in idle alert.
    static let defaultTitle = "Claude Code"

    struct SessionInfo {
        let sessionID: String
        let cwd: String?
        let title: String?
        let status: String?
    }

    static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/ghostty", isDirectory: true)

    private struct CachedFile {
        let modified: timespec
        let inode: ino_t
        let size: off_t
        let terminalID: String?
        let started: String
        let info: SessionInfo
    }

    // Parsed session files per directory, keyed by file name. Every
    // notification and every restorable-state save of a Claude surface looks
    // sessions up, and the hook keeps days of files, so re-reading them all
    // costs milliseconds on the main thread each time. Path APIs and stat(2)
    // are used because URL resource lookups on fresh URLs cost as much as the
    // parsing they save. Guarded by cacheLock.
    nonisolated(unsafe) private static var cache: [String: [String: CachedFile]] = [:]
    private static let cacheLock = NSLock()

    static func latestSession(
        forTerminalID id: String,
        requiringStatus: String? = nil,
        in dir: URL = directory
    ) -> SessionInfo? {
        let dirPath = dir.path
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dirPath) else { return nil }

        cacheLock.lock()
        defer { cacheLock.unlock() }

        let previous = cache[dirPath] ?? [:]
        var current: [String: CachedFile] = [:]
        var best: CachedFile?
        for name in names where name.hasSuffix(".json") {
            guard let entry = cachedFile(at: dirPath + "/" + name, name: name, previous: previous[name])
            else { continue }
            current[name] = entry
            guard entry.terminalID == id else { continue }
            if let required = requiringStatus, entry.info.status != required { continue }
            if best == nil || entry.started > best!.started {
                best = entry
            }
        }
        cache[dirPath] = current
        return best?.info
    }

    private static func cachedFile(at path: String, name: String, previous: CachedFile?) -> CachedFile? {
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        let modified = st.st_mtimespec
        if let previous, previous.inode == st.st_ino, previous.size == st.st_size,
           previous.modified.tv_sec == modified.tv_sec,
           previous.modified.tv_nsec == modified.tv_nsec {
            return previous
        }

        guard let data = FileManager.default.contents(atPath: path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return CachedFile(
            modified: modified,
            inode: st.st_ino,
            size: st.st_size,
            terminalID: obj["terminal_id"] as? String,
            started: obj["started_at"] as? String ?? "",
            info: SessionInfo(
                sessionID: String(name.dropLast(".json".count)),
                cwd: obj["cwd"] as? String,
                title: obj["title"] as? String,
                status: obj["status"] as? String))
    }

    static func cachedTitle(forTerminalID id: String) -> String? {
        guard let session = latestSession(forTerminalID: id, requiringStatus: "running"),
              let title = session.title, !title.isEmpty
        else { return nil }
        return title
    }
}
