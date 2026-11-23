import Foundation

/// A compiled URL pattern. Matching is case-insensitive.
///
/// - `regex:<expr>` matches the regular expression against the full URL.
/// - Anything else is `host/path`, where `*` matches anything. A host covers its subdomains,
///   so `cloudflare.com` and `*.cloudflare.com` mean the same. A path covers everything below it,
///   so `github.com/acme` and `github.com/acme/*` mean the same. A `*://` prefix is ignored, and
///   any other scheme, like `http://`, must match the link's.
public struct URLPattern {
    enum Kind {
        case regex(NSRegularExpression)
        case glob(scheme: String?, host: [[UInt8]], path: [[UInt8]])
    }

    public let source: String
    let kind: Kind

    public init(_ source: String) throws {
        self.source = source
        let text = source.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("regex:") {
            kind = .regex(try NSRegularExpression(pattern: String(text.dropFirst(6)), options: .caseInsensitive))
            return
        }
        var rest = Substring(text.lowercased())
        var scheme: String?
        if let separator = rest.range(of: "://") {
            let name = rest[..<separator.lowerBound]
            scheme = name == "*" ? nil : String(name)
            rest = rest[separator.upperBound...]
        }
        let slash = rest.firstIndex(of: "/") ?? rest.endIndex
        var host = rest[..<slash]
        while host.hasPrefix("*.") { host = host.dropFirst(2) }
        var path = String(rest[slash...])
        while path.hasSuffix("/*") || path.hasSuffix("/") { path.removeLast(path.hasSuffix("/") ? 1 : 2) }
        kind = .glob(
            scheme: scheme,
            host: [String(host), "*." + host].map { Array($0.utf8) },
            path: path.isEmpty ? [] : [path, path + "/*", path + "?*"].map { Array($0.utf8) }
        )
    }

    public func matches(_ url: URL) -> Bool {
        switch kind {
        case .regex(let expression):
            let text = url.absoluteString
            return expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
        case .glob(let scheme, let hostGlobs, let pathGlobs):
            if let scheme, url.scheme?.lowercased() != scheme { return false }
            guard let host = url.host()?.lowercased() else { return false }
            let hostBytes = Array(host.utf8)
            guard hostGlobs.contains(where: { Glob.matches($0, hostBytes) }) else { return false }
            if pathGlobs.isEmpty { return true }
            var text = url.path(percentEncoded: true)
            if let query = url.query(percentEncoded: true) { text += "?" + query }
            let pathBytes = Array(text.lowercased().utf8)
            return pathGlobs.contains { Glob.matches($0, pathBytes) }
        }
    }
}

enum Glob {
    /// `*` matches any run of bytes, including none. Greedy with backtracking to the last star.
    static func matches(_ pattern: [UInt8], _ text: [UInt8]) -> Bool {
        let star = UInt8(ascii: "*")
        var p = 0, t = 0
        var lastStar = -1, resume = 0
        while t < text.count {
            if p < pattern.count, pattern[p] == star {
                lastStar = p
                resume = t
                p += 1
            } else if p < pattern.count, pattern[p] == text[t] {
                p += 1
                t += 1
            } else if lastStar >= 0 {
                p = lastStar + 1
                resume += 1
                t = resume
            } else {
                return false
            }
        }
        while p < pattern.count, pattern[p] == star { p += 1 }
        return p == pattern.count
    }
}
