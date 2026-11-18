import Foundation

/// Where a link should open. `browser` is the app's bundle identifier.
public struct Target: Codable, Equatable, Hashable, Sendable {
    public var browser: String
    /// Profile name (or id) as the browser shows it. Chromium, Firefox-family and Ardia only.
    public var profile: String?
    /// Firefox container name. Needs the "Open external links in a container" extension.
    public var container: String?
    /// Open without bringing the browser to the front.
    public var background: Bool?

    public init(browser: String, profile: String? = nil, container: String? = nil, background: Bool? = nil) {
        self.browser = browser
        self.profile = profile
        self.container = container
        self.background = background
    }
}

public struct Rule: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String?
    public var enabled: Bool
    /// Bundle identifiers of the apps the link comes from. Empty or missing means any app.
    public var from: [String]
    /// URL patterns, see `URLPattern`. Empty or missing means any URL.
    public var match: [String]
    public var open: Target

    public init(id: String = Rule.newID(), name: String? = nil, enabled: Bool = true, from: [String] = [], match: [String] = [], open: Target) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.from = from
        self.match = match
        self.open = open
    }

    public static func newID() -> String { "r-" + UUID().uuidString.prefix(8).lowercased() }

    enum CodingKeys: String, CodingKey { case id, name, enabled, from, match, open }

    // Hand-written config files may leave out everything but `open`.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? "" // Config fills in a stable one.
        name = try c.decodeIfPresent(String.self, forKey: .name)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        from = try c.decodeIfPresent([String].self, forKey: .from) ?? []
        match = try c.decodeIfPresent([String].self, forKey: .match) ?? []
        open = try c.decode(Target.self, forKey: .open)
    }
}

public struct Config: Codable, Equatable, Sendable {
    /// Where links that no rule catches open.
    public var fallback: Target
    /// Checked from the top. The first enabled rule that fits decides.
    public var rules: [Rule]

    public init(fallback: Target, rules: [Rule] = []) {
        self.fallback = fallback
        self.rules = rules
    }

    enum CodingKeys: String, CodingKey { case fallback, rules }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fallback = try c.decode(Target.self, forKey: .fallback)
        rules = try c.decodeIfPresent([Rule].self, forKey: .rules) ?? []
        // Ids from the position, so reloading an unchanged hand-written file keeps them,
        // and a settings editor that was open during the reload still finds its rule.
        // Settings saves these ids, so skip any the file already uses.
        var used = Set(rules.map(\.id))
        for i in rules.indices where rules[i].id.isEmpty {
            var id = "r-\(i + 1)", suffix = 1
            while used.contains(id) {
                suffix += 1
                id = "r-\(i + 1)-\(suffix)"
            }
            rules[i].id = id
            used.insert(id)
        }
    }

    /// `~/.config/switchyard/config.json`, the same path the Omarchy app will read.
    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".config/switchyard/config.json")
    }

    public static func load(from url: URL) throws -> Config {
        try JSONDecoder().decode(Config.self, from: Data(contentsOf: url))
    }

    public func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
