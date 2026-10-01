// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Sandglass",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "SandglassCore"),
        // The app's own logic, kept out of the executable so it can be tested. Depends on no
        // UI framework: AppKit, SwiftUI and UserNotifications all live in Sandglass.
        .target(name: "SandglassAppCore", dependencies: ["SandglassCore"]),
        .executableTarget(name: "Sandglass", dependencies: ["SandglassCore", "SandglassAppCore"]),
        .executableTarget(name: "SandglassTests", dependencies: ["SandglassCore", "SandglassAppCore"]),
    ]
)
