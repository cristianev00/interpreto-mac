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
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.4"),
    ],
    targets: [
        .systemLibrary(name: "SherpaOnnxC", path: "Vendor/SherpaOnnxC"),
        // llama.cpp (MIT) for the HY-MT2 translation model, Metal-accelerated.
        .binaryTarget(
            name: "llama",
            url: "https://github.com/ggml-org/llama.cpp/releases/download/b11381/llama-b11381-xcframework.zip",
            checksum: "0d41c207c7c0ad736d0b8662add59872c63fa416f10eb087c7e62e012295416f"),
        .executableTarget(
            name: "Interpreto",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
                "SherpaOnnxC",
                "llama",
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
    ]
)
