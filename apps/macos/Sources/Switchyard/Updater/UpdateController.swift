import AppKit
import OSLog
import os
import SwitchyardCore

private let updateLog = Logger(subsystem: "dev.donnes.switchyard", category: "updater")

/// Coordinates one user-initiated update session: check -> prompt -> download -> verify -> install -> relaunch.
/// Created on demand when the user clicks "Check for Updates…" and released once the session ends.
@MainActor
final class UpdateController: NSObject {
    private let currentVersionString: String
    private let currentAppURL: URL
    private let bundleID: String
    private let openURL: (URL) -> Void
    private let onFinish: () -> Void

    private let windowController = UpdateWindowController()
    private let cancelledFlag = OSAllocatedUnfairLock(initialState: false)

    private var session: URLSession?
    private var activeTask: Task<Void, Never>?
    private var downloadDelegate: DownloadDelegate?
    private var downloadTask: URLSessionDownloadTask?
    private var tempDir: URL?
    private var pendingRelease: ReleaseInfo?
    private var finished = false

    init(
        currentVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0",
        currentAppURL: URL = Bundle.main.bundleURL,
        bundleID: String = Bundle.main.bundleIdentifier ?? "dev.donnes.switchyard",
        openURL: @escaping (URL) -> Void,
        onFinish: @escaping () -> Void
    ) {
        self.currentVersionString = currentVersion
        self.currentAppURL = currentAppURL
        self.bundleID = bundleID
        self.openURL = openURL
        self.onFinish = onFinish
        super.init()

        windowController.onCancel = { [weak self] in self?.cancel() }
        windowController.onInstall = { [weak self] in self?.beginInstall() }
        windowController.onOpenReleasePage = { [weak self] in
            guard let self else { return }
            self.openURL(self.pendingRelease?.pageURL ?? UpdateFeed.releasesPageURL)
        }
    }

    func bringToFront() {
        NSApp.activate()
        windowController.window.makeKeyAndOrderFront(nil)
    }

    func checkForUpdates() {
        windowController.show(.checking)

        let session = makeSession()
        self.session = session

        activeTask = Task { [weak self] in
            guard let self else { return }
            do {
                let release = try await self.fetchLatestRelease(using: session)
                guard !self.isCancelled else { return }

                let current = AppVersion(self.currentVersionString) ?? AppVersion(major: 0, minor: 0, patch: 0)
                if UpdateFeed.isNewer(release, than: current) {
                    self.pendingRelease = release
                    self.windowController.show(.available(release: release, currentVersion: self.currentVersionString))
                } else {
                    self.windowController.close()
                    self.showUpToDateAlert()
                    self.finish()
                }
            } catch is CancellationError {
                self.finish()
            } catch let urlError as URLError where urlError.code == .cancelled {
                self.finish()
            } catch {
                guard !self.isCancelled else { return }
                updateLog.error("Update check failed: \(error.localizedDescription, privacy: .public)")
                self.windowController.close()
                self.showErrorAlert(
                    title: "Couldn’t Check for Updates",
                    message: Self.describeCheckError(error),
                    releasesURL: UpdateFeed.releasesPageURL
                )
                self.finish()
            }
        }
    }

    private func beginInstall() {
        guard let release = pendingRelease else { return }

        // Check install location and running-app Team ID before downloading so the user isn't kept waiting.
        do {
            try UpdateInstallPreflight.checkCanReplace(appURL: currentAppURL)
            let currentSigning = try CodeSignatureVerifier.signingInfo(for: currentAppURL)
            guard currentSigning.teamIdentifier != nil else {
                throw UpdateError.unsignedRunningApp
            }
        } catch {
            windowController.close()
            showErrorAlert(
                title: "Couldn’t Install Switchyard \(release.version)",
                message: error.localizedDescription,
                releasesURL: release.pageURL
            )
            finish()
            return
        }

        let workDir = FileManager.default.temporaryDirectory.appending(
            path: "switchyard-update-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        do {
            try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
            tempDir = workDir
        } catch {
            windowController.close()
            showErrorAlert(
                title: "Couldn’t Download Switchyard \(release.version)",
                message: "Couldn’t create a temporary folder for the download (\(error.localizedDescription)). Your current version wasn’t changed.",
                releasesURL: release.pageURL
            )
            finish()
            return
        }

        windowController.show(.downloading(version: release.version.description, fraction: nil, detail: "Connecting…"))

        activeTask = Task { [weak self] in
            guard let self else { return }
            do {
                let expectedSHA256 = try await self.resolveExpectedChecksum(for: release)
                guard !self.isCancelled else { return }

                let dmgPath = try await self.downloadDMG(for: release, into: workDir)
                guard !self.isCancelled else { return }

                self.windowController.show(.installing(
                    version: release.version.description,
                    detail: "Verifying checksum…",
                    canCancel: true
                ))

                let targetURL = self.currentAppURL
                let expectedBundleID = self.bundleID
                let flag = self.cancelledFlag
                let versionText = release.version.description
                let onStage: @Sendable (InstallStage) -> Void = { [weak self] stage in
                    Task { @MainActor [weak self] in
                        self?.updateInstallStage(stage, version: versionText)
                    }
                }

                try await Task.detached(priority: .userInitiated) {
                    try UpdateInstaller.install(
                        dmgURL: dmgPath,
                        expectedSHA256: expectedSHA256,
                        expectedVersion: release.version,
                        expectedBundleID: expectedBundleID,
                        replacing: targetURL,
                        stageChange: onStage,
                        isCancelled: { flag.withLock { $0 } }
                    )
                }.value

                self.cleanupTempDir()
                self.windowController.show(.installing(
                    version: release.version.description,
                    detail: "Relaunching Switchyard…",
                    canCancel: false
                ))

                try AppRelauncher.relaunch(appURL: targetURL)
                self.finish()
                NSApp.terminate(nil)
            } catch UpdateError.cancelled {
                self.finish()
            } catch is CancellationError {
                self.finish()
            } catch let urlError as URLError where urlError.code == .cancelled {
                self.finish()
            } catch {
                guard !self.isCancelled else { return }
                updateLog.error("Update install failed: \(error.localizedDescription, privacy: .public)")
                self.windowController.close()
                self.showErrorAlert(
                    title: "Couldn’t Install Switchyard \(release.version)",
                    message: error.localizedDescription,
                    releasesURL: release.pageURL
                )
                self.finish()
            }
        }
    }

    private func updateInstallStage(_ stage: InstallStage, version: String) {
        guard !finished else { return }
        switch stage {
        case .verifyingChecksum:
            windowController.show(.installing(version: version, detail: "Verifying checksum…", canCancel: true))
        case .openingDiskImage:
            windowController.show(.installing(version: version, detail: "Opening disk image…", canCancel: true))
        case .verifyingSignature:
            windowController.show(.installing(version: version, detail: "Verifying signature…", canCancel: true))
        case .replacingApp:
            windowController.show(.installing(version: version, detail: "Replacing Switchyard…", canCancel: false))
        }
    }

    private func cancel() {
        cancelledFlag.withLock { $0 = true }
        activeTask?.cancel()
        downloadTask?.cancel()
        finish()
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        activeTask?.cancel()
        activeTask = nil
        downloadTask?.cancel()
        downloadTask = nil
        downloadDelegate = nil
        session?.invalidateAndCancel()
        session = nil
        windowController.close()
        cleanupTempDir()
        onFinish()
    }

    private func cleanupTempDir() {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
            self.tempDir = nil
        }
    }

    private var isCancelled: Bool {
        cancelledFlag.withLock { $0 }
    }

    // MARK: - Networking

    private func makeSession(delegate: URLSessionDelegate? = nil) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 300
        return URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }

    private func fetchLatestRelease(using session: URLSession) async throws -> ReleaseInfo {
        var request = URLRequest(url: UpdateFeed.latestReleaseURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Switchyard/\(currentVersionString)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw UpdateError.httpStatus(http.statusCode)
        }
        return try UpdateFeed.parseLatestRelease(data)
    }

    private func resolveExpectedChecksum(for release: ReleaseInfo) async throws -> String? {
        guard let checksumsURL = release.checksumsURL else {
            return release.sha256
        }
        let session = self.session ?? makeSession()
        self.session = session
        var request = URLRequest(url: checksumsURL)
        request.setValue("Switchyard/\(currentVersionString)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw UpdateError.httpStatus(http.statusCode)
        }
        let text = String(decoding: data, as: UTF8.self)
        guard let fromFile = UpdateFeed.parseSHA256Sums(text, filename: release.dmgName) else {
            throw UpdateError.checksumMissing(release.dmgName)
        }
        if let fromAPI = release.sha256, fromAPI != fromFile {
            throw UpdateError.checksumMismatch(expected: fromFile, actual: fromAPI)
        }
        return fromFile
    }

    private func downloadDMG(for release: ReleaseInfo, into workDir: URL) async throws -> URL {
        let destination = workDir.appending(path: release.dmgName)
        let versionText = release.version.description
        let fallbackTotal = release.dmgSize ?? -1

        return try await withCheckedThrowingContinuation { continuation in
            let delegate = DownloadDelegate(
                destination: destination,
                fallbackExpectedBytes: fallbackTotal,
                onProgress: { [weak self] written, expected in
                    Task { @MainActor [weak self] in
                        guard let self, !self.finished else { return }
                        let fraction = expected > 0 ? Double(written) / Double(expected) : nil
                        let detail = Self.formatProgress(written: written, expected: expected)
                        self.windowController.show(.downloading(
                            version: versionText,
                            fraction: fraction,
                            detail: detail
                        ))
                    }
                },
                onComplete: { result in
                    continuation.resume(with: result)
                }
            )
            self.downloadDelegate = delegate
            self.session?.invalidateAndCancel()
            let dlSession = self.makeSession(delegate: delegate)
            self.session = dlSession

            var request = URLRequest(url: release.dmgURL)
            request.setValue("Switchyard/\(self.currentVersionString)", forHTTPHeaderField: "User-Agent")
            let task = dlSession.downloadTask(with: request)
            self.downloadTask = task
            task.resume()
        }
    }

    // MARK: - Alerts

    private func showUpToDateAlert() {
        let alert = Self.makeUpToDateAlert(version: currentVersionString)
        NSApp.activate()
        if alert.runModal() == .alertSecondButtonReturn {
            openURL(UpdateFeed.releasesPageURL)
        }
    }

    private func showErrorAlert(title: String, message: String, releasesURL: URL) {
        let alert = Self.makeErrorAlert(title: title, message: message)
        NSApp.activate()
        if alert.runModal() == .alertSecondButtonReturn {
            openURL(releasesURL)
        }
    }

    static func makeUpToDateAlert(version: String) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "You’re up to date!"
        alert.informativeText = "Switchyard \(version) is currently the newest version available."
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Version History")
        return alert
    }

    static func makeErrorAlert(title: String, message: String) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Open Releases Page")
        return alert
    }

    private static func formatProgress(written: Int64, expected: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        if expected > 0 {
            return "\(formatter.string(fromByteCount: written)) of \(formatter.string(fromByteCount: expected))"
        }
        return formatter.string(fromByteCount: written)
    }

    private static func describeCheckError(_ error: Error) -> String {
        if let updateError = error as? UpdateError {
            return updateError.localizedDescription
        }
        if let urlError = error as? URLError {
            return "Switchyard couldn’t reach GitHub to check for updates (\(urlError.localizedDescription)). Check your internet connection and try again."
        }
        return error.localizedDescription
    }
}

private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let fallbackExpectedBytes: Int64
    private let onProgress: @Sendable (Int64, Int64) -> Void
    private let state: OSAllocatedUnfairLock<State>

    private struct State: Sendable {
        var completion: (@Sendable (Result<URL, Error>) -> Void)?
        var movedFile = false
    }

    init(
        destination: URL,
        fallbackExpectedBytes: Int64,
        onProgress: @escaping @Sendable (Int64, Int64) -> Void,
        onComplete: @escaping @Sendable (Result<URL, Error>) -> Void
    ) {
        self.destination = destination
        self.fallbackExpectedBytes = fallbackExpectedBytes
        self.onProgress = onProgress
        self.state = OSAllocatedUnfairLock(initialState: State(completion: onComplete))
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : fallbackExpectedBytes
        onProgress(totalBytesWritten, total)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            finish(.failure(UpdateError.httpStatus(http.statusCode)))
            return
        }
        do {
            let fm = FileManager.default
            if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
            try fm.moveItem(at: location, to: destination)
            state.withLock { $0.movedFile = true }
            finish(.success(destination))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            finish(.failure(error))
        } else {
            let moved = state.withLock { $0.movedFile }
            if !moved {
                finish(.failure(UpdateError.invalidRelease("download finished without a file")))
            }
        }
    }

    private func finish(_ result: Result<URL, Error>) {
        let handler = state.withLock { state -> (@Sendable (Result<URL, Error>) -> Void)? in
            let current = state.completion
            state.completion = nil
            return current
        }
        handler?(result)
    }
}
