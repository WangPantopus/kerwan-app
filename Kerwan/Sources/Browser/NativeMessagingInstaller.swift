import Foundation
import os

/// Installs the Chrome Native Messaging Host manifest so Chrome can discover
/// and launch the `kerwan-nmh` binary.
///
/// ## What this writes
///
/// `~/Library/Application Support/Google/Chrome/NativeMessagingHosts/com.kerwan.app.json`
///
/// ```json
/// {
///   "name": "com.kerwan.app",
///   "description": "Kerwan Native Messaging Host",
///   "path": "/path/to/kerwan-nmh",
///   "type": "stdio",
///   "allowed_origins": [
///     "chrome-extension://<extensionID>/"
///   ]
/// }
/// ```
///
/// The extension ID must be provided by the user via `BrowserSettingsTab`.
/// Until it is set, installation is not possible.
///
/// ## NMH binary location
///
/// In a debug build the binary lives next to the `Kerwan` executable. In a
/// production `.app` bundle it lives in `Contents/MacOS/kerwan-nmh`.
struct NativeMessagingInstaller {

    private static let logger = Logger(
        subsystem: "com.kerwan.app",
        category: "NativeMessagingInstaller"
    )

    static let nmhName = "com.kerwan.app"
    static let nmhFilename = nmhName + ".json"

    // Chrome NMH directory (user-level).
    static var chromeNMHDirectory: URL {
        FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Google/Chrome/NativeMessagingHosts")
    }

    static var manifestURL: URL {
        chromeNMHDirectory.appendingPathComponent(nmhFilename)
    }

    // ─── Install ──────────────────────────────────────────────────────────────

    /// Writes the NMH manifest for `extensionID` to the Chrome NMH directory.
    ///
    /// - Parameter extensionID: The unpacked or store extension ID, e.g.
    ///   `"abcdefghijklmnopqrstuvwxyzabcdef"`.
    /// - Throws: File I/O errors or if the NMH binary cannot be located.
    static func install(extensionID: String) throws {
        let nmhPath = try nmhBinaryPath()
        let manifest = buildManifest(nmhPath: nmhPath, extensionID: extensionID)
        let data = try JSONSerialization.data(
            withJSONObject: manifest,
            options: [.prettyPrinted, .sortedKeys]
        )
        try FileManager.default.createDirectory(
            at: chromeNMHDirectory,
            withIntermediateDirectories: true
        )
        try data.write(to: manifestURL, options: .atomic)
        logger.info("NMH manifest written to \(manifestURL.path, privacy: .public)")
    }

    /// Removes the manifest file (e.g. on uninstall / extension ID change).
    static func uninstall() {
        try? FileManager.default.removeItem(at: manifestURL)
        logger.info("NMH manifest removed")
    }

    /// Returns `true` if the manifest file currently exists.
    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: manifestURL.path)
    }

    // ─── Helpers ──────────────────────────────────────────────────────────────

    private static func buildManifest(
        nmhPath: String,
        extensionID: String
    ) -> [String: Any] {
        [
            "name": nmhName,
            "description": "Kerwan Native Messaging Host — relays browser context to the Kerwan app.",
            "path": nmhPath,
            "type": "stdio",
            "allowed_origins": [
                "chrome-extension://\(extensionID)/"
            ]
        ]
    }

    private static func nmhBinaryPath() throws -> String {
        // Production: kerwan-nmh is a sibling of the Kerwan executable inside
        // the .app bundle's Contents/MacOS/.
        let executableURL = Bundle.main.executableURL
        let sibling = executableURL?
            .deletingLastPathComponent()
            .appendingPathComponent("kerwan-nmh")

        if let path = sibling?.path,
           FileManager.default.isExecutableFile(atPath: path) {
            return path
        }

        // Development / SPM: look for kerwan-nmh next to the Kerwan executable
        // (both end up in .build/…/debug/ or .build/…/release/).
        if let execDir = executableURL?.deletingLastPathComponent(),
           FileManager.default.isExecutableFile(
               atPath: execDir.appendingPathComponent("kerwan-nmh").path
           ) {
            return execDir.appendingPathComponent("kerwan-nmh").path
        }

        throw InstallerError.nmhBinaryNotFound
    }
}

// MARK: - Errors

enum InstallerError: LocalizedError {
    case nmhBinaryNotFound

    var errorDescription: String? {
        switch self {
        case .nmhBinaryNotFound:
            return "kerwan-nmh binary not found. Build the project and try again."
        }
    }
}
