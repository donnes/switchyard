import AppKit
import ServiceManagement

/// The menu bar icon. The menu is rebuilt each time it opens, so it costs nothing while closed.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private unowned let app: AppDelegate
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

    init(app: AppDelegate) {
        self.app = app
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        refreshIcon()
    }

    func refreshIcon() {
        let hasProblem = app.store.error != nil || app.recent.first?.problem != nil
        let image = hasProblem
            ? NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: "Switchyard has a problem")
            : Self.fork
        image?.isTemplate = true
        item.button?.image = image
        item.button?.toolTip = app.store.error ?? "Switchyard"
    }

    /// The app icon's fork (assets/app-icon.icon/Assets/fork.svg) at menu bar size: the same 5 × 5 grid
    /// and diagonal fade, as a template so the menu bar tints it. Squares are 3 pt on a 3.5 pt pitch,
    /// which lands on whole pixels at 2x.
    private static let fork: NSImage = {
        let rows = ["X...X",
                    "XX.XX",
                    ".XXX.",
                    "..X..",
                    "..X.."]
        let image = NSImage(size: NSSize(width: 17, height: 17), flipped: true) { _ in
            for (r, line) in rows.enumerated() {
                for (c, cell) in line.enumerated() where cell == "X" {
                    NSColor.black.withAlphaComponent(1 - 0.8 * CGFloat(c + r) / 8).setFill()
                    NSRect(x: CGFloat(c) * 3.5, y: CGFloat(r) * 3.5, width: 3, height: 3).fill()
                }
            }
            return true
        }
        image.accessibilityDescription = "Switchyard"
        return image
    }()

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        if let error = app.store.error {
            menu.addItem(disabled: "Config problem: \(error)")
            menu.addItem(.separator())
        }

        if AppCatalog.isDefaultBrowser {
            menu.addItem(disabled: "Switchyard is your default browser")
        } else {
            menu.addItem(action("Make Switchyard the Default Browser…", #selector(makeDefault)))
        }

        menu.addItem(.separator())
        if app.recent.isEmpty {
            menu.addItem(disabled: "No links yet")
        } else {
            menu.addItem(NSMenuItem.sectionHeader(title: "Recent links"))
            for entry in app.recent {
                let item = action("\(entry.source) → \(entry.destination)", #selector(copyLink(_:)))
                item.toolTip = [entry.link.absoluteString, entry.problem].compactMap { $0 }.joined(separator: "\n")
                item.representedObject = entry.link
                if entry.problem != nil {
                    item.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: "Problem")
                }
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())
        menu.addItem(action("Settings…", #selector(openSettings), key: ","))
        menu.addItem(action("Edit Config File", #selector(editConfig)))
        let login = action("Open at Login", #selector(toggleOpenAtLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(action("Quit Switchyard", #selector(quit), key: "q"))
    }

    private func action(_ title: String, _ selector: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func makeDefault() { AppCatalog.becomeDefaultBrowser() }
    @objc private func openSettings() { app.showSettings() }
    @objc private func editConfig() { NSWorkspace.shared.open(app.store.url) }
    @objc private func quit() { NSApp.terminate(nil) }

    /// Running from login keeps the first link after a restart from waiting for Switchyard to start.
    @objc private func toggleOpenAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch where service.status != .requiresApproval {
            let alert = NSAlert(error: error)
            alert.messageText = "Switchyard couldn't change Open at Login."
            NSApp.activate()
            alert.runModal()
        } catch {}
        if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
    }

    /// Clicking a recent link copies it.
    @objc private func copyLink(_ sender: NSMenuItem) {
        guard let link = sender.representedObject as? URL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(link.absoluteString, forType: .string)
    }
}

private extension NSMenu {
    func addItem(disabled title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        addItem(item)
    }
}
