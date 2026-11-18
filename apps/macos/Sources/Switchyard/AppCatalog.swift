import AppKit
import SwitchyardCore

struct AppInfo: Identifiable, Hashable {
    let id: String // bundle identifier
    let name: String
}

/// App names and lists for menus and settings, looked up through Launch Services.
@MainActor
enum AppCatalog {
    private static var names: [String: String] = [:]

    static func name(for bundleID: String) -> String {
        if let cached = names[bundleID] { return cached }
        let name = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") }
            ?? bundleID
        names[bundleID] = name
        return name
    }

    /// "Ardia · Personal", "Zen · Work container".
    static func label(for target: Target) -> String {
        var parts = [name(for: target.browser)]
        if let profile = target.profile, !profile.isEmpty { parts.append(profile) }
        if let container = target.container, !container.isEmpty { parts.append("\(container) container") }
        if target.background == true { parts.append("background") }
        return parts.joined(separator: " · ")
    }

    /// Apps that can open web links, except Switchyard.
    static func browsers() -> [AppInfo] {
        let urls = NSWorkspace.shared.urlsForApplications(toOpen: URL(string: "https://example.com")!)
        return uniqueApps(urls.compactMap { Bundle(url: $0)?.bundleIdentifier })
    }

    /// Apps with a Dock icon that are running now, the likely sources of links.
    static func runningApps() -> [AppInfo] {
        uniqueApps(NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap(\.bundleIdentifier))
    }

    static func app(at url: URL) -> AppInfo? {
        guard let id = Bundle(url: url)?.bundleIdentifier else { return nil }
        return AppInfo(id: id, name: name(for: id))
    }

    private static func uniqueApps(_ ids: [String]) -> [AppInfo] {
        let me = Bundle.main.bundleIdentifier
        return Set(ids).subtracting([me].compactMap { $0 })
            .map { AppInfo(id: $0, name: name(for: $0)) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static var isDefaultBrowser: Bool {
        guard let handler = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com")!) else { return false }
        return Bundle(url: handler)?.bundleIdentifier == Bundle.main.bundleIdentifier
    }

    /// macOS asks the user to confirm the change.
    static func becomeDefaultBrowser() {
        let me = Bundle.main.bundleURL
        Task {
            for scheme in ["http", "https"] {
                try? await NSWorkspace.shared.setDefaultApplication(at: me, toOpenURLsWithScheme: scheme)
            }
        }
    }
}
