// swift-tools-version:6.0
// Interpreto for Mac — live English ⇄ Chinese speech translation, on device.
// Speech: Apple (default), Parakeet (FluidAudio) for English, SenseVoice (sherpa-onnx) for Chinese.
import Foundation
import PackageDescription

/// sherpa-onnx's runtime (fetched and verified by scripts/fetch-vendor.sh).
let sherpaLib = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent("Vendor/sherpa-onnx/lib").path

let package = Package(
    name: "Interpreto",
    platforms: [.macOS("26.4")],
    dependencies: [
        // Parakeet speech recognition on the Neural Engine (Apache-2.0).
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.18.2"),
    ],
    targets: [
        .systemLibrary(name: "SherpaOnnxC", path: "Vendor/SherpaOnnxC"),
        .executableTarget(
            name: "Interpreto",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
                "SherpaOnnxC",
            ],
            path: "Sources/Interpreto",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .unsafeFlags([
                    "-L", sherpaLib,
                    // In the app the libraries sit in Contents/Frameworks; during development, here.
                    "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
                    "-Xlinker", "-rpath", "-Xlinker", sherpaLib,
                ]),
            ]
        ),
        // `swift test` (Swift Testing, from Xcode's toolchain): glossary, term fixer, text tidying.
        .testTarget(
            name: "InterpretoTests",
            dependencies: ["Interpreto"],
            path: "Tests/InterpretoTests",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", sherpaLib])]
        ),
    ]
)
