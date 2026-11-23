import Darwin
import Foundation
import os

public enum InstallStage: Equatable, Sendable {
    case verifyingChecksum
    case openingDiskImage
    case verifyingSignature
    case replacingApp
}

/// Checks whether the running app bundle can be replaced in place before downloading or installing.
public enum UpdateInstallPreflight {
    public static func checkCanReplace(appURL: URL, fileManager: FileManager = .default) throws {
        let standardized = appURL.standardizedFileURL
        if standardized.path.contains("/AppTranslocation/") {
            throw UpdateError.readOnlyInstallLocation(standardized.path)
        }
        if let values = try? standardized.resourceValues(forKeys: [.volumeIsReadOnlyKey]),
           values.volumeIsReadOnly == true {
            throw UpdateError.readOnlyInstallLocation(standardized.path)
        }
        let parent = standardized.deletingLastPathComponent()
        guard fileManager.isWritableFile(atPath: parent.path),
              fileManager.isWritableFile(atPath: standardized.path)
        else {
            throw UpdateError.unwritableInstallLocation(standardized.path)
        }
    }
}

/// Verifies a downloaded DMG, extracts and stages Switchyard.app on the target volume, verifies its
/// code signature against the running app, and swaps the bundle atomically.
public enum UpdateInstaller {
    public static func install(
        dmgURL: URL,
        expectedSHA256: String?,
        expectedVersion: AppVersion,
        expectedBundleID: String,
        replacing targetAppURL: URL,
        stageChange: (@Sendable (InstallStage) -> Void)? = nil,
        isCancelled: (@Sendable () -> Bool)? = nil,
        verifySignature: (@Sendable (URL, URL) throws -> Void)? = nil
    ) throws {
        let fm = FileManager.default
        let checkCancel = {
            if isCancelled?() == true { throw UpdateError.cancelled }
        }

        try UpdateInstallPreflight.checkCanReplace(appURL: targetAppURL, fileManager: fm)
        try checkCancel()

        if let expected = expectedSHA256?.lowercased() {
            stageChange?(.verifyingChecksum)
            let actual = try UpdateFeed.sha256Hex(of: dmgURL)
            guard actual == expected else {
                throw UpdateError.checksumMismatch(expected: expected, actual: actual)
            }
        }
        try checkCancel()

        stageChange?(.openingDiskImage)
        let mountDir = fm.temporaryDirectory.appending(path: "switchyard-mount-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fm.createDirectory(at: mountDir, withIntermediateDirectories: true)
        var mounted = false
        defer {
            if mounted { detachImage(at: mountDir) }
            try? fm.removeItem(at: mountDir)
        }

        try attachImage(dmgURL, at: mountDir)
        mounted = true
        try checkCancel()

        let sourceAppURL = try locateApp(in: mountDir, expectedBundleID: expectedBundleID, fileManager: fm)

        // Stage onto the same volume as the installed app before verifying so there is no TOCTOU gap
        // between verification and atomic replacement.
        let stagingDir = try fm.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: targetAppURL,
            create: true
        )
        defer { try? fm.removeItem(at: stagingDir) }

        let stagedAppURL = stagingDir.appending(path: targetAppURL.lastPathComponent, directoryHint: .isDirectory)
        try fm.copyItem(at: sourceAppURL, to: stagedAppURL)
        clearQuarantine(at: stagedAppURL, fileManager: fm)
        try checkCancel()

        stageChange?(.verifyingSignature)
        try verifyBundleMetadata(at: stagedAppURL, expectedBundleID: expectedBundleID, minimumVersion: expectedVersion)
        let verifier = verifySignature ?? CodeSignatureVerifier.verifyUpdate(at:against:)
        try verifier(stagedAppURL, targetAppURL)
        try checkCancel()

        // Past this point the swap is atomic and cannot be cancelled halfway.
        stageChange?(.replacingApp)
        do {
            _ = try fm.replaceItemAt(targetAppURL, withItemAt: stagedAppURL, backupItemName: nil, options: [])
        } catch {
            throw UpdateError.replaceFailed(error.localizedDescription)
        }
    }

    private static func attachImage(_ dmgURL: URL, at mountDir: URL) throws {
        let result = try runProcess(
            "/usr/bin/hdiutil",
            arguments: ["attach", dmgURL.path, "-nobrowse", "-readonly", "-mountpoint", mountDir.path, "-plist"]
        )
        guard result.status == 0 else {
            let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw UpdateError.mountFailed(detail.isEmpty ? "hdiutil exited \(result.status)" : detail)
        }
    }

    private static func detachImage(at mountDir: URL) {
        let normal = try? runProcess("/usr/bin/hdiutil", arguments: ["detach", mountDir.path, "-quiet"])
        if normal?.status != 0 {
            _ = try? runProcess("/usr/bin/hdiutil", arguments: ["detach", mountDir.path, "-force", "-quiet"])
        }
    }

    private static func locateApp(in mountDir: URL, expectedBundleID: String, fileManager: FileManager) throws -> URL {
        let preferred = mountDir.appending(path: "Switchyard.app", directoryHint: .isDirectory)
        if isPlainDirectory(preferred) { return preferred }

        let entries = (try? fileManager.contentsOfDirectory(at: mountDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        for entry in entries where entry.pathExtension == "app" && isPlainDirectory(entry) {
            if let bundle = Bundle(url: entry), bundle.bundleIdentifier == expectedBundleID {
                return entry
            }
        }
        throw UpdateError.appMissingInImage
    }

    private static func verifyBundleMetadata(at appURL: URL, expectedBundleID: String, minimumVersion: AppVersion) throws {
        guard let bundle = Bundle(url: appURL) else {
            throw UpdateError.appMissingInImage
        }
        let actualID = bundle.bundleIdentifier
        guard actualID == expectedBundleID else {
            throw UpdateError.bundleIdentifierMismatch(expected: expectedBundleID, actual: actualID)
        }
        let rawVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        guard let actualVersion = rawVersion.flatMap(AppVersion.init), actualVersion >= minimumVersion else {
            throw UpdateError.versionMismatch(expected: minimumVersion, actual: rawVersion)
        }
    }

    /// Plain directory check using lstat so a symlink inside a mounted DMG can't escape the image.
    private static func isPlainDirectory(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
    }

    /// Removes `com.apple.quarantine` after signature verification so macOS doesn't block relaunch.
    private static func clearQuarantine(at root: URL, fileManager: FileManager) {
        let xattrName = "com.apple.quarantine"
        _ = removexattr(root.path, xattrName, XATTR_NOFOLLOW)
        guard let walk = fileManager.enumerator(at: root, includingPropertiesForKeys: nil) else { return }
        for case let url as URL in walk {
            _ = removexattr(url.path, xattrName, XATTR_NOFOLLOW)
        }
    }

    private static func runProcess(_ executable: String, arguments: [String]) throws -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(filePath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        // Read pipes concurrently so large hdiutil plist output cannot fill the pipe buffer and deadlock.
        let outData = OSAllocatedUnfairLock(initialState: Data())
        let errData = OSAllocatedUnfairLock(initialState: Data())
        let group = DispatchGroup()
        let queue = DispatchQueue.global(qos: .userInitiated)

        try process.run()
        group.enter()
        queue.async {
            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            outData.withLock { $0 = data }
            group.leave()
        }
        group.enter()
        queue.async {
            let data = errPipe.fileHandleForReading.readDataToEndOfFile()
            errData.withLock { $0 = data }
            group.leave()
        }
        process.waitUntilExit()
        group.wait()

        return (
            process.terminationStatus,
            String(decoding: outData.withLock { $0 }, as: UTF8.self),
            String(decoding: errData.withLock { $0 }, as: UTF8.self)
        )
    }
}

/// Waits for the old Switchyard process to exit, then launches the newly installed app bundle.
public enum AppRelauncher {
    public static func relaunch(appURL: URL, afterPID pid: Int32 = ProcessInfo.processInfo.processIdentifier) throws {
        let helper = Process()
        helper.executableURL = URL(filePath: "/bin/sh")
        helper.arguments = [
            "-c",
            """
            i=0
            while kill -0 "$1" 2>/dev/null && [ "$i" -lt 200 ]; do
              sleep 0.05
              i=$((i + 1))
            done
            /usr/bin/open "$2"
            """,
            "_",
            String(pid),
            appURL.path,
        ]
        helper.standardInput = FileHandle.nullDevice
        helper.standardOutput = FileHandle.nullDevice
        helper.standardError = FileHandle.nullDevice
        do {
            try helper.run()
        } catch {
            throw UpdateError.relaunchFailed(error.localizedDescription)
        }
    }
}
