import Foundation

/// A minimal client for Ardia's control socket, the one the `ardia` CLI uses.
/// One JSON object per line: `hello` first, then `apply` with an `open` op.
/// It needs "Let the ardia command control Ardia" on in Ardia's settings.
enum ArdiaControl {
    struct Failure: Error, CustomStringConvertible {
        let description: String
        /// Ardia isn't ready: nothing listens on the socket yet, or it dropped us before `hello` finished.
        var unreachable = false
        /// Ardia refused because it has no window yet, which the reopen request makes it open.
        var noWindow = false
        /// Ardia got the whole `apply` and didn't answer. It may have opened the tab.
        var unconfirmed = false
    }

    static var socketPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/com.ardia.browser/ArdiaControl.sock").path
    }

    /// Blocking, with a short timeout per step. Call it off the main thread.
    /// Retries while Ardia is still starting (no socket for up to `waitForSocket`) or still opening the
    /// window it was asked for (no-window refusals for up to 2 s). Any other failure throws at once.
    static func open(_ link: URL, profileID: String, activate: Bool, waitForSocket: Duration = .zero, timeout: TimeInterval = 1.5) throws {
        let start = ContinuousClock.now
        while true {
            do {
                let fd = try connect(timeout: timeout)
                defer { close(fd) }
                try send(link, profileID: profileID, activate: activate, on: fd)
                return
            } catch let failure as Failure {
                let waited = ContinuousClock.now - start
                let retry = failure.unreachable ? waited < waitForSocket
                    : failure.noWindow ? waited < max(waitForSocket, .seconds(2))
                    : false
                guard retry else { throw failure }
                Thread.sleep(forTimeInterval: 0.2)
            }
        }
    }

    private static func send(_ link: URL, profileID: String, activate: Bool, on fd: Int32) throws {
        let hello = try call(fd, id: 1, method: "hello", params: ["caller": ["name": "Switchyard"]])
        guard (hello["result"] as? [String: Any])?["app"] as? String == "Ardia" else {
            throw Failure(description: "Something other than Ardia answers on its control socket.")
        }
        var op: [String: Any] = ["op": "open", "urls": [link.absoluteString], "profile": profileID]
        // Ardia shows the new tab only with this flag. Without it the tab opens in the background.
        if activate { op["activate"] = true }
        let reply = try call(fd, id: 2, method: "apply", params: ["ops": [op]])
        // A refused request has a top-level error. A failed op, like having no window open, has ok: false.
        let result = reply["result"] as? [String: Any]
        guard result?["ok"] as? Bool == true else {
            let error = (reply["error"] ?? result?["error"]) as? [String: Any]
            let code = error?["code"] as? String ?? ""
            let message = error?["message"] as? String ?? "unknown error"
            // Ardia says "No window the ardia command can use is open." (or "No browser window …").
            let noWindow = code.contains("window") || message.lowercased().hasPrefix("no window")
                || message.lowercased().hasPrefix("no browser window")
            throw Failure(description: "Ardia didn't open the link: \(message)", noWindow: noWindow)
        }
    }

    private static func connect(timeout: TimeInterval) throws -> Int32 {
        let unreachable = Failure(description: "Ardia isn't running, or \"Let the ardia command control Ardia\" is off.", unreachable: true)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw unreachable }

        var wait = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - Double(Int(timeout))) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
        // A write after Ardia hangs up should fail, not kill Switchyard with SIGPIPE.
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = Array(socketPath.utf8CString)
        guard path.count <= MemoryLayout.size(ofValue: address.sun_path) else { close(fd); throw unreachable }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            path.withUnsafeBytes { buffer.copyMemory(from: $0) }
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { close(fd); throw unreachable }

        // Only talk to a socket served by this user, like the CLI does.
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else {
            close(fd)
            throw Failure(description: "Ardia's control socket belongs to another user.")
        }
        return fd
    }

    private static func call(_ fd: Int32, id: Int, method: String, params: [String: Any]) throws -> [String: Any] {
        var line = try JSONSerialization.data(withJSONObject: ["id": id, "method": method, "params": params])
        line.append(UInt8(ascii: "\n"))
        let written = line.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        // Losing Ardia during `hello` means it's still starting, so that's worth a retry. A lost `apply` reply
        // isn't: Ardia may already have opened the tab, so it's reported as unconfirmed instead.
        let starting = method == "hello"
        guard written == line.count else { throw Failure(description: "Lost the connection to Ardia.", unreachable: starting) }

        // Read lines until the reply with our id. Ardia only sends events to subscribers, so this is short.
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let message = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                if let object = try? JSONSerialization.jsonObject(with: message) as? [String: Any],
                   object["id"] as? Int == id {
                    return object
                }
            }
            let count = read(fd, &chunk, chunk.count)
            guard count > 0 else {
                let what = count == 0 ? "Ardia closed the connection before answering \(method)." : "Ardia didn't answer \(method) in time."
                throw Failure(description: what, unreachable: starting, unconfirmed: method == "apply")
            }
            buffer.append(contentsOf: chunk[0..<count])
        }
    }
}
