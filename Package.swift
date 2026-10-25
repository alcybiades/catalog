// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "Catalog",
    // Liquid Glass and the Wikipedia reader's SwiftUI need macOS 26.
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "Catalog",
            path: "Sources/Catalog",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
