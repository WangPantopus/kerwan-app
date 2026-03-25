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
///
/// ## Appcast XML format
///
/// The feed served at `SUFeedURL` must be valid RSS 2.0 with Sparkle extensions:
///
/// ```xml
/// <?xml version="1.0" encoding="utf-8"?>
/// <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
///   <channel>
///     <title>Kerwan Updates</title>
///     <item>
///       <title>Kerwan 1.2.3</title>
///       <pubDate>Wed, 25 Mar 2026 12:00:00 +0000</pubDate>
///       <sparkle:version>42</sparkle:version>
///       <sparkle:shortVersionString>1.2.3</sparkle:shortVersionString>
///       <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
///       <enclosure
///         url="https://api.kerwan.app/releases/Kerwan-1.2.3.zip"
///         type="application/octet-stream"
///         sparkle:edSignature="BASE64_EDSIG_HERE"
///         length="12345678"/>
///     </item>
///   </channel>
/// </rss>
/// ```
///
/// > Important: `sparkle:version` must be a monotonically increasing integer
/// > matching `CFBundleVersion`. `sparkle:shortVersionString` is the
/// > human-readable label shown in the update sheet.
@MainActor
final class UpdateManager: NSObject, SPUUpdaterDelegate {

    private static let logger = Logger(
        subsystem: "com.kerwan.app",
        category: "UpdateManager"
    )

    // MARK: - Private state

    /// Sparkle 2 controller — owns the background update scheduler and UI driver.
    ///
    /// `startingUpdater: true` immediately begins the automatic check cycle
    /// according to `SUScheduledCheckInterval` in `Info.plist`.
    private let updaterController: SPUStandardUpdaterController

    // MARK: - Init

    override init() {
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        super.init()
        Self.logger.info("UpdateManager initialised — automatic update checks active")
    }

    // MARK: - Public API

    /// Triggers a user-initiated update check (connected to "Check for Updates…").
    ///
    /// Sparkle will show the standard update sheet or an alert if the app is
    /// already up to date. Safe to call from any `@MainActor` context.
    func checkForUpdates() {
        Self.logger.info("Manual update check requested")
        updaterController.checkForUpdates(nil)
    }
}
