import Foundation
import Synchronization

enum ProcessTree {
    /// Nil once the process has exited.
    static func executable(of pid: pid_t) -> String? {
        var path = [UInt8](repeating: 0, count: Int(4 * MAXPATHLEN))
        let length = proc_pidpath(pid, &path, UInt32(path.count))
        return length > 0 ? String(decoding: path.prefix(Int(length)), as: UTF8.self) : nil
    }

    /// 0 once the process has exited.
    static func parent(of pid: pid_t) -> pid_t {
        var info = proc_bsdshortinfo()
        let size = Int32(MemoryLayout<proc_bsdshortinfo>.size)
        return proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, size) == size ? pid_t(info.pbsi_ppid) : 0
    }

    /// An app's executable sits in `X.app/Contents/MacOS`, or in `X.app` itself for iPad apps. Tools elsewhere in a
    /// bundle, like Xcode's, aren't the app.
    static func appBundle(containing executable: String) -> String? {
        let folder = (executable as NSString).deletingLastPathComponent
        if folder.hasSuffix(".app") { return folder }
        let macOS = "/Contents/MacOS"
        guard folder.hasSuffix(".app" + macOS) else { return nil }
        return String(folder.dropLast(macOS.count))
    }
}

/// Where a link came from. A command-line tool counts as the app it runs in, like Terminal, so `from` rules see that app.
public enum LinkSource: Equatable, Sendable, CustomStringConvertible {
    case app(bundleID: String, tool: String?)
    /// A tool with no app above it, like one started by launchd.
    case tool(String)
    /// The sender quit before the link arrived, as `open` and `osascript` usually have, so its parents are unknown.
    case exited(pid_t)
    case unknown

    /// Reads executable paths instead of asking NSRunningApplication, which costs 5 to 10 times as much on every link.
    /// launchd starts every app, so a tool's app is its outermost ancestor, and only that one's path is read.
    public init(senderPID pid: pid_t) {
        guard pid > 0 else { self = .unknown; return }
        guard let executable = ProcessTree.executable(of: pid) else { self = .exited(pid); return }
        if let bundleID = Self.appBundleID(executable) { self = .app(bundleID: bundleID, tool: nil); return }

        let tool = (executable as NSString).lastPathComponent
        var outermost = pid
        var parent = ProcessTree.parent(of: pid)
        while parent > 1 {
            outermost = parent
            parent = ProcessTree.parent(of: parent)
        }
        if outermost != pid, let path = ProcessTree.executable(of: outermost), let bundleID = Self.appBundleID(path) {
            self = .app(bundleID: bundleID, tool: tool)
        } else {
            self = .tool(tool)
        }
    }

    private static let bundleIDs = Mutex<[String: String]>([:])

    private static func appBundleID(_ executable: String) -> String? {
        guard let app = ProcessTree.appBundle(containing: executable) else { return nil }
        if let cached = bundleIDs.withLock({ $0[executable] }) { return cached }
        // Apps like Zed ship command-line tools beside their own executable, and those aren't the app.
        guard let bundle = Bundle(path: app), bundle.executableURL?.lastPathComponent == (executable as NSString).lastPathComponent,
              let bundleID = bundle.bundleIdentifier else { return nil }
        bundleIDs.withLock { $0[executable] = bundleID }
        return bundleID
    }

    public var bundleID: String? {
        if case .app(let bundleID, _) = self { bundleID } else { nil }
    }

    public var description: String {
        switch self {
        case .app(let bundleID, let tool): tool.map { "\(bundleID) via \($0)" } ?? bundleID
        case .tool(let name): "\(name) (no app)"
        case .exited(let pid): "pid \(pid) (quit)"
        case .unknown: "unknown"
        }
    }
}
