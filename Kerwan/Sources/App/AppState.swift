import Foundation
import os

/// Observable application state shared across the SwiftUI view hierarchy.
///
/// `AppState` serves as the root-level state container, holding references to
/// service status, capture state, and user preferences. It uses the `@Observable`
/// macro (Observation framework, macOS 14+) with a fallback note for macOS 13.
@Observable
final class AppState {
    private static let logger = Logger(
        subsystem: "com.kerwan.app",
        category: "AppState"
    )

    // MARK: - Capture State

    /// Whether passive audio capture is currently active.
    var isCaptureActive: Bool = false

    /// Whether the whisper model is loaded and ready for transcription.
    var isModelLoaded: Bool = false

    // MARK: - Service Status

    /// Whether the Ollama subprocess is running and responsive.
    var isOllamaRunning: Bool = false

    /// Whether the WhisperService XPC connection is established.
    var isWhisperServiceConnected: Bool = false

    // MARK: - Session State

    /// The number of sessions captured today.
    var todaySessionCount: Int = 0

    /// Total minutes of audio captured today.
    var todayCapturedMinutes: Double = 0.0

    // MARK: - Errors

    /// The most recent error to display to the user, if any.
    var lastError: String?

    // MARK: - Degradation

    /// Live health status for Whisper, Ollama, IMAP, AX, and Database subsystems.
    var degradation = GracefulDegradationManager()

    init() {
        Self.logger.info("AppState initialized")
    }
}
