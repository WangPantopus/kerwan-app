// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "Kerwan",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "Kerwan", targets: ["Kerwan"]),
        .executable(name: "WhisperService", targets: ["WhisperService"])
    ],
    dependencies: [
        .package(url: "https://github.com/stephencelis/SQLite.swift.git", from: "0.15.3")
    ],
    targets: [
        // MARK: - Main App Target
        .executableTarget(
            name: "Kerwan",
            dependencies: [
                .product(name: "SQLite", package: "SQLite.swift"),
                "KerwanXPCProtocol",
                "SQLCipher"
            ],
            path: "Kerwan/Sources",
            resources: [
                .copy("../Resources")
            ],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),

        // MARK: - XPC Protocol (shared between app and service)
        .target(
            name: "KerwanXPCProtocol",
            path: "KerwanXPCProtocol",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),

        // MARK: - WhisperKit XPC Service
        .executableTarget(
            name: "WhisperService",
            dependencies: [
                "KerwanXPCProtocol"
            ],
            path: "WhisperService/Sources",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),

        // MARK: - SQLCipher (system library wrapper)
        .systemLibrary(
            name: "SQLCipher",
            path: "Vendor/SQLCipher",
            pkgConfig: "sqlcipher",
            providers: [
                .brew(["sqlcipher"])
            ]
        ),

        // MARK: - Unit Tests
        .testTarget(
            name: "KerwanTests",
            dependencies: ["Kerwan", "KerwanXPCProtocol"],
            path: "KerwanTests",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),

        // MARK: - Integration Tests
        .testTarget(
            name: "KerwanIntegrationTests",
            dependencies: ["Kerwan", "KerwanXPCProtocol"],
            path: "KerwanIntegrationTests",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        )
    ]
)
