// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "Write",
    // Liquid Glass and the Wikipedia reader's SwiftUI need macOS 26.
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "Write",
            path: "Sources/Write",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
