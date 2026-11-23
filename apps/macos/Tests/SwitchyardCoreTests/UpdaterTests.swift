import Foundation
import Testing
@testable import SwitchyardCore

@Test(arguments: [
    ("0.1.0", AppVersion(major: 0, minor: 1, patch: 0)),
    ("v0.1.1", AppVersion(major: 0, minor: 1, patch: 1)),
    ("V1.23.456", AppVersion(major: 1, minor: 23, patch: 456)),
    ("0.1", nil),
    ("0.1.0-beta.1", nil),
    ("abc", nil),
    ("-1.0.0", nil),
])
func versionParsing(raw: String, expected: AppVersion?) {
    #expect(AppVersion(raw) == expected)
}

@Test func versionOrdering() throws {
    let v010 = try #require(AppVersion("0.1.0"))
    let v011 = try #require(AppVersion("0.1.1"))
    let v020 = try #require(AppVersion("0.2.0"))
    let v0100 = try #require(AppVersion("0.10.0"))
    let v100 = try #require(AppVersion("1.0.0"))

    #expect(v010 < v011)
    #expect(v011 < v020)
    #expect(v020 < v0100)
    #expect(v0100 < v100)
    #expect(!(v011 < v011))
}

@Test func parsesGitHubLatestReleaseAndRejectsUnsafeOrIncompleteOnes() throws {
    let json = Data(#"""
    {
      "tag_name": "v0.1.1",
      "name": "Switchyard 0.1.1",
      "body": "**v0.1.1** · 1 change\n\n## Highlights\nWildcards.\n\n<details>\n<summary>Full changelog</summary>\n\n- feat(macos): wildcards\n\n</details>\n",
      "html_url": "https://github.com/donnes/switchyard/releases/tag/v0.1.1",
      "draft": false,
      "prerelease": false,
      "assets": [
        {
          "name": "SHA256SUMS",
          "size": 93,
          "browser_download_url": "https://github.com/donnes/switchyard/releases/download/v0.1.1/SHA256SUMS"
        },
        {
          "name": "Switchyard-0.1.1-arm64.dmg",
          "size": 1799624,
          "digest": "sha256:526bc5af2528f2e2ce197f055c4a50877afb9d4f029a027c85b52ccf3be1978e",
          "browser_download_url": "https://github.com/donnes/switchyard/releases/download/v0.1.1/Switchyard-0.1.1-arm64.dmg"
        }
      ]
    }
    """#.utf8)

    let release = try UpdateFeed.parseLatestRelease(json, architecture: "arm64")
    #expect(release.version == AppVersion(major: 0, minor: 1, patch: 1))
    #expect(release.dmgName == "Switchyard-0.1.1-arm64.dmg")
    #expect(release.dmgSize == 1_799_624)
    #expect(release.sha256 == "526bc5af2528f2e2ce197f055c4a50877afb9d4f029a027c85b52ccf3be1978e")
    #expect(release.checksumsURL?.lastPathComponent == "SHA256SUMS")
    #expect(UpdateFeed.isNewer(release, than: AppVersion(major: 0, minor: 1, patch: 0)))
    #expect(!UpdateFeed.isNewer(release, than: AppVersion(major: 0, minor: 1, patch: 1)))

    // Prerelease is rejected.
    let prerelease = Data(#"""
    {"tag_name":"v0.2.0","html_url":"https://github.com/donnes/switchyard/releases/tag/v0.2.0","draft":false,"prerelease":true,"assets":[{"name":"Switchyard-0.2.0-arm64.dmg","browser_download_url":"https://github.com/donnes/switchyard/releases/download/v0.2.0/Switchyard-0.2.0-arm64.dmg"}]}
    """#.utf8)
    #expect(throws: UpdateError.self) {
        try UpdateFeed.parseLatestRelease(prerelease, architecture: "arm64")
    }

    // Non-HTTPS download URL is rejected.
    let insecure = Data(#"""
    {"tag_name":"v0.2.0","html_url":"https://github.com/donnes/switchyard/releases/tag/v0.2.0","draft":false,"prerelease":false,"assets":[{"name":"Switchyard-0.2.0-arm64.dmg","browser_download_url":"http://example.com/Switchyard-0.2.0-arm64.dmg"}]}
    """#.utf8)
    #expect(throws: UpdateError.self) {
        try UpdateFeed.parseLatestRelease(insecure, architecture: "arm64")
    }
}

@Test func checksumsParseAndVerifyOnDisk() throws {
    let sums = """
    526bc5af2528f2e2ce197f055c4a50877afb9d4f029a027c85b52ccf3be1978e  Switchyard-0.1.1-arm64.dmg
    0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef *Other.dmg
    """
    #expect(UpdateFeed.parseSHA256Sums(sums, filename: "Switchyard-0.1.1-arm64.dmg")
        == "526bc5af2528f2e2ce197f055c4a50877afb9d4f029a027c85b52ccf3be1978e")
    #expect(UpdateFeed.parseSHA256Sums(sums, filename: "Other.dmg")
        == "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef")
    #expect(UpdateFeed.parseSHA256Sums(sums, filename: "Missing.dmg") == nil)

    let dir = FileManager.default.temporaryDirectory.appending(path: "switchyard-sha-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let file = dir.appending(path: "sample.bin")
    try Data("switchyard".utf8).write(to: file)
    // printf 'switchyard' | shasum -a 256
    let expected = "3e865a8f1fca8d39afb548a7b2ff97019d9f12a3af0a846d4ef83b584b59fd0d"
    #expect(try UpdateFeed.sha256Hex(of: file) == expected)
}

@Test func releaseNotesCleanupStripsDetailsTags() {
    let raw = """
    **v0.1.1** · 1 change

    ## Highlights
    Wildcards work.

    <details>
    <summary>Full changelog</summary>

    - feat(macos): wildcards

    </details>
    """
    let cleaned = ReleaseNotesFormatter.cleanMarkdown(raw)
    #expect(!cleaned.contains("<details>"))
    #expect(!cleaned.contains("</details>"))
    #expect(cleaned.contains("### Full changelog"))
    #expect(cleaned.contains("- feat(macos): wildcards"))
    #expect(!ReleaseNotesFormatter.cleanMarkdown("   \n  ").isEmpty)
}

@Test func signaturePolicyRequiresMatchingDeveloperIDAndTeam() throws {
    let running = BundleSigningInfo(
        bundleIdentifier: "dev.donnes.switchyard",
        teamIdentifier: "YNNZS92R87",
        isValid: true,
        satisfiesDeveloperID: true
    )
    let good = running
    try CodeSignaturePolicy.validate(candidate: good, against: running)

    let wrongTeam = BundleSigningInfo(
        bundleIdentifier: "dev.donnes.switchyard",
        teamIdentifier: "OTHERTEAM1",
        isValid: true,
        satisfiesDeveloperID: true
    )
    #expect(throws: UpdateError.teamIdentifierMismatch(expected: "YNNZS92R87", actual: "OTHERTEAM1")) {
        try CodeSignaturePolicy.validate(candidate: wrongTeam, against: running)
    }

    let wrongBundle = BundleSigningInfo(
        bundleIdentifier: "com.evil.app",
        teamIdentifier: "YNNZS92R87",
        isValid: true,
        satisfiesDeveloperID: true
    )
    #expect(throws: UpdateError.bundleIdentifierMismatch(expected: "dev.donnes.switchyard", actual: "com.evil.app")) {
        try CodeSignaturePolicy.validate(candidate: wrongBundle, against: running)
    }

    let adHocCandidate = BundleSigningInfo(
        bundleIdentifier: "dev.donnes.switchyard",
        teamIdentifier: nil,
        isValid: true,
        satisfiesDeveloperID: false
    )
    #expect(throws: UpdateError.teamIdentifierMismatch(expected: "YNNZS92R87", actual: nil)) {
        try CodeSignaturePolicy.validate(candidate: adHocCandidate, against: running)
    }

    let adHocRunning = BundleSigningInfo(
        bundleIdentifier: "dev.donnes.switchyard",
        teamIdentifier: nil,
        isValid: true,
        satisfiesDeveloperID: false
    )
    #expect(throws: UpdateError.unsignedRunningApp) {
        try CodeSignaturePolicy.validate(candidate: good, against: adHocRunning)
    }
}

@Test func codeSignatureVerifierDetectsTamperedBundle() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "switchyard-sig-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let app = try makeSignedDummyApp(at: root.appending(path: "Switchyard.app"), version: "0.2.0", bundleID: "dev.donnes.switchyard.test")

    let valid = try CodeSignatureVerifier.signingInfo(for: app)
    #expect(valid.isValid)
    #expect(valid.bundleIdentifier == "dev.donnes.switchyard.test")
    #expect(valid.teamIdentifier == nil)
    #expect(!valid.satisfiesDeveloperID)

    // Modify a sealed resource after signing: strict verification must reject it.
    let marker = app.appending(path: "Contents/Resources/marker.txt")
    try Data("tampered".utf8).write(to: marker)
    let tampered = try CodeSignatureVerifier.signingInfo(for: app)
    #expect(!tampered.isValid)
}

@Test func installerAtomicallyReplacesAppAndLeavesOriginalIntactOnFailure() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "switchyard-install-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }

    let installedApp = try makeSignedDummyApp(at: root.appending(path: "InstallDir/Switchyard.app"), version: "0.1.0", bundleID: "dev.donnes.switchyard.test")
    let stageDir = root.appending(path: "dmg-stage")
    _ = try makeSignedDummyApp(at: stageDir.appending(path: "Switchyard.app"), version: "0.2.0", bundleID: "dev.donnes.switchyard.test")

    let dmg = root.appending(path: "Switchyard-0.2.0-arm64.dmg")
    try runTool("/usr/bin/hdiutil", ["create", "-quiet", "-volname", "Switchyard", "-srcfolder", stageDir.path, "-format", "UDZO", "-fs", "APFS", dmg.path])
    let realSHA = try UpdateFeed.sha256Hex(of: dmg)

    // 1. Bad SHA-256 fails and leaves 0.1.0 untouched.
    #expect(throws: UpdateError.self) {
        try UpdateInstaller.install(
            dmgURL: dmg,
            expectedSHA256: String(repeating: "0", count: 64),
            expectedVersion: AppVersion(major: 0, minor: 2, patch: 0),
            expectedBundleID: "dev.donnes.switchyard.test",
            replacing: installedApp,
            verifySignature: { _, _ in }
        )
    }
    #expect(shortVersion(of: installedApp) == "0.1.0")

    // 2. Failing signature check fails and leaves 0.1.0 untouched.
    #expect(throws: UpdateError.teamIdentifierMismatch(expected: "TEAM1", actual: "TEAM2")) {
        try UpdateInstaller.install(
            dmgURL: dmg,
            expectedSHA256: realSHA,
            expectedVersion: AppVersion(major: 0, minor: 2, patch: 0),
            expectedBundleID: "dev.donnes.switchyard.test",
            replacing: installedApp,
            verifySignature: { _, _ in throw UpdateError.teamIdentifierMismatch(expected: "TEAM1", actual: "TEAM2") }
        )
    }
    #expect(shortVersion(of: installedApp) == "0.1.0")

    // 3. Downgrade / version mismatch fails and leaves 0.1.0 untouched.
    #expect(throws: UpdateError.self) {
        try UpdateInstaller.install(
            dmgURL: dmg,
            expectedSHA256: realSHA,
            expectedVersion: AppVersion(major: 0, minor: 3, patch: 0),
            expectedBundleID: "dev.donnes.switchyard.test",
            replacing: installedApp,
            verifySignature: { _, _ in }
        )
    }
    #expect(shortVersion(of: installedApp) == "0.1.0")

    // 4. Valid install swaps 0.1.0 -> 0.2.0 cleanly.
    try UpdateInstaller.install(
        dmgURL: dmg,
        expectedSHA256: realSHA,
        expectedVersion: AppVersion(major: 0, minor: 2, patch: 0),
        expectedBundleID: "dev.donnes.switchyard.test",
        replacing: installedApp,
        verifySignature: { candidate, _ in
            let info = try CodeSignatureVerifier.signingInfo(for: candidate)
            guard info.isValid else { throw UpdateError.signatureInvalid("invalid ad-hoc signature") }
        }
    )
    #expect(shortVersion(of: installedApp) == "0.2.0")

    // 5. Translocated path is rejected by preflight.
    #expect(throws: UpdateError.self) {
        try UpdateInstallPreflight.checkCanReplace(
            appURL: URL(filePath: "/private/var/folders/xx/T/AppTranslocation/ABC/d/Switchyard.app")
        )
    }
}

// MARK: - Fixtures

private func makeSignedDummyApp(at url: URL, version: String, bundleID: String) throws -> URL {
    let fm = FileManager.default
    let macos = url.appending(path: "Contents/MacOS")
    let resources = url.appending(path: "Contents/Resources")
    try fm.createDirectory(at: macos, withIntermediateDirectories: true)
    try fm.createDirectory(at: resources, withIntermediateDirectories: true)

    // Copy a tiny signed system executable (/usr/bin/true) so codesign seals a real Mach-O binary.
    let binary = macos.appending(path: "Switchyard")
    try fm.copyItem(at: URL(filePath: "/usr/bin/true"), to: binary)
    try Data("v\(version)".utf8).write(to: resources.appending(path: "marker.txt"))

    let plist = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
        <key>CFBundleIdentifier</key><string>\(bundleID)</string>
        <key>CFBundleExecutable</key><string>Switchyard</string>
        <key>CFBundlePackageType</key><string>APPL</string>
        <key>CFBundleShortVersionString</key><string>\(version)</string>
        <key>CFBundleVersion</key><string>\(version)</string>
    </dict>
    </plist>
    """
    try Data(plist.utf8).write(to: url.appending(path: "Contents/Info.plist"))
    try runTool("/usr/bin/codesign", ["--force", "--sign", "-", url.path])
    return url
}

private func shortVersion(of appURL: URL) -> String? {
    let plistURL = appURL.appending(path: "Contents/Info.plist")
    guard let data = try? Data(contentsOf: plistURL),
          let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    else { return nil }
    return dict["CFBundleShortVersionString"] as? String
}

private func runTool(_ path: String, _ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(filePath: path)
    process.arguments = arguments
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
}
