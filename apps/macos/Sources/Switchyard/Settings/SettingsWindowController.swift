import AppKit
import SwiftUI

/// Created when settings open and dropped when they close, so SwiftUI views don't stay in memory.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private let onClose: () -> Void
    private var form: NSScrollView?
    /// The tallest the window grows to fit the form. Past it, the form scrolls.
    private static let maxHeight: CGFloat = 720

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
        window.setContentSize(NSSize(width: 680, height: Self.maxHeight))
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
    }

    func show() {
        // A Dock icon while settings are open, so the window shows up in Cmd-Tab.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        watchFormHeight()
    }

    /// SwiftUI doesn't report a Form's content height on macOS, so this watches the scroll view that backs it.
    private func watchFormHeight() {
        guard form == nil else { return }
        window.layoutIfNeeded()
        guard let scroll = window.contentView?.firstSubview(of: NSScrollView.self), let document = scroll.documentView else { return }
        form = scroll
        document.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(fitToForm), name: NSView.frameDidChangeNotification, object: document)
        fitToForm()
    }

    /// Sizes the window to the form, up to `maxHeight` and the screen's height, keeping its top edge in place.
    @objc private func fitToForm() {
        guard let form, let document = form.documentView, let screen = window.screen ?? NSScreen.main else { return }
        let content = document.frame.height + form.contentInsets.top + form.contentInsets.bottom
        let fitted = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: 0, height: content)).height
        let height = min(fitted.rounded(.up), Self.maxHeight, screen.visibleFrame.height)
        var frame = window.frame
        guard abs(height - frame.height) >= 1 else { return }
        frame.origin.y += frame.height - height
        frame.size.height = height
        window.setFrame(frame, display: true)
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        onClose()
    }
}

private extension NSView {
    func firstSubview<View: NSView>(of type: View.Type) -> View? {
        for subview in subviews {
            if let match = subview as? View ?? subview.firstSubview(of: type) { return match }
        }
        return nil
    }
}
