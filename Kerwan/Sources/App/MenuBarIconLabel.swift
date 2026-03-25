import SwiftUI

/// The `MenuBarExtra` label view: an SF Symbol tinted to reflect capture status
/// with a subtle opacity pulse while WhisperService is actively transcribing.
///
/// The label is constrained to what the menu bar icon slot supports — a small
/// image with no text. The `systemImage` name resolves to "brain.head.profile"
/// (available on macOS 13+ SF Symbols 4) which is a distinctive, recognisable
/// glyph for an AI-driven capture tool.
///
/// Tinting:
/// - `.green`   — actively capturing
/// - `.yellow`  — paused
/// - `.red`     — private mode
/// - `.secondary` (adaptive gray) — idle / stopped
/// - `.orange`  — error state
///
/// Pulse animation:
/// When `activeTranscription` is `true` the icon opacity oscillates between
/// 1.0 and 0.45 on a 0.9-second ease-in-out loop. The animation is started and
/// stopped via `onChange` so it never runs unnecessarily.
@MainActor
struct MenuBarIconLabel: View {
    @Environment(AppState.self) private var appState

    /// Drives the repeating opacity animation when transcription is active.
    @State private var pulseOpacity: Double = 1.0

    var body: some View {
        Image(systemName: "brain.head.profile")
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(iconColor)
            .opacity(pulseOpacity)
            .onChange(of: appState.activeTranscription) { _, isTranscribing in
                if isTranscribing {
                    startPulse()
                } else {
                    stopPulse()
                }
            }
            .onAppear {
                // Restore pulse state if view re-appears mid-transcription.
                if appState.activeTranscription {
                    startPulse()
                }
            }
    }

    // MARK: - Icon color

    /// Maps the current `CaptureStatus` to an appropriate tint color.
    private var iconColor: Color {
        switch appState.captureStatus {
        case .capturing:   return .green
        case .paused:      return .yellow
        case .privateMode: return .red
        case .idle:        return .secondary
        case .error:       return .orange
        }
    }

    // MARK: - Pulse animation

    /// Starts a repeating ease-in-out opacity animation that signals active
    /// transcription without being distracting.
    private func startPulse() {
        withAnimation(
            .easeInOut(duration: 0.9)
            .repeatForever(autoreverses: true)
        ) {
            pulseOpacity = 0.45
        }
    }

    /// Stops the pulse and snaps the icon back to fully opaque.
    private func stopPulse() {
        withAnimation(.easeOut(duration: 0.25)) {
            pulseOpacity = 1.0
        }
    }
}
