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

        AppDelegate.logger.debug("saved terminal state: \(debugDescription)")
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
    var agentArgv: [String]? {
        internalState.agentArgv
    }
    var agentTerminalID: String? {
        internalState.agentTerminalID
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

        // Build agent restore command to inject into the shell after restoration.
        // We restore the normal surface tree (shell) and send the command as
        // initial input, so the shell has full PATH/profile and stays alive
        // even if the command fails.
        var agentRestoreInput: String?
        if let agentArgv = state.agentArgv, !agentArgv.isEmpty {
            let session = state.agentTerminalID.flatMap {
                ClaudeCodeSession.latestSession(forTerminalID: $0)
            }
            if let command = agentRestoreCommand(argv: agentArgv, sessionID: session?.sessionID) {
                agentRestoreInput = command
            }
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

        if let input = agentRestoreInput, let surfaceView = c.focusedSurface {
            sendTextWhenReady(input, to: surfaceView)
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

    static func agentRestoreCommand(argv: [String], sessionID: String?) -> String? {
        guard !argv.isEmpty else { return nil }

        // Flags that take a value (so we also need to drop the next token).
        let stripWithValue: Set<String> = ["--resume", "-r", "--session-id"]
        // Boolean flags (no following value).
        let stripBoolean: Set<String> = ["--continue", "-c"]

        var parts = argv
        var i = 0
        while i < parts.count {
            let flag = parts[i]
            if stripWithValue.contains(flag) {
                parts.remove(at: i)
                if i < parts.count && !parts[i].hasPrefix("-") {
                    parts.remove(at: i)
                }
                continue
            }
            if stripBoolean.contains(flag) {
                parts.remove(at: i)
                continue
            }
            i += 1
        }

        // Deduplicate flags: shell wrapper functions (e.g. the user's claude()
        // alias) often inject the same flags on every invocation, so the
        // captured argv can contain 3× copies of "--flag value" pairs.
        // macOS pty canonical-mode line buffer is 1024 bytes — a long
        // command that arrives before the shell switches to raw mode gets
        // truncated, losing the trailing CR and preventing execution.
        parts = deduplicateFlags(parts)

        if let sessionID = sessionID, UUID(uuidString: sessionID) != nil {
            parts.append(contentsOf: ["--resume", sessionID])
        }

        return parts.map { shellQuote($0) }.joined(separator: " ")
    }

    static func deduplicateFlags(_ parts: [String]) -> [String] {
        guard parts.count > 1 else { return parts }
        var result = [parts[0]]
        var seen = Set<String>()
        var i = 1
        while i < parts.count {
            let arg = parts[i]
            if arg.hasPrefix("-") {
                let hasValue = i + 1 < parts.count && !parts[i + 1].hasPrefix("-")
                let key = hasValue ? arg + "\0" + parts[i + 1] : arg
                if seen.contains(key) {
                    i += hasValue ? 2 : 1
                    continue
                }
                seen.insert(key)
                result.append(arg)
                if hasValue {
                    result.append(parts[i + 1])
                    i += 2
                } else {
                    i += 1
                }
            } else {
                result.append(arg)
                i += 1
            }
        }
        return result
    }

    private static func shellQuote(_ s: String) -> String {
        if s.isEmpty { return "''" }
        let safe = s.allSatisfy { $0.isLetter || $0.isNumber || "-._/=:@".contains($0) }
        return safe ? s : "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func sendTextWhenReady(_ text: String, to view: Ghostty.SurfaceView, attempts: Int = 0) {
        // Wait longer on the first attempt to give the shell time to finish
        // startup scripts and switch from canonical to raw mode. In canonical
        // mode the pty line buffer is only 1024 bytes; characters beyond that
        // (including the trailing CR) are silently dropped by the kernel.
        let after: DispatchTime
        if attempts == 0 {
            after = .now() + .milliseconds(500)
        } else if attempts > 30 {
            return
        } else {
            after = .now() + .milliseconds(150)
        }

        DispatchQueue.main.asyncAfter(deadline: after) {
            guard let surface = view.surfaceModel, view.window != nil else {
                sendTextWhenReady(text, to: view, attempts: attempts + 1)
                return
            }
            guard let pid = surface.foregroundPID, pid > 0 else {
                sendTextWhenReady(text, to: view, attempts: attempts + 1)
                return
            }

            // Send the command text, then press Enter via a key event.
            // sendText goes through paste encoding: if the shell has
            // enabled bracketed paste mode, \n would NOT be converted
            // to \r and the command wouldn't execute. Sending Enter as a
            // key event bypasses paste encoding entirely.
            surface.sendText(text)
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(50)) {
                guard view.window != nil else { return }
                surface.sendKeyEvent(Ghostty.Input.KeyEvent(key: .enter, text: "\r"))
            }
        }
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

