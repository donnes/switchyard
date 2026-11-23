import CryptoKit
import Foundation

/// Semantic version `major.minor.patch` as stamped on Switchyard releases.
public struct AppVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// Parses `X.Y.Z` or `vX.Y.Z`. Rejects prereleases and malformed versions.
    public init?(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let stripped = trimmed.hasPrefix("v") || trimmed.hasPrefix("V") ? String(trimmed.dropFirst()) : trimmed
        let parts = stripped.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }),
              let major = Int(parts[0]),
              let minor = Int(parts[1]),
              let patch = Int(parts[2])
        else { return nil }
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    public var description: String { "\(major).\(minor).\(patch)" }

    public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }
}

/// One published Switchyard release on GitHub.
public struct ReleaseInfo: Equatable, Sendable {
    public let version: AppVersion
    public let name: String
    public let notes: String
    public let pageURL: URL
    public let dmgURL: URL
    public let dmgName: String
    public let dmgSize: Int64?
    public let sha256: String?
    public let checksumsURL: URL?

    public init(
        version: AppVersion,
        name: String,
        notes: String,
        pageURL: URL,
        dmgURL: URL,
        dmgName: String,
        dmgSize: Int64? = nil,
        sha256: String? = nil,
        checksumsURL: URL? = nil
    ) {
        self.version = version
        self.name = name
        self.notes = notes
        self.pageURL = pageURL
        self.dmgURL = dmgURL
        self.dmgName = dmgName
        self.dmgSize = dmgSize
        self.sha256 = sha256
        self.checksumsURL = checksumsURL
    }
}

/// Errors surfaced to the user when checking, downloading, verifying, or installing an update.
public enum UpdateError: LocalizedError, Equatable, Sendable {
    case invalidRelease(String)
    case httpStatus(Int)
    case checksumMismatch(expected: String, actual: String)
    case checksumMissing(String)
    case readOnlyInstallLocation(String)
    case unwritableInstallLocation(String)
    case mountFailed(String)
    case appMissingInImage
    case bundleIdentifierMismatch(expected: String, actual: String?)
    case versionMismatch(expected: AppVersion, actual: String?)
    case unsignedRunningApp
    case signatureInvalid(String)
    case teamIdentifierMismatch(expected: String, actual: String?)
    case replaceFailed(String)
    case relaunchFailed(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .invalidRelease(let detail):
            "Couldn’t read the release information from GitHub (\(detail)). Your current version wasn’t changed."
        case .httpStatus(403), .httpStatus(429):
            "GitHub temporarily rate-limited update checks. Try again in a few minutes, or open the releases page."
        case .httpStatus(let code):
            "GitHub returned HTTP \(code) while checking for updates. Your current version wasn’t changed."
        case .checksumMismatch:
            "The downloaded disk image didn’t match its published SHA-256 checksum. Your current version wasn’t changed."
        case .checksumMissing(let filename):
            "The release’s SHA256SUMS file doesn’t list \(filename). Your current version wasn’t changed."
        case .readOnlyInstallLocation:
            "Switchyard is running from a read-only location. Move it to Applications before updating."
        case .unwritableInstallLocation(let path):
            "Switchyard doesn’t have permission to replace \(path). Download the update from GitHub to install it manually."
        case .mountFailed(let detail):
            "Couldn’t open the downloaded disk image (\(detail)). Your current version wasn’t changed."
        case .appMissingInImage:
            "The downloaded disk image doesn’t contain Switchyard.app. Your current version wasn’t changed."
        case .bundleIdentifierMismatch:
            "The downloaded app has a different bundle identifier than this copy of Switchyard. Your current version wasn’t changed."
        case .versionMismatch:
            "The downloaded app’s version doesn’t match the release. Your current version wasn’t changed."
        case .unsignedRunningApp:
            "This copy of Switchyard isn’t signed with a Developer ID, so Switchyard can’t verify the update’s Team ID. Download the new version from GitHub instead."
        case .signatureInvalid(let detail):
            "The downloaded app’s code signature couldn’t be verified (\(detail)). Your current version wasn’t changed."
        case .teamIdentifierMismatch:
            "The downloaded app wasn’t signed by the same developer Team ID as this copy of Switchyard. Your current version wasn’t changed."
        case .replaceFailed(let detail):
            "Couldn’t replace Switchyard on disk (\(detail)). Your current version wasn’t changed."
        case .relaunchFailed(let detail):
            "Switchyard was updated, but couldn’t relaunch automatically (\(detail)). Open Switchyard again to finish."
        case .cancelled:
            "The update was cancelled."
        }
    }
}

/// Parses GitHub release metadata and checks SHA-256 checksums.
public enum UpdateFeed {
    public static let latestReleaseURL = URL(string: "https://api.github.com/repos/donnes/switchyard/releases/latest")!
    public static let releasesPageURL = URL(string: "https://github.com/donnes/switchyard/releases")!

    public static var currentArchitecture: String {
        #if arch(arm64)
        "arm64"
        #elseif arch(x86_64)
        "x86_64"
        #else
        "unknown"
        #endif
    }

    public static func isNewer(_ release: ReleaseInfo, than current: AppVersion) -> Bool {
        release.version > current
    }

    public static func parseLatestRelease(_ data: Data, architecture: String = currentArchitecture) throws -> ReleaseInfo {
        let raw: GitHubRelease
        do {
            raw = try JSONDecoder().decode(GitHubRelease.self, from: data)
        } catch {
            throw UpdateError.invalidRelease("invalid JSON")
        }

        guard !raw.draft, !raw.prerelease else {
            throw UpdateError.invalidRelease("release is a draft or prerelease")
        }
        guard let version = AppVersion(raw.tagName) else {
            throw UpdateError.invalidRelease("unexpected tag \(raw.tagName)")
        }
        guard let pageURL = httpsURL(raw.htmlURL) else {
            throw UpdateError.invalidRelease("missing release page URL")
        }

        let exactName = "Switchyard-\(version)-\(architecture).dmg"
        let archSuffix = "-\(architecture).dmg"
        let dmgAsset = raw.assets.first { $0.name == exactName }
            ?? raw.assets.first { $0.name.hasSuffix(archSuffix) }
            ?? raw.assets.first { $0.name.hasSuffix("-universal.dmg") }

        guard let dmgAsset, let dmgURL = httpsURL(dmgAsset.browserDownloadURL) else {
            throw UpdateError.invalidRelease("no \(architecture) disk image in release \(version)")
        }

        let checksumsURL = raw.assets
            .first { $0.name == "SHA256SUMS" }
            .flatMap { httpsURL($0.browserDownloadURL) }

        let digest = dmgAsset.digest.flatMap(parseAssetDigest)
        let title = raw.name?.trimmingCharacters(in: .whitespacesAndNewlines)

        return ReleaseInfo(
            version: version,
            name: (title?.isEmpty == false ? title! : "Switchyard \(version)"),
            notes: raw.body ?? "",
            pageURL: pageURL,
            dmgURL: dmgURL,
            dmgName: dmgAsset.name,
            dmgSize: dmgAsset.size,
            sha256: digest,
            checksumsURL: checksumsURL
        )
    }

    /// Parses `shasum -a 256` output (`<hex>  <filename>` or `<hex> *<filename>`).
    public static func parseSHA256Sums(_ text: String, filename: String) -> String? {
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let parts = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard parts.count == 2 else { continue }
            let hash = String(parts[0]).lowercased()
            var entryName = parts[1].trimmingCharacters(in: .whitespaces)
            if entryName.hasPrefix("*") { entryName.removeFirst() }
            guard isHexSHA256(hash) else { continue }
            if entryName == filename { return hash }
        }
        return nil
    }

    /// Streams a file in fixed chunks so computing its digest doesn't load the whole DMG into memory.
    public static func sha256Hex(of fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func parseAssetDigest(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard trimmed.hasPrefix("sha256:") else { return nil }
        let hex = String(trimmed.dropFirst("sha256:".count))
        return isHexSHA256(hex) ? hex : nil
    }

    private static func isHexSHA256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { $0.isASCII && $0.isHexDigit }
    }

    private static func httpsURL(_ string: String?) -> URL? {
        guard let string,
              let url = URL(string: string),
              url.scheme?.lowercased() == "https",
              url.host() != nil
        else { return nil }
        return url
    }

    private struct GitHubRelease: Decodable {
        let tagName: String
        let name: String?
        let body: String?
        let htmlURL: String?
        let draft: Bool
        let prerelease: Bool
        let assets: [Asset]

        struct Asset: Decodable {
            let name: String
            let size: Int64?
            let digest: String?
            let browserDownloadURL: String?

            enum CodingKeys: String, CodingKey {
                case name, size, digest
                case browserDownloadURL = "browser_download_url"
            }
        }

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case name, body, draft, prerelease, assets
            case htmlURL = "html_url"
        }
    }
}

/// Cleans GitHub release Markdown (including `<details>/<summary>` blocks) for native display.
public enum ReleaseNotesFormatter {
    public static func cleanMarkdown(_ raw: String) -> String {
        let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var lines: [String] = []
        var blankRun = 0

        for line in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let lowered = trimmed.lowercased()
            if lowered == "<details>" || lowered == "</details>" {
                continue
            }
            if lowered.hasPrefix("<summary>") && lowered.hasSuffix("</summary>") {
                let start = trimmed.index(trimmed.startIndex, offsetBy: "<summary>".count)
                let end = trimmed.index(trimmed.endIndex, offsetBy: -"</summary>".count)
                let heading = trimmed[start..<end].trimmingCharacters(in: .whitespaces)
                if !heading.isEmpty {
                    lines.append("### \(heading)")
                    blankRun = 0
                }
                continue
            }
            if trimmed.isEmpty {
                if !lines.isEmpty && blankRun == 0 {
                    lines.append("")
                }
                blankRun += 1
            } else {
                lines.append(String(line))
                blankRun = 0
            }
        }

        while lines.last?.isEmpty == true { lines.removeLast() }
        let result = lines.joined(separator: "\n")
        return result.isEmpty ? "No release notes were provided for this version." : result
    }
}
