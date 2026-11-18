import AppKit
import Observation
import SwitchyardCore

/// Owns the config file: loads it, watches it for outside edits and saves changes from settings.
@MainActor
@Observable
final class ConfigStore {
    let url: URL
    private(set) var config: Config
    private(set) var router: Router
    /// Set when the file can't be read or a pattern doesn't compile. The last good rules stay in use.
    private(set) var error: String?
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private var folderWatcher: DispatchSourceFileSystemObject?
    @ObservationIgnored private var fileWatcher: DispatchSourceFileSystemObject?
    /// The file on disk doesn't load. Settings must not save over it: the user is likely mid-edit,
    /// and the copy in memory is older than what they wrote.
    @ObservationIgnored private var fileIsBroken = false

    init(url: URL) {
        self.url = url
        let empty = Config(fallback: Target(browser: "com.apple.Safari"))
        config = empty
        router = try! Router(config: empty) // An empty config has no patterns to fail on.
    }

    func load() {
        if !FileManager.default.fileExists(atPath: url.path) {
            try? Config(fallback: Target(browser: Self.currentDefaultBrowser())).save(to: url)
        }
        reload()
        watch()
    }

    /// Saves a change made in settings. Returns why it wasn't saved, or nil when it was.
    @discardableResult
    func update(_ change: (inout Config) -> Void) -> String? {
        var next = config
        change(&next)
        // SwiftUI bindings can call their setter with the current value. Don't rewrite the file then.
        guard next != config else { return nil }
        // The change is based on `config`. If the file no longer matches it (an outside edit the watcher
        // hasn't delivered yet, or a file that doesn't load), saving would overwrite that edit.
        guard !fileIsBroken, (try? Config.load(from: url)) == config else {
            reload()
            return error ?? "\(url.lastPathComponent) changed on disk, so this change wasn't saved. Settings now show the new file."
        }
        do {
            try next.save(to: url)
            apply(next)
            return nil
        } catch {
            // Also in the banner: most settings controls have nowhere else to show it.
            let problem = "Couldn't save \(url.path): \(error.localizedDescription)"
            self.error = problem
            onChange?()
            return problem
        }
    }

    private func reload() {
        do {
            apply(try Config.load(from: url))
        } catch let decoding as DecodingError {
            broken("\(url.lastPathComponent): \(Self.describe(decoding))")
        } catch {
            broken("\(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    private func apply(_ next: Config) {
        do {
            router = try Router(config: next)
            config = next
            error = nil
            fileIsBroken = false
            onChange?()
        } catch {
            broken("A pattern doesn't compile: \(error.localizedDescription)")
        }
    }

    private func broken(_ problem: String) {
        error = problem + " Settings won't save until the file is fixed."
        fileIsBroken = true
        onChange?()
    }

    /// Watches the folder for saves that replace the file (atomic writes, most editors) and the file
    /// itself for saves that write into it (`cp`, some editors). A replaced file needs a new file watch.
    private func watch() {
        folderWatcher = Self.source(for: url.deletingLastPathComponent(), events: .write) { [weak self] in
            self?.watchFile()
            self?.reloadIfChanged()
        }
        watchFile()
    }

    private func watchFile() {
        fileWatcher?.cancel()
        fileWatcher = Self.source(for: url, events: [.write, .extend, .delete, .rename]) { [weak self] in
            self?.reloadIfChanged()
        }
    }

    private static func source(for url: URL, events: DispatchSource.FileSystemEvent, handler: @escaping @MainActor () -> Void) -> DispatchSourceFileSystemObject? {
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: events, queue: .main)
        source.setEventHandler { MainActor.assumeIsolated(handler) }
        source.setCancelHandler { close(fd) }
        source.resume()
        return source
    }

    private func reloadIfChanged() {
        guard let onDisk = try? Config.load(from: url) else { return reload() }
        // Not on any `error`: a failed atomic save touches the folder too, and reloading the unchanged
        // file would clear the save error before anyone sees it.
        if onDisk != config || fileIsBroken { reload() }
    }

    static func currentDefaultBrowser() -> String {
        let me = Bundle.main.bundleIdentifier
        if let app = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com")!),
           let id = Bundle(url: app)?.bundleIdentifier, id != me {
            return id
        }
        return "com.apple.Safari"
    }

    private static func describe(_ error: DecodingError) -> String {
        switch error {
        case .keyNotFound(let key, let context):
            "missing \"\(key.stringValue)\" at \(path(context))"
        case .typeMismatch(_, let context), .valueNotFound(_, let context):
            "wrong value at \(path(context))"
        case .dataCorrupted(let context):
            context.underlyingError.map { "not valid JSON (\(($0 as NSError).localizedDescription))" } ?? "not valid JSON"
        @unknown default:
            error.localizedDescription
        }
    }

    private static func path(_ context: DecodingError.Context) -> String {
        context.codingPath.map { $0.intValue.map(String.init) ?? $0.stringValue }.joined(separator: ".")
    }
}
