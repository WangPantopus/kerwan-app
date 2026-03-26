import Foundation
import IOKit

/// Reads the hardware UUID that uniquely identifies this Mac.
///
/// The UUID is obtained from IOKit's `IOPlatformExpertDevice` entry and is:
/// - **Stable** across app reinstalls, macOS upgrades, and reboots.
/// - **Unique** per physical machine (not per user account).
/// - Used by the license backend to enforce machine-binding (one active seat
///   per machine by default).
///
/// ## Usage
/// ```swift
/// let id = MachineIdentifier.hardwareUUID()
/// // → "8A45C63D-1B2F-4E7A-9D3C-F0B81A4C5E62"
/// ```
enum MachineIdentifier {

    /// Returns the hardware UUID for this machine.
    ///
    /// Falls back to a hostname-derived string if IOKit is unavailable.
    /// On any real macOS installation this branch is never taken.
    static func hardwareUUID() -> String {
        // IOServiceGetMatchingService consumes the matching dictionary (CFRelease
        // is called internally), so we do not need to release `matching`.
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("IOPlatformExpertDevice")
        )

        guard service != 0 else {
            return fallback()
        }
        defer { IOObjectRelease(service) }

        let cfKey = "IOPlatformUUID" as CFString
        guard let rawValue = IORegistryEntryCreateCFProperty(
            service,
            cfKey,
            kCFAllocatorDefault,
            0   // options — 0 = none
        ) else {
            return fallback()
        }

        // takeRetainedValue() transfers ownership and bridges to Swift.
        guard let uuid = rawValue.takeRetainedValue() as? String, !uuid.isEmpty else {
            return fallback()
        }

        return uuid
    }

    // MARK: - Private

    /// Stable fallback for environments where IOKit is unavailable (unit test
    /// hosts, CI runners, etc.). Not a UUID but deterministic per host.
    private static func fallback() -> String {
        "host-\(ProcessInfo.processInfo.hostName)"
    }
}
