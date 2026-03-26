#if canImport(Sparkle)
import Sparkle
import Foundation
import os

/// Manages automatic app updates via Sparkle 2.
///
/// Owns a `SPUStandardUpdaterController` that wires the full Sparkle update UI.
/// Automatic background checks run on launch and every 24 hours (controlled by
/// `SUScheduledCheckInterval` in `Info.plist`). The "Check for Updates…" menu
/// item calls ``checkForUpdates()`` to trigger an explicit user-initiated check.
///
/// ## EdDSA key setup (one-time, before shipping)
///
/// 1. Download the Sparkle distribution archive for the version pinned in
///    `Package.swift` and extract `./bin/generate_keys`:
///    ```sh
///    ./bin/generate_keys
///    ```
///    The tool prints a **private key** (store in 1Password / CI secrets) and a
///    **public key** (paste into `Info.plist` as `SUPublicEDKey`).
///
/// 2. Sign each appcast item with the private key before publishing:
///    ```sh
///    ./bin/sign_update path/to/Kerwan-1.2.3.zip
///    ```
///    Paste the `edSignature` and `length` values into the appcast XML.
@MainActor
final class UpdateManager: NSObject, SPUUpdaterDelegate {

    private static let logger = Logger(
        subsystem: "com.kerwan.app",
        category: "UpdateManager"
    )

    private let updaterController: SPUStandardUpdaterController

    override init() {
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        super.init()
        Self.logger.info("UpdateManager initialised — automatic update checks active")
    }

    func checkForUpdates() {
        Self.logger.info("Manual update check requested")
        updaterController.checkForUpdates(nil)
    }
}

#else

// Stub for builds where Sparkle is not linked (e.g. swift test on CI).
import Foundation

@MainActor
final class UpdateManager: NSObject {
    override init() { super.init() }
    func checkForUpdates() {}
}

#endif
