import Foundation

/// A compiled URL pattern. Matching is case-insensitive.
///
/// - `regex:<expr>` matches the regular expression against the full URL.
/// - A pattern with `://` is a glob (`*` = anything) against the full URL: `*://*.cloudflare.com/*`.
/// - A pattern without `/` is a host: `cloudflare.com` matches that host and its subdomains.
///   Globs work here too: `*.cloudflare.com`.
/// - Anything else is a glob against host, path and query: `linear.app/acme/*`.
public struct URLPattern {
    enum Kind {
        case regex(NSRegularExpression)
        case fullURL([UInt8])
        case host([UInt8], subdomains: Bool)
        case hostAndPath([UInt8])
    }

    public let source: String
    let kind: Kind

    public init(_ source: String) throws {
        self.source = source
        let text = source.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("regex:") {
            kind = .regex(try NSRegularExpression(pattern: String(text.dropFirst(6)), options: .caseInsensitive))
        } else if text.contains("://") {
            kind = .fullURL(Array(text.lowercased().utf8))
        } else if !text.contains("/") {
            kind = .host(Array(text.lowercased().utf8), subdomains: !text.contains("*"))
        } else {
            kind = .hostAndPath(Array(text.lowercased().utf8))
        }
    }

    public func matches(_ url: URL) -> Bool {
        switch kind {
        case .regex(let expression):
            let text = url.absoluteString
            return expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
        case .fullURL(let glob):
            return Glob.matches(glob, Array(url.absoluteString.lowercased().utf8))
        case .host(let glob, let subdomains):
            guard let host = url.host()?.lowercased() else { return false }
            let bytes = Array(host.utf8)
            if Glob.matches(glob, bytes) { return true }
            return subdomains && host.hasSuffix("." + String(decoding: glob, as: UTF8.self))
        case .hostAndPath(let glob):
            guard let host = url.host()?.lowercased() else { return false }
            var text = host + url.path(percentEncoded: true)
            if let query = url.query(percentEncoded: true) { text += "?" + query }
            return Glob.matches(glob, Array(text.lowercased().utf8))
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
