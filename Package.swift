// swift-tools-version:6.0
// Interpreto for Mac — live English ⇄ Chinese speech translation with Apple's on-device engines.
import PackageDescription

let package = Package(
    name: "Interpreto",
    platforms: [.macOS("26.4")],
    targets: [
        .executableTarget(
            name: "Interpreto",
            path: "Sources/Interpreto",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
