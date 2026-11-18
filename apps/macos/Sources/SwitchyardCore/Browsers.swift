import Foundation

/// How a browser takes a profile from outside. Decides both discovery and launching.
public enum BrowserKind: Hashable, Sendable {
    /// `--profile-directory=<dir>`. `dataDir` is relative to Application Support.
    case chromium(dataDir: String)
    /// `-P <name>` and `ext+container:` links. `dataDir` is relative to Application Support.
    case firefox(dataDir: String)
    /// Ardia's control socket, which opens a tab in a given profile.
    case ardia
    /// Anything else: the link goes to the app as is.
    case plain

    public static func of(_ bundleID: String) -> BrowserKind {
        if bundleID == ardiaBundleID { return .ardia }
        if let dir = chromiumDirs[bundleID] { return .chromium(dataDir: dir) }
        if let dir = firefoxDirs[bundleID] { return .firefox(dataDir: dir) }
        return .plain
    }

    public static let ardiaBundleID = "com.ardia.browser"

    static let chromiumDirs = [
        "com.google.Chrome": "Google/Chrome",
        "com.google.Chrome.beta": "Google/Chrome Beta",
        "com.google.Chrome.canary": "Google/Chrome Canary",
        "org.chromium.Chromium": "Chromium",
        "com.brave.Browser": "BraveSoftware/Brave-Browser",
        "com.brave.Browser.nightly": "BraveSoftware/Brave-Browser-Nightly",
        "com.microsoft.edgemac": "Microsoft Edge",
        "com.vivaldi.Vivaldi": "Vivaldi",
        "net.imput.helium": "net.imput.helium",
    ]

    static let firefoxDirs = [
        "org.mozilla.firefox": "Firefox",
        "org.mozilla.firefoxdeveloperedition": "Firefox",
        "org.mozilla.nightly": "Firefox",
        "app.zen-browser.zen": "zen",
    ]
}

public struct BrowserProfile: Hashable, Sendable {
    /// What the browser needs: a Chromium directory, a Firefox profile name or an Ardia profile id.
    public var id: String
    /// What the browser shows.
    public var name: String
}

public struct BrowserProfiles: Equatable, Sendable {
    public var profiles: [BrowserProfile] = []
    /// Firefox containers of the default profile.
    public var containers: [String] = []
    /// Whether the default Firefox profile has the extension that opens `ext+container:` links.
    public var hasContainerExtension = false

    public func profile(named nameOrID: String) -> BrowserProfile? {
        profiles.first { $0.id == nameOrID }
            ?? profiles.first { $0.name.caseInsensitiveCompare(nameOrID) == .orderedSame }
    }
}

/// Reads profiles from the browsers' own files. Nothing here launches or talks to a browser.
public enum ProfileDiscovery {
    public static var applicationSupport: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support")
    }

    /// The file that lists a browser's profiles.
    static func listFile(for kind: BrowserKind, in support: URL) -> URL? {
        switch kind {
        case .chromium(let dir): support.appending(path: dir).appending(path: "Local State")
        case .firefox(let dir): support.appending(path: dir).appending(path: "profiles.ini")
        case .ardia: support.appending(path: BrowserKind.ardiaBundleID).appending(path: "session.json")
        case .plain: nil
        }
    }

    /// The files whose changes mean `profiles(for:)` would answer differently, for caching.
    public static func sourceFiles(for kind: BrowserKind, in support: URL = applicationSupport) -> [URL] {
        guard let list = listFile(for: kind, in: support) else { return [] }
        guard case .firefox = kind, let text = try? String(contentsOf: list, encoding: .utf8),
              let dir = firefoxMainProfile(firefoxProfiles(profilesINI: text), listedIn: list) else { return [list] }
        return [list, dir.appending(path: "containers.json"), dir.appending(path: "extensions.json")]
    }

    public static func profiles(for kind: BrowserKind, in support: URL = applicationSupport) -> BrowserProfiles {
        guard let file = listFile(for: kind, in: support), let data = try? Data(contentsOf: file) else {
            return BrowserProfiles()
        }
        switch kind {
        case .chromium:
            return BrowserProfiles(profiles: chromiumProfiles(localState: data))
        case .ardia:
            return BrowserProfiles(profiles: ardiaProfiles(session: data))
        case .firefox:
            let entries = firefoxProfiles(profilesINI: String(decoding: data, as: UTF8.self))
            var result = BrowserProfiles(profiles: entries.map { BrowserProfile(id: $0.name, name: $0.name) })
            if let dir = firefoxMainProfile(entries, listedIn: file) {
                if let json = try? Data(contentsOf: dir.appending(path: "containers.json")) {
                    result.containers = firefoxContainers(json: json)
                }
                if let json = try? Data(contentsOf: dir.appending(path: "extensions.json")) {
                    result.hasContainerExtension = firefoxHasContainerExtension(extensionsJSON: json)
                }
            }
            return result
        case .plain:
            return BrowserProfiles()
        }
    }

    /// The profile folder this install starts with, where containers and extensions live.
    static func firefoxMainProfile(_ entries: [FirefoxProfileEntry], listedIn ini: URL) -> URL? {
        guard let main = entries.first(where: \.isDefault) ?? entries.first else { return nil }
        return main.isRelative ? ini.deletingLastPathComponent().appending(path: main.path) : URL(filePath: main.path)
    }

    /// "Open external links in a container" on addons.mozilla.org.
    static let containerExtensionID = "{f069aec0-43c5-4bbf-b6b4-df95c4326b98}"

    static func firefoxHasContainerExtension(extensionsJSON: Data) -> Bool {
        struct File: Decodable {
            struct Addon: Decodable { let id: String; let active: Bool? }
            let addons: [Addon]
        }
        guard let file = try? JSONDecoder().decode(File.self, from: extensionsJSON) else { return false }
        return file.addons.contains { $0.id == containerExtensionID && $0.active != false }
    }

    static func chromiumProfiles(localState: Data) -> [BrowserProfile] {
        struct LocalState: Decodable {
            struct Profile: Decodable {
                struct Info: Decodable { let name: String }
                let info_cache: [String: Info]
            }
            let profile: Profile
        }
        guard let state = try? JSONDecoder().decode(LocalState.self, from: localState) else { return [] }
        return state.profile.info_cache
            .map { BrowserProfile(id: $0.key, name: $0.value.name) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func ardiaProfiles(session: Data) -> [BrowserProfile] {
        struct Session: Decodable {
            struct Profile: Decodable { let id: String; let name: String }
            let profiles: [String: Profile]
        }
        guard let session = try? JSONDecoder().decode(Session.self, from: session) else { return [] }
        // "default" first, then in the order the user made them (ids grow over time).
        return session.profiles.values
            .sorted { ($0.id == "default" ? "" : $0.id) < ($1.id == "default" ? "" : $1.id) }
            .map { BrowserProfile(id: $0.id, name: $0.name) }
    }

    struct FirefoxProfileEntry: Equatable {
        var name = ""
        var path = ""
        var isRelative = true
        var isDefault = false
    }

    static func firefoxProfiles(profilesINI: String) -> [FirefoxProfileEntry] {
        var entries: [FirefoxProfileEntry] = []
        var current: FirefoxProfileEntry?
        var installDefault: String?
        var inInstall = false
        for raw in profilesINI.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                if let current { entries.append(current) }
                current = line.hasPrefix("[Profile") ? FirefoxProfileEntry() : nil
                inInstall = line.hasPrefix("[Install")
                continue
            }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq], value = String(line[line.index(after: eq)...])
            if inInstall, key == "Default" { installDefault = value }
            switch key {
            case "Name": current?.name = value
            case "Path": current?.path = value
            case "IsRelative": current?.isRelative = value == "1"
            case "Default": current?.isDefault = value == "1"
            default: break
            }
        }
        if let current { entries.append(current) }
        // The [Install…] section's Default is the profile this install actually starts with.
        if let installDefault, entries.contains(where: { $0.path == installDefault }) {
            for i in entries.indices { entries[i].isDefault = entries[i].path == installDefault }
        }
        return entries.filter { !$0.name.isEmpty }
    }

    static func firefoxContainers(json: Data) -> [String] {
        struct File: Decodable {
            struct Identity: Decodable {
                let name: String?
                let l10nId: String?
                let `public`: Bool?
            }
            let identities: [Identity]
        }
        guard let file = try? JSONDecoder().decode(File.self, from: json) else { return [] }
        let builtIn = [
            "user-context-personal": "Personal", "user-context-work": "Work",
            "user-context-banking": "Banking", "user-context-shopping": "Shopping",
        ]
        return file.identities.compactMap { identity in
            guard identity.public != false else { return nil }
            return identity.name ?? identity.l10nId.flatMap { builtIn[$0] }
        }
    }
}
