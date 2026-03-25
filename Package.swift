// swift-tools-version: 5.9
import PackageDescription

// Kerwan — Capture & Transcription Layer (P-010 through P-018)
//
// This package builds and tests the capture/transcription layer in isolation.
// WhisperService XPC target is excluded (requires whisper.cpp C bindings and
// an embedded XPC bundle, both of which need an Xcode project to wire up).
//
// Build:   swift build
// Test:    swift test
// Lint:    swift build 2>&1 | grep -E "error:|warning:"

let package = Package(
    name: "Kerwan",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "Kerwan", targets: ["Kerwan"]),
    ],
    targets: [

        // MARK: - Main library
        // Includes every source under Kerwan/ and Shared/.
        // WhisperService/ is intentionally excluded (XPC executable, needs C bridging).

        .target(
            name: "Kerwan",
            path: ".",
            sources: [
                "Kerwan",
                "Shared",
            ],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
            ]
        ),

        // MARK: - Tests

        .testTarget(
            name: "KerwanTests",
            dependencies: ["Kerwan"],
            path: "Tests"
        ),
    ]
)
