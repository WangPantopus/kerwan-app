import Foundation

/// A model present in the local Ollama registry, as returned by `GET /api/tags`.
public struct OllamaModel: Codable, Sendable, Identifiable, Hashable {

    /// Fully-qualified model name, e.g. `"llama3:8b-instruct-q4_K_M"` or `"nomic-embed-text"`.
    public let name: String

    /// ISO 8601 timestamp of the last modification (e.g. when the model was pulled or updated).
    public let modifiedAt: String?

    /// On-disk size in bytes.
    public let size: Int64?

    /// SHA-256 digest of the model manifest.
    public let digest: String?

    /// Additional metadata reported by Ollama about the model's architecture and quantization.
    public let details: ModelDetails?

    /// Conforms to `Identifiable` using the model name as the stable identifier.
    public var id: String { name }

    /// Metadata sub-object nested inside the `/api/tags` model entry.
    public struct ModelDetails: Codable, Sendable, Hashable {
        /// Storage format, e.g. `"gguf"`.
        public let format: String?
        /// Model family, e.g. `"llama"`.
        public let family: String?
        /// Human-readable parameter count, e.g. `"8B"`.
        public let parameterSize: String?
        /// Quantization level, e.g. `"Q4_K_M"`.
        public let quantizationLevel: String?

        private enum CodingKeys: String, CodingKey {
            case format
            case family
            case parameterSize      = "parameter_size"
            case quantizationLevel  = "quantization_level"
        }
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case modifiedAt = "modified_at"
        case size
        case digest
        case details
    }
}

// MARK: - Notification names

extension Notification.Name {
    /// Posted on `NotificationCenter.default` when ``OllamaManager`` exhausts all restart attempts.
    /// The main app observes this to surface an error banner in the UI.
    static let ollamaMaxRestartsExceeded = Notification.Name("com.kerwan.ollama.maxRestartsExceeded")

    /// Posted when Ollama transitions to a running state (either adopted or freshly launched).
    static let ollamaDidBecomeReady = Notification.Name("com.kerwan.ollama.didBecomeReady")
}
