import Foundation

/// The current state of the passive capture system.
///
/// `CaptureStatus` drives the menu bar indicator and capture controls.
/// The main ``CaptureManager`` actor publishes status changes that flow
/// through ``AppState`` to the UI.
public enum CaptureStatus: Sendable, Hashable {
    /// No capture sources are active. The system is waiting for the user
    /// to enable capture or for a scheduled capture window to begin.
    case idle

    /// One or more capture sources are actively recording data.
    case capturing

    /// Capture was manually paused by the user. It can be resumed without
    /// re-initialization.
    case paused

    /// Private mode — all capture is suspended and no data is recorded.
    /// Activated by the user when they want guaranteed privacy.
    case privateMode

    /// An error prevented capture from continuing. The associated string
    /// describes the failure (e.g., "Microphone permission denied").
    case error(String)
}

extension CaptureStatus: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
        case message
    }

    private enum StatusType: String, Codable {
        case idle, capturing, paused, privateMode, error
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .idle:
            try container.encode(StatusType.idle, forKey: .type)
        case .capturing:
            try container.encode(StatusType.capturing, forKey: .type)
        case .paused:
            try container.encode(StatusType.paused, forKey: .type)
        case .privateMode:
            try container.encode(StatusType.privateMode, forKey: .type)
        case .error(let message):
            try container.encode(StatusType.error, forKey: .type)
            try container.encode(message, forKey: .message)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(StatusType.self, forKey: .type)
        switch type {
        case .idle:
            self = .idle
        case .capturing:
            self = .capturing
        case .paused:
            self = .paused
        case .privateMode:
            self = .privateMode
        case .error:
            let message = try container.decode(String.self, forKey: .message)
            self = .error(message)
        }
    }
}

extension CaptureStatus: CustomStringConvertible {
    public var description: String {
        switch self {
        case .idle: return "Idle"
        case .capturing: return "Capturing"
        case .paused: return "Paused"
        case .privateMode: return "Private Mode"
        case .error(let message): return "Error: \(message)"
        }
    }

    /// Whether this status indicates active data recording.
    public var isActive: Bool {
        if case .capturing = self { return true }
        return false
    }
}
