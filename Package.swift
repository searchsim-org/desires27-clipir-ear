// swift-tools-version:6.0
// ponytail: tools 6.0 matches Xcode 16.2 (ADR-008); GRDB pinned to 7.8.0, the last release on tools 6.0.
// Binary deps are built by `make deps` (tools/deps/*.sh): sherpa-onnx v1.13.8 without TTS (ADR-007),
// llama.cpp b11624 from source (the release zip has no iOS simulator slice).
import PackageDescription

let package = Package(
    name: "EarCore",
    platforms: [.iOS(.v18), .macOS(.v15)],  // ADR-008: iOS 18 (owner phone on 18.6.2), ADR-005: macOS 15
    products: [
        .library(name: "EarCore", targets: ["EarCore"]),
        .executable(name: "EarCLI", targets: ["EarCLI"]),
        .library(name: "EarTTSKokoro", targets: ["EarTTSKokoro"]),  // ADR-020; MLX, so build with xcodebuild
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.8.0"),
        // Kokoro TTS (ADR-020): local copies fetched and patched for Xcode 16.2 by tools/deps/fetch_kokoro.sh
        .package(path: "Packages/kokoro/kokoro-ios"),
        .package(path: "Packages/kokoro/MLXUtilsLibrary"),
        .package(url: "https://github.com/ml-explore/mlx-swift", exact: "0.30.2"),
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", exact: "0.9.20"),
    ],
    targets: [
        .binaryTarget(name: "llama", path: "Packages/llama/llama.xcframework"),
        .binaryTarget(name: "SherpaOnnxC", path: "Packages/SherpaOnnx/SherpaOnnxC.xcframework"),
        .binaryTarget(name: "onnxruntime", path: "Packages/SherpaOnnx/onnxruntime.xcframework"),
        .target(
            name: "EarCore",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift"), "llama", "SherpaOnnxC", "onnxruntime"],
            resources: [.copy("Assets")],  // not "Resources": codesign rejects that folder name in an iOS bundle
            linkerSettings: [.linkedLibrary("c++"), .linkedFramework("Accelerate"), .linkedFramework("CoreML")]
        ),
        .executableTarget(name: "EarCLI", dependencies: ["EarCore"]),
        .testTarget(name: "EarCoreTests", dependencies: ["EarCore", "llama", "SherpaOnnxC"]),
        .target(
            name: "EarTTSKokoro",
            dependencies: [
                "EarCore",
                .product(name: "KokoroSwift", package: "kokoro-ios"),
                .product(name: "MLXUtilsLibrary", package: "MLXUtilsLibrary"),
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
            ],
            // KokoroSwift types are not Sendable; KokoroSpeaker serialises access to them
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(name: "EarTTSKokoroTests", dependencies: ["EarTTSKokoro", "EarCore", "SherpaOnnxC", "llama"]),
    ],
    swiftLanguageModes: [.v6]
)
