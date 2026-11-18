import AppKit
import SwiftUI

/// Created when settings open and dropped when they close, so SwiftUI views don't stay in memory.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private let onClose: () -> Void

    init(store: ConfigStore, onClose: @escaping () -> Void) {
        self.onClose = onClose
        let host = NSHostingController(rootView: SettingsView(store: store))
        // Hands the SwiftUI toolbar and title to the window, so they render as its glass toolbar.
        host.sceneBridgingOptions = [.toolbars, .title]
        window = NSWindow(contentViewController: host)
        super.init()
        window.title = "Switchyard"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.toolbarStyle = .unified
        window.setContentSize(NSSize(width: 680, height: 720))
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
    }

    func show() {
        // A Dock icon while settings are open, so the window shows up in Cmd-Tab.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        onClose()
    }
}
