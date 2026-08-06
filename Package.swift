// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClaudeUsageMonitor",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "ClaudeUsageMonitor",
            path: "Sources/ClaudeUsageMonitor",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
