import Foundation

public struct Decision: Equatable, Sendable {
    public var target: Target
    /// The rule that caught the link, or nil when the fallback decided.
    public var ruleID: String?
}

/// Rules compiled once per config load, so each link costs only the matching.
public struct Router {
    struct CompiledRule {
        let rule: Rule
        let from: Set<String>
        let patterns: [URLPattern]
    }

    public let config: Config
    let rules: [CompiledRule]

    /// Throws on the first invalid regex so the config error names it.
    public init(config: Config) throws {
        self.config = config
        rules = try config.rules.filter(\.enabled).map { rule in
            CompiledRule(rule: rule, from: Set(rule.from), patterns: try rule.match.map(URLPattern.init))
        }
    }

    public func decide(url: URL, from sourceBundleID: String?) -> Decision {
        for compiled in rules {
            if !compiled.from.isEmpty {
                guard let sourceBundleID, compiled.from.contains(sourceBundleID) else { continue }
            }
            if !compiled.patterns.isEmpty, !compiled.patterns.contains(where: { $0.matches(url) }) {
                continue
            }
            return Decision(target: compiled.rule.open, ruleID: compiled.rule.id)
        }
        return Decision(target: config.fallback, ruleID: nil)
    }
}
