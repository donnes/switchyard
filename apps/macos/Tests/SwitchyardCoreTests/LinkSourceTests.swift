import Foundation
import Testing
@testable import SwitchyardCore

@Test func readsALiveProcessesExecutableAndParent() {
    #expect(ProcessTree.executable(of: getpid()).map { URL(filePath: $0).lastPathComponent } == ProcessInfo.processInfo.processName)
    #expect(ProcessTree.parent(of: getpid()) == getppid())
}

@Test func senderThatQuitIsReportedNotGuessed() throws {
    let tool = Process()
    tool.executableURL = URL(filePath: "/usr/bin/true")
    try tool.run()
    tool.waitUntilExit()
    #expect(LinkSource(senderPID: tool.processIdentifier) == .exited(tool.processIdentifier))
    #expect(LinkSource(senderPID: 0) == .unknown)
}

@Test(arguments: [
    ("/Applications/T3 Code.app/Contents/MacOS/T3 Code", "/Applications/T3 Code.app"),
    ("/Applications/Grok.app/Contents/Library/LoginItems/Grok Bot.app/Contents/MacOS/Grok Bot", "/Applications/Grok.app/Contents/Library/LoginItems/Grok Bot.app"),
    ("/Applications/Game.app/Wrapper/Game.app/Game", "/Applications/Game.app/Wrapper/Game.app"),
    ("/Applications/Xcode.app/Contents/Developer/usr/bin/xcrun", nil),
    ("/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code", nil),
    ("/usr/bin/osascript", nil),
] as [(String, String?)])
func onlyAnAppsOwnExecutableCountsAsTheApp(executable: String, bundle: String?) {
    #expect(ProcessTree.appBundle(containing: executable) == bundle)
}

@Test func toolsShippedBesideAnAppArentTheApp() throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: "switchyard-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: folder) }
    let app = folder.appending(path: "Editor.app")
    let macOS = app.appending(path: "Contents/MacOS")
    try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
    let info = ["CFBundleIdentifier": "dev.example.editor", "CFBundleExecutable": "editor"]
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appending(path: "Contents/Info.plist"))

    func source(runningAs name: String) throws -> LinkSource {
        let executable = macOS.appending(path: name)
        try FileManager.default.copyItem(at: URL(filePath: "/bin/sleep"), to: executable)
        let process = Process()
        process.executableURL = executable
        process.arguments = ["60"]
        try process.run()
        defer { process.terminate(); process.waitUntilExit() }
        return LinkSource(senderPID: process.processIdentifier)
    }
    #expect(try source(runningAs: "editor") == .app(bundleID: "dev.example.editor", tool: nil))
    #expect(try source(runningAs: "cli").bundleID != "dev.example.editor")
}
