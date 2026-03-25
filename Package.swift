// swift-tools-version: 5.9
import PackageDescription

/// Kerwan — local-first macOS activity capture and billing assistant.
///
/// SQLCipher note: In production, replace the system sqlite3 with SQLCipher by
/// adding a local C target (Sources/CSQLCipher) that compiles the sqlcipher
/// amalgamation and set linkerSettings to link against it. The Swift code is
/// identical — SQLCipher is a drop-in superset of sqlite3. The PRAGMA key /
/// cipher_page_size / kdf_iter calls below are no-ops on unencrypted sqlite3
/// during development and take effect once SQLCipher is linked.
///
/// sqlite-vec note: Include the sqlite-vec amalgamation (sqlite-vec.h /
/// sqlite-vec.c) as a C target and load it via sqlite3_auto_extension at
/// startup. The Migrations file references this via loadSqliteVec().
let package = Package(
    name: "Kerwan",
    platforms: [.macOS(.v13)],
    products: [
        // MARK: Executables
        .executable(name: "Kerwan",        targets: ["Kerwan"]),
        .executable(name: "WhisperService", targets: ["WhisperService"]),

        // MARK: Foundation Libraries (P-003 – P-006)
        .library(name: "KerwanStorage",   targets: ["KerwanStorage"]),
        .library(name: "KerwanKeychain",  targets: ["KerwanKeychain"]),
        .library(name: "KerwanExclusion", targets: ["KerwanExclusion"]),
        .library(name: "KerwanCapture",   targets: ["KerwanCapture"]),

        // MARK: Utilities & Polish (Workstream 5)
        .library(name: "KerwanScoring",   targets: ["KerwanScoring"]),
    ],
    dependencies: [
        .package(url: "https://github.com/stephencelis/SQLite.swift.git", from: "0.15.3"),
    ],
    targets: [

        // ====================================================================
        // MARK: - Foundation Libraries
        // ====================================================================

        .target(
            name: "KerwanStorage",
            path: "Sources/KerwanStorage",
            swiftSettings: [
                .unsafeFlags(["-strict-concurrency=complete"])
            ]
        ),
        .target(
            name: "KerwanKeychain",
            path: "Sources/KerwanKeychain",
            swiftSettings: [
                .unsafeFlags(["-strict-concurrency=complete"])
            ]
        ),
        .target(
            name: "KerwanExclusion",
            dependencies: ["KerwanStorage"],
            path: "Sources/KerwanExclusion",
            swiftSettings: [
                .unsafeFlags(["-strict-concurrency=complete"])
            ]
        ),
        .target(
            name: "KerwanCapture",
            dependencies: ["KerwanStorage"],
            path: "Sources/KerwanCapture",
            swiftSettings: [
                .unsafeFlags(["-strict-concurrency=complete"])
            ]
        ),
        .target(
            name: "KerwanScoring",
            dependencies: ["KerwanStorage"],
            path: "Sources/KerwanScoring",
            swiftSettings: [
                .unsafeFlags(["-strict-concurrency=complete"])
            ]
        ),

        // ====================================================================
        // MARK: - Main App Target
        // ====================================================================

        .executableTarget(
            name: "Kerwan",
            dependencies: [
                .product(name: "SQLite", package: "SQLite.swift"),
                "KerwanXPCProtocol",
                "SQLCipher",
            ],
            path: "Kerwan/Sources",
            resources: [
                .copy("../Resources"),
            ],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
            ]
        ),

        // MARK: - XPC Protocol (shared between app and service)

        .target(
            name: "KerwanXPCProtocol",
            path: "KerwanXPCProtocol",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
            ]
        ),

        // MARK: - WhisperKit XPC Service

        .executableTarget(
            name: "WhisperService",
            dependencies: ["KerwanXPCProtocol"],
            path: "WhisperService/Sources",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
            ]
        ),

        // MARK: - SQLCipher (system library wrapper)

        .systemLibrary(
            name: "SQLCipher",
            path: "Vendor/SQLCipher",
            pkgConfig: "sqlcipher",
            providers: [
                .brew(["sqlcipher"]),
            ]
        ),

        // ====================================================================
        // MARK: - Tests
        // ====================================================================

        .testTarget(
            name: "KerwanStorageTests",
            dependencies: ["KerwanStorage"],
            path: "Tests/KerwanStorageTests"
        ),
        .testTarget(
            name: "KerwanKeychainTests",
            dependencies: ["KerwanKeychain"],
            path: "Tests/KerwanKeychainTests"
        ),
        .testTarget(
            name: "KerwanExclusionTests",
            dependencies: ["KerwanExclusion"],
            path: "Tests/KerwanExclusionTests"
        ),
        .testTarget(
            name: "KerwanCaptureTests",
            dependencies: ["KerwanCapture", "KerwanStorage"],
            path: "Tests/KerwanCaptureTests"
        ),
        .testTarget(
            name: "KerwanTests",
            dependencies: ["Kerwan", "KerwanXPCProtocol"],
            path: "KerwanTests",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
            ]
        ),
        .testTarget(
            name: "KerwanIntegrationTests",
            dependencies: ["Kerwan", "KerwanXPCProtocol"],
            path: "KerwanIntegrationTests",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
            ]
        ),
        .testTarget(
            name: "KerwanScoringTests",
            dependencies: ["KerwanScoring", "KerwanStorage"],
            path: "Tests/KerwanScoringTests",
            swiftSettings: [
                .unsafeFlags(["-strict-concurrency=complete"])
            ]
        ),
    ]
)
