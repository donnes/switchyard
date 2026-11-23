import AppKit
import OSLog
import SwitchyardCore

let log = Logger(subsystem: "dev.donnes.switchyard", category: "routing")

struct RecentLink {
    let link: URL
    let source: String
    let destination: String
    let problem: String?
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = ConfigStore(url: Config.defaultURL)
    let launcher = Launcher()
    private(set) var recent: [RecentLink] = []
    private var statusItem: StatusItemController?
    private var settings: SettingsWindowController?
    private var updater: UpdateController?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // The link that launched Switchyard arrives before applicationDidFinishLaunching, so the rules load first.
        store.load()
        // Our own handler instead of application(_:open:), because only the raw event carries the sender's PID.
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURL(_:reply:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = StatusItemController(app: self)
        store.onChange = { [weak self] in self?.statusItem?.refreshIcon() }
    }

    /// Opening the app again (Finder, Spotlight, Raycast) shows settings, since there is no Dock icon.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return false
    }

    @objc private func handleGetURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let text = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let link = URL(string: text) else { return }
        let pid = event.attributeDescriptor(forKeyword: keySenderPIDAttr)?.int32Value ?? 0
        route(link, senderPID: pid)
    }

    /// Local .html files, when Switchyard is the default for them.
    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        route(URL(filePath: filename), senderPID: 0)
        return true
    }

    func route(_ link: URL, senderPID: pid_t) {
        let started = ContinuousClock.now
        let source = LinkSource(senderPID: senderPID)
        let decision = store.router.decide(url: link, from: source.bundleID)
        let target = decision.target.browser == Bundle.main.bundleIdentifier ? Target(browser: "com.apple.Safari") : decision.target

        launcher.launch(link, target: target) { [weak self] problem in
            let elapsed = ContinuousClock.now - started
            log.info("\(source, privacy: .public) -> \(target.browser, privacy: .public) [rule \(decision.ruleID ?? "fallback", privacy: .public)] in \(elapsed, privacy: .public)")
            if let problem { log.error("\(problem, privacy: .public)") }
            self?.remember(RecentLink(
                link: link,
                source: source.label,
                destination: AppCatalog.label(for: target),
                problem: problem
            ))
        }
    }

    private func remember(_ entry: RecentLink) {
        recent.insert(entry, at: 0)
        if recent.count > 8 { recent.removeLast() }
        statusItem?.refreshIcon()
    }

    func showSettings() {
        if settings == nil {
            settings = SettingsWindowController(store: store) { [weak self] in self?.settings = nil }
        }
        settings?.show()
    }

    func checkForUpdates() {
        if let updater {
            updater.bringToFront()
            return
        }
        let controller = UpdateController(
            openURL: { [weak self] url in self?.openExternalURL(url) },
            onFinish: { [weak self] in self?.updater = nil }
        )
        updater = controller
        controller.checkForUpdates()
    }

    private func openExternalURL(_ url: URL) {
        if AppCatalog.isDefaultBrowser {
            route(url, senderPID: getpid())
        } else {
            NSWorkspace.shared.open(url)
        }
    }
}
