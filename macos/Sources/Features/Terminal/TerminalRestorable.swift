import Cocoa

protocol TerminalRestorable: Codable {
    static var selfKey: String { get }
    static var versionKey: String { get }
    static var version: Int { get }
    /// Minimum version that can be decoded safely
    static var minimumVersion: Int { get }
    init(copy other: Self)

    /// Returns a base configuration to use when restoring terminal surfaces.
    /// Override this to provide custom environment variables or other configuration.
    var baseConfig: Ghostty.SurfaceConfiguration? { get }
}

extension TerminalRestorable {
    static var minimumVersion: Int { version }
}

extension TerminalRestorable {
    static var selfKey: String { "state" }
    static var versionKey: String { "version" }

    private var debugDescription: String {
        withUnsafePointer(to: self) { ptr in
            "<\(ptr)>[version: \(Self.version)]"
        }
    }

    /// Default implementation returns nil (no custom base config).
    var baseConfig: Ghostty.SurfaceConfiguration? { nil }

    init?(coder aDecoder: NSCoder) {
        // If the version doesn't match then we can't decode. In the future we can perform
        // version upgrading or something but for now we only have one version so we
        // don't bother.
        let current = aDecoder.decodeInteger(forKey: Self.versionKey)
        guard current >= Self.minimumVersion else {
            AppDelegate.logger.error("error restoring terminal: version not supported: expected=\(Self.minimumVersion, privacy: .public), got=\(current, privacy: .public)")
            return nil
        }

        guard let v = aDecoder.decodeObject(of: CodableBridge<Self>.self, forKey: Self.selfKey) else {
            AppDelegate.logger.error("error restoring terminal: decode failed")
            return nil
        }

        self.init(copy: v.value)
    }

    func encode(with coder: NSCoder) {
        coder.encode(Self.version, forKey: Self.versionKey)
        coder.encode(CodableBridge(self), forKey: Self.selfKey)

        AppDelegate.logger.debug("saved terminal state: \(debugDescription, privacy: .public)")
    }
}

/// The state stored for terminal window restoration.
final class TerminalRestorableState: TerminalRestorable {
    static var version: Int { 8 }
    static var minimumVersion: Int { 5 }

    var focusedSurface: String? {
        internalState.focusedSurface
    }
    var surfaceTree: SplitTree<Ghostty.SurfaceView> {
        internalState.surfaceTree
    }
    var effectiveFullscreenMode: FullscreenMode? {
        internalState.effectiveFullscreenMode
    }
    var tabColor: TerminalTabColor? {
        internalState.tabColor
    }
    var titleOverride: String? {
        internalState.titleOverride
    }

    /// Internal State we use to perform unit tests
    ///
    /// Since we can't really change the type of `TerminalRestorableState`
    /// due to `CodableBridge<TerminalRestorableState>` supporting secure coding,
    /// we use an internal type to perform migration and tests
    private let internalState: InternalState<Ghostty.SurfaceView>

    init(from controller: TerminalController) {
        internalState = .init(from: controller)
    }

    required init(copy other: TerminalRestorableState) {
        self.internalState = other.internalState
    }

    /// This is just wrapper around internalState
    ///
    /// - Important: If you intend to add more things, go to `InternalState`.
    init(from decoder: any Decoder) throws {
        self.internalState = try InternalState<Ghostty.SurfaceView>(from: decoder)
    }

    /// This is just wrapper around internalState
    ///
    /// - Important: If you intend to add more things, go to `InternalState`.
    func encode(to encoder: any Encoder) throws {
        try internalState.encode(to: encoder)
    }
}

enum TerminalRestoreError: Error {
    case delegateInvalid
    case identifierUnknown
    case stateDecodeFailed
    case windowDidNotLoad
}

/// The NSWindowRestoration implementation that is called when a terminal window needs to be restored.
/// The encoding of a terminal window is handled elsewhere (usually NSWindowDelegate).
class TerminalWindowRestoration: NSObject, NSWindowRestoration {
    static func restoreWindow(
        withIdentifier identifier: NSUserInterfaceItemIdentifier,
        state: NSCoder,
        completionHandler: @escaping (NSWindow?, Error?) -> Void
    ) {
        // Verify the identifier is what we expect
        guard identifier == .init(String(describing: Self.self)) else {
            completionHandler(nil, TerminalRestoreError.identifierUnknown)
            return
        }

        // The app delegate is definitely setup by now. If it isn't our AppDelegate
        // then something is royally fucked up but protect against it anyhow.
        guard let appDelegate = NSApplication.shared.delegate as? AppDelegate else {
            completionHandler(nil, TerminalRestoreError.delegateInvalid)
            return
        }

        // If our configuration is "never" then we never restore the state
        // no matter what. Note its safe to use "ghostty.config" directly here
        // because window restoration is only ever invoked on app start so we
        // don't have to deal with config reloads.
        if appDelegate.ghostty.config.windowSaveState == "never" {
            AppDelegate.logger.warning("skip restoration: window-save-state=never")
            completionHandler(nil, nil)
            return
        }

        // Decode the state. If we can't decode the state, then we can't restore.
        guard let state = TerminalRestorableState(coder: state) else {
            completionHandler(nil, TerminalRestoreError.stateDecodeFailed)
            return
        }

        // The window creation has to go through our terminalManager so that it
        // can be found for events from libghostty. This uses the low-level
        // createWindow so that AppKit can place the window wherever it should
        // be.
        let c = TerminalController.init(
            appDelegate.ghostty,
            withSurfaceTree: state.surfaceTree)
        guard let window = c.window else {
            completionHandler(nil, TerminalRestoreError.windowDidNotLoad)
            return
        }

        // Restore our tab color and avoid unnecessary `invalidateRestorableState` calls
        if let tabColor = state.tabColor {
            (window as? TerminalWindow)?.tabColor = tabColor
        }

        // Restore the tab title override
        c.titleOverride = state.titleOverride

        // Setup our restored state on the controller.
        if let focusedStr = state.focusedSurface {
            var foundView: Ghostty.SurfaceView?
            for view in c.surfaceTree where view.id.uuidString == focusedStr {
                foundView = view
                break
            }

            if let view = foundView {
                c.focusedSurface = view
                restoreFocus(to: view, inWindow: window)
            }
        }

        // Write restore commands for surfaces that had an agent running.
        // The shell integration hook picks these up after initialization
        // completes, avoiding races with interactive prompts (e.g. oh-my-zsh
        // update checks) that would consume characters from pty injection.
        for view in c.surfaceTree {
            guard let argv = view.savedAgentArgv,
                  let sessionID = view.savedAgentSessionID else { continue }
            view.savedAgentArgv = nil
            view.savedAgentSessionID = nil
            if let command = agentRestoreCommand(argv: argv, sessionID: sessionID) {
                writeRestoreFile(command, forSurfaceID: view.id)
            }
        }

        completionHandler(window, nil)
        guard let mode = state.effectiveFullscreenMode, mode != .native else {
            // We let AppKit handle native fullscreen
            return
        }
        // Give the window to AppKit first, then adjust its frame and style
        // to minimise any visible frame changes.
        c.toggleFullscreen(mode: mode)
    }

    // Claude Code flags that take no value. Any other flag consumes the next
    // token as its value, as Claude Code's own parser does for required and
    // optional values. Unknown flags are assumed to take one, so their value
    // is never mistaken for a prompt and dropped.
    private static let claudeBooleanFlags: Set<String> = [
        "--allow-dangerously-skip-permissions", "--ax-screen-reader", "--bare",
        "--brief", "--chrome", "--no-chrome", "--dangerously-skip-permissions",
        "--disable-slash-commands", "--exclude-dynamic-system-prompt-sections",
        "--forward-subagent-text", "--ide", "--include-hook-events",
        "--include-partial-messages", "--no-session-persistence",
        "--replay-user-messages", "--restricted", "--safe-mode",
        "--strict-mcp-config", "--verbose", "--fork-session",
        "-c", "--continue", "-p", "--print", "--bg", "--background",
        "-h", "--help", "-v", "--version",
    ]

    // Flags that consume every following non-flag token.
    private static let claudeVariadicFlags: Set<String> = [
        "--add-dir", "--allowedTools", "--allowed-tools", "--betas",
        "--disallowedTools", "--disallowed-tools", "--file", "--mcp-config", "--tools",
    ]

    // Flags that pick which session to open; replaced by `--resume <id>`.
    private static let claudeSessionFlags: Set<String> = [
        "-r", "--resume", "-c", "--continue", "--session-id", "--fork-session",
        "--from-pr", "--teleport",
    ]

    // Invocations that don't leave an interactive session to resume.
    private static let claudeNonInteractiveFlags: Set<String> = [
        "-p", "--print", "--bg", "--background", "-h", "--help", "-v", "--version",
    ]

    /// Builds the shell command that resumes a Claude Code session with the
    /// flags it was started with. Positional arguments (the initial prompt)
    /// are dropped so they aren't sent again on every restore, and repeated
    /// flags are collapsed: shell wrapper functions often inject the same
    /// flags on every invocation, and a long command can overflow the 1024
    /// byte canonical-mode line buffer before the shell switches to raw mode.
    static func agentRestoreCommand(argv: [String], sessionID: String) -> String? {
        guard let program = argv.first, UUID(uuidString: sessionID) != nil else { return nil }

        var units: [[String]] = []
        var i = 1
        while i < argv.count {
            let arg = argv[i]
            i += 1
            if arg == "--" { break }
            guard arg.hasPrefix("-"), arg.count > 1 else { continue }

            let name = arg.split(separator: "=", maxSplits: 1).first.map(String.init) ?? arg
            var unit = [arg]
            if !arg.contains("="), !claudeBooleanFlags.contains(name) {
                let variadic = claudeVariadicFlags.contains(name)
                while i < argv.count, !argv[i].hasPrefix("-") {
                    unit.append(argv[i])
                    i += 1
                    if !variadic { break }
                }
            }

            if claudeNonInteractiveFlags.contains(name) { return nil }
            if claudeSessionFlags.contains(name) { continue }
            if !units.contains(unit) { units.append(unit) }
        }

        let parts = [program] + units.flatMap { $0 } + ["--resume", sessionID]
        return parts.map { shellQuote($0) }.joined(separator: " ")
    }

    private static func shellQuote(_ s: String) -> String {
        if s.isEmpty { return "''" }
        let safe = s.allSatisfy { $0.isLetter || $0.isNumber || "-._/=:@".contains($0) }
        return safe ? s : "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func writeRestoreFile(_ command: String, forSurfaceID id: UUID) {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/ghostty", isDirectory: true)
        let file = dir.appendingPathComponent("\(id.uuidString).restore")
        try? command.write(to: file, atomically: true, encoding: .utf8)
    }

    /// This restores the focus state of the surfaceview within the given window. When restoring,
    /// the view isn't immediately attached to the window since we have to wait for SwiftUI to
    /// catch up. Therefore, we sit in an async loop waiting for the attachment to happen.
    private static func restoreFocus(to: Ghostty.SurfaceView, inWindow: NSWindow, attempts: Int = 0) {
        // For the first attempt, we schedule it immediately. Subsequent events wait a bit
        // so we don't just spin the CPU at 100%. Give up after some period of time.
        let after: DispatchTime
        if attempts == 0 {
            after = .now()
        } else if attempts > 40 {
            // 2 seconds, give up
            return
        } else {
            after = .now() + .milliseconds(50)
        }

        DispatchQueue.main.asyncAfter(deadline: after) {
            // If the view is not attached to a window yet then we repeat.
            guard let viewWindow = to.window else {
                restoreFocus(to: to, inWindow: inWindow, attempts: attempts + 1)
                return
            }

            // If the view is attached to some other window, we give up
            guard viewWindow == inWindow else { return }

            inWindow.makeFirstResponder(to)

            // If the window is main, then we also make sure it comes forward. This
            // prevents a bug found in #1177 where sometimes on restore the windows
            // would be behind other applications.
            if viewWindow.isMainWindow {
                viewWindow.orderFront(nil)
            }
        }
    }
}

