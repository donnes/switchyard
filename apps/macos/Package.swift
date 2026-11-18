// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Switchyard",
    // macOS 26 is also what turns on Liquid Glass: macOS keeps apps built for older systems on the old look.
    platforms: [.macOS(.v26)],
    targets: [
        // Rules, config and profile discovery. Foundation only, so it stays testable without AppKit.
        .target(name: "SwitchyardCore"),
        .executableTarget(name: "Switchyard", dependencies: ["SwitchyardCore"]),
        .testTarget(name: "SwitchyardCoreTests", dependencies: ["SwitchyardCore"]),
    ]
)
