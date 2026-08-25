// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClaudeQuota",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "ClaudeQuota",
            path: "Sources/ClaudeQuota",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
