// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "claude-top",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ClaudeTopKit", targets: ["ClaudeTopKit"]),
        .executable(name: "claude-top", targets: ["ClaudeTopCLI"]),
        .executable(name: "ClaudeTopApp", targets: ["ClaudeTopApp"]),
    ],
    // No third-party dependencies. System frameworks only: libproc, sysctl,
    // libsqlite3, SwiftUI, Charts. See CLAUDE.md before adding any.
    dependencies: [],
    targets: [
        .target(name: "ClaudeTopKit"),

        .executableTarget(name: "ClaudeTopCLI", dependencies: ["ClaudeTopKit"]),

        // Built into an .app bundle by Scripts/make-app.sh rather than by Xcode.
        // A MenuBarExtra app needs no storyboards, so there is no project file.
        .executableTarget(name: "ClaudeTopApp", dependencies: ["ClaudeTopKit"]),

        // Fixtures live at Tests/Fixtures and are located at runtime relative to
        // #filePath rather than bundled, since SPM will not accept a resource
        // path outside the target's own directory.
        .testTarget(name: "ClaudeTopKitTests", dependencies: ["ClaudeTopKit"]),
    ]
)
