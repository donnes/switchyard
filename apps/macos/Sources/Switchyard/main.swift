import AppKit

// A menu bar app: no Dock icon, no SwiftUI app lifecycle. SwiftUI loads only with the settings window.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
