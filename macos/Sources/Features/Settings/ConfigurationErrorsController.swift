import Foundation
import Cocoa
import SwiftUI
import Combine

class ConfigurationErrorsController: NSWindowController, NSWindowDelegate, ConfigurationErrorsViewModel {
    /// Singleton for the errors view.
    static let sharedInstance = ConfigurationErrorsController()

    override var windowNibName: NSNib.Name? { "ConfigurationErrors" }

    /// What the window is reporting. A rejection means the running
    /// configuration was kept; diagnostics mean the configuration was
    /// applied with the offending lines skipped.
    enum Notice: Equatable {
        case diagnostics
        case rejected
    }

    /// The data model for this view. Update this directly and the associated view will be updated, too.
    @Published var errors: [String] = [] {
        didSet {
            if errors.count == 0 {
                // Only close the window if it was ever loaded: accessing
                // `window` on an NSWindowController loads the nib (and our
                // SwiftUI content view), which takes tens of milliseconds.
                // This happens on every app launch via the initial config
                // apply, when there are usually no errors and the window
                // was never loaded.
                if isWindowLoaded {
                    self.window?.performClose(nil)
                }
            }
        }
    }

    @Published var notice: Notice = .diagnostics

    /// Show a reload that was refused. The running configuration is unchanged.
    func present(_ rejection: Ghostty.Config.Rejection) {
        let messages: [String]
        switch rejection {
        case .invalid(let diagnostics), .unloadable(let diagnostics):
            messages = diagnostics
        }
        notice = .rejected
        errors = messages.isEmpty
            ? ["The configuration could not be loaded, so the running configuration was kept."]
            : messages
        if window == nil || !window!.isVisible {
            showWindow(nil)
        }
    }

    // MARK: - NSWindowController

    override func windowWillLoad() {
        shouldCascadeWindows = false
    }

    override func windowDidLoad() {
        guard let window = window else { return }
        window.center()
        window.level = .popUpMenu
        window.contentView = NSHostingView(rootView: ConfigurationErrorsView(model: self))
        window.titlebarAppearsTransparent = true
    }
}
